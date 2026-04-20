# Dockerfile for ITL Branding Extension
# Talos system extensions use OCI images with /manifest.yaml + /rootfs overlay

FROM alpine:3.19 AS rootfs-builder

RUN mkdir -p /rootfs/etc

COPY rootfs/etc/issue         /rootfs/etc/issue
COPY rootfs/etc/issue.net     /rootfs/etc/issue.net
COPY rootfs/etc/motd          /rootfs/etc/motd
COPY rootfs/etc/itl-release   /rootfs/etc/itl-release

FROM scratch

COPY --from=rootfs-builder /rootfs /rootfs
COPY manifest.yaml /manifest.yaml

LABEL org.opencontainers.image.title="ITL.Talos.HardenedOS Branding Extension"
LABEL org.opencontainers.image.description="Talos extension: ITLusions console banners, MOTD, and branding files"
LABEL org.opencontainers.image.vendor="ITlusions"
LABEL org.opencontainers.image.licenses="MIT"
