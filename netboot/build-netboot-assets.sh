#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# build-netboot-assets.sh
#
# Build kernel and initramfs for HTTP netboot using the official Talos imager.
# Uses 'imager kernel' and 'imager initramfs' subcommands — the same tool and
# the same extension arguments as the ISO build.
#
# Usage:
#   ./netboot/build-netboot-assets.sh [output-dir]
#
# Arguments:
#   output-dir  Where to write vmlinuz + initramfs.xz
#               Default: netboot-assets/<PROFILE>
#
# Configuration (override via env vars — same as build-simple.sh):
#   TALOS_VERSION         (default: v1.9.0)
#   ITL_BRANDING_TAG      (default: latest)
#   ITL_SECURITY_TAG      (default: latest)
#   ITL_TPM_REGISTER_TAG  (default: latest)
#   GVISOR_TAG            (default: v20231214.0-v1.9.0)
#   INTEL_UCODE_TAG       (default: 20240312-v1.9.0)
#   EXTRA_EXTENSIONS      space-separated OCI refs to add on top of core set
#   PROFILE               profile name used for output directory (default: standard)
#
# Requires: docker
# ─────────────────────────────────────────────────────────────────────────────

TALOS_VERSION="${TALOS_VERSION:-v1.9.0}"
ITL_BRANDING_TAG="${ITL_BRANDING_TAG:-latest}"
ITL_SECURITY_TAG="${ITL_SECURITY_TAG:-latest}"
ITL_TPM_REGISTER_TAG="${ITL_TPM_REGISTER_TAG:-latest}"
GVISOR_TAG="${GVISOR_TAG:-v20231214.0-v1.9.0}"
INTEL_UCODE_TAG="${INTEL_UCODE_TAG:-20240312-v1.9.0}"
EXTRA_EXTENSIONS="${EXTRA_EXTENSIONS:-}"
PROFILE="${PROFILE:-standard}"

# ── Load profile env if it exists (mirrors build-simple.sh behaviour) ─────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.env"
if [ -f "$PROFILE_FILE" ] && [ -z "${EXTRA_EXTENSIONS+x}" ]; then
    echo "[*] Loading profile: $PROFILE ($PROFILE_FILE)"
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
fi
EXTRA_EXTENSIONS="${EXTRA_EXTENSIONS:-}"

OUT="${1:-netboot-assets/${PROFILE}}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "========================================="
echo "ITL Talos — Build Netboot Assets"
echo "========================================="
echo "Talos Version : ${TALOS_VERSION}"
echo "Profile       : ${PROFILE}"
echo "Output        : ${OUT}"
echo ""

command -v docker &>/dev/null || { echo "[ERROR] docker not found"; exit 1; }
mkdir -p "$OUT"

# ── Build extension argument list ─────────────────────────────────────────────
EXTENSION_ARGS=(
    "--system-extension-image" "ghcr.io/itlusions/itl-talos-hardened-os-branding:${ITL_BRANDING_TAG}"
    "--system-extension-image" "ghcr.io/itlusions/itl-talos-hardened-os-security:${ITL_SECURITY_TAG}"
    "--system-extension-image" "ghcr.io/itlusions/itl-talos-tpm-register:${ITL_TPM_REGISTER_TAG}"
    "--system-extension-image" "ghcr.io/siderolabs/gvisor:${GVISOR_TAG}"
    "--system-extension-image" "ghcr.io/siderolabs/intel-ucode:${INTEL_UCODE_TAG}"
)
if [ -n "$EXTRA_EXTENSIONS" ]; then
    echo "[*] Extra extensions:"
    for ext in $EXTRA_EXTENSIONS; do
        echo "    + $ext"
        EXTENSION_ARGS+=("--system-extension-image" "$ext")
    done
    echo ""
fi

# ── kernel subcommand — produces kernel-amd64 ─────────────────────────────────
# The kernel binary is the same for all profiles; extensions do not affect it.
echo "[*] Running: imager kernel..."
docker run --rm \
    -v "${TMP}:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    kernel \
    --arch amd64

# ── initramfs subcommand — produces initramfs-amd64.xz ───────────────────────
# Extensions are baked into the initramfs (squashfs). Pass all --system-extension-image
# args here, same as for the ISO build.
echo "[*] Running: imager initramfs..."
docker run --rm \
    -v "${TMP}:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    initramfs \
    --arch amd64 \
    "${EXTENSION_ARGS[@]}"

# ── Move outputs to final location ────────────────────────────────────────────
mv "${TMP}/kernel-amd64"       "${OUT}/vmlinuz"
mv "${TMP}/initramfs-amd64.xz" "${OUT}/initramfs.xz"

echo ""
echo "========================================="
echo "Netboot assets ready"
echo "========================================="
echo "vmlinuz      : ${OUT}/vmlinuz      ($(du -h "${OUT}/vmlinuz" | cut -f1))"
echo "initramfs.xz : ${OUT}/initramfs.xz ($(du -h "${OUT}/initramfs.xz" | cut -f1))"
echo ""
echo "Serve these files and update netboot/menu.ipxe:"
echo "  kernel \${netboot-server}/boot/${PROFILE}/vmlinuz"
echo "  initrd \${netboot-server}/boot/${PROFILE}/initramfs.xz"
