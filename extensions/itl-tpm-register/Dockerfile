# ────────────────────────────────────────────────────────────────────────────
# ITL Talos Extension: itl-tpm-register
#
# Builds tpm2-tools from the Alpine apk cache and copies only the binaries
# and libraries needed for:
#   - tpm2_getekcertificate   → read the TPM Endorsement Key certificate
#   - tpm2_readpublic         → export EK public key
#   - tpm2_quote              → generate a PCR quote for remote attestation
#   - tpm2_flushcontext       → housekeeping
#
# The rootfs overlay also adds:
#   /usr/local/itl/tpm-register.sh    → post-install attestation script
#   /usr/local/itl/tpm-attest.sh      → runtime attestation script (called
#                                        by Talos extension service on boot)
#
# Talos extension services are declared via the manifest.yaml and executed
# by machined on each boot.  The scripts are idempotent: after the machine
# is marked "attested" in the Registration Service the script exits 0
# immediately without further API calls.
# ────────────────────────────────────────────────────────────────────────────

# Stage 1 — compile / collect tpm2-tools + libraries on Alpine
FROM alpine:3.21 AS tpm-builder

RUN apk add --no-cache \
    tpm2-tools \
    tpm2-tss \
    openssl \
    curl \
    jq \
    ca-certificates

# Collect binaries
RUN mkdir -p /rootfs/usr/local/bin && \
    for bin in \
        tpm2_getekcertificate \
        tpm2_readpublic \
        tpm2_createek \
        tpm2_quote \
        tpm2_flushcontext \
        tpm2_getcap; \
    do \
        cp -v "$(which $bin)" /rootfs/usr/local/bin/; \
    done && \
    cp $(which curl) /rootfs/usr/local/bin/ && \
    cp $(which jq)   /rootfs/usr/local/bin/

# Collect shared libraries needed by the binaries
RUN mkdir -p /rootfs/usr/local/lib && \
    ldd /usr/bin/tpm2_getekcertificate 2>/dev/null \
        | grep "=> /" \
        | awk '{print $3}' \
        | xargs -I{} cp -v {} /rootfs/usr/local/lib/ ; \
    # tss runtime libs
    for lib in \
        libtss2-esys.so.0 \
        libtss2-sys.so.1 \
        libtss2-mu.so.0 \
        libtss2-tcti-device.so.0 \
        libtss2-tcti-mssim.so.0 \
        libtss2-rc.so.0 \
        libtss2-tctildr.so.0; \
    do \
        find /usr/lib /lib -name "${lib}" -exec cp -v {} /rootfs/usr/local/lib/ \; 2>/dev/null || true; \
    done

# Copy CA certs (needed for HTTPS calls to Registration Service)
RUN mkdir -p /rootfs/etc/ssl/certs && \
    cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/

# ── Registration / Attestation Scripts ───────────────────────────────────────
RUN mkdir -p /rootfs/usr/local/itl

COPY rootfs/usr/local/itl/tpm-register.sh   /rootfs/usr/local/itl/tpm-register.sh
COPY rootfs/usr/local/itl/tpm-attest.sh     /rootfs/usr/local/itl/tpm-attest.sh
COPY rootfs/usr/local/itl/tpm-common.sh     /rootfs/usr/local/itl/tpm-common.sh

RUN chmod +x \
    /rootfs/usr/local/itl/tpm-register.sh \
    /rootfs/usr/local/itl/tpm-attest.sh \
    /rootfs/usr/local/itl/tpm-common.sh

# ── State directory (survives across reboots on Talos STATE partition) ────────
RUN mkdir -p /rootfs/var/lib/itl-tpm

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — final Talos extension image (rootfs overlay + manifest)
# ─────────────────────────────────────────────────────────────────────────────
FROM scratch

COPY --from=tpm-builder /rootfs /rootfs
COPY manifest.yaml       /manifest.yaml

LABEL org.opencontainers.image.title="ITL Talos TPM Registration Extension"
LABEL org.opencontainers.image.description="tpm2-tools + ITL registration/attestation scripts for Talos Linux"
LABEL org.opencontainers.image.vendor="ITlusions"
LABEL org.opencontainers.image.licenses="MIT"
