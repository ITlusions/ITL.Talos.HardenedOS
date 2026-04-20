# Deployment Guide

Comprehensive production deployment of Talos Linux clusters.

## Deployment Methods

| Method | When to use |
|--------|-------------|
| [Zero-Touch Provisioning (ZTP)](#zero-touch-provisioning-ztp) | Production — fully automated via TPM identity |
| [Manual deployment](#single-node-deployment) | Dev/test or single-node |
| [HA multi-node](#multi-node-ha-deployment) | Production multi-node (manual config push) |
| [Cloud](#cloud-deployments) | AWS / Azure / GCP |

---

## Zero-Touch Provisioning (ZTP)

Full automated install driven by TPM hardware identity. A machine boots a lightweight Alpine USB agent, registers its TPM EK with the Registration Service, receives the correct role-specific ISO, installs it, then attestation and config delivery happen automatically on first Talos boot — zero operator input per node.

### Architecture

```
USB Agent Boot (Alpine Linux)
        │
        │  POST /api/v1/register
        │  { ek_fingerprint, hw_uuid, hw_mac, desired_role }
        ▼
Registration Service  ────────────────────────────────────────────
        │                                                         │
   EK known?                                                      │
   ├─ YES → assign pre-configured role + ISO URL + config_token   │
   └─ NO  → status=pending_approval (admin approves via UI/CLI)   │
        │                                                         │
        ▼                                                    SQLite DB
   Returns: { role, iso_url, config_token }                  machines
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

### What determines the role?

| Source | How |
|--------|-----|
| **Pre-registration by EK fingerprint** | Register TPM EK before hardware arrives → role auto-assigned at USB boot |
| **`desired_role` hint** | Set `ITL_ROLE=controlplane` env var on USB agent — used as hint, admin can override |
| **Admin approval** | Unknown machines land in `pending_approval` → `POST /api/v1/machines/{id}/approve` |
| **Offline bundle** | Role baked into bundle at generation time — fully deterministic, airgap-safe |

### Start the Registration Service

```bash
# 1. Configure environment
cd provisioner
cp .env.example .env
# Edit .env:
#   ITL_ADMIN_TOKEN=<strong-secret>
#   ITL_SERVICE_URL=https://reg.itlusions.com
#   ITL_ISO_BASE_URL=https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download

# 2. Start stack (Registration API + Caddy TLS proxy)
docker compose up -d

# 3. Download role configs from the matching GitHub Release
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh v1.9.0"
```

### Pre-register a machine (known hardware)

```bash
# Register by EK fingerprint before the machine arrives
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
# Online (downloads latest USB agent image)
cd provisioner/usb-agent
./build-usb.sh /dev/sdX

# Airgapped / offline (embeds everything needed)
./build-usb-offline.sh /dev/sdX --machine-id <uuid> --role controlplane
```

### Boot a node

1. Insert USB, power on machine.
2. USB agent detects target disk, reads TPM EK, calls Registration Service.
3. Downloads + writes role-specific ISO to disk automatically.
4. Reboots — no operator input required from this point.

### Admin approval (unknown machines)

```bash
# List pending machines
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
# Check machine status
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

> **Port requirement** — Add `8443/tcp` (or `443/tcp` if behind Caddy) to your firewall for nodes to reach the Registration Service during install.

---

## Pre-Deployment Checklist

Before deploying to production, verify:

**Infrastructure**
- [ ] Minimum 2GB RAM per node
- [ ] Minimum 40GB disk per node
- [ ] Network connectivity (1Gbps recommended)
- [ ] DNS resolution working
- [ ] Time synchronization (NTP) working
- [ ] Power redundancy for production

**Security**
- [ ] Firewall configured for Kubernetes ports
- [ ] SSH key pair generated and backed up
- [ ] Storage encryption enabled (LUKS2)
- [ ] TPM 2.0 enabled in BIOS (if available)
- [ ] Network policies planned
- [ ] TLS certificates prepared

**Talos Tools**
- [ ] talosctl v1.9.0+ installed
- [ ] kubectl v1.29.0+ installed
- [ ] kubeconfig backup location ready

## Network Planning

### Port Requirements

| Service | Port | Protocol | Direction |
|---------|------|----------|-----------|
| Kubernetes API | 6443 | TCP | Control Plane |
| etcd | 2379-2380 | TCP | Control Plane |
| kubelet | 10250 | TCP | All Nodes |
| kube-proxy | 31000-32767 | TCP/UDP | All Nodes |
| Talos API | 50000 | TCP | Management |
| DNS | 53 | UDP | All Nodes |

### Firewall Rules (Example - AWS Security Group)

```yaml
# Inbound Rules
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
  CidrIp: 10.0.0.0/24         # Talos API (management)
- IpProtocol: tcp
  FromPort: 22
  ToPort: 22
  CidrIp: 0.0.0.0/0           # SSH (restrict in production!)
- IpProtocol: tcp
  FromPort: 31000
  ToPort: 32767
  CidrIp: 0.0.0.0/0           # Service NodePort range

# Outbound: All (default)
```

## Single Node Deployment

Minimal setup for testing or small workloads.

### 1. Prepare Configuration

```bash
# Get IP address
TALOS_HOST=192.168.1.100
TALOS_ENDPOINT=192.168.1.100

export TALOS_HOST
export TALOS_ENDPOINT
```

### 2. Boot ISO

- Flash itl-talos-v1.9.0.iso to USB or boot in VM
- Machine boots to Talos console

### 3. Apply Configuration

```bash
# Apply control plane config
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure

# Wait for config to apply (30 seconds)
sleep 30
```

### 4. Bootstrap Kubernetes

```bash
# Bootstrap the cluster
talosctl bootstrap --nodes ${TALOS_HOST} \
  --endpoints ${TALOS_ENDPOINT}

# Wait for initialization (2-3 minutes)
sleep 180
```

### 5. Get kubeconfig

```bash
# Generate kubeconfig
talosctl kubeconfig . --nodes ${TALOS_HOST} \
  --endpoints ${TALOS_ENDPOINT}

# Verify access
export KUBECONFIG=${PWD}/kubeconfig
kubectl get nodes
# Should show: talos-1 Ready
```

### 6. Verify Cluster

```bash
# Check node status
talosctl health --nodes ${TALOS_HOST}

# Check Kubernetes components
kubectl get pods -A

# Expected output:
# NAMESPACE     NAME                              READY   STATUS
# kube-system   coredns-...                       1/1     Running
# kube-system   kube-apiserver-...                1/1     Running
# kube-system   kube-controller-manager-...       1/1     Running
```

**Result**: Single-node cluster ready for workloads.

## Multi-Node HA Deployment

Recommended for production.

### Architecture

```
3 Control Plane Nodes (HA etcd)
├── talos-cp1 (192.168.1.100)
├── talos-cp2 (192.168.1.101)
└── talos-cp3 (192.168.1.102)

N Worker Nodes
├── talos-w1 (192.168.1.110)
├── talos-w2 (192.168.1.111)
└── talos-w3+ (...)

Load Balancer (optional)
└── Kubernetes API: 192.168.1.200:6443
```

### 1. Prepare Control Plane Nodes

For each control plane node (repeat 3x with different IPs):

```bash
# Node 1
TALOS_HOST=192.168.1.100
TALOS_ENDPOINT=192.168.1.100

export TALOS_HOST
export TALOS_ENDPOINT

# Boot ISO
# Apply config
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure
```

### 2. Bootstrap First Control Plane

```bash
# Bootstrap with first node
talosctl bootstrap --nodes 192.168.1.100 \
  --endpoints 192.168.1.100

# Wait 3 minutes for initialization
sleep 180
```

### 3. Add Additional Control Plane Nodes

```bash
# Add second and third control plane nodes
for NODE in 192.168.1.101 192.168.1.102; do
  talosctl apply-config --nodes ${NODE} \
    --file controlplane-final.yaml \
    --insecure
done

# Wait 2 minutes for nodes to join
sleep 120
```

### 4. Add Worker Nodes

```bash
# For each worker node
for NODE in 192.168.1.110 192.168.1.111 192.168.1.112; do
  # Boot ISO first

  # Apply worker config
  talosctl apply-config --nodes ${NODE} \
    --file worker-final.yaml \
    --insecure

  # Wait for node to be ready
  sleep 30
done
```

### 5. Get kubeconfig

```bash
# Get kubeconfig from any control plane
talosctl kubeconfig . --nodes 192.168.1.100

# Verify all nodes
kubectl get nodes -w
# Should show all nodes as Ready
```

### 6. Configure Load Balancer (Optional)

If using external load balancer:

```yaml
# Example HAProxy config
frontend kubernetes-api
  bind 192.168.1.200:6443
  default_backend api_servers

backend api_servers
  balance roundrobin
  server talos-cp1 192.168.1.100:6443 check
  server talos-cp2 192.168.1.101:6443 check
  server talos-cp3 192.168.1.102:6443 check
```

Update kubeconfig:

```bash
# Edit kubeconfig
sed -i 's/192.168.1.100/192.168.1.200/g' kubeconfig

# Test access
kubectl get nodes
```

## Cloud Deployments

### AWS EC2

```bash
# Upload ISO to S3
aws s3 cp itl-talos-v1.9.0.iso s3://my-bucket/

# Create AMI from ISO
aws ec2 import-image --description "Talos Custom" \
  --license-type BYOL \
  --platform Linux

# Create security group
aws ec2 create-security-group \
  --group-name talos-sg \
  --description "Talos cluster"

# Add rules
aws ec2 authorize-security-group-ingress \
  --group-name talos-sg \
  --protocol tcp --port 6443 --cidr 10.0.0.0/8

# Launch instances
aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.large \
  --count 3 \
  --security-group-names talos-sg
```

### Azure VMs

```bash
# Create resource group
az group create -n talos-rg -l eastus

# Upload VHD
az storage blob upload --file itl-talos-v1.9.0.iso \
  --container-name vhds \
  --name talos.vhd \
  --account-name mystorageaccount

# Create image
az image create -g talos-rg -n talos-image \
  --os-type Linux \
  --source <vhd-url>

# Create VMs
az vm create -g talos-rg -n talos-1 \
  --image talos-image \
  --size Standard_B2s
```

### Google Cloud

```bash
# Create custom image
gcloud compute images create talos-image \
  --source-uri gs://my-bucket/itl-talos-v1.9.0.iso

# Create instances
gcloud compute instances create talos-1 \
  --image talos-image \
  --machine-type n1-standard-2 \
  --zone us-central1-a
```

## Post-Deployment Configuration

### 1. Deploy Storage

```bash
# Add persistent volumes
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

# Create StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
EOF
```

### 2. Install CNI (Network Plugin)

```bash
# Install Cilium
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium \
  --namespace kube-system

# Or Flannel
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```

### 3. Install Ingress Controller

```bash
# Install nginx-ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

### 4. Set Up Monitoring

```bash
# Install Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace
```

## Backup and Recovery

### Backup Configuration

```bash
# Backup all node configs
for NODE in 192.168.1.100 192.168.1.101 192.168.1.102; do
  talosctl read /etc/os-release --nodes ${NODE} > ${NODE}-config.yaml
done

# Backup kubeconfig
cp kubeconfig kubeconfig.backup

# Backup etcd
kubectl get etcd -o yaml > etcd-backup.yaml
```

### Recovery Procedure

```bash
# If control plane node fails
# 1. Boot new machine with ISO
TALOS_HOST=192.168.1.100  # New IP if different

# 2. Reapply saved config
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure

# 3. Node joins cluster automatically

# If entire cluster lost
# 1. Boot all nodes with ISO
# 2. Apply configs
# 3. Bootstrap again
talosctl bootstrap --nodes 192.168.1.100
```

## Troubleshooting

### Node Won't Boot

```bash
# Check Talos logs
talosctl logs -f -n ${TALOS_HOST}

# Check system services
talosctl services -n ${TALOS_HOST}

# Reboot node
talosctl reboot -n ${TALOS_HOST}
```

### Kubernetes API Unreachable

```bash
# Check API server status
talosctl logs -f -n ${TALOS_HOST} -k kube-apiserver

# Check etcd
talosctl logs -f -n ${TALOS_HOST} -k etcd

# Restart API server
talosctl restart -n ${TALOS_HOST} -k kube-apiserver
```

### Node Not Joining Cluster

```bash
# Check node logs
kubectl describe node <node-name>

# Check kubelet logs
talosctl logs -f -n ${TALOS_HOST} -k kubelet

# Restart kubelet
talosctl restart -n ${TALOS_HOST} -k kubelet
```

### Persistent Volume Issues

```bash
# Check PV status
kubectl get pv,pvc

# Check local path permissions
talosctl ssh -n ${TALOS_HOST}
ls -la /mnt/local-storage/
```

## Security Hardening

### Network Policies

```bash
# Deny all ingress traffic by default
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

# Allow specific traffic
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress
spec:
  podSelector:
    matchLabels:
      role: frontend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: backend
    ports:
    - protocol: TCP
      port: 8080
EOF
```

### Pod Security Standards

```bash
# Enforce Pod Security Standards
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted
```

### RBAC Configuration

```bash
# Create service account
kubectl create serviceaccount app-user

# Create role
kubectl create role app-role --verb=get,list --resource=pods

# Bind role to service account
kubectl create rolebinding app-rolebinding \
  --clusterrole=app-role \
  --serviceaccount=default:app-user
```

## Production Checklist

Before going live:

- [ ] All nodes passing health checks
- [ ] All Kubernetes components running
- [ ] Persistent storage configured
- [ ] Network CNI installed
- [ ] Backup strategy implemented
- [ ] Monitoring and alerting configured
- [ ] Log aggregation set up
- [ ] Network policies configured
- [ ] RBAC roles defined
- [ ] Disaster recovery tested

## Performance Tuning

### Node Kernel Parameters

```bash
# SSH to node
talosctl ssh -n ${TALOS_HOST}

# View current settings
cat /proc/sys/net/core/somaxconn
cat /proc/sys/net/ipv4/tcp_max_syn_backlog

# Note: Talos uses immutable config, changes via machine config
```

### Kubernetes API Server Tuning

Edit controlplane-final.yaml:

```yaml
machine:
  kubelet:
    systemReserved:
      cpu: 100m
      memory: 100Mi
```

## Version Upgrades

### Upgrade Talos

```bash
# Check current version
talosctl version

# Plan upgrade
talosctl upgrade --dry-run

# Perform upgrade
talosctl upgrade --image ghcr.io/siderolabs/talos:v1.10.0
```

### Upgrade Kubernetes

Kubernetes upgrades automatically with Talos upgrades.

## Support and Resources

- Documentation: See docs/ folder
- Talos Docs: https://www.talos.dev/
- Kubernetes Docs: https://kubernetes.io/docs/
- GitHub Issues: Report problems

---

**Version**: 1.0.0
**Talos**: v1.9.0
**Status**: Production Ready
