# Air-Gapped Deployment

For nodes that have no internet access during provisioning — isolated networks, dark-site facilities, or high-security environments. The entire provisioning flow runs from a pre-built USB drive with no outbound network calls required.

---

## How It Works

The air-gapped flow uses an Enrollment Certificate Authority (CA) embedded in the Registration Service. When an admin generates an offline bundle, the Registration Service issues a short-lived client certificate for the machine. That certificate — along with the role ISO and MachineConfig — is embedded into a USB drive before the drive ever touches the air-gapped network.

On first boot inside Talos, the `itl-tpm-register` extension finds the certificate and key, uses them to prove identity to the Registration Service via a challenge-response (sign a nonce with the private key), and self-enrolls. The private key is deleted from disk immediately after successful enrollment.

```
Admin (internet-connected)                Air-gapped network
─────────────────────────────             ─────────────────────
Registration Service                      Target Server
  └── GET /machines/{id}/offline-bundle
        │
        ├── ISO download link
        ├── One-time config token
        ├── enrollment_cert (30-day PEM)
        └── enrollment_key (RSA-2048 PEM)
              │
              ▼
    build-usb-offline.sh /dev/sdX
    (embeds everything onto USB)
              │
              ▼ USB transferred physically
                                          USB boot (Alpine)
                                            └── reads pre-baked ISO
                                            └── dd to disk → reboot
                                          Talos first boot
                                            └── tpm-attest.sh:
                                                  Path A (cert enrollment)
                                                  sign nonce → /enroll
                                                  key deleted on success
```

---

## Prerequisites

- Registration Service deployed and reachable from your admin machine
- Machine already registered (`POST /api/v1/register` or `/import`) and approved
- USB drive of at least 1 GB
- `build-usb-offline.sh` available in `provisioner/usb-agent/`

---

## Enrollment CA

The Registration Service generates a self-signed RSA 4096 CA on first startup and persists it at `ITL_ENROLLMENT_CA_DIR` (default `/var/lib/itl-reg/ca/`).

| File | Purpose |
|---|---|
| `enrollment-ca.key` | CA private key — **keep this secret, back up offline** |
| `enrollment-ca.crt` | CA certificate — embedded in issued client certs |

The CA is valid for **10 years**. It is auto-generated — no manual setup required.

Issued machine enrollment certificates are:
- RSA 2048
- Valid for `ITL_ENROLLMENT_CERT_DAYS` days (default: 30)
- Subject: `CN=<machine_id>, OU=<role>, O=ITL Usions, C=NL`
- EKU: `clientAuth`
- `keyEncipherment` key usage (signals the key can wrap/encrypt material)
- `SubjectKeyIdentifier` and `AuthorityKeyIdentifier` extensions (for OCSP/CRL readiness)
- URI SAN: `urn:itl:ek:<ek_fingerprint>` — binds the cert to the specific TPM EK

The URI SAN is verified by `tpm-cert-check.sh` on the Talos node before the cert is presented to the Registration Service. This prevents a stolen cert from being used on a machine with a different TPM.

---

## Step-by-Step Offline Provisioning

### 1. Register (or import) the machine

If the machine is not yet registered, import it from its known EK fingerprint:

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/import \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ek_fingerprint": "<64-char hex>",
    "role":           "worker-app",
    "hostname":       "w1.airgapped.internal"
  }'
```

Note the `machine_id` in the response.

### 2. Generate the offline bundle

```bash
MACHINE_ID="<uuid from step 1>"

curl -s "https://reg.your-domain.com/api/v1/machines/${MACHINE_ID}/offline-bundle" \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -o bundle.json

# Inspect the bundle
jq . bundle.json
```

Bundle contents:

```json
{
  "machine_id":      "<UUID>",
  "role":            "worker-app",
  "iso_url":         "https://github.com/.../itl-talos-worker-app-amd64.iso",
  "config_token":    "<one-time token>",
  "config_url":      "https://reg.your-domain.com/api/v1/config/<token>",
  "enrollment_cert": "-----BEGIN CERTIFICATE-----\n...",
  "enrollment_key":  "-----BEGIN RSA PRIVATE KEY-----\n..."
}
```

> The `enrollment_key` is only returned once. Treat it as a short-lived secret — it is valid only for 30 days and is deleted from the node after first successful enrollment.

### 3. Download the ISO (on the internet-connected machine)

```bash
ISO_URL=$(jq -r .iso_url bundle.json)
curl -L "${ISO_URL}" -o talos-role.iso
```

### 4. Build the offline USB

```bash
cd provisioner/usb-agent
./build-usb-offline.sh /dev/sdX \
  --bundle ../../../bundle.json \
  --iso    ../../../talos-role.iso
```

The script embeds onto the USB:
- `/itl/talos.iso` — the role ISO
- `/itl/reg-bundle.json` — machine metadata
- The enrollment cert embedded into the MachineConfig at `/var/lib/itl-tpm/enrollment.crt`
- The enrollment key embedded into the MachineConfig at `/var/lib/itl-tpm/enrollment.key`

### 5. Transfer USB to the air-gapped site

Use physical transport. The USB is now fully self-contained.

### 6. Boot the target machine from USB

The Alpine Linux agent runs automatically:

1. Reads TPM EK + hardware identity (recorded to `/itl/tpm-receipt.json` on the USB)
2. Detects `ITL_OFFLINE=yes` mode — skips network registration
3. Uses the pre-baked `/itl/talos.iso`
4. Writes ISO to target disk via `dd`
5. Injects the embedded MachineConfig (with cert + key) into the EFI partition
6. Reboots into Talos

### 7. Talos first boot — certificate enrollment

The `itl-tpm-register` extension runs and detects `/var/lib/itl-tpm/enrollment.crt` and `.key`:

**Certificate-based enrollment (Path A):**

```
1. Detect sealed key files on EFI partition:
   - enrollment.key.enc  present → Layer 2 (TPM-sealed) path
   - enrollment.key      present → plaintext path (fallback)

Layer 2 unseal:
2. tpm2_createprimary -C o -G rsa  (recreate SRK, deterministic on this TPM)
3. tpm2_load + tpm2_unseal         (recover AES key into memory)
4. openssl enc -d -aes-256-cbc     (decrypt enrollment key into /run/itl-enroll.key)

Then (both paths):
5. tpm-cert-check.sh: chain verify, expiry, key match, URI SAN ↔ TPM EK
6. Generate nonce: openssl rand -hex 32
7. Sign nonce with enrollment private key: openssl dgst -sha256 -sign <key>
8. POST /api/v1/machines/enroll:
   {
     "cert_pem":        "<PEM>",
     "nonce":           "<hex>",
     "nonce_signature": "<base64>"
   }
9. Registration Service:
   a. Verifies cert chain against Enrollment CA
   b. Verifies RSA-SHA256 signature of nonce against cert public key
   c. Extracts machine_id and role from cert CN/OU
   d. Verifies URI SAN matches registered EK fingerprint
   e. Sets machine status = attested
10. On success:
   - Writes /var/lib/itl-tpm/attested
   - Deletes /run/itl-enroll.key              ← key destroyed from tmpfs
   - Deletes enrollment.key.enc + seal files  ← sealed objects destroyed
   - Writes attestation receipt
```

The private key (in `/run` tmpfs) and all sealed key material on disk are destroyed on the node after the first successful enrollment. They cannot be recovered.

> The node must be able to reach the Registration Service **once** to complete enrollment. For fully offline nodes with no return network path, see the note below.

---

## Fully Disconnected Nodes (no network at all)

If the node will never have any network access, enrollment cannot complete automatically. The operator must manually mark the machine as attested after verifying the hardware:

```bash
# Mark attested without network-based enrollment
curl -X POST https://reg.your-domain.com/api/v1/machines/${MACHINE_ID}/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role": "worker-app", "hostname": "w1.isolated.internal"}'
```

The node will have the `pending` state file at `/var/lib/itl-tpm/pending` and will reattempt enrollment on each boot until it succeeds or the operator manually creates the `attested` flag.

---

## Certificate Security Model

| Property | Value |
|---|---|
| CA key size | RSA 4096 |
| CA validity | 10 years |
| Issued cert key size | RSA 2048 |
| Issued cert validity | 30 days (configurable) |
| Authentication method | Challenge-response: sign random nonce with private key |
| Replay prevention | Nonce is random, single-use |
| Key destruction | Private key deleted from node disk after first successful enrollment |
| CA storage | `/var/lib/itl-reg/ca/` — included in `reg-data` volume |

---

## Rotating the Enrollment CA

If the CA is compromised, generate a new one by removing the CA directory and restarting the service. Existing enrolled (attested) machines are unaffected — they no longer hold enrollment keys. Only machines with unspent offline bundles will fail enrollment and need new bundles.

```bash
# On the Registration Service host
docker compose exec registration rm -rf /var/lib/itl-reg/ca
docker compose restart registration
# New CA is auto-generated on startup
```

Re-generate offline bundles for any machines that have not yet enrolled.

---

## Offline Mode Fallback

The online USB agent (`build-usb.sh`) also supports automatic offline fallback. If the Registration Service is unreachable and a pre-baked ISO exists on the USB (`/itl/talos.iso`), it automatically switches to offline mode:

```
ITL_OFFLINE=auto (default)
  → Tries Registration Service
  → If unreachable AND /itl/talos.iso exists: uses ISO, skips registration
  → If unreachable AND no ISO: exits with error
```

Force offline mode explicitly:

```bash
ITL_OFFLINE=yes ./build-usb.sh /dev/sdX
```
