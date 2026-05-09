# Security Reference

All security configuration for ITL.Talos.HardenedOS lives in `config/patches/security-hardening.yaml` and `config/patches/oidc-patch.yaml`. This document explains every setting, why it is present, and what to change for your environment.

---

## Disk Encryption (LUKS2 + TPM)

The `STATE` and `EPHEMERAL` Talos partitions are encrypted with LUKS2. Both use a **dual-key setup**:

```yaml
machine:
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - nodeID: {}    # slot 0 — Talos-managed node identity key
        - tpm: {}       # slot 1 — TPM2 PCR-sealed auto-unlock key
    ephemeral:
      provider: luks2
      keys:
        - nodeID: {}
        - tpm: {}
```

| Key | Slot | Purpose |
|---|---|---|
| `nodeID` | 0 | Talos generates this key from the node's identity. Used for recovery if the TPM-sealed key is inaccessible. Never exposed to operators. |
| `tpm` | 1 | Sealed to the current PCR state. Auto-unlocks on reboot if firmware/boot chain has not changed. |

> The existing documentation showing only a single TPM key without `nodeID` is incorrect. Always use the dual-key setup — a single TPM key with no recovery path means the disk is permanently inaccessible if the TPM is cleared or the firmware changes.

### Required kernel modules

These must be declared in the machine config:

```yaml
machine:
  kernel:
    modules:
      - name: tpm
      - name: tpm_crb
      - name: tpm_tis
      - name: integrity
      - name: dm_crypt
```

`tpm_crb` covers modern firmware-based TPMs (most x86 servers since 2016). `tpm_tis` covers LPC-attached discrete TPMs. Both are loaded — the kernel ignores the one that does not match.

### PCR sealing

The TPM seals the LUKS key against PCRs 0–7:

| PCR | Covers | Effect of change |
|---|---|---|
| 0 | SRTM / firmware code | Firmware update → re-seal required |
| 1 | Firmware configuration | BIOS setting change → re-seal |
| 2 | Option ROM code | New PCIe card firmware → re-seal |
| 3 | Option ROM configuration | Option ROM config change → re-seal |
| 4 | MBR / bootloader code | Bootloader update → re-seal |
| 5 | GPT / partition table | Disk repartition → re-seal |
| 6 | State transitions | Platform reset events |
| 7 | Secure Boot policy and keys | Secure Boot key change → re-seal |

If any of these PCRs change, the TPM will refuse to unseal the key. The node falls back to the `nodeID` key (Talos handles this transparently on upgrade) or requires manual intervention.

---

## Kernel Hardening (sysctls)

### Kernel memory

```yaml
kernel.kptr_restrict: "2"              # Hide kernel symbol addresses from all users
kernel.randomize_va_space: "2"         # Full ASLR for stack, heap, mmap
kernel.unprivileged_bpf_disabled: "1"  # Block BPF from non-root processes
kernel.yama.ptrace_scope: "2"          # Only admin can ptrace; blocks process injection
```

### Network hardening

```yaml
# Source validation — drop packets that arrive on unexpected interfaces
net.ipv4.conf.all.rp_filter: "1"
net.ipv4.conf.default.rp_filter: "1"

# Block ICMP redirect injection
net.ipv4.conf.all.accept_redirects: "0"
net.ipv4.conf.all.send_redirects: "0"
net.ipv4.conf.default.accept_redirects: "0"

# Log packets that should not be here
net.ipv4.conf.all.log_martians: "1"

# SYN flood mitigation
net.ipv4.tcp_syncookies: "1"

# Block source routing
net.ipv4.conf.all.accept_source_route: "0"
```

### IPv6

IPv6 is **disabled** on these nodes:

```yaml
net.ipv6.conf.all.disable_ipv6: "1"
net.ipv6.conf.default.disable_ipv6: "1"
```

> The integration guide and some older documentation incorrectly shows IPv6 enabled (`disable_ipv6: "0"`). The actual security hardening patch disables it. If your environment requires IPv6, explicitly override this in a node-specific patch.

### eBPF

```yaml
kernel.unprivileged_bpf_disabled: "1"   # Non-root cannot use BPF
net.core.bpf_jit_harden: "2"            # Constant blinding in BPF JIT
```

---

## Kernel Module Policy

Only permitted modules can be loaded. The `itl-security` extension writes `/etc/modprobe.d/itl-policy.conf`:

- All load operations are logged via audit
- Modules not explicitly listed are blocked at the policy layer

TPM and crypto modules are explicitly allowed (required for LUKS2 and attestation). Do not remove these from the allowed list.

---

## SSH Hardening

```yaml
# Ed25519 only — no RSA, ECDSA, or DSA host keys
HostKeyAlgorithms ssh-ed25519

# ChaCha20-Poly1305 cipher only — modern authenticated encryption
Ciphers chacha20-poly1305@openssh.com

# Key-based auth only — no passwords
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no

# Connection limits
MaxAuthTries 3
LoginGraceTime 30
```

---

## Kubelet Hardening (CIS Kubernetes Benchmark)

Applied via `security-hardening.yaml` kubelet configuration:

```yaml
cluster:
  kubelet:
    extraArgs:
      # Disable anonymous auth to kubelet API
      anonymous-auth: "false"
      # Require explicit authorization for all requests
      authorization-mode: Webhook
      # Rotate serving certs automatically
      rotate-server-certificates: "true"
      # Prevent privilege escalation via containers
      protect-kernel-defaults: "true"
      # Event record limit
      event-qps: "5"
```

---

## Kubernetes API Server (OIDC)

Configured in `config/patches/oidc-patch.yaml`. The kube-apiserver is configured for OIDC authentication via Keycloak:

```yaml
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: "https://auth.itlusions.com/realms/itl"
      oidc-client-id:  "talos-cluster"
      oidc-username-claim: "preferred_username"
      oidc-username-prefix: "oidc:"
      oidc-groups-claim:  "groups"
      oidc-groups-prefix: "oidc:"
```

Audit logging is also configured:

```yaml
audit-log-path:      "/var/log/kubernetes/audit.log"
audit-log-maxage:    "30"
audit-log-maxbackup: "10"
audit-log-maxsize:   "100"
```

Encryption at rest for Kubernetes Secrets:

```yaml
encryption-provider-config: "/etc/kubernetes/encryption-config.yaml"
```

---

## Audit Rules

The `itl-security` extension deploys audit rules under `/etc/audit/`. These capture:

- File access on sensitive paths (`/etc/passwd`, `/etc/shadow`, `/etc/sudoers`)
- Privileged execution (`sudo`, `su`)
- Kernel module load/unload
- Network configuration changes
- Process credential changes (`setuid`, `setgid`)

---

## Security Limitations and Roadmap

| Item | Current state | Planned |
|---|---|---|
| PCR quote verification | PCR quotes are stored and logged; not cryptographically verified server-side | Full TPM2 remote attestation with AIK/AK key (v2.0 roadmap) |
| Admin token | Single static bearer token | OIDC-based admin auth or mTLS |
| EK CA chain verification | Optional (`ITL_TPM_VERIFY_CA` env var) | Enabled by default |
| SQLite backend | Suitable for single Registration Service instance | PostgreSQL for HA deployments |
| Enrollment key window | Key on disk between USB flash and first successful boot | Short-lived cert (30 days) mitigates exposure; key deleted immediately after use |

---

## Applying Security Patches

The security hardening patch is applied by the CI pipeline as a MachineConfig patch layer. To apply a change:

1. Edit `config/patches/security-hardening.yaml`
2. Commit, push, and tag a new release
3. Download updated `controlplane-final.yaml` / `worker-*-final.yaml` from the release
4. On running nodes: `talosctl apply-config --nodes <ip> --file <updated-yaml>`

> Talos applies config changes gracefully. Reboot is required for kernel sysctl changes. LUKS2 config changes require a reinstall.
