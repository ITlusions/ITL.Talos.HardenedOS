#!/bin/sh
# tpm-attest.sh — Talos post-install attestation
#
# Called by the Talos extension service (machined unit) on first boot AFTER
# Talos has installed and the machine is running in metal mode.
#
# Flow:
#   1. Read TPM EK cert / public key
#   2. Generate a TPM PCR quote (PCRs 0-7 = firmware + boot chain)
#   3. POST to Registration Service /api/v1/attest with:
#        - ek_fingerprint
#        - ek_cert_pem  (base64)
#        - pcr_quote    (base64)
#        - hw_uuid, hw_mac, hw_serial
#   4. Registration Service verifies EK matches pre-registered machine
#      and returns { machine_id, status: "attested", hostname, role }
#   5. Write attestation receipt to STATE partition
#   6. If not yet registered (machine booted without USB agent), fall back
#      to auto-registration flow (operator must approve via UI/CLI)
#
# The script is IDEMPOTENT — if the attested flag file exists it exits 0
# without making any network calls.
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(dirname "$0")"
. "${SCRIPT_DIR}/tpm-common.sh"

# ── Idempotency check ────────────────────────────────────────────────────────
if [ -f "$ATTESTED_FLAG" ]; then
    log "Machine already attested ($(cat $ATTESTED_FLAG)) — skipping"
    exit 0
fi

log "Starting TPM attestation — endpoint: ${REG_URL}"

# ── Step 1: read hardware identity ──────────────────────────────────────────
read_hw_identity
log "HW identity: uuid=${HW_UUID} mac=${HW_MAC} serial=${HW_SERIAL}"

# ── Step 2: read TPM EK ─────────────────────────────────────────────────────
read_tpm_ek
EK_FP=$(ek_fingerprint)
log "EK fingerprint: ${EK_FP} (source: ${EK_SOURCE})"

EK_B64=$(base64 -w0 < "$EK_CERT_PEM")

# ── Step 3: certificate-based enrollment (offline-provisioned nodes only) ───
# If an enrollment cert + key were embedded in the machineconfig by the
# build-usb-offline.sh tool, use them for self-enrollment.
# This avoids the manual `POST /api/v1/machines/import` step.
ENROLL_CERT="${STATE_DIR}/enrollment.crt"
ENROLL_KEY="${STATE_DIR}/enrollment.key"
ENROLL_CA="${STATE_DIR}/enrollment-ca.crt"
ENROLL_KEY_TMPFS=0   # set to 1 when key was decrypted into /run (must delete after use)

# ── Unseal TPM-sealed enrollment key (Layer 2) ───────────────────────────────
# If the USB agent used seal_enrollment_key(), enrollment.key is absent and
# enrollment.key.enc + enrollment.seal.pub + enrollment.seal.priv are present
# instead.  Recreate the same Storage-hierarchy SRK (deterministic on this TPM),
# load and unseal the AES key, then AES-decrypt the key into /run (tmpfs).
# Sets ENROLL_KEY to the decrypted path and ENROLL_KEY_TMPFS=1.
# Silently returns if no sealed files are present (plain .key path is used).
unseal_enrollment_key() {
    local seal_pub="${STATE_DIR}/enrollment.seal.pub"
    local seal_priv="${STATE_DIR}/enrollment.seal.priv"
    local key_enc="${STATE_DIR}/enrollment.key.enc"

    [ -f "$seal_pub" ] && [ -f "$seal_priv" ] && [ -f "$key_enc" ] || return 0

    log "Sealed enrollment key detected — unsealing via TPM (Layer 2)..."

    local srk_ctx seal_ctx aes_key decrypted
    srk_ctx=$(mktemp)
    seal_ctx=$(mktemp)
    aes_key=$(mktemp)
    decrypted="/run/itl-enroll.key"   # /run is tmpfs on Talos

    set +e
    tpm2_createprimary -C o -G rsa -c "$srk_ctx" 2>/dev/null ; local rc_srk=$?
    tpm2_load -C "$srk_ctx" -u "$seal_pub" -r "$seal_priv" -c "$seal_ctx" 2>/dev/null ; local rc_load=$?
    tpm2_unseal -c "$seal_ctx" -o "$aes_key" 2>/dev/null ; local rc_unseal=$?
    set -e

    rm -f "$srk_ctx" "$seal_ctx"

    if [ "$rc_srk" -ne 0 ] || [ "$rc_load" -ne 0 ] || [ "$rc_unseal" -ne 0 ]; then
        log "ERROR: TPM unseal failed (srk=$rc_srk load=$rc_load unseal=$rc_unseal)"
        log "ERROR: Cannot recover enrollment key — skipping cert-based enrollment"
        rm -f "$aes_key"
        # Signal to caller that the sealed path is broken
        ENROLL_CERT=""
        return 0
    fi

    set +e
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -in  "$key_enc" \
        -out "$decrypted" \
        -pass file:"$aes_key" 2>/dev/null
    local rc_dec=$?
    set -e

    rm -f "$aes_key"

    if [ "$rc_dec" -ne 0 ]; then
        log "ERROR: AES-256-CBC decrypt of enrollment key failed"
        log "ERROR: Skipping cert-based enrollment"
        rm -f "$decrypted"
        ENROLL_CERT=""
        return 0
    fi

    ENROLL_KEY="$decrypted"
    ENROLL_KEY_TMPFS=1
    log "Enrollment key unsealed and decrypted to /run (tmpfs)"
}

# Resolve sealed key first so ENROLL_KEY points to the right path before cert check.
# When Layer 2 sealing was used by the USB agent, enrollment.key is absent and
# enrollment.key.enc + seal.pub + seal.priv are present instead.
unseal_enrollment_key

if [ -f "$ENROLL_CERT" ] && [ -f "$ENROLL_KEY" ]; then
    log "Enrollment cert found — validating before use"
    # Verify the cert was issued by the ITL Enrollment CA, is not expired,
    # and the private key matches the cert before sending anything to the network.
    if [ ! -f "$ENROLL_CA" ]; then
        log "ERROR: Enrollment CA cert not found at $ENROLL_CA — cannot verify enrollment cert"
        log "ERROR: Skipping certificate enrollment (tampered or incomplete bundle?)"
        ENROLL_CERT=""
    else
        "${SCRIPT_DIR}/tpm-cert-check.sh" \
            "$ENROLL_CERT" "$ENROLL_KEY" "$ENROLL_CA" "$EK_FP" || {
                log "ERROR: Enrollment cert validation failed — skipping certificate enrollment"
                log "ERROR: The cert may be expired, tampered, or not issued by the ITL Enrollment CA"
                ENROLL_CERT=""
            }
    fi
fi

if [ -f "$ENROLL_CERT" ] && [ -f "$ENROLL_KEY" ]; then
    log "Enrollment cert validated — attempting certificate-based enrollment"

    # Generate a nonce and sign it with the enrollment private key to prove
    # key possession (prevents replay from an attacker with only the cert PEM)
    ENROLL_NONCE=$(openssl rand -hex 32)
    ENROLL_SIG=$(printf '%s' "$ENROLL_NONCE" \
        | openssl dgst -sha256 -sign "$ENROLL_KEY" -binary \
        | base64 -w0) || {
            log "WARN: Failed to sign enrollment nonce — skipping cert enrollment"
            ENROLL_CERT=""
        }

    if [ -n "$ENROLL_CERT" ]; then
        ENROLL_PAYLOAD=$(/usr/local/bin/jq -n \
            --rawfile cert   "$ENROLL_CERT" \
            --arg     nonce  "$ENROLL_NONCE" \
            --arg     sig    "$ENROLL_SIG" \
            '{cert_pem: $cert, nonce: $nonce, nonce_signature: $sig}')

        ENROLL_RESPONSE=$(/usr/local/bin/curl \
            --silent \
            --fail \
            --max-time 30 \
            --retry 3 \
            --retry-delay 5 \
            --retry-connrefused \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$ENROLL_PAYLOAD" \
            "${REG_URL}/api/v1/machines/enroll") && ENROLL_OK=true || ENROLL_OK=false

        if $ENROLL_OK; then
            ENROLL_STATUS=$(/usr/local/bin/jq -r '.status' <<< "$ENROLL_RESPONSE" 2>/dev/null || echo "unknown")
            MACHINE_ID=$(/usr/local/bin/jq -r '.machine_id' <<< "$ENROLL_RESPONSE" 2>/dev/null || echo "")
            if [ "$ENROLL_STATUS" = "attested" ]; then
                log "Certificate enrollment successful — machine_id=${MACHINE_ID}"
                echo "${MACHINE_ID}" > "$ATTESTED_FLAG"
                echo "$ENROLL_RESPONSE" > "${STATE_DIR}/attestation_receipt.json"
                # Delete the private key — no longer needed after enrollment.
                # When Layer 2 was used, ENROLL_KEY points to /run (tmpfs); also
                # clean the seal objects from STATE_DIR so they cannot be replayed.
                rm -f "$ENROLL_KEY"
                if [ "$ENROLL_KEY_TMPFS" = "1" ]; then
                    rm -f "${STATE_DIR}/enrollment.key.enc" \
                          "${STATE_DIR}/enrollment.seal.pub" \
                          "${STATE_DIR}/enrollment.seal.priv"
                    log "Sealed key objects deleted from STATE_DIR"
                fi
                log "Enrollment key deleted; cert retained for reference"
                exit 0
            fi
            log "WARN: Unexpected enrollment status: ${ENROLL_STATUS} — falling through to TPM attestation"
        else
            log "WARN: Certificate enrollment call failed — falling through to TPM attestation"
        fi
    fi
fi

# ── Step 4: generate PCR quote (PCRs 0-7 cover firmware + Secure Boot + GRUB)
# (Reached when no enrollment cert present, or cert enrollment failed)
NONCE=$(openssl rand -hex 20)
/usr/local/bin/tpm2_quote \
    --key-context "$STATE_DIR/ek.ctx" \
    --pcr-list "sha256:0,1,2,3,4,5,6,7" \
    --message    "$STATE_DIR/pcr_quote.bin" \
    --signature  "$STATE_DIR/pcr_sig.bin" \
    --qualification "$NONCE" \
    2>/dev/null || {
        log "WARN: PCR quote failed (TPM may not have signing key) — continuing without quote"
        touch "$STATE_DIR/pcr_quote.bin" "$STATE_DIR/pcr_sig.bin"
    }

PCR_QUOTE_B64=$(base64 -w0 < "$STATE_DIR/pcr_quote.bin")
PCR_SIG_B64=$(base64  -w0 < "$STATE_DIR/pcr_sig.bin")

# ── Step 5: POST attestation to Registration Service ────────────────────────
PAYLOAD=$(cat <<EOF
{
  "ek_fingerprint": "${EK_FP}",
  "ek_cert_pem": "${EK_B64}",
  "ek_source": "${EK_SOURCE}",
  "pcr_quote": "${PCR_QUOTE_B64}",
  "pcr_signature": "${PCR_SIG_B64}",
  "pcr_nonce": "${NONCE}",
  "hw_uuid": "${HW_UUID}",
  "hw_mac": "${HW_MAC}",
  "hw_serial": "${HW_SERIAL}",
  "hw_product": "${HW_PRODUCT}"
}
EOF
)

RESPONSE=$(/usr/local/bin/curl \
    --silent \
    --fail \
    --max-time 30 \
    --retry 5 \
    --retry-delay 10 \
    --retry-connrefused \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${REG_URL}/api/v1/attest") || {
        log "WARN: Attestation call failed — will retry on next boot"
        exit 0  # Non-fatal: don't block Talos boot
    }

# ── Step 6: parse response and persist receipt ───────────────────────────────
STATUS=$(/usr/local/bin/jq -r '.status' <<< "$RESPONSE" 2>/dev/null || echo "unknown")
ACTION=$(/usr/local/bin/jq -r '.action // "none"' <<< "$RESPONSE" 2>/dev/null || echo "none")
MACHINE_ID=$(/usr/local/bin/jq -r '.machine_id' <<< "$RESPONSE" 2>/dev/null || echo "")
HOSTNAME=$(/usr/local/bin/jq -r '.hostname // empty' <<< "$RESPONSE" 2>/dev/null || echo "")
CONFIG_URL=$(/usr/local/bin/jq -r '.config_url // empty' <<< "$RESPONSE" 2>/dev/null || echo "")

# ── Operator-triggered lock ───────────────────────────────────────────────────
# action=lock means the operator called POST /lock on this machine.
# The node writes a lock flag so other extensions/scripts can detect the state.
# Boot continues normally (non-fatal) but enrollment/cert renewal will not complete.
# When the operator calls POST /unlock, the next boot contact restores normal flow.
if [ "$ACTION" = "lock" ] || [ "$STATUS" = "locked" ]; then
    log "WARN: Machine ${MACHINE_ID} is LOCKED by operator — enrollment suspended"
    log "WARN: Node will continue running but cannot renew certs until unlocked"
    echo "locked:${MACHINE_ID}" > "${STATE_DIR}/locked"
    exit 0
fi

# ── Operator-triggered wipe / revocation ─────────────────────────────────────
# The Registration Service sets action=wipe when an operator has called
# POST /api/v1/machines/{id}/revoke?wipe=true.
# We wipe STATE + EPHEMERAL via the Talos machine API and reboot.
# The node comes up in maintenance mode (no Talos config, no cluster membership).
# After a wipe the operator can re-provision with a new USB agent run.
if [ "$ACTION" = "wipe" ]; then
    log "SECURITY: Operator-initiated wipe received for machine_id=${MACHINE_ID}"
    log "SECURITY: Wiping STATE and EPHEMERAL partitions — node will reboot into maintenance mode"
    echo "revoked_wipe:${MACHINE_ID}" > "${STATE_DIR}/revoked"

    # Primary: talosctl reset via the local machine API socket (available on Talos metal mode)
    if command -v talosctl >/dev/null 2>&1; then
        talosctl reset \
            --graceful=false \
            --reboot \
            --insecure \
            --nodes 127.0.0.1 \
            2>/dev/null && exit 0
    fi

    # Fallback: wipe known partition labels directly and force reboot.
    # Talos STATE and EPHEMERAL are on the same disk as the boot partition.
    # Determine the disk from the block device backing /var/lib/itl-tpm (STATE mount).
    DISK=""
    for d in /dev/sda /dev/vda /dev/nvme0n1 /dev/xvda; do
        [ -b "$d" ] && DISK="$d" && break
    done
    if [ -n "$DISK" ]; then
        log "SECURITY: Fallback wipe of ${DISK} STATE/EPHEMERAL partitions"
        # Zero the first 4 MB of each known Talos partition label
        for label in STATE EPHEMERAL; do
            PART=$(blkid -L "$label" 2>/dev/null || true)
            if [ -n "$PART" ]; then
                log "SECURITY: Zeroing partition ${PART} (label=${label})"
                dd if=/dev/zero of="$PART" bs=1M count=4 2>/dev/null || true
            fi
        done
    fi

    sync
    log "SECURITY: Wipe complete — rebooting"
    reboot -f
    exit 0
fi

# ── status=revoked without wipe ───────────────────────────────────────────────
if [ "$STATUS" = "revoked" ]; then
    log "WARN: Machine ${MACHINE_ID} has been revoked by operator (no wipe requested)"
    log "WARN: Node will continue running but cannot re-attest — contact operator"
    echo "revoked:${MACHINE_ID}" > "${STATE_DIR}/revoked"
    exit 0
fi

if [ "$STATUS" = "attested" ] || [ "$STATUS" = "already_attested" ]; then
    log "Attestation successful — machine_id=${MACHINE_ID} hostname=${HOSTNAME}"
    echo "${MACHINE_ID}" > "$ATTESTED_FLAG"
    echo "$RESPONSE"     > "${STATE_DIR}/attestation_receipt.json"
    # Clear any stale lock/pending flags — operator may have unlocked or approved
    rm -f "${STATE_DIR}/locked" "${STATE_DIR}/pending_approval"
    log "Attestation receipt saved to ${STATE_DIR}/attestation_receipt.json"

    # action=apply-config means the machine just attested for the first time
    # via the no-USB path (itl-tpm-register extension auto-registration).
    # Fetch the one-time config_url and apply the full MachineConfig so Talos
    # reboots into the cluster without requiring a USB pre-staging step.
    if [ "$ACTION" = "apply-config" ] && [ -n "$CONFIG_URL" ]; then
        log "Applying machine config from Registration Service (action=apply-config)"
        log "Config URL: ${CONFIG_URL}"
        TALOS_CFG=$(mktemp)
        if /usr/local/bin/curl \
                --silent \
                --fail \
                --max-time 30 \
                --retry 3 \
                --retry-delay 5 \
                -o "$TALOS_CFG" \
                "$CONFIG_URL"; then
            log "Config downloaded ($(wc -c < "$TALOS_CFG") bytes) — applying via talosctl"
            if talosctl apply-config \
                    --insecure \
                    --nodes 127.0.0.1 \
                    --file "$TALOS_CFG" \
                    2>/dev/null; then
                log "MachineConfig applied — Talos will reboot into the cluster"
                rm -f "$TALOS_CFG"
                exit 0
            else
                log "ERROR: talosctl apply-config failed — config saved to ${STATE_DIR}/pending.config"
                cp "$TALOS_CFG" "${STATE_DIR}/pending.config"
            fi
        else
            log "ERROR: Failed to download config from ${CONFIG_URL} — will retry on next boot"
        fi
        rm -f "$TALOS_CFG"
    fi
elif [ "$STATUS" = "pending_approval" ]; then
    log "Attestation pending operator approval — machine_id=${MACHINE_ID}"
    echo "pending:${MACHINE_ID}" > "${STATE_DIR}/pending_approval"

    # Poll the Registration Service every 60 s until the operator approves.
    # Max 60 attempts (60 min) — after that the next Talos boot will retry.
    # This avoids requiring a manual reboot after operator approval.
    POLL_MAX=60
    POLL_N=0
    log "Polling for operator approval (max ${POLL_MAX} attempts × 60 s)..."
    while [ "$POLL_N" -lt "$POLL_MAX" ]; do
        sleep 60
        POLL_N=$((POLL_N + 1))
        log "Poll attempt ${POLL_N}/${POLL_MAX} — checking Registration Service"

        POLL_RESP=$(/usr/local/bin/curl \
            --silent \
            --fail \
            --max-time 30 \
            --retry 2 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "${REG_URL}/api/v1/attest" 2>/dev/null) || { log "WARN: Poll call failed — will retry"; continue; }

        POLL_STATUS=$(/usr/local/bin/jq -r '.status' <<< "$POLL_RESP" 2>/dev/null || echo "unknown")
        POLL_ACTION=$(/usr/local/bin/jq -r '.action // "none"' <<< "$POLL_RESP" 2>/dev/null || echo "none")
        POLL_CFG_URL=$(/usr/local/bin/jq -r '.config_url // empty' <<< "$POLL_RESP" 2>/dev/null || echo "")
        log "Poll response: status=${POLL_STATUS} action=${POLL_ACTION}"

        if [ "$POLL_STATUS" = "attested" ]; then
            MACHINE_ID=$(/usr/local/bin/jq -r '.machine_id' <<< "$POLL_RESP" 2>/dev/null || echo "")
            log "Approved! machine_id=${MACHINE_ID}"
            echo "${MACHINE_ID}" > "$ATTESTED_FLAG"
            echo "$POLL_RESP"   > "${STATE_DIR}/attestation_receipt.json"
            rm -f "${STATE_DIR}/pending_approval"

            if [ "$POLL_ACTION" = "apply-config" ] && [ -n "$POLL_CFG_URL" ]; then
                log "Applying machine config from Registration Service"
                TALOS_CFG=$(mktemp)
                if /usr/local/bin/curl --silent --fail --max-time 30 --retry 3 \
                        -o "$TALOS_CFG" "$POLL_CFG_URL"; then
                    if talosctl apply-config --insecure --nodes 127.0.0.1 \
                            --file "$TALOS_CFG" 2>/dev/null; then
                        log "MachineConfig applied — Talos will reboot into the cluster"
                        rm -f "$TALOS_CFG"
                        exit 0
                    else
                        log "ERROR: talosctl apply-config failed"
                        cp "$TALOS_CFG" "${STATE_DIR}/pending.config"
                    fi
                else
                    log "ERROR: Failed to download config from ${POLL_CFG_URL}"
                fi
                rm -f "$TALOS_CFG"
            fi
            exit 0
        fi

        if [ "$POLL_STATUS" = "locked" ] || [ "$POLL_STATUS" = "revoked" ]; then
            log "WARN: Machine ${MACHINE_ID} status changed to ${POLL_STATUS} during poll — stopping"
            break
        fi
    done
    log "Poll loop ended — will retry attestation on next boot"
    exit 0
else
    log "WARN: Unexpected attestation response: status=${STATUS}"
    log "Full response: $RESPONSE"
    exit 0  # Non-fatal
fi
