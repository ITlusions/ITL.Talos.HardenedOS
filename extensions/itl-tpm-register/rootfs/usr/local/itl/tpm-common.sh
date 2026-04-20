#!/bin/sh
# tpm-common.sh — shared helpers for all ITL TPM scripts
# Sourced by tpm-register.sh and tpm-attest.sh
# ─────────────────────────────────────────────────────────────────────────────

# The Registration Service endpoint is read from the kernel command line:
#   itl.reg_url=https://reg.itlusions.com
# Falls back to the default endpoint if not set.
REG_URL="${ITL_REG_URL:-}"
if [ -z "$REG_URL" ]; then
    REG_URL=$(grep -oP 'itl\.reg_url=\K[^\s]+' /proc/cmdline 2>/dev/null || true)
fi
REG_URL="${REG_URL:-https://reg.itlusions.com}"

STATE_DIR="/var/lib/itl-tpm"
ATTESTED_FLAG="${STATE_DIR}/attested"
EK_CERT_PEM="${STATE_DIR}/ek_cert.pem"
EK_PUB_PEM="${STATE_DIR}/ek_pub.pem"

log() { echo "[itl-tpm] $(date -Iseconds) $*"; }

die() { log "ERROR: $*"; exit 1; }

# ── read_hw_identity ─────────────────────────────────────────────────────────
# Collects hardware identity fields: MAC, SMBIOS UUID, chassis serial.
read_hw_identity() {
    HW_MAC=$(cat /sys/class/net/$(ip -o link show | grep -v lo | awk 'NR==1{print $2}' | tr -d :)/address 2>/dev/null || echo "unknown")
    HW_UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "unknown")
    HW_SERIAL=$(cat /sys/class/dmi/id/chassis_serial 2>/dev/null || echo "unknown")
    HW_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr ' ' '_' || echo "unknown")
}

# ── read_tpm_ek ──────────────────────────────────────────────────────────────
# Reads TPM EK certificate (X.509 DER in NV index 0x01c00002) and converts
# to PEM.  Falls back to reading the EK public key if no cert is provisioned
# (some older/non-OEM TPMs).
read_tpm_ek() {
    mkdir -p "$STATE_DIR"

    # Flush any lingering transient handles
    /usr/local/bin/tpm2_flushcontext --transient-object 2>/dev/null || true

    # Try EK certificate first (OEM-provisioned in NV, more authoritative)
    if /usr/local/bin/tpm2_getekcertificate \
            --ek-certificate "$STATE_DIR/ek_cert.der" \
            --offline 2>/dev/null; then
        openssl x509 -in "$STATE_DIR/ek_cert.der" \
            -inform DER -out "$EK_CERT_PEM" 2>/dev/null && \
            log "EK certificate read from NV (OEM-provisioned)" && \
            EK_SOURCE="cert" && return 0
    fi

    # Fall back: create a transient EK and export the public key
    log "No OEM EK cert found — exporting EK public key"
    /usr/local/bin/tpm2_createek \
        --ek-context "$STATE_DIR/ek.ctx" \
        --key-algorithm rsa \
        --public "$STATE_DIR/ek_pub.pem" 2>/dev/null || \
        die "Failed to read or create TPM EK"

    EK_SOURCE="pub"
    EK_CERT_PEM="$EK_PUB_PEM"
    log "EK public key exported"
}

# ── ek_fingerprint ───────────────────────────────────────────────────────────
# Returns a stable SHA-256 fingerprint of the EK material.
ek_fingerprint() {
    openssl dgst -sha256 "$EK_CERT_PEM" | awk '{print $NF}'
}
