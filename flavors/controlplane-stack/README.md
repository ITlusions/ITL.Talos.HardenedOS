# ITL Talos Flavor — ControlPlane Stack

Purpose-built Talos OS configuration for running the
[ITL ControlPlane Stack](https://github.com/itlusions/ITL.ControlPanel.Stack).

Layered on top of the base `ITL.Talos.HardenedOS` extensions and patches,
this flavor adds everything a ControlPlane Stack node needs out of the box.

---

## What this flavor provides

| Component | Detail |
|-----------|--------|
| **StorageClass** | Rancher `local-path-provisioner` v0.0.28 as default |
| **CNI** | Cilium v1.15.6 (replaces Flannel, enables NetworkPolicy) |
| **Ingress** | Nginx Ingress Controller in `itl-ingress` namespace |
| **Namespaces** | `itl-controlplane`, `itl-monitoring`, `itl-ingress` |
| **NetworkPolicy** | Default-deny + allow rules for `itl-controlplane` namespace |
| **OIDC** | Keycloak issuer at `https://auth.itlusions.com/realms/itl` |
| **RBAC** | `itl-platform-admins` → `cluster-admin`, `itl-platform-viewers` → `view` |
| **Registry mirrors** | `ghcr.io`, `docker.io`, `quay.io` |
| **Node labels** | `itl.io/flavor`, `itl.io/role` (infra/app), `itl.io/managed-by` |

---

## Node roles

Workers are split into two roles via `machine.nodeLabels` in the Talos config:

| Role | Label | Runs |
|------|-------|------|
| `infra` | `itl.io/role=infra` | PostgreSQL, Neo4j, Redis, RabbitMQ |
| `app`   | `itl.io/role=app`   | API Gateway, Core/Identity/IAM providers, Portals |

Generated configs:

- `controlplane-final.yaml` — control-plane nodes
- `worker-infra-final.yaml` — stateful infra nodes
- `worker-app-final.yaml`   — stateless app nodes

---

## Storage sizing

Defaults in `helm-values-overlay.yaml`:

| Service | PVC size |
|---------|----------|
| PostgreSQL | 20 Gi |
| Neo4j | 20 Gi |
| Redis | 4 Gi |
| RabbitMQ | 8 Gi |
| **Total** | **~52 Gi** |

All PVCs use `storageClass: local-path` (ReadWriteOnce).

---

## Quick start

### 1. Trigger the flavor build

```bash
# Tag format: v<semver>-cpstack
git tag v1.0.0-cpstack
git push origin v1.0.0-cpstack
```

The [GitHub Actions workflow](../../.github/workflows/build-controlplane-stack-flavor.yaml)
builds extensions, applies all patches, and uploads artifacts.

### 2. Download and apply configs

```bash
# Download the release tarball and extract
tar -xzf itl-talos-controlplane-stack-v1.0.0-cpstack.tar.gz

# Apply to each node type
talosctl apply-config --nodes <cp-ip>    --file controlplane-final.yaml
talosctl apply-config --nodes <infra-ip> --file worker-infra-final.yaml
talosctl apply-config --nodes <app-ip>   --file worker-app-final.yaml
```

### 3. Bootstrap the cluster

```bash
talosctl bootstrap --nodes <cp-ip>
talosctl kubeconfig --nodes <cp-ip> --force
```

### 4. Deploy the ControlPlane Stack

```bash
# Create GHCR pull secret
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<PAT> \
  -n itl-controlplane

# Install via Helm
helm upgrade --install itl-controlplane ./helm \
  -f helm/values.yaml \
  -f helm-values-overlay.yaml \
  --namespace itl-controlplane \
  --create-namespace
```

---

## Patch layering order

```
1. config/patches/branding-patch.yaml        (base)
2. config/patches/security-hardening.yaml    (base)
3. config/patches/network-hardening.yaml     (base)
4. config/patches/oidc-patch.yaml            (base, cp only)
5. flavors/controlplane-stack/patches/cp-storage.yaml
6. flavors/controlplane-stack/patches/cp-networking.yaml
7. flavors/controlplane-stack/patches/cp-node-labels.yaml
8. flavors/controlplane-stack/patches/cp-registry.yaml
9. flavors/controlplane-stack/patches/cp-oidc.yaml        (cp only)
```

---

## Files

```
flavors/controlplane-stack/
  README.md                    (this file)
  helm-values-overlay.yaml     Helm values for deploying the stack on Talos
  patches/
    cp-storage.yaml            Kernel modules + kubelet mounts + local-path-provisioner
    cp-networking.yaml         Pod/service CIDRs + Cilium CNI
    cp-node-labels.yaml        Node labels + kubelet GC/resource tuning
    cp-registry.yaml           Registry mirrors (ghcr.io, docker.io, quay.io)
    cp-oidc.yaml               Keycloak OIDC override + inline RBAC bindings
  manifests/
    00-namespaces.yaml         itl-controlplane, itl-monitoring, itl-ingress
    02-network-policies.yaml   Default-deny + allow rules
    03-ingress-nginx.yaml      Nginx security ConfigMaps
```
