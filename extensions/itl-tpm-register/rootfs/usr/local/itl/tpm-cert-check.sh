#!/bin/sh
# tpm-cert-check.sh — validate the offline enrollment certificate
#
# Verifies that the enrollment cert on disk was genuinely issued by the ITL
# Machine Enrollment CA before the node sends it to the Registration Service.
# This is a client-side pre-flight that catches:
#
#   - Certs not signed by the Enrollment CA (tampered / wrong bundle)
#   - Expired certs (30-day window has lapsed)
#   - Key/cert mismatch (private key does not match the public key in the cert)
#   - Missing EK fingerprint in the cert Subject CN
#
# Usage: called by tpm-attest.sh before the enrollment POST.
#   tpm-cert-check.sh <cert_path> <key_path> <ca_cert_path> <ek_fingerprint>
#
# Exit codes:
#   0  — cert is valid, chain is trusted, key matches, not expired
#   1  — validation failed (reason logged); caller should skip enrollment
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(dirname "$0")"
. "${SCRIPT_DIR}/tpm-common.sh"

ENROLL_CERT="${1:-}"
ENROLL_KEY="${2:-}"
ENROLL_CA="${3:-}"
EK_FP="${4:-}"

# ── Argument checks ───────────────────────────────────────────────────────────
if [ -z "$ENROLL_CERT" ] || [ -z "$ENROLL_KEY" ] || [ -z "$ENROLL_CA" ]; then
    log "CERT-CHECK: usage: $0 <cert> <key> <ca_cert> [ek_fingerprint]"
    exit 1
fi

if [ ! -f "$ENROLL_CERT" ]; then
    log "CERT-CHECK: enrollment cert not found: $ENROLL_CERT"
    exit 1
fi

if [ ! -f "$ENROLL_KEY" ]; then
    log "CERT-CHECK: enrollment key not found: $ENROLL_KEY"
    exit 1
fi

if [ ! -f "$ENROLL_CA" ]; then
    log "CERT-CHECK: CA cert not found: $ENROLL_CA"
    exit 1
fi

# ── 1. Verify cert chain against Enrollment CA ───────────────────────────────
log "CERT-CHECK: verifying cert chain against Enrollment CA"
if ! openssl verify -CAfile "$ENROLL_CA" "$ENROLL_CERT" >/dev/null 2>&1; then
    log "CERT-CHECK: FAILED — cert is not signed by the Enrollment CA at $ENROLL_CA"
    log "CERT-CHECK: issuer in cert: $(openssl x509 -in "$ENROLL_CERT" -noout -issuer 2>/dev/null)"
    log "CERT-CHECK: expected CA subject: $(openssl x509 -in "$ENROLL_CA" -noout -subject 2>/dev/null)"
    exit 1
fi
log "CERT-CHECK: chain OK"

# ── 2. Check cert has not expired ────────────────────────────────────────────
log "CERT-CHECK: checking cert validity window"
if ! openssl x509 -in "$ENROLL_CERT" -noout -checkend 0 >/dev/null 2>&1; then
    EXPIRY=$(openssl x509 -in "$ENROLL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
    log "CERT-CHECK: FAILED — cert has expired (notAfter: $EXPIRY)"
    exit 1
fi
log "CERT-CHECK: validity window OK"

# ── 3. Verify key matches cert (public key fingerprint comparison) ────────────
log "CERT-CHECK: verifying private key matches cert public key"
CERT_PUBKEY_FP=$(openssl x509 -in "$ENROLL_CERT" -noout -pubkey 2>/dev/null \
    | openssl pkey -pubin -noout -text 2>/dev/null \
    | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')

KEY_PUBKEY_FP=$(openssl pkey -in "$ENROLL_KEY" -pubout 2>/dev/null \
    | openssl pkey -pubin -noout -text 2>/dev/null \
    | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')

if [ -z "$CERT_PUBKEY_FP" ] || [ -z "$KEY_PUBKEY_FP" ]; then
    log "CERT-CHECK: FAILED — could not extract public key fingerprints for comparison"
    exit 1
fi

if [ "$CERT_PUBKEY_FP" != "$KEY_PUBKEY_FP" ]; then
    log "CERT-CHECK: FAILED — private key does not match the cert public key"
    log "CERT-CHECK: cert pubkey fp : $CERT_PUBKEY_FP"
    log "CERT-CHECK: key  pubkey fp : $KEY_PUBKEY_FP"
    exit 1
fi
log "CERT-CHECK: key/cert match OK"

# ── 4. Verify cert Extended Key Usage contains clientAuth ─────────────────────
log "CERT-CHECK: checking Extended Key Usage"
EKU=$(openssl x509 -in "$ENROLL_CERT" -noout -ext extendedKeyUsage 2>/dev/null || true)
if ! echo "$EKU" | grep -qi "TLS Web Client Authentication"; then
    log "CERT-CHECK: WARN — cert does not have clientAuth EKU (may be rejected by Registration Service)"
    # Non-fatal: warn only, the server will reject it if required
fi

# ── 5. Verify EK fingerprint is bound to this cert ───────────────────────────
# Newer certs carry the EK fingerprint as a URI SAN: urn:itl:ek:<fingerprint>
# Older/admin-generated certs may carry it in the Subject CN.
# We check the SAN first; if absent we fall back to CN for backwards compat.
if [ -n "$EK_FP" ]; then
    log "CERT-CHECK: verifying EK fingerprint is bound to this cert"

    # Check URI SAN for urn:itl:ek:<fingerprint>
    CERT_SAN=$(openssl x509 -in "$ENROLL_CERT" -noout -ext subjectAltName 2>/dev/null || true)
    EK_URI="urn:itl:ek:${EK_FP}"

    if echo "$CERT_SAN" | grep -qF "$EK_URI"; then
        log "CERT-CHECK: EK fingerprint in URI SAN OK"
    else
        # SAN not present or doesn't match — check CN (backwards compat)
        CERT_CN=$(openssl x509 -in "$ENROLL_CERT" -noout -subject 2>/dev/null \
            | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | tr -d ' ')

        if echo "$CERT_CN" | grep -qF "$EK_FP"; then
            log "CERT-CHECK: EK fingerprint in Subject CN OK (legacy cert)"
        else
            log "CERT-CHECK: FAILED — EK fingerprint not found in cert SAN or CN"
            log "CERT-CHECK: expected SAN URI : $EK_URI"
            log "CERT-CHECK: cert SAN         : ${CERT_SAN:-<none>}"
            log "CERT-CHECK: cert CN          : ${CERT_CN:-<unknown>}"
            log "CERT-CHECK: EK fp            : $EK_FP"
            exit 1
        fi
    fi
fi

# ── All checks passed ─────────────────────────────────────────────────────────
SUBJECT=$(openssl x509 -in "$ENROLL_CERT" -noout -subject 2>/dev/null)
EXPIRY=$(openssl x509 -in "$ENROLL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
log "CERT-CHECK: all checks passed"
log "CERT-CHECK: subject : $SUBJECT"
log "CERT-CHECK: expires : $EXPIRY"
exit 0
