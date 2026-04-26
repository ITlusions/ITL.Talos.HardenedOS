# Quick Reference

## Build & Publish Custom Talos OS in 3 Commands

```bash
# 1. Create release tag
git tag v1.0.0

# 2. Push to GitHub
git push origin v1.0.0

# 3. Wait 45 minutes, then download from Releases tab
```

## What You Get

GitHub Release v1.0.0:
- itl-talos-v1.9.0.iso (Bootable OS image, ~500MB)
- itl-talos-v1.9.0.iso.sha256 (Verify integrity)
- controlplane-final.yaml (Control plane config)
- worker-final.yaml (Worker config)
- Release notes (Features & instructions)

## Pipeline Timeline

```
Tag Created (v1.0.0)
  5 min   - Build branding assets
  10 min  - Build Docker extensions
  5 min   - Build custom installer
  5 min   - Generate Talos configs
  15 min  - Create bootable ISO
  2 min   - Publish GitHub release
  Total: 45 minutes (20 min with cache)
```

## Deployment Options

**Option 1: From ISO**
```bash
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M
```

**Option 2: Apply config**
```bash
talosctl apply-config --nodes <ip> --file controlplane-final.yaml
```

**Option 3: Use installer**
```yaml
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
```

## Customize Before Releasing

| Component | File | Edit |
|-----------|------|------|
| Branding | `config/patches/branding-patch.yaml` | Banner text, messages |
| Security | `config/patches/security-hardening.yaml` | TPM, LUKS2, kernel params |
| Extensions | `.github/workflows/build-talos-hardened.yaml` | Add/remove extensions |
| Talos Version | `.github/workflows/build-talos-hardened.yaml` | Update TALOS_VERSION |

## Monitor Build

Visit GitHub Actions Tab: "Build Custom Talos OS"

Shows all 6 jobs:
- build-branding
- build-extensions
- build-installer
- generate-configs
- build-iso
- create-release

## Download Artifacts

Visit Releases Tab, download:
- ISO for boot
- YAML configs
- Everything has checksums for verification

## Included Features

- Custom branding (console banners, logos)
- LUKS2 encryption + TPM 2.0
- Kernel hardening
- Network security
- Audit logging
- gVisor sandbox
- Intel microcode

## Quick Troubleshooting

| Problem | Fix |
|---------|-----|
| Build doesn't start | Check tag format: v1.0.0 (not 1.0.0) |
| Build times out | Retry - Image Factory API can be slow |
| ISO missing | Wait longer - 15 min step can be slow |

---

## Zero-Touch Provisioning (ZTP)

### Start Registration Service
```bash
cd provisioner
cp .env.example .env   # set ITL_ADMIN_TOKEN, ITL_SERVICE_URL
docker compose up -d
docker compose exec registration /bin/sh -c "/app/scripts/download-configs.sh v1.9.0"
```

### Pre-register a node (before hardware arrives)
```bash
curl -X POST https://reg.itlusions.com/api/v1/machines/import \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"ek_fingerprint":"<64hex>","role":"controlplane","hostname":"cp1.itlusions.internal"}'
```

### Build USB provisioning agent
```bash
cd provisioner/usb-agent
./build-usb.sh /dev/sdX               # online
./build-usb-offline.sh /dev/sdX       # airgapped
```

### Check node status
```bash
curl -s https://reg.itlusions.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | jq '.[] | {hostname,role,status}'
```

### Approve a pending node
```bash
curl -X POST https://reg.itlusions.com/api/v1/machines/{machine_id}/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role":"worker-app","hostname":"w1.itlusions.internal"}'
```

### ZTP timeline (per node)

```
USB boot          30 sec   — TPM read + register call
ISO download       5 min   — role-specific ISO (~500 MB)
dd to disk         2 min   — write ISO
Talos first boot   2 min   — fetch config, apply patches, reboot
TPM attestation   30 sec   — PCR quote verified
──────────────────────────
Total             ~10 min  — zero operator input after USB insert
```

### Role → ISO mapping

| Role | ISO filename |
|------|-------------|
| `controlplane` | `itl-talos-controlplane-amd64.iso` |
| `worker-infra` | `itl-talos-worker-infra-amd64.iso` |
| `worker-app`   | `itl-talos-worker-app-amd64.iso`   |
| Config invalid | Check YAML syntax, verify Talos version |

## Verify Deployment

```bash
# SSH and see branding
ssh -i ~/.talos/id_rsa talos@<node-ip>

# Check encryption
talosctl get volumes --nodes <node-ip>

# Check extensions
talosctl get extensions --nodes <node-ip>

# Check Kubernetes
kubectl get nodes -o wide
```

## Version Naming

- v1.0.0 = Release
- v1.0.1 = Patch
- v2.0.0 = Major update
- v1.1.0-rc.1 = Release candidate
- v1.1.0-beta = Beta version

## TalosOps Agent

AI assistant for deploying and customising ITL Talos HardenedOS:

```bash
cd agents
cp .env.example .env          # add OPENAI_API_KEY
pip install -r requirements.txt
python talos_agent.py
```

One-shot mode:
```bash
python talos_agent.py --question "Generate a 3-node config for 192.168.1.100"
```

## See Also

- Visual overview: [02-VISUAL_OVERVIEW.md](02-VISUAL_OVERVIEW.md)
- Build pipeline: [03-BUILD-PIPELINE.md](03-BUILD-PIPELINE.md)
- Deployment: [04-DEPLOYMENT.md](04-DEPLOYMENT.md)
- Container usage: [05-CONTAINER-USAGE.md](05-CONTAINER-USAGE.md)
- **Bare metal cluster walkthrough (1 CP + 2 workers)**: [08-BAREMETAL-CLUSTER-WALKTHROUGH.md](08-BAREMETAL-CLUSTER-WALKTHROUGH.md)
