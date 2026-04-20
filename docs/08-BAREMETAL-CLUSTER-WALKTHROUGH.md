# Bare Metal Cluster Walkthrough

Complete step-by-step guide for deploying a **1 Control Plane + 2 Worker** ITL Talos HardenedOS cluster on three physical machines.

---

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Network (LAN)                      │
│                                                             │
│  ┌──────────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Machine 1      │  │  Machine 2   │  │  Machine 3   │  │
│  │   itl-cp1        │  │  itl-w1      │  │  itl-w2      │  │
│  │   Control Plane  │  │  Worker      │  │  Worker      │  │
│  │  192.168.1.100   │  │ 192.168.1.101│  │ 192.168.1.102│  │
│  └──────────────────┘  └──────────────┘  └──────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Admin Laptop — runs talosctl / kubectl / script    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### What gets deployed

| Layer | What | How |
|-------|------|-----|
| **ISO** (build time) | Boot loader, ITL kernel, splash screen, installer | Pre-built `itl-talos-v1.9.0.iso` |
| **MachineConfig** (provision time) | Disk encryption, kubelet hardening, network policy, branding banner | Patches applied via `talosctl apply-config` |
| **Kubernetes** (bootstrap time) | etcd, kube-apiserver, kube-scheduler, kube-controller, CoreDNS, kube-proxy | `talosctl bootstrap` |

---

## Prerequisites

### Admin machine (your laptop)

| Tool | Version | Install |
|------|---------|---------|
| `talosctl` | v1.9.0+ | https://github.com/siderolabs/talos/releases |
| `kubectl` | v1.29.0+ | https://kubernetes.io/docs/tasks/tools/ |
| Rufus (Windows) or `dd` (Linux/macOS) | latest | https://rufus.ie |

Verify:
```powershell
talosctl version --client
kubectl version --client
```

### Each bare metal machine

| Requirement | Minimum |
|------------|---------|
| CPU | 2 cores (x86-64) |
| RAM | 2 GB (4 GB recommended) |
| Disk | 40 GB (SSD recommended) |
| Network | 1 wired NIC, connected to the same LAN switch as your laptop |
| BIOS/UEFI | UEFI preferred; Secure Boot **must be OFF** |
| Boot order | USB first, then disk |

---

## Step 1 — Get the ISO

### Option A: Download from GitHub Releases (recommended)

```powershell
cd D:\repos\ITL.Talos.HardenedOS

# Download latest release ISO
$release = Invoke-RestMethod "https://api.github.com/repos/ITlusions/ITL.Talos.HardenedOS/releases/latest"
$asset   = $release.assets | Where-Object name -like "*.iso" | Select-Object -First 1
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "iso-download\$($asset.name)"
```

### Option B: Use existing ISO in this repo

```powershell
# Already present at:
ls .\iso-download\
# itl-talos-v1.9.0.iso
```

### Option C: Build from source

```powershell
.\build-iso.ps1
# Output: .\iso-output\itl-talos-v1.9.0.iso
```

> The ISO contains the ITL kernel, splash screen, and installer. The **hardening settings are applied separately** in Step 5.

---

## Step 2 — Flash USB drives

You need 3 USB drives (one per machine), or boot them one at a time from the same USB.

### Windows (Rufus)

1. Open **Rufus** → select the USB device
2. **Boot selection**: select `itl-talos-v1.9.0.iso`
3. **Partition scheme**: GPT
4. **Target system**: UEFI (non-CSM)
5. Click **START** → Write in DD Image mode when prompted

### Linux / macOS

```bash
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress oflag=sync
# Replace /dev/sdX with your USB device (check with lsblk)
```

---

## Step 3 — Boot machines from USB

On each machine:

1. Plug in the USB drive
2. Power on and enter boot menu (**F12** / **DEL** / **F2** — varies by vendor)
3. Select **USB Drive / UEFI USB**
4. Disable Secure Boot if prompted

**What you'll see:**

```
╔════════════════════════════════════════════════════╗
║  ITL TALOS — HARDENED OS FOR KUBERNETES            ║
║  Security Level: MAXIMUM                           ║
║  Encryption: LUKS2 + TPM 2.0                       ║
╚════════════════════════════════════════════════════╝

Talos v1.9.0 booting...
[  OK  ] Reached target: maintenance mode
```

Talos is now in **maintenance mode** — it has not touched the disk yet. The node waits for a MachineConfig to be pushed before installing.

5. Note each machine's IP address from the console, or check your router's DHCP leases.

---

## Step 4 — Verify connectivity from your laptop

```powershell
# Talos maintenance API listens on port 50000
Test-NetConnection -ComputerName 192.168.1.100 -Port 50000   # CP
Test-NetConnection -ComputerName 192.168.1.101 -Port 50000   # W1
Test-NetConnection -ComputerName 192.168.1.102 -Port 50000   # W2
```

All three should show `TcpTestSucceeded : True`.

---

## Step 5 — Generate MachineConfigs (with all patches)

The following patches are applied on top of the base Talos config:

| Patch | Contents |
|-------|----------|
| `security-hardening.yaml` | LUKS2 disk encryption (TPM2 + nodeID), kubelet CIS hardening, sysctls (ptrace, BPF, ICMP hardening, IPv6 disable), SSH key-only auth, audit log |
| `network-hardening.yaml` | DNS (1.1.1.1 / 8.8.8.8), NTP (Cloudflare + pool.ntp.org), kube-proxy iptables, etcd metrics on localhost only |
| `branding-patch.yaml` | ITLusions ASCII banner written to `/etc/issue` and `/etc/motd` — shown at console login |

```powershell
cd D:\repos\ITL.Talos.HardenedOS

$CP_IP    = "192.168.1.100"
$OUT      = ".\config\generated\itl"

# Generate configs for this cluster
talosctl gen config itl "https://${CP_IP}:6443" `
    --output $OUT `
    --config-patch "@.\config\patches\security-hardening.yaml" `
    --config-patch "@.\config\patches\network-hardening.yaml" `
    --config-patch "@.\config\patches\branding-patch.yaml" `
    --force
```

**Output files in `config\generated\itl\`:**

| File | Purpose |
|------|---------|
| `controlplane.yaml` | Applied to Machine 1 only |
| `worker.yaml` | Applied to Machines 2 and 3 |
| `talosconfig` | Your admin credentials for `talosctl` |

> **Optional — OIDC (Keycloak)**: If Keycloak is already running at `https://auth.itlusions.com`, add:
> ```powershell
>     --config-patch "@.\config\patches\oidc-patch.yaml"
> ```

---

## Step 6 — Apply configs to nodes

This is the moment Talos installs to disk. Each node will:
1. Receive the MachineConfig
2. Install Talos (with all hardening settings) to the primary disk
3. Enable LUKS2 encryption on the STATE and EPHEMERAL partitions
4. Reboot from disk

```powershell
$OUT  = ".\config\generated\itl"
$CP   = "192.168.1.100"
$W1   = "192.168.1.101"
$W2   = "192.168.1.102"

# Control plane
talosctl apply-config --nodes $CP --file "$OUT\controlplane.yaml" --insecure

# Workers
talosctl apply-config --nodes $W1 --file "$OUT\worker.yaml" --insecure
talosctl apply-config --nodes $W2 --file "$OUT\worker.yaml" --insecure
```

Watch the consoles — each machine will show the install progress, then reboot. **You can remove the USB drives after the first reboot.**

Wait until all 3 machines have rebooted and are showing the maintenance prompt again (~2–3 minutes).

---

## Step 7 — Bootstrap Kubernetes

Bootstrap must be run **exactly once** on the control plane node. It initialises etcd and the Kubernetes API server.

```powershell
$env:TALOSCONFIG = "D:\repos\ITL.Talos.HardenedOS\config\generated\itl\talosconfig"

talosctl bootstrap --nodes 192.168.1.100 --endpoints 192.168.1.100
```

This triggers:
- etcd cluster formation (single node for now)
- kube-apiserver start with all CIS hardening arguments
- kube-controller-manager + kube-scheduler start
- CoreDNS deployment
- Workers automatically join once they receive the kubeconfig secret from the CP

---

## Step 8 — Get kubeconfig

Wait ~3 minutes for the Kubernetes API to become ready, then:

```powershell
talosctl kubeconfig .\kubeconfig-itl `
    --nodes 192.168.1.100 `
    --endpoints 192.168.1.100

$env:KUBECONFIG = "$PWD\kubeconfig-itl"
```

---

## Step 9 — Verify the cluster

```powershell
kubectl get nodes -o wide
```

Expected output:

```
NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP
itl-cp1   Ready    control-plane   5m    v1.29.0   192.168.1.100
itl-w1    Ready    <none>          4m    v1.29.0   192.168.1.101
itl-w2    Ready    <none>          4m    v1.29.0   192.168.1.102
```

```powershell
# Check all system pods are running
kubectl get pods -A

# Check cluster health via talosctl
talosctl health --nodes 192.168.1.100 --endpoints 192.168.1.100

# Open live dashboard (Ctrl+C to exit)
talosctl dashboard --nodes 192.168.1.100
```

---

## Automated version

All of the above is scripted in one file:

```powershell
# Interactive (prompts for IPs)
.\setup-cluster-baremetal.ps1

# Non-interactive
.\setup-cluster-baremetal.ps1 `
    -CpIp 192.168.1.100 `
    -W1Ip 192.168.1.101 `
    -W2Ip 192.168.1.102

# With static IPs (no DHCP)
.\setup-cluster-baremetal.ps1 `
    -CpIp 192.168.1.100 -W1Ip 192.168.1.101 -W2Ip 192.168.1.102 `
    -UseStaticIps $true -Gateway 192.168.1.1

# With OIDC (Keycloak must be live)
.\setup-cluster-baremetal.ps1 `
    -CpIp 192.168.1.100 -W1Ip 192.168.1.101 -W2Ip 192.168.1.102 `
    -EnableOidc $true
```

---

## Troubleshooting

### Node not reachable on port 50000

- Machine still booting — wait another 30 seconds
- USB not set as first boot device — re-enter BIOS
- Secure Boot blocking the kernel — disable in BIOS

### `apply-config` fails with "certificate signed by unknown authority"

Add `--insecure`. This is expected on first boot — the node has no TLS certificate yet.

### `bootstrap` fails with "connection refused"

The CP hasn't finished installing. Check the console — it should show install progress bars. Wait until the reboot completes.

### Workers stay `NotReady`

```powershell
# Check worker status
talosctl logs --nodes 192.168.1.101 --endpoints 192.168.1.100 kubelet
```

Common cause: CPgroup didn't finish bootstrapping. Worker joins automatically once the API server is reachable — just wait.

### Disk encryption seal fails (TPM error)

The machine has no TPM 2.0 chip. Edit `security-hardening.yaml` and remove the `tpm: {}` key entry, leaving only `nodeID: {}`. Re-run Step 5 and 6.

### Lost talosconfig

The talosconfig is at `config\generated\itl\talosconfig`. If lost entirely, use `--insecure` with a reset:
```powershell
talosctl reset --nodes 192.168.1.100 --endpoints 192.168.1.100 --graceful=false
# Then start from Step 5
```

---

## What's protected after deployment

| Protection | Mechanism |
|------------|-----------|
| Disk at rest | LUKS2 (STATE + EPHEMERAL), sealed with TPM2 PCR + nodeID |
| Network | IPv6 disabled, ICMP hardened, TCP SYN cookies, martian logging |
| Kernel | ptrace restricted (scope 2), BPF unprivileged disabled, dmesg restricted |
| Kubernetes API | Audit log, encryption-at-rest config, CIS controller-manager flags |
| kubelet | Read-only port disabled, protect-kernel-defaults, cert rotation |
| SSH | Key-only auth, Ed25519 only, ChaCha20-Poly1305 / AES-256-GCM ciphers |
| Console login | ITLusions banner on `/etc/issue` — confirms you're on a hardened node |
