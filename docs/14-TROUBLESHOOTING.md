# Troubleshooting

---

## Build Pipeline Issues

### Build does not start after `git push origin v1.0.0`

- Verify the tag format: must match `v*.*` (e.g. `v1.0.0`). A tag like `1.0.0` will not trigger the workflow.
- Check GitHub Actions is enabled for the repository (Settings → Actions → Allow all actions).
- Confirm you have `contents: write` and `packages: write` permissions configured on the workflow.

### Build times out at the ISO step

The ISO build step (15 min) depends on the Talos Image Factory API. If it is slow, retry the workflow run from the GitHub Actions tab. The step is deterministic — retrying is safe.

### `itl-talos-controlplane-amd64.iso` not present in the release

The build job that produces role ISOs runs after the installer and config jobs. If the release was published before all jobs completed, re-run the failed jobs. The release assets are uploaded at the end of the workflow.

---

## Registration Service Issues

### Service will not start — `Set ITL_ADMIN_TOKEN in .env`

The `ITL_ADMIN_TOKEN` variable has no default and is required. Generate one and set it:

```bash
echo "ITL_ADMIN_TOKEN=$(openssl rand -hex 32)" >> provisioner/.env
```

### `POST /api/v1/register` returns 422

The `ek_fingerprint` field validation failed. It must be exactly 64 lowercase hexadecimal characters. Verify the fingerprint being sent:

```bash
echo -n "<fingerprint>" | wc -c   # must be 64
echo -n "<fingerprint>" | grep -P '^[0-9a-f]{64}$'
```

If the USB agent produced the fingerprint, check `tpm-common.sh: ek_fingerprint()` — it uses `openssl dgst -sha256` of the raw EK bytes.

### `GET /api/v1/config/{token}` returns 404

The one-time config token has already been consumed (Talos fetched the config on first boot). This is expected. If a new token is needed (e.g. the node needs to be re-provisioned):

```bash
# Re-register the machine from the USB agent
# OR generate a fresh token by approving again
curl -X POST https://reg.your-domain.com/api/v1/machines/<id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -d '{"role": "worker-app", "hostname": "w1.itlusions.internal"}'
```

### Role configs not found — `Base config not found at /var/lib/itl-reg/configs/...`

The role YAML files have not been downloaded yet. Run:

```bash
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh ${TALOS_RELEASE_TAG}"
```

If the GitHub Release does not exist yet, wait for the CI pipeline to finish.

### Caddy certificate provisioning fails

- Ensure port 80 and 443 are open inbound from the internet (required for Let's Encrypt ACME challenge)
- Verify the domain in `Caddyfile` matches the DNS record pointing to this server
- For internal-only deployments, switch to `tls internal` in the Caddyfile

---

## USB Agent Issues

### USB agent boots but cannot reach Registration Service

- Check the `ITL_REG_URL` value: `cat /proc/cmdline | grep itl.reg_url`
- Check network: `ping -c3 reg.your-domain.com`
- If both fail, the agent will switch to offline mode if `/itl/talos.iso` exists on the USB. Check `OFFLINE_MODE` in the boot log.

### TPM not detected — `ERROR: TPM device not found`

1. Verify the kernel modules are loaded:

```bash
lsmod | grep -E 'tpm|integrity'
```

2. Check the TPM device exists:

```bash
ls /dev/tpm* /dev/tpmrm*
```

3. If missing: check BIOS/UEFI — TPM must be enabled. Also verify `tpm_crb` or `tpm_tis` is loaded (not both are needed, depends on hardware type).

4. Check TPM capabilities:

```bash
tpm2_getcap properties-fixed 2>&1 | head -20
```

### `tpm2_getekcertificate` returns nothing (NV index empty)

The OEM did not provision an EK certificate. The agent automatically falls back to `tpm2_createek` and exports the public key. `EK_SOURCE` will be `"pub"` instead of `"cert"`. Registration continues normally — only the EK fingerprint changes.

### ISO download fails or is corrupted

- The USB agent verifies the SHA-256 checksum if `<iso_url>.sha256` exists. If verification fails, the download is retried once.
- Check available disk space on the USB (need ~500 MB for the ISO download in `/tmp`)
- Check network stability — large downloads over unstable links may corrupt. Use a wired connection for provisioning.

### `dd` fails — `Operation not permitted` or `No space left on device`

- Verify the target disk was correctly auto-detected: `echo $TARGET_DISK`
- The target disk must be at least 40 GB
- Do not run from the target disk itself — the USB agent must be on a different device

---

## Talos Boot / Attestation Issues

### Machine stuck in `registered` state after Talos boot

The `itl-tpm-register` extension ran but did not call `POST /api/v1/attest`. Check the extension service log:

```bash
talosctl logs itl-tpm-register --nodes <ip>
```

Common causes:
- Network unreachable from inside Talos — check firewall rules allow the node to reach the Registration Service on 443
- Registration Service health check failing — verify `curl https://reg.your-domain.com/healthz`
- TPM device not available inside Talos — verify kernel modules are declared in the MachineConfig (`config/patches/security-hardening.yaml`)

### Machine in `pending_approval` after attestation call

The EK fingerprint sent during attestation did not match any `registered` machine. This can happen if:
- The USB agent registered the machine but attestation was sent from a different fingerprint (unlikely)
- The machine was never registered via the USB agent (booted directly from ISO without running the agent)

Approve the machine manually:

```bash
# Find the machine with the correct EK fingerprint
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  | jq '.[] | select(.status == "pending_approval")'

# Approve
curl -X POST https://reg.your-domain.com/api/v1/machines/<id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -d '{"role": "worker-app", "hostname": "w1.itlusions.internal"}'
```

### `tpm-attest.sh` keeps running on every boot

The idempotency flag at `/var/lib/itl-tpm/attested` is missing or not persisted between reboots. This file lives on the `STATE` partition which is LUKS2-encrypted. If the partition fails to mount, the file is not visible.

Check LUKS2 mount status:

```bash
talosctl get volumes --nodes <ip>
```

If the TPM-sealed key fails (PCR mismatch after firmware update), Talos should fall back to the `nodeID` key. If both keys fail, the partition cannot be unlocked and the node requires manual recovery.

### LUKS2 fails to auto-unlock after firmware update

A firmware update changed PCRs 0–7, invalidating the TPM-sealed key. The `nodeID` key (slot 0) takes over automatically in normal Talos operation. To re-seal the TPM key to the new PCR values:

```bash
# Talos re-seals the TPM key on config re-apply
talosctl apply-config --nodes <ip> --file <role>-final.yaml
```

### Certificate enrollment fails — `invalid signature`

The nonce signature verification failed on the `/api/v1/machines/enroll` endpoint. Causes:
- The private key on the node does not match the certificate sent (bundle was corrupted or the wrong cert/key pair was embedded)
- The cert has expired (30-day validity window passed)

Generate a new offline bundle:

```bash
curl -s https://reg.your-domain.com/api/v1/machines/${MACHINE_ID}/offline-bundle \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -o new-bundle.json
```

Rebuild the USB drive and retry.

### Enrollment key not deleted after successful enrollment

The `tpm-attest.sh` script deletes `/var/lib/itl-tpm/enrollment.key` after `POST /api/v1/machines/enroll` returns `status=attested`. If the script exits before deletion (power loss during enrollment), re-run the attestation:

```bash
# On the Talos node, delete the flag to force re-run
talosctl exec --nodes <ip> -- rm /var/lib/itl-tpm/attested

# Restart the extension service
talosctl service itl-tpm-register restart --nodes <ip>
```

---

## Kubernetes Issues

### Node not joining cluster after Talos install

1. Verify Talos is running: `talosctl health --nodes <ip>`
2. Verify the MachineConfig was applied: `talosctl get machineconfig --nodes <ip>`
3. If config token was consumed but config was not applied, re-apply directly:

```bash
talosctl apply-config --nodes <ip> --file worker-app-final.yaml --insecure
```

### Encryption-related — `device-mapper: table: ... dm-crypt`

The `dm_crypt` kernel module is not loaded. Check:

```bash
talosctl read /proc/modules --nodes <ip> | grep dm_crypt
```

If missing, verify the module declaration in `security-hardening.yaml` and re-apply the config.

---

## Diagnostic Commands Reference

```bash
# Registration Service — all machines
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" | jq .

# Talos — node health
talosctl health --nodes <ip>

# Talos — list extensions
talosctl get extensions --nodes <ip>

# Talos — ITL extension log
talosctl logs itl-tpm-register --nodes <ip>

# Talos — disk encryption volumes
talosctl get volumes --nodes <ip>

# Talos — kernel modules
talosctl read /proc/modules --nodes <ip> | grep -E 'tpm|dm_crypt|integrity'

# TPM — check on Alpine USB boot
tpm2_getcap properties-fixed 2>&1 | grep TPMVersion
tpm2_getcap handles-persistent
```
