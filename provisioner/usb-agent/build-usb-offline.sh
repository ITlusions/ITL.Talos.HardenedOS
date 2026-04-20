#!/bin/bash
# build-usb-offline.sh — Create an airgapped offline provisioning USB
#
# This tool creates a USB drive (or ISO) that includes:
#   - Alpine Linux with the ITL registration agent
#   - A pre-downloaded Talos role ISO
#   - (optional) A pre-generated Talos machineconfig
#   - (optional) A reg-bundle.json with machine_id/role from the Registration Service
#
# The resulting USB can install a Talos node with NO network access during
# provisioning. The TPM EK fingerprint is captured and written to the EFI
# partition so the operator can later import the machine into the Registration
# Service.
#
# Usage:
#   # Basic: create an offline USB for a specific role (downloads the ISO automatically)
#   ./build-usb-offline.sh --role worker-app --output /dev/sdb
#
#   # With pre-generated config (fully airgapped — no service needed post-install)
#   ./build-usb-offline.sh \
#       --role controlplane \
#       --iso /path/to/itl-talos-controlplane-amd64.iso \
#       --config /path/to/controlplane.yaml \
#       --output /dev/sdb
#
#   # From a pre-registered machine_id (reads bundle from Registration Service)
#   ./build-usb-offline.sh \
#       --machine-id <uuid> \
#       --admin-token <token> \
#       --output /dev/sdb
#
# Requirements (on build host):
#   curl, jq, dd, parted, mkfs.vfat, grub-mkrescue (or Docker via --use-docker)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../../dist"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Defaults ─────────────────────────────────────────────────────────────────
ROLE="${ITL_ROLE:-worker-app}"
TARGET_OUTPUT=""
TALOS_ISO_PATH=""
MACHINE_CONFIG_PATH=""
MACHINE_ID=""
ADMIN_TOKEN="${ITL_ADMIN_TOKEN:-}"
REG_URL="${ITL_REG_URL:-https://reg.itlusions.com}"
ISO_BASE_URL="${ITL_ISO_BASE_URL:-https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download}"
USE_DOCKER="${USE_DOCKER:-}"
OUTPUT_ISO=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --role)         ROLE="$2";                shift 2 ;;
        --iso)          TALOS_ISO_PATH="$2";      shift 2 ;;
        --config)       MACHINE_CONFIG_PATH="$2"; shift 2 ;;
        --machine-id)   MACHINE_ID="$2";          shift 2 ;;
        --admin-token)  ADMIN_TOKEN="$2";         shift 2 ;;
        --reg-url)      REG_URL="$2";             shift 2 ;;
        --output)       TARGET_OUTPUT="$2";       shift 2 ;;
        --output-iso)   OUTPUT_ISO="$2";          shift 2 ;;
        --use-docker)   USE_DOCKER="yes";         shift ;;
        --help|-h)
            sed -n '/^# Usage/,/^# Requirements/p' "$0" | grep -v '^#$' | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$TARGET_OUTPUT" ] || [ -n "$OUTPUT_ISO" ] || {
    echo "ERROR: Specify --output <device|/dev/sdX> or --output-iso <file.iso>" >&2
    exit 1
}

BUNDLE_DIR="${WORK_DIR}/bundle/itl"
mkdir -p "$BUNDLE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── Fetch machine bundle from Registration Service ────────────────────────────
fetch_bundle_from_service() {
    [ -n "$ADMIN_TOKEN" ] || die "--admin-token required when using --machine-id"

    log "Fetching machine bundle for ${MACHINE_ID} from ${REG_URL} ..."
    BUNDLE_RESPONSE=$(curl \
        --silent --fail --max-time 30 \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${REG_URL}/api/v1/machines/${MACHINE_ID}/offline-bundle") || \
        die "Failed to fetch bundle from Registration Service"

    ROLE=$(jq -r '.role' <<< "$BUNDLE_RESPONSE")
    ISO_URL=$(jq -r '.iso_url' <<< "$BUNDLE_RESPONSE")

    # Save bundle JSON (contains machine_id, role, one-time config token, etc.)
    echo "$BUNDLE_RESPONSE" | jq 'del(.ek_cert_pem)' > "${BUNDLE_DIR}/reg-bundle.json"
    log "Bundle saved (role: ${ROLE})"

    # Save machineconfig if embedded in the bundle
    MACHINECONFIG=$(jq -r '.machineconfig // empty' <<< "$BUNDLE_RESPONSE")
    if [ -n "$MACHINECONFIG" ]; then
        echo "$MACHINECONFIG" > "${BUNDLE_DIR}/machineconfig.yaml"
        log "machineconfig.yaml extracted from bundle"
    fi
}

# ── Determine Talos ISO URL for the role ─────────────────────────────────────
iso_url_for_role() {
    case "$1" in
        controlplane) echo "${ISO_BASE_URL}/itl-talos-controlplane-amd64.iso" ;;
        worker-infra) echo "${ISO_BASE_URL}/itl-talos-worker-infra-amd64.iso" ;;
        worker-app)   echo "${ISO_BASE_URL}/itl-talos-worker-app-amd64.iso" ;;
        *) die "Unknown role: $1 (expected: controlplane | worker-infra | worker-app)" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "  ITL Talos Offline USB Builder"
echo "  Role     : ${ROLE}"
echo "  Reg URL  : ${REG_URL}"
echo "══════════════════════════════════════════════════════"

# ── Step 1: Fetch bundle from Registration Service (if machine-id given) ──────
if [ -n "$MACHINE_ID" ]; then
    fetch_bundle_from_service
fi

# ── Step 2: Get the Talos ISO into the bundle ─────────────────────────────────
if [ -n "$TALOS_ISO_PATH" ]; then
    log "Copying provided ISO: ${TALOS_ISO_PATH}"
    cp "$TALOS_ISO_PATH" "${BUNDLE_DIR}/talos.iso"
else
    ISO_URL="${ISO_URL:-$(iso_url_for_role $ROLE)}"
    log "Downloading Talos ISO for role '${ROLE}' ..."
    log "  URL: ${ISO_URL}"
    curl \
        --location \
        --progress-bar \
        --output "${BUNDLE_DIR}/talos.iso" \
        "$ISO_URL" || die "ISO download failed"
fi
log "ISO ready: $(du -sh ${BUNDLE_DIR}/talos.iso | cut -f1)"

# ── Step 3: Copy machineconfig if provided ────────────────────────────────────
if [ -n "$MACHINE_CONFIG_PATH" ]; then
    cp "$MACHINE_CONFIG_PATH" "${BUNDLE_DIR}/machineconfig.yaml"
    log "machineconfig.yaml included from ${MACHINE_CONFIG_PATH}"
fi

# ── Step 4: Write bundle metadata ────────────────────────────────────────────
if [ ! -f "${BUNDLE_DIR}/reg-bundle.json" ]; then
    cat > "${BUNDLE_DIR}/reg-bundle.json" <<EOF
{
  "role":          "${ROLE}",
  "machine_id":    "",
  "reg_url":       "${REG_URL}",
  "install_mode":  "offline",
  "built_at":      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
fi

# ── Step 5: Write to device or build ISO ─────────────────────────────────────
if [ -n "$TARGET_OUTPUT" ]; then
    # Writing directly to a USB device
    if [ -b "$TARGET_OUTPUT" ]; then
        log "Writing offline bundle to USB device ${TARGET_OUTPUT} ..."

        # First: build the Alpine USB agent ISO (online-capable image)
        AGENT_ISO="${WORK_DIR}/usb-agent.iso"
        if [ -f "${DIST_DIR}/itl-talos-usb-agent-"*".iso" ] 2>/dev/null; then
            AGENT_ISO=$(ls -t "${DIST_DIR}/itl-talos-usb-agent-"*".iso" | head -1)
            log "Using existing USB agent ISO: ${AGENT_ISO}"
        else
            log "Building USB agent ISO ..."
            "${SCRIPT_DIR}/build-usb.sh"
            AGENT_ISO=$(ls -t "${DIST_DIR}/itl-talos-usb-agent-"*".iso" | head -1)
        fi

        # Write the Alpine agent ISO to the USB
        echo ""
        echo "  WARNING: ALL DATA ON ${TARGET_OUTPUT} WILL BE ERASED"
        printf "  Type 'yes' to continue: "
        read -r CONFIRM
        [ "$CONFIRM" = "yes" ] || die "Aborted"

        dd if="$AGENT_ISO" of="$TARGET_OUTPUT" bs=4M status=progress oflag=sync
        sync
        partprobe "$TARGET_OUTPUT" 2>/dev/null || true
        sleep 2

        # Find the first FAT partition and write the bundle to /itl/
        for part in "${TARGET_OUTPUT}1" "${TARGET_OUTPUT}p1"; do
            [ -b "$part" ] || continue
            MNT=$(mktemp -d)
            mount -t vfat "$part" "$MNT" 2>/dev/null || continue
            mkdir -p "${MNT}/itl"
            cp -r "${BUNDLE_DIR}/." "${MNT}/itl/"
            sync
            umount "$MNT" 2>/dev/null || true
            rmdir  "$MNT"
            log "Bundle written to ${part}/itl/"
            break
        done

        log "USB device ready: ${TARGET_OUTPUT}"
    else
        die "${TARGET_OUTPUT} is not a block device. Use --output-iso for ISO output."
    fi

elif [ -n "$OUTPUT_ISO" ]; then
    mkdir -p "$(dirname "$OUTPUT_ISO")"
    log "Building offline bundle ISO → ${OUTPUT_ISO}"

    # Build the Alpine agent ISO (all deps included in Docker build)
    "${SCRIPT_DIR}/build-usb.sh"
    AGENT_ISO=$(ls -t "${DIST_DIR}/itl-talos-usb-agent-"*".iso" | head -1)

    # Patch the ISO: add /itl/ bundle to the first partition
    # Use xorriso to append files to the existing ISO
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$AGENT_ISO" \
                -outdev "$OUTPUT_ISO" \
                -map "${BUNDLE_DIR}" /itl \
                -commit 2>/dev/null || {
            # xorriso not available with all options — just copy and add a tar
            cp "$AGENT_ISO" "$OUTPUT_ISO"
            log "Warning: could not embed bundle into ISO with xorriso."
            log "Bundle saved separately as: ${OUTPUT_ISO%.iso}-bundle.tar.gz"
            tar czf "${OUTPUT_ISO%.iso}-bundle.tar.gz" -C "${WORK_DIR}/bundle" itl/
        }
    else
        cp "$AGENT_ISO" "$OUTPUT_ISO"
        log "xorriso not found — bundle saved separately"
        tar czf "${OUTPUT_ISO%.iso}-bundle.tar.gz" -C "${WORK_DIR}/bundle" itl/
        log "  Copy to USB EFI partition: ${OUTPUT_ISO%.iso}-bundle.tar.gz"
        log "  Then: tar xzf bundle.tar.gz -C /mnt/efi/"
    fi

    log "Offline ISO ready: ${OUTPUT_ISO}"
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Offline USB provisioning bundle complete!"
echo ""
echo "  Boot the USB on the target hardware."
echo "  The provisioner will automatically use the pre-baked"
echo "  Talos ISO and machineconfig (no network required)."
echo ""
if [ -z "$MACHINE_ID" ]; then
    echo "  IMPORTANT: After Talos boots, import the TPM receipt"
    echo "  into the Registration Service:"
    echo ""
    echo "    Mount the EFI partition and:"
    echo "    curl -X POST ${REG_URL}/api/v1/machines/import \\"
    echo "         -H 'Authorization: Bearer <ADMIN_TOKEN>' \\"
    echo "         -d @/mnt/efi/EFI/itl/tpm-receipt.json"
fi
echo "══════════════════════════════════════════════════════════"
