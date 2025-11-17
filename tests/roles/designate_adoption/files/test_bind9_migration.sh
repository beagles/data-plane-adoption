#!/bin/bash
# Comprehensive BIND9 migration testing script
# Tests IP preservation, DNS functionality, and zone transfers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

function print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

function test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

function test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

function test_skip() {
    echo -e "${YELLOW}⊘ SKIP${NC}: $1"
    ((TESTS_SKIPPED++))
}

function check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}ERROR${NC}: Required command '$1' not found"
        exit 1
    fi
}

# Check prerequisites
print_header "Checking Prerequisites"
check_command oc
check_command dig
check_command jq

# Get expected IPs from ConfigMap
print_header "Loading Expected IP Configuration"

if ! CM_DATA=$(oc get configmap designate-bind-ip-map -n openstack -o json 2>/dev/null); then
    echo -e "${RED}ERROR${NC}: ConfigMap 'designate-bind-ip-map' not found"
    echo "Have you run the IP preservation steps?"
    exit 1
fi

EXPECTED_IPS=$(echo "$CM_DATA" | jq -r '.data | to_entries[] | select(.key | startswith("bind_address_")) | .value')
IP_COUNT=$(echo "$EXPECTED_IPS" | wc -l)

echo "Found $IP_COUNT expected BIND9 IP(s):"
echo "$EXPECTED_IPS" | while read ip; do echo "  - $ip"; done

# Test 1: Verify pods are running
print_header "Test 1: BIND9 Pod Health"

POD_LIST=$(oc get pods -n openstack -l service=designate-backendbind9 -o name 2>/dev/null || true)

if [ -z "$POD_LIST" ]; then
    test_fail "No BIND9 pods found"
else
    POD_COUNT=$(echo "$POD_LIST" | wc -l)

    if [ "$POD_COUNT" -eq "$IP_COUNT" ]; then
        test_pass "Pod count matches IP count ($POD_COUNT)"
    else
        test_fail "Pod count ($POD_COUNT) does not match IP count ($IP_COUNT)"
    fi

    # Check each pod is Ready
    for pod in $POD_LIST; do
        pod_name=$(basename "$pod")
        if oc wait "$pod" -n openstack --for=condition=Ready --timeout=5s >/dev/null 2>&1; then
            test_pass "Pod $pod_name is Ready"
        else
            test_fail "Pod $pod_name is not Ready"
        fi
    done
fi

# Test 2: Verify IP assignments
print_header "Test 2: IP Address Preservation"

if [ -z "$POD_LIST" ]; then
    test_skip "No pods to test (from Test 1 failure)"
else
    for pod in $POD_LIST; do
        pod_name=$(basename "$pod")
        pod_index=$(echo "$pod_name" | grep -oE '[0-9]+$')
        expected_ip=$(echo "$EXPECTED_IPS" | sed -n "$((pod_index + 1))p")

        # Get actual IP from pod
        actual_ip=$(oc exec -n openstack "$pod_name" -- ip addr show designate 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "")

        if [ -z "$actual_ip" ]; then
            test_fail "$pod_name: Could not retrieve IP"
        elif [ "$actual_ip" == "$expected_ip" ]; then
            test_pass "$pod_name has correct IP: $actual_ip"
        else
            test_fail "$pod_name has wrong IP: $actual_ip (expected: $expected_ip)"
        fi
    done
fi

# Test 3: DNS port accessibility
print_header "Test 3: DNS Port Accessibility"

echo "$EXPECTED_IPS" | while read ip; do
    if timeout 5 bash -c "echo > /dev/tcp/$ip/53" 2>/dev/null; then
        test_pass "DNS port 53 accessible on $ip"
    else
        test_fail "DNS port 53 not accessible on $ip"
    fi
done

# Test 4: DNS query response
print_header "Test 4: DNS Query Response"

echo "$EXPECTED_IPS" | while read ip; do
    if response=$(dig @$ip version.bind chaos txt +short +timeout=5 2>/dev/null); then
        if echo "$response" | grep -q "BIND"; then
            test_pass "BIND9 responding on $ip: $response"
        else
            test_fail "Unexpected response from $ip: $response"
        fi
    else
        test_fail "No DNS response from $ip"
    fi
done

# Test 5: RNDC port accessibility
print_header "Test 5: RNDC Port Accessibility"

echo "$EXPECTED_IPS" | while read ip; do
    if timeout 5 bash -c "echo > /dev/tcp/$ip/953" 2>/dev/null; then
        test_pass "RNDC port 953 accessible on $ip"
    else
        test_fail "RNDC port 953 not accessible on $ip"
    fi
done

# Test 6: RNDC connectivity from Designate Worker
print_header "Test 6: RNDC Connectivity from Designate Worker"

WORKER_POD=$(oc get pods -n openstack -l service=designate-worker -o name 2>/dev/null | head -1 || true)

if [ -z "$WORKER_POD" ]; then
    test_skip "No Designate Worker pod found"
else
    worker_name=$(basename "$WORKER_POD")

    echo "$EXPECTED_IPS" | while read ip; do
        if oc exec -n openstack "$worker_name" -- timeout 10 rndc -s "$ip" status 2>&1 | grep -q "version"; then
            test_pass "RNDC connection successful from worker to $ip"
        else
            test_fail "RNDC connection failed from worker to $ip"
        fi
    done
fi

# Test 7: Designate API endpoints
print_header "Test 7: Designate API Endpoints"

OSCLIENT_POD=$(oc get pods -n openstack -l service=openstackclient -o name 2>/dev/null | head -1 || true)

if [ -z "$OSCLIENT_POD" ]; then
    test_skip "No openstackclient pod found"
else
    if oc exec -n openstack "$OSCLIENT_POD" -- openstack endpoint list 2>/dev/null | grep -q "dns"; then
        test_pass "Designate endpoints are registered"
    else
        test_fail "Designate endpoints not found"
    fi
fi

# Test 8: Zone listing
print_header "Test 8: Zone Listing"

if [ -z "$OSCLIENT_POD" ]; then
    test_skip "No openstackclient pod (from Test 7)"
else
    if zone_list=$(oc exec -n openstack "$OSCLIENT_POD" -- openstack zone list -f value 2>/dev/null); then
        zone_count=$(echo "$zone_list" | wc -l)
        test_pass "Zone listing successful ($zone_count zones)"

        if [ "$zone_count" -gt 0 ]; then
            echo "Zones found:"
            echo "$zone_list" | awk '{print "  - " $2}'
        fi
    else
        test_fail "Could not list zones"
    fi
fi

# Test 9: Test zone creation
print_header "Test 9: Zone Creation Test"

if [ -z "$OSCLIENT_POD" ]; then
    test_skip "No openstackclient pod (from Test 7)"
else
    TEST_ZONE="test-adoption-$(date +%s).example.com."

    if oc exec -n openstack "$OSCLIENT_POD" -- \
        openstack zone create --email admin@example.com "$TEST_ZONE" 2>/dev/null >/dev/null; then
        test_pass "Test zone created: $TEST_ZONE"

        # Verify zone is on BIND9 servers
        sleep 5  # Give time for zone to propagate

        echo "$EXPECTED_IPS" | while read ip; do
            if dig @$ip "$TEST_ZONE" SOA +short +timeout=5 2>/dev/null | grep -q SOA; then
                test_pass "Zone $TEST_ZONE found on BIND9 server $ip"
            else
                test_fail "Zone $TEST_ZONE not found on BIND9 server $ip"
            fi
        done

        # Cleanup test zone
        if oc exec -n openstack "$OSCLIENT_POD" -- \
            openstack zone delete "$TEST_ZONE" 2>/dev/null >/dev/null; then
            test_pass "Test zone deleted: $TEST_ZONE"
        else
            test_fail "Could not delete test zone: $TEST_ZONE"
        fi
    else
        test_fail "Could not create test zone"
    fi
fi

# Test 10: Zone transfer capability
print_header "Test 10: Zone Transfer (AXFR) Test"

MDNS_POD=$(oc get pods -n openstack -l service=designate-mdns -o name 2>/dev/null | head -1 || true)

if [ -z "$MDNS_POD" ]; then
    test_skip "No Designate MDNS pod found"
elif [ -z "$zone_list" ] || [ $(echo "$zone_list" | wc -l) -eq 0 ]; then
    test_skip "No zones available for transfer test"
else
    mdns_name=$(basename "$MDNS_POD")
    test_zone=$(echo "$zone_list" | head -1 | awk '{print $2}')

    echo "$EXPECTED_IPS" | while read ip; do
        if oc exec -n openstack "$mdns_name" -- \
            dig @$ip "$test_zone" AXFR +timeout=10 2>/dev/null | grep -q SOA; then
            test_pass "Zone transfer successful from $ip for zone $test_zone"
        else
            test_fail "Zone transfer failed from $ip for zone $test_zone"
        fi
    done
fi

# Test 11: Configuration verification
print_header "Test 11: Configuration Verification"

if [ -z "$POD_LIST" ]; then
    test_skip "No pods to test (from Test 1 failure)"
else
    first_pod=$(echo "$POD_LIST" | head -1 | xargs basename)

    # Check named.conf
    if oc exec -n openstack "$first_pod" -- test -f /etc/named.conf; then
        test_pass "named.conf exists in pod $first_pod"

        # Check if it's listening on correct network
        if oc exec -n openstack "$first_pod" -- grep -q "listen-on" /etc/named.conf 2>/dev/null; then
            test_pass "listen-on directive found in named.conf"
        else
            test_fail "listen-on directive not found in named.conf"
        fi
    else
        test_fail "named.conf not found in pod $first_pod"
    fi

    # Check rndc.conf
    if oc exec -n openstack "$first_pod" -- test -f /etc/rndc.conf; then
        test_pass "rndc.conf exists in pod $first_pod"
    else
        test_fail "rndc.conf not found in pod $first_pod"
    fi
fi

# Test 12: Persistent storage
print_header "Test 12: Persistent Storage"

if [ -z "$POD_LIST" ]; then
    test_skip "No pods to test (from Test 1 failure)"
else
    for pod in $POD_LIST; do
        pod_name=$(basename "$pod")

        if oc exec -n openstack "$pod_name" -- test -d /var/named-persistent; then
            test_pass "Persistent storage mounted in $pod_name"

            # Check if writable
            if oc exec -n openstack "$pod_name" -- \
                sh -c "touch /var/named-persistent/.test && rm /var/named-persistent/.test" 2>/dev/null; then
                test_pass "Persistent storage is writable in $pod_name"
            else
                test_fail "Persistent storage not writable in $pod_name"
            fi
        else
            test_fail "Persistent storage not mounted in $pod_name"
        fi
    done
fi

# Test 13: Resource usage
print_header "Test 13: Resource Usage"

if [ -z "$POD_LIST" ]; then
    test_skip "No pods to test (from Test 1 failure)"
else
    for pod in $POD_LIST; do
        pod_name=$(basename "$pod")

        if mem_usage=$(oc exec -n openstack "$pod_name" -- \
            sh -c "free -m | awk 'NR==2{print \$3}'" 2>/dev/null); then
            test_pass "$pod_name memory usage: ${mem_usage}MB"
        else
            test_skip "Could not get memory usage for $pod_name"
        fi
    done
fi

# Summary
print_header "Test Summary"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

echo "Total tests:  $TOTAL_TESTS"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
echo -e "${YELLOW}Skipped:      $TESTS_SKIPPED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}ALL TESTS PASSED!${NC}"
    echo -e "${GREEN}BIND9 migration successful with IP preservation.${NC}"
    echo -e "${GREEN}========================================${NC}"
    exit 0
else
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}SOME TESTS FAILED!${NC}"
    echo -e "${RED}Please review the failures above.${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
fi

