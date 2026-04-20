# Deployment Guide

Complete guide for deploying ITL Talos OS clusters — from quick single-node to production HA and Zero-Touch Provisioning.

---

## Quick Start (5 minutes)

### Prerequisites

- GitHub account with access to the repository
- Target machine: 2 CPU / 2 GB RAM / 40 GB disk minimum
- `talosctl` v1.9.0+ and `kubectl` v1.29.0+ installed on your admin machine

### 1. Trigger a build

```bash
git clone https://github.com/ITlusions/ITL.Talos.HardenedOS.git
cd ITL.Talos.HardenedOS
git tag v1.0.0
git push origin v1.0.0
```

The pipeline runs automatically (~45 minutes). See [03-BUILD-PIPELINE.md](03-BUILD-PIPELINE.md) for details.

### 2. Download artifacts

Go to **GitHub → Releases → v1.0.0** and download:
- `itl-talos-v1.9.0.iso` — bootable image (~500 MB)
- `controlplane-final.yaml` — control plane config
- `worker-final.yaml` — worker node config

### 3. Boot the ISO

**VM (KVM/VirtualBox)**: Create a 40 GB disk, attach ISO as boot media, power on.

**Bare metal**:
```bash
# Linux/Mac
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress
# Windows: use Rufus (https://rufus.ie/)
```

**Cloud**: Upload ISO to cloud storage and create a VM from a custom image.

### 4. Apply configuration and bootstrap

```bash
export TALOS_HOST=<machine-ip>
export TALOS_ENDPOINT=<machine-ip>

# Apply control plane config
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure

# Bootstrap Kubernetes
talosctl bootstrap --nodes ${TALOS_HOST} --endpoints ${TALOS_ENDPOINT}

# Get kubeconfig and verify
talosctl kubeconfig . --nodes ${TALOS_HOST} --endpoints ${TALOS_ENDPOINT}
kubectl get nodes
```

After 2–3 minutes: `talos-1   Ready   master,worker   2m   v1.29.0`

### Common Quick-Start Issues

| Symptom | Fix |
|---------|-----|
| Can't download release | Check GitHub permissions; re-tag if needed |
| ISO won't boot | Use Rufus/Etcher; verify SHA256; try UEFI mode |
| apply-config fails | Add `--insecure` on first boot; verify IP |
| Kubernetes won't start | Wait 2–3 min for etcd; check disk space; `talosctl logs -f` |
| Lost access | `talosctl apply-config --insecure --force` |

---

## Deployment Methods

| Method | Best for |
|--------|----------|
| [Zero-Touch Provisioning (ZTP)](#zero-touch-provisioning-ztp) | Production — fully automated via TPM identity |
| [USB-less Installation](#usb-less-installation) | Bare metal without physical media — PXE, UEFI HTTP Boot, BMC virtual media |
| [Single node](#single-node-deployment) | Dev/test |
| [HA multi-node](#multi-node-ha-deployment) | Production |
| [Cloud](#cloud-deployments) | AWS / Azure / GCP |

---

## Zero-Touch Provisioning (ZTP)

Fully automated install driven by TPM hardware identity. A machine boots a lightweight Alpine USB agent, registers its TPM EK with the Registration Service, receives the correct role-specific ISO, installs it — then attestation and config delivery happen automatically on first Talos boot. Zero operator input per node.

### Architecture

```
USB Agent Boot (Alpine Linux)
        │
        │  POST /api/v1/register
        │  { ek_fingerprint, hw_uuid, hw_mac, desired_role }
        ▼
Registration Service  ─────────────────────────────────────────
        │                                                      │
   EK known?                                                   │
   ├─ YES → assign pre-configured role + ISO URL + config_token│
   └─ NO  → status=pending_approval (admin approves via UI/CLI)│
        │                                                      │
        ▼                                               SQLite DB
   Returns: { role, iso_url, config_token }              machines
        │
        │  Download role-specific ISO
        │  itl-talos-controlplane-amd64.iso
        │  itl-talos-worker-infra-amd64.iso
        │  itl-talos-worker-app-amd64.iso
        ▼
   dd ISO → target disk
   Write registration receipt → EFI partition
        │
        ▼
   Reboot into Talos
        │
        │  GET /api/v1/config/{token}  (kernel cmdline: talos.config=...)
        ▼
   Talos fetches machine-specific MachineConfig YAML (one-time token)
   Applies: LUKS2+TPM seal, OIDC, network, security patches
   Reboots into hardened state
        │
        ▼
   itl-tpm-register extension runs (first boot only, idempotent)
        │  POST /api/v1/attest
        │  { ek_fingerprint, pcr_quote (PCRs 0-7), hw_uuid }
        ▼
   Service verifies EK matches pre-registered record
   Machine marked status=attested
```

### Role assignment

| Source | How |
|--------|-----|
| **Pre-registration by EK fingerprint** | Register TPM EK before hardware arrives → role auto-assigned at USB boot |
| **`desired_role` hint** | Set `ITL_ROLE=controlplane` env var on USB agent — used as hint, admin can override |
| **Admin approval** | Unknown machines land in `pending_approval` → `POST /api/v1/machines/{id}/approve` |
| **Offline bundle** | Role baked into bundle at generation time — fully deterministic, airgap-safe |

### Start the Registration Service

```bash
cd provisioner
cp .env.example .env
# Edit .env:
#   ITL_ADMIN_TOKEN=<strong-secret>
#   ITL_SERVICE_URL=https://reg.itlusions.com
#   ITL_ISO_BASE_URL=https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download

docker compose up -d

# Download role configs from the matching release
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh v1.9.0"
```

### Pre-register a machine (known hardware)

```bash
curl -s -X POST https://reg.itlusions.com/api/v1/machines/import \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ek_fingerprint": "<64-char-sha256-hex>",
    "hw_serial": "SRV-001",
    "role": "controlplane",
    "hostname": "cp1.itlusions.internal"
  }'
```

### Create the USB agent

```bash
# Online
cd provisioner/usb-agent
./build-usb.sh /dev/sdX

# Airgapped / offline
./build-usb-offline.sh /dev/sdX --machine-id <uuid> --role controlplane
```

### Boot a node

1. Insert USB, power on machine.
2. USB agent reads TPM EK, calls Registration Service, downloads + writes role-specific ISO.
3. Reboots — no operator input required from this point.

### Admin approval (unknown machines)

```bash
# List pending
curl -s https://reg.itlusions.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | jq '.[] | select(.status=="pending_approval")'

# Approve and assign role
curl -s -X POST https://reg.itlusions.com/api/v1/machines/{machine_id}/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role": "worker-app", "hostname": "w1.itlusions.internal"}'
```

### Verify attestation

```bash
curl -s https://reg.itlusions.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | \
  jq '.[] | {hostname, role, status, attested_at}'
# status=attested means TPM PCR quote verified, node is trusted
```

### ZTP checklist

| Step | Who | Command / Action |
|------|-----|-----------------|
| Start Registration Service | Admin | `docker compose up -d` |
| Pre-register hardware (optional) | Admin | `POST /api/v1/machines/import` |
| Build USB agent | Admin | `./build-usb.sh /dev/sdX` |
| Boot machine with USB | Ops | Insert USB, power on |
| Approve if unknown (optional) | Admin | `POST /api/v1/machines/{id}/approve` |
| Node installs + attests | Automatic | — |
| Bootstrap first control plane | Admin | `talosctl bootstrap` (once) |

> **Firewall**: Add port `8443/tcp` (or `443/tcp` behind Caddy) for nodes to reach the Registration Service during install.

---

## USB-less Installation

Deploy ITL Talos OS to bare metal without preparing any USB drive. Choose the method that fits your infrastructure:

| Method | Requires | Best for |
|--------|----------|----------|
| [PXE / iPXE](#pxe--ipxe-network-boot) | TFTP/HTTP server on LAN | Datacentres, rack servers |
| [UEFI HTTP Boot](#uefi-http-boot) | HTTP server + UEFI 2.5+ firmware | Modern servers, no PXE infra needed |
| [BMC Virtual Media](#bmc--ipmi-virtual-media) | iDRAC / iLO / IPMI access | Servers with out-of-band management |
| [ZTP PXE Agent](#ztp-pxe-agent) | ZTP Registration Service + PXE | Full automation without any physical media |

---

### PXE / iPXE Network Boot

Serve the ITL Talos ISO kernel and initrd over the network. The machine boots entirely from the LAN — no USB, no CD.

#### 1. Set up the PXE server

```bash
# Install dnsmasq (DHCP + TFTP) and a simple HTTP server
apt-get install -y dnsmasq nginx

# Download the ITL Talos assets from the release
mkdir -p /srv/pxe/itl-talos
curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download/itl-talos-v1.9.0-vmlinuz \
  -o /srv/pxe/itl-talos/vmlinuz
curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download/itl-talos-v1.9.0-initramfs.xz \
  -o /srv/pxe/itl-talos/initramfs.xz
curl -L https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download/itl-talos-v1.9.0.iso \
  -o /srv/pxe/itl-talos/itl-talos.iso
```

#### 2. Configure dnsmasq

```ini
# /etc/dnsmasq.d/pxe.conf
dhcp-range=192.168.1.50,192.168.1.150,12h
dhcp-boot=ipxe.efi                         # UEFI
# dhcp-boot=undionly.kpxe                  # BIOS fallback
enable-tftp
tftp-root=/srv/tftp

# Point iPXE clients to the HTTP boot script
dhcp-match=set:ipxe,175                    # iPXE option
dhcp-boot=tag:ipxe,http://192.168.1.1/boot.ipxe
```

#### 3. Write the iPXE boot script

```ipxe
# /var/www/html/boot.ipxe
#!ipxe

echo ITL Talos HardenedOS - Network Boot
echo.

set base-url http://192.168.1.1/itl-talos

kernel ${base-url}/vmlinuz \
  talos.platform=metal \
  talos.config=http://192.168.1.1/configs/${mac:hexhyp}-controlplane.yaml \
  console=tty0 console=ttyS0,115200n8
initrd ${base-url}/initramfs.xz
boot
```

> **Tip**: Replace `${mac:hexhyp}` with a fixed filename if you want all nodes to receive the same config, or use the MAC address variable to serve per-node configs automatically.

#### 4. Serve machine configs

```bash
# Place configs so they are reachable by the boot script
cp controlplane-final.yaml /var/www/html/configs/aa-bb-cc-dd-ee-ff-controlplane.yaml
cp worker-final.yaml       /var/www/html/configs/aa-bb-cc-dd-ee-ff-worker.yaml

# Or serve a generic config for all nodes of the same role
cp controlplane-final.yaml /var/www/html/configs/controlplane.yaml
```

#### 5. Boot the target machine

Set the BIOS/UEFI boot order to **Network / PXE first**, then power on. The machine will:
1. Get a DHCP lease and iPXE binary from dnsmasq
2. Chainload the iPXE boot script
3. Download kernel + initrd and boot Talos in memory
4. Fetch its MachineConfig from the URL in the kernel cmdline
5. Install to disk and reboot into the hardened OS

#### 6. Bootstrap (first time only)

```bash
# Wait ~2 min after reboot, then:
talosctl bootstrap --nodes 192.168.1.100 --endpoints 192.168.1.100
talosctl kubeconfig . --nodes 192.168.1.100
kubectl get nodes
```

---

### UEFI HTTP Boot

Modern UEFI firmware (2.5+) can boot directly from an HTTP URL without a TFTP server or iPXE binary. This is the simplest USB-less method for modern hardware.

#### 1. Serve the ISO over HTTPS

```bash
# Host the ISO on any static file server, e.g. nginx
cp itl-talos-v1.9.0.iso /var/www/html/

# Or use a one-liner with Python
python3 -m http.server 8080 --directory /path/to/releases/
```

#### 2. Configure the UEFI HTTP Boot entry

In the machine's UEFI setup screen:

```
Boot Manager → Add Boot Option
  Description : ITL Talos
  Network Interface : <LAN adapter>
  Boot URL : http://192.168.1.1:8080/itl-talos-v1.9.0.iso
```

Or configure it remotely via `efibootmgr` on a running system:

```bash
efibootmgr --create \
  --label "ITL Talos" \
  --loader '\EFI\BOOT\BOOTX64.EFI' \
  --unicode 'http://192.168.1.1:8080/itl-talos-v1.9.0.iso'
```

#### 3. Boot and apply config

Select the new boot entry. The firmware downloads and boots the ISO. Once Talos is running:

```bash
talosctl apply-config --nodes <machine-ip> --file controlplane-final.yaml --insecure
talosctl bootstrap --nodes <machine-ip> --endpoints <machine-ip>
```

---

### BMC / IPMI Virtual Media

If the server has an out-of-band management interface (iDRAC, iLO, IPMI, Redfish), you can mount the ISO as a virtual USB/CD drive remotely — no physical access required.

#### iDRAC (Dell)

```bash
# Mount ISO via Redfish API
curl -k -X POST \
  -H "Content-Type: application/json" \
  -u root:password \
  https://<idrac-ip>/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia \
  -d '{
    "Image": "http://192.168.1.1/itl-talos-v1.9.0.iso",
    "Inserted": true,
    "WriteProtected": true
  }'

# Set one-time boot from virtual CD
curl -k -X PATCH \
  -H "Content-Type: application/json" \
  -u root:password \
  https://<idrac-ip>/redfish/v1/Systems/System.Embedded.1 \
  -d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}'

# Power cycle
curl -k -X POST \
  -H "Content-Type: application/json" \
  -u root:password \
  https://<idrac-ip>/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \
  -d '{"ResetType": "ForceRestart"}'
```

#### iLO (HPE)

```bash
# Mount ISO via Redfish
curl -k -X POST \
  -H "Content-Type: application/json" \
  -u Administrator:password \
  https://<ilo-ip>/redfish/v1/Managers/1/VirtualMedia/2/Actions/VirtualMedia.InsertMedia \
  -d '{"Image": "http://192.168.1.1/itl-talos-v1.9.0.iso"}'

# One-time boot from virtual CD
curl -k -X PATCH \
  -H "Content-Type: application/json" \
  -u Administrator:password \
  https://<ilo-ip>/redfish/v1/Systems/1 \
  -d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}'
```

#### Generic IPMI (older servers)

```bash
# Share the ISO as a NFS/CIFS export then map it
ipmi-oem dell set-system-info os-name "ITL Talos"
ipmitool -I lanplus -H <bmc-ip> -U admin -P password \
  chassis bootdev cdrom options=persistent
ipmitool -I lanplus -H <bmc-ip> -U admin -P password chassis power reset
```

---

### ZTP PXE Agent

Combine ZTP (automatic role assignment + TPM attestation) with PXE boot to eliminate ALL physical media. The PXE server delivers the Alpine Linux ZTP agent over the network — the same agent that normally runs from a USB drive.

```
Machine powers on (no USB, no CD)
        │
        │  DHCP → iPXE binary
        ▼
  iPXE boot script
        │  Downloads Alpine ZTP agent kernel + initrd
        ▼
  ZTP Agent (Alpine, running in RAM)
        │  POST /api/v1/register  { ek_fingerprint, hw_uuid, desired_role }
        ▼
  Registration Service
        │  Returns: role + ISO URL + config_token
        ▼
  dd role-specific ISO → disk
  Reboots into Talos
        │  Fetches MachineConfig by token
        ▼
  Hardened Talos running — no operator touch required
```

#### Set up the PXE ZTP agent images

```bash
# Build the PXE-bootable ZTP agent (produces vmlinuz + initramfs)
cd provisioner/usb-agent
./build-pxe-agent.sh

# Copy to PXE server
cp dist/pxe/vmlinuz    /srv/pxe/ztp-agent/
cp dist/pxe/initramfs.xz /srv/pxe/ztp-agent/
```

#### iPXE boot script for ZTP agent

```ipxe
#!ipxe

set base-url http://192.168.1.1/ztp-agent
set reg-url   https://reg.itlusions.com

kernel ${base-url}/vmlinuz \
  ITL_REGISTRATION_URL=${reg-url} \
  ITL_ROLE=auto \
  console=tty0 console=ttyS0,115200n8
initrd ${base-url}/initramfs.xz
boot
```

#### From here, the flow is identical to USB ZTP

See [ZTP checklist](#ztp-checklist) above. The only difference: step "Build USB agent" becomes "ensure PXE server is serving ZTP agent images".

---

## Pre-Deployment Checklist

**Infrastructure**
- [ ] Minimum 2 GB RAM per node
- [ ] Minimum 40 GB disk per node
- [ ] Network connectivity (1 Gbps recommended)
- [ ] DNS resolution working
- [ ] NTP time synchronization working
- [ ] Power redundancy for production

**Security**
- [ ] Firewall configured for Kubernetes ports
- [ ] SSH key pair generated and backed up
- [ ] Storage encryption enabled (LUKS2)
- [ ] TPM 2.0 enabled in BIOS (if available)
- [ ] Network policies planned
- [ ] TLS certificates prepared

**Tools**
- [ ] talosctl v1.9.0+ installed
- [ ] kubectl v1.29.0+ installed
- [ ] kubeconfig backup location ready

---

## Network Planning

### Port Requirements

| Service | Port | Protocol | Nodes |
|---------|------|----------|-------|
| Kubernetes API | 6443 | TCP | Control Plane |
| etcd | 2379–2380 | TCP | Control Plane |
| kubelet | 10250 | TCP | All |
| Service NodePort | 31000–32767 | TCP/UDP | All |
| Talos API | 50000 | TCP | Management |
| DNS | 53 | UDP | All |
| ZTP Registration | 8443 | TCP | All (ZTP only) |

### Firewall Rules (AWS Security Group example)

```yaml
- IpProtocol: tcp
  FromPort: 6443
  ToPort: 6443
  CidrIp: 10.0.0.0/8          # Kubernetes API

- IpProtocol: tcp
  FromPort: 10250
  ToPort: 10250
  CidrIp: 10.0.0.0/8          # Kubelet

- IpProtocol: tcp
  FromPort: 50000
  ToPort: 50000
  CidrIp: 10.0.0.0/24         # Talos API (management subnet only)

- IpProtocol: tcp
  FromPort: 31000
  ToPort: 32767
  CidrIp: 0.0.0.0/0           # Service NodePort range
```

---

## Single Node Deployment

Minimal setup for testing or small workloads.

### 1. Set variables

```bash
export TALOS_HOST=192.168.1.100
export TALOS_ENDPOINT=192.168.1.100
```

### 2. Boot ISO

Flash `itl-talos-v1.9.0.iso` to USB or attach to VM, then boot.

### 3. Apply configuration

```bash
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure

sleep 30
```

### 4. Bootstrap Kubernetes

```bash
talosctl bootstrap --nodes ${TALOS_HOST} \
  --endpoints ${TALOS_ENDPOINT}

sleep 180
```

### 5. Get kubeconfig and verify

```bash
talosctl kubeconfig . --nodes ${TALOS_HOST} --endpoints ${TALOS_ENDPOINT}

export KUBECONFIG=${PWD}/kubeconfig
kubectl get nodes
# talos-1   Ready   ...

talosctl health --nodes ${TALOS_HOST}
kubectl get pods -A
```

---

## Multi-Node HA Deployment

### Architecture

```
3 Control Plane Nodes (HA etcd)
├── talos-cp1 (192.168.1.100)
├── talos-cp2 (192.168.1.101)
└── talos-cp3 (192.168.1.102)

Worker Nodes
├── talos-w1 (192.168.1.110)
├── talos-w2 (192.168.1.111)
└── talos-w3+ (...)

Load Balancer (optional)
└── Kubernetes API: 192.168.1.200:6443
```

### 1. Apply config to control plane nodes

```bash
for NODE in 192.168.1.100 192.168.1.101 192.168.1.102; do
  talosctl apply-config --nodes ${NODE} \
    --file controlplane-final.yaml \
    --insecure
done
```

### 2. Bootstrap first control plane

```bash
talosctl bootstrap --nodes 192.168.1.100 \
  --endpoints 192.168.1.100

sleep 180
```

### 3. Add worker nodes

```bash
for NODE in 192.168.1.110 192.168.1.111 192.168.1.112; do
  talosctl apply-config --nodes ${NODE} \
    --file worker-final.yaml \
    --insecure
  sleep 30
done
```

### 4. Get kubeconfig and verify

```bash
talosctl kubeconfig . --nodes 192.168.1.100
kubectl get nodes -w
```

### 5. Configure load balancer (optional)

```
# HAProxy example
frontend kubernetes-api
  bind 192.168.1.200:6443
  default_backend api_servers

backend api_servers
  balance roundrobin
  server talos-cp1 192.168.1.100:6443 check
  server talos-cp2 192.168.1.101:6443 check
  server talos-cp3 192.168.1.102:6443 check
```

---

## Cloud Deployments

### AWS EC2

```bash
aws s3 cp itl-talos-v1.9.0.iso s3://my-bucket/
aws ec2 import-image --description "Talos Custom" --license-type BYOL --platform Linux

aws ec2 create-security-group --group-name talos-sg --description "Talos cluster"
aws ec2 authorize-security-group-ingress \
  --group-name talos-sg --protocol tcp --port 6443 --cidr 10.0.0.0/8

aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.large \
  --count 3 \
  --security-group-names talos-sg
```

### Azure VMs

```bash
az group create -n talos-rg -l eastus
az storage blob upload --file itl-talos-v1.9.0.iso \
  --container-name vhds --name talos.vhd --account-name mystorageaccount
az image create -g talos-rg -n talos-image --os-type Linux --source <vhd-url>
az vm create -g talos-rg -n talos-1 --image talos-image --size Standard_B2s
```

### Google Cloud

```bash
gcloud compute images create talos-image \
  --source-uri gs://my-bucket/itl-talos-v1.9.0.iso

gcloud compute instances create talos-1 \
  --image talos-image \
  --machine-type n1-standard-2 \
  --zone us-central1-a
```

---

## Post-Deployment Configuration

### Storage

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  local:
    path: /mnt/local-storage
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - talos-1
EOF
```

### CNI (Network Plugin)

```bash
# Cilium
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --namespace kube-system

# Flannel
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```

### Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

### Monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

---

## Backup and Recovery

### Backup

```bash
# Backup node configs
for NODE in 192.168.1.100 192.168.1.101 192.168.1.102; do
  talosctl read /etc/os-release --nodes ${NODE} > ${NODE}-config.yaml
done

cp kubeconfig kubeconfig.backup
kubectl get etcd -o yaml > etcd-backup.yaml
```

### Recovery

```bash
# If a control plane node fails — boot replacement with ISO then:
talosctl apply-config --nodes <new-ip> --file controlplane-final.yaml --insecure
# Node joins cluster automatically

# If entire cluster lost:
# 1. Boot all nodes with ISO
# 2. Apply configs to all nodes
# 3. Bootstrap again:
talosctl bootstrap --nodes 192.168.1.100
```

---

## Troubleshooting

### Node Won't Boot

```bash
talosctl logs -f -n ${TALOS_HOST}
talosctl services -n ${TALOS_HOST}
talosctl reboot -n ${TALOS_HOST}
```

### Kubernetes API Unreachable

```bash
talosctl logs -f -n ${TALOS_HOST} -k kube-apiserver
talosctl logs -f -n ${TALOS_HOST} -k etcd
talosctl restart -n ${TALOS_HOST} -k kube-apiserver
```

### Node Not Joining Cluster

```bash
kubectl describe node <node-name>
talosctl logs -f -n ${TALOS_HOST} -k kubelet
talosctl restart -n ${TALOS_HOST} -k kubelet
```

### Security Hardening

```bash
# Default deny ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF

# Enforce Pod Security Standards
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted
```
