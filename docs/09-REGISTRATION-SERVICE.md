# Registration Service

The ITL Machine Registration Service is the central control point for Zero-Touch Provisioning. It manages machine identity (via TPM EK fingerprint), distributes role-specific Talos ISOs, delivers one-time MachineConfig tokens, and tracks every node through its lifecycle from first registration to attested.

Stack: FastAPI · SQLModel · SQLite · Caddy TLS proxy · Docker Compose.

---

## Architecture

```
Internet / LAN
       │
   :443 (HTTPS)
       │
┌──────▼──────────────────────────────────┐
│  Caddy  (caddy:2-alpine)                │
│  TLS termination + rate-limit on /enroll│
└──────┬──────────────────────────────────┘
       │ http://registration:8080
┌──────▼──────────────────────────────────┐
│  Registration Service  (:8080)          │
│  FastAPI + SQLModel                     │
│                                         │
│  /var/lib/itl-reg/                      │
│  ├── db/machines.db    (SQLite)         │
│  ├── configs/          (role YAMLs)     │
│  └── ca/               (Enrollment CA)  │
└─────────────────────────────────────────┘
```

---

## Deploy

### Prerequisites

- Docker + Docker Compose on a server with a public DNS record pointing to it
- Ports 80 and 443 reachable from nodes being provisioned
- A strong random admin token

### 1. Configure

```bash
cd provisioner
cp .env.example .env
```

Edit `.env`:

```env
# Public URL nodes will use to reach this service
ITL_SERVICE_URL=https://reg.itlusions.com

# Base URL for ISO downloads (GitHub Releases of ITL.Talos.HardenedOS)
ITL_ISO_BASE_URL=https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download

# Admin token — protect this
# Generate: openssl rand -hex 32
ITL_ADMIN_TOKEN=<64-char-hex>

# GitHub Release tag to download role configs from
TALOS_RELEASE_TAG=v1.0.0
```

Edit `Caddyfile` — replace the domain on line 1:

```
reg.your-domain.com {
    ...
}
```

### 2. Start the stack

```bash
docker compose up -d
```

Caddy automatically provisions a Let's Encrypt TLS certificate on first start.

### 3. Download role configs

The Registration Service delivers role-specific MachineConfig YAMLs. These must be downloaded from the GitHub Release before any nodes can provision.

```bash
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh ${TALOS_RELEASE_TAG}"
```

This populates `/var/lib/itl-reg/configs/` inside the container with:
- `controlplane-final.yaml`
- `worker-infra-final.yaml`
- `worker-app-final.yaml`

### 4. Verify

```bash
# Health check
curl https://reg.your-domain.com/healthz

# List machines (empty on first run)
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}"
```

---

## Environment Variables

| Variable | Default | Required | Description |
|---|---|---|---|
| `ITL_ADMIN_TOKEN` | — | Yes | Bearer token for all admin endpoints |
| `ITL_SERVICE_URL` | `https://reg.itlusions.com` | Yes | Public base URL returned to nodes in `config_url` |
| `ITL_ISO_BASE_URL` | GitHub Releases latest | No | Base URL for ISO download links returned at registration |
| `ITL_DB_URL` | `sqlite:////var/lib/itl-reg/db/machines.db` | No | SQLAlchemy DB URL |
| `ITL_CONFIG_CACHE_DIR` | `/var/lib/itl-reg/configs` | No | Directory containing downloaded role YAMLs |
| `ITL_ENROLLMENT_CA_DIR` | `/var/lib/itl-reg/ca` | No | Enrollment CA key and cert storage |
| `ITL_ENROLLMENT_CERT_DAYS` | `30` | No | Validity period for offline enrollment certs |

---

## API Reference

All endpoints are under `/api/v1/`. The OpenAPI docs are available at `/docs`.

### Public endpoints (no auth)

#### `POST /api/v1/register`

Called by the USB provisioning agent during initial node setup.

**Request:**
```json
{
  "ek_fingerprint": "<64-char SHA-256 hex>",
  "ek_cert_pem":    "<base64-encoded EK material>",
  "ek_source":      "cert",
  "hw_uuid":        "<DMI UUID>",
  "hw_mac":         "<first NIC MAC>",
  "hw_serial":      "<chassis serial>",
  "hw_product":     "<DMI product name>",
  "desired_role":   "worker-app"
}
```

`ek_source` is `"cert"` when an OEM EK X.509 certificate was found at TPM NV index `0x01c00002`, or `"pub"` when only the EK public key was available.

**Response:**
```json
{
  "machine_id":   "<UUID v4>",
  "role":         "worker-app",
  "status":       "pending_approval",
  "iso_url":      "https://github.com/.../itl-talos-worker-app-amd64.iso",
  "config_token": "<one-time token>",
  "config_url":   "https://reg.your-domain.com/api/v1/config/<token>",
  "message":      "Machine registered. Download ISO and boot."
}
```

The ISO URL maps role to filename:

| Role | ISO filename |
|---|---|
| `controlplane` | `itl-talos-controlplane-amd64.iso` |
| `worker-infra` | `itl-talos-worker-infra-amd64.iso` |
| `worker-app` | `itl-talos-worker-app-amd64.iso` |

#### `POST /api/v1/attest`

Called by the `itl-tpm-register` Talos extension on first boot. Verifies the TPM EK fingerprint and advances the machine to `attested`.

**Request:**
```json
{
  "ek_fingerprint": "<64-char SHA-256 hex>",
  "ek_cert_pem":    "<base64>",
  "ek_source":      "cert",
  "pcr_quote":      "<base64 TPM2B_ATTEST>",
  "pcr_signature":  "<base64 TPMT_SIGNATURE>",
  "pcr_nonce":      "<hex nonce>",
  "hw_uuid":        "<DMI UUID>",
  "hw_mac":         "<MAC>",
  "hw_serial":      "<serial>",
  "hw_product":     "<product>"
}
```

PCR fields are optional. If present, they are recorded against the machine record. Full cryptographic PCR quote verification is a planned enhancement (see `07-ROADMAP.md`).

**Response:**
```json
{
  "machine_id": "<UUID>",
  "status":     "attested",
  "hostname":   "cp1.itlusions.internal",
  "role":       "controlplane",
  "message":    "Machine attested."
}
```

If the machine is not yet in the database the status will be `pending_approval`.

#### `GET /api/v1/config/{token}`

Delivers the machine-specific MachineConfig YAML to Talos during `talos.config=` fetch. The token is **one-time** — it is invalidated after the first successful fetch.

**Response:** `application/yaml` — full Talos MachineConfig with hostname, node labels, and IP pre-applied.

#### `POST /api/v1/machines/enroll`

Called by the `itl-tpm-register` extension on offline/air-gapped nodes. Authenticated by an Enrollment CA certificate (see `11-AIRGAPPED-DEPLOYMENT.md`).

**Request:**
```json
{
  "cert_pem":        "<PEM enrollment cert>",
  "nonce":           "<hex>",
  "nonce_signature": "<base64 RSA-SHA256 signature of nonce>"
}
```

The service verifies the cert chain against the Enrollment CA and verifies the nonce signature. This proves private key possession, not just cert possession. On success the machine transitions to `attested`.

---

### Admin endpoints (require `Authorization: Bearer <ITL_ADMIN_TOKEN>`)

#### `GET /api/v1/machines`

List all machines.

```bash
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | jq .
```

**Response:** array of `MachineDetail` objects with all fields.

#### `POST /api/v1/machines/{id}/approve`

Approve a `pending_approval` machine and assign its role and hostname.

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/<machine_id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "role":        "controlplane",
    "hostname":    "cp1.itlusions.internal",
    "assigned_ip": "10.0.0.10/24"
  }'
```

`assigned_ip` is optional. If provided it is written into the generated MachineConfig as a static address on `eth0`.

#### `GET /api/v1/machines/{id}/offline-bundle`

Generate an offline provisioning bundle for air-gapped nodes. Returns a JSON payload containing:
- `iso_url` — role ISO download link
- `config_token` — one-time MachineConfig token
- `enrollment_cert` — PEM enrollment certificate (valid `ITL_ENROLLMENT_CERT_DAYS` days)
- `enrollment_key` — PEM RSA-2048 private key

> The private key is only returned once. Store it securely or embed it immediately into the USB bundle.

```bash
curl -s https://reg.your-domain.com/api/v1/machines/<machine_id>/offline-bundle \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | jq .
```

#### `POST /api/v1/machines/import`

Pre-register a machine from a hardware receipt (EFI partition `itl/registration.json`), or manually from a known EK fingerprint.

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/import \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ek_fingerprint": "<64-char hex>",
    "role":           "worker-infra",
    "hostname":       "w1.itlusions.internal"
  }'
```

---

## Machine Lifecycle

```
              ┌─────────────────┐
              │  (unknown)      │
              └────────┬────────┘
                       │ POST /register or /attest (unknown EK)
                       ▼
              ┌─────────────────┐
              │ pending_approval│◄── Machines with unknown EK
              └────────┬────────┘    land here for operator review
                       │ POST /machines/{id}/approve
                       ▼
              ┌─────────────────┐
              │   registered    │◄── ISO downloaded, Talos installing
              └────────┬────────┘
                       │ POST /attest  or  POST /machines/enroll
                       ▼
              ┌─────────────────┐
              │    attested     │◄── Node running, PCR quote recorded
              └─────────────────┘

              At any state:
              POST /machines/{id}/approve with role=rejected
                       ▼
              ┌─────────────────┐
              │    rejected     │
              └─────────────────┘
```

---

## Volumes and Persistence

| Volume | Mount | Contents | Backup critical |
|---|---|---|---|
| `reg-data` | `/var/lib/itl-reg` | SQLite DB, role YAMLs, Enrollment CA | **Yes** |
| `caddy-data` | `/data` | Let's Encrypt certificates | No (auto-renewed) |
| `caddy-config` | `/config` | Caddy runtime config | No |

> Back up `/var/lib/itl-reg` regularly. The Enrollment CA private key at `/var/lib/itl-reg/ca/enrollment-ca.key` is irreplaceable — losing it means offline-bundle-provisioned nodes cannot self-enroll.

---

## Updating Role Configs

When a new Talos release is published, download updated configs:

```bash
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh v1.1.0"
```

Update `TALOS_RELEASE_TAG` in `.env` as well so new registrations use the correct ISO URL.

---

## TLS and Caddy

The `Caddyfile` configures:

- **Public endpoints** (`/api/v1/register`, `/api/v1/attest`, `/api/v1/config/*`, `/healthz`, `/docs`) — proxied directly, no additional auth
- **Enroll endpoint** (`/api/v1/machines/enroll`) — rate-limited to 10 requests per minute per IP
- **Admin endpoints** (`/api/v1/machines*`) — proxied to the service; the service itself checks the bearer token

For private/internal deployments replace Let's Encrypt with a self-signed cert:

```
reg.your-domain.com {
    tls internal
    reverse_proxy registration:8080
}
```
