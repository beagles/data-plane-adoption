# Designate BIND9 Migration - Quick Start Guide

## TL;DR - 5-Minute Overview

Migrating Designate DNS service from TripleO to OpenShift enables consolidation onto a cloud-native platform while extracting and preserving important configuration information.

This quick start focuses on information extraction and basic migration:
- Extract IP addresses, RNDC keys, and NS records from TripleO
- Store extracted information in ConfigMaps for documentation and audit
- Verify information is correctly preserved and accessible

## Quick Migration Steps

### 1. Extract Information from TripleO (5 minutes)

```bash
cd /home/beagles/data-plane-adoption

# Run extraction playbook
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/extract_designate_config.yaml

# Check results
cat tripleo_bind9_ips.yaml
```

### 2. Run Adoption (30-45 minutes)

```bash
# The adoption playbook automatically handles information extraction
ansible-playbook -i tests/inventory.yaml \
  tests/playbooks/test_with_designate.yaml
```

The adoption role will:
- Extract BIND9 IPs from TripleO
- Create ConfigMap with extracted information
- Deploy Designate to OpenShift
- Verify extraction and deployment
- Test DNS functionality

### 3. Verify Migration (5 minutes)

```bash
# Run comprehensive test suite
./tests/roles/designate_adoption/files/test_bind9_migration.sh

# Check ConfigMap contents
oc get configmap designate-bind-ip-map -o yaml
```

## What Happens Behind the Scenes

### Information Extraction

1. **Extraction** (`extract_bind_ips.yaml`):
   - Queries TripleO BIND9 nodes for current IPs
   - Parses pools.yaml for configuration
   - Saves IPs to `tripleo_bind9_ips.yaml`
   - Extracts RNDC keys and NS records

2. **Preservation** (`preserve_bind_ips.yaml`):
   - Creates `designate-bind-ip-map` ConfigMap with extracted IPs
   - ConfigMap format: `bind_address_0: "192.168.24.50"`
   - Stores extraction timestamp and metadata
   - Maps pod index to preserved IP address

3. **Verification** (`verify_bind_ips.yaml`):
   - Confirms extracted information is correctly stored
   - Tests DNS queries on extracted IPs
   - Verifies RNDC connectivity
   - Validates information persistence

## Architecture Overview

### TripleO Designate Architecture
```
┌─────────────────────────────────────────┐
│ Baremetal/VM Node                       │
│  ┌────────────────────────────────────┐ │
│  │ BIND9 Container                    │ │
│  │  - Serves external DNS queries     │ │
│  │  - IP configured via Heat/Ansible  │ │
│  └────────────────────────────────────┘ │
│  Interface: eth1 (192.168.24.50/24)    │
└─────────────────────────────────────────┘
```

### OpenShift Designate Architecture
```
┌──────────────────────────────────────────────────┐
│ OpenShift Cluster                                │
│  ┌────────────────────────────────────────────┐ │
│  │ Pod: designate-backendbind9-0              │ │
│  │  - BIND9 container for DNS                 │ │
│  │  - Receives zone updates from MDNS         │ │
│  │  - Serves external queries                 │ │
│  └────────────────────────────────────────────┘ │
│  Pod extracts IP information from ConfigMap    │
└──────────────────────────────────────────────────┘
```

## Critical Configuration Points

### Extracted Information Storage

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: designate-bind-ip-map
  namespace: openstack
  annotations:
    tripleo.openstack.org/extracted-at: "2025-01-01T00:00:00Z"
data:
  bind_address_0: "192.168.24.50"  # Pod 0 reference
  bind_address_1: "192.168.24.51"  # Pod 1 reference
  bind_address_2: "192.168.24.52"  # Pod 2 reference
```

### Designate CR Configuration
```yaml
spec:
  designate:
    template:
      designateBackendbind9:
        replicas: 3  # Must match number of extracted IPs
```

## Troubleshooting Quick Reference

| Symptom | Check | Solution |
|---------|-------|----------|
| IPs not extracted | Check designate_bind inventory group | Verify TripleO BIND9 group exists in inventory |
| ConfigMap not created | `oc get cm designate-bind-ip-map` | Run extraction tasks independently |
| RNDC connection fails | `oc get secret designate-bind-secret` | Verify RNDC key extracted from TripleO |
| Zone transfer fails | `oc logs designate-worker-0` | Check Designate Worker logs |
| Unbound not resolving | Check Unbound configuration on compute | Verify forward-zone IP references |

## DNS Architecture Considerations

### Information Preserved

The migration preserves:
1. **BIND9 IP Addresses** - For documentation and verification
2. **RNDC Keys** - For zone management and control
3. **NS Records** - Zone service records from TripleO
4. **Zone Data** - Migrated through database copy

### Why This Information Matters

1. **Audit Trail**: Complete record of migrated configuration
2. **Verification**: Can confirm information is correctly preserved
3. **Rollback**: Reference information for reverting if needed
4. **Documentation**: Permanent record in ConfigMaps

## Migration Timeline

| Time | Activity |
|------|----------|
| T-24h | Extract configuration, review information |
| T-1h | Backup zone data, verify prerequisites |
| T-0 | **Start Maintenance Window** |
| T+5min | Extract final configuration snapshot |
| T+10min | Deploy OpenShift Designate |
| T+30min | Verify all tests pass |
| T+45min | **End Maintenance Window** |
| T+24h | Monitor for issues |

## Success Criteria

✅ BIND9 configuration information extracted successfully
✅ ConfigMap created with preserved IP information
✅ All BIND9 pods running and Ready
✅ DNS service operational
✅ Zone data accessible and queryable
✅ Zone creation/deletion via API working
✅ RNDC connectivity established
✅ No errors in Designate logs
✅ Information audit trail complete

## Extracted Information Files

### Documentation Created
- `DESIGNATE_BIND9_MIGRATION_STRATEGIES.md` - Strategy overview
- `DESIGNATE_MIGRATION_SUMMARY.md` - Implementation details
- `DESIGNATE_MIGRATION_INDEX.md` - Navigation guide
- `scenarios/uni04delta/README_DESIGNATE_MIGRATION.md` - Scenario guide

### Extracted Artifacts
- `tripleo_bind9_ips.yaml` - BIND9 IPs from TripleO
- `designate-bind-ip-map` ConfigMap - Stored in Kubernetes
- `designate-bind-secret` Secret - RNDC key storage

### Ansible Components
- `tests/roles/designate_adoption/tasks/extract_bind_ips.yaml` - IP extraction
- `tests/roles/designate_adoption/tasks/preserve_bind_ips.yaml` - ConfigMap creation
- `tests/roles/designate_adoption/tasks/verify_bind_ips.yaml` - Information verification

### Testing
- `tests/roles/designate_adoption/files/test_bind9_migration.sh` - Comprehensive verification

## Next Steps

1. **Review documentation**: Read `DESIGNATE_BIND9_MIGRATION_STRATEGIES.md` for detailed strategies
2. **Understand your deployment**: Check current BIND9 configuration in TripleO
3. **Plan maintenance window**: Coordinate with DNS team about migration timing
4. **Test in non-production**: Run through migration in staging environment
5. **Execute migration**: Follow scenario-specific guide for your deployment

## Support and References

- **TripleO BIND9 Templates**: `/home/beagles/tripleo-heat-templates/deployment/designate/`
- **Designate Operator**: `/home/beagles/designate-operator/`
- **Adoption Framework**: `/home/beagles/data-plane-adoption/tests/roles/designate_adoption/`

## Key Concept

> The migration strategy centers on comprehensive information extraction:
> TripleO configuration extracted → ConfigMaps created → Information verified
> → Deployable in OpenShift → Complete audit trail maintained!

This approach ensures no configuration information is lost and all decisions
can be made with complete visibility into the migrated system.
