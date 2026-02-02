# Quickstart: Deploy Talos OS in 5 Minutes

Get Talos Linux with custom branding and security hardening running in minutes.

## Prerequisites

- GitHub account
- Access to download releases
- One of: VM, bare metal, cloud instance (2 CPU, 2GB RAM minimum)

## Step 1: Create a Release (2 minutes)

Open the repository on GitHub and create a tag:

```bash
git clone https://github.com/ITlusions/ITL.Talos.HardenedOS.git
cd ITL.Talos.HardenedOS
git tag v1.0.0
git push origin v1.0.0
```

Visit GitHub Actions and watch "Build Custom Talos OS" start automatically.

## Step 2: Wait for Build (30 seconds active, 40 minutes passive)

The pipeline will:
1. Build custom branding (5 min)
2. Build extensions (10 min)
3. Generate Talos configs (5 min)
4. Create ISO image (15 min)
5. Publish release (1 min)

Watch build progress:

```bash
git log --oneline | head
# Should show v1.0.0 tag
```

## Step 3: Download Artifacts

Go to GitHub Releases and find version v1.0.0:

```
ITL.Talos.HardenedOS/releases/tag/v1.0.0
```

Download these files:
- itl-talos-v1.9.0.iso (bootable image, ~500MB)
- controlplane-final.yaml (control plane config)
- worker-final.yaml (worker config)

## Step 4: Boot the ISO (1 minute)

### On VM (KVM/VirtualBox)

Create a 40GB disk, attach ISO as boot media, power on.

### On Bare Metal

Create bootable USB:

```bash
# Linux/Mac
sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress

# Windows - use Rufus (https://rufus.ie/)
```

Insert USB and boot from it.

### On Cloud

Upload ISO to cloud storage, create VM from custom image.

## Step 5: Configure and Start (1 minute)

Machine boots to Talos welcome screen:

```
ITL Custom Talos Linux v1.9.0
Custom Branding: Enabled
Security: Hardened
Status: Ready for Configuration
```

Open terminal and configure:

```bash
# From your admin machine with internet access
export TALOS_HOST=<machine-ip>
export TALOS_ENDPOINT=<machine-ip>

# Apply control plane config
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure

# Bootstrap Kubernetes
talosctl bootstrap --nodes ${TALOS_HOST} --endpoints ${TALOS_ENDPOINT}

# Verify cluster
talosctl health
talosctl kubeconfig .
kubectl get nodes
```

## Result

After 2-3 minutes:

```
NAME       STATUS   ROLES            AGE     VERSION
talos-1    Ready    master,worker    2m      v1.29.0
```

Your Talos cluster with custom branding and security hardening is ready!

## Next Steps

### Add More Nodes

Repeat Step 4-5 with worker-final.yaml:

```bash
talosctl apply-config --nodes <new-worker-ip> \
  --file worker-final.yaml \
  --insecure

# Join cluster
talosctl health --nodes <new-worker-ip>
```

### Deploy Applications

```bash
kubectl apply -f deployment.yaml
kubectl get pods
```

### Check Logs

```bash
# Node logs
talosctl logs -f -n <node-ip>

# Kubernetes
kubectl logs -n kube-system -f etcd-talos-1
```

### Update Configuration

```bash
# Edit config
sed -i 's/old/new/g' controlplane-final.yaml

# Apply updates
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml
```

## Common Issues

### Can't Download Release

- Check GitHub permissions
- Verify internet connectivity
- Try releasing again with different tag

### ISO Won't Boot

- Use bootable media creation tool (Rufus, Etcher)
- Verify ISO file integrity (check SHA256)
- Try UEFI mode on older hardware

### Configuration Application Fails

- Add --insecure flag for initial boot
- Verify IP address is correct
- Check machine has network access

### Kubernetes Won't Start

- Wait 2-3 minutes for etcd startup
- Check disk space (40GB minimum)
- Review system logs: `talosctl logs -f`

### Lost SSH Access

- Boot into Talos again
- Reapply configuration with --force:

```bash
talosctl apply-config --nodes ${TALOS_HOST} \
  --file controlplane-final.yaml \
  --insecure --force
```

## Installation Methods Summary

| Method | Time | Complexity | Use Case |
|--------|------|-----------|----------|
| ISO Boot | 5 min | Low | Single machine quick start |
| Cloud Upload | 10 min | Medium | Cloud providers (AWS, Azure) |
| PXE Boot | 15 min | High | Large deployments |
| Container Lab | 2 min | Low | Testing/learning |

## What's Included

**Talos Linux v1.9.0**
- Minimal OS (~100MB)
- Immutable infrastructure
- Declarative configuration

**Custom Branding**
- Console banners
- Boot messages
- Custom logos

**Security Hardening**
- LUKS2 encryption
- TPM 2.0 support
- Kernel hardening
- Network policies

**Extensions**
- gVisor runtime (sandboxing)
- Intel microcode (CPU updates)
- Custom drivers
- Security tools

## Kubernetes Features

After bootstrap:

```bash
# Check cluster health
kubectl get nodes -w

# Check system pods
kubectl get pods -A

# Check persistent volumes
kubectl get pv

# Check storage classes
kubectl get storageclasses
```

Your cluster is ready for:
- Microservices
- Stateless applications
- Stateful databases (with PVC)
- Custom workloads

## Full Documentation

- Detailed setup: See 03-SIMPLIFIED_SETUP.md
- Pipeline explanation: See 04-BUILD_PIPELINE.md
- Deployment guide: See 06-DEPLOYMENT.md
- Container usage: See 07-CONTAINER_USAGE.md

## Support Resources

- GitHub Issues: https://github.com/ITlusions/ITL.Talos.HardenedOS/issues
- Talos Docs: https://www.talos.dev/
- Kubernetes Docs: https://kubernetes.io/docs/

## Version Info

- Talos: v1.9.0
- Kubernetes: 1.29.0
- Release: v1.0.0
- Updated: 2024

---

**Estimated Total Time**: 5 minutes

**Done!** Your Talos cluster with custom branding is running.
