#!/bin/sh
# tpm-register.sh — USB Agent first-time machine registration
#
# Run from the Alpine Linux USB registration environment (NOT from Talos).
# Registers the machine's TPM EK + hardware identity with the ITL Registration
# Service, downloads the correct role-specific Talos ISO, writes it to the
# target disk, and reboots.
#
# Usage (on the Alpine USB environment):
#   ITL_REG_URL=https://reg.itlusions.com \
#   ITL_TARGET_DISK=/dev/sda \
#   ITL_ROLE=controlplane \
#   /usr/local/itl/tpm-register.sh
#
# Environment variables:
#   ITL_REG_URL       Registration Service base URL (required)
#   ITL_TARGET_DISK   Disk to install Talos onto (required, e.g. /dev/sda)
#   ITL_ROLE          Desired node role: controlplane | worker-infra | worker-app
#                     (optional — service assigns role based on pre-registration
#                      or prompts operator for approval)
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(dirname "$0")"
. "${SCRIPT_DIR}/tpm-common.sh"

TARGET_DISK="${ITL_TARGET_DISK:-}"
DESIRED_ROLE="${ITL_ROLE:-}"

banner() {
    echo "══════════════════════════════════════════════════════"
    echo "  ITL Talos Node Registration"
    echo "  Registration Service: ${REG_URL}"
    echo "══════════════════════════════════════════════════════"
}

# ── Pre-flight checks ────────────────────────────────────────────────────────
preflight() {
    for cmd in tpm2_getekcertificate tpm2_createek tpm2_flushcontext curl jq openssl; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done

    [ -n "$TARGET_DISK" ] || die "ITL_TARGET_DISK is not set (e.g. /dev/sda)"
    [ -b "$TARGET_DISK" ] || die "Target disk not found: $TARGET_DISK"
    log "Pre-flight OK — target disk: $TARGET_DISK"
}

# ── Step 1: Collect hardware identity ────────────────────────────────────────
collect_identity() {
    read_hw_identity
    read_tpm_ek
    EK_FP=$(ek_fingerprint)
    EK_B64=$(base64 -w0 < "$EK_CERT_PEM")

    log "Hardware identity collected:"
    log "  UUID   : ${HW_UUID}"
    log "  MAC    : ${HW_MAC}"
    log "  Serial : ${HW_SERIAL}"
    log "  Product: ${HW_PRODUCT}"
    log "  EK fp  : ${EK_FP} (source: ${EK_SOURCE})"
}

# ── Step 2: Register with Registration Service ────────────────────────────────
register_machine() {
    PAYLOAD=$(cat <<EOF
{
  "ek_fingerprint": "${EK_FP}",
  "ek_cert_pem": "${EK_B64}",
  "ek_source": "${EK_SOURCE}",
  "hw_uuid": "${HW_UUID}",
  "hw_mac": "${HW_MAC}",
  "hw_serial": "${HW_SERIAL}",
  "hw_product": "${HW_PRODUCT}",
  "desired_role": "${DESIRED_ROLE}"
}
EOF
)

    log "Registering machine with ${REG_URL}/api/v1/register ..."

    RESPONSE=$(curl \
        --silent \
        --fail \
        --max-time 30 \
        --retry 5 \
        --retry-delay 10 \
        --retry-connrefused \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${REG_URL}/api/v1/register") || die "Registration failed — is the Registration Service reachable at ${REG_URL}?"

    MACHINE_ID=$(jq -r '.machine_id'      <<< "$RESPONSE")
    ROLE=$(jq       -r '.role'             <<< "$RESPONSE")
    ISO_URL=$(jq    -r '.iso_url'          <<< "$RESPONSE")
    CONFIG_TOKEN=$(jq -r '.config_token'   <<< "$RESPONSE")
    STATUS=$(jq     -r '.status'           <<< "$RESPONSE")

    log "Registration response:"
    log "  machine_id   : ${MACHINE_ID}"
    log "  role         : ${ROLE}"
    log "  status       : ${STATUS}"
    log "  iso_url      : ${ISO_URL}"

    [ -n "$MACHINE_ID" ] || die "Empty machine_id in response — registration rejected"
    [ -n "$ISO_URL" ]    || die "Empty iso_url in response"
}

# ── Step 3: Download role-specific Talos ISO ──────────────────────────────────
download_iso() {
    ISO_FILE="/tmp/talos-${ROLE}.iso"
    log "Downloading ISO: ${ISO_URL}"
    log "  destination  : ${ISO_FILE}"

    curl \
        --location \
        --progress-bar \
        --output "$ISO_FILE" \
        --retry 3 \
        --retry-delay 5 \
        "$ISO_URL" || die "ISO download failed"

    # Verify checksum if the Registration Service provides one
    CHECKSUM_URL="${ISO_URL}.sha256"
    if curl --silent --fail --head "$CHECKSUM_URL" >/dev/null 2>&1; then
        log "Verifying ISO checksum..."
        EXPECTED=$(curl --silent --fail "$CHECKSUM_URL" | awk '{print $1}')
        ACTUAL=$(sha256sum "$ISO_FILE" | awk '{print $1}')
        [ "$EXPECTED" = "$ACTUAL" ] || die "ISO checksum mismatch — download may be corrupted"
        log "ISO checksum verified OK"
    fi

    ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
    log "ISO downloaded: ${ISO_SIZE}"
}

# ── Step 4: Write ISO to target disk ─────────────────────────────────────────
write_iso() {
    log "Writing ISO to ${TARGET_DISK}..."
    log "WARNING: This will DESTROY all data on ${TARGET_DISK}"

    # Confirm unless running non-interactively
    if [ -t 0 ]; then
        printf "  Confirm [yes/no]: "
        read -r CONFIRM
        [ "$CONFIRM" = "yes" ] || die "Aborted by user"
    fi

    # Unmount any existing partitions
    umount "${TARGET_DISK}"* 2>/dev/null || true

    dd if="$ISO_FILE" of="$TARGET_DISK" bs=4M status=progress oflag=sync
    sync

    log "ISO written to ${TARGET_DISK}"
}

# ── Step 5: Save registration receipt to a config partition ─────────────────
# Talos ISOs include a small FAT EFI partition.  We write a lightweight
# receipt file there so the machine can read config_token on first boot
# without needing a separate config URL argument.
write_receipt() {
    # Re-read partition table after dd
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 1

    EFI_PART=""
    for p in "${TARGET_DISK}1" "${TARGET_DISK}p1"; do
        [ -b "$p" ] && EFI_PART="$p" && break
    done

    if [ -n "$EFI_PART" ]; then
        MOUNT_DIR=$(mktemp -d)
        mount "$EFI_PART" "$MOUNT_DIR" 2>/dev/null && {
            mkdir -p "${MOUNT_DIR}/itl"
            cat > "${MOUNT_DIR}/itl/registration.json" <<EOF
{
  "machine_id":   "${MACHINE_ID}",
  "ek_fingerprint": "${EK_FP}",
  "role":         "${ROLE}",
  "config_token": "${CONFIG_TOKEN}",
  "reg_url":      "${REG_URL}",
  "registered_at": "$(date -Iseconds)"
}
EOF
            sync
            umount "$MOUNT_DIR" 2>/dev/null || true
            rmdir  "$MOUNT_DIR"
            log "Registration receipt written to EFI partition"
        } || log "WARN: Could not mount EFI partition — receipt not written (non-fatal)"
    fi
}

# ── Step 6: Reboot ────────────────────────────────────────────────────────────
do_reboot() {
    log "Installation complete — rebooting into Talos in 5 seconds..."
    log "After reboot the node will fetch its machineconfig from:"
    log "  ${REG_URL}/api/v1/config/${CONFIG_TOKEN}"
    sleep 5
    reboot
}

# ─────────────────────────────────────────────────────────────────────────────
banner
preflight
collect_identity
register_machine
download_iso
write_iso
write_receipt
do_reboot
