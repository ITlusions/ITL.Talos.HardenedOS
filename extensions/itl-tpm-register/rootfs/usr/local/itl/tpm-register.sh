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

# Global state for two-layer enrollment key encryption
WRAP_CTX=""          # loaded TPM wrapping key context (for tpm2_rsadecrypt)
WRAP_SRK_CTX=""      # SRK context reused for sealing (Layer 2)
WRAP_KEY_PEM=""      # RSA-2048 public key PEM to include in cert request
ENROLLMENT_KEY_SEALED=0          # 1 when TPM-sealing of at-rest key succeeded
ENROLLMENT_KEY_ENC_FILE=""       # temp path: AES-GCM encrypted enrollment key
ENROLLMENT_SEAL_PUB_FILE=""      # temp path: TPM seal object public area
ENROLLMENT_SEAL_PRIV_FILE=""     # temp path: TPM seal object private area

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

# ── Layer 1: generate TPM wrapping key ───────────────────────────────────────
# Creates an unrestricted RSA-2048 OAEP-SHA256 decrypt key inside the TPM.
# The public half is sent with the cert request; the server encrypts the
# enrollment private key so only this specific TPM can decrypt it.
# fixedtpm|fixedparent|noda: private key is hardware-bound, non-exportable.
generate_wrapping_key() {
    log "Generating TPM wrapping key (Layer 1 transport protection)..."

    local wrap_srk wrap_pub_bin wrap_priv_bin wrap_pub_pem
    wrap_srk=$(mktemp)
    wrap_pub_bin=$(mktemp)
    wrap_priv_bin=$(mktemp)
    wrap_pub_pem=$(mktemp)

    set +e
    tpm2_createprimary -C o -G rsa -c "$wrap_srk" 2>/dev/null
    local rc_srk=$?
    tpm2_create \
        -C "$wrap_srk" \
        -G rsa2048:oaep:sha256 \
        -u "$wrap_pub_bin" \
        -r "$wrap_priv_bin" \
        -a "decrypt|fixedtpm|fixedparent|noda" \
        2>/dev/null
    local rc_create=$?
    local wrap_ctx
    wrap_ctx=$(mktemp)
    tpm2_load -C "$wrap_srk" -u "$wrap_pub_bin" -r "$wrap_priv_bin" -c "$wrap_ctx" 2>/dev/null
    local rc_load=$?
    tpm2_readpublic -c "$wrap_ctx" --output "$wrap_pub_pem" --format pem 2>/dev/null
    local rc_pub=$?
    set -e

    rm -f "$wrap_pub_bin" "$wrap_priv_bin"

    if [ "$rc_srk" -eq 0 ] && [ "$rc_create" -eq 0 ] && \
       [ "$rc_load" -eq 0 ] && [ "$rc_pub" -eq 0 ] && [ -s "$wrap_pub_pem" ]; then
        WRAP_CTX="$wrap_ctx"
        WRAP_SRK_CTX="$wrap_srk"
        WRAP_KEY_PEM=$(cat "$wrap_pub_pem")
        rm -f "$wrap_pub_pem"
        log "TPM wrapping key ready — enrollment key will be transport-encrypted (Layer 1)"
    else
        rm -f "$wrap_pub_pem" "$wrap_ctx" "$wrap_srk"
        WRAP_CTX=""
        WRAP_SRK_CTX=""
        WRAP_KEY_PEM=""
        log "WARN: Could not create TPM wrapping key — enrollment key travels over TLS only"
    fi
}

# ── Layer 2: TPM-seal enrollment key at rest ─────────────────────────────────
# After the Layer 1 decrypt, the enrollment key is briefly in memory.
# This function AES-256-CBC encrypts it and seals the AES key under the TPM
# Storage hierarchy (fixedtpm|fixedparent = hardware-bound).
# The seal object can be loaded on any later boot of this same TPM chip
# without a PCR policy, making it portable across Alpine → Talos reboots.
seal_enrollment_key() {
    log "TPM-sealing enrollment key (Layer 2 at-rest protection)..."

    local key_tmp aes_key enc_tmp seal_pub seal_priv srk_ctx
    key_tmp=$(mktemp)
    aes_key=$(mktemp)
    enc_tmp=$(mktemp)
    seal_pub=$(mktemp)
    seal_priv=$(mktemp)

    printf '%s' "$ENROLLMENT_KEY" > "$key_tmp"
    openssl rand 32 > "$aes_key"

    # AES-256-CBC encrypt the enrollment key PEM with the random AES key
    set +e
    openssl enc -aes-256-cbc -pbkdf2 \
        -in  "$key_tmp" \
        -out "$enc_tmp" \
        -pass file:"$aes_key" 2>/dev/null
    local rc_enc=$?
    set -e
    rm -f "$key_tmp"

    if [ "$rc_enc" -ne 0 ]; then
        log "WARN: AES encryption failed — enrollment key will be written as plaintext"
        rm -f "$aes_key" "$enc_tmp" "$seal_pub" "$seal_priv"
        return 0
    fi

    # Seal the AES key in the TPM under the Storage (Owner) hierarchy.
    # Reuse the SRK from generate_wrapping_key() when available so we make
    # only one tpm2_createprimary call per registration.
    if [ -n "$WRAP_SRK_CTX" ] && [ -f "$WRAP_SRK_CTX" ]; then
        srk_ctx="$WRAP_SRK_CTX"
    else
        srk_ctx=$(mktemp)
        set +e
        tpm2_createprimary -C o -G rsa -c "$srk_ctx" 2>/dev/null
        set -e
    fi

    set +e
    tpm2_create \
        -C "$srk_ctx" \
        -i "$aes_key" \
        -u "$seal_pub" \
        -r "$seal_priv" \
        -a "fixedtpm|fixedparent|noda" \
        2>/dev/null
    local rc_seal=$?
    set -e

    # Destroy the AES key from disk immediately — it now lives only in the TPM
    rm -f "$aes_key"

    # Clean up SRK context unless it belongs to the wrapping key flow
    [ "$srk_ctx" != "$WRAP_SRK_CTX" ] && rm -f "$srk_ctx"

    if [ "$rc_seal" -ne 0 ]; then
        log "WARN: TPM seal failed — enrollment key will be written as plaintext"
        rm -f "$enc_tmp" "$seal_pub" "$seal_priv"
        return 0
    fi

    ENROLLMENT_KEY_ENC_FILE="$enc_tmp"
    ENROLLMENT_SEAL_PUB_FILE="$seal_pub"
    ENROLLMENT_SEAL_PRIV_FILE="$seal_priv"
    ENROLLMENT_KEY_SEALED=1
    log "Enrollment key sealed: AES-256-CBC ciphertext + TPM seal objects ready"
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

# ── Step 5a: Request enrollment certificate ──────────────────────────────────
# Ask the Registration Service to issue an enrollment cert for this machine.
# No admin token required — the EK material is the authentication credential.
#
# If a TPM wrapping key was generated (generate_wrapping_key), its public key
# is included in the request.  The server encrypts the enrollment private key
# with RSA-OAEP-SHA256 (Layer 1).  The USB agent then decrypts it using
# tpm2_rsadecrypt and immediately TPM-seals it for at-rest protection (Layer 2).
#
# The cert + sealed key are saved to the EFI partition so tpm-attest.sh can
# use them on first Talos boot without network access.
request_enrollment_cert() {
    # Build JSON payload — include wrapping key when available
    if [ -n "$WRAP_KEY_PEM" ]; then
        CERT_PAYLOAD=$(jq -n \
            --arg ek_fingerprint   "$EK_FP" \
            --arg ek_cert_pem      "$EK_B64" \
            --arg ek_source        "$EK_SOURCE" \
            --arg wrapping_key_pem "$WRAP_KEY_PEM" \
            '{ek_fingerprint: $ek_fingerprint, ek_cert_pem: $ek_cert_pem,
              ek_source: $ek_source, wrapping_key_pem: $wrapping_key_pem}')
    else
        CERT_PAYLOAD=$(cat <<EOF
{
  "ek_fingerprint": "${EK_FP}",
  "ek_cert_pem": "${EK_B64}",
  "ek_source": "${EK_SOURCE}"
}
EOF
)
    fi

    log "Requesting enrollment certificate from ${REG_URL}/api/v1/machines/${MACHINE_ID}/request-cert ..."

    CERT_RESPONSE_FILE=$(mktemp)
    set +e
    curl \
        --silent \
        --fail \
        --request POST \
        --header "Content-Type: application/json" \
        --data "$CERT_PAYLOAD" \
        --output "$CERT_RESPONSE_FILE" \
        "${REG_URL}/api/v1/machines/${MACHINE_ID}/request-cert"
    CURL_RC=$?
    set -e

    if [ "$CURL_RC" -ne 0 ]; then
        log "WARN: Enrollment cert request failed (curl exit $CURL_RC) — machine will fall back to TPM attestation on first boot"
        rm -f "$CERT_RESPONSE_FILE"
        # Clean up wrapping key resources
        rm -f "$WRAP_CTX" "$WRAP_SRK_CTX"
        WRAP_CTX="" ; WRAP_SRK_CTX=""
        ENROLLMENT_CERT="" ; ENROLLMENT_KEY="" ; ENROLLMENT_CA=""
        return 0
    fi

    CERT_RESPONSE=$(cat "$CERT_RESPONSE_FILE")
    rm -f "$CERT_RESPONSE_FILE"

    ENROLLMENT_CERT=$(printf '%s' "$CERT_RESPONSE" | jq -r '.enrollment_cert_pem // empty')
    ENROLLMENT_CA=$(printf '%s' "$CERT_RESPONSE"   | jq -r '.enrollment_ca_pem // empty')
    CERT_VALID_DAYS=$(printf '%s' "$CERT_RESPONSE" | jq -r '.valid_days // "30"')

    # ── Layer 1 decrypt: RSA-OAEP with TPM wrapping key ─────────────────────
    ENROLLMENT_KEY_ENC_B64=$(printf '%s' "$CERT_RESPONSE" | jq -r '.enrollment_key_encrypted_b64 // empty')
    ENROLLMENT_KEY_PLAIN=$(printf '%s' "$CERT_RESPONSE"   | jq -r '.enrollment_key_pem // empty')

    if [ -n "$ENROLLMENT_KEY_ENC_B64" ] && [ -n "$WRAP_CTX" ]; then
        log "Decrypting enrollment key with TPM wrapping key (Layer 1)..."
        local enc_bin decrypted_key
        enc_bin=$(mktemp)
        decrypted_key=$(mktemp)

        printf '%s' "$ENROLLMENT_KEY_ENC_B64" | base64 -d > "$enc_bin"

        set +e
        tpm2_rsadecrypt \
            --key-context "$WRAP_CTX" \
            --input  "$enc_bin" \
            --output "$decrypted_key" \
            2>/dev/null
        local rc_dec=$?
        set -e

        rm -f "$enc_bin"
        rm -f "$WRAP_CTX" "$WRAP_SRK_CTX"
        WRAP_CTX="" ; WRAP_SRK_CTX=""

        if [ "$rc_dec" -eq 0 ] && [ -s "$decrypted_key" ]; then
            ENROLLMENT_KEY=$(cat "$decrypted_key")
            rm -f "$decrypted_key"
            log "Layer 1 decrypt OK — enrollment key recovered from TPM wrapping"
        else
            rm -f "$decrypted_key"
            log "WARN: TPM Layer 1 decrypt failed (rc=$rc_dec) — attempting plaintext fallback"
            ENROLLMENT_KEY="$ENROLLMENT_KEY_PLAIN"
        fi
    else
        # No wrapping key / server returned plaintext — clean up any leftover contexts
        rm -f "$WRAP_CTX" "$WRAP_SRK_CTX"
        WRAP_CTX="" ; WRAP_SRK_CTX=""
        ENROLLMENT_KEY="$ENROLLMENT_KEY_PLAIN"
    fi

    if [ -z "$ENROLLMENT_CERT" ] || [ -z "$ENROLLMENT_KEY" ] || [ -z "$ENROLLMENT_CA" ]; then
        log "WARN: Enrollment cert response was incomplete — certificate not saved"
        ENROLLMENT_CERT=""
        return 0
    fi

    # ── Layer 2: TPM-seal the decrypted key at rest ──────────────────────────
    seal_enrollment_key

    log "Enrollment certificate obtained (valid ${CERT_VALID_DAYS} days, sealed=${ENROLLMENT_KEY_SEALED})"
}


# ── Step 5b: Save registration receipt and enrollment cert to EFI partition ──
# Talos ISOs include a small FAT EFI partition.  We write a lightweight
# receipt file there so the machine can read config_token on first boot
# without needing a separate config URL argument.
#
# If an enrollment cert was obtained (step 5a), we also write the cert + key
# and CA cert to /itl/ on the EFI partition.  tpm-attest.sh on first Talos
# boot looks for these files and uses them for certificate-based self-enrollment,
# allowing the machine to work fully offline from that point on.
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

            # Write enrollment cert files if we received them from the service.
            # These are read by tpm-attest.sh on first Talos boot.
            if [ -n "$ENROLLMENT_CERT" ]; then
                printf '%s' "$ENROLLMENT_CERT" > "${MOUNT_DIR}/itl/enrollment.crt"
                printf '%s' "$ENROLLMENT_CA"   > "${MOUNT_DIR}/itl/enrollment-ca.crt"

                if [ "$ENROLLMENT_KEY_SEALED" = "1" ] \
                   && [ -s "$ENROLLMENT_KEY_ENC_FILE" ] \
                   && [ -s "$ENROLLMENT_SEAL_PUB_FILE" ] \
                   && [ -s "$ENROLLMENT_SEAL_PRIV_FILE" ]; then
                    # Layer 2 sealed: write ciphertext + TPM seal objects.
                    # enrollment.key is intentionally absent — tpm-attest.sh
                    # will detect seal.pub/priv and unseal before use.
                    cp "$ENROLLMENT_KEY_ENC_FILE"  "${MOUNT_DIR}/itl/enrollment.key.enc"
                    cp "$ENROLLMENT_SEAL_PUB_FILE" "${MOUNT_DIR}/itl/enrollment.seal.pub"
                    cp "$ENROLLMENT_SEAL_PRIV_FILE" "${MOUNT_DIR}/itl/enrollment.seal.priv"
                    rm -f "$ENROLLMENT_KEY_ENC_FILE" "$ENROLLMENT_SEAL_PUB_FILE" "$ENROLLMENT_SEAL_PRIV_FILE"
                    log "Enrollment cert + TPM-sealed key written to EFI /itl/"
                    log "  enrollment.crt         — X.509 enrollment certificate"
                    log "  enrollment.key.enc     — AES-256-CBC ciphertext (Layer 2)"
                    log "  enrollment.seal.pub    — TPM seal object public area"
                    log "  enrollment.seal.priv   — TPM seal object private area"
                    log "  enrollment-ca.crt      — Enrollment CA certificate"
                else
                    # Fallback: no TPM / sealing failed — write plaintext key
                    printf '%s' "$ENROLLMENT_KEY" > "${MOUNT_DIR}/itl/enrollment.key"
                    rm -f "$ENROLLMENT_KEY_ENC_FILE" "$ENROLLMENT_SEAL_PUB_FILE" "$ENROLLMENT_SEAL_PRIV_FILE"
                    log "Enrollment cert + key written to EFI /itl/ (TLS-only protection — no TPM seal)"
                    log "  enrollment.crt     — X.509 enrollment certificate"
                    log "  enrollment.key     — plaintext private key (protect physical access!)"
                    log "  enrollment-ca.crt  — Enrollment CA certificate"
                fi
            else
                log "No enrollment cert obtained — node will use TPM attestation on first boot"
            fi

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
generate_wrapping_key
register_machine
download_iso
write_iso
request_enrollment_cert
write_receipt
do_reboot
