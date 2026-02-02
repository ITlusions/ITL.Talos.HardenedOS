#!/bin/bash
set -e

# ITL Talos HardenedOS Build Script
# Builds custom Talos ISO with branding and optional custom kernel

TALOS_VERSION="v1.9.0"
PKGS_VERSION="release-1.9"
BUILD_CUSTOM_KERNEL="${BUILD_CUSTOM_KERNEL:-false}"
REGISTRY="${REGISTRY:-ghcr.io}"
USERNAME="${USERNAME:-itlusions}"
PLATFORM="${PLATFORM:-linux/amd64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-output"

echo "========================================="
echo "ITL Talos HardenedOS Build Script"
echo "========================================="
echo "Talos Version: ${TALOS_VERSION}"
echo "Custom Kernel: ${BUILD_CUSTOM_KERNEL}"
echo "Platform: ${PLATFORM}"
echo "Registry: ${REGISTRY}/${USERNAME}"
echo "========================================="
echo ""

# Check prerequisites
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required"; exit 1; }
command -v figlet >/dev/null 2>&1 || { echo "WARNING: figlet not found, skipping ASCII banner generation"; }
command -v convert >/dev/null 2>&1 || { echo "WARNING: imagemagick not found, skipping logo conversion"; }

# Create work directory
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Step 1: Generate branding assets
echo "[*] Step 1: Generating branding assets..."
mkdir -p branding/output branding/logos

if command -v figlet >/dev/null 2>&1; then
    echo "ITL Talos" | figlet -f standard > branding/output/console-banner.txt
    echo "" >> branding/output/console-banner.txt
    echo "HardenedOS ${TALOS_VERSION}" >> branding/output/console-banner.txt
    echo "Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> branding/output/console-banner.txt
    echo "[OK] Console banner generated"
else
    echo "ITL Talos HardenedOS ${TALOS_VERSION}" > branding/output/console-banner.txt
    echo "[!] Basic banner created (install figlet for ASCII art)"
fi

# Create placeholder logo
if command -v convert >/dev/null 2>&1; then
    if [ ! -f branding/logos/boot-logo.png ]; then
        convert -size 224x224 xc:navy \
            -pointsize 20 -fill white -gravity center \
            -annotate +0+0 "ITL" \
            branding/logos/boot-logo.png
    fi
    
    convert branding/logos/boot-logo.png -resize 224x224 branding/output/boot-logo.png
    convert branding/output/boot-logo.png branding/output/boot-logo.ppm
    
    if command -v ppmquant >/dev/null 2>&1 && command -v pnmtoplainpnm >/dev/null 2>&1; then
        ppmquant 224 branding/output/boot-logo.ppm | pnmtoplainpnm > branding/output/logo_custom_clut224.ppm
        echo "[OK] Kernel logo converted"
    fi
fi

echo ""

# Step 2: Build custom kernel (if enabled)
CUSTOM_KERNEL_IMAGE=""
if [ "${BUILD_CUSTOM_KERNEL}" = "true" ]; then
    echo "[*] Step 2: Building custom kernel..."
    
    if [ ! -d pkgs ]; then
        echo "[*] Cloning siderolabs/pkgs repository..."
        git clone --depth 1 --branch "${PKGS_VERSION}" https://github.com/siderolabs/pkgs.git pkgs
    fi
    
    cd pkgs
    
    # Apply kernel customizations (modify kernel/build/config-amd64 here if needed)
    echo "[*] Using default kernel configuration"
    echo "[*] To customize: edit pkgs/kernel/build/config-amd64 before running this script"
    
    echo "[*] Building kernel (this will take 15-30 minutes)..."
    make kernel \
        REGISTRY="${REGISTRY}/${USERNAME}" \
        PUSH=false \
        PLATFORM="${PLATFORM}"
    
    # Get the built kernel tag
    KERNEL_TAG=$(git describe --tags --always)
    CUSTOM_KERNEL_IMAGE="${REGISTRY}/${USERNAME}/kernel:${KERNEL_TAG}"
    
    echo "[OK] Custom kernel built: ${CUSTOM_KERNEL_IMAGE}"
    echo ""
    
    cd "${WORK_DIR}"
else
    echo "[*] Step 2: Skipping custom kernel build (using standard Talos kernel)"
    echo "[*] To enable: export BUILD_CUSTOM_KERNEL=true"
    echo ""
fi

# Step 3: Clone Talos source
echo "[*] Step 3: Preparing Talos source..."
if [ ! -d talos-src ]; then
    echo "[*] Cloning Talos repository..."
    git clone --depth 1 --branch "${TALOS_VERSION}" https://github.com/siderolabs/talos.git talos-src
else
    echo "[*] Talos source already exists"
fi
echo ""

# Step 4: Prepare branding overlay
echo "[*] Step 4: Preparing branding overlay..."
mkdir -p talos-src/_out/overlay/etc

cp branding/output/console-banner.txt talos-src/_out/overlay/etc/issue
echo "[OK] Console banner added to overlay"

if [ -f branding/output/logo_custom_clut224.ppm ]; then
    cp branding/output/logo_custom_clut224.ppm talos-src/_out/overlay/etc/logo.ppm
    echo "[OK] Kernel logo added to overlay"
fi
echo ""

# Step 5: Build custom ISO by injecting branding into official ISO
cd "${WORK_DIR}"

if [ -n "${CUSTOM_KERNEL_IMAGE}" ]; then
    echo "[*] Step 5: Custom kernel builds not supported in local script yet"
    echo "[*] Use GitHub Actions workflow with BUILD_CUSTOM_KERNEL=true instead"
    exit 1
else
    echo "[*] Step 5: Building custom ISO from official Talos release..."
    
    # Download official ISO if not exists
    OFFICIAL_ISO="talos-${TALOS_VERSION}-amd64.iso"
    if [ ! -f "${OFFICIAL_ISO}" ]; then
        echo "[*] Downloading official Talos ISO..."
        wget -q --show-progress \
            "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.iso" \
            -O "${OFFICIAL_ISO}"
    fi
    
    # We'll extract kernel and initramfs from the ISO after extraction
    echo "[OK] Will extract kernel and initramfs from ISO"
    
    # Extract bootloader from official ISO
    echo "[*] Extracting bootloader from official ISO..."
    mkdir -p iso-original iso-custom
    echo "[*] Running xorriso extraction (this may take 1-2 minutes)..."
    xorriso -osirrox on -indev "${OFFICIAL_ISO}" -extract / iso-original/
    echo "[OK] Extraction complete"
    
    # Find and locate initramfs in extracted ISO
    echo "[*] Locating kernel and initramfs in ISO..."
    INITRAMFS_PATH=$(find iso-original -name "initramfs*.xz" -o -name "initrd*" | head -1)
    KERNEL_PATH=$(find iso-original -name "vmlinuz*" -o -name "kernel*" | grep -v ".sig" | head -1)
    
    if [ -z "$INITRAMFS_PATH" ]; then
        echo "[ERROR] Could not find initramfs in ISO"
        ls -la iso-original/
        exit 1
    fi
    
    echo "[OK] Found initramfs: $INITRAMFS_PATH"
    echo "[OK] Found kernel: $KERNEL_PATH"
    
    # Check what format the initramfs actually is
    echo "[*] Checking initramfs format..."
    file "$INITRAMFS_PATH"
    
    # Copy structure with write permissions (use hardlinks for speed)
    echo "[*] Preparing ISO for modification..."
    cp -al iso-original iso-custom 2>/dev/null || {
        echo "[*] Hardlinks failed, using direct modification instead..."
        chmod -R u+w iso-original/
        ISO_DIR="iso-original"
    }
    : ${ISO_DIR:=iso-custom}
    
    # Inject branding into initramfs
    echo "[*] Injecting ITL branding into initramfs..."
    mkdir -p initramfs-mod
    cd initramfs-mod
    echo "[*] Extracting initramfs (this may take 30-60 seconds)..."
    
    # Try different decompression methods based on file type
    if zstd -dc "../${INITRAMFS_PATH}" 2>/dev/null | cpio -idm 2>&1 | tail -10; then
        echo "[OK] Initramfs extracted with zstd"
        COMPRESS_CMD="zstd -19 -T0"
        COMPRESS_EXT="zst"
    elif xz -dc "../${INITRAMFS_PATH}" 2>/dev/null | cpio -idm 2>&1 | tail -10; then
        echo "[OK] Initramfs extracted with xz"
        COMPRESS_CMD="xz --check=crc32 --lzma2=dict=1MiB"
        COMPRESS_EXT="xz"
    elif zcat "../${INITRAMFS_PATH}" 2>/dev/null | cpio -idm 2>&1 | tail -10; then
        echo "[OK] Initramfs extracted with gzip"
        COMPRESS_CMD="gzip -9"
        COMPRESS_EXT="gz"
    elif cat "../${INITRAMFS_PATH}" | cpio -idm 2>&1 | tail -10; then
        echo "[OK] Initramfs extracted (uncompressed)"
        COMPRESS_CMD="cat"
        COMPRESS_EXT="cpio"
    else
        echo "[ERROR] Could not extract initramfs"
        exit 1
    fi
    
    # Add branding
    mkdir -p etc
    cp ../branding/output/console-banner.txt etc/issue
    
    # Repack initramfs with same compression
    echo "[*] Repacking initramfs with $COMPRESS_CMD..."
    find . | cpio -o -H newc 2>/dev/null | $COMPRESS_CMD > ../initramfs-branded.$COMPRESS_EXT
    cd ..
    
    # Replace initramfs in ISO structure (kernel stays the same)
    echo "[*] Replacing initramfs with branded version..."
    INITRAMFS_DEST="${ISO_DIR}/boot/initramfs-branded.$COMPRESS_EXT"
    cp "initramfs-branded.$COMPRESS_EXT" "${INITRAMFS_DEST}"
    echo "[OK] Branded initramfs installed"
    
    # Build final ISO
    echo "[*] Building bootable ISO..."
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ITL-TALOS-${TALOS_VERSION}" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "itl-talos-${TALOS_VERSION}.iso" \
        "${ISO_DIR}/" 2>&1 | grep -vE "^xorriso|^libisofs"
fi

echo "[OK] ISO build complete"
echo ""

# Step 6: Copy and prepare artifacts
echo "[*] Step 6: Preparing artifacts..."

OUTPUT_ISO="${WORK_DIR}/itl-talos-${TALOS_VERSION}.iso"

if [ -f "${OUTPUT_ISO}" ]; then
    
    # Generate checksums
    sha256sum "${OUTPUT_ISO}" > "${OUTPUT_ISO}.sha256"
    md5sum "${OUTPUT_ISO}" > "${OUTPUT_ISO}.md5"
    
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
    
    echo ""
    echo "========================================="
    echo "BUILD SUCCESSFUL"
    echo "========================================="
    echo "ISO File: ${OUTPUT_ISO}"
    echo "Size: ${ISO_SIZE}"
    echo "SHA256: $(cat ${OUTPUT_ISO}.sha256)"
    echo ""
    echo "Kernel: $([ -n "${CUSTOM_KERNEL_IMAGE}" ] && echo "Custom (${CUSTOM_KERNEL_IMAGE})" || echo "Standard Talos")"
    echo "Branding: ITL custom console banner"
    echo "========================================="
    echo ""
    echo "To test in Hyper-V:"
    echo "  1. Copy ISO to Windows: ${OUTPUT_ISO}"
    echo "  2. Create VM: New-VM -Name ITL-Talos -MemoryStartupBytes 4GB -Generation 2"
    echo "  3. Attach ISO: Set-VMDvdDrive -VMName ITL-Talos -Path <path-to-iso>"
    echo "  4. Start VM: Start-VM -Name ITL-Talos"
    echo ""
else
    echo "[ERROR] ISO file not found: ${ISO_FILE}"
    exit 1
fi
