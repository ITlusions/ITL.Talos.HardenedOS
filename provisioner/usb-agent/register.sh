#!/bin/sh
# ITL Talos Node Registration — Alpine USB Agent
#
# This script is pre-baked into the Alpine Linux USB image.
# It runs automatically on boot (via /etc/local.d/itl-register.start)
# and performs ONE of two flows:
#
# ── ONLINE mode (default) ────────────────────────────────────────────────────
#   1. Read TPM EK cert from hardware
#   2. Collect SMBIOS hardware identity
#   3. Register with the ITL Registration Service
#   4. Download the role-specific Talos ISO
#   5. Write ISO to the target disk
#   6. Reboot into Talos (config fetched by node from Registration Service)
#
# ── OFFLINE mode (airgapped / pre-provisioned) ───────────────────────────────
#   Activated when ITL_OFFLINE=yes, itl.offline=yes kernel arg, or when the
#   Registration Service is unreachable and /itl/talos.iso exists on the USB.
#
#   The USB drive must contain (on any mounted partition under /mnt/usb/):
#     /itl/talos.iso         — pre-downloaded Talos role ISO
#     /itl/machineconfig.yaml — (optional) pre-generated Talos machineconfig
#     /itl/reg-bundle.json   — (optional) JSON with machine_id, role, config_url
#
#   Flow:
#   1. Read TPM EK + hardware identity (recorded to /itl/tpm-receipt.json)
#   2. Use pre-baked ISO (no network download)
#   3. Write ISO to target disk
#   4. Inject machineconfig.yaml into EFI partition (if provided)
#   5. Reboot into Talos
#
# Environment variables (set via /etc/itl-reg.conf or kernel args):
#   ITL_REG_URL        Registration Service base URL
#                      (default: https://reg.itlusions.com)
#   ITL_OFFLINE        Force offline mode: yes | no | auto
#                      (default: auto — falls back if service unreachable)
#   ITL_USB_BUNDLE_DIR Path to directory containing offline bundle
#                      (default: auto-mounted from USB)
#   ITL_TARGET_DISK    Target disk device (e.g. /dev/sda)
#                      (default: auto-detect first non-USB block device)
#   ITL_ROLE           Desired node role: controlplane | worker-infra | worker-app
#                      (default: worker-app)
#   ITL_AUTO_CONFIRM   Set to "yes" to skip the confirmation prompt
#                      (default: empty — interactive)
# ─────────────────────────────────────────────────────────────────────────────

set -e

STATE_DIR="/tmp/itl-reg"
USB_BUNDLE_MNT="/mnt/itl-usb"
mkdir -p "$STATE_DIR" "$USB_BUNDLE_MNT"

# ── Load config from /etc/itl-reg.conf if present ───────────────────────────
[ -f /etc/itl-reg.conf ] && . /etc/itl-reg.conf

# ── Read kernel args for override ────────────────────────────────────────────
_karg() {
    grep -oP "(?<=$1=)\S+" /proc/cmdline 2>/dev/null || true
}
REG_URL="${ITL_REG_URL:-$(_karg itl.reg_url)}"
REG_URL="${REG_URL:-https://reg.itlusions.com}"
DESIRED_ROLE="${ITL_ROLE:-$(_karg itl.role)}"
DESIRED_ROLE="${DESIRED_ROLE:-worker-app}"
AUTO_CONFIRM="${ITL_AUTO_CONFIRM:-$(_karg itl.auto_confirm)}"
OFFLINE_MODE="${ITL_OFFLINE:-$(_karg itl.offline)}"
OFFLINE_MODE="${OFFLINE_MODE:-auto}"
BUNDLE_DIR="${ITL_USB_BUNDLE_DIR:-}"

# ─────────────────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

banner() {
    clear
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       ITL Talos Node Provisioner — USB Agent         ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Mode                 : ${OFFLINE_MODE}"
    echo "║  Registration Service : ${REG_URL}"
    echo "║  Desired Role         : ${DESIRED_ROLE}"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
}

# ── Find and mount the ITL bundle partition on the USB ───────────────────────
# The offline bundle is stored on a partition labelled ITL_BUNDLE or as a
# directory on the first FAT partition of the USB device.
find_bundle_dir() {
    # Explicit override wins
    if [ -n "$BUNDLE_DIR" ] && [ -d "$BUNDLE_DIR" ]; then
        echo "$BUNDLE_DIR"
        return
    fi

    # Try label-based mount
    if blkid -L ITL_BUNDLE >/dev/null 2>&1; then
        DEV=$(blkid -L ITL_BUNDLE)
        mount "$DEV" "$USB_BUNDLE_MNT" 2>/dev/null || true
        [ -f "${USB_BUNDLE_MNT}/itl/talos.iso" ] && echo "${USB_BUNDLE_MNT}/itl" && return
    fi

    # Scan all vfat partitions for /itl/talos.iso
    for dev in /dev/sd?[0-9] /dev/nvme?n?p[0-9]; do
        [ -b "$dev" ] || continue
        FSTYPE=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
        [ "$FSTYPE" = "vfat" ] || continue
        MNT="${USB_BUNDLE_MNT}/$(basename $dev)"
        mkdir -p "$MNT"
        mount "$dev" "$MNT" 2>/dev/null || continue
        if [ -f "${MNT}/itl/talos.iso" ]; then
            echo "${MNT}/itl"
            return
        fi
        umount "$MNT" 2>/dev/null || true
    done

    echo ""
}

# ── Check whether the Registration Service is reachable ─────────────────────
service_reachable() {
    curl --silent --max-time 5 --fail "${REG_URL}/healthz" >/dev/null 2>&1
}

# ── Install required Alpine packages (if not already present) ────────────────
install_deps() {
    MISSING=""
    for cmd in tpm2_getekcertificate tpm2_createek tpm2_flushcontext \
               curl jq openssl; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
    done

    if [ -n "$MISSING" ]; then
        log "Installing missing packages for:$MISSING"
        apk add --no-cache tpm2-tools curl jq openssl 2>/dev/null || \
            die "apk install failed — is the USB image network-reachable or pre-baked?"
    fi
}

# ── Auto-detect target disk ──────────────────────────────────────────────────
detect_target_disk() {
    if [ -n "$ITL_TARGET_DISK" ]; then
        echo "$ITL_TARGET_DISK"
        return
    fi

    # List block devices, exclude the USB (sr*, loop*, the device we booted from)
    BOOT_DEV=$(cat /proc/cmdline | grep -oP 'root=\K\S+' | sed 's/[0-9]*$//' || true)
    for dev in /dev/nvme0n1 /dev/sda /dev/sdb /dev/vda; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$BOOT_DEV" ] && continue
        echo "$dev"
        return
    done

    # Interactive fallback
    echo ""
    log "Available block devices:"
    lsblk -dpno NAME,SIZE,MODEL 2>/dev/null || ls /dev/sd* /dev/nvme* 2>/dev/null || true
    printf "Enter target disk device (e.g. /dev/sda): "
    read -r TARGET
    echo "$TARGET"
}

# ── Read TPM EK certificate ──────────────────────────────────────────────────
read_tpm_ek() {
    EK_PEM="${STATE_DIR}/ek_cert.pem"
    EK_SOURCE="cert"

    # Flush any existing TPM contexts first
    tpm2_flushcontext --transient-object 2>/dev/null || true

    # Try OEM EK certificate from NV index 0x01c00002 (RSA-2048 EK cert)
    if tpm2_getekcertificate \
            --ek-certificate "$EK_PEM" \
            --nv-index 0x01c00002 \
            2>/dev/null; then
        log "EK certificate read from NV index 0x01c00002 (OEM-provisioned)"
    # Fallback: try ECC EK cert at 0x01c0000a
    elif tpm2_getekcertificate \
            --ek-certificate "$EK_PEM" \
            --nv-index 0x01c0000a \
            2>/dev/null; then
        log "EK certificate read from NV index 0x01c0000a (ECC)"
    else
        # No OEM cert — create a transient EK and export its public key
        log "No OEM EK certificate found — generating transient EK public key"
        tpm2_createek \
            --ek-context "${STATE_DIR}/ek.ctx" \
            --key-algorithm rsa \
            --public "${STATE_DIR}/ek.pub" \
            2>/dev/null || die "tpm2_createek failed — TPM not available or blocked"
        tpm2_readpublic \
            --object-context "${STATE_DIR}/ek.ctx" \
            --output "${STATE_DIR}/ek_pub.der" \
            2>/dev/null
        # Wrap as minimal PEM for consistent handling
        {
            echo "-----BEGIN PUBLIC KEY-----"
            base64 < "${STATE_DIR}/ek_pub.der" | fold -w 64
            echo "-----END PUBLIC KEY-----"
        } > "$EK_PEM"
        EK_SOURCE="pub"
        log "Transient EK public key written to ${EK_PEM}"
    fi

    EK_FP=$(openssl dgst -sha256 -hex "$EK_PEM" | awk '{print $2}')
    EK_B64=$(base64 -w0 < "$EK_PEM")
    log "EK fingerprint: ${EK_FP} (source: ${EK_SOURCE})"
}

# ── Collect SMBIOS hardware identity ─────────────────────────────────────────
read_hw_identity() {
    HW_UUID=$(cat /sys/class/dmi/id/product_uuid   2>/dev/null | tr -d '\n' | tr '[:upper:]' '[:lower:]' || echo "unknown")
    HW_SERIAL=$(cat /sys/class/dmi/id/chassis_serial 2>/dev/null | tr -d '\n' || echo "unknown")
    HW_PRODUCT=$(cat /sys/class/dmi/id/product_name  2>/dev/null | tr -d '\n' || echo "unknown")
    HW_MAC=$(cat /sys/class/net/eth0/address         2>/dev/null | tr -d '\n' || \
             ls /sys/class/net/ | grep -v lo | head -1 | xargs -I{} cat /sys/class/net/{}/address 2>/dev/null || \
             echo "00:00:00:00:00:00")
}

# ── Register machine ──────────────────────────────────────────────────────────
register() {
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

    log "Registering with ${REG_URL}/api/v1/register ..."

    RESPONSE=$(curl \
        --silent \
        --fail \
        --max-time 30 \
        --retry 5 \
        --retry-delay 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${REG_URL}/api/v1/register") || die "Registration call failed — check network and ${REG_URL}"

    MACHINE_ID=$(jq    -r '.machine_id'      <<< "$RESPONSE")
    ROLE=$(jq          -r '.role'             <<< "$RESPONSE")
    ISO_URL=$(jq       -r '.iso_url'          <<< "$RESPONSE")
    CONFIG_TOKEN=$(jq  -r '.config_token'     <<< "$RESPONSE")
    CONFIG_URL=$(jq    -r '.config_url'       <<< "$RESPONSE")

    log "Registered:"
    log "  machine_id   : ${MACHINE_ID}"
    log "  role         : ${ROLE}"
    log "  config_url   : ${CONFIG_URL}"
    log "  iso_url      : ${ISO_URL}"
}

# ── Download ISO ──────────────────────────────────────────────────────────────
download_iso() {
    ISO_FILE="${STATE_DIR}/talos.iso"
    log "Downloading Talos ISO for role '${ROLE}' ..."

    curl \
        --location \
        --progress-bar \
        --output "$ISO_FILE" \
        --retry 3 \
        "$ISO_URL" || die "ISO download failed from ${ISO_URL}"

    ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
    log "ISO downloaded: ${ISO_SIZE} — ${ISO_FILE}"
}

# ── Write ISO to disk ─────────────────────────────────────────────────────────
write_iso() {
    TARGET="$1"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  Target disk : ${TARGET}"
    log "  ISO size    : $(du -sh ${STATE_DIR}/talos.iso | cut -f1)"
    log "  WARNING     : ALL DATA ON ${TARGET} WILL BE DESTROYED"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$AUTO_CONFIRM" != "yes" ]; then
        printf "  Type 'yes' to continue: "
        read -r CONFIRM
        [ "$CONFIRM" = "yes" ] || die "Aborted by user"
    fi

    umount "${TARGET}"* 2>/dev/null || true

    log "Writing ISO to ${TARGET} ..."
    dd if="${STATE_DIR}/talos.iso" of="$TARGET" bs=4M status=progress oflag=sync
    sync
    log "Write complete"
}

# ── Embed config_url into EFI partition ──────────────────────────────────────
# The ISO already has the talos.config kernel arg pointing to our Registration
# Service.  If the CI baked a generic URL, we override it here by writing a
# small JSON file to the EFI partition that Talos reads on first boot.
# (Talos reads /EFI/itl/registration.json if present.)
embed_config_url() {
    TARGET="$1"
    partprobe "$TARGET" 2>/dev/null || true
    sleep 1

    for p in "${TARGET}1" "${TARGET}p1"; do
        [ -b "$p" ] || continue
        MOUNT=$(mktemp -d)
        if mount -t vfat "$p" "$MOUNT" 2>/dev/null; then
            mkdir -p "${MOUNT}/EFI/itl"
            cat > "${MOUNT}/EFI/itl/registration.json" <<EOF
{
  "machine_id":    "${MACHINE_ID}",
  "config_token":  "${CONFIG_TOKEN}",
  "config_url":    "${CONFIG_URL}",
  "reg_url":       "${REG_URL}",
  "role":          "${ROLE}",
  "ek_fingerprint": "${EK_FP}"
}
EOF
            sync
            umount "$MOUNT" 2>/dev/null || true
            rmdir  "$MOUNT"
            log "Config URL embedded in EFI partition: ${CONFIG_URL}"
        fi
        break
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# OFFLINE INSTALL
# Uses a pre-baked ISO (and optional machineconfig) from the USB bundle.
# No network required — TPM identity is still read and saved to the USB for
# later import into the Registration Service by an operator.
# ─────────────────────────────────────────────────────────────────────────────
offline_install() {
    local BUNDLE="$1"
    local TARGET="$2"

    OFFLINE_ISO="${BUNDLE}/talos.iso"
    OFFLINE_CONFIG="${BUNDLE}/machineconfig.yaml"
    OFFLINE_BUNDLE_JSON="${BUNDLE}/reg-bundle.json"

    [ -f "$OFFLINE_ISO" ] || die "Offline ISO not found at ${OFFLINE_ISO}"

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  OFFLINE INSTALL MODE"
    log "  ISO     : ${OFFLINE_ISO}  ($(du -sh $OFFLINE_ISO | cut -f1))"
    [ -f "$OFFLINE_CONFIG" ] && \
        log "  Config  : ${OFFLINE_CONFIG}"
    [ -f "$OFFLINE_BUNDLE_JSON" ] && \
        log "  Bundle  : ${OFFLINE_BUNDLE_JSON}"
    log "  Target  : ${TARGET}"
    log "  WARNING : ALL DATA ON ${TARGET} WILL BE DESTROYED"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$AUTO_CONFIRM" != "yes" ]; then
        printf "  Type 'yes' to continue: "
        read -r CONFIRM
        [ "$CONFIRM" = "yes" ] || die "Aborted by user"
    fi

    # Copy ISO into state dir so write_iso() can find it
    cp "$OFFLINE_ISO" "${STATE_DIR}/talos.iso"

    umount "${TARGET}"* 2>/dev/null || true
    log "Writing ISO to ${TARGET} ..."
    dd if="${STATE_DIR}/talos.iso" of="$TARGET" bs=4M status=progress oflag=sync
    sync
    log "Write complete"

    # Wait for partition table to settle
    partprobe "$TARGET" 2>/dev/null || true
    sleep 2

    # Inject machineconfig and/or receipt into EFI partition
    for p in "${TARGET}1" "${TARGET}p1"; do
        [ -b "$p" ] || continue
        MNT=$(mktemp -d)
        mount -t vfat "$p" "$MNT" 2>/dev/null || continue
        mkdir -p "${MNT}/EFI/itl"

        # Embed pre-generated machineconfig if provided
        if [ -f "$OFFLINE_CONFIG" ]; then
            cp "$OFFLINE_CONFIG" "${MNT}/EFI/itl/machineconfig.yaml"
            log "machineconfig.yaml written to EFI partition"
        fi

        # Read bundle metadata (role, machine_id, etc.) if present
        BUNDLE_ROLE="${DESIRED_ROLE}"
        BUNDLE_MACHINE_ID=""
        if [ -f "$OFFLINE_BUNDLE_JSON" ]; then
            BUNDLE_ROLE=$(jq -r '.role // empty' < "$OFFLINE_BUNDLE_JSON" || echo "$DESIRED_ROLE")
            BUNDLE_MACHINE_ID=$(jq -r '.machine_id // empty' < "$OFFLINE_BUNDLE_JSON" || echo "")
            cp "$OFFLINE_BUNDLE_JSON" "${MNT}/EFI/itl/reg-bundle.json"
        fi

        # Write TPM receipt so the operator can import this machine later
        cat > "${MNT}/EFI/itl/tpm-receipt.json" <<EOF
{
  "install_mode":   "offline",
  "machine_id":     "${BUNDLE_MACHINE_ID}",
  "role":           "${BUNDLE_ROLE}",
  "hw_uuid":        "${HW_UUID}",
  "hw_mac":         "${HW_MAC}",
  "hw_serial":      "${HW_SERIAL}",
  "hw_product":     "${HW_PRODUCT}",
  "ek_fingerprint": "${EK_FP}",
  "ek_source":      "${EK_SOURCE}",
  "installed_at":   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
        sync
        umount "$MNT" 2>/dev/null || true
        rmdir  "$MNT"
        log "TPM receipt written to EFI partition"
        break
    done

    log ""
    log "══════════════════════════════════════════════════════════"
    log "  Offline install complete!"
    log "  EK fingerprint: ${EK_FP}"
    log "  Role          : ${BUNDLE_ROLE:-${DESIRED_ROLE}}"
    if [ -z "$BUNDLE_MACHINE_ID" ]; then
        log ""
        log "  NOTE: This machine was NOT pre-registered."
        log "  After first Talos boot, import the TPM receipt:"
        log "    curl -X POST ${REG_URL}/api/v1/machines/import \\"
        log "         -H 'Authorization: Bearer <ADMIN_TOKEN>' \\"
        log "         -d @/mnt/<efi>/EFI/itl/tpm-receipt.json"
    fi
    log "  Rebooting into Talos in 5 seconds..."
    log "══════════════════════════════════════════════════════════"
    sleep 5
    reboot
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
banner
install_deps

TARGET_DISK=$(detect_target_disk)
[ -n "$TARGET_DISK" ] || die "Could not determine target disk"
log "Target disk: ${TARGET_DISK}"

log "─── Reading hardware identity ──────────────────────────────"
read_hw_identity
log "  UUID   : ${HW_UUID}"
log "  MAC    : ${HW_MAC}"
log "  Serial : ${HW_SERIAL}"
log "  Product: ${HW_PRODUCT}"

log "─── Reading TPM EK ────────────────────────────────────────"
read_tpm_ek

# ─── Determine install mode ──────────────────────────────────────────────────
if [ "$OFFLINE_MODE" = "yes" ]; then
    log "Offline mode forced via ITL_OFFLINE=yes"
    BUNDLE=$(find_bundle_dir)
    [ -n "$BUNDLE" ] || die "Offline mode requested but no bundle found on USB (need /itl/talos.iso)"
    offline_install "$BUNDLE" "$TARGET_DISK"
    exit 0
fi

# Auto mode: try online, fall back to offline if bundle exists and service is down
if [ "$OFFLINE_MODE" = "auto" ] && ! service_reachable; then
    BUNDLE=$(find_bundle_dir)
    if [ -n "$BUNDLE" ]; then
        log "Registration Service unreachable — falling back to offline install"
        offline_install "$BUNDLE" "$TARGET_DISK"
        exit 0
    else
        log "Warning: Registration Service unreachable and no offline bundle found"
        log "Retrying online registration (will die if still unreachable)..."
    fi
fi

# ─── ONLINE FLOW ─────────────────────────────────────────────────────────────
log "─── Step 1/4: Registering machine ─────────────────────────"
register

log "─── Step 2/4: Downloading Talos ISO ───────────────────────"
download_iso

log "─── Step 3/4: Writing ISO to disk ─────────────────────────"
write_iso "$TARGET_DISK"

log "─── Step 4/4: Embedding config URL ────────────────────────"
embed_config_url "$TARGET_DISK"

log ""
log "══════════════════════════════════════════════════════════"
log "  Provisioning complete!"
log "  machine_id: ${MACHINE_ID}"
log "  role      : ${ROLE}"
log "  config    : ${CONFIG_URL}"
log "  Rebooting into Talos in 5 seconds..."
log "══════════════════════════════════════════════════════════"
sleep 5
reboot
