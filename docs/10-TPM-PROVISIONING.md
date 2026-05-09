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
  └─ POST /api/v1/register → receives role ISO URL + one-time config token
  └─ Downloads role ISO → dd to target disk
  └─ Writes receipt to EFI partition → reboots


Phase 2 — Talos Attestation (runs once inside Talos, idempotent)
─────────────────────────────────────────────────────────────────
itl-tpm-register extension runs on first boot
  ├─ Path A (offline):  enrollment cert + key present
  │    └─ Signs nonce → POST /api/v1/machines/enroll → key deleted
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

**Step 5 — ISO download and verification**

```bash
curl -L <iso_url> -o /tmp/talos.iso
# If <iso_url>.sha256 exists, verifies SHA-256 before continuing
```

**Step 6 — Write to disk**

```bash
dd if=/tmp/talos.iso of=<target_disk> bs=4M
sync
```

Target disk is auto-detected (first non-USB block device) or set via `ITL_TARGET_DISK`.

**Step 7 — EFI receipt**

Written to the EFI FAT partition at `/itl/registration.json`:

```json
{
  "machine_id":   "<UUID>",
  "ek_fingerprint": "<64-char hex>",
  "role":         "worker-app",
  "config_token": "<token>",
  "reg_url":      "https://reg.your-domain.com",
  "registered_at": "2026-05-09T10:00:00Z"
}
```

This receipt is the handover record between Phase 1 and Phase 2.

**Step 8 — Reboot into Talos**

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

### Path B — Standard (PCR quote)

This is the default path for online-provisioned nodes.

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
