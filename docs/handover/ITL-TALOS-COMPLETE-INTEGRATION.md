# ITL.Talos.HardenedOS Complete Integration Guide

**Enterprise Kubernetes Infrastructure by ITlusions**

Version: 1.0  
Last Updated: May 2026  
Author: ITlusions Infrastructure Team

---

## Table of Contents

1. [Executive Overview](#executive-overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Quick Start (30 Minutes)](#quick-start-30-minutes)
5. [Detailed Setup](#detailed-setup)
6. [Integration Methods](#integration-methods)
7. [Production Deployment](#production-deployment)
8. [Automation & CI/CD](#automation--cicd)
9. [Security Configuration](#security-configuration)
10. [Operations & Maintenance](#operations--maintenance)
11. [Troubleshooting](#troubleshooting)
12. [Advanced Scenarios](#advanced-scenarios)
13. [Reference](#reference)

---

## Executive Overview

### What This Integration Provides

ITL.Talos.HardenedOS is ITlusions' enterprise-grade hardened Talos Linux distribution, combining:

- **Custom Hardened OS**: Security-hardened Talos with LUKS2 encryption, TPM integration, and kernel hardening
- **ITlusions Branding**: Custom boot banners, logos, and organizational identity
- **Automated Deployment**: Network boot infrastructure for zero-touch provisioning
- **Pre-configured Security**: Enterprise-ready configurations with compliance in mind

This guide integrates three components:

```
┌────────────────────────────────────────────────────────────┐
│  1. ITL.Talos.HardenedOS Repository                        │
│     • Custom Talos builds via GitHub Actions               │
│     • Security hardening & extensions                      │
│     • ITlusions branding                                   │
└────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────┐
│  2. Network Boot Infrastructure                            │
│     • HTTP/TFTP servers                                    │
│     • iPXE boot menu with profiles                         │
│     • Configuration delivery                               │
└────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────┐
│  3. Target Infrastructure                                  │
│     • Bare metal servers                                   │
│     • Virtual machines (Proxmox, VMware, etc.)             │
│     • Cloud instances                                      │
└────────────────────────────────────────────────────────────┘
```

### Value Proposition

**For Customers:**
- Zero-touch deployment of hardened Kubernetes infrastructure
- Enterprise security by default (LUKS2, TPM, kernel hardening)
- Professional support from ITlusions
- Compliance-ready configurations (SOC2, ISO27001)

**For ITlusions:**
- Differentiated product vs vanilla Talos
- Recurring revenue through support contracts
- Scalable deployment infrastructure
- Brand building as "The Enterprise Talos Company"

---

## Architecture

### Complete System Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    DEVELOPMENT LAYER                             │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  GitHub Repository: ITL.Talos.HardenedOS               │    │
│  │                                                        │    │
│  │  Developer tags release → v1.0.x                       │    │
│  │         ↓                                              │    │
│  │  GitHub Actions Pipeline (45 min):                    │    │
│  │  ├── Build custom Talos kernel                        │    │
│  │  ├── Add ITlusions branding extension                 │    │
│  │  ├── Add security hardening extension                 │    │
│  │  ├── Build installer image                            │    │
│  │  ├── Generate ISO                                     │    │
│  │  ├── Create configurations                            │    │
│  │  └── Publish to ghcr.io/itlusions                     │    │
│  └────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────────┐
│                  DISTRIBUTION LAYER                              │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Container Registry: ghcr.io/itlusions                 │    │
│  │                                                        │    │
│  │  Published Images:                                     │    │
│  │  • itl-talos-hardened-os-installer:v1.0.0             │    │
│  │  • itl-talos-hardened-os-branding:v1.0.0              │    │
│  │  • itl-talos-hardened-os-security:v1.0.0              │    │
│  └────────────────────────────────────────────────────────┘    │
│                            ↓                                    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Network Boot Server (netboot.itlusions.local)         │    │
│  │                                                        │    │
│  │  Services:                                             │    │
│  │  ├── HTTP (nginx) - Port 80/443                       │    │
│  │  │   └── Serves: Boot menu, configs, images           │    │
│  │  ├── TFTP (optional) - Port 69                        │    │
│  │  │   └── Serves: iPXE bootloaders                     │    │
│  │  └── DHCP (optional) - Port 67/68                     │    │
│  │      └── Serves: IP assignment, boot params           │    │
│  │                                                        │    │
│  │  Content:                                              │    │
│  │  /var/www/netboot/                                    │    │
│  │  ├── boot/                                            │    │
│  │  │   ├── menu.ipxe (ITL profiles)                    │    │
│  │  │   ├── undionly.kpxe (BIOS)                        │    │
│  │  │   └── ipxe.efi (UEFI)                             │    │
│  │  ├── images/                                          │    │
│  │  │   └── itl-hardened/                               │    │
│  │  │       ├── itl-talos-v1.9.0.iso                    │    │
│  │  │       ├── kernel                                   │    │
│  │  │       └── initramfs.xz                            │    │
│  │  └── config/                                          │    │
│  │      └── itl-hardened/                               │    │
│  │          ├── controlplane-final.yaml                 │    │
│  │          ├── worker-final.yaml                       │    │
│  │          └── auto-config.yaml                        │    │
│  └────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────────┐
│                   DEPLOYMENT LAYER                               │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Target Servers                                        │    │
│  │                                                        │    │
│  │  Boot Sequence:                                        │    │
│  │  1. Power on / PXE boot                               │    │
│  │  2. DHCP → Gets IP + boot server address              │    │
│  │  3. TFTP → Downloads iPXE bootloader                  │    │
│  │  4. HTTP → Fetches ITL boot menu                      │    │
│  │  5. User selects profile                              │    │
│  │  6. HTTP → Downloads kernel + initramfs               │    │
│  │  7. HTTP → Fetches ITL hardened config                │    │
│  │  8. Boots ITL.Talos.HardenedOS                        │    │
│  │  9. Installs to disk with:                            │    │
│  │     • LUKS2 encryption (AES-256-XTS)                  │    │
│  │     • TPM 2.0 unsealing                               │    │
│  │     • Kernel hardening                                │    │
│  │     • ITlusions branding                              │    │
│  │ 10. Reboots → Shows ITL boot banner                   │    │
│  │ 11. Ready for cluster configuration                   │    │
│  └────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Developer              GitHub Actions         GHCR              Netboot Server         Target Server
   │                         │                  │                      │                      │
   │ git tag v1.0.1         │                  │                      │                      │
   ├────────────────────────>                  │                      │                      │
   │                         │                  │                      │                      │
   │                         │ Build images     │                      │                      │
   │                         ├──────────────────>                      │                      │
   │                         │                  │                      │                      │
   │                         │ Publish          │                      │                      │
   │                         ├──────────────────>                      │                      │
   │                         │                  │                      │                      │
   │                         │                  │ Sync images/configs  │                      │
   │                         │                  ├──────────────────────>                      │
   │                         │                  │                      │                      │
   │                         │                  │                      │ PXE boot             │
   │                         │                  │                      <──────────────────────│
   │                         │                  │                      │                      │
   │                         │                  │                      │ Serve menu           │
   │                         │                  │                      ├──────────────────────>
   │                         │                  │                      │                      │
   │                         │                  │                      │ Download kernel      │
   │                         │                  │                      ├──────────────────────>
   │                         │                  │                      │                      │
   │                         │                  │                      │ Download config      │
   │                         │                  │                      ├──────────────────────>
   │                         │                  │                      │                      │
   │                         │                  │                      │ Install & boot       │
   │                         │                  │                      │                      │
```

---

## Prerequisites

### Development Environment

**Required Software:**
- Git 2.x+
- Docker 20.x+ (for local testing)
- Text editor (VS Code recommended)

**GitHub Repository Access:**
- Fork or clone `ITL.Talos.HardenedOS`
- GitHub Actions enabled
- GHCR access configured

### Network Boot Server

**Hardware Requirements:**
- CPU: 2 cores minimum
- RAM: 4GB minimum
- Disk: 50GB minimum (for images and configs)
- Network: 1Gbps NIC

**Software Requirements:**
- Ubuntu 22.04/24.04 or Debian 12 (recommended)
- nginx or Apache
- Optional: dnsmasq (for DHCP/TFTP)
- Optional: Docker (for containerized approach)

**Network Requirements:**
- Static IP address
- Access to target server subnet
- Firewall ports open:
  - 80/tcp (HTTP)
  - 443/tcp (HTTPS, optional)
  - 69/udp (TFTP, optional)
  - 67-68/udp (DHCP, optional)

### Target Servers

**Hardware Requirements:**
- CPU: 4 cores minimum (8+ recommended for production)
- RAM: 8GB minimum (16GB+ recommended)
- Disk: 100GB minimum
- Network: PXE boot capable NIC
- Optional: TPM 2.0 chip (for automatic disk unlock)

**BIOS/UEFI Settings:**
- PXE/Network boot enabled
- Secure Boot disabled (or configure Talos shim)
- Boot order: Network first

### Network Infrastructure

**DHCP Server:**
- Existing DHCP or use built-in dnsmasq
- Must support PXE boot options (next-server, filename)

**DNS (Recommended):**
- Internal DNS for netboot.itlusions.local
- Or use IP addresses

**Firewall:**
- Allow traffic between netboot server and target servers
- No filtering on DHCP/TFTP/HTTP

---

## Quick Start (30 Minutes)

### Step 1: Set Up GitHub Repository (5 minutes)

```bash
# Clone the repository
git clone https://github.com/ITlusions/ITL.Talos.HardenedOS.git
cd ITL.Talos.HardenedOS

# Review configuration
cat config/patches/branding-patch.yaml
cat config/patches/security-hardening.yaml

# Optional: Customize branding
vim config/patches/branding-patch.yaml

# Commit and tag
git add .
git commit -m "Initial ITL.Talos.HardenedOS setup"
git tag v1.0.0
git push origin main
git push origin v1.0.0

# GitHub Actions will start building (watch in GitHub Actions tab)
# This takes ~45 minutes
```

### Step 2: Set Up Network Boot Server (10 minutes)

```bash
# On your netboot server (Ubuntu/Debian)

# Download setup script
curl -LO https://raw.githubusercontent.com/your-repo/setup-netboot-server.sh
chmod +x setup-netboot-server.sh

# Run setup (choose option 1: Web server only)
sudo ./setup-netboot-server.sh

# When prompted, choose:
# 1) Web server only (HTTP - simple, works with existing DHCP)

# Script completes and shows:
# ✓ Network Boot Server Ready!
# IP Address: 192.168.1.5
# Boot Menu: http://192.168.1.5/boot/menu.ipxe
```

### Step 3: Configure ITL Profiles in Menu (5 minutes)

```bash
# Edit the boot menu
sudo nano /var/www/netboot/boot/menu.ipxe
```

Add ITL profiles:

```ipxe
#!ipxe

:start
clear
echo ╔═══════════════════════════════════════════════════════════╗
echo ║   ITlusions Enterprise Kubernetes Infrastructure          ║
echo ║   Powered by ITL.Talos.HardenedOS                        ║
echo ╚═══════════════════════════════════════════════════════════╝
echo 
echo Detected: ${manufacturer} ${product}
echo MAC: ${net0/mac}
echo IP:  ${net0/ip}
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
choose --timeout 30000 --default itl-standard target && goto ${target}

:itl-standard
set profile ITL Hardened Standard
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
goto boot_itl

:itl-proxmox
set profile ITL Hardened Proxmox
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
set extra_args talos.board=proxmox
goto boot_itl

:itl-gpu
set profile ITL Hardened GPU
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
goto boot_itl

:itl-storage
set profile ITL Hardened Storage
set installer ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
goto boot_itl

:boot_itl
echo ═══════════════════════════════════════════════════════════
echo Booting: ${profile}
echo Installer: ${installer}
echo ═══════════════════════════════════════════════════════════
echo 
# NOTE: Replace YOUR_SCHEMATIC_ID with actual ID from Image Factory
# Or use kernel/initramfs from your built ISO
kernel http://192.168.1.5/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=http://192.168.1.5/config/itl-hardened/auto-config.yaml \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp \
  ${extra_args}
initrd http://192.168.1.5/images/itl-hardened/initramfs.xz
boot

:shell
shell
goto menu

:reboot
reboot
```

Save and exit.

### Step 4: Sync ITL Images (5 minutes)

Wait for GitHub Actions to complete, then:

```bash
# Create directories
sudo mkdir -p /var/www/netboot/images/itl-hardened
sudo mkdir -p /var/www/netboot/config/itl-hardened

# Download latest release ISO
cd /var/www/netboot/images/itl-hardened
sudo curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/download/v1.0.0/itl-talos-v1.9.0.iso \
  -o itl-talos-v1.9.0.iso

# Extract kernel and initramfs
mkdir /tmp/iso
sudo mount -o loop itl-talos-v1.9.0.iso /tmp/iso
sudo cp /tmp/iso/boot/vmlinuz kernel
sudo cp /tmp/iso/boot/initramfs.xz initramfs.xz
sudo umount /tmp/iso

# Copy configurations
cd /var/www/netboot/config/itl-hardened
sudo curl -L https://raw.githubusercontent.com/ITlusions/ITL.Talos.HardenedOS/main/controlplane-final.yaml \
  -o controlplane-final.yaml
sudo curl -L https://raw.githubusercontent.com/ITlusions/ITL.Talos.HardenedOS/main/worker-final.yaml \
  -o worker-final.yaml

# Create auto-config
sudo tee auto-config.yaml > /dev/null <<'EOF'
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    
  extensions:
    - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
    - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
  
  sysctls:
    kernel.kptr_restrict: "2"
    kernel.randomize_va_space: "2"
    kernel.unprivileged_bpf_disabled: "1"
  
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

### Step 5: Test Boot (5 minutes)

```bash
# Option A: Test in VM
qemu-system-x86_64 -boot n -m 4096 -smp 2

# Option B: Boot real server
# 1. Enable PXE boot in BIOS
# 2. Boot server
# 3. Watch for ITlusions menu
# 4. Select "ITL Hardened Standard"
# 5. Installation proceeds automatically

# Option C: Test menu in browser
curl http://192.168.1.5/boot/menu.ipxe
```

**You should see:**
1. ITlusions branded boot menu
2. Profile selection
3. Automatic download and installation
4. Reboot showing ITL boot banner

---

## Detailed Setup

### GitHub Repository Configuration

#### Repository Structure

```
ITL.Talos.HardenedOS/
├── .github/
│   └── workflows/
│       └── build-talos-hardened.yaml        # Main CI/CD pipeline
├── branding/
│   ├── ascii-art/
│   │   ├── boot-banner.txt                  # Boot splash
│   │   └── login-banner.txt                 # Console banner
│   ├── logos/
│   │   └── itlusions-logo.png               # Custom logo
│   └── templates/
│       └── motd.template                     # Message of the day
├── build/
│   ├── Dockerfile.installer                  # Installer image
│   ├── Dockerfile.branding                   # Branding extension
│   ├── Dockerfile.security                   # Security extension
│   └── scripts/
│       ├── build-iso.sh                      # ISO generation
│       └── generate-configs.sh               # Config generation
├── config/
│   └── patches/
│       ├── branding-patch.yaml               # Branding config
│       ├── security-hardening.yaml           # Security config
│       └── base-config.yaml                  # Base Talos config
├── extensions/
│   ├── itl-branding/
│   │   ├── manifest.yaml
│   │   └── rootfs/
│   └── itl-security/
│       ├── manifest.yaml
│       └── rootfs/
├── docs/
│   ├── 01-QUICK_REFERENCE.md
│   ├── 02-VISUAL_OVERVIEW.md
│   └── ...
├── scripts/
│   ├── setup-cluster.ps1                     # Windows deployment
│   ├── setup-cluster-baremetal.ps1           # Bare metal
│   └── build-simple.sh                       # Quick build
├── README.md
└── LICENSE
```

#### Customizing Branding

**Edit boot banner:**

```bash
vim branding/ascii-art/boot-banner.txt
```

```
 _____ _______                 _                 
|_   _|__   __|               (_)                
  | |    | | __ _  ___  ___   _  ___  _ __  ___ 
  | |    | |/ _` |/ _ \/ __| | |/ _ \| '_ \/ __|
 _| |_   | | (_| | (_) \__ \ | | (_) | | | \__ \
|_____|  |_|\__,_|\___/|___/ |_|\___/|_| |_|___/
                                                  
Enterprise Kubernetes Infrastructure
Hardened • Supported • Production-Ready
```

**Customize security settings:**

```bash
vim config/patches/security-hardening.yaml
```

```yaml
machine:
  sysctls:
    # Kernel hardening
    kernel.kptr_restrict: "2"                    # Hide kernel pointers
    kernel.randomize_va_space: "2"               # ASLR
    kernel.unprivileged_bpf_disabled: "1"        # Disable BPF for non-root
    kernel.yama.ptrace_scope: "2"                # Restrict ptrace
    
    # Network hardening
    net.ipv4.conf.all.rp_filter: "1"            # Reverse path filtering
    net.ipv4.conf.all.log_martians: "1"         # Log spoofed packets
    net.ipv4.conf.all.send_redirects: "0"       # Disable ICMP redirects
    net.ipv4.conf.all.accept_redirects: "0"
    net.ipv4.tcp_syncookies: "1"                # SYN flood protection
    
    # IPv6 hardening
    net.ipv6.conf.all.disable_ipv6: "0"         # Keep IPv6 enabled
    net.ipv6.conf.all.accept_redirects: "0"
    net.ipv6.conf.all.accept_source_route: "0"
  
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}                                # TPM 2.0 auto-unlock
      options:
        - cipher=aes-xts-plain64                # AES-256 encryption
        - key-size=512                          # 512-bit key
        - pbkdf=argon2id                        # Argon2id KDF
        - pbkdf-memory=1048576                  # 1GB memory for KDF
        - pbkdf-parallel=4
        - pbkdf-iterations=4
  
  features:
    rbac: true                                   # RBAC enabled
    stableHostname: true
    apidCheckExtKeyUsage: true
    diskQuotaSupport: true
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:admin
      allowedKubernetesNamespaces:
        - kube-system
```

**Commit changes:**

```bash
git add branding/ config/
git commit -m "Customize ITL branding and security"
git push origin main
```

#### Triggering Builds

**Manual trigger:**

```bash
# Tag a new version
git tag v1.0.1
git push origin v1.0.1

# Watch build progress
# https://github.com/ITlusions/ITL.Talos.HardenedOS/actions
```

**Automatic trigger via GitHub UI:**

1. Go to repository → Releases
2. Click "Draft a new release"
3. Create tag: `v1.0.1`
4. Fill in release notes
5. Publish release
6. GitHub Actions starts automatically

**Build timeline:**

```
0:00  - Checkout code
0:02  - Build branding extension        (5 min)
0:07  - Build security extension        (5 min)
0:12  - Build custom installer          (10 min)
0:22  - Generate configurations         (3 min)
0:25  - Build bootable ISO              (15 min)
0:40  - Publish to GHCR                 (3 min)
0:43  - Create GitHub release           (2 min)
0:45  - Complete ✓
```

### Network Boot Server Setup

#### Installation Methods

**Method 1: Scripted Setup (Recommended)**

```bash
# Download setup script
curl -LO https://raw.githubusercontent.com/your-scripts/setup-netboot-server.sh
chmod +x setup-netboot-server.sh

# Run with defaults
sudo ./setup-netboot-server.sh

# Or customize
sudo WEBROOT=/srv/netboot LISTEN_IP=10.0.0.5 ./setup-netboot-server.sh
```

**Method 2: Manual Setup**

```bash
# Install nginx
sudo apt update
sudo apt install -y nginx

# Create directory structure
sudo mkdir -p /var/www/netboot/{boot,images,config}
sudo mkdir -p /var/www/netboot/images/itl-hardened
sudo mkdir -p /var/www/netboot/config/itl-hardened

# Download iPXE bootloaders
cd /var/www/netboot/boot
sudo curl -LO https://boot.ipxe.org/undionly.kpxe
sudo curl -LO https://boot.ipxe.org/ipxe.efi

# Create nginx config
sudo tee /etc/nginx/sites-available/netboot > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    
    server_name netboot netboot.itlusions.local;
    root /var/www/netboot;
    
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    location ~* \.(ipxe|kpxe|efi)$ {
        add_header Content-Type text/plain;
    }
    
    # CORS for iPXE
    add_header Access-Control-Allow-Origin *;
    
    access_log /var/log/nginx/netboot-access.log;
    error_log /var/log/nginx/netboot-error.log;
}
EOF

# Enable site
sudo ln -s /etc/nginx/sites-available/netboot /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

**Method 3: Docker Container**

```bash
# Create docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3'
services:
  netboot:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./netboot:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    restart: unless-stopped
EOF

# Create nginx config
cat > nginx.conf <<'EOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    autoindex on;
    
    location ~* \.(ipxe|kpxe|efi)$ {
        add_header Content-Type text/plain;
    }
}
EOF

# Start
docker-compose up -d
```

#### DHCP Configuration

**If using existing DHCP server (recommended):**

Add to your DHCP server configuration:

```
# ISC DHCP
subnet 192.168.1.0 netmask 255.255.255.0 {
    range 192.168.1.100 192.168.1.200;
    option routers 192.168.1.1;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    
    # PXE boot settings
    next-server 192.168.1.5;              # Your netboot server
    
    # BIOS clients
    if substring (option vendor-class-identifier, 0, 9) = "PXEClient" {
        filename "undionly.kpxe";
    }
    
    # UEFI clients
    elsif substring (option vendor-class-identifier, 0, 10) = "HTTPClient" {
        filename "ipxe.efi";
    }
}
```

**If using dnsmasq (built-in DHCP):**

```bash
# Install dnsmasq
sudo apt install -y dnsmasq

# Configure
sudo tee /etc/dnsmasq.d/netboot.conf > /dev/null <<'EOF'
# Disable DNS (only DHCP)
port=0

# DHCP range
dhcp-range=192.168.1.100,192.168.1.200,12h

# Gateway
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

#### Testing Network Boot Server

```bash
# Test HTTP access
curl http://192.168.1.5/

# Test menu
curl http://192.168.1.5/boot/menu.ipxe

# Test TFTP (if enabled)
tftp 192.168.1.5 -c get undionly.kpxe

# Test in browser
firefox http://192.168.1.5/
```

---

## Integration Methods

### Method 1: Direct ISO Hosting

**Best for:** Simple deployments, testing, maximum control

**How it works:**
- Host your built ISO on the netboot server
- Extract kernel/initramfs for network boot
- Serve configurations alongside

**Setup:**

```bash
# Download ISO from GitHub release
cd /var/www/netboot/images/itl-hardened
sudo curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download/itl-talos-v1.9.0.iso \
  -o itl-talos-latest.iso

# Extract boot files
mkdir /tmp/itl-mount
sudo mount -o loop itl-talos-latest.iso /tmp/itl-mount

# Copy kernel and initramfs
sudo cp /tmp/itl-mount/boot/vmlinuz ./kernel
sudo cp /tmp/itl-mount/boot/initramfs.xz ./initramfs.xz

# Unmount
sudo umount /tmp/itl-mount
rmdir /tmp/itl-mount

# Verify
ls -lh kernel initramfs.xz
```

**iPXE menu entry:**

```ipxe
:itl-direct
echo Loading ITL.Talos.HardenedOS from local mirror...
kernel http://192.168.1.5/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=http://192.168.1.5/config/itl-hardened/controlplane-final.yaml \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp
initrd http://192.168.1.5/images/itl-hardened/initramfs.xz
boot
```

**Pros:**
- ✅ Full control over images
- ✅ Works offline (after initial download)
- ✅ Fast boot (local network)
- ✅ No external dependencies

**Cons:**
- ❌ Manual updates required
- ❌ Larger storage footprint
- ❌ Must sync each release

---

### Method 2: Hybrid (Image Factory + Custom Installer)

**Best for:** Production deployments, automatic updates

**How it works:**
- Use Image Factory kernel/initramfs (always latest)
- Reference your custom installer from GHCR
- Combine convenience with customization

**Setup:**

```bash
# Generate schematic ID for your extensions
# (This is a one-time step)

# Create schematic request
cat > schematic.json <<'EOF'
{
  "customization": {
    "systemExtensions": {
      "officialExtensions": [
        "siderolabs/qemu-guest-agent",
        "siderolabs/intel-ucode"
      ]
    }
  }
}
EOF

# Post to Image Factory
SCHEMATIC_ID=$(curl -sS -X POST https://factory.talos.dev/schematics \
  -H "Content-Type: application/json" \
  -d @schematic.json | jq -r '.id')

echo "Schematic ID: $SCHEMATIC_ID"
# Save this ID for your menu
```

**iPXE menu entry:**

```ipxe
:itl-hybrid
set schematic YOUR_SCHEMATIC_ID_FROM_ABOVE
echo Loading ITL.Talos.HardenedOS (Hybrid Mode)...
echo Schematic: ${schematic}
echo 

# Kernel/initramfs from Image Factory (always latest)
kernel https://factory.talos.dev/image/${schematic}/v1.9.0/kernel-amd64 \
  talos.platform=metal \
  talos.config=http://192.168.1.5/config/itl-hardened/auto-config.yaml \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp
initrd https://factory.talos.dev/image/${schematic}/v1.9.0/initramfs-amd64.xz
boot
```

**auto-config.yaml:**

```yaml
machine:
  install:
    # Use YOUR custom installer from GHCR
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
  
  # Include YOUR extensions
  extensions:
    - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
    - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
  
  # YOUR security hardening
  sysctls:
    kernel.kptr_restrict: "2"
    kernel.randomize_va_space: "2"
    # ... rest of your security settings
  
  # YOUR disk encryption
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
      options:
        - cipher=aes-xts-plain64
        - key-size=512
```

**Pros:**
- ✅ Always latest Talos kernel (from Factory)
- ✅ Your custom branding/security (from GHCR)
- ✅ Best of both worlds
- ✅ Automatic Talos updates

**Cons:**
- ❌ Requires internet access
- ❌ Depends on factory.talos.dev uptime
- ❌ Slightly more complex

---

### Method 3: Fully Custom (Air-Gapped)

**Best for:** Air-gapped environments, maximum security

**How it works:**
- Everything hosted locally
- No external dependencies
- Complete control

**Setup:**

```bash
# Build custom kernel/initramfs locally
# (This is advanced - typically done in your build pipeline)

cd ~/ITL.Talos.HardenedOS

# Build using imager
docker run --rm -v $PWD:/out \
  ghcr.io/siderolabs/imager:v1.9.0 \
  --arch amd64 \
  --platform metal \
  --output-kind kernel \
  --output /out/vmlinuz

docker run --rm -v $PWD:/out \
  ghcr.io/siderolabs/imager:v1.9.0 \
  --arch amd64 \
  --platform metal \
  --output-kind initramfs \
  --output /out/initramfs.xz

# Copy to netboot server
scp vmlinuz initramfs.xz netboot-server:/var/www/netboot/images/itl-hardened/

# Also copy your installer image
docker save ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 | \
  ssh netboot-server "docker load"
```

**iPXE menu (air-gapped):**

```ipxe
:itl-airgapped
echo Loading ITL.Talos.HardenedOS (Air-Gapped Mode)...
kernel http://192.168.1.5/images/itl-hardened/vmlinuz \
  talos.platform=metal \
  talos.config=http://192.168.1.5/config/itl-hardened/controlplane-final.yaml \
  installer.image=192.168.1.5:5000/itl-talos-hardened-os-installer:v1.0.0 \
  console=tty0 console=ttyS0,115200n8 \
  ip=dhcp
initrd http://192.168.1.5/images/itl-hardened/initramfs.xz
boot
```

**Pros:**
- ✅ Works completely offline
- ✅ No external dependencies
- ✅ Maximum control
- ✅ Compliance-friendly

**Cons:**
- ❌ More complex setup
- ❌ Manual update process
- ❌ Larger infrastructure footprint

---

## Production Deployment

### Architecture Patterns

#### Pattern 1: Single Netboot Server (Small Deployments)

```
┌─────────────────────────────────────────┐
│  Internet                               │
│  ├── github.com/ITlusions               │
│  └── ghcr.io/itlusions                  │
└─────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│  Netboot Server (192.168.1.5)           │
│  ├── nginx (HTTP)                       │
│  ├── dnsmasq (DHCP/TFTP)                │
│  └── Images/Configs                     │
└─────────────────────────────────────────┘
              │
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐
│ Server │ │ Server │ │ Server │
│   1    │ │   2    │ │   3    │
└────────┘ └────────┘ └────────┘
```

**Use when:**
- < 50 servers
- Single datacenter
- Simple network topology

---

#### Pattern 2: HA Netboot Servers (Medium Deployments)

```
┌─────────────────────────────────────────┐
│  Load Balancer / VIP                    │
│  netboot.itlusions.local                │
│  192.168.1.10                           │
└─────────────────────────────────────────┘
         │                │
    ┌────┴────┐      ┌────┴────┐
    ▼         ▼      ▼         ▼
┌─────────┐ ┌─────────┐ ┌─────────┐
│Netboot 1│ │Netboot 2│ │Netboot 3│
│.1.5     │ │.1.6     │ │.1.7     │
└─────────┘ └─────────┘ └─────────┘
         │         │         │
    ┌────┴────┬────┴────┬────┴────┐
    ▼         ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐ ...
│Server 1│ │Server 2│ │Server 3│
└────────┘ └────────┘ └────────┘
```

**Setup:**

```bash
# Install keepalived for VIP
sudo apt install -y keepalived

# Configure VIP (on all netboot servers)
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<'EOF'
vrrp_instance VI_1 {
    state MASTER              # MASTER on primary, BACKUP on others
    interface eth0
    virtual_router_id 51
    priority 100              # 100 on primary, 90/80 on others
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass secret123
    }
    
    virtual_ipaddress {
        192.168.1.10/24
    }
}
EOF

# Start keepalived
sudo systemctl enable --now keepalived

# Sync content between servers
# Option A: rsync (simple)
rsync -avz /var/www/netboot/ netboot2:/var/www/netboot/

# Option B: GlusterFS (automatic)
# Option C: NFS shared storage
```

**Use when:**
- 50-500 servers
- Requires high availability
- Cannot tolerate downtime

---

#### Pattern 3: Multi-Site (Large Deployments)

```
┌────────────────────────────────────────────────────────┐
│  Central Management                                    │
│  ├── GitHub: ITL.Talos.HardenedOS                     │
│  ├── GHCR: Container images                           │
│  └── Automation: Config sync                          │
└────────────────────────────────────────────────────────┘
         │                │                │
    ┌────┴───┐       ┌────┴───┐      ┌────┴───┐
    ▼        ▼       ▼        ▼      ▼        ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ Site A       │ │ Site B       │ │ Site C       │
│ Amsterdam    │ │ London       │ │ Frankfurt    │
│              │ │              │ │              │
│ Netboot HA   │ │ Netboot HA   │ │ Netboot HA   │
│ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │
│ │ Servers  │ │ │ │ Servers  │ │ │ │ Servers  │ │
│ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │
└──────────────┘ └──────────────┘ └──────────────┘
```

**Setup:**

```bash
# Central sync script (runs on CI/CD or cron)
#!/bin/bash

SITES=("amsterdam" "london" "frankfurt")
VERSION="v1.0.0"

for site in "${SITES[@]}"; do
    echo "Syncing to $site..."
    
    # Sync configs
    rsync -avz \
        /builds/ITL.Talos.HardenedOS/config/ \
        netboot-${site}:/var/www/netboot/config/itl-hardened/
    
    # Sync images
    rsync -avz \
        /builds/ITL.Talos.HardenedOS/images/ \
        netboot-${site}:/var/www/netboot/images/itl-hardened/
    
    # Update version marker
    ssh netboot-${site} \
        "echo $VERSION > /var/www/netboot/VERSION"
done
```

**Use when:**
- 500+ servers
- Multiple geographic locations
- Regional compliance requirements

---

### Zero-Touch Provisioning (ZTP)

**Complete automated deployment flow:**

```
1. Server powers on
   ↓
2. DHCP provides:
   • IP address
   • Netboot server address
   • Boot filename
   ↓
3. TFTP loads iPXE
   ↓
4. iPXE chains to HTTP menu
   ↓
5. Menu auto-selects based on:
   • MAC address
   • IP subnet
   • Hardware detection
   ↓
6. Downloads ITL.Talos.HardenedOS
   ↓
7. Applies configuration:
   • From HTTP server
   • Or embedded in image
   ↓
8. Installs to disk with:
   • LUKS2 encryption
   • TPM unsealing
   • Security hardening
   ↓
9. Reboots
   ↓
10. Joins cluster automatically
    ↓
11. Ready for workloads
```

**Implementation:**

**Step 1: MAC-based auto-selection**

```ipxe
#!ipxe

# Auto-detect based on MAC address
iseq ${net0/mac} 00:11:22:33:44:55 && set profile controlplane || set profile worker
iseq ${net0/mac} 00:11:22:33:44:56 && set profile controlplane ||
iseq ${net0/mac} 00:11:22:33:44:57 && set profile controlplane ||

# Load profile-specific config
set config http://192.168.1.5/config/itl-hardened/${profile}-final.yaml

echo Auto-detected profile: ${profile}
echo Config: ${config}

# Boot
kernel http://192.168.1.5/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=${config} \
  console=tty0 ip=dhcp
initrd http://192.168.1.5/images/itl-hardened/initramfs.xz
boot
```

**Step 2: Subnet-based auto-selection**

```ipxe
# Detect subnet
iseq ${net0/ip:network} 192.168.10.0 && set site amsterdam ||
iseq ${net0/ip:network} 192.168.20.0 && set site london ||
iseq ${net0/ip:network} 192.168.30.0 && set site frankfurt ||

# Site-specific configuration
set config http://192.168.1.5/config/itl-hardened/${site}-config.yaml
```

**Step 3: Hardware-based auto-selection**

```ipxe
# GPU servers
isset ${pci/vendor:1} && set profile gpu ||

# Virtual machines
iseq ${manufacturer} QEMU && set profile proxmox ||

# Default
set profile standard
```

**Step 4: Database-driven (advanced)**

```ipxe
# Query external API for configuration
chain http://provisioning-api.itlusions.local/boot?mac=${net0/mac}
```

---

### Security Configuration

#### SSL/TLS for Netboot Server

```bash
# Install certbot
sudo apt install -y certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d netboot.itlusions.local

# Auto-renewal
sudo systemctl enable --now certbot.timer

# Update nginx config
sudo tee /etc/nginx/sites-available/netboot > /dev/null <<'EOF'
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    server_name netboot.itlusions.local;
    
    ssl_certificate /etc/letsencrypt/live/netboot.itlusions.local/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/netboot.itlusions.local/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    root /var/www/netboot;
    autoindex on;
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name netboot.itlusions.local;
    return 301 https://$server_name$request_uri;
}
EOF

sudo nginx -t && sudo systemctl reload nginx
```

#### Access Control

```nginx
# Restrict config access to internal network
location /config/ {
    allow 192.168.0.0/16;
    allow 10.0.0.0/8;
    deny all;
}

# Require authentication for sensitive areas
location /admin/ {
    auth_basic "ITlusions Netboot Admin";
    auth_basic_user_file /etc/nginx/.htpasswd;
}
```

#### Image Verification

```bash
# Sign your releases
cd /var/www/netboot/images/itl-hardened

# Create GPG key (one-time)
gpg --gen-key

# Sign ISO
gpg --detach-sign --armor itl-talos-v1.9.0.iso

# Verify before deployment
gpg --verify itl-talos-v1.9.0.iso.asc itl-talos-v1.9.0.iso
```

#### Audit Logging

```nginx
# Enhanced logging
log_format detailed '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    '$request_time $upstream_response_time';

access_log /var/log/nginx/netboot-detailed.log detailed;
```

```bash
# Monitor boots
tail -f /var/log/nginx/netboot-access.log | grep -E 'kernel|initramfs'

# Count deployments
awk '/kernel/ {print $1}' /var/log/nginx/netboot-access.log | sort -u | wc -l
```

---

## Automation & CI/CD

### GitHub Actions Auto-Sync

Add to your ITL.Talos.HardenedOS repository:

**.github/workflows/sync-to-netboot.yaml:**

```yaml
name: Sync to Network Boot Servers

on:
  release:
    types: [published]
  workflow_dispatch:

jobs:
  sync-to-netboot:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        site: [amsterdam, london, frankfurt]
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Download release assets
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          # Get latest release
          VERSION=$(gh release view --json tagName -q .tagName)
          
          # Download ISO
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
          ssh-keyscan -H netboot-${{ matrix.site }}.itlusions.local >> ~/.ssh/known_hosts
      
      - name: Sync images to ${{ matrix.site }}
        run: |
          # Sync kernel and initramfs
          scp kernel initramfs.xz \
            netboot-${{ matrix.site }}:/var/www/netboot/images/itl-hardened/
          
          # Sync ISO (optional)
          scp *.iso \
            netboot-${{ matrix.site }}:/var/www/netboot/images/itl-hardened/
      
      - name: Sync configs to ${{ matrix.site }}
        run: |
          scp config/controlplane-final.yaml config/worker-final.yaml \
            netboot-${{ matrix.site }}:/var/www/netboot/config/itl-hardened/
      
      - name: Update version marker
        run: |
          VERSION=$(gh release view --json tagName -q .tagName)
          ssh netboot-${{ matrix.site }} \
            "echo $VERSION > /var/www/netboot/VERSION"
      
      - name: Notify
        if: success()
        run: |
          echo "✅ Synced $VERSION to ${{ matrix.site }}"
```

### Automated Testing

**Test deployment before production:**

```yaml
name: Test Deployment

on:
  pull_request:
    branches: [main]

jobs:
  test-vm-deployment:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Build test image
        run: ./build-simple.sh
      
      - name: Start test VM
        run: |
          # Use QEMU to test boot
          qemu-system-x86_64 \
            -m 4096 \
            -smp 2 \
            -drive file=test-disk.img,format=raw \
            -cdrom output/itl-talos-test.iso \
            -boot d \
            -nographic \
            -serial mon:stdio &
          
          # Wait for boot
          sleep 120
          
          # Check if Talos is running
          # (add your validation here)
      
      - name: Validate branding
        run: |
          # Check if ITlusions branding is present
          # (inspect logs, screenshots, etc.)
          echo "Branding validation placeholder"
      
      - name: Validate security
        run: |
          # Check LUKS2, TPM, kernel params
          echo "Security validation placeholder"
```

### Monitoring & Alerting

```bash
# Install Prometheus node exporter on netboot server
sudo apt install -y prometheus-node-exporter

# Monitor boot requests
cat > /etc/prometheus/netboot-metrics.sh <<'EOF'
#!/bin/bash
# Count boots in last hour
BOOTS=$(awk -v d=$(date -d '1 hour ago' +%s) \
  '{if($4 > d) print}' /var/log/nginx/netboot-access.log | \
  grep -c 'kernel')

echo "netboot_boots_last_hour $BOOTS"
EOF

chmod +x /etc/prometheus/netboot-metrics.sh
```

---

## Operations & Maintenance

### Daily Operations

**Check netboot server status:**

```bash
# Service health
sudo systemctl status nginx
sudo systemctl status dnsmasq  # if using

# Disk space
df -h /var/www/netboot

# Recent boots
tail -n 50 /var/log/nginx/netboot-access.log

# Active deployments
journalctl -u nginx -f | grep -E 'kernel|initramfs'
```

**Monitor deployment metrics:**

```bash
# Count successful boots today
grep "$(date +%d/%b/%Y)" /var/log/nginx/netboot-access.log | \
  grep -c '200.*kernel'

# List unique IPs that booted
awk '/kernel/ {print $1}' /var/log/nginx/netboot-access.log | \
  sort -u

# Most popular profile
grep 'GET.*menu.ipxe' /var/log/nginx/netboot-access.log | \
  awk '{print $7}' | sort | uniq -c | sort -rn
```

### Update Procedures

**Update ITL.Talos.HardenedOS:**

```bash
# In your repository
cd ~/ITL.Talos.HardenedOS

# Make changes
vim config/patches/security-hardening.yaml

# Commit
git add .
git commit -m "Update security hardening"

# Tag new version
git tag v1.0.2
git push origin main v1.0.2

# GitHub Actions builds automatically
# Wait 45 minutes

# Verify release
gh release list

# Auto-sync will update netboot servers
# Or manually sync (see CI/CD section)
```

**Update netboot server software:**

```bash
# Update packages
sudo apt update
sudo apt upgrade -y nginx dnsmasq

# Test configuration
sudo nginx -t
sudo dnsmasq --test

# Reload services
sudo systemctl reload nginx
sudo systemctl restart dnsmasq
```

**Rollback procedure:**

```bash
# List versions
ls -la /var/www/netboot/images/itl-hardened/

# Rollback to previous version
cd /var/www/netboot/images/itl-hardened
sudo mv kernel kernel.v1.0.2
sudo mv kernel.v1.0.1 kernel
sudo mv initramfs.xz initramfs.v1.0.2
sudo mv initramfs.v1.0.1 initramfs.xz

# Update version marker
echo "v1.0.1" | sudo tee /var/www/netboot/VERSION

# No restart needed - takes effect immediately
```

### Backup & Disaster Recovery

**Backup strategy:**

```bash
# Automated backup script
cat > /usr/local/bin/backup-netboot.sh <<'EOF'
#!/bin/bash

BACKUP_DIR="/backup/netboot"
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p $BACKUP_DIR

# Backup content
tar czf $BACKUP_DIR/netboot-$DATE.tar.gz \
  /var/www/netboot \
  /etc/nginx/sites-available/netboot \
  /etc/dnsmasq.d/

# Backup database (if using for ZTP)
# mysqldump provisioning > $BACKUP_DIR/provisioning-$DATE.sql

# Keep last 30 days
find $BACKUP_DIR -name "netboot-*.tar.gz" -mtime +30 -delete

# Sync to remote
rsync -avz $BACKUP_DIR/ backup-server:/backups/netboot/
EOF

chmod +x /usr/local/bin/backup-netboot.sh

# Schedule daily
sudo crontab -e
# Add: 0 2 * * * /usr/local/bin/backup-netboot.sh
```

**Restore procedure:**

```bash
# Restore from backup
cd /backup/netboot
tar xzf netboot-20260509-020000.tar.gz -C /

# Restore nginx config
sudo cp backup/etc/nginx/sites-available/netboot /etc/nginx/sites-available/
sudo nginx -t && sudo systemctl reload nginx

# Restore dnsmasq
sudo cp backup/etc/dnsmasq.d/* /etc/dnsmasq.d/
sudo systemctl restart dnsmasq

# Verify
curl http://localhost/boot/menu.ipxe
```

**Disaster recovery:**

```bash
# Rebuild netboot server from scratch
# 1. Fresh Ubuntu install
sudo apt update && sudo apt install -y nginx

# 2. Restore from backup
rsync -avz backup-server:/backups/netboot/latest/ /var/www/netboot/

# 3. Restore configs
rsync -avz backup-server:/backups/netboot/configs/ /etc/

# 4. Reload services
sudo systemctl reload nginx

# 5. Test
curl http://localhost/boot/menu.ipxe
```

---

## Troubleshooting

### Common Issues

#### Issue: Server boots vanilla Talos instead of ITL version

**Symptoms:**
- Boot banner shows "Talos" not "ITlusions"
- Security features not applied
- No custom branding

**Diagnosis:**

```bash
# Check what installer was used
talosctl --nodes <ip> get machineconfig -o yaml | grep image

# Should show:
# image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Check extensions
talosctl --nodes <ip> get extensions

# Should include:
# ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
# ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
```

**Solutions:**

```bash
# Verify menu points to ITL installer
curl http://192.168.1.5/boot/menu.ipxe | grep installer

# Should contain:
# ghcr.io/itlusions/itl-talos-hardened-os-installer

# If not, fix menu
sudo nano /var/www/netboot/boot/menu.ipxe

# Verify GHCR access
docker pull ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Re-deploy server
talosctl reset --nodes <ip> --graceful=false
# Boot again from PXE
```

---

#### Issue: PXE boot fails / No network boot

**Symptoms:**
- Server doesn't PXE boot
- "PXE-E53: No boot filename received"
- "PXE-M0F: Exiting PXE ROM"

**Diagnosis:**

```bash
# Check DHCP server
sudo systemctl status dnsmasq  # or your DHCP server

# Monitor DHCP requests
sudo tcpdump -i eth0 port 67 or port 68

# Check TFTP
tftp 192.168.1.5 -c get undionly.kpxe

# Check nginx
curl http://192.168.1.5/boot/undionly.kpxe
```

**Solutions:**

```bash
# Verify DHCP configuration
cat /etc/dnsmasq.d/netboot.conf | grep -E 'dhcp-boot|next-server'

# Should have:
# next-server 192.168.1.5
# dhcp-boot=undionly.kpxe

# Restart DHCP
sudo systemctl restart dnsmasq

# Check firewall
sudo ufw allow 67/udp
sudo ufw allow 68/udp
sudo ufw allow 69/udp
sudo ufw allow 80/tcp

# Test from another machine
tftp 192.168.1.5
> get undionly.kpxe
```

---

#### Issue: Menu loads but kernel download fails

**Symptoms:**
- iPXE menu shows
- Selecting profile fails with "Could not download kernel"

**Diagnosis:**

```bash
# Check if kernel exists
ls -lh /var/www/netboot/images/itl-hardened/kernel

# Check nginx access log
sudo tail -f /var/log/nginx/netboot-access.log

# Test download manually
curl -I http://192.168.1.5/images/itl-hardened/kernel
```

**Solutions:**

```bash
# Verify files exist
cd /var/www/netboot/images/itl-hardened
ls -lh kernel initramfs.xz

# If missing, re-extract from ISO
sudo mount -o loop itl-talos-v1.9.0.iso /tmp/iso
sudo cp /tmp/iso/boot/vmlinuz kernel
sudo cp /tmp/iso/boot/initramfs.xz initramfs.xz
sudo umount /tmp/iso

# Fix permissions
sudo chown -R www-data:www-data /var/www/netboot
sudo chmod -R 755 /var/www/netboot

# Verify nginx can read
sudo -u www-data cat /var/www/netboot/images/itl-hardened/kernel > /dev/null

# Test again
curl http://192.168.1.5/images/itl-hardened/kernel --output /tmp/test
file /tmp/test  # Should be: Linux kernel x86 boot executable
```

---

#### Issue: Configuration not applied

**Symptoms:**
- Server installs but configuration missing
- No LUKS encryption
- Default settings instead of ITL hardening

**Diagnosis:**

```bash
# Check what config was used
talosctl --nodes <ip> get machineconfig -o yaml

# Check if config URL was correct in boot params
# (check nginx access log for the IP during boot)
grep <server-ip> /var/log/nginx/netboot-access.log | grep config
```

**Solutions:**

```bash
# Verify config is accessible
curl http://192.168.1.5/config/itl-hardened/auto-config.yaml

# Check boot menu has correct config URL
cat /var/www/netboot/boot/menu.ipxe | grep talos.config

# Should be:
# talos.config=http://192.168.1.5/config/itl-hardened/auto-config.yaml

# Verify config syntax
talosctl validate --config config/itl-hardened/auto-config.yaml

# Re-apply config manually if needed
talosctl apply-config \
  --nodes <ip> \
  --file /var/www/netboot/config/itl-hardened/controlplane-final.yaml
```

---

#### Issue: TPM disk unlock fails

**Symptoms:**
- Server hangs at "Waiting for TPM"
- Manual unlock required on every boot

**Diagnosis:**

```bash
# Check if TPM is detected
talosctl --nodes <ip> get tpm

# Check systemDiskEncryption config
talosctl --nodes <ip> get machineconfig -o yaml | grep -A10 systemDiskEncryption

# Check TPM module is loaded
talosctl --nodes <ip> dmesg | grep -i tpm
```

**Solutions:**

```bash
# Enable TPM in BIOS/UEFI
# Ensure TPM 2.0 is enabled, not just present

# Verify config has TPM key
cat config/itl-hardened/security-hardening.yaml | grep -A5 tpm

# Should have:
# keys:
#   - slot: 0
#     tpm: {}

# Re-provision with correct config
talosctl reset --nodes <ip>
# Boot from PXE with corrected config
```

---

#### Issue: Branding not showing

**Symptoms:**
- No ITlusions boot banner
- Default Talos appearance

**Diagnosis:**

```bash
# Check if branding extension is loaded
talosctl --nodes <ip> get extensions | grep branding

# Check extension contents
docker run --rm ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0 ls -la /
```

**Solutions:**

```bash
# Verify extension is in config
cat config/itl-hardened/auto-config.yaml | grep branding

# Should have:
# extensions:
#   - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0

# Rebuild extension if needed
cd ~/ITL.Talos.HardenedOS
docker build -t ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0 \
  -f build/Dockerfile.branding .
docker push ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0

# Force re-pull extension
talosctl --nodes <ip> upgrade --preserve --image <same-version>
```

---

### Debugging Tools

**Network debugging:**

```bash
# Monitor all netboot traffic
sudo tcpdump -i any -n -s0 -w /tmp/netboot.pcap \
  'port 67 or port 68 or port 69 or port 80'

# Analyze capture
tcpdump -r /tmp/netboot.pcap -A | less

# Test DHCP response
sudo nmap --script broadcast-dhcp-discover
```

**HTTP debugging:**

```bash
# Monitor nginx in real-time
sudo tail -f /var/log/nginx/netboot-access.log | \
  grep --line-buffered -E 'kernel|initramfs|config'

# Enable nginx debug logging
sudo nano /etc/nginx/nginx.conf
# Set: error_log /var/log/nginx/error.log debug;
sudo nginx -t && sudo systemctl reload nginx

# Watch debug log
sudo tail -f /var/log/nginx/error.log
```

**Talos debugging:**

```bash
# Enable debug logging during boot
# Add to kernel params in menu.ipxe:
# talos.debug=true

# View boot logs
talosctl --nodes <ip> logs --follow

# Access emergency shell (if enabled)
talosctl --nodes <ip> dashboard

# Get machine config
talosctl --nodes <ip> get machineconfig -o yaml > current-config.yaml
```

---

## Advanced Scenarios

### Multi-Tenancy with Different Security Profiles

**Scenario:** Different customers need different security levels

**Implementation:**

```ipxe
# In menu.ipxe
:tenant_menu
menu Select Security Profile
item standard    Standard Security (ISO 27001)
item high        High Security (SOC2 Type II)
item maximum     Maximum Security (Government/Financial)
choose profile && goto boot_tenant

:standard
set config http://192.168.1.5/config/tenant/standard.yaml
goto boot_itl

:high
set config http://192.168.1.5/config/tenant/high.yaml
goto boot_itl

:maximum
set config http://192.168.1.5/config/tenant/maximum.yaml
goto boot_itl
```

**tenant/maximum.yaml:**

```yaml
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
  
  extensions:
    - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
    - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
    - image: siderolabs/nvidia-open-gpu-kernel-modules:latest  # If needed
  
  # Maximum security sysctls
  sysctls:
    kernel.kptr_restrict: "2"
    kernel.dmesg_restrict: "1"
    kernel.unprivileged_userns_clone: "0"
    kernel.unprivileged_bpf_disabled: "1"
    kernel.yama.ptrace_scope: "3"  # Maximum restriction
    net.core.bpf_jit_harden: "2"
    net.ipv4.conf.all.log_martians: "1"
    net.ipv4.conf.all.rp_filter: "1"
    net.ipv4.conf.all.accept_source_route: "0"
    net.ipv4.tcp_syncookies: "1"
  
  # Dual encryption (LUKS + filesystem)
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
        - slot: 1
          static:
            passphrase: "ask-during-install"  # Manual backup key
      options:
        - cipher=aes-xts-plain64
        - key-size=512
        - pbkdf=argon2id
        - pbkdf-memory=2097152  # 2GB for KDF
        - pbkdf-iterations=8
  
  # Disable unused features
  features:
    rbac: true
    stableHostname: true
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:admin
      allowedKubernetesNamespaces:
        - kube-system
  
  # Audit logging
  logging:
    destinations:
      - endpoint: tcp://siem.itlusions.local:514
        format: json_lines
```

---

### Edge Deployment with Offline Capability

**Scenario:** Deploy at remote sites with intermittent connectivity

**Setup:**

```bash
# Create offline package
cd /var/www/netboot
tar czf itl-talos-offline-v1.0.0.tar.gz \
  images/itl-hardened/ \
  config/itl-hardened/ \
  boot/*.ipxe

# Ship to remote site
scp itl-talos-offline-v1.0.0.tar.gz edge-site:/tmp/

# At edge site
ssh edge-site
cd /var/www
sudo tar xzf /tmp/itl-talos-offline-v1.0.0.tar.gz

# Configure edge netboot server
sudo ./setup-netboot-server.sh
# Choose option 1 (HTTP only)

# Test
curl http://localhost/boot/menu.ipxe
```

**Edge-specific menu:**

```ipxe
:edge
echo ITlusions Edge Deployment
echo Offline Mode - Using Local Cache
echo 

kernel http://192.168.100.1/images/itl-hardened/kernel \
  talos.platform=metal \
  talos.config=http://192.168.100.1/config/itl-hardened/edge-config.yaml \
  installer.image=192.168.100.1:5000/itl-talos-installer:v1.0.0 \
  console=tty0 ip=dhcp
initrd http://192.168.100.1/images/itl-hardened/initramfs.xz
boot
```

---

### Custom Hardware Integration

**Scenario:** Deploy on specialized hardware (GPU clusters, storage nodes)

**GPU cluster configuration:**

```yaml
# config/hardware/gpu-cluster.yaml
machine:
  install:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    extensions:
      - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
      - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
      - image: siderolabs/nvidia-container-toolkit:latest
      - image: siderolabs/nonfree-kmod-nvidia:latest
  
  kernel:
    modules:
      - name: nvidia
      - name: nvidia-uvm
      - name: nvidia-drm
      - name: nvidia-modeset
  
  sysctls:
    # GPU-specific tuning
    vm.max_map_count: "262144"
  
  nodeLabels:
    hardware.itlusions.com/gpu: "nvidia"
    hardware.itlusions.com/gpu-count: "8"
    hardware.itlusions.com/gpu-memory: "80GB"
  
cluster:
  # GPU workload scheduling
  allowSchedulingOnControlPlanes: false
```

---

## Reference

### File Locations

**Netboot Server:**
```
/var/www/netboot/
├── boot/
│   ├── menu.ipxe                    # Main menu
│   ├── undionly.kpxe                # BIOS bootloader
│   └── ipxe.efi                     # UEFI bootloader
├── images/
│   └── itl-hardened/
│       ├── itl-talos-v1.9.0.iso     # Full ISO
│       ├── kernel                    # Extracted kernel
│       └── initramfs.xz             # Extracted initramfs
├── config/
│   └── itl-hardened/
│       ├── controlplane-final.yaml  # CP config
│       ├── worker-final.yaml        # Worker config
│       └── auto-config.yaml         # Auto-apply config
└── VERSION                          # Current version marker
```

**ITL.Talos.HardenedOS Repository:**
```
~/ITL.Talos.HardenedOS/
├── .github/workflows/               # CI/CD
├── branding/                        # Logos, banners
├── build/                           # Dockerfiles, scripts
├── config/patches/                  # Configuration patches
├── extensions/                      # Custom extensions
├── docs/                            # Documentation
└── scripts/                         # Helper scripts
```

### Port Reference

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| HTTP | 80 | TCP | Boot files, configs |
| HTTPS | 443 | TCP | Secure boot (optional) |
| TFTP | 69 | UDP | iPXE bootloader |
| DHCP | 67-68 | UDP | IP assignment |
| DNS | 53 | UDP/TCP | Name resolution |

### Environment Variables

**Build pipeline:**
```bash
TALOS_VERSION=v1.9.0
KUBERNETES_VERSION=1.30.0
GHCR_TOKEN=ghp_xxxxx
```

**Netboot server:**
```bash
WEBROOT=/var/www/netboot
LISTEN_IP=192.168.1.5
TFTP_ROOT=/srv/tftp
```

### Command Reference

**GitHub Actions:**
```bash
# Trigger build
git tag v1.0.1 && git push origin v1.0.1

# View logs
gh run list
gh run view <run-id>

# Download artifacts
gh release download v1.0.1
```

**Netboot operations:**
```bash
# Sync from GitHub
rsync -avz github:/releases/v1.0.0/ /var/www/netboot/images/

# Test menu
curl http://localhost/boot/menu.ipxe

# Monitor boots
tail -f /var/log/nginx/netboot-access.log | grep kernel

# Check DHCP
sudo journalctl -u dnsmasq -f
```

**Talos operations:**
```bash
# Apply config
talosctl apply-config --nodes <ip> --file config.yaml

# Check installation
talosctl --nodes <ip> get installations

# View logs
talosctl --nodes <ip> logs --follow

# Reset node
talosctl --nodes <ip> reset --graceful=false
```

### URLs

| Resource | URL |
|----------|-----|
| Repository | https://github.com/ITlusions/ITL.Talos.HardenedOS |
| Container Registry | https://ghcr.io/itlusions |
| Image Factory | https://factory.talos.dev |
| Talos Docs | https://www.talos.dev |
| ITlusions Support | https://support.itlusions.com |

---

## Support & Contact

### Getting Help

**Documentation:**
- This guide (comprehensive reference)
- Repository docs: `ITL.Talos.HardenedOS/docs/`
- Talos official docs: https://www.talos.dev

**Community:**
- GitHub Discussions: https://github.com/ITlusions/ITL.Talos.HardenedOS/discussions
- Slack: #itlusions-talos

**Professional Support:**
- Email: support@itlusions.com
- Phone: +31 (0)20 xxx xxxx
- Portal: https://support.itlusions.com

### Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

### License

MIT License - See repository LICENSE file

---

**Document Version:** 1.0  
**Last Updated:** May 2026  
**Maintained by:** ITlusions Infrastructure Team  
**For:** ITL.Talos.HardenedOS v1.0.0+

---

*ITlusions - Enterprise Kubernetes Infrastructure*  
*Hardened • Supported • Production-Ready*
