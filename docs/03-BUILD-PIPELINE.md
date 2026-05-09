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

### Job 3: build-iso (15 minutes)

Calls `ghcr.io/siderolabs/imager` to bake the extension OCI images into a bootable ISO.
This is the job that actually fuses the OS with ITL customizations.

```yaml
  build-iso:
    runs-on: ubuntu-latest
    needs: build-extensions
    steps:
      - uses: actions/checkout@v4

      - name: Run imager
        run: |
          docker run --rm \
            -v /dev:/dev \
            -v ${PWD}/output:/output \
            --privileged \
            ghcr.io/siderolabs/imager:${{ env.TALOS_VERSION }} \
              iso \
              --arch amd64 \
              --system-extension-image ghcr.io/itlusions/itl-talos-hardened-os-branding:${{ github.ref_name }} \
              --system-extension-image ghcr.io/itlusions/itl-talos-hardened-os-security:${{ github.ref_name }} \
              --system-extension-image ghcr.io/itlusions/itl-talos-tpm-register:${{ github.ref_name }} \
              --output /output

          mv output/metal-amd64.iso itl-talos-${{ env.TALOS_VERSION }}.iso
          sha256sum itl-talos-${{ env.TALOS_VERSION }}.iso > itl-talos-${{ env.TALOS_VERSION }}.iso.sha256
          md5sum   itl-talos-${{ env.TALOS_VERSION }}.iso > itl-talos-${{ env.TALOS_VERSION }}.iso.md5

      - name: Upload ISO
        uses: actions/upload-artifact@v4
        with:
          name: talos-iso
          path: |
            itl-talos-*.iso
            itl-talos-*.iso.sha256
            itl-talos-*.iso.md5
          retention-days: 90
```

**ISO includes**: Talos Linux v1.9.0, all three ITL extensions baked in at the filesystem level.
No network access is required on nodes during installation — the OS is fully self-contained.

---

### Job 4: create-release (2 minutes)

Creates the GitHub Release and attaches the ISO.

```yaml
  create-release:
    runs-on: ubuntu-latest
    needs: build-iso
    steps:
      - uses: actions/checkout@v4

      - name: Download ISO artifact
        uses: actions/download-artifact@v4
        with:
          name: talos-iso
          path: artifacts/

      - name: Create Release
        uses: ncipollo/release-action@v1
        with:
          tag: ${{ github.ref_name }}
          name: ITL Talos ${{ github.ref_name }}
          body: |
            ## Release: ${{ github.ref_name }}

            Custom Talos Linux with branding, security hardening, and TPM registration.

            ### Included
            - Talos OS: ${{ env.TALOS_VERSION }}
            - Extensions: itl-branding, itl-security, itl-tpm-register

            ### Files
            - `itl-talos-v1.9.0.iso` — Bootable image
            - `.sha256` / `.md5` — Checksums
          artifacts: artifacts/**/*
          token: ${{ secrets.GITHUB_TOKEN }}
          draft: false
          prerelease: false
```

## Data Flow Between Jobs

```
build-extensions (push 3 extension images)
        ↓
build-iso  ← pulls extensions, runs siderolabs/imager, produces ISO
        ↓
create-release  ← attaches ISO to GitHub Release
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
