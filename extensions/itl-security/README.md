# ITL Security Extension
# Talos system extension for security hardening and compliance

This extension adds security hardening to Talos Linux systems including:
- Kernel hardening modules
- Network security policies
- Audit logging configuration
- TPM 2.0 support
- LUKS2 encryption

## Building

```bash
# Build with bldr
docker run --rm -v $(pwd):/src ghcr.io/siderolabs/bldr:latest \
  build --root /src/extensions/itl-security
```

## Features

- Kernel security parameters (kptr_restrict, dmesg_restrict)
- Network hardening (rp_filter, SYN cookies, ICMP filtering)
- TPM 2.0 module support
- Audit framework configuration
- File system security (protected hardlinks/symlinks)
- SELinux/AppArmor support

## Installation

Include in Talos configuration:

```yaml
machine:
  install:
    extensions:
      - image: ghcr.io/itlusions/itl-talos-hardened-os-security:latest
```

## Compliance

Supports:
- FIPS compliance
- CIS Kubernetes Benchmark
- NIST guidelines
- PCI DSS requirements

## Customization

Modify security parameters in configuration patches:
- `config/patches/security-hardening.yaml`
