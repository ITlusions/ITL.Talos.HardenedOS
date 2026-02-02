#!/bin/bash
set -e

TALOS_VERSION="${TALOS_VERSION:-v1.9.0}"
WORK_DIR="${1:-.}"
if [ "$WORK_DIR" = "." ]; then
    WORK_DIR="$(pwd)"
fi
cd "$WORK_DIR" || { echo "[ERROR] Could not cd to $WORK_DIR"; exit 1; }

echo "========================================="
echo "ITL Talos HardenedOS Simple Build"
echo "========================================="
echo "Talos Version: ${TALOS_VERSION}"
echo ""

# Get the official ISO
OFFICIAL_ISO="talos-${TALOS_VERSION}-amd64.iso"
if [ ! -f "${OFFICIAL_ISO}" ]; then
    echo "[*] Downloading official Talos ISO..."
    wget -q --show-progress "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.iso" -O "${OFFICIAL_ISO}"
    echo "[OK] ISO downloaded"
fi

echo "[*] Extracting just the initramfs from ISO..."
# Use 7z or xorriso to extract only the boot directory
mkdir -p iso-boot
cd iso-boot

# Extract just boot files
echo "[*] Extracting /boot from ISO..."
xorriso -osirrox on -indev "../${OFFICIAL_ISO}" -extract /boot . 2>&1 | tail -5

cd ..
echo "[OK] Boot files extracted"

# Find initramfs
INITRAMFS=$(ls iso-boot/initramfs* 2>/dev/null | head -1)
if [ -z "$INITRAMFS" ]; then
    echo "[ERROR] Initramfs not found!"
    ls -la iso-boot/
    exit 1
fi

echo "[*] Found initramfs: $INITRAMFS"
echo "[*] Checking format..."
file "$INITRAMFS"

# Extract and modify initramfs
mkdir -p initramfs-work
cd initramfs-work

# Decompress
if file "$INITRAMFS" | grep -q "Zstandard"; then
    echo "[*] Extracting zstd initramfs..."
    zstd -dc "../$INITRAMFS" | cpio -idm 2>/dev/null || true
    COMPRESS="zstd -19 -T0"
    EXT="zst"
elif file "$INITRAMFS" | grep -q "xz"; then
    echo "[*] Extracting xz initramfs..."
    xz -dc "../$INITRAMFS" | cpio -idm 2>/dev/null || true
    COMPRESS="xz --check=crc32 --lzma2=dict=1MiB"
    EXT="xz"
else
    echo "[*] Extracting gzip initramfs..."
    zcat "../$INITRAMFS" | cpio -idm 2>/dev/null || true
    COMPRESS="gzip -9"
    EXT="gz"
fi

echo "[OK] Initramfs extracted"

# Add branding
echo "[*] Injecting ITL branding..."
mkdir -p etc
echo "Welcome to ITL Talos HardenedOS" > etc/issue
echo "Version: ${TALOS_VERSION}" >> etc/issue

# Repack
echo "[*] Repacking initramfs..."
find . -print0 | cpio --null -o -H newc 2>/dev/null | $COMPRESS > "../initramfs-branded.$EXT"
cd ..

echo "[OK] Branded initramfs created: initramfs-branded.$EXT"

# Replace in ISO - create new ISO with isohybrid
echo "[*] Creating new ISO with branded initramfs..."
ISO_COPY="itl-talos-${TALOS_VERSION}.iso"

# Extract ISO structure minimally
mkdir -p iso-work
cd iso-work
echo "[*] Extracting ISO structure (this is fast)..."
xorriso -osirrox on -indev "../${OFFICIAL_ISO}" -extract / . 2>&1 | tail -3
cd ..

# Replace initramfs
echo "[*] Replacing initramfs..."
cp "initramfs-branded.$EXT" "iso-work/boot/initramfs-branded.$EXT"

# Rebuild ISO
echo "[*] Rebuilding ISO..."
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "ITL-TALOS-v1_9_0" \
    -eltorito-boot boot.catalog \
    -no-emul-boot \
    -eltorito-alt-boot \
    -e efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "${ISO_COPY}" \
    iso-work/ 2>&1 | tail -10

if [ -f "$ISO_COPY" ]; then
    echo "[OK] ISO build successful!"
    ls -lh "$ISO_COPY"
    sha256sum "$ISO_COPY" > "$ISO_COPY.sha256"
    echo "[OK] Checksums created"
else
    echo "[ERROR] ISO build failed!"
    exit 1
fi

echo ""
echo "========================================="
echo "BUILD COMPLETE"
echo "========================================="
echo "ISO: $ISO_COPY"
echo "Size: $(du -h $ISO_COPY | cut -f1)"
echo "========================================="
