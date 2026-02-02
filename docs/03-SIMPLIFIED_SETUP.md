# Simplified Setup

Complete setup for building custom Talos OS.

## What You Have

A focused build pipeline that does one thing well: build custom Talos OS and publish releases.

```
Tag Created (v1.0.0)
        ↓
Pipeline Builds Custom Talos OS
        ↓
Publishes to GitHub Releases
        ↓
Ready to Deploy
```

## The 6-Step Pipeline

**Step 1: Build Branding (5 min)**
- Generates ASCII art banners
- Converts PNG logos to kernel format
- Creates branding assets

**Step 2: Build Extensions (10 min)**
- Builds branding Docker extension
- Builds security Docker extension
- Pushes to GitHub Container Registry

**Step 3: Build Installer (5 min)**
- Creates custom Talos installer image
- Embeds branding assets
- Pushes to registry

**Step 4: Generate Configs (5 min)**
- Generates base Talos configurations
- Applies branding patches
- Applies security hardening
- Validates everything

**Step 5: Build ISO (15 min)**
- Creates bootable ISO image
- Includes all extensions
- Generates SHA256 checksums

**Step 6: Create Release (2 min)**
- Creates GitHub release
- Attaches all artifacts
- Publishes release notes

## How to Use

### Create Your First Release

```bash
cd ITL.Talos.HardenedOS

# Tag your first release
git tag v1.0.0

# Push the tag (this triggers the pipeline)
git push origin v1.0.0

# Pipeline runs automatically
```

### Monitor the Build

1. Go to GitHub: https://github.com/ITlusions/ITL.Talos.HardenedOS
2. Click "Actions" tab
3. Find "Build Custom Talos OS v1.0.0"
4. Watch the 6 jobs complete

### Download When Done

1. Go to "Releases" tab
2. Click v1.0.0
3. Download:
   - itl-talos-v1.9.0.iso (Bootable image)
   - controlplane-final.yaml (Control plane config)
   - worker-final.yaml (Worker config)

### Deploy

**Option A: Boot from ISO**
```bash
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress
# Boot and follow prompts
```

**Option B: Apply to Existing Talos**
```bash
talosctl apply-config --nodes <ip> --file controlplane-final.yaml
```

## What Gets Released

### ISO Image
- Bootable Talos OS
- Custom ITL branding
- All extensions included
- Ready to deploy
- ~500MB size

### Docker Images

Pushed to GitHub Container Registry (GHCR):
- itl-talos-hardened-os-installer:v1.0.0
- itl-talos-hardened-os-branding:v1.0.0
- itl-talos-hardened-os-security:v1.0.0

### Configuration Files

Ready to use:
- controlplane-final.yaml
- worker-final.yaml
- Can be customized for your environment

## Customization (Before Tag)

### Change Branding

Edit config/patches/branding-patch.yaml:

```yaml
- content: |
    Your custom banner here
  path: /etc/issue
```

### Update Security

Edit config/patches/security-hardening.yaml:
- TPM 2.0 settings
- LUKS2 encryption options
- Kernel parameters
- Network policies

### Add Extensions

Edit .github/workflows/build-talos-hardened.yaml:

```yaml
- {"image": "ghcr.io/your-org/your-extension:latest"}
```

### Change Talos Version

Edit .github/workflows/build-talos-hardened.yaml:

```yaml
env:
  TALOS_VERSION: v1.10.0
```

Then: git commit - git tag v1.0.0 - git push origin v1.0.0

## Security Features

**Encryption**
- LUKS2 disk encryption
- TPM 2.0 auto-unlock
- AES-256-XTS cipher

**Hardening**
- Kernel pointer restrictions
- ASLR hardening
- BPF restrictions
- Ptrace scope limits

**Network**
- Reverse path filtering
- SYN cookies
- ICMP filtering
- IPv6 hardening

**Logging**
- Audit logging enabled
- Security event tracking

## Key Files

```
.github/workflows/
└── build-talos-hardened.yaml      The pipeline (500 lines)

build/
├── Dockerfile.installer            Custom installer
└── scripts/
    ├── branding-init.sh            Branding setup
    └── installer-entrypoint.sh     Entry point

config/patches/
├── branding-patch.yaml             Branding config
└── security-hardening.yaml         Security config

extensions/
├── itl-branding/Dockerfile         Branding extension
└── itl-security/Dockerfile         Security extension
```

## Timeline

**First Build**: 45 minutes
- 5 min: branding
- 10 min: extensions
- 5 min: installer
- 5 min: configs
- 15 min: ISO (Image Factory API)
- 2 min: release

**Subsequent Builds**: 20 minutes (with Docker cache)

## Simple Workflow

```
Edit config/patches/
    ↓
git add .
    ↓
git commit "Update branding"
    ↓
git tag v1.0.1
    ↓
git push origin v1.0.1
    ↓
Pipeline automatically builds & publishes
    ↓
Download from Releases tab
```

## Quick Help

**How do I create a release?**
```bash
git tag v1.0.0
git push origin v1.0.0
```

**How long does it take?**
First: 45 min | Later: 20 min

**Where are the artifacts?**
GitHub Releases tab - v1.0.0

**How do I deploy?**
See 05-QUICKSTART.md (5-minute guide)

**Can I customize it?**
Yes. Edit config/patches/ before tagging

## Features

- Builds custom Talos OS
- Adds custom branding
- Includes security hardening
- Publishes to GitHub Releases
- Pushes to Docker Registry
- Generates ready-to-use configs
- Complete in 20-45 minutes
- Fully customizable
- Zero configuration needed

## Next Steps

1. Customize (optional)
   - Edit config/patches/branding-patch.yaml
   - Edit config/patches/security-hardening.yaml

2. Create Release
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. Monitor
   - Watch GitHub Actions

4. Download
   - Get artifacts from Releases tab

5. Deploy
   - Boot from ISO or apply configs

See 05-QUICKSTART.md for detailed deployment steps.

---

You have everything needed to:
- Build a custom Talos Linux OS
- Add your own branding
- Include security hardening
- Publish releases automatically
- Deploy across your infrastructure

Everything is automated. Just create a tag.

**Status**: Ready to Use
**Version**: 1.0.0
