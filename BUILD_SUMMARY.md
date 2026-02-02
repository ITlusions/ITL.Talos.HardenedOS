# ITL Talos HardenedOS - Build Summary

## Build Status: SUCCESS

**Date**: February 1, 2026  
**Build Location**: D:\repos\ITL.Talos.HardenedOS  
**Talos Version**: v1.9.0  

## Artifacts Generated

### 1. Docker Installer Image
- **Name**: `itl-talos-hardened:installer-v1.9.0`
- **Size**: 529 MB (185 MB compressed)
- **Type**: Custom Talos installer with ITL branding and security hardening
- **Status**: Available in local Docker registry

### 2. Bootable ISO Image
- **Name**: `itl-talos-v1.9.0.iso`
- **Path**: `D:\repos\ITL.Talos.HardenedOS\iso-output\itl-talos-v1.9.0.iso`
- **Size**: 91.81 MB
- **Type**: UEFI bootable ISO
- **Contents**: 
  - Talos kernel (vmlinuz)
  - Talos initramfs (initramfs.xz)
  - Rock Ridge and Joliet extensions

## Build Components

### Branding Assets
- Console banner with ITL branding and security details
- Boot logo (PNG format)
- Boot logo in PPM format (kernel compatible)
- Metadata files for branding configuration

### Security Hardening
- LUKS2 encryption support
- TPM integration
- Maximum security level configuration
- Keycloak authentication platform integration

### Installer Entrypoint
- Custom initialization script (`branding-init`)
- Environment information logging
- Readiness checks before deployment

## Build Process

### Step 1: Local Build Script
```powershell
cd D:\repos\ITL.Talos.HardenedOS
powershell -ExecutionPolicy Bypass -File build-local.ps1
```
- Generates branding assets
- Creates Docker image
- Runs branding initialization

### Step 2: ISO Generation
```powershell
cd D:\repos\ITL.Talos.HardenedOS
powershell -ExecutionPolicy Bypass -File build-iso.ps1
```
- Extracts kernel and initramfs
- Generates bootable ISO
- Creates Rock Ridge/Joliet filesystem

## Deployment Options

### Option 1: ISO Deployment
1. Download: `itl-talos-v1.9.0.iso`
2. Create bootable USB/CD
3. Boot target hardware
4. Run Talos installer

### Option 2: Container-based Deployment
1. Use Docker image: `itl-talos-hardened:installer-v1.9.0`
2. Deploy in Kubernetes as sidecar
3. Use talosctl for configuration

### Option 3: PXE Boot
1. Extract kernel and initramfs from ISO
2. Configure PXE server
3. Boot network clients

## Configuration Files

### Docker Image
- **Dockerfile**: `build/Dockerfile.installer`
- **Based on**: `ghcr.io/siderolabs/installer:v1.9.0`
- **Extensions**: Custom branding, security hardening scripts

### Branding Files
- **Console Banner**: `branding/output/console-banner.txt`
- **Boot Logo**: `branding/output/boot-logo.png`
- **Logo PPM**: `branding/output/logo_custom_clut224.ppm`

### Scripts
- **Branding Init**: `build/scripts/branding-init.sh`
- **Installer Entrypoint**: `build/scripts/installer-entrypoint.sh`

## Next Steps

### Testing
```bash
# Boot ISO on test machine
# Or run with QEMU:
qemu-system-x86_64 -cdrom itl-talos-v1.9.0.iso -m 2048 -enable-kvm
```

### Deployment
1. Create Talos machine configuration
2. Run: `talosctl apply-config -n <node-ip> -f machineconfig.yaml`
3. Bootstrap Kubernetes cluster

### Registry Push
```bash
# Tag for registry
docker tag itl-talos-hardened:installer-v1.9.0 <registry>/itl-talos-hardened:v1.9.0

# Push to registry
docker push <registry>/itl-talos-hardened:v1.9.0
```

## Build Tools Used

- **Local**: PowerShell 7.x, Docker Desktop
- **Container**: Ubuntu 24.04, ImageMagick, netpbm, xorriso
- **Talos**: v1.9.0 official installer (ghcr.io/siderolabs/installer)

## System Requirements

### For Building
- Docker Desktop with 2GB+ available disk
- PowerShell 5.1+
- Windows 10/11 or WSL2

### For Deployment
- Hardware with UEFI firmware
- 4GB+ RAM recommended
- 20GB+ storage for cluster

## Troubleshooting

### Issue: ISO not bootable
- Solution: Use UEFI boot mode in BIOS
- Alternative: Use container-based deployment

### Issue: Boot logo not showing
- Solution: This is cosmetic; system will function normally
- Check: Console banner appears at login

### Issue: Branding not visible
- Solution: This is expected on headless/serial console
- View: Check `/etc/issue` on booted system

## Support

- **Talos Documentation**: https://www.talos.dev/
- **ITL Documentation**: Contact ITL team
- **Issues**: Check GitHub repository for Talos

## Build Metadata

- **Build Script**: `build-local.ps1`
- **ISO Script**: `build-iso.ps1`
- **Build Duration**: ~5 minutes (including Docker pulls)
- **Final ISO Size**: 91.81 MB
- **Installer Image Size**: 529 MB

## Verification

To verify the ISO integrity:
```powershell
# Check file exists
Test-Path "D:\repos\ITL.Talos.HardenedOS\iso-output\itl-talos-v1.9.0.iso"

# Get file details
Get-Item "D:\repos\ITL.Talos.HardenedOS\iso-output\itl-talos-v1.9.0.iso" | 
  Select-Object Name, @{N="Size(MB)";E={[math]::Round($_.Length/1MB,2)}}, CreationTime
```

---

**Build completed successfully on February 1, 2026**
