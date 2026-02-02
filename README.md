# ITL.Talos.HardenedOS

Enterprise-grade Talos Linux with ITLusions branding and security hardening. Custom Kubernetes OS with automatic CI/CD pipeline, security hardening, and custom branding.

[![Latest Release](https://img.shields.io/github/v/release/ITlusions/ITL.Talos.HardenedOS?style=for-the-badge&label=Version)](https://github.com/ITlusions/ITL.Talos.HardenedOS/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/ITlusions/ITL.Talos.HardenedOS/build-talos-hardened.yaml?style=for-the-badge&label=Build)](https://github.com/ITlusions/ITL.Talos.HardenedOS/actions)
[![Talos Version](https://img.shields.io/badge/Talos-v1.9.0-blue?style=for-the-badge)](https://www.talos.dev/)
[![License MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)
[![Security Hardened](https://img.shields.io/badge/Security-Hardened-red?style=for-the-badge)](docs/06-DEPLOYMENT.md)
[![Docker Ready](https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge)](docs/07-CONTAINER_USAGE.md)

## Quick Start

```bash
# 1. Create release tag
git tag v1.0.0
git push origin v1.0.0

# 2. Wait 45 minutes (watch GitHub Actions)
# 3. Download from Releases tab
# 4. Deploy
talosctl apply-config --nodes <ip> --file controlplane-final.yaml
```

## Features

**Custom Branding**
- ASCII art banners for SSH/console
- Custom boot logos
- Organization-specific messages

**Security Hardening**
- LUKS2 disk encryption with AES-256-XTS
- TPM 2.0 integration for automatic unlock
- Kernel hardening patches
- Audit logging
- Network security policies

**Extensions**
- gVisor sandbox runtime
- Intel microcode updates
- Custom branding extension
- Custom security extension

**Automated CI/CD**
- GitHub Actions pipeline (triggered on tag)
- Automatic ISO generation
- Docker image builds
- Configuration generation
- Release automation

**Pre-configured**
- Ready-to-use YAML configurations
- Branding patches
- Security hardening patches
- All extensions included

## Documentation

Start here based on your needs:

### Getting Started
- **[01-QUICK_REFERENCE.md](docs/01-QUICK_REFERENCE.md)** (1 min) - Commands only
- **[02-VISUAL_OVERVIEW.md](docs/02-VISUAL_OVERVIEW.md)** (2 min) - Diagrams and flowcharts
- **[03-SIMPLIFIED_SETUP.md](docs/03-SIMPLIFIED_SETUP.md)** (5 min) - Step-by-step walkthrough

### Detailed Documentation
- **[04-BUILD_PIPELINE.md](docs/04-BUILD_PIPELINE.md)** - How the pipeline works
- **[05-QUICKSTART.md](docs/05-QUICKSTART.md)** - 5-minute deployment guide
- **[06-DEPLOYMENT.md](docs/06-DEPLOYMENT.md)** - Detailed deployment instructions
- **[07-CONTAINER_USAGE.md](docs/07-CONTAINER_USAGE.md)** - Running containers on the OS

### Reference
- **[08-CICD_PIPELINE.md](docs/08-CICD_PIPELINE.md)** - Complete pipeline architecture
- **[09-PROJECT_STRUCTURE.md](docs/09-PROJECT_STRUCTURE.md)** - File reference and listing

## What You Get

### ISO Image
- Bootable Talos OS with custom branding
- All extensions included
- Ready to deploy
- ~500MB

### Docker Images
Published to GitHub Container Registry:
```
ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
```

### Configuration Files
- `controlplane-final.yaml` — Control plane configuration
- `worker-final.yaml` — Worker node configuration

## Pipeline

Triggered automatically on tag creation:

```
git tag v1.0.0 && git push origin v1.0.0
    ↓ (5 min)   Build branding
    ↓ (10 min)  Build extensions
    ↓ (5 min)   Build installer
    ↓ (5 min)   Generate configs
    ↓ (15 min)  Build ISO
    ↓ (2 min)   Publish release
    ✅ Done (45 min total)
```

## Customization

Edit before creating release:

| Component | File | What to Change |
|-----------|------|----------------|
| Branding | `config/patches/branding-patch.yaml` | Banner text, messages |
| Security | `config/patches/security-hardening.yaml` | TPM, LUKS2, kernel params |
| Extensions | `.github/workflows/build-talos-hardened.yaml` | Add/remove extensions |
| Talos Version | `.github/workflows/build-talos-hardened.yaml` | Update version |

Then:
```bash
git add .
git commit -m "Update configuration"
git tag v1.0.1
git push origin v1.0.1
```

## Deployment

### Option 1: Boot from ISO
```bash
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M
# Boot and follow prompts
```

### Option 2: Apply Configuration
```bash
talosctl apply-config --nodes <ip> --file controlplane-final.yaml
talosctl apply-config --nodes <ip> --file worker-final.yaml
```

### Option 3: Use Custom Installer
```yaml
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
```

See [05-QUICKSTART.md](docs/05-QUICKSTART.md) for detailed steps.

## Security Features

### Encryption
- LUKS2 with AES-256-XTS cipher
- TPM 2.0 sealing
- Argon2id key derivation

### Hardening
- Kernel pointer restrictions
- ASLR hardening
- BPF restrictions
- Ptrace scope limits
- Filesystem protection

### Network
- Reverse path filtering
- SYN cookies
- ICMP filtering
- IPv6 hardening
- Firewall support

### Logging
- Audit logging enabled
- Security event tracking
- Pod security standards

## Project Structure

```
ITL.Talos.HardenedOS/
├── .github/workflows/           GitHub Actions
│   └── build-talos-hardened.yaml
├── build/                       Docker & scripts
│   ├── Dockerfile.installer
│   └── scripts/
├── config/                      Talos configurations
│   └── patches/
├── extensions/                  Custom extensions
│   ├── itl-branding/
│   └── itl-security/
├── branding/                    Assets (logos, templates)
├── docs/                        All documentation
│   ├── 01-QUICK_REFERENCE.md
│   ├── 02-VISUAL_OVERVIEW.md
│   ├── 03-SIMPLIFIED_SETUP.md
│   ├── 04-BUILD_PIPELINE.md
│   ├── 05-QUICKSTART.md
│   ├── 06-DEPLOYMENT.md
│   ├── 07-CONTAINER_USAGE.md
│   ├── 08-CICD_PIPELINE.md
│   └── 09-PROJECT_STRUCTURE.md
└── README.md                    This file
```

## Troubleshooting

### Build doesn't start
- Check tag format: `v1.0.0` (not `1.0.0`)
- Verify it's a **push** to origin, not just a local tag

### Build times out
- Image Factory API can be slow
- Check GitHub Actions logs
- Retry the workflow

### Configuration won't apply
```bash
# Check node status
talosctl health --nodes <ip>

# View logs
talosctl logs --nodes <ip>

# Reset if needed
talosctl reset --nodes <ip> --graceful=false
```

### Extensions not loading
```bash
# Verify extensions are installed
talosctl get extensions --nodes <ip>

# Check configuration
grep -A5 "extensions:" controlplane-final.yaml
```

## Support

- **Documentation**: See `docs/` folder
- **Issues**: [GitHub Issues](https://github.com/ITlusions/ITL.Talos.HardenedOS/issues)
- **Email**: support@itlusions.com
- **Talos Docs**: https://www.talos.dev/

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

MIT License - See LICENSE file

---

## Getting Help

New to this project? Start with [01-QUICK_REFERENCE.md](docs/01-QUICK_REFERENCE.md)

Prefer diagrams? See [02-VISUAL_OVERVIEW.md](docs/02-VISUAL_OVERVIEW.md)

Want to customize? Read [03-SIMPLIFIED_SETUP.md](docs/03-SIMPLIFIED_SETUP.md)

Need to deploy now? Follow [05-QUICKSTART.md](docs/05-QUICKSTART.md)

Want to run containers? Check [07-CONTAINER_USAGE.md](docs/07-CONTAINER_USAGE.md)

Want all the details? Read [08-CICD_PIPELINE.md](docs/08-CICD_PIPELINE.md)

---

**Status**: Production Ready | **Version**: 1.0.0 | **Talos**: v1.9.0 | **Created**: February 2026
