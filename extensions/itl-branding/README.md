# ITL Branding Extension
# Talos system extension for ITL branding and logos

This extension adds custom branding to Talos Linux systems including:
- Console banners
- Boot logos
- Custom messages

## Building

```bash
# Build with bldr
docker run --rm -v $(pwd):/src ghcr.io/siderolabs/bldr:latest \
  build --root /src/extensions/itl-branding
```

## Contents

- ASCII art banners for SSH/console
- Boot logos for kernel display
- Branding configuration files

## Installation

Include in Talos configuration:

```yaml
machine:
  install:
    extensions:
      - image: ghcr.io/itlusions/itl-talos-hardened-os-branding:latest
```

## Customization

Edit banner text in `Dockerfile` or base configuration.
