# Dockerfile for ITL Security Extension
# This extension adds security hardening to Talos Linux

FROM ghcr.io/siderolabs/bldr:latest as builder

WORKDIR /src
COPY . .

RUN bldr build --root /src

FROM scratch

COPY --from=builder /src/_out /

# Metadata
LABEL org.opencontainers.image.title="ITL.Talos.HardenedOS Security Extension"
LABEL org.opencontainers.image.description="Talos extension with security hardening, audit logging, and compliance controls"
LABEL org.opencontainers.image.vendor="ITlusions"
