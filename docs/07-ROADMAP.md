# Roadmap

Development roadmap for ITL Talos HardenedOS. Items are ordered by priority within each milestone.

---

## Current State — v1.9.0

**What works today:**
- Custom Talos v1.9.0 images with security extensions (Falco, OIDC, TPM register, Kata containers, LUKS2)
- GitHub Actions CI/CD pipeline — full build + ISO generation in ~45 min
- Role-specific ISOs: `controlplane`, `worker-infra`, `worker-app`
- Zero-Touch Provisioning via USB Alpine agent + Registration Service (FastAPI / SQLite)
- TPM-based machine identity (EK fingerprint) + PCR attestation (PCRs 0-7)
- Token-based one-time MachineConfig delivery (`talos.config=` kernel cmdline)
- Offline/airgapped enrollment via Enrollment CA + self-signed node certificates
- 3-node Kubernetes HA reference deployment
- Full Talos API access via `talosctl`

---

## Near-term — v1.10 (next quarter)

### ZTP: Auto-approve policy engine
**Problem**: All currently-unknown machines land in `pending_approval`, requiring manual admin action per node.
**Goal**: Rules-based auto-approval using hardware attributes — no human touch for known hardware profiles.

```
[ Rule examples ]
  hw_product = "PowerEdge R650" AND hw_rack_zone = "zone-a" → role=worker-app, auto-approve
  hw_serial IN asset_db AND asset_db.role = "controlplane"  → role=controlplane, auto-approve
  (no match)                                                  → status=pending_approval (as today)
```

Implementation plan:
- `POST /api/v1/policy` — CRUD for approval rules (JSON rules or OPA Rego)
- CMDB/asset inventory connector (CSV, Netbox, or API-based)
- Audit log: every auto-approval recorded with rule ID + hw attributes
- Admin override always possible

### Registration Service web UI
**Problem**: All admin operations currently via curl.
**Goal**: Simple browser-based dashboard for machine management.

Scope:
- Machine list with status badges (`pending_approval`, `registered`, `attested`, `rejected`)
- One-click approve / reject with role picker
- Hardware detail view (EK fingerprint, serial, mac, PCR quote summary)
- Offline bundle download per machine
- Activity feed / audit log

### arm64 ISO support
**Problem**: Only `amd64` ISOs built today.
**Goal**: Parallel arm64 builds for Graviton / Apple Silicon / Raspberry Pi 5 nodes.

- Extend Talos schematic YAML to include `arch: arm64`
- Add `ARCH` matrix to GitHub Actions workflow (`amd64`, `arm64`)
- Role ISOs: 6 artifacts per release (`{role}-{arch}.iso`)
- USB agent: detect host architecture and download matching ISO

---

## Mid-term — v2.0 (6-12 months)

### GitOps post-attestation trigger
**Problem**: After a node attests, GitOps (ArgoCD/Flux) workloads must be deployed manually.
**Goal**: Automatic GitOps sync triggered when a node transitions to `status=attested`.

- Registration Service webhook: `POST /callback/node-ready` after attestation
- ArgoCD ApplicationSet or Flux Kustomization reconcile triggered per node role
- Node labels synced from Registration Service metadata (rack, zone, role) to Kubernetes node labels

### Cluster lifecycle management via Registration Service
**Problem**: Talos upgrades (OS + Kubernetes) require manual `talosctl upgrade` per node.
**Goal**: Push new MachineConfig tokens to registered/attested nodes for coordinated upgrades.

- `POST /api/v1/machines/{id}/upgrade` — generate new config token for target version
- Node polls (or webhook notified) for pending upgrades
- Drain → upgrade → re-attest flow tracked in Registration Service
- Rollback: keep previous token until re-attestation succeeds

### Hardware health attestation
**Problem**: PCR quote today only proves boot chain integrity.
**Goal**: Extend attestation to include firmware versions and BIOS configuration hashes.

- Read DMI firmware version during USB agent phase
- Include `fw_version`, `bios_vendor`, `bios_date` in register payload
- Registration Service: optional enforcement policy (reject nodes on old firmware)
- Alert on firmware version drift across attested nodes

### Prometheus metrics for Registration Service
**Problem**: No visibility into provisioning pipeline health.
**Goal**: Expose metrics scrape-able by Prometheus.

```
itl_machines_total{status}           gauge   — count per status bucket
itl_provision_duration_seconds       histogram — USB agent → attested latency
itl_pending_approval_queue           gauge   — machines awaiting human action
itl_attestation_failures_total       counter — EK/PCR mismatch events
```

- Grafana dashboard: Provisioning throughput, queue depth, failure rate
- Alert: `pending_approval` queue > N for > 30 min

---

## Long-term — v3.0+ (12+ months)

### Multi-tenant cluster isolation
**Problem**: Single Registration Service and shared ISOs — no org-level separation.
**Goal**: Namespace/tenant isolation for large enterprise deployments.

- `tenant_id` field on machines, configs, approval policies
- Per-tenant ISO variants with org-specific patches (CA bundles, OIDC endpoints)
- Admin roles: global admin + tenant admin (scoped approval authority)
- Metrics and audit logs scoped per tenant

### Confidential attestation (vTPM / TDX / SEV)
**Problem**: PCR quote proves boot chain but not memory isolation.
**Goal**: Support Intel TDX and AMD SEV-SNP for confidential computing environments.

- Registration Service: accept TDX quote alongside TPM EK
- PCR policy extended with TDX RTMR measurements
- Azure Confidential VMs + AWS Nitro Enclaves as first targets

### Declarative cluster config in Git
**Problem**: Node roles and hostnames are imperative API calls.
**Goal**: Git-native node declaration — `nodes.yaml` in repo drives Registration Service state.

```yaml
# nodes.yaml
nodes:
  - hostname: cp1.itlusions.internal
    ek_fingerprint: abc123...
    role: controlplane
  - hostname: w1.itlusions.internal
    ek_fingerprint: def456...
    role: worker-app
```

- Registration Service reconciliation loop: `nodes.yaml` → pre-registered machines
- PRs to `nodes.yaml` = provisioning requests (with approver workflow via GitHub)
- Drift detection: machines in DB but not in `nodes.yaml` flagged for review

### Extension marketplace
**Problem**: Custom extensions (Falco, Kata, etc.) are hardcoded in schematics.
**Goal**: Operator-selectable extension catalog at build or deploy time.

- Extension registry: list of signed OCI images with version + compatibility matrix
- Per-role extension set configurable via `roles.yaml`
- Registration Service includes extension manifest in MachineConfig token response
- Automated compatibility testing in CI for each extension × Talos version combination

---

## Won't do / out of scope

| Item | Reason |
|------|--------|
| Windows worker nodes | Talos is Linux-only by design |
| GUI installer replacing USB agent | CLI-first philosophy; web UI covers admin needs |
| Public cloud managed Kubernetes (EKS/AKS/GKE) replacement | ZTP targets bare-metal + private cloud |

---

## Version History

| Version | Released | Highlights |
|---------|----------|-----------|
| v1.9.0 | Current | ZTP USB agent, Registration Service, TPM attestation, 3 node roles, LUKS2, OIDC, Falco |
| v1.8.x | Prior | Manual `talosctl apply-config` workflow, basic ISO generation |
