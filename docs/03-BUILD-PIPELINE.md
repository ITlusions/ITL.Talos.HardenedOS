# Build Pipeline

GitHub Actions pipeline that builds ITL Talos OS from source: container images, configurations, ISO, and release artifacts.

> **Trigger a build**: `git tag v1.x.x && git push origin v1.x.x`  
> **Total time**: ~45 minutes | See [01-QUICK_REFERENCE.md](01-QUICK_REFERENCE.md) for the cheat sheet.

## Architecture Overview

```
GitHub Event (Tag Push: v*.*)
           ↓
Workflow: build-talos-hardened.yaml
           ↓
build-branding → build-extensions → build-installer
                                          ↓
                                   generate-configs
                                          ↓
                                      build-iso
                                          ↓
                                    create-release
                                          ↓
                             GitHub Release with Artifacts
```

**Artifacts produced:**
- `itl-talos-v1.9.0.iso` — Bootable image (~500MB)
- `controlplane-final.yaml` — Control plane configuration
- `worker-final.yaml` — Worker node configuration
- Docker images in `ghcr.io/itlusions/`

## Workflow Configuration

### Trigger

```yaml
on:
  push:
    tags:
      - 'v*.*'  # Matches v1.0.0, v2.1.3, etc.

env:
  REGISTRY: ghcr.io
  OWNER: ${{ github.repository_owner }}
  TALOS_VERSION: v1.9.0
  KUBE_VERSION: 1.29.0
```

Only fires on version tags — ignores branch pushes and pull requests.

### Permissions

```yaml
permissions:
  contents: write          # Create releases
  packages: write          # Push to registry
  id-token: write          # OIDC (optional)
```

## Pipeline Jobs

### Job 1: build-branding (5 minutes)

Creates console and boot branding assets, builds and pushes the branding Docker image.

```yaml
jobs:
  build-branding:
    runs-on: ubuntu-latest
    outputs:
      branding-tag: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4

      - name: Generate Branding
        run: |
          mkdir -p branding/output
          figlet -f banner "ITL Custom Talos" > branding/output/banner.txt
          cat branding/output/banner.txt

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push Branding
        uses: docker/build-push-action@v5
        with:
          context: ./extensions/itl-branding
          file: ./build/Dockerfile.branding
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-branding:${{ github.ref_name }}
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-branding:latest
          cache-from: type=registry
          cache-to: type=inline
```

**Outputs**: Docker image + SHA256 digest. Image size target: < 100MB.

---

### Job 2: build-extensions (10 minutes)

Builds security and custom extensions in parallel using a matrix strategy.

```yaml
  build-extensions:
    runs-on: ubuntu-latest
    needs: build-branding
    strategy:
      matrix:
        extension:
          - itl-security
          - itl-custom
    steps:
      - uses: actions/checkout@v4

      - name: Log in to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push Extension
        uses: docker/build-push-action@v5
        with:
          context: ./extensions/${{ matrix.extension }}
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-${{ matrix.extension }}:${{ github.ref_name }}
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-${{ matrix.extension }}:latest
          build-args: |
            TALOS_VERSION=${{ env.TALOS_VERSION }}
            GVISOR_VERSION=latest
```

**Each extension includes**: security hardening, custom drivers, kernel modules, runtime tools.

---

### Job 3: build-installer (5 minutes)

Assembles the custom Talos installer image from branding + extensions.

```yaml
  build-installer:
    runs-on: ubuntu-latest
    needs:
      - build-branding
      - build-extensions
    steps:
      - uses: actions/checkout@v4

      - name: Log in to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push Installer
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./build/Dockerfile.installer
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-installer:${{ github.ref_name }}
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-installer:latest
          build-args: |
            TALOS_VERSION=${{ env.TALOS_VERSION }}
            BRANDING_IMAGE=${{ needs.build-branding.outputs.branding-tag }}
          cache-from: type=registry
          cache-to: type=inline
```

---

### Job 4: generate-configs (5 minutes)

Runs talosctl inside the installer container to generate and patch configuration YAML files.

```yaml
  generate-configs:
    runs-on: ubuntu-latest
    needs: build-installer
    steps:
      - uses: actions/checkout@v4

      - name: Generate Configurations
        run: |
          docker run --rm \
            -v ${PWD}/config:/workspace/config \
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-installer:${{ github.ref_name }} \
            /bin/sh -c '
              talosctl gen config itl-talos \
                https://itl-talos:6443 \
                --output-dir /workspace/config/output

              yq eval-all "select(fileIndex==0) * select(fileIndex==1)" \
                /workspace/config/output/controlplane.yaml \
                /workspace/config/patches/branding-patch.yaml > \
                /workspace/config/output/controlplane-final.yaml

              yq eval-all "select(fileIndex==0) * select(fileIndex==1)" \
                /workspace/config/output/controlplane-final.yaml \
                /workspace/config/patches/security-hardening.yaml > \
                /workspace/config/output/controlplane-final-secure.yaml

              cp /workspace/config/output/worker.yaml \
                /workspace/config/output/worker-final.yaml
            '

      - name: Validate Configurations
        run: |
          docker run --rm \
            -v ${PWD}/config:/workspace/config \
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-installer:${{ github.ref_name }} \
            /bin/sh -c '
              talosctl validate --file /workspace/config/output/controlplane-final.yaml
              talosctl validate --file /workspace/config/output/worker-final.yaml
            '

      - name: Upload Configs
        uses: actions/upload-artifact@v4
        with:
          name: talos-configs
          path: config/output/
          retention-days: 30
```

**Process**: gen config → apply branding patch → apply security patch → validate → store artifact.

---

### Job 5: build-iso (15 minutes)

Calls the Talos Image Factory API to produce the bootable ISO with all extensions embedded.

```yaml
  build-iso:
    runs-on: ubuntu-latest
    needs: generate-configs
    steps:
      - uses: actions/checkout@v4

      - name: Download Configs
        uses: actions/download-artifact@v4
        with:
          name: talos-configs
          path: config/output/

      - name: Build ISO
        run: |
          curl -X POST -s \
            -F arch=amd64 \
            -F version=${{ env.TALOS_VERSION }} \
            -F extensions=siderolabs/gvisor:latest \
            -F extensions=${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-branding:${{ github.ref_name }} \
            -F customization.meta.key1=value1 \
            https://api.talos.dev/image \
            > talos-image.tar.gz

          tar -xzf talos-image.tar.gz
          mv talos-image.iso itl-talos-${{ env.TALOS_VERSION }}.iso
          sha256sum itl-talos-${{ env.TALOS_VERSION }}.iso > itl-talos-${{ env.TALOS_VERSION }}.iso.sha256

      - name: Upload ISO
        uses: actions/upload-artifact@v4
        with:
          name: talos-iso
          path: |
            itl-talos-*.iso
            itl-talos-*.iso.sha256
          retention-days: 90
```

**ISO includes**: Talos Linux v1.9.0, custom branding, security hardening, gVisor runtime (~500MB).

---

### Job 6: create-release (2 minutes)

Creates the GitHub Release and attaches all build artifacts.

```yaml
  create-release:
    runs-on: ubuntu-latest
    needs:
      - build-iso
      - generate-configs
    steps:
      - uses: actions/checkout@v4

      - name: Download All Artifacts
        uses: actions/download-artifact@v4
        with:
          path: artifacts/

      - name: Create Release
        uses: ncipollo/release-action@v1
        with:
          tag: ${{ github.ref_name }}
          name: ITL Talos ${{ github.ref_name }}
          body: |
            ## Release: ${{ github.ref_name }}

            Custom Talos Linux with branding and security hardening.

            ### Included
            - Talos OS: ${{ env.TALOS_VERSION }}
            - Kubernetes: ${{ env.KUBE_VERSION }}
            - Custom Branding, Security Hardening, gVisor Runtime

            ### Files
            - `itl-talos-v1.9.0.iso` — Bootable image
            - `controlplane-final.yaml` — Control plane config
            - `worker-final.yaml` — Worker node config
            - `.sha256` — Checksums

            ---
            Build ID: ${{ github.run_id }}
          artifacts: artifacts/**/*
          token: ${{ secrets.GITHUB_TOKEN }}
          draft: false
          prerelease: false
```

## Data Flow Between Jobs

```
build-branding (image tag output)
        ↓
build-extensions ← uses branding image tag
        ↓
build-installer  ← uses extension images
        ↓
generate-configs ← uses installer image
        ↓
build-iso        ← uses configs + installer
        ↓
create-release   ← collects all artifacts
```

## Configuration

### Environment Variables

| Variable | Default | Usage |
|----------|---------|-------|
| `REGISTRY` | `ghcr.io` | Container registry domain |
| `OWNER` | `github.repository_owner` | GitHub username/org |
| `TALOS_VERSION` | `v1.9.0` | Talos OS version to build |
| `KUBE_VERSION` | `1.29.0` | Kubernetes version |

### Customization Points

**Change Talos version** — edit `.github/workflows/build-talos-hardened.yaml`:
```yaml
env:
  TALOS_VERSION: v1.10.0
```

**Change Kubernetes version**:
```yaml
env:
  KUBE_VERSION: 1.30.0
```

**Add custom extensions** — in `build-iso` job:
```yaml
-F extensions=${{ env.REGISTRY }}/${{ env.OWNER }}/my-extension:latest
```

**Modify branding** — edit `config/patches/branding-patch.yaml`:
```yaml
machine:
  system:
    logging:
      kernel:
        level: info
```

## Operations

### Caching Strategy

**Docker layer caching** (2-3× speedup on rebuild):
```yaml
cache-from: type=registry
cache-to: type=inline
```

**Artifact retention**:
- Configs: 30 days
- ISO: 90 days

### Error Handling

Failed job dependencies stop all downstream jobs immediately — no wasted resources:
```yaml
needs:
  - build-branding
  - build-extensions
```

Validation steps catch config errors before they produce broken releases:
```yaml
- name: Validate Configurations
  run: talosctl validate --file config.yaml
```

### Monitoring and Debugging

**View build logs**: GitHub Actions tab → Workflow run → select job → expand steps.

**Enable debug output** — add to any step:
```yaml
- name: Debug
  run: |
    set -x
    ls -la
    docker images
    env | grep TALOS
```

**Collect debug artifacts on failure**:
```yaml
- name: Upload Debug Info
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: debug-logs
    path: /tmp/build-logs/
```
