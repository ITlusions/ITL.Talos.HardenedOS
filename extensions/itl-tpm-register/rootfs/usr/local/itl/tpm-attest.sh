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

if [ -f "$ENROLL_CERT" ] && [ -f "$ENROLL_KEY" ]; then
    log "Enrollment cert found — attempting certificate-based enrollment"

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
                # Remove the private key — it is no longer needed and should not
                # persist on disk after successful enrollment
                rm -f "$ENROLL_KEY"
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
MACHINE_ID=$(/usr/local/bin/jq -r '.machine_id' <<< "$RESPONSE" 2>/dev/null || echo "")
HOSTNAME=$(/usr/local/bin/jq -r '.hostname // empty' <<< "$RESPONSE" 2>/dev/null || echo "")

if [ "$STATUS" = "attested" ] || [ "$STATUS" = "already_attested" ]; then
    log "Attestation successful — machine_id=${MACHINE_ID} hostname=${HOSTNAME}"
    echo "${MACHINE_ID}" > "$ATTESTED_FLAG"
    echo "$RESPONSE"     > "${STATE_DIR}/attestation_receipt.json"
    log "Attestation receipt saved to ${STATE_DIR}/attestation_receipt.json"
elif [ "$STATUS" = "pending_approval" ]; then
    log "Attestation pending operator approval — machine_id=${MACHINE_ID}"
    echo "pending:${MACHINE_ID}" > "${STATE_DIR}/pending_approval"
    # Exit 0 — don't block boot; operator approves via Registration Service UI
    exit 0
else
    log "WARN: Unexpected attestation response: status=${STATUS}"
    log "Full response: $RESPONSE"
    exit 0  # Non-fatal
fi
