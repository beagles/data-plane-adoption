# Designate BIND9 Migration Guide for uni04delta Scenario

## Overview

This guide provides specific instructions for migrating Designate DNS service from TripleO to OpenShift in the uni04delta scenario. It covers BIND9 IP address extraction and documentation to support informed IP management decisions.

## Prerequisites

### TripleO Configuration
- Designate BIND9 services must be running
- BIND9 IPs must be accessible (see extraction steps below)
- Zone data should be backed up before migration
- RNDC keys must be available for zone management

## Migration Steps

### Step 1: Extract BIND9 IP Addresses from TripleO

There are three methods to extract the current BIND9 IPs:

#### Method A: Automatic extraction via Ansible role (Recommended)

```bash
cd /home/beagles/data-plane-adoption

# Run the extraction task
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/extract_designate_config.yaml \
  --tags extract_bind_ips

# Check the generated file
cat tripleo_bind9_ips.yaml
```

#### Method B: Manual extraction from TripleO nodes

```bash
# SSH to each designate_bind node and check the IP
ansible -i tests/inventory.yaml designate_bind -m shell \
  -a "ip addr show | grep -E 'inet.*192.168.24' | awk '{print \$2}' | cut -d/ -f1"

# Or check the Designate configuration
ansible -i tests/inventory.yaml designate_bind -m shell \
  -a "grep -E 'listen-on' /var/lib/config-data/puppet-generated/designate/etc/named.conf"
```

#### Method C: Extract from Designate pools.yaml

```bash
# Get pools.yaml from controller
ansible -i tests/inventory.yaml osp-controllers[0] -m shell \
  -a "sudo podman exec designate_worker cat /etc/designate/pools.yaml"

# Parse the 'host' field from targets section
```

### Step 2: Store IP Information

#### Automatic storage via adoption playbook

If you used Method A above, the IPs are already in `tripleo_bind9_ips.yaml`. The adoption playbook will automatically create the ConfigMap with this information.

#### Manual ConfigMap creation

```bash
cd scenarios/uni04delta

# Copy the template
cp designate-bind-ip-configmap.yaml.template designate-bind-ip-configmap.yaml

# Edit with actual IPs
vim designate-bind-ip-configmap.yaml

# Create the ConfigMap before running adoption
oc apply -f designate-bind-ip-configmap.yaml
```

Example ConfigMap with extracted IPs:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: designate-bind-ip-map
  namespace: openstack
data:
  bind_address_0: "192.168.24.50"  # Actual IP from your TripleO deployment
  bind_address_1: "192.168.24.51"
  bind_address_2: "192.168.24.52"
```

### Step 3: Update Test Variables

Ensure your `tests/vars.yaml` includes Designate-specific configuration:

```yaml
# Designate BIND9 IP preservation
designate_bind_ip_preservation: true

# Number of BIND9 replicas (should match TripleO deployment)
# This will be auto-detected from tripleo_bind9_ips if available
# designate_bind9_replicas: 3

# Optional: Explicitly set IPs if not auto-extracted
# tripleo_bind9_ips:
#   - "192.168.24.50"
#   - "192.168.24.51"
#   - "192.168.24.52"
```

### Step 4: Run the Adoption Playbook

#### Full adoption with Designate

```bash
cd /home/beagles/data-plane-adoption

# Set test configuration
export TEST_VARS=tests/vars.yaml
export TEST_SECRETS=tests/secrets.yaml

# Run adoption including Designate
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml
```

#### Designate-only adoption (if other services already adopted)

```bash
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml \
  --tags designate_adoption
```

#### Skip IP preservation (not recommended for production)

```bash
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml \
  --tags designate_adoption \
  --extra-vars "designate_bind_ip_preservation=false"
```

### Step 5: Verify IP Information Preservation

After deployment, verify that the IP information is correctly preserved:

```bash
# Use the generated verification script
./tests/verify_bind9_ips.sh

# Or manually check the ConfigMap
oc get configmap designate-bind-ip-map -o yaml

# Check BIND9 pod readiness
oc get pods -l service=designate,component=designate-backendbind9
```

### Step 6: Verify Designate Functionality

```bash
# Check Designate endpoints
oc exec -it openstackclient -- openstack endpoint list | grep dns

# List zones (should show existing zones from TripleO)
oc exec -it openstackclient -- openstack zone list

# Test zone creation
oc exec -it openstackclient -- openstack zone create --email admin@example.com test.example.com.

# Verify zone functionality
dig test.example.com SOA +short
```

### Step 7: Validate Zone Management

```bash
# Check Designate Worker readiness
oc get pods -l service=designate,component=designate-worker

# Verify zone transfer capability
oc logs designate-worker-0 | grep -i "zone\|transfer"

# Test zone updates
oc exec -it openstackclient -- openstack zone list -f table
```

## Troubleshooting

### IPs Not Extracted

**Symptom**: Extraction script fails or returns empty list

**Diagnosis**:
```bash
# Check if designate_bind group exists
ansible-inventory --list | grep designate_bind

# Check TripleO BIND9 service status
ansible -i tests/inventory.yaml designate_bind -m systemd \
  -a "name=tripleo_designate_backend_bind9 state=present"
```

**Solution**:
1. Verify `designate_bind` group is defined in inventory
2. Ensure TripleO BIND9 services are running
3. Use manual extraction methods (B or C above)

### DNS Not Responding

**Symptom**: Designate API not accessible or DNS queries fail

**Diagnosis**:
```bash
# Check if Designate pods are ready
oc get pods -l service=designate

# Check Designate API logs
oc logs designate-api-0 | tail -20

# Verify BIND9 pod health
oc get pods -l component=designate-backendbind9
```

**Solution**:
1. Wait for all pods to reach Ready state
2. Check pod logs for errors
3. Verify storage is available for BIND9 pods

### Zone Data Not Migrated

**Symptom**: Zone list empty or zones not visible in OpenShift

**Diagnosis**:
```bash
# Check database migration
oc logs designate-central-0 | grep -i "database\|migrate"

# Check if zones exist in TripleO
ansible -i tests/inventory.yaml osp-controllers[0] -m shell \
  -a "sudo podman exec designate_worker openstack zone list"
```

**Solution**:
1. Verify database copy completed successfully
2. Ensure zone data is accessible from previous deployment
3. Check database credentials in osp-secret

### Unbound Resolvers Not Working

**Symptom**: Compute nodes cannot resolve DNS

**Diagnosis**:
```bash
# Check Unbound configuration on compute nodes
ansible -i tests/inventory.yaml osp-computes -m shell \
  -a "cat /etc/unbound/forward-zones.d/openstack.conf"

# Test resolution from compute
ansible -i tests/inventory.yaml osp-computes -m shell \
  -a "dig @localhost test.example.com"
```

**Solution**:
1. Verify Unbound forward-zone configuration is correct
2. Check Unbound service status: `systemctl status unbound`
3. Review Unbound logs: `journalctl -u unbound -f`

## Rollback Procedure

If migration fails and you need to rollback to TripleO:

```bash
# 1. Scale down OpenShift Designate BIND9
oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  designate:
    template:
      designateBackendbind9:
        replicas: 0
'

# 2. Wait for pods to terminate
oc get pods -l service=designate,component=designate-backendbind9 -w

# 3. Restart TripleO BIND9 services
ansible -i tests/inventory.yaml designate_bind -m systemd \
  -a "name=tripleo_designate_backend_bind9 state=started"

# 4. Verify TripleO BIND9 operational
ansible -i tests/inventory.yaml designate_bind -m shell \
  -a "rndc status"

# 5. Restore Designate Worker configuration if needed
ansible -i tests/inventory.yaml osp-controllers -m shell \
  -a "sudo podman restart designate_worker"
```

## Post-Migration Monitoring

Monitor these aspects for 24-48 hours after migration:

```bash
# BIND9 pod health
oc get pods -l service=designate,component=designate-backendbind9 -w

# BIND9 logs
oc logs -f designate-backendbind9-0

# Designate Worker logs
oc logs -f designate-worker-0

# DNS query functionality
dig test.example.com +short

# Designate zone management
oc exec -it openstackclient -- openstack zone list
```

## Validation Checklist

- [ ] BIND9 IPs extracted and documented
- [ ] ConfigMap created with extracted IP information
- [ ] Adoption playbook completed successfully
- [ ] All BIND9 pods in Ready state
- [ ] IP information stored correctly
- [ ] DNS service responding
- [ ] Designate API accessible
- [ ] Zone list populated from TripleO data
- [ ] Zone creation via API successful
- [ ] Zone management working
- [ ] No errors in Designate component logs
- [ ] External DNS resolution working (if applicable)

## References

- Main migration strategy document: `/home/beagles/data-plane-adoption/DESIGNATE_BIND9_MIGRATION_STRATEGIES.md`
- Designate operator repository: `/home/beagles/designate-operator`
- TripleO BIND9 configuration: `/home/beagles/tripleo-heat-templates/deployment/designate/`
- Test role: `/home/beagles/data-plane-adoption/tests/roles/designate_adoption/`
