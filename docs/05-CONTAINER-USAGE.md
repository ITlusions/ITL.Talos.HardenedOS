# Container Usage Guide

Docker images produced by the build pipeline and the Registration Service stack.

## Container Images

### Extension Images (CI pipeline â€” `ghcr.io/itlusions/`)

The flavor pipeline (`build-controlplane-stack-flavor.yaml`) builds and pushes three
extension OCI images. These are baked into the ISO by `ghcr.io/siderolabs/imager`
at build time â€” no GHCR access is needed on nodes during installation.

| Image | Built from | Included in ISO |
|---|---|---|
| `itl-talos-hardened-os-branding:vX.Y.Z` | `extensions/itl-branding/Dockerfile` | All 3 role ISOs |
| `itl-talos-hardened-os-security:vX.Y.Z` | `extensions/itl-security/Dockerfile` | All 3 role ISOs |
| `itl-talos-tpm-register:vX.Y.Z` | `extensions/itl-tpm-register/Dockerfile` | All 3 role ISOs |

Additionally, two upstream Siderolabs extensions are baked in:
- `ghcr.io/siderolabs/gvisor` â€” gVisor sandbox runtime (controlplane ISO only)
- `ghcr.io/siderolabs/intel-ucode` â€” Intel microcode updates (controlplane ISO only)

There is no separate installer image. Extensions are embedded in the ISO at build time.

### Registration Service Stack

The provisioner (`provisioner/docker-compose.yml`) runs two containers:

| Container | Image | Purpose |
|---|---|---|
| `itl-machine-registration` | Built from `services/machine-registration/Dockerfile` | FastAPI Registration + config delivery on port 8080 |
| `itl-reg-caddy` | `caddy:2-alpine` | Automatic TLS reverse proxy on ports 80 and 443 |

See [09-REGISTRATION-SERVICE.md](09-REGISTRATION-SERVICE.md) for full deployment instructions.

## Local Development with Docker

### Validate MachineConfig

### Validate MachineConfig locally

Use the upstream `talosctl` binary directly â€” no custom container needed.

```bash
# Install talosctl (Linux/macOS)
curl -Lo /usr/local/bin/talosctl \
  https://github.com/siderolabs/talos/releases/download/v1.9.0/talosctl-linux-amd64
chmod +x /usr/local/bin/talosctl

# Validate a generated config
talosctl validate --config config/output/controlplane-final.yaml --mode metal
talosctl validate --config config/output/worker-infra-final.yaml --mode metal
talosctl validate --config config/output/worker-app-final.yaml --mode metal
```

### Run the Registration Service locally

```bash
cd provisioner
cp .env.example .env
# Edit .env â€” set ITL_ADMIN_TOKEN at minimum

docker compose up -d

# Download role configs for local testing
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh v1.0.0"

# Test
curl http://localhost:80/healthz
```

For HTTPS locally, change `Caddyfile` to use `tls internal` and add `127.0.0.1 reg.itlusions.local` to your hosts file.

### Build and test an extension locally

```bash
# Build the TPM register extension
cd extensions/itl-tpm-register
docker build -t itl-tpm-register:dev .

# Inspect the rootfs overlay
docker run --rm itl-tpm-register:dev find /rootfs -type f
```

## Build an ISO Locally

Use `build-simple.sh` (Linux/macOS) to produce a single ISO with branding and security extensions baked in. Requires Docker.

```bash
# Default: uses TALOS_VERSION=v1.9.0, pulls extensions tagged 'latest'
./build-simple.sh

# Override versions
TALOS_VERSION=v1.9.0 \
ITL_BRANDING_TAG=v1.0.0 \
ITL_SECURITY_TAG=v1.0.0 \
./build-simple.sh

# Add extra extensions on top of the core set
EXTRA_EXTENSIONS="ghcr.io/siderolabs/amd-ucode:20240312-v1.9.0" \
./build-simple.sh
```

Output: `itl-talos-v1.9.0.iso` + `.sha256` + `.md5` in the repo root.

> For the full ZTP build (3 role ISOs with `talos.config=` embedded), use the
> `build-controlplane-stack-flavor.yaml` CI pipeline triggered by a `v*-cpstack` tag.

## Build and Inspect Extension Images Locally

```bash
# Build the branding extension
cd extensions/itl-branding
docker build -t itl-branding:dev .

# Inspect the rootfs overlay (files that will be injected into the OS)
docker run --rm itl-branding:dev find /rootfs -type f

# Build the TPM registration extension
cd extensions/itl-tpm-register
docker build -t itl-tpm-register:dev .
docker run --rm itl-tpm-register:dev find /rootfs -type f
```

## Container Registry Management

### Authenticate to GHCR

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u <github-username> --password-stdin
```

### Pull a specific extension image

```bash
docker pull ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
docker pull ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
docker pull ghcr.io/itlusions/itl-talos-tpm-register:v1.0.0
```

### Scan extension images for vulnerabilities

```bash
# Using Trivy
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image \
  ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
```

## Troubleshooting

### Registration Service won't start

```bash
# Check logs
docker compose -f provisioner/docker-compose.yml logs registration

# Check health
curl http://localhost:80/healthz
```

### Extension image pull fails

```bash
# Confirm you are logged in to GHCR
docker pull ghcr.io/itlusions/itl-talos-hardened-os-branding:latest

# If the image is private, ensure the repo has GHCR visibility set to internal/public
# or provide a pull secret
```

### ISO build fails â€” /dev/mapper/control not found

```bash
# Load device mapper before running build-simple.sh
sudo modprobe dm-mod
ls /dev/mapper/control  # should exist

./build-simple.sh
```
