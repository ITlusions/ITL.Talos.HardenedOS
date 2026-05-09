# Developer Handover: ITL.Talos.HardenedOS Network Boot Integration

**Project:** ITL.Talos.HardenedOS Deployment Infrastructure  
**Date:** May 2026  
**Prepared for:** Development Team  
**Prepared by:** ITlusions Infrastructure Team

---

## Executive Summary

This document provides everything a developer needs to implement, deploy, and maintain the ITL.Talos.HardenedOS network boot infrastructure.

**What you're building:**
- Custom hardened Talos Linux distribution (ITL.Talos.HardenedOS)
- Network boot infrastructure for zero-touch deployment
- Integration between GitHub Actions, GHCR, and netboot servers
- Production-ready deployment pipeline

**Time to implement:** 2-3 days for basic setup, 1 week for production-ready

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Step-by-Step Implementation](#step-by-step-implementation)
5. [Testing](#testing)
6. [Deployment](#deployment)
7. [Monitoring & Maintenance](#monitoring--maintenance)
8. [Troubleshooting](#troubleshooting)
9. [Security Considerations](#security-considerations)
10. [Reference](#reference)

---

## Project Overview

### What is ITL.Talos.HardenedOS?

**Talos Linux** is an immutable, minimal Linux distribution built specifically for Kubernetes. It has no shell, no SSH, and is managed entirely via API.

**ITL.Talos.HardenedOS** is your custom Talos distribution with:
- ITlusions branding (boot banners, logos)
- Security hardening (LUKS2, TPM, kernel hardening)
- Custom extensions (branding, security)
- Pre-configured for enterprise compliance

### Business Model

Think **Red Hat for Talos:**
- Upstream Talos = Free, community-supported
- ITL.Talos.HardenedOS = Commercial, ITlusions-supported
- Revenue from support contracts, consulting, managed services

### System Components

```
┌─────────────────────────────────────────────────────┐
│  1. GitHub Repository                               │
│     github.com/ITlusions/ITL.Talos.HardenedOS       │
│                                                     │
│     • Custom builds (GitHub Actions)                │
│     • Branding (ASCII art, logos)                   │
│     • Security configs (LUKS2, TPM, sysctls)        │
│     • CI/CD pipeline (auto-build on tag)            │
└─────────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│  2. Container Registry                              │
│     ghcr.io/itlusions                               │
│                                                     │
│     • itl-talos-hardened-os-installer:v1.0.0        │
│     • itl-talos-hardened-os-branding:v1.0.0         │
│     • itl-talos-hardened-os-security:v1.0.0         │
└─────────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│  3. Network Boot Server                             │
│     netboot.itlusions.local                         │
│                                                     │
│     • nginx (HTTP server for boot files)            │
│     • iPXE menu (profile selection)                 │
│     • Kernel/initramfs (from GHCR)                  │
│     • Configs (from repository)                     │
└─────────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│  4. Target Servers                                  │
│     Customer infrastructure                         │
│                                                     │
│     • PXE boot from network                         │
│     • Load ITL boot menu                            │
│     • Install ITL.Talos.HardenedOS                  │
│     • Join Kubernetes cluster                       │
└─────────────────────────────────────────────────────┘
```

### Data Flow

```
Developer                GitHub Actions       GHCR           Netboot Server      Target Server
    │                         │                 │                   │                  │
    │ git tag v1.0.1          │                 │                   │                  │
    ├─────────────────────────>                 │                   │                  │
    │                         │                 │                   │                  │
    │                         │ Build images    │                   │                  │
    │                         ├─────────────────>                   │                  │
    │                         │                 │                   │                  │
    │                         │ Publish         │                   │                  │
    │                         ├─────────────────>                   │                  │
    │                         │                 │                   │                  │
    │                         │ Sync (auto)     │                   │                  │
    │                         ├─────────────────────────────────────>                  │
    │                         │                 │                   │                  │
    │                         │                 │                   │ PXE boot         │
    │                         │                 │                   <──────────────────│
    │                         │                 │                   │                  │
    │                         │                 │                   │ Download kernel  │
    │                         │                 │                   ├──────────────────>
    │                         │                 │                   │                  │
    │                         │                 │                   │ Download config  │
    │                         │                 │                   ├──────────────────>
    │                         │                 │                   │                  │
    │                         │                 │                   │ Install & boot   │
    │                         │                 │                   │                  │
```

---

## Architecture

### Repository Structure

```
ITL.Talos.HardenedOS/
├── .github/
│   └── workflows/
│       ├── build-talos-hardened.yaml      # Main CI/CD pipeline
│       └── sync-to-netboot.yaml           # Auto-sync to netboot servers
│
├── branding/
│   ├── ascii-art/
│   │   ├── boot-banner.txt                # Boot splash screen
│   │   └── login-banner.txt               # Console banner
│   └── logos/
│       └── itlusions-logo.png
│
├── build/
│   ├── Dockerfile.installer               # Custom installer image
│   ├── Dockerfile.branding                # Branding extension
│   ├── Dockerfile.security                # Security extension
│   └── scripts/
│       ├── build-iso.sh                   # Generate bootable ISO
│       └── generate-configs.sh            # Create machine configs
│
├── config/
│   └── patches/
│       ├── branding-patch.yaml            # Branding configuration
│       ├── security-hardening.yaml        # Security settings
│       └── base-config.yaml               # Base Talos config
│
├── extensions/
│   ├── itl-branding/
│   │   ├── manifest.yaml
│   │   └── rootfs/
│   │       └── etc/
│   │           └── issue.d/
│   │               └── 50-itl-banner.txt
│   └── itl-security/
│       ├── manifest.yaml
│       └── rootfs/
│           └── etc/
│               └── sysctl.d/
│                   └── 99-itl-security.conf
│
├── docs/
│   ├── 01-QUICK_REFERENCE.md
│   ├── 02-VISUAL_OVERVIEW.md
│   └── ...
│
├── scripts/
│   ├── setup-cluster.ps1                  # Windows deployment helper
│   └── setup-cluster-baremetal.ps1
│
├── README.md
└── LICENSE
```

### Network Boot Server Structure

```
/var/www/netboot/
├── boot/
│   ├── menu.ipxe                          # Main boot menu (YOU WILL EDIT THIS)
│   ├── boot.ipxe                          # Initial chain loader
│   ├── undionly.kpxe                      # iPXE for BIOS
│   └── ipxe.efi                           # iPXE for UEFI
│
├── images/
│   └── itl-hardened/
│       ├── itl-talos-v1.9.0.iso           # Full ISO (optional)
│       ├── kernel                         # Extracted kernel
│       └── initramfs.xz                   # Extracted initramfs
│
├── config/
│   └── itl-hardened/
│       ├── controlplane-final.yaml        # Control plane config
│       ├── worker-final.yaml              # Worker config
│       └── auto-config.yaml               # Auto-apply config
│
└── VERSION                                # Current version marker
```

---

## Prerequisites

### Development Environment

**Required:**
- Linux workstation (Ubuntu 22.04+ recommended)
- Git 2.30+
- Docker 20.10+
- Text editor (VS Code recommended)
- SSH access to netboot server

**Optional:**
- QEMU (for local VM testing)
- VirtualBox or VMware (for testing)

### Accounts & Access

**GitHub:**
- Organization: `ITlusions`
- Repository: `ITL.Talos.HardenedOS`
- Permissions: Admin access for repository settings
- Personal Access Token with `write:packages` scope

**GHCR (GitHub Container Registry):**
- Automatically available with GitHub account
- No separate signup needed

**Network Boot Server:**
- Ubuntu 22.04 or 24.04 server
- Root/sudo access
- Static IP address
- Internet access (for downloading dependencies)

### Network Requirements

**Netboot Server:**
- Static IP (e.g., 192.168.1.5)
- Open ports:
  - 80/tcp (HTTP)
  - 443/tcp (HTTPS, optional)
  - 69/udp (TFTP, optional)
  - 67-68/udp (DHCP, optional)

**Target Servers:**
- PXE boot capable
- Network access to netboot server
- Internet access (for downloading from GHCR/factory.talos.dev)

---

## Step-by-Step Implementation

### Phase 1: Set Up GitHub Repository (Day 1, Morning)

#### 1.1 Clone Repository

```bash
# Clone the repository
git clone https://github.com/ITlusions/ITL.Talos.HardenedOS.git
cd ITL.Talos.HardenedOS

# Check current structure
tree -L 2
```

#### 1.2 Configure GitHub Actions

**File:** `.github/workflows/build-talos-hardened.yaml`

**What it does:**
- Triggers on git tag push (e.g., `v1.0.0`)
- Builds custom Talos installer
- Builds branding extension
- Builds security extension
- Publishes to GHCR
- Creates GitHub release with ISO

**No changes needed unless:**
- You want to customize build parameters
- Add additional extensions
- Change Talos version

**To trigger a build:**

```bash
# Tag a release
git tag v1.0.0
git push origin v1.0.0

# Watch build progress
# https://github.com/ITlusions/ITL.Talos.HardenedOS/actions

# Build takes ~45 minutes
```

#### 1.3 Customize Branding (Optional)

**File:** `branding/ascii-art/boot-banner.txt`

```bash
# Edit boot banner
vim branding/ascii-art/boot-banner.txt
```

**Example:**

```
 _____ _______  _           _                 
|_   _|__   __|| |         (_)                
  | |    | |   | |  _   _  _  ___  _ __  ___ 
  | |    | |   | | | | | || |/ _ \| '_ \/ __|
 _| |_   | |   | | | |_| || | (_) | | | \__ \
|_____|  |_|   |_|  \__,_||_|\___/|_| |_|___/
                                              
Enterprise Kubernetes Infrastructure
Hardened • Supported • Production-Ready

Version: ${VERSION}
```

**File:** `config/patches/security-hardening.yaml`

**Review security settings:**

```yaml
machine:
  sysctls:
    kernel.kptr_restrict: "2"                # Hide kernel pointers
    kernel.randomize_va_space: "2"           # ASLR
    kernel.unprivileged_bpf_disabled: "1"    # No unprivileged BPF
    # ... (already configured)
  
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}                            # TPM auto-unlock
      options:
        - cipher=aes-xts-plain64
        - key-size=512
        # ... (already configured)
```

**Commit changes:**

```bash
git add branding/ config/
git commit -m "Customize ITL branding"
git push origin main

# Tag new version
git tag v1.0.1
git push origin v1.0.1
```

#### 1.4 Configure GHCR Access

```bash
# Create GitHub Personal Access Token
# https://github.com/settings/tokens
# Scopes needed: write:packages, read:packages

# Login to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin

# Test pull
docker pull ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
```

---

### Phase 2: Set Up Network Boot Server (Day 1, Afternoon)

#### 2.1 Provision Server

**Option A: Physical Server**
```bash
# Install Ubuntu 22.04 or 24.04
# During install:
# - Use entire disk
# - Install OpenSSH server
# - Set static IP: 192.168.1.5/24
```

**Option B: Virtual Machine**
```bash
# Create VM in Proxmox/VMware/VirtualBox
# - 2 CPU cores
# - 4GB RAM
# - 50GB disk
# - Bridged network
# - Ubuntu 22.04 Server ISO
```

#### 2.2 Install Network Boot Server

**Connect to server:**

```bash
ssh root@192.168.1.5
```

**Download setup script:**

```bash
# Create working directory
mkdir -p ~/itl-setup
cd ~/itl-setup

# Download setup script
curl -L https://raw.githubusercontent.com/your-scripts/setup-netboot-server.sh \
  -o setup-netboot-server.sh

chmod +x setup-netboot-server.sh
```

**Run setup:**

```bash
# Run installation
sudo ./setup-netboot-server.sh

# When prompted, select:
# "1) Web server only (HTTP - simple, works with existing DHCP)"

# Installation takes ~5 minutes
```

**What this does:**
- Installs nginx
- Creates directory structure
- Downloads iPXE bootloaders
- Creates default boot menu
- Configures nginx virtual host
- Starts services

**Verify installation:**

```bash
# Check nginx is running
sudo systemctl status nginx

# Check directory structure
ls -la /var/www/netboot/

# Test in browser (from your workstation)
curl http://192.168.1.5/
```

#### 2.3 Configure Boot Menu

**File:** `/var/www/netboot/boot/menu.ipxe`

**Edit:**

```bash
sudo nano /var/www/netboot/boot/menu.ipxe
```

**Content:**

```ipxe
#!ipxe

:start
clear
echo ╔═══════════════════════════════════════════════════════════╗
echo ║   ITlusions Enterprise Kubernetes Infrastructure          ║
echo ║   Powered by ITL.Talos.HardenedOS                        ║
echo ╚═══════════════════════════════════════════════════════════╝
echo 
echo Server Information:
echo   Manufacturer: ${manufacturer}
echo   Product:      ${product}
echo   MAC Address:  ${net0/mac}
echo   IP Address:   ${net0/ip}
echo 

:menu
menu Select Installation Profile
item --gap ── ITlusions Hardened Profiles ──
item itl-standard     ITL Hardened Standard
item itl-proxmox      ITL Hardened for Proxmox/KVM  
item itl-gpu          ITL Hardened with GPU Support
item itl-storage      ITL Hardened Storage Node
item --gap ── Utilities ──
item shell            iPXE Shell
item reboot           Reboot System
choose --timeout 30000 --default itl-standard selected && goto ${selected}

:itl-standard
set profile ITL Hardened Standard
set config http://192.168.1.5/config/itl-hardened/auto-config.yaml
goto boot_itl

:itl-proxmox
set profile ITL Hardened Proxmox
set config http://192.168.1.5/config/itl-hardened/auto-config.yaml
set extra_args talos.platform=proxmox
goto boot_itl

:itl-gpu
set profile ITL Hardened GPU
set config http://192.168.1.5/config/itl-hardened/auto-config.yaml
goto boot_itl

:itl-storage
set profile ITL Hardened Storage
set config http://192.168.1.5/config/itl-hardened/auto-config.yaml
goto boot_itl

:boot_itl
echo ═══════════════════════════════════════════════════════════
echo Booting: ${profile}
echo Config:  ${config}
echo ═══════════════════════════════════════════════════════════
echo 
echo Downloading kernel...

# Boot using local mirror
kernel http://192.168.1.5/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=${config} \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp \
  ${extra_args}

echo Downloading initramfs...
initrd http://192.168.1.5/images/itl-hardened/initramfs.xz

echo Booting ITL.Talos.HardenedOS...
boot

:shell
shell
goto menu

:reboot
reboot
```

**Save and exit:** Ctrl+X, Y, Enter

---

### Phase 3: Sync Images and Configs (Day 1, Late Afternoon)

#### 3.1 Download Release from GitHub

```bash
# On netboot server

# Create temp directory
mkdir -p ~/itl-download
cd ~/itl-download

# Download latest release ISO
# (Replace v1.0.0 with your actual version)
VERSION="v1.0.0"
curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/download/${VERSION}/itl-talos-v1.9.0.iso \
  -o itl-talos-${VERSION}.iso

# Verify download
ls -lh itl-talos-${VERSION}.iso
# Should be ~150-200 MB
```

#### 3.2 Extract Kernel and Initramfs

```bash
# Mount ISO
sudo mkdir -p /mnt/itl-iso
sudo mount -o loop itl-talos-${VERSION}.iso /mnt/itl-iso

# Verify mount
ls -la /mnt/itl-iso/boot/
# Should show: vmlinuz, initramfs.xz

# Copy to netboot directory
sudo cp /mnt/itl-iso/boot/vmlinuz \
  /var/www/netboot/images/itl-hardened/kernel

sudo cp /mnt/itl-iso/boot/initramfs.xz \
  /var/www/netboot/images/itl-hardened/initramfs.xz

# Unmount ISO
sudo umount /mnt/itl-iso

# Verify
ls -lh /var/www/netboot/images/itl-hardened/
# Should show kernel (~10MB) and initramfs.xz (~50MB)
```

#### 3.3 Download Configurations

```bash
# Download from repository
cd /var/www/netboot/config/itl-hardened

# Control plane config
sudo curl -L https://raw.githubusercontent.com/ITlusions/ITL.Talos.HardenedOS/main/controlplane-final.yaml \
  -o controlplane-final.yaml

# Worker config
sudo curl -L https://raw.githubusercontent.com/ITlusions/ITL.Talos.HardenedOS/main/worker-final.yaml \
  -o worker-final.yaml

# Create auto-config
sudo tee auto-config.yaml > /dev/null <<'EOF'
machine:
  install:
    # Your custom installer from GHCR
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    
  # Your custom extensions
  extensions:
    - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
    - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
  
  # Security hardening
  sysctls:
    kernel.kptr_restrict: "2"
    kernel.randomize_va_space: "2"
    kernel.unprivileged_bpf_disabled: "1"
    kernel.yama.ptrace_scope: "2"
    net.ipv4.conf.all.rp_filter: "1"
    net.ipv4.tcp_syncookies: "1"
  
  # Disk encryption with TPM
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
        - pbkdf-memory=1048576
        - pbkdf-parallel=4
        - pbkdf-iterations=4
    
    ephemeral:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
      options:
        - cipher=aes-xts-plain64
        - key-size=512
        - pbkdf=argon2id
        - pbkdf-memory=1048576
        - pbkdf-parallel=4
        - pbkdf-iterations=4
EOF

# Verify
ls -la /var/www/netboot/config/itl-hardened/
```

#### 3.4 Set Permissions

```bash
# Ensure nginx can read all files
sudo chown -R www-data:www-data /var/www/netboot
sudo chmod -R 755 /var/www/netboot
```

---

### Phase 4: Testing (Day 2, Morning)

#### 4.1 Test Boot Menu in Browser

```bash
# From your workstation
curl http://192.168.1.5/boot/menu.ipxe

# Should show iPXE menu script
# Check for:
# - ITlusions branding
# - Profile options (itl-standard, itl-proxmox, etc.)
# - Correct URLs (http://192.168.1.5/...)
```

#### 4.2 Test File Downloads

```bash
# Test kernel download
curl -I http://192.168.1.5/images/itl-hardened/kernel
# Should return: HTTP/1.1 200 OK

# Test initramfs download
curl -I http://192.168.1.5/images/itl-hardened/initramfs.xz
# Should return: HTTP/1.1 200 OK

# Test config download
curl -I http://192.168.1.5/config/itl-hardened/auto-config.yaml
# Should return: HTTP/1.1 200 OK
```

#### 4.3 Test in VM (QEMU)

**On your workstation:**

```bash
# Install QEMU (if not already installed)
sudo apt install qemu-system-x86

# Create test disk
qemu-img create -f qcow2 test-disk.qcow2 20G

# Boot VM with network boot
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -drive file=test-disk.qcow2,format=qcow2 \
  -netdev user,id=net0,tftp=/var/www/netboot/boot,bootfile=undionly.kpxe \
  -device e1000,netdev=net0 \
  -boot n \
  -nographic

# Or use VNC (better for watching boot)
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -drive file=test-disk.qcow2,format=qcow2 \
  -netdev bridge,id=net0,br=virbr0 \
  -device e1000,netdev=net0 \
  -boot n \
  -vnc :0

# Connect with VNC client to localhost:5900
```

**Expected behavior:**

```
1. VM powers on
2. iPXE loads
3. ITlusions menu appears
4. Select profile (or wait for default)
5. Kernel downloads
6. Initramfs downloads
7. Talos boots
8. Installation begins
9. System reboots
10. ITlusions boot banner shows
11. Talos is ready
```

#### 4.4 Test with Physical Server

**Prerequisites:**
- Physical server with PXE boot capable NIC
- Server on same network as netboot server
- DHCP server configured (see next section)

**Steps:**

```
1. Configure DHCP server (see Phase 5)
2. Power on server
3. Press F12/F11/Del to enter boot menu
4. Select "Network Boot" or "PXE Boot"
5. Wait for ITlusions menu
6. Select profile
7. Installation proceeds
```

---

### Phase 5: DHCP Configuration (Day 2, Afternoon)

#### Option A: Configure Existing DHCP Server

**ISC DHCP Server:**

```bash
# Edit dhcpd.conf
sudo nano /etc/dhcp/dhcpd.conf

# Add PXE boot configuration
subnet 192.168.1.0 netmask 255.255.255.0 {
    range 192.168.1.100 192.168.1.200;
    option routers 192.168.1.1;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    
    # PXE boot settings
    next-server 192.168.1.5;               # Your netboot server
    
    # BIOS clients
    if substring (option vendor-class-identifier, 0, 9) = "PXEClient" {
        filename "undionly.kpxe";
    }
    
    # UEFI clients
    elsif substring (option vendor-class-identifier, 0, 10) = "HTTPClient" {
        filename "ipxe.efi";
    }
}

# Restart DHCP
sudo systemctl restart isc-dhcp-server
```

**dnsmasq:**

```bash
# Edit dnsmasq config
sudo nano /etc/dnsmasq.conf

# Add PXE boot settings
dhcp-boot=undionly.kpxe,192.168.1.5,192.168.1.5
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,ipxe.efi,192.168.1.5,192.168.1.5

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

#### Option B: Built-in DHCP on Netboot Server

**Only use if you don't have existing DHCP!**

```bash
# On netboot server
sudo apt install dnsmasq

# Configure
sudo tee /etc/dnsmasq.d/netboot.conf > /dev/null <<'EOF'
# Disable DNS (only DHCP)
port=0

# DHCP range (ADJUST TO YOUR NETWORK!)
dhcp-range=192.168.1.100,192.168.1.200,12h

# Gateway (ADJUST TO YOUR NETWORK!)
dhcp-option=3,192.168.1.1

# DNS servers
dhcp-option=6,8.8.8.8,1.1.1.1

# PXE boot
dhcp-boot=undionly.kpxe

# UEFI
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,ipxe.efi

# TFTP
enable-tftp
tftp-root=/var/www/netboot/boot

# Logging
log-dhcp
log-facility=/var/log/dnsmasq.log
EOF

# Restart
sudo systemctl restart dnsmasq
```

---

### Phase 6: Automation (Day 2, Late Afternoon)

#### 6.1 Auto-Sync GitHub Actions

**File:** `.github/workflows/sync-to-netboot.yaml`

```yaml
name: Sync to Network Boot Servers

on:
  release:
    types: [published]
  workflow_dispatch:

jobs:
  sync-to-netboot:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Download release assets
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION=$(gh release view --json tagName -q .tagName)
          gh release download $VERSION -p "*.iso"
          
          # Extract kernel and initramfs
          mkdir /tmp/iso
          sudo mount -o loop *.iso /tmp/iso
          cp /tmp/iso/boot/vmlinuz kernel
          cp /tmp/iso/boot/initramfs.xz initramfs.xz
          sudo umount /tmp/iso
      
      - name: Setup SSH
        env:
          SSH_KEY: ${{ secrets.NETBOOT_SSH_KEY }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh-keyscan -H 192.168.1.5 >> ~/.ssh/known_hosts
      
      - name: Sync to netboot server
        run: |
          # Sync kernel and initramfs
          scp kernel initramfs.xz \
            root@192.168.1.5:/var/www/netboot/images/itl-hardened/
          
          # Sync configs
          scp config/*.yaml \
            root@192.168.1.5:/var/www/netboot/config/itl-hardened/
          
          # Update version marker
          VERSION=$(gh release view --json tagName -q .tagName)
          ssh root@192.168.1.5 \
            "echo $VERSION > /var/www/netboot/VERSION"
      
      - name: Notify
        run: |
          echo "✅ Synced to netboot server successfully"
```

**Add SSH key to GitHub Secrets:**

```bash
# On your workstation, generate SSH key for automation
ssh-keygen -t ed25519 -f ~/.ssh/netboot-deploy -N ""

# Copy public key to netboot server
ssh-copy-id -i ~/.ssh/netboot-deploy.pub root@192.168.1.5

# Copy PRIVATE key to GitHub Secrets
# Settings → Secrets → Actions → New repository secret
# Name: NETBOOT_SSH_KEY
# Value: (paste contents of ~/.ssh/netboot-deploy)
cat ~/.ssh/netboot-deploy
```

---

## Testing

### Test Checklist

**Phase 1: Repository**
- [ ] Repository cloned successfully
- [ ] GitHub Actions builds on tag push
- [ ] Images published to GHCR
- [ ] GitHub release created with ISO

**Phase 2: Netboot Server**
- [ ] nginx running
- [ ] Directory structure created
- [ ] iPXE bootloaders present
- [ ] Boot menu accessible via HTTP

**Phase 3: Images & Configs**
- [ ] Kernel downloaded and extracted
- [ ] Initramfs downloaded and extracted
- [ ] Configs downloaded
- [ ] Files have correct permissions

**Phase 4: Network Boot**
- [ ] Boot menu shows in browser
- [ ] Files downloadable via HTTP
- [ ] VM boots from network successfully
- [ ] Physical server boots from network

**Phase 5: DHCP**
- [ ] DHCP provides IP addresses
- [ ] DHCP provides next-server (netboot IP)
- [ ] DHCP provides boot filename

**Phase 6: Installation**
- [ ] Server boots ITlusions menu
- [ ] Profile selection works
- [ ] Kernel downloads
- [ ] Initramfs downloads
- [ ] Config applied
- [ ] Installation completes
- [ ] Server reboots
- [ ] ITlusions banner shows
- [ ] Talos ready for cluster config

### End-to-End Test Script

```bash
#!/bin/bash
# test-e2e.sh - End-to-end test

set -e

echo "Starting E2E test..."

# Test 1: Repository build
echo "Test 1: Triggering build..."
git tag test-v1.0.0-$(date +%s)
git push origin --tags
echo "✓ Build triggered, check GitHub Actions"

# Test 2: Netboot server
echo "Test 2: Testing netboot server..."
curl -sf http://192.168.1.5/boot/menu.ipxe > /dev/null
echo "✓ Boot menu accessible"

# Test 3: File downloads
echo "Test 3: Testing file downloads..."
curl -sf -I http://192.168.1.5/images/itl-hardened/kernel | grep -q "200 OK"
curl -sf -I http://192.168.1.5/images/itl-hardened/initramfs.xz | grep -q "200 OK"
curl -sf -I http://192.168.1.5/config/itl-hardened/auto-config.yaml | grep -q "200 OK"
echo "✓ All files downloadable"

# Test 4: VM boot
echo "Test 4: Testing VM boot..."
echo "Manual step: Boot VM and verify ITlusions menu appears"
echo "Press enter when done..."
read

echo "All tests passed! ✓"
```

---

## Deployment

### Production Deployment Checklist

**Infrastructure:**
- [ ] Netboot server deployed (physical or VM)
- [ ] Static IP configured
- [ ] DNS entry created (netboot.itlusions.local)
- [ ] Firewall rules configured
- [ ] DHCP server configured

**Security:**
- [ ] SSL certificate installed (optional but recommended)
- [ ] Access control configured (restrict /config/ to internal network)
- [ ] Firewall rules (allow only necessary ports)
- [ ] SSH key-based auth only (no password)
- [ ] Regular backups configured

**Monitoring:**
- [ ] nginx access logs monitored
- [ ] Disk space monitoring
- [ ] Uptime monitoring
- [ ] Alert on build failures

**Documentation:**
- [ ] Internal wiki updated
- [ ] Runbooks created
- [ ] Team trained
- [ ] Escalation procedures defined

### Rollout Plan

**Week 1: Test Environment**
```
Day 1-2: Set up netboot server
Day 3-4: Test with VMs
Day 5: Test with 1-2 physical servers
```

**Week 2: Staging Environment**
```
Day 1-2: Deploy to staging netboot server
Day 3-4: Test with staging cluster
Day 5: Performance testing
```

**Week 3: Production Rollout**
```
Day 1: Deploy to production netboot server
Day 2: Configure production DHCP
Day 3: Test with 1 production server
Day 4: Rollout to 10% of fleet
Day 5: Full rollout
```

---

## Monitoring & Maintenance

### Daily Checks

```bash
# Run daily (or set up cron)

# Check netboot server health
ssh root@192.168.1.5 '
  # Check nginx
  systemctl status nginx --no-pager
  
  # Check disk space
  df -h /var/www/netboot
  
  # Check recent boots
  tail -n 50 /var/log/nginx/netboot-access.log | grep kernel
  
  # Count boots today
  grep "$(date +%d/%b/%Y)" /var/log/nginx/netboot-access.log | \
    grep -c "200.*kernel"
'
```

### Weekly Maintenance

```bash
# Weekly tasks

# Check for updates
sudo apt update
sudo apt list --upgradable

# Review logs
sudo tail -n 1000 /var/log/nginx/netboot-access.log | less

# Check GitHub Actions
# https://github.com/ITlusions/ITL.Talos.HardenedOS/actions

# Verify backups
ls -lh /backup/netboot/
```

### Backups

**Automated backup script:**

```bash
#!/bin/bash
# /usr/local/bin/backup-netboot.sh

BACKUP_DIR="/backup/netboot"
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p $BACKUP_DIR

# Backup webroot
tar czf $BACKUP_DIR/netboot-$DATE.tar.gz /var/www/netboot

# Backup nginx config
tar czf $BACKUP_DIR/nginx-$DATE.tar.gz /etc/nginx/sites-available/netboot

# Keep last 30 days
find $BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete

# Optional: Sync to remote
# rsync -avz $BACKUP_DIR/ backup-server:/backups/netboot/
```

**Schedule:**

```bash
# Add to crontab
sudo crontab -e

# Daily at 2 AM
0 2 * * * /usr/local/bin/backup-netboot.sh
```

---

## Troubleshooting

### Common Issues

#### Issue 1: "Build Failed in GitHub Actions"

**Symptoms:**
- GitHub Actions workflow fails
- Red X on commit

**Check:**
```bash
# View logs in GitHub UI
# https://github.com/ITlusions/ITL.Talos.HardenedOS/actions

# Common causes:
# - GHCR authentication failed
# - Docker build timeout
# - Network issues
```

**Fix:**
```bash
# Re-trigger build
git tag v1.0.0 --force
git push origin v1.0.0 --force
```

---

#### Issue 2: "Server Doesn't PXE Boot"

**Symptoms:**
- Server tries to boot from network
- Hangs or shows "PXE-E53: No boot filename received"

**Check:**
```bash
# Verify DHCP is providing boot info
sudo tcpdump -i eth0 port 67 or port 68 -v

# Look for:
# - DHCP Offer
# - next-server: 192.168.1.5
# - filename: undionly.kpxe
```

**Fix:**
```bash
# Check DHCP config
sudo nano /etc/dhcp/dhcpd.conf
# Ensure next-server and filename are set

# Restart DHCP
sudo systemctl restart isc-dhcp-server
```

---

#### Issue 3: "Menu Shows But Kernel Download Fails"

**Symptoms:**
- iPXE menu appears
- Selecting profile shows "Could not download kernel"

**Check:**
```bash
# Test kernel download manually
curl -I http://192.168.1.5/images/itl-hardened/kernel

# Check nginx logs
sudo tail -f /var/log/nginx/netboot-access.log
```

**Fix:**
```bash
# Verify file exists
ls -lh /var/www/netboot/images/itl-hardened/kernel

# Check permissions
sudo chmod 644 /var/www/netboot/images/itl-hardened/kernel
sudo chown www-data:www-data /var/www/netboot/images/itl-hardened/kernel

# Restart nginx
sudo systemctl restart nginx
```

---

#### Issue 4: "Installation Hangs at 'Waiting for TPM'"

**Symptoms:**
- Installation starts
- Hangs at TPM unsealing

**Check:**
```bash
# Is TPM enabled in BIOS?
# - Reboot server
# - Enter BIOS
# - Security → TPM
# - Enable TPM 2.0
```

**Temporary Fix:**
```bash
# Remove TPM requirement from config
# Edit: /var/www/netboot/config/itl-hardened/auto-config.yaml

# Change:
systemDiskEncryption:
  state:
    keys:
      - slot: 0
        static:
          passphrase: "temporary-password"  # Will prompt during install

# To:
# (TPM removed, uses passphrase instead)
```

---

### Debug Mode

**Enable verbose logging:**

```bash
# On netboot server

# Enable nginx debug logging
sudo nano /etc/nginx/nginx.conf

# Change:
error_log /var/log/nginx/error.log;
# To:
error_log /var/log/nginx/error.log debug;

# Restart nginx
sudo systemctl restart nginx

# Watch logs
sudo tail -f /var/log/nginx/error.log
```

**Boot server with debug:**

```ipxe
# In menu.ipxe, add debug flag:
kernel http://192.168.1.5/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=http://192.168.1.5/config/itl-hardened/auto-config.yaml \
  talos.debug=true \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp
```

---

## Security Considerations

### Network Boot Security

**Risks:**
- Unencrypted HTTP (kernel/config in plaintext)
- No authentication (anyone on network can boot)
- MitM attacks possible

**Mitigations:**

**1. Enable HTTPS:**

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d netboot.itlusions.local

# Update menu.ipxe URLs to https://
```

**2. Restrict access:**

```bash
# In /etc/nginx/sites-available/netboot
location /config/ {
    allow 192.168.0.0/16;
    allow 10.0.0.0/8;
    deny all;
}
```

**3. Network segmentation:**

```
Management VLAN (VLAN 10) → Netboot server only
Server VLAN (VLAN 20) → Target servers only
No routing between VLANs except through firewall
```

### Secrets Management

**DO NOT:**
- Store passwords in configs in git
- Commit SSH keys
- Hard-code API tokens

**DO:**
- Use GitHub Secrets for CI/CD tokens
- Use environment variables for passwords
- Use password managers for recovery passphrases

**Example:**

```yaml
# BAD - password in config
systemDiskEncryption:
  state:
    keys:
      - slot: 1
        static:
          passphrase: "MyPassword123"  # DON'T DO THIS!

# GOOD - prompt during install
systemDiskEncryption:
  state:
    keys:
      - slot: 1
        static:
          passphrase: ""  # Empty = prompt during install
```

---

## Reference

### File Locations Quick Reference

**Repository:**
```
github.com/ITlusions/ITL.Talos.HardenedOS
├── .github/workflows/build-talos-hardened.yaml
├── branding/ascii-art/boot-banner.txt
├── config/patches/security-hardening.yaml
└── build/Dockerfile.installer
```

**Netboot Server:**
```
/var/www/netboot/
├── boot/menu.ipxe                         # EDIT THIS for profiles
├── images/itl-hardened/kernel             # From GitHub release
├── images/itl-hardened/initramfs.xz       # From GitHub release
└── config/itl-hardened/auto-config.yaml   # From repository
```

**Logs:**
```
/var/log/nginx/netboot-access.log          # HTTP access logs
/var/log/nginx/netboot-error.log           # HTTP errors
/var/log/dnsmasq.log                       # DHCP logs (if using dnsmasq)
```

### Commands Quick Reference

**Repository:**
```bash
# Tag and release
git tag v1.0.1
git push origin v1.0.1

# Watch build
gh run list --workflow=build-talos-hardened.yaml
```

**Netboot Server:**
```bash
# Check status
systemctl status nginx

# View logs
tail -f /var/log/nginx/netboot-access.log

# Restart services
systemctl restart nginx

# Test downloads
curl http://192.168.1.5/boot/menu.ipxe
```

**Testing:**
```bash
# VM test
qemu-system-x86_64 -m 4096 -boot n

# Manual download test
curl -I http://192.168.1.5/images/itl-hardened/kernel
```

### Port Reference

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| HTTP | 80 | TCP | Boot files, configs |
| HTTPS | 443 | TCP | Secure boot (optional) |
| TFTP | 69 | UDP | iPXE bootloader delivery |
| DHCP | 67-68 | UDP | IP assignment |

### URLs

**GitHub:**
- Repository: https://github.com/ITlusions/ITL.Talos.HardenedOS
- Actions: https://github.com/ITlusions/ITL.Talos.HardenedOS/actions
- Releases: https://github.com/ITlusions/ITL.Talos.HardenedOS/releases

**GHCR:**
- Installer: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
- Branding: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
- Security: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0

**Talos:**
- Official docs: https://www.talos.dev
- Image Factory: https://factory.talos.dev

---

## Next Steps

### Immediate (This Week)

1. **Set up development environment**
   - Clone repository
   - Install dependencies
   - Test local builds

2. **Deploy netboot server**
   - Provision server (VM or physical)
   - Run setup script
   - Test boot menu

3. **First deployment**
   - Boot 1 VM successfully
   - Verify installation works
   - Document any issues

### Short-term (This Month)

1. **Production hardening**
   - Enable HTTPS
   - Configure backups
   - Set up monitoring

2. **Automation**
   - Configure auto-sync
   - Test update procedure
   - Create runbooks

3. **Team training**
   - Demo to team
   - Document procedures
   - Transfer knowledge

### Long-term (This Quarter)

1. **Scale deployment**
   - Deploy to staging
   - Deploy to production
   - Monitor metrics

2. **Continuous improvement**
   - Gather feedback
   - Optimize boot times
   - Add features

3. **Documentation**
   - Customer-facing docs
   - Internal wiki
   - Video tutorials

---

## Support

### Getting Help

**Internal:**
- Team chat: #infrastructure
- Email: infrastructure@itlusions.com

**External:**
- Talos docs: https://www.talos.dev
- Talos Slack: https://slack.dev.talos-systems.io
- GitHub Issues: https://github.com/ITlusions/ITL.Talos.HardenedOS/issues

### Escalation

**Level 1:** Development team (self-service)
**Level 2:** Infrastructure team (this project)
**Level 3:** External Talos experts (for Talos issues)

---

## Appendix

### A. Example Build Log

```
Run: Building ITL.Talos.HardenedOS v1.0.0

[00:00] Checking out repository
[00:02] ✓ Repository checked out

[00:02] Building branding extension
[00:07] ✓ Branding extension built

[00:07] Building security extension
[00:12] ✓ Security extension built

[00:12] Building custom installer
[00:22] ✓ Custom installer built

[00:22] Generating configurations
[00:25] ✓ Configurations generated

[00:25] Building bootable ISO
[00:40] ✓ ISO built

[00:40] Publishing to GHCR
[00:43] ✓ Published to GHCR

[00:43] Creating GitHub release
[00:45] ✓ Release created

[00:45] Build complete! ✓
```

### B. Example Boot Log

```
iPXE 1.21.1+ -- Open Source Network Boot Firmware

net0: 00:0c:29:3a:bc:de using 82545em on 0000:02:01.0 (open)
  [Link:up, TX:0 TXE:0 RX:0 RXE:0]
Configuring (net0 00:0c:29:3a:bc:de)................ ok
net0: 192.168.1.150/255.255.255.0 gw 192.168.1.1
DNS: 8.8.8.8

Booting from: http://192.168.1.5/boot/menu.ipxe

╔═══════════════════════════════════════════════════════════╗
║   ITlusions Enterprise Kubernetes Infrastructure          ║
║   Powered by ITL.Talos.HardenedOS                        ║
╚═══════════════════════════════════════════════════════════╝

Server Information:
  Manufacturer: VMware, Inc.
  Product:      VMware Virtual Platform
  MAC Address:  00:0c:29:3a:bc:de
  IP Address:   192.168.1.150

Select Installation Profile
  ITL Hardened Standard
  ITL Hardened for Proxmox/KVM
  ITL Hardened with GPU Support
  ITL Hardened Storage Node
  iPXE Shell
  Reboot System

═══════════════════════════════════════════════════════════
Booting: ITL Hardened Standard
Config:  http://192.168.1.5/config/itl-hardened/auto-config.yaml
═══════════════════════════════════════════════════════════

Downloading kernel...
http://192.168.1.5/images/itl-hardened/kernel... ok

Downloading initramfs...
http://192.168.1.5/images/itl-hardened/initramfs.xz... ok

Booting ITL.Talos.HardenedOS...

[    0.000000] Linux version 6.1.90-talos-hardened
[    0.000000] Command line: talos.platform=metal console=tty0 ip=dhcp
[    0.523891] Talos 1.9.0 starting
[    1.234567] Installing to /dev/sda
[    5.678901] Encrypting STATE partition (LUKS2 + TPM)
[    7.890123] Encrypting EPHEMERAL partition (LUKS2 + TPM)
[   12.345678] Installation complete
[   13.456789] Rebooting...

[Reboot]

 _____ _______  _           _                 
|_   _|__   __|| |         (_)                
  | |    | |   | |  _   _  _  ___  _ __  ___ 
  | |    | |   | | | | | || |/ _ \| '_ \/ __|
 _| |_   | |   | | | |_| || | (_) | | | \__ \
|_____|  |_|   |_|  \__,_||_|\___/|_| |_|___/

Enterprise Kubernetes Infrastructure
Hardened • Supported • Production-Ready

Version: v1.0.0

[talos] waiting for cluster configuration...
```

---

**Document Version:** 1.0  
**Last Updated:** May 2026  
**Next Review:** November 2026

**Prepared by:** ITlusions Infrastructure Team  
**For questions:** infrastructure@itlusions.com

*This document is confidential and proprietary to ITlusions B.V.*
