# CI/CD Pipeline Deep Dive

Complete architecture and implementation details of the GitHub Actions build pipeline.

## Architecture Overview

```
GitHub Event (Tag Push: v*.*)
           ↓
Workflow Trigger: build-talos-hardened.yaml
           ↓
Job Matrix: build-branding, build-extensions, build-installer
           ↓
           generate-configs, build-iso
           ↓
           create-release
           ↓
GitHub Release with Artifacts
```

## Workflow File Structure

Location: `.github/workflows/build-talos-hardened.yaml`

### Trigger Configuration

```yaml
on:
  push:
    tags:
      - 'v*.*'  # Match semantic versioning: v1.0.0, v2.1.3, etc.

env:
  REGISTRY: ghcr.io
  OWNER: ${{ github.repository_owner }}
  TALOS_VERSION: v1.9.0
  KUBE_VERSION: 1.29.0
```

Trigger rules:
- Only fires on tags matching v*.* pattern
- Ignores other pushes and pull requests
- Automatically extracts version from tag

### Workflow Permissions

```yaml
permissions:
  contents: write          # Create releases
  packages: write          # Push to registry
  id-token: write          # For OIDC (optional)
```

## Job Pipeline Details

### Job 1: build-branding (5 minutes)

Creates console and boot branding assets.

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
          
          # ASCII art banner
          figlet -f banner "ITL Custom Talos" > branding/output/banner.txt
          
          # Convert to kernel format
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

**Outputs**:
- Docker image in registry
- SHA256 digest for verification
- Build cache for subsequent jobs

**Success criteria**:
- Docker image pushed successfully
- Image size < 100MB
- No layer caching issues

### Job 2: build-extensions (10 minutes)

Builds security and custom extensions.

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

**Parallel builds**:
- security extension
- custom extensions

**Each extension includes**:
- Security hardening
- Custom drivers
- Kernel modules
- Runtime tools

### Job 3: build-installer (5 minutes)

Creates custom Talos installer image.

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

**Depends on**: 
- build-branding (gets branding image)
- build-extensions (gets extensions)

**Creates**:
- Talos installer with extensions
- Compatible with talosctl
- Ready for ISO generation

### Job 4: generate-configs (5 minutes)

Generates Talos configuration files.

```yaml
  generate-configs:
    runs-on: ubuntu-latest
    needs: build-installer
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Generate Configurations
        run: |
          docker run --rm \
            -v ${PWD}/config:/workspace/config \
            ${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-installer:${{ github.ref_name }} \
            /bin/sh -c '
              # Generate base configs
              talosctl gen config itl-talos \
                https://itl-talos:6443 \
                --output-dir /workspace/config/output
              
              # Apply branding patch
              yq eval-all "select(fileIndex==0) * select(fileIndex==1)" \
                /workspace/config/output/controlplane.yaml \
                /workspace/config/patches/branding-patch.yaml > \
                /workspace/config/output/controlplane-final.yaml
              
              # Apply security patch
              yq eval-all "select(fileIndex==0) * select(fileIndex==1)" \
                /workspace/config/output/controlplane-final.yaml \
                /workspace/config/patches/security-hardening.yaml > \
                /workspace/config/output/controlplane-final-secure.yaml
              
              # Generate worker config
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

**Process**:
1. Container pulls installer image
2. Runs talosctl gen config
3. Applies branding patches
4. Applies security hardening
5. Validates all YAML
6. Stores configs for next jobs

**Output artifacts**:
- controlplane-final.yaml
- worker-final.yaml
- SHA256 checksums

### Job 5: build-iso (15 minutes)

Creates bootable ISO image.

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
          # Use Talos Image Factory to generate ISO
          curl -X POST -s \
            -F arch=amd64 \
            -F version=${{ env.TALOS_VERSION }} \
            -F extensions=siderolabs/gvisor:latest \
            -F extensions=${{ env.REGISTRY }}/${{ env.OWNER }}/itl-talos-hardened-os-branding:${{ github.ref_name }} \
            -F customization.meta.key1=value1 \
            https://api.talos.dev/image \
            > talos-image.tar.gz
          
          # Extract ISO
          tar -xzf talos-image.tar.gz
          
          # Rename with version
          mv talos-image.iso itl-talos-${{ env.TALOS_VERSION }}.iso
          
          # Generate checksum
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

**ISO includes**:
- Talos Linux v1.9.0
- Custom branding extension
- Security hardening
- gVisor runtime

**Size**: ~500MB

### Job 6: create-release (2 minutes)

Creates GitHub release with all artifacts.

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
            - Custom Branding
            - Security Hardening
            - gVisor Runtime
            
            ### Files
            - `itl-talos-v1.9.0.iso` - Bootable image
            - `controlplane-final.yaml` - Control plane config
            - `worker-final.yaml` - Worker node config
            - `.sha256` - Checksums for verification
            
            ### Installation
            1. Download ISO
            2. Create bootable media
            3. Boot machine
            4. Apply configuration with talosctl
            
            ### Support
            - GitHub Issues: Report problems
            - Documentation: See docs/ folder
            
            ---
            Built by GitHub Actions
            Build ID: ${{ github.run_id }}
          artifacts: artifacts/**/*
          token: ${{ secrets.GITHUB_TOKEN }}
          draft: false
          prerelease: false
```

**Creates**:
- GitHub Release page
- Attaches all artifacts
- Generates release notes
- Makes downloadable to users

## Data Flow Between Jobs

```
build-branding (outputs: image tag)
                ↓
            build-extensions ← uses image tag
                ↓
build-installer ← uses extension images
                ↓
            generate-configs ← uses installer image
                ↓
            build-iso ← uses configs and installer
                ↓
            create-release ← collects all artifacts
```

## Environment Variables

Global to workflow:

| Variable | Value | Usage |
|----------|-------|-------|
| REGISTRY | ghcr.io | Container registry domain |
| OWNER | github.repository_owner | GitHub username/org |
| TALOS_VERSION | v1.9.0 | Talos OS version to build |
| KUBE_VERSION | 1.29.0 | Kubernetes version |

Can be customized per release by:
1. Creating release notes
2. Editing workflow file
3. Updating environment section

## Caching Strategy

### Docker Layer Caching

```yaml
cache-from: type=registry
cache-to: type=inline
```

- Uses previous Docker builds
- Speeds up rebuild (2-3x faster)
- Shares cache across workflow runs

### Artifact Caching

```yaml
uses: actions/upload-artifact@v4
with:
  retention-days: 30
```

- Keeps configs for 30 days
- Available for re-release if needed
- Reduces storage costs

## Error Handling

### Job Dependencies

```yaml
needs: 
  - build-branding
  - build-extensions
```

- Failed dependency stops downstream jobs
- Workflow clearly shows failure point
- No wasted resources on doomed jobs

### Validation Steps

```yaml
- name: Validate Configurations
  run: |
    talosctl validate --file config.yaml
```

- Catches errors early
- Prevents invalid releases
- Clear error messages to developer

## Customization Points

### Change Talos Version

Edit `.github/workflows/build-talos-hardened.yaml`:

```yaml
env:
  TALOS_VERSION: v1.10.0  # Change this
```

### Add Custom Extensions

In `generate-configs` job:

```yaml
-F extensions=${{ env.REGISTRY }}/${{ env.OWNER }}/my-custom-extension:latest
```

### Modify Branding

Edit `config/patches/branding-patch.yaml`:

```yaml
machine:
  system:
    logging:
      kernel:
        level: info
```

### Change Kubernetes Version

Edit `.github/workflows/build-talos-hardened.yaml`:

```yaml
env:
  KUBE_VERSION: 1.30.0  # Change this
```

## Monitoring and Debugging

### View Logs

GitHub Actions tab → Workflow → Job → View logs

### Debug Mode

Add to step:

```yaml
- name: Debug
  run: |
    set -x  # Print all commands
    ls -la
    docker images
    env | grep TALOS
```

### Upload Debug Artifacts

```yaml
- name: Upload Debug Info
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: debug-logs
    path: /tmp/build-logs/
```

## Performance Metrics

Expected build times:

| Job | Time | CPU | Memory |
|-----|------|-----|--------|
| build-branding | 5 min | 2 | 2GB |
| build-extensions | 10 min | 4 | 4GB |
| build-installer | 5 min | 2 | 2GB |
| generate-configs | 5 min | 1 | 1GB |
| build-iso | 15 min | 4 | 4GB |
| create-release | 2 min | 1 | 1GB |
| **Total** | **~40 min** | | |

## Cost Analysis

GitHub Actions free tier:
- 2000 free minutes/month
- 20 builds @ 40 minutes = 800 minutes
- Well within free tier

Commercial usage:
- Private repos charged per minute
- Estimated: 1.5 hours/release
- Cost: minimal for typical usage

## Security Considerations

### Secrets Management

GITHUB_TOKEN is automatically available. For custom secrets:

```yaml
env:
  DOCKER_REGISTRY: ${{ secrets.DOCKER_REGISTRY }}
  DOCKER_USER: ${{ secrets.DOCKER_USER }}
```

### Artifact Security

Artifacts stored for 30 days, then auto-deleted.

Upload only to trusted registries:

```yaml
- name: Push Only on Main Branch
  if: github.ref == 'refs/heads/main'
  run: docker push ${{ env.REGISTRY }}/...
```

## Related Documentation

- Build Pipeline Overview: See 04-BUILD_PIPELINE.md
- Quick Reference: See 01-QUICK_REFERENCE.md
- Setup Guide: See 03-SIMPLIFIED_SETUP.md

---

**Version**: 1.0.0
**Last Updated**: 2024
**Status**: Production
