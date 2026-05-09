# ITL.Talos.HardenedOS + Network Boot Integration

## Overview

This guide integrates your **ITL.Talos.HardenedOS** custom Talos build with the network boot infrastructure we created.

Your repo provides:
- ✅ Custom hardened Talos images
- ✅ ITlusions branding
- ✅ Security extensions (LUKS2, TPM, kernel hardening)
- ✅ Automated CI/CD pipeline
- ✅ Custom installer images

We'll integrate this with:
- Network boot server
- Bootstrap USB
- Image Factory approach
- PXE/iPXE deployment

## Architecture Integration

```
┌──────────────────────────────────────────┐
│  ITL.Talos.HardenedOS Repository        │
│  (GitHub Actions)                        │
│                                          │
│  • Builds custom Talos ISO              │
│  • Creates Docker images                │
│  • Generates configurations             │
│  • Publishes to GHCR                    │
└──────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────┐
│  Your Network Boot Server                │
│  (setup-netboot-server.sh)               │
│                                          │
│  • Serves boot menu                      │
│  • References your custom images        │
│  • Applies ITL branding                  │
│  • Deploys hardened configurations      │
└──────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────┐
│  Target Servers                          │
│  • Boot via PXE/USB                      │
│  • Load ITL.Talos.HardenedOS            │
│  • Auto-configure with security          │
└──────────────────────────────────────────┘
```

## Integration Methods

### Method 1: Use Your Custom Installer in Image Factory Menu

Modify the iPXE menu to use your custom installer:

**File: `/var/www/netboot/boot/menu.ipxe`**

```ipxe
#!ipxe

:start
clear
echo ╔═══════════════════════════════════════════════════════════╗
echo ║   ITlusions Talos OS - Hardened Edition                  ║
echo ║   Network Boot Menu                                      ║
echo ╚═══════════════════════════════════════════════════════════╝
echo 

:menu
menu Select Installation Profile
item --gap ── ITlusions Hardened Profiles
item itl-standard   ITL Hardened Standard
item itl-proxmox    ITL Hardened for Proxmox/KVM
item itl-gpu        ITL Hardened with GPU Support
item itl-storage    ITL Hardened Storage Node
item --gap ── Standard Profiles
item vanilla        Vanilla Talos (Upstream)
choose --timeout 30000 --default itl-standard target && goto ${target}

:itl-standard
set name ITL Hardened Standard
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
goto boot_itl

:itl-proxmox
set name ITL Hardened Proxmox
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
set extra_extensions siderolabs/qemu-guest-agent
goto boot_itl

:itl-gpu
set name ITL Hardened GPU
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
set extra_extensions siderolabs/nvidia-container-toolkit
goto boot_itl

:itl-storage
set name ITL Hardened Storage
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
set extra_extensions siderolabs/iscsi-tools
goto boot_itl

:boot_itl
echo Booting ${name}...
echo Installer: ${installer}
echo 
# Use your custom installer with Image Factory kernel/initrd
# This combines your hardening with Image Factory convenience
kernel https://factory.talos.dev/image/YOUR_SCHEMATIC/v1.9.0/kernel-amd64 \
  talos.platform=metal \
  talos.config=http://YOUR_SERVER/config/itl-hardened.yaml \
  console=tty0 console=ttyS0,115200n8 ip=dhcp
initrd https://factory.talos.dev/image/YOUR_SCHEMATIC/v1.9.0/initramfs-amd64.xz
boot

:vanilla
# Standard Talos for comparison
set schematic 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
kernel https://factory.talos.dev/image/${schematic}/v1.9.0/kernel-amd64 \
  talos.platform=metal console=tty0 ip=dhcp
initrd https://factory.talos.dev/image/${schematic}/v1.9.0/initramfs-amd64.xz
boot
```

### Method 2: Host Your Custom ISO on Network Boot Server

Serve your built ISO directly from the web server:

```bash
# After GitHub Actions builds your ISO
cd /var/www/netboot
mkdir -p images/itl-hardened

# Download from GitHub releases
curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/download/v1.0.0/itl-talos-v1.9.0.iso \
  -o images/itl-hardened/itl-talos-v1.9.0.iso

# Extract kernel and initrd from ISO
mkdir -p /tmp/iso-mount
sudo mount -o loop images/itl-hardened/itl-talos-v1.9.0.iso /tmp/iso-mount
cp /tmp/iso-mount/boot/vmlinuz boot/itl-kernel
cp /tmp/iso-mount/boot/initramfs.xz boot/itl-initramfs.xz
sudo umount /tmp/iso-mount
```

**Update iPXE menu:**

```ipxe
:itl-hardened
set name ITL Hardened OS
kernel http://YOUR_SERVER/boot/itl-kernel \
  talos.platform=metal \
  talos.config=http://YOUR_SERVER/config/controlplane-final.yaml \
  console=tty0 ip=dhcp
initrd http://YOUR_SERVER/boot/itl-initramfs.xz
boot
```

### Method 3: Automate Config Delivery

Serve your generated configs from the web server:

```bash
# Set up automatic config sync
cd /var/www/netboot
mkdir -p config/itl-hardened

# Copy configs from your repo
cp ~/ITL.Talos.HardenedOS/controlplane-final.yaml config/itl-hardened/
cp ~/ITL.Talos.HardenedOS/worker-final.yaml config/itl-hardened/

# Create profile-specific configs
cat > config/itl-hardened/auto-config.yaml <<'EOF'
# ITL.Talos.HardenedOS Auto-Configuration
# This gets fetched automatically during boot

machine:
  install:
    # Use your custom installer from GHCR
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    
  # ITL Branding extension
  extensions:
    - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
    - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0

  # Security hardening from your config
  sysctls:
    kernel.kptr_restrict: "2"
    kernel.randomize_va_space: "2"
    kernel.unprivileged_bpf_disabled: "1"
    # ... rest of your hardening

  # LUKS2 encryption
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
      options:
        - cipher=aes-xts-plain64
        - key-size=512
        - pbkdf=argon2id
EOF
```

**Boot with auto-config:**

```ipxe
:itl-auto
kernel http://YOUR_SERVER/boot/kernel \
  talos.platform=metal \
  talos.config=http://YOUR_SERVER/config/itl-hardened/auto-config.yaml \
  console=tty0 ip=dhcp
initrd http://YOUR_SERVER/boot/initramfs
boot
```

## Complete Workflow

### One-Time Setup

1. **Set up network boot server:**
   ```bash
   sudo ./setup-netboot-server.sh
   # Choose option 1 (Web server only)
   ```

2. **Add ITL.Talos.HardenedOS to menu:**
   ```bash
   sudo nano /var/www/netboot/boot/menu.ipxe
   # Add ITL profiles (see Method 1 above)
   ```

3. **Sync your configs:**
   ```bash
   cd /var/www/netboot/config
   git clone https://github.com/ITlusions/ITL.Talos.HardenedOS.git
   ln -s ITL.Talos.HardenedOS/controlplane-final.yaml itl-controlplane.yaml
   ln -s ITL.Talos.HardenedOS/worker-final.yaml itl-worker.yaml
   ```

### Automated Updates

**GitHub Actions workflow to sync to netboot server:**

```yaml
# .github/workflows/sync-to-netboot.yaml
name: Sync to Network Boot Server

on:
  release:
    types: [published]

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Sync configs to netboot server
        env:
          NETBOOT_SERVER: ${{ secrets.NETBOOT_SERVER }}
          SSH_KEY: ${{ secrets.NETBOOT_SSH_KEY }}
        run: |
          # Install SSH key
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          
          # Sync configs
          scp controlplane-final.yaml root@$NETBOOT_SERVER:/var/www/netboot/config/itl-hardened/
          scp worker-final.yaml root@$NETBOOT_SERVER:/var/www/netboot/config/itl-hardened/
          
          # Optional: Sync ISO
          scp itl-talos-*.iso root@$NETBOOT_SERVER:/var/www/netboot/images/itl-hardened/
```

### Daily Operations

**Deploy new server:**

```bash
# 1. Boot server via PXE
# 2. Server shows ITlusions boot menu
# 3. Select "ITL Hardened Standard"
# 4. Server downloads and installs automatically
# 5. Ready for cluster join
```

**Update deployment:**

```bash
# In your ITL.Talos.HardenedOS repo
git tag v1.0.1
git push origin v1.0.1

# GitHub Actions builds new version
# Auto-syncs to netboot server
# Next server boot gets new version
```

## Example: Complete Integration

### Repository Structure

```
Your Infrastructure:

ITL.Talos.HardenedOS/              # Your custom Talos (GitHub)
├── Custom builds
├── Hardening configs
└── CI/CD pipeline

netboot-server/                     # Network boot server
├── /var/www/netboot/
│   ├── boot/
│   │   ├── menu.ipxe              # Points to ITL images
│   │   ├── itl-kernel             # From your ISO
│   │   └── itl-initramfs.xz
│   ├── config/
│   │   └── itl-hardened/
│   │       ├── controlplane-final.yaml  # From your repo
│   │       └── worker-final.yaml
│   └── images/
│       └── itl-hardened/
│           └── itl-talos-v1.9.0.iso     # From your releases
```

### Full Deployment Flow

```
1. Developer tags release in ITL.Talos.HardenedOS
   └─> v1.0.1

2. GitHub Actions pipeline builds
   ├─> Custom ISO
   ├─> Docker images
   └─> Configurations

3. Auto-sync to netboot server
   └─> Updates menu, kernel, configs

4. Field technician arrives at datacenter
   ├─> Plugs in servers
   ├─> Enables PXE boot
   └─> Boots

5. Server boots
   ├─> Loads iPXE from DHCP
   ├─> Fetches ITL boot menu
   ├─> Shows ITlusions branding
   └─> User selects profile

6. Installation
   ├─> Downloads ITL hardened image
   ├─> Applies security config
   ├─> Encrypts disk (LUKS2 + TPM)
   └─> Reboots

7. Server ready
   └─> Shows ITlusions boot banner
   └─> Waiting for cluster config
```

## Security Considerations

### Config Delivery

Your configs contain sensitive data. Protect them:

```nginx
# /etc/nginx/sites-available/netboot
server {
    listen 443 ssl;
    server_name netboot.itlusions.local;
    
    ssl_certificate /etc/ssl/certs/netboot.crt;
    ssl_certificate_key /etc/ssl/private/netboot.key;
    
    root /var/www/netboot;
    
    # Restrict config access to internal network
    location /config/ {
        allow 192.168.0.0/16;
        allow 10.0.0.0/8;
        deny all;
    }
}
```

### Image Verification

Verify images before deployment:

```bash
# Sign your releases
gpg --detach-sign --armor itl-talos-v1.9.0.iso

# Verify on netboot server
gpg --verify itl-talos-v1.9.0.iso.asc itl-talos-v1.9.0.iso
```

## Troubleshooting

### Issue: Server boots vanilla Talos instead of ITL version

**Check:**
```bash
# Verify menu points to your installer
grep "ghcr.io/itlusions" /var/www/netboot/boot/menu.ipxe

# Check server can reach GHCR
curl -I https://ghcr.io/v2/itlusions/itl-talos-hardened-os-installer/manifests/v1.0.0
```

### Issue: Branding not showing

**Check:**
```bash
# Verify branding extension is included
talosctl get extensions --nodes <ip>

# Should show:
# ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
```

### Issue: Security features not applied

**Check:**
```bash
# Verify security config was applied
talosctl get machineconfig --nodes <ip> -o yaml | grep -A10 sysctls

# Check LUKS2
talosctl get systemdiskencryption --nodes <ip>
```

## Next Steps

1. **Test deployment:**
   ```bash
   # Boot one server with ITL profile
   # Verify branding shows
   # Check security features enabled
   # Confirm encrypted disk
   ```

2. **Scale to production:**
   ```bash
   # Update DHCP to point to your netboot server
   # Deploy to all new servers
   # Monitor via centralized logging
   ```

3. **Integrate with Omni/Sidero:**
   ```bash
   # Use ITL.Talos.HardenedOS as base image
   # Manage fleet via Sidero Metal
   # Zero-touch provisioning at scale
   ```

---

**Your ITL.Talos.HardenedOS is now fully integrated with modern network boot!** 🎉

This gives you:
- Custom hardened Talos with ITlusions branding
- Network boot from PXE/USB
- Auto-deployment with security features
- GitOps workflow (tag → build → deploy)
- Production-ready at scale
