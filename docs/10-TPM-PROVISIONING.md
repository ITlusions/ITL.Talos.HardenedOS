# TPM Provisioning

End-to-end guide for the Zero-Touch Provisioning (ZTP) flow: from booting the USB agent on bare metal to a fully attested Talos node in the cluster.

---

## Overview

ZTP requires two phases. Both are driven by TPM hardware identity — the EK (Endorsement Key) fingerprint is the durable identifier for every machine.

```
Phase 1 — USB Registration (Alpine Linux, before Talos)
─────────────────────────────────────────────────────────
USB agent boots on target hardware
  └─ Reads TPM EK + hardware identity (UUID, MAC, serial, product)
  └─ Generates TPM wrapping key (RSA-2048 OAEP, hardware-bound)
  └─ POST /api/v1/register → receives role ISO URL + one-time config token
  └─ POST /api/v1/machines/{id}/request-cert → enrollment cert (Layer 1 encrypted)
  └─ TPM-seals enrollment key on EFI partition (Layer 2)
  └─ Downloads role ISO → dd to target disk → reboots


Phase 2 — Talos Attestation (runs once inside Talos, idempotent)
─────────────────────────────────────────────────────────────────
itl-tpm-register extension runs on first boot
  ├─ Path A (cert enrollment):  sealed enrollment key detected
  │    └─ Unseal AES key via TPM → decrypt enrollment.key.enc → /run (tmpfs)
  │    └─ tpm-cert-check.sh validates cert chain + URI SAN + key match
  │    └─ Signs nonce → POST /api/v1/machines/enroll → key deleted from /run
  └─ Path B (standard): generates PCR quote (PCRs 0-7)
       └─ POST /api/v1/attest → machine marked attested
```

---

## Prerequisites

### Hardware

- TPM 2.0 chip (required for Phase 1 EK read and Phase 2 PCR quote)
  - OEM EK X.509 certificate preferred (TPM NV index `0x01c00002`)
  - If absent, the agent falls back to `tpm2_createek` (transient public key)
- UEFI or BIOS that can boot from USB
- A USB drive of at least 1 GB

### Software

- Registration Service running and reachable — see `09-REGISTRATION-SERVICE.md`
- At least one GitHub Release of `ITL.Talos.HardenedOS` published (so role ISOs exist)
- Role configs downloaded into the Registration Service

---

## Build the USB Agent

The USB agent is an Alpine Linux image with the TPM tools, curl, and the provisioning scripts pre-baked in.

### Online agent (standard)

Requires network access to the Registration Service and GitHub Releases during provisioning.

```bash
cd provisioner/usb-agent
./build-usb.sh /dev/sdX
```

Replace `/dev/sdX` with your USB device. The script formats the drive, installs Alpine, copies `tpm-register.sh`, `tpm-attest.sh`, `tpm-common.sh`, and configures `/etc/local.d/itl-register.start` to run on boot.

### Environment overrides

You can embed overrides into the image:

```bash
ITL_REG_URL=https://reg.your-domain.com \
ITL_ROLE=controlplane \
ITL_AUTO_CONFIRM=yes \
./build-usb.sh /dev/sdX
```

These can also be set as kernel command-line arguments via GRUB on the USB:

| Kernel arg | Default | Description |
|---|---|---|
| `itl.reg_url=` | `https://reg.itlusions.com` | Registration Service URL |
| `itl.role=` | `worker-app` | Desired node role |
| `itl.auto_confirm=yes` | — | Skip confirmation prompt |
| `itl.offline=yes` | `auto` | Force offline mode |

---

## Phase 1 — USB Registration Step by Step

Insert USB into target server and boot. The agent runs automatically.

### What the agent does

**Step 1 — Hardware identity collection** (`tpm-common.sh: read_hw_identity`)

```
HW_MAC     = first NIC /sys/class/net/*/address (excluding lo)
HW_UUID    = /sys/class/dmi/id/product_uuid (SMBIOS UUID)
HW_SERIAL  = /sys/class/dmi/id/chassis_serial
HW_PRODUCT = /sys/class/dmi/id/product_name
```

**Step 2 — TPM EK read** (`tpm-common.sh: read_tpm_ek`)

```
Primary:  tpm2_getekcertificate --ek-certificate <file>
          Reads OEM EK X.509 from NV index 0x01c00002
          Sets EK_SOURCE="cert"

Fallback: tpm2_createek --ek-context <ctx>
          tpm2_readpublic --object-context <ctx>
          Sets EK_SOURCE="pub"
```

**Step 3 — EK fingerprint** (`tpm-common.sh: ek_fingerprint`)

```bash
sha256sum <raw EK bytes>  # 64-char hex, stable across reboots
```

**Step 4 — Registration** (`POST /api/v1/register`)

Sends all collected data. On success receives:
- `machine_id` — UUID v4 assigned to this machine
- `role` — role to provision
- `iso_url` — direct download link to the role ISO
- `config_token` — one-time token Talos will use to fetch its config
- `config_url` — full URL: `{reg_url}/api/v1/config/{token}`

**Step 4.5 — Generate TPM wrapping key (Layer 1 transport protection)**

Before requesting the enrollment certificate, the USB agent generates a TPM-resident unrestricted RSA-2048 OAEP-SHA256 decrypt key:

```bash
tpm2_createprimary -C o -G rsa -c $srk_ctx
tpm2_create -C $srk_ctx -G rsa2048:oaep:sha256 \
    -a "decrypt|fixedtpm|fixedparent|noda" \
    -u $pub -r $priv
tpm2_load -C $srk_ctx -u $pub -r $priv -c $wrap_ctx
tpm2_readpublic -c $wrap_ctx --format pem
```

The public key PEM is sent in the `wrapping_key_pem` field of `POST /request-cert`. The private half is hardware-bound (`fixedtpm|fixedparent`) — it cannot leave the TPM chip. If TPM key creation fails, the agent falls back to TLS-only protection.

**Step 5 — Request enrollment certificate** (`POST /api/v1/machines/{id}/request-cert`)

The Registration Service:
1. Re-verifies the EK material (same as `POST /register`)
2. Issues an RSA-2048 enrollment cert (valid 30 days) with URI SAN `urn:itl:ek:<fingerprint>`, `keyEncipherment`, `SubjectKeyIdentifier`, `AuthorityKeyIdentifier`
3. Encrypts the enrollment private key with the wrapping public key (RSA-OAEP-SHA256)

The USB agent:
1. Decrypts the enrollment key with `tpm2_rsadecrypt` — key recovered in-memory only
2. Generates a 32-byte random AES key (`openssl rand 32`)
3. AES-256-CBC encrypts the enrollment key: `openssl enc -aes-256-cbc -pbkdf2`
4. Seals the AES key in the TPM Storage hierarchy (`tpm2_create -i $aes_key -a "fixedtpm|fixedparent|noda"`)
5. Destroys the AES key from disk immediately

**Step 6 — ISO download and verification**

```bash
curl -L <iso_url> -o /tmp/talos.iso
# If <iso_url>.sha256 exists, verifies SHA-256 before continuing
```

**Step 7 — Write to disk**

```bash
dd if=/tmp/talos.iso of=<target_disk> bs=4M
sync
```

Target disk is auto-detected (first non-USB block device) or set via `ITL_TARGET_DISK`.

**Step 8 — EFI receipt**

Written to the EFI FAT partition at `/itl/`. The enrollment key is **never** written in plaintext:

```
/itl/registration.json      — machine identity, config token, reg_url
/itl/enrollment.crt         — X.509 enrollment certificate (PEM)
/itl/enrollment.key.enc     — AES-256-CBC ciphertext of enrollment private key
/itl/enrollment.seal.pub    — TPM seal object public area
/itl/enrollment.seal.priv   — TPM seal object private area
/itl/enrollment-ca.crt      — Enrollment CA certificate (PEM)
```

`enrollment.key` is intentionally absent when Layer 2 sealing succeeds. `tpm-attest.sh` detects the presence of `enrollment.seal.pub/priv` and `enrollment.key.enc` as the trigger to unseal via TPM before use.

Fallback: if TPM is unavailable or sealing fails, `enrollment.key` is written in plaintext and the seal files are absent. TLS remains the only transport protection in this case.

**Step 9 — Reboot into Talos**

Talos boots from the written ISO. On first boot it reads `talos.config=<config_url>` from the kernel cmdline, fetches the MachineConfig (one-time — token consumed), applies it, and reboots.

### Interactive confirmation

By default the agent pauses before writing to disk and shows:

```
Target disk : /dev/sda  (500 GB — WD Blue)
Role        : worker-app
Reg Service : https://reg.itlusions.com

Type YES to continue or Ctrl-C to abort:
```

Set `ITL_AUTO_CONFIRM=yes` or kernel arg `itl.auto_confirm=yes` to skip this.

---

## Phase 2 — Talos Attestation Step by Step

The `itl-tpm-register` extension runs as a Talos service on every boot. It is idempotent: if `/var/lib/itl-tpm/attested` exists the service exits 0 immediately.

### Path A — Certificate enrollment (ZTP-provisioned nodes)

This path runs when the USB agent wrote sealed enrollment key files to the EFI partition during Phase 1.

**Step 1** — Re-reads TPM EK and hardware identity.

**Step 2** — Unseal enrollment key (`unseal_enrollment_key`)

Detects `enrollment.seal.pub`, `enrollment.seal.priv`, and `enrollment.key.enc` in `STATE_DIR`:

```bash
# Recreate Storage-hierarchy SRK (deterministic on this TPM — no owner password)
tpm2_createprimary -C o -G rsa -c $srk_ctx
# Load the seal object
tpm2_load -C $srk_ctx -u enrollment.seal.pub -r enrollment.seal.priv -c $seal_ctx
# Unseal the AES key
tpm2_unseal -c $seal_ctx -o $aes_key
# Decrypt enrollment key into /run (tmpfs)
openssl enc -d -aes-256-cbc -pbkdf2 -in enrollment.key.enc -pass file:$aes_key -out /run/itl-enroll.key
```

If no seal files are present (`enrollment.key` exists instead), this step is skipped and the plaintext path is used. If unsealing fails, cert enrollment is skipped and the node falls through to Path B.

**Step 3** — `tpm-cert-check.sh` validates the enrollment cert:
1. Chain: `openssl verify -CAfile enrollment-ca.crt enrollment.crt`
2. Expiry: cert not-after > now
3. Key match: cert public key matches private key modulus
4. EKU: `clientAuth` present (warning only)
5. URI SAN: `urn:itl:ek:<fingerprint>` matches current TPM EK fingerprint

If any check fails (except EKU warning), enrollment is aborted.

**Step 4** — Sign a nonce with the enrollment key and `POST /api/v1/machines/enroll`:

```bash
nonce=$(openssl rand -hex 32)
sig=$(printf '%s' "$nonce" | openssl dgst -sha256 -sign /run/itl-enroll.key -binary | base64 -w0)
```

**Step 5** — On `status=attested`:
- Writes `/var/lib/itl-tpm/attested`
- Deletes `/run/itl-enroll.key` (tmpfs, but explicit cleanup)
- Deletes `enrollment.key.enc`, `enrollment.seal.pub`, `enrollment.seal.priv` from `STATE_DIR`
- Exits 0

### Path B — Standard (PCR quote)

This is the default path for online-provisioned nodes that did not receive an enrollment cert, or when Path A fails.

**Step 1** — Re-reads TPM EK and hardware identity (same logic as Phase 1).

**Step 2** — Generates random nonce: `openssl rand -hex 20`

**Step 3** — Generates PCR quote covering PCRs 0–7:

```bash
tpm2_quote \
  --pcr-list sha256:0,1,2,3,4,5,6,7 \
  --qualification <nonce> \
  --message    /tmp/quote.msg \
  --signature  /tmp/quote.sig
```

PCRs 0–7 cover: firmware code, firmware config, option ROMs, option ROM config, MBR/bootloader, GPT, state transitions, and Secure Boot state.

**Step 4** — `POST /api/v1/attest` with all fields.

**Step 5** — On `status=attested` or `status=already_attested`:
- Writes `/var/lib/itl-tpm/attested` (idempotency flag)
- Writes `/var/lib/itl-tpm/attestation_receipt.json`
- Exits 0

**Step 6** — On `status=pending_approval`:
- Writes `/var/lib/itl-tpm/pending` (non-blocking)
- Exits 0 — Talos boot continues normally

**All errors are non-fatal** — the extension exits 0 even on network failure to avoid blocking Talos boot. Check the service log to diagnose issues.

---

## Machine Status Reference

| Status | Meaning | Next action |
|---|---|---|
| `pending_approval` | EK fingerprint not previously seen; awaiting operator decision | Admin calls `POST /api/v1/machines/{id}/approve` |
| `registered` | Approved; ISO assigned; waiting for Talos to boot and fetch config | No action needed — wait for node to boot |
| `attested` | TPM PCR quote received; node is running | Cluster operations proceed normally |
| `rejected` | Operator rejected the machine | No further provisioning |

### Check machine status

```bash
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  | jq '.[] | {hostname, role, status, hw_mac, ek_fingerprint}'
```

### Approve a pending machine

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/<machine_id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role": "worker-app", "hostname": "w1.itlusions.internal"}'
```

---

## ZTP Timeline

```
USB insert + boot     ~30 sec   Alpine boots, TPM read, register call
ISO download          ~5 min    Role ISO ~500 MB over 1 Gbps LAN
dd to disk            ~2 min    ISO write
Talos first boot      ~2 min    Config fetch, patch apply, reboot
TPM attestation       ~30 sec   PCR quote generated and sent
──────────────────────────────
Total per node        ~10 min   Zero operator input after USB insert
```

---

## Manual Pre-Registration

If you know the hardware before it arrives (e.g., from a purchase order with serial numbers), pre-register machines so they auto-approve:

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/import \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ek_fingerprint": "<64-char hex from spec sheet>",
    "role":           "controlplane",
    "hostname":       "cp1.itlusions.internal",
    "assigned_ip":    "10.0.0.10/24"
  }'
```

When the USB agent calls `POST /api/v1/register` and the EK fingerprint matches, the machine is immediately set to `registered` rather than `pending_approval`.

---

## Idempotency

- **Phase 1** (USB agent): if a machine with the same EK fingerprint already exists in the database, the agent receives an updated config token but does not change the machine's role or hostname. Re-flashing the same machine is safe.
- **Phase 2** (attest script): the `$ATTESTED_FLAG` file at `/var/lib/itl-tpm/attested` prevents the script from posting a duplicate attestation. Delete this file to force re-attestation on the next boot.

---

## Integration Methods

### Method 1 — Direct (USB agent, standard)

The default method described above. The USB agent downloads the role ISO at provisioning time over the network.

### Method 2 — Hybrid (Image Factory kernel + custom config)

Use the upstream Talos Image Factory for kernel/initramfs and your Registration Service for config delivery only. Suitable when you want to track the latest Talos kernel without rebuilding ISOs.

```bash
# Generate schematic ID for your extensions at factory.talos.dev
SCHEMATIC_ID=$(curl -sS -X POST https://factory.talos.dev/schematics \
  -H "Content-Type: application/json" \
  -d '{"customization":{"systemExtensions":{"officialExtensions":[]}}}' \
  | jq -r '.id')

# Kernel/initramfs from Image Factory, config from Registration Service
kernel https://factory.talos.dev/image/${SCHEMATIC_ID}/v1.9.0/kernel-amd64 \
  talos.config=https://reg.your-domain.com/api/v1/config/<token>
initrd https://factory.talos.dev/image/${SCHEMATIC_ID}/v1.9.0/initramfs-amd64.xz
```

### Method 3 — Air-Gapped (offline USB bundle)

For nodes with no internet access. See `11-AIRGAPPED-DEPLOYMENT.md`.
