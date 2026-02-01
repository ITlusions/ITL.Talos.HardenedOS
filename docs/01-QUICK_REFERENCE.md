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

## See Also

- Visual overview: [02-VISUAL_OVERVIEW.md](02-VISUAL_OVERVIEW.md)
- Setup guide: [03-SIMPLIFIED_SETUP.md](03-SIMPLIFIED_SETUP.md)
- Deployment: [05-QUICKSTART.md](05-QUICKSTART.md)
- Full reference: [04-BUILD_PIPELINE.md](04-BUILD_PIPELINE.md)
