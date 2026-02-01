# Dockerfile for ITL Branding Extension
# This extension adds ITLusions branding to Talos Linux

FROM ghcr.io/siderolabs/bldr:latest as builder

WORKDIR /src
COPY . .

RUN bldr build --root /src

FROM scratch

COPY --from=builder /src/_out /

# Metadata
LABEL org.opencontainers.image.title="ITL.Talos.HardenedOS Branding Extension"
LABEL org.opencontainers.image.description="Talos extension with ITLusions branding, console banners, and logos"
LABEL org.opencontainers.image.vendor="ITlusions"
