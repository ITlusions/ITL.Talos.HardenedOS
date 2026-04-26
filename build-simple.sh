#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# ITL Talos HardenedOS — Imager-based ISO build
#
# Uses the official Talos imager to bake ITL extensions directly into the ISO.
# Extensions are pre-installed at boot time — no GHCR internet access needed
# during node installation (airgap-ready).
#
# Configuration (override via env vars):
#   TALOS_VERSION        Talos release to build against      (default: v1.9.0)
#   ITL_BRANDING_TAG     itl-talos-hardened-os-branding tag  (default: latest)
#   ITL_SECURITY_TAG     itl-talos-hardened-os-security tag  (default: latest)
#   GVISOR_TAG           siderolabs/gvisor extension tag     (default: v20231214.0-v1.9.0)
#   INTEL_UCODE_TAG      siderolabs/intel-ucode tag          (default: 20240312-v1.9.0)
#   EXTRA_EXTENSIONS     Space-separated OCI refs to add on top of core set
#                        e.g.: "ghcr.io/myorg/myext:v1.0 ghcr.io/other/ext:latest"
# ─────────────────────────────────────────────────────────────────────────────

TALOS_VERSION="${TALOS_VERSION:-v1.9.0}"
ITL_BRANDING_TAG="${ITL_BRANDING_TAG:-latest}"
ITL_SECURITY_TAG="${ITL_SECURITY_TAG:-latest}"
GVISOR_TAG="${GVISOR_TAG:-v20231214.0-v1.9.0}"
INTEL_UCODE_TAG="${INTEL_UCODE_TAG:-20240312-v1.9.0}"
EXTRA_EXTENSIONS="${EXTRA_EXTENSIONS:-}"

WORK_DIR="$(cd "${1:-.}" && pwd)"

echo "========================================="
echo "ITL Talos HardenedOS — Imager Build"
echo "========================================="
echo "Talos Version : ${TALOS_VERSION}"
echo "Output Dir    : ${WORK_DIR}"
echo ""

# ── Build extension argument list ─────────────────────────────────────────────
# Core ITL extensions — always baked in
EXTENSION_ARGS=(
    "--system-extension-image" "ghcr.io/itlusions/itl-talos-hardened-os-branding:${ITL_BRANDING_TAG}"
    "--system-extension-image" "ghcr.io/itlusions/itl-talos-hardened-os-security:${ITL_SECURITY_TAG}"
    "--system-extension-image" "ghcr.io/siderolabs/gvisor:${GVISOR_TAG}"
    "--system-extension-image" "ghcr.io/siderolabs/intel-ucode:${INTEL_UCODE_TAG}"
)

# Optional extra extensions from GHCR or any OCI registry
if [ -n "$EXTRA_EXTENSIONS" ]; then
    echo "[*] Extra extensions (EXTRA_EXTENSIONS):"
    for ext in $EXTRA_EXTENSIONS; do
        echo "    + $ext"
        EXTENSION_ARGS+=("--system-extension-image" "$ext")
    done
    echo ""
fi

echo "[*] Extensions to be baked into ISO:"
for arg in "${EXTENSION_ARGS[@]}"; do
    [[ "$arg" == --* ]] && continue
    echo "    - $arg"
done
echo ""

# ── Ensure device mapper is available (required by imager for squashfs) ───────
if [ ! -e /dev/mapper/control ]; then
    echo "[*] Loading dm-mod kernel module..."
    modprobe dm-mod 2>/dev/null || echo "[!] modprobe dm-mod failed — continuing (may fail on non-Linux hosts)"
fi

mkdir -p "${WORK_DIR}/_out"

# ── Run the Talos imager ───────────────────────────────────────────────────────
echo "[*] Running ghcr.io/siderolabs/imager:${TALOS_VERSION}..."
docker run --rm \
    -v /dev/mapper/control:/dev/mapper/control \
    -v "${WORK_DIR}/_out:/out" \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
    iso \
    "${EXTENSION_ARGS[@]}" \
    --extra-kernel-arg "console=ttyS0,115200" \
    --extra-kernel-arg "console=tty0"

# ── Rename and checksum ───────────────────────────────────────────────────────
ISO_SRC="${WORK_DIR}/_out/metal-amd64.iso"
ISO_DST="${WORK_DIR}/itl-talos-${TALOS_VERSION}.iso"

if [ ! -f "$ISO_SRC" ]; then
    echo "[ERROR] Imager did not produce output at $ISO_SRC"
    ls -la "${WORK_DIR}/_out/" || true
    exit 1
fi

mv "$ISO_SRC" "$ISO_DST"
sha256sum "$ISO_DST" > "$ISO_DST.sha256"
md5sum    "$ISO_DST" > "$ISO_DST.md5"

echo ""
echo "========================================="
echo "BUILD COMPLETE"
echo "========================================="
echo "ISO    : $ISO_DST"
echo "Size   : $(du -h "$ISO_DST" | cut -f1)"
echo "SHA256 : $(awk '{print $1}' "$ISO_DST.sha256")"
echo ""
echo "Extensions baked in:"
echo "  ghcr.io/itlusions/itl-talos-hardened-os-branding:${ITL_BRANDING_TAG}"
echo "  ghcr.io/itlusions/itl-talos-hardened-os-security:${ITL_SECURITY_TAG}"
echo "  ghcr.io/siderolabs/gvisor:${GVISOR_TAG}"
echo "  ghcr.io/siderolabs/intel-ucode:${INTEL_UCODE_TAG}"
[ -n "$EXTRA_EXTENSIONS" ] && echo "  + Extra: $EXTRA_EXTENSIONS"
echo ""
echo "NOTE: machine.install.extensions in MachineConfig is no longer required"
echo "      for the above extensions — they are already in the ISO."
echo "      Use machine.install.extensions only for additional cluster-specific"
echo "      extensions not included in this ISO."
echo "========================================="
