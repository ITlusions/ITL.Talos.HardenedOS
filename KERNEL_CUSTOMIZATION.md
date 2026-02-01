# Kernel Customization Guide

This guide explains how to enable and customize the Linux kernel for ITL Talos HardenedOS.

## Overview

The build pipeline supports two modes:

1. **Simple Mode (Default)**: Uses standard Talos kernel with ITL branding overlay
2. **Advanced Mode**: Builds custom kernel with modifications + ITL branding

## Enabling Kernel Customization

### Step 1: Enable Custom Kernel Build

Set the repository variable `BUILD_CUSTOM_KERNEL` to `true`:

```bash
gh variable set BUILD_CUSTOM_KERNEL --body "true"
```

Or via GitHub UI:
1. Go to repository Settings > Secrets and variables > Actions > Variables
2. Click "New repository variable"
3. Name: `BUILD_CUSTOM_KERNEL`
4. Value: `true`

### Step 2: Modify Kernel Configuration (Optional)

The pipeline uses the default Talos kernel configuration. To customize:

#### Option A: Direct Config File Edit

1. Clone siderolabs/pkgs repository locally:
   ```bash
   git clone https://github.com/siderolabs/pkgs.git
   cd pkgs
   git checkout release-1.9
   ```

2. Edit kernel config:
   ```bash
   # For AMD64
   nano kernel/build/config-amd64
   
   # Add your custom kernel options
   # Example: CONFIG_CUSTOM_MODULE=y
   ```

3. Clean up config (recommended):
   ```bash
   make kernel-olddefconfig
   ```

4. Commit and push to a fork, then modify workflow to use your fork

#### Option B: Use Kernel Menuconfig

1. In the workflow, modify the "Apply kernel customizations" step:
   ```yaml
   - name: Apply kernel customizations
     run: |
       cd pkgs
       make kernel-menuconfig  # Opens interactive config UI
       make kernel-olddefconfig
   ```

#### Option C: Apply Config Patches in Workflow

Modify the workflow step to apply patches:

```yaml
- name: Apply kernel customizations
  run: |
    cd pkgs
    
    # Enable custom kernel options
    echo "CONFIG_SECURITY_LOCKDOWN_LSM=y" >> kernel/build/config-amd64
    echo "CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y" >> kernel/build/config-amd64
    echo "CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y" >> kernel/build/config-amd64
    
    # Disable options
    sed -i 's/CONFIG_UNWANTED_OPTION=y/# CONFIG_UNWANTED_OPTION is not set/' kernel/build/config-amd64
    
    make kernel-olddefconfig
```

## What Gets Built

When `BUILD_CUSTOM_KERNEL=true`:

1. **Custom Kernel Container** (`ghcr.io/itlusions/kernel:TAG`)
   - Built from siderolabs/pkgs
   - Pushed to GitHub Container Registry
   - Contains kernel + modules

2. **Custom Kernel & Initramfs** 
   - Built in Talos source with `PKG_KERNEL` reference
   - Includes your kernel modifications
   - Output: `_out/vmlinuz-amd64`, `_out/initramfs-amd64.xz`

3. **Custom Imager Container** (`ghcr.io/itlusions/imager:TAG`)
   - Built with custom kernel reference
   - Used to generate ISO and other boot assets

4. **ISO Image**
   - Built using custom imager
   - Contains custom kernel + ITL branding

## Build Process Flow

```
[siderolabs/pkgs repo] 
        |
        v
[Build Custom Kernel] --push--> [ghcr.io/.../kernel:TAG]
        |
        v
[Checkout Talos Source]
        |
        v
[Build Kernel + Initramfs with PKG_KERNEL]
        |
        v
[Build Custom Imager] --push--> [ghcr.io/.../imager:TAG]
        |
        v
[Build ISO with Custom Imager + Branding Overlay]
        |
        v
[ISO Artifact]
```

## Common Kernel Customizations

### Security Hardening

```bash
# Lockdown LSM
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y

# Kernel page table isolation
CONFIG_PAGE_TABLE_ISOLATION=y

# Disable legacy protocols
# CONFIG_IP_DCCP is not set
# CONFIG_IP_SCTP is not set
```

### Performance Tuning

```bash
# Enable BBR congestion control
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y

# CPU frequency scaling
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
```

### Custom Drivers

```bash
# Enable specific hardware driver
CONFIG_CUSTOM_DRIVER=m

# Disable unwanted drivers
# CONFIG_STAGING is not set
```

## Troubleshooting

### Build Takes Too Long
Custom kernel builds can take 15-30 minutes. Consider:
- Building only for needed architecture (`PLATFORM=linux/amd64`)
- Using GitHub Actions cache for kernel builds

### Module Signing Errors
All kernel modules must be signed with the build-time generated key. If you add new modules:
1. Ensure they're compiled with the same kernel build
2. Don't try to load external modules (won't have valid signature)

### Registry Push Failures
Ensure `GITHUB_TOKEN` has package write permissions:
- Repository Settings > Actions > General
- Workflow permissions: "Read and write permissions"

### ISO Build Fails with Custom Kernel
Check:
1. Kernel container was pushed successfully
2. `PKG_KERNEL` variable matches actual registry path
3. Imager container built successfully

## Disabling Kernel Customization

```bash
gh variable set BUILD_CUSTOM_KERNEL --body "false"
```

Or delete the variable entirely. The pipeline will fall back to standard Talos kernel with branding overlay only.

## References

- [Talos Kernel Customization](https://docs.siderolabs.com/talos/v1.6/build-and-extend-talos/custom-images-and-development/customizing-the-kernel)
- [Talos PKGS Repository](https://github.com/siderolabs/pkgs)
- [Linux Kernel Configuration](https://www.kernel.org/doc/html/latest/admin-guide/README.html)
