# Dockerfile for ITL Security Extension
# Talos system extensions use OCI images with /manifest.yaml + /rootfs overlay

FROM alpine:3.19 AS rootfs-builder

RUN mkdir -p \
    /rootfs/etc/sysctl.d \
    /rootfs/etc/audit/rules.d \
    /rootfs/etc/modprobe.d

COPY rootfs/etc/sysctl.d/99-itl-hardening.conf  /rootfs/etc/sysctl.d/99-itl-hardening.conf
COPY rootfs/etc/audit/rules.d/99-itl.rules       /rootfs/etc/audit/rules.d/99-itl.rules
COPY rootfs/etc/modprobe.d/itl-security.conf     /rootfs/etc/modprobe.d/itl-security.conf

FROM scratch

COPY --from=rootfs-builder /rootfs /rootfs
COPY manifest.yaml /manifest.yaml

LABEL org.opencontainers.image.title="ITL.Talos.HardenedOS Security Extension"
LABEL org.opencontainers.image.description="Talos extension: sysctl hardening, audit rules, kernel module policy"
LABEL org.opencontainers.image.vendor="ITlusions"
LABEL org.opencontainers.image.licenses="MIT"
