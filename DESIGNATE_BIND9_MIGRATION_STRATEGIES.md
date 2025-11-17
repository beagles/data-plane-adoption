# Designate BIND9 Migration Strategies: TripleO to OpenShift

## Executive Summary

This document outlines strategies for migrating Designate BIND9 DNS servers from a TripleO-based deployment to OpenShift-based Red Hat OpenStack (RHOSO), with the critical constraint that **BIND9 server IP addresses must be preserved** due to external DNS infrastructure dependencies and hard-coded IP references from Unbound resolvers and OpenStack workloads.

## Background: The IP Preservation Challenge

### Why IPs Cannot Change

1. **External DNS Infrastructure Integration**: BIND9 servers are authoritative nameservers registered with external DNS infrastructure (zone delegations, glue records, NS records)
2. **Unbound Resolver Dependencies**: Unbound recursive resolvers used by OpenStack workloads reference BIND9 servers by IP address in their forwarder configurations
3. **Hard-coded References**: Legacy systems, documentation, and automation may contain hard-coded IP references
4. **DNS Protocol Constraints**: NS record updates have propagation delays (TTL-dependent) making immediate cutover with new IPs risky

### Current Architectures

#### TripleO Deployment
- BIND9 runs in containers on dedicated nodes or controller nodes
- IPs assigned to network interfaces via `DesignateBackendListenIPs` parameter or dynamically allocated from external network
- Configuration managed via Heat templates and ansible roles (`designate_bind_config`)
- IPs persisted through `ifup-local` scripts on host interfaces
- Worker communication via rndc on port 953

#### OpenShift Deployment
- BIND9 runs as StatefulSets in pods with Network Attachment Definitions (NADs)
- Predictable IPs allocated from NAD IPAM ranges via ConfigMaps (`designate-bind-ip-map`)
- Init containers configure secondary IPs on NAD interfaces using `setipalias.py`
- Configuration managed via operators and ConfigMaps
- Pools.yaml generated dynamically from IP mappings

## Migration Strategies

### Strategy 1: Direct IP Injection (Recommended for Small Deployments)

**Overview**: Explicitly configure OpenShift BIND9 pods to use the exact IPs from TripleO deployment.

#### Prerequisites
- Extract current BIND9 IPs from TripleO deployment
- Ensure NAD IPAM range includes these IPs
- Verify no IP conflicts in target OpenShift environment

#### Implementation Steps

```bash
# 1. Extract current BIND9 IPs from TripleO
ansible -i inventory.yaml designate_bind -m shell \
  -a "grep -E 'listen-on|listen-on-v6' /var/named/options.conf" > tripleo_bind_ips.txt

# Alternative: check interface configurations
ansible -i inventory.yaml designate_bind -m shell \
  -a "ip addr show | grep -A2 'inet.*designate'" > tripleo_bind_ips.txt

# 2. Create a predictable IP ConfigMap with exact IPs
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: designate-bind-ip-map
  namespace: openstack
data:
  bind_address_0: "192.168.24.50"  # Replace with actual TripleO IP
  bind_address_1: "192.168.24.51"  # Add more as needed
  bind_address_2: "192.168.24.52"
EOF

# 3. Configure Designate NAD to include these IPs in range
# Ensure NAD definition has IPAM range that includes target IPs

# 4. Deploy Designate with matching replica count
oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  designate:
    enabled: true
    template:
      designateBackendbind9:
        replicas: 3
        networkAttachments:
          - designate
'
```

#### Advantages
- Simple and direct
- Guaranteed IP preservation
- Works with existing external DNS infrastructure immediately

#### Disadvantages
- Requires manual IP extraction and configuration
- No automatic IP allocation benefits
- Potential for configuration drift

#### Cutover Process

```python
#!/usr/bin/env python3
"""
Cutover strategy for direct IP injection
"""

def cutover_bind9_direct_ip():
    steps = [
        "1. Verify TripleO BIND9 IPs and extract current zones",
        "2. Pre-create ConfigMap with exact IPs",
        "3. Stop TripleO BIND9 containers",
        "4. Deploy OpenShift BIND9 pods",
        "5. Wait for pods to reach Ready state",
        "6. Verify BIND9 listening on correct IPs (dig @IP)",
        "7. Restore zones from backup if needed",
        "8. Verify zone transfers and NOTIFY working",
        "9. Test Unbound -> BIND9 resolution",
        "10. Monitor logs for 24-48 hours"
    ]
    return steps
```

---

### Strategy 2: IP Takeover with Gradual Migration

**Overview**: Deploy OpenShift BIND9 with temporary IPs first, then swap IPs during a controlled maintenance window.

#### Implementation Steps

```bash
# Phase 1: Deploy parallel BIND9 with temporary IPs
oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  designate:
    enabled: true
    template:
      designateBackendbind9:
        replicas: 3
        networkAttachments:
          - designate
        # Let automatic IP allocation handle initial deployment
'

# Phase 2: Sync zone data (during parallel operation)
# Run zone export from TripleO BIND9
ansible -i inventory.yaml designate_bind[0] -m shell \
  -a "rndc dumpdb -zones; cat /var/named-persistent/data/cache_dump.db" \
  > tripleo_zones_backup.txt

# Import to OpenShift BIND9
oc exec -it designate-backendbind9-0 -- \
  bash -c "cat > /tmp/zones_import.txt" < tripleo_zones_backup.txt

# Phase 3: Controlled IP swap (maintenance window)
# 3a. Stop TripleO BIND9
ansible -i inventory.yaml designate_bind -m systemd \
  -a "name=tripleo_designate_backend_bind9 state=stopped"

# 3b. Update ConfigMap with production IPs
oc patch configmap designate-bind-ip-map --type=merge -p '
data:
  bind_address_0: "192.168.24.50"
  bind_address_1: "192.168.24.51"
  bind_address_2: "192.168.24.52"
'

# 3c. Delete pods to trigger recreation with new IPs
oc delete pod -l service=designate-backendbind9

# 3d. Verify new IPs assigned
oc exec designate-backendbind9-0 -- ip addr show designate
```

#### Advantages
- Lower risk - can test OpenShift deployment before IP swap
- Allows data sync and validation before cutover
- Rollback easier during parallel operation phase

#### Disadvantages
- Requires two IP ranges temporarily
- More complex cutover process
- Longer migration window

---

### Strategy 3: Network Attachment with Reserved IPs

**Overview**: Use OpenShift networking capabilities to reserve specific IPs via NetA ttachment Definition IPAM.

#### NAD Configuration

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: designate
  namespace: openstack
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "designate",
      "type": "bridge",
      "bridge": "ospbr",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.24.0/24",
        "range_start": "192.168.24.50",
        "range_end": "192.168.24.60",
        "routes": [{
          "dst": "0.0.0.0/0"
        }],
        "addresses": [
          {
            "address": "192.168.24.50/24",
            "gateway": "192.168.24.1"
          },
          {
            "address": "192.168.24.51/24",
            "gateway": "192.168.24.1"
          },
          {
            "address": "192.168.24.52/24",
            "gateway": "192.168.24.1"
          }
        ]
      }
    }
```

#### Implementation

```bash
# 1. Create NAD with specific IP reservations
oc apply -f designate-nad-with-reserved-ips.yaml

# 2. Annotate TripleO->OpenShift IP mapping in adoption vars
cat >> tests/vars.yaml <<EOF
designate_bind_ip_migration:
  tripleo_bind_ips:
    - host: overcloud-designate-bind-0
      ip: 192.168.24.50
    - host: overcloud-designate-bind-1
      ip: 192.168.24.51
    - host: overcloud-designate-bind-2
      ip: 192.168.24.52
  target_pod_ips:
    designate-backendbind9-0: 192.168.24.50
    designate-backendbind9-1: 192.168.24.51
    designate-backendbind9-2: 192.168.24.52
EOF

# 3. Pre-seed ConfigMap before Designate deployment
oc create configmap designate-bind-ip-map \
  --from-literal=bind_address_0=192.168.24.50 \
  --from-literal=bind_address_1=192.168.24.51 \
  --from-literal=bind_address_2=192.168.24.52

# 4. Deploy Designate
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml
```

#### Advantages
- Leverages OpenShift native networking
- More maintainable long-term
- Works well with MetalLB for external connectivity

#### Disadvantages
- Requires careful NAD configuration
- Depends on CNI plugin capabilities (Whereabouts, etc.)
- May need custom NAD per deployment

---

### Strategy 4: Hybrid Approach with Unbound Reconfiguration

**Overview**: Accept that BIND9 IPs will change, but update Unbound configurations dynamically during migration to point to new IPs.

#### When to Use
- When IP preservation is extremely difficult
- When Unbound resolvers are fully managed
- When external NS record updates are acceptable

#### Implementation

```python
#!/usr/bin/env python3
"""
Strategy 4: Update Unbound configurations during migration
"""

migration_steps = """
1. Deploy OpenShift BIND9 with new IPs
2. Extract new BIND9 pod IPs
3. Update Designate pools.yaml with new BIND9 targets
4. Update Unbound forwarder configurations on all compute nodes:

   # On each compute/edpm node
   cat > /etc/unbound/forward-zones.d/openstack.conf <<EOF
   forward-zone:
       name: "cloud.example.com"
       forward-addr: <new-bind9-ip-1>
       forward-addr: <new-bind9-ip-2>
       forward-addr: <new-bind9-ip-3>
   EOF

   systemctl reload unbound

5. Update external NS records (DNS registrar/parent zone)
6. Wait for TTL expiration (typically 24-48 hours)
7. Verify resolution working from external clients
8. Decommission TripleO BIND9
"""

def generate_unbound_update_playbook(old_ips, new_ips):
    """Generate Ansible playbook for Unbound updates"""
    playbook = {
        "name": "Update Unbound forwarders for new BIND9 IPs",
        "hosts": "edpm_nodes",
        "tasks": [
            {
                "name": "Backup current Unbound config",
                "ansible.builtin.copy": {
                    "src": "/etc/unbound/forward-zones.d/openstack.conf",
                    "dest": "/etc/unbound/forward-zones.d/openstack.conf.backup",
                    "remote_src": True
                }
            },
            {
                "name": "Update forward-zone configuration",
                "ansible.builtin.template": {
                    "src": "unbound-forwarder.conf.j2",
                    "dest": "/etc/unbound/forward-zones.d/openstack.conf"
                },
                "vars": {
                    "bind9_ips": new_ips
                }
            },
            {
                "name": "Reload Unbound",
                "ansible.builtin.systemd": {
                    "name": "unbound",
                    "state": "reloaded"
                }
            }
        ]
    }
    return playbook
```

#### Advantages
- Doesn't require IP preservation on BIND9 side
- Simpler OpenShift deployment
- Uses standard automatic IP allocation

#### Disadvantages
- Requires external NS record updates
- DNS propagation delays (TTL-dependent)
- Risk of resolution failures during transition
- Doesn't solve external infrastructure dependency

---

## Detailed Technical Considerations

### DNS Zone Transfer and NOTIFY Mechanism

```bash
# Zone transfers use:
# - NOTIFY from designate-mdns to BIND9 (port 53 UDP)
# - Zone transfer (AXFR/IXFR) from BIND9 to secondary servers
# - RNDC communication for dynamic zone updates (port 953 TCP)

# Verify NOTIFY working:
oc exec designate-mdns-0 -- dig @<bind9-ip> example.com AXFR

# Check BIND9 zone transfer logs:
oc logs designate-backendbind9-0 | grep -i "zone transfer"
```

### RNDC Key Migration

```bash
# Extract rndc key from TripleO
ansible -i inventory.yaml designate_bind[0] -m shell \
  -a "cat /etc/rndc.key" > tripleo_rndc_key.txt

# Create secret in OpenShift
oc create secret generic designate-bind-secret \
  --from-file=rndc-key-0=tripleo_rndc_key.txt

# Designate operator will use this for RNDC communication
```

### Zone Data Migration

```python
#!/usr/bin/env python3
"""
Zone data migration script
"""
import subprocess
import json

def export_tripleo_zones():
    """Export all zones from TripleO BIND9"""
    cmd = [
        "ansible", "-i", "inventory.yaml",
        "designate_bind[0]", "-m", "shell",
        "-a", "rndc dumpdb -zones"
    ]
    subprocess.run(cmd, check=True)

    # Copy zone files
    cmd = [
        "ansible", "-i", "inventory.yaml",
        "designate_bind[0]", "-m", "fetch",
        "-a", "src=/var/named-persistent/data/cache_dump.db dest=./zones/"
    ]
    subprocess.run(cmd, check=True)

def import_to_openshift_bind9():
    """Import zones to OpenShift BIND9 pods"""
    # Zones will automatically be recreated by Designate
    # worker when it connects to new BIND9 servers
    # This is just for disaster recovery

    for pod_idx in range(3):
        pod_name = f"designate-backendbind9-{pod_idx}"
        cmd = [
            "oc", "cp",
            f"./zones/cache_dump.db",
            f"{pod_name}:/var/named-persistent/zones_backup.db"
        ]
        subprocess.run(cmd, check=True)

def verify_zone_consistency():
    """Verify zones match between old and new"""
    # Query both old and new BIND9 for zone list
    pass
```

### Monitoring and Validation

```bash
# Create validation script for adoption playbook
cat > tests/roles/designate_adoption/tasks/verify_bind9_ips.yaml <<'EOF'
---
- name: Verify BIND9 pods have correct IPs
  ansible.builtin.shell: |
    {{ shell_header }}
    {{ oc_header }}

    # Get expected IPs from migration vars
    expected_ips='{{ designate_bind_ip_migration.target_pod_ips | dict2items }}'

    # Check each pod
    for pod in $(oc get pods -l service=designate-backendbind9 -o name); do
      pod_name=$(basename $pod)
      pod_ip=$(oc exec $pod -- ip addr show designate | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
      echo "Pod: $pod_name, IP: $pod_ip"
    done
  register: bind9_ip_verification

- name: Verify BIND9 responding on correct IPs
  ansible.builtin.shell: |
    {{ shell_header }}

    # Test DNS query to each IP
    for ip in {{ designate_bind_ip_migration.target_pod_ips.values() | join(' ') }}; do
      dig @$ip chaos txt version.bind +short || echo "FAIL: $ip not responding"
    done
  register: bind9_response_test

- name: Verify RNDC connectivity
  ansible.builtin.shell: |
    {{ shell_header }}
    {{ oc_header }}

    oc exec designate-worker-0 -- rndc -s {{ designate_bind_ip_migration.target_pod_ips.values() | first }} status
  register: rndc_test
EOF
```

---

## Recommended Migration Workflow for uni04delta Scenario

Based on the uni04delta scenario configuration, here's the recommended approach:

### Phase 1: Pre-Migration (Day 1-3)

```bash
# 1. Document current state
cd /home/beagles/data-plane-adoption
ansible-playbook -i tests/inventory.yaml tests/playbooks/extract_designate_config.yaml \
  --extra-vars "extract_bind_ips=true"

# 2. Create IP preservation configuration
cat > scenarios/uni04delta/designate_bind_ip_map.yaml <<EOF
# TripleO BIND9 IP mappings for preservation
designate_bind_ips:
  - 192.168.24.50  # overcloud-designate-bind-0
  - 192.168.24.51  # overcloud-designate-bind-1
  - 192.168.24.52  # overcloud-designate-bind-2
EOF

# 3. Pre-create ConfigMap
oc create -f scenarios/uni04delta/designate-bind-ip-configmap.yaml
```

### Phase 2: Adoption Preparation (Day 4-7)

```bash
# 1. Run adoption test with Designate (dry-run mode)
TEST_VARS=tests/vars.yaml TEST_SECRETS=tests/secrets.yaml \
  make test-with-designate --check

# 2. Validate IP allocation strategy
ansible-playbook tests/playbooks/validate_designate_ips.yaml

# 3. Backup zone data
ansible-playbook tests/playbooks/backup_designate_zones.yaml
```

### Phase 3: Cutover (Maintenance Window)

```bash
# Expected downtime: 30-45 minutes

# 1. Stop TripleO BIND9
ansible -i tests/inventory.yaml designate_bind -m systemd \
  -a "name=tripleo_designate_backend_bind9 state=stopped"

# 2. Run adoption playbook
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml \
  --tags designate_adoption

# 3. Verify IPs preserved
./tests/roles/designate_adoption/files/verify_bind9_ips.sh

# 4. Verify DNS resolution
dig @192.168.24.50 example.com
dig @192.168.24.51 example.com
dig @192.168.24.52 example.com

# 5. Check zone transfers
oc exec designate-mdns-0 -- rndc -s 192.168.24.50 status
```

### Phase 4: Validation (Day 8-14)

```bash
# Monitor for issues
oc logs -f designate-backendbind9-0
oc logs -f designate-worker-0

# Verify Unbound resolvers working
ansible -i tests/inventory.yaml osp-computes -m shell \
  -a "dig @localhost vm.example.com"

# Check external resolution (if NS records public)
dig @8.8.8.8 example.com NS
```

---

## Rollback Procedures

### Rollback to TripleO BIND9

```bash
# If migration fails within first 4 hours:

# 1. Scale down OpenShift BIND9
oc patch openstackcontrolplane openstack --type=merge --patch '
spec:
  designate:
    template:
      designateBackendbind9:
        replicas: 0
'

# 2. Restart TripleO BIND9
ansible -i tests/inventory.yaml designate_bind -m systemd \
  -a "name=tripleo_designate_backend_bind9 state=started"

# 3. Verify TripleO BIND9 operational
ansible -i tests/inventory.yaml designate_bind -m shell \
  -a "rndc status"

# 4. Re-enable Designate Worker connections to TripleO BIND9
# (Restore pools.yaml if modified)
```

### Partial Rollback (Hybrid Operation)

```python
#!/usr/bin/env python3
"""
Run both TripleO and OpenShift BIND9 in parallel
Use for extended validation period
"""

def configure_hybrid_pools_yaml():
    """
    Configure Designate pools.yaml to include both old and new BIND9 servers
    This provides redundancy during transition
    """
    pools_config = {
        "targets": [
            # TripleO BIND9 servers
            {"host": "192.168.24.50", "type": "bind9", "description": "TripleO BIND9-0"},
            {"host": "192.168.24.51", "type": "bind9", "description": "TripleO BIND9-1"},
            # OpenShift BIND9 servers (temporary IPs)
            {"host": "192.168.24.60", "type": "bind9", "description": "OpenShift BIND9-0"},
            {"host": "192.168.24.61", "type": "bind9", "description": "OpenShift BIND9-1"},
        ],
        "nameservers": [
            {"host": "192.168.24.50", "port": 53},
            {"host": "192.168.24.51", "port": 53},
        ]
    }
    return pools_config

# This allows:
# - Both sets of BIND9 servers receive zone updates
# - Unbound continues using old IPs
# - Validation of OpenShift BIND9 in production
# - Zero-downtime eventual cutover
```

---

## Testing and Validation Checklist

### Pre-Migration Validation

- [ ] Document all TripleO BIND9 IPs
- [ ] Identify all Unbound resolver references
- [ ] Export all DNS zones
- [ ] Backup rndc keys
- [ ] Verify NAD configuration supports target IPs
- [ ] Test OpenShift BIND9 deployment in non-production
- [ ] Verify MetalLB/external connectivity to target IPs

### Post-Migration Validation

- [ ] BIND9 pods running and Ready
- [ ] Correct IPs assigned to pods (ip addr show)
- [ ] BIND9 listening on ports 53 and 953
- [ ] RNDC connectivity from Designate Worker
- [ ] Zone transfers functioning (AXFR test)
- [ ] NOTIFY working from Designate MDNS
- [ ] Unbound resolvers can query BIND9
- [ ] External resolution working (if public NS records)
- [ ] Zone creation via Designate API successful
- [ ] No errors in Designate Worker/MDNS logs

### Performance Validation

```bash
# Query response time test
for ip in 192.168.24.50 192.168.24.51 192.168.24.52; do
  echo "Testing $ip:"
  time dig @$ip example.com +short
done

# Zone transfer performance
time dig @192.168.24.50 example.com AXFR | wc -l

# RNDC operation performance
oc exec designate-worker-0 -- time rndc -s 192.168.24.50 status
```

---

## Implementation Artifacts for uni04delta

### Required Test Role Updates

```bash
# Create new tasks for IP-aware adoption
mkdir -p tests/roles/designate_adoption/tasks/
touch tests/roles/designate_adoption/tasks/preserve_bind_ips.yaml
touch tests/roles/designate_adoption/tasks/verify_bind_ips.yaml

# Add to designate_adoption/defaults/main.yaml
cat >> tests/roles/designate_adoption/defaults/main.yaml <<'EOF'

# BIND9 IP preservation settings
designate_bind_ip_preservation: true
designate_bind_ip_source: "{{ lookup('file', scenarios_path + '/uni04delta/designate_bind_ip_map.yaml') | from_yaml }}"
EOF
```

### ConfigMap Pre-Creation Template

```yaml
# scenarios/uni04delta/designate-bind-ip-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: designate-bind-ip-map
  namespace: openstack
  labels:
    service: designate
    component: backendbind9
data:
  # These IPs must match TripleO deployment
  bind_address_0: "192.168.24.50"
  bind_address_1: "192.168.24.51"
  bind_address_2: "192.168.24.52"
```

### Adoption Playbook Integration

```yaml
# tests/playbooks/test_with_designate.yaml additions
- name: Adoption with Designate
  hosts: local
  roles:
    # ... existing roles ...

    - role: designate_adoption
      tags: designate_adoption
      vars:
        preserve_bind9_ips: true
        bind9_ip_configmap_path: "{{ scenarios_path }}/{{ scenario }}/designate-bind-ip-configmap.yaml"
```

---

## Conclusion

**Recommended Strategy for uni04delta**: **Strategy 1 (Direct IP Injection)** with **Strategy 2 (Gradual Migration)** as fallback.

### Rationale

1. **Direct IP preservation** eliminates DNS propagation delays and external dependencies
2. **uni04delta scenario** appears to be a standard HA controller deployment with dedicated BIND9 nodes
3. **OpenShift predictable IP mechanism** already supports arbitrary IP assignment via ConfigMaps
4. **Risk is minimized** by pre-creating IP mappings before cutover

### Next Steps

1. Extract actual BIND9 IPs from uni04delta TripleO deployment
2. Create ConfigMap pre-creation in adoption playbook
3. Add IP verification tasks to designate_adoption role
4. Test in CI/CD environment
5. Document rollback procedures
6. Create operational runbook for production cutover

### Key Success Factors

- **Thorough pre-migration documentation** of IPs and configurations
- **Zone data backup** before cutover
- **Verification at each step** of migration process
- **Monitoring** for 24-48 hours post-migration
- **Rollback plan** tested and ready

---

## Appendix: Related Files and References

### TripleO Configuration Files
- `/home/beagles/tripleo-heat-templates/deployment/designate/designate-bind-container.yaml`
- `/home/beagles/tripleo-ansible/tripleo_ansible/roles/designate_bind_config/`

### OpenShift Operator Code
- `/home/beagles/designate-operator/pkg/designatebackendbind9/deployment.go`
- `/home/beagles/designate-operator/controllers/designate_controller.go` (allocatePredictableIPs)
- `/home/beagles/designate-operator/templates/common/setipalias.py`

### Data Plane Adoption Framework
- `/home/beagles/data-plane-adoption/tests/roles/designate_adoption/`
- `/home/beagles/data-plane-adoption/scenarios/uni04delta/`

### DNS Protocol References
- RFC 1035 (DNS Protocol)
- RFC 1996 (DNS NOTIFY)
- RFC 5936 (DNS Zone Transfer Protocol AXFR)
- RFC 2136 (Dynamic Updates in DNS)

