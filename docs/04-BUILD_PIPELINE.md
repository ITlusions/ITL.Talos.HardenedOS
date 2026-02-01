# Build Pipeline Overview

Automated GitHub Actions pipeline to build custom Talos Linux OS and publish releases.

## What This Does

```
Tag: v1.0.0
  ↓
build-branding (5 min)
  ↓
build-extensions (10 min)
  ↓
build-installer (5 min)
  ↓
generate-configs (5 min)
  ↓
build-iso (15 min)
  ↓
create-release (2 min)
  ↓
GitHub Release Published
```

## Quick Start

### 1. Create a Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

### 2. Watch the Build

Go to GitHub Actions - "Build Custom Talos OS"

### 3. Download Artifacts

Visit Releases - find v1.0.0

Download:
- itl-talos-v1.9.0.iso (Bootable image)
- controlplane-final.yaml (Control plane config)
- worker-final.yaml (Worker config)

## What Gets Built

### ISO Image
- Bootable Talos Linux with custom branding
- Includes all extensions (gVisor, intel-ucode, branding, security)
- 500MB size

### Docker Images
- Installer: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
- Branding: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
- Security: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0

### Configuration Files
- controlplane-final.yaml - Ready-to-use control plane config
- worker-final.yaml - Ready-to-use worker config

### Release Notes
- Features list
- Installation instructions
- Upgrade guide
- Support information

## Pipeline Jobs

### 1. build-branding (5 min)
- Generates ASCII art banners
- Converts logos to kernel format
- Creates branding assets

### 2. build-extensions (10 min)
- Builds branding Docker extension
- Builds security Docker extension
- Pushes to container registry

### 3. build-installer (5 min)
- Creates custom Talos installer image
- Embeds branding assets
- Pushes to container registry

### 4. generate-configs (5 min)
- Generates base Talos configurations
- Applies branding patches
- Applies security hardening patches
- Adds custom extensions
- Validates all configs

### 5. build-iso (15 min)
- Creates bootable ISO using Talos Image Factory
- Includes all extensions
- Generates SHA256 checksums

### 6. create-release (2 min)
- Creates GitHub release
- Attaches all artifacts (ISO, configs, checksums)
- Publishes release notes

## Customization

### Change Branding

Edit config/patches/branding-patch.yaml with your custom banner:

```yaml
- content: |
    Your custom banner here
  path: /etc/issue
```

### Add Extensions

Update generate-configs job in workflow:

```yaml
yq eval '.machine.install.extensions += [
  {"image": "ghcr.io/your-org/your-extension:latest"}
]' -i config/output/controlplane-final.yaml
```

### Change Talos Version

Edit workflow file:

```yaml
env:
  TALOS_VERSION: v1.10.0
```

### Adjust Security Settings

Edit config/patches/security-hardening.yaml:
- TPM 2.0 configuration
- LUKS2 encryption settings
- Kernel hardening parameters
- Network security policies

## Installation Methods

### Method 1: Boot from ISO

```bash
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress
# Boot and follow prompts
```

### Method 2: Apply Configurations

```bash
talosctl apply-config --nodes <ip> --file controlplane-final.yaml
talosctl apply-config --nodes <ip> --file worker-final.yaml
```

### Method 3: Use Custom Installer

```yaml
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
```

## Features Included

**Custom Branding**
- Console banners (SSH/console)
- Boot logos (kernel display)
- Custom messages

**Security**
- LUKS2 encryption
- TPM 2.0 sealing
- Kernel hardening
- Audit logging
- Network security

**Extensions**
- gVisor sandbox runtime
- Intel microcode updates
- Custom branding extension
- Custom security extension

## Project Structure

```
.
├── .github/workflows/
│   └── build-talos-hardened.yaml    Main pipeline
├── build/
│   ├── Dockerfile.installer
│   └── scripts/
│       ├── branding-init.sh
│       └── installer-entrypoint.sh
├── config/
│   └── patches/
│       ├── branding-patch.yaml
│       └── security-hardening.yaml
├── extensions/
│   ├── itl-branding/
│   └── itl-security/
└── branding/
    └── templates/
```

## File Locations

| File | Purpose |
|------|---------|
| .github/workflows/build-talos-hardened.yaml | GitHub Actions workflow |
| build/Dockerfile.installer | Custom installer image |
| config/patches/branding-patch.yaml | Branding configuration |
| config/patches/security-hardening.yaml | Security configuration |
| extensions/itl-branding/Dockerfile | Branding extension |
| extensions/itl-security/Dockerfile | Security extension |

## Troubleshooting

**Build fails in build-branding**
- Check if figlet/toilet installed
- Verify branding directory exists

**Extensions don't build**
- Check Docker authentication
- Verify Dockerfile syntax

**ISO creation fails**
- Image Factory API may be down
- Check network connectivity
- Retry the workflow

**Configuration validation fails**
- Check YAML syntax in patches
- Verify Talos version compatibility
- Review talosctl validate output

## Support

- GitHub Issues: Report problems
- Documentation: See docs/ folder
- Talos Docs: https://www.talos.dev/

---

**Next**: See 05-QUICKSTART.md to deploy or 07-CONTAINER_USAGE.md to run containers.

**Version**: 1.0.0
**Talos**: v1.9.0
