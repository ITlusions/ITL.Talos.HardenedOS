#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# build-ipxe-usb.sh
#
# Build a minimal bootable iPXE USB image that chains to the ITL netboot menu.
# The resulting ISO can be written to any USB drive — no Talos ISO needed,
# no Alpine, no agent.  Boot order: USB → iPXE → DHCP → menu.ipxe → role.
#
# Usage:
#   ./netboot/build-ipxe-usb.sh
#
# Environment variables:
#   NETBOOT_SERVER   HTTP(S) base URL of the netboot server
#                    e.g. http://192.168.1.10  or  https://netboot.itlusions.local
#                    Default: http://192.168.1.10
#
#   IPXE_REF         iPXE git tag to build from (default: v1.21.1)
#
#   OUTPUT_DIR       Where to write the ISO (default: dist/)
#
# Requires: docker (buildx)
#
# Write the output ISO to a USB drive:
#   Linux/macOS:
#     sudo dd if=dist/itl-ipxe-usb-<date>.iso of=/dev/sdX bs=4M status=progress
#   Windows:
#     Rufus → select ISO → DD image mode → GPT → UEFI (non-CSM)
# ─────────────────────────────────────────────────────────────────────────────

NETBOOT_SERVER="${NETBOOT_SERVER:-http://192.168.1.10}"
IPXE_REF="${IPXE_REF:-v1.21.1}"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$0")/../dist}"
OUTPUT_ISO="${OUTPUT_DIR}/itl-ipxe-usb-$(date +%Y%m%d).iso"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "ITL — Build iPXE Chainload USB"
echo "========================================="
echo "Netboot server : ${NETBOOT_SERVER}"
echo "iPXE ref       : ${IPXE_REF}"
echo "Output         : ${OUTPUT_ISO}"
echo ""

command -v docker &>/dev/null || { echo "[ERROR] docker not found"; exit 1; }

mkdir -p "${OUTPUT_DIR}"

# ── Build using Docker BuildKit --output to extract the ISO ───────────────────
DOCKER_BUILDKIT=1 docker build \
    --file "${SCRIPT_DIR}/Dockerfile.ipxe-usb" \
    --build-arg "NETBOOT_SERVER=${NETBOOT_SERVER}" \
    --build-arg "IPXE_REF=${IPXE_REF}" \
    --output "type=local,dest=${OUTPUT_DIR}/__ipxe_out" \
    "${SCRIPT_DIR}"

mv "${OUTPUT_DIR}/__ipxe_out/ipxe-usb.iso" "${OUTPUT_ISO}"
rm -rf "${OUTPUT_DIR}/__ipxe_out"

echo ""
echo "========================================="
echo "ISO ready: ${OUTPUT_ISO}"
echo "Size     : $(du -h "${OUTPUT_ISO}" | cut -f1)"
echo "========================================="
echo ""
echo "Write to USB (Linux/macOS):"
echo "  sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo ""
echo "Write to USB (Windows — Rufus):"
echo "  Mode: DD Image"
echo "  Scheme: GPT"
echo "  Target: UEFI (non-CSM)"
echo ""
echo "Boot sequence:"
echo "  USB → iPXE → DHCP → ${NETBOOT_SERVER}/menu.ipxe → role selection"
