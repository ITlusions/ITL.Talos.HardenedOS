# Project Structure Reference

Complete file listing and component organization.

## Directory Tree

```
ITL.Talos.HardenedOS/
|-- README.md
|-- LICENSE
|-- .github/
|   +-- workflows/
|       +-- build-talos-hardened.yaml     GitHub Actions pipeline (tag-triggered)
|
|-- docs/                                 Documentation
|   |-- 01-QUICK_REFERENCE.md
|   |-- 02-VISUAL_OVERVIEW.md
|   |-- 03-BUILD-PIPELINE.md
|   |-- 04-DEPLOYMENT.md
|   |-- 05-CONTAINER-USAGE.md
|   |-- 06-PROJECT-STRUCTURE.md           This file
|   |-- 07-ROADMAP.md
|   |-- 08-BAREMETAL-CLUSTER-WALKTHROUGH.md
|   |-- 09-REGISTRATION-SERVICE.md        Registration Service deploy + API reference
|   |-- 10-TPM-PROVISIONING.md            ZTP: USB agent + attestation flow
|   |-- 11-AIRGAPPED-DEPLOYMENT.md        Offline/air-gapped enrollment
|   |-- 12-SECURITY-REFERENCE.md          Security config reference
|   |-- 13-OPERATIONS.md                  Day-to-day operations
|   +-- 14-TROUBLESHOOTING.md             Troubleshooting guide
|
|-- config/
|   +-- patches/
|       |-- branding-patch.yaml           Console branding MachineConfig patch
|       |-- security-hardening.yaml       LUKS2, TPM, kernel hardening, SSH, kubelet CIS
|       +-- oidc-patch.yaml               kube-apiserver OIDC (Keycloak)
|
|-- extensions/
|   |-- itl-branding/
|   |   |-- manifest.yaml                 Talos extension manifest
|   |   |-- Dockerfile                    Builds rootfs overlay
|   |   +-- rootfs/
|   |       +-- usr/local/itl/            Boot banner + MOTD assets
|   |
|   |-- itl-security/
|   |   |-- manifest.yaml
|   |   |-- Dockerfile
|   |   +-- rootfs/
|   |       +-- etc/
|   |           |-- audit/                Audit rules
|   |           |-- modprobe.d/           Kernel module policy
|   |           +-- sysctl.d/             Additional sysctl overrides
|   |
|   +-- itl-tpm-register/                 TPM registration + attestation extension
|       |-- manifest.yaml                 v1.0.0, compat >= v1.7.0, idempotent
|       |-- Dockerfile                    Compiles tpm2-tools; copies binaries + scripts
|       +-- rootfs/
|           +-- usr/local/itl/
|               |-- tpm-common.sh         Shared: read_hw_identity, read_tpm_ek, ek_fingerprint
|               |-- tpm-register.sh       Phase 1 USB: register + ISO download + dd
|               +-- tpm-attest.sh         Phase 2 Talos: PCR quote or cert enrollment
|
|-- branding/
|   |-- ascii-art/
|   |   +-- boot-banner.txt
|   +-- logos/
|
|-- provisioner/
|   |-- docker-compose.yml                Registration Service + Caddy TLS stack
|   |-- Caddyfile                         TLS reverse proxy (rate-limit on /enroll)
|   |-- .env.example                      Environment variable template
|   +-- usb-agent/
|       |-- build-usb.sh                  Build online USB provisioning drive
|       |-- build-usb-offline.sh          Build air-gapped USB (pre-baked bundle)
|       |-- register.sh                   USB agent entry point (Alpine boot script)
|       +-- Dockerfile.usb-builder        USB image builder
|
|-- services/
|   +-- machine-registration/             FastAPI Registration Service
|       |-- Dockerfile
|       |-- pyproject.toml
|       +-- src/registration/
|           |-- main.py                   FastAPI app -- 8 endpoints
|           |-- models.py                 Machine, NodeRole, MachineStatus, schemas
|           |-- tpm_verifier.py           EK fingerprint verify (constant-time)
|           |-- enrollment_ca.py          Enrollment CA lifecycle
|           +-- config_generator.py       Role YAML -> machine MachineConfig
|
|-- flavors/                              Role-specific build flavor manifests
|   |-- controlplane.yaml
|   |-- worker-infra.yaml
|   +-- worker-app.yaml
|
|-- scripts/
|   |-- setup-cluster.ps1
|   |-- setup-cluster-baremetal.ps1
|   +-- build-simple.sh
|
+-- build/
    +-- scripts/
```

---

## Component Descriptions

### Extensions (`/extensions/`)

| Extension | GHCR image | Purpose |
|---|---|---|
| `itl-branding` | `itl-talos-branding:vX.Y.Z` | Boot banner, MOTD, login screen |
| `itl-security` | `itl-talos-security:vX.Y.Z` | Kernel module policy, audit rules |
| `itl-tpm-register` | `itl-tpm-register:vX.Y.Z` | TPM EK identity, registration, PCR attestation |

Each extension follows the Talos extension contract: a `manifest.yaml` declares the name, version, and compatibility, and a `Dockerfile` builds a rootfs overlay that is merged into the Talos filesystem.

### Registration Service (`/services/machine-registration/`)

| File | Purpose |
|---|---|
| `main.py` | FastAPI app with 8 API endpoints; bearer token admin auth |
| `models.py` | SQLModel `Machine` table; `NodeRole`, `MachineStatus` enums; all request/response Pydantic schemas |
| `tpm_verifier.py` | EK PEM structural check; SHA-256 fingerprint compute; `hmac.compare_digest` for constant-time comparison |
| `enrollment_ca.py` | RSA 4096 CA lifecycle (`init_enrollment_ca`, `issue_enrollment_cert`, `verify_enrollment_cert`, `verify_nonce_signature`) |
| `config_generator.py` | Loads role base YAML from `ITL_CONFIG_CACHE_DIR`; merges hostname, static IP, node labels, enrollment cert/key |

### Provisioner (`/provisioner/`)

| File | Purpose |
|---|---|
| `docker-compose.yml` | Runs `itl-machine-registration` and `caddy:2-alpine`; mounts `reg-data` volume |
| `Caddyfile` | TLS termination via Let's Encrypt; rate-limit 10 req/min/IP on `/api/v1/machines/enroll` |
| `.env.example` | Template for `ITL_ADMIN_TOKEN`, `ITL_SERVICE_URL`, `ITL_ISO_BASE_URL`, `TALOS_RELEASE_TAG` |
| `usb-agent/build-usb.sh` | Builds Alpine USB image for online provisioning |
| `usb-agent/build-usb-offline.sh` | Embeds pre-baked ISO + enrollment cert/key for air-gapped provisioning |
| `usb-agent/register.sh` | Alpine boot script: TPM read, register call, ISO download, `dd`, reboot |

### Config Patches (`/config/patches/`)

| File | Applied to | Key content |
|---|---|---|
| `security-hardening.yaml` | All roles | LUKS2 dual-key (nodeID + TPM), kernel modules, sysctls, SSH hardening, kubelet CIS args |
| `branding-patch.yaml` | All roles | Boot banner, MOTD |
| `oidc-patch.yaml` | All roles | kube-apiserver OIDC (Keycloak realm `itl`, client `talos-cluster`) |

### Documentation (`/docs/`)

| File | Covers |
|---|---|
| 01-QUICK_REFERENCE.md | Command cheat sheet, ZTP timeline, role-ISO map |
| 02-VISUAL_OVERVIEW.md | Architecture diagrams, pipeline flow |
| 03-BUILD-PIPELINE.md | GitHub Actions pipeline jobs and triggers |
| 04-DEPLOYMENT.md | Quick start, ISO flash, config apply, bootstrap |
| 05-CONTAINER-USAGE.md | Container images, local dev setup |
| 06-PROJECT-STRUCTURE.md | This file |
| 07-ROADMAP.md | Planned features and milestones |
| 08-BAREMETAL-CLUSTER-WALKTHROUGH.md | 3-node bare metal cluster guide |
| 09-REGISTRATION-SERVICE.md | Deploy, configure, API reference |
| 10-TPM-PROVISIONING.md | USB agent, attestation flow, machine lifecycle |
| 11-AIRGAPPED-DEPLOYMENT.md | Enrollment CA, offline bundle, air-gapped USB |
| 12-SECURITY-REFERENCE.md | LUKS2 dual-key, sysctls, SSH, OIDC, kubelet CIS |
| 13-OPERATIONS.md | Daily ops, updates, backup, monitoring, HA patterns |
| 14-TROUBLESHOOTING.md | Build, Registration Service, USB agent, Talos issues |
