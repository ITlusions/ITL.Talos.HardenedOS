#!/bin/bash
# build-usb.sh — Build an Alpine Linux USB image with the ITL registration agent
#
# Prerequisites (on the build host):
#   - docker (for pulling Alpine and tpm2-tools)
#   - mtools, syslinux / grub2-mkrescue (for ISO building)
#   OR use the Docker-based build which handles all deps inside a container.
#
# Output: dist/itl-talos-usb-agent-<date>.iso
#         (write to USB with: dd if=dist/itl-talos-usb-agent.iso of=/dev/sdX bs=4M status=progress)
#
# Usage:
#   ./build-usb.sh                             # build with defaults
#   ITL_REG_URL=https://myhost ./build-usb.sh  # bake a custom reg URL
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ALPINE_VERSION="${ALPINE_VERSION:-3.21}"
ITL_REG_URL="${ITL_REG_URL:-https://reg.itlusions.com}"
ITL_ROLE="${ITL_ROLE:-worker-app}"
DIST_DIR="$(dirname "$0")/../../dist"
OUTPUT_ISO="${DIST_DIR}/itl-talos-usb-agent-$(date +%Y%m%d).iso"

mkdir -p "$DIST_DIR"

echo "══════════════════════════════════════════════════════"
echo "  ITL Talos USB Agent Builder"
echo "  Alpine version : ${ALPINE_VERSION}"
echo "  Default reg URL: ${ITL_REG_URL}"
echo "  Default role   : ${ITL_ROLE}"
echo "══════════════════════════════════════════════════════"

TMP_OUT="${DIST_DIR}/__usb_out"
mkdir -p "${TMP_OUT}"

# ── Build with BuildKit --output to extract the ISO directly ─────────────────
DOCKER_BUILDKIT=1 docker build \
    --build-arg ALPINE_VERSION="${ALPINE_VERSION}" \
    --build-arg ITL_REG_URL="${ITL_REG_URL}" \
    --build-arg ITL_ROLE="${ITL_ROLE}" \
    --output "type=local,dest=${TMP_OUT}" \
    -f "$(dirname "$0")/Dockerfile.usb-builder" \
    "$(dirname "$0")"

mv "${TMP_OUT}/usb-agent.iso" "${OUTPUT_ISO}"
rm -rf "${TMP_OUT}"

echo ""
echo "USB agent ISO built: ${OUTPUT_ISO}"
echo ""
echo "Write to USB drive with:"
echo "  sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo ""
echo "The USB will:"
echo "  1. Boot Alpine Linux"
echo "  2. Read the TPM EK certificate from the hardware"
echo "  3. Register with ${ITL_REG_URL}"
echo "  4. Download the role-specific Talos ISO"
echo "  5. Write Talos to the local disk and reboot"
