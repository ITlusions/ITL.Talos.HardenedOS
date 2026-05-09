# TPM 2.0 and Attestation Deep Dive
## ITL.Talos.HardenedOS Security Analysis

**Document Version:** 1.0  
**Last Updated:** May 2026  
**Author:** ITlusions Security Team

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [TPM 2.0 Architecture](#tpm-20-architecture)
3. [Boot Process & Attestation Flow](#boot-process--attestation-flow)
4. [LUKS2 Encryption Implementation](#luks2-encryption-implementation)
5. [PCR (Platform Configuration Registers)](#pcr-platform-configuration-registers)
6. [Key Management & Sealing](#key-management--sealing)
7. [Security Guarantees](#security-guarantees)
8. [Attack Vectors & Mitigations](#attack-vectors--mitigations)
9. [ITL.Talos.HardenedOS Implementation](#itltalohardenedos-implementation)
10. [Operational Procedures](#operational-procedures)
11. [Troubleshooting](#troubleshooting)
12. [Compliance & Certification](#compliance--certification)

---

## Executive Summary

### What is TPM 2.0?

**Trusted Platform Module (TPM) 2.0** is a hardware security chip that provides:

- **Hardware Root of Trust** - Cryptographic operations in tamper-resistant hardware
- **Secure Storage** - Protected storage for keys and secrets
- **Attestation** - Proof that a system booted in a known-good state
- **Sealed Storage** - Decrypt data only when system state matches expected values

### How ITL.Talos.HardenedOS Uses TPM

```
┌─────────────────────────────────────────────────────────┐
│  ITL.Talos.HardenedOS Boot Flow                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  1. UEFI Firmware starts                                │
│     └─> Measures itself into TPM PCR[0-7]              │
│                                                         │
│  2. Bootloader (systemd-boot) loads                     │
│     └─> Measures itself into TPM PCR[4]                │
│                                                         │
│  3. Talos Kernel + Initramfs (UKI) loads                │
│     └─> Measures itself into TPM PCR[11]               │
│                                                         │
│  4. Talos init starts                                   │
│     └─> Measures boot phases into TPM PCR[11]          │
│                                                         │
│  5. Talos reads machine config from STATE partition     │
│     (STATE is encrypted with LUKS2)                     │
│     └─> TPM unseals STATE encryption key               │
│         (only if PCR measurements match expected)       │
│                                                         │
│  6. STATE partition decrypted and mounted               │
│     └─> Machine config available                       │
│                                                         │
│  7. Talos prepares to mount EPHEMERAL (/var)            │
│     └─> TPM unseals EPHEMERAL encryption key           │
│         (only if PCR measurements match expected)       │
│                                                         │
│  8. EPHEMERAL partition decrypted and mounted           │
│     └─> /var filesystem ready                          │
│                                                         │
│  9. Kubernetes starts                                   │
│     └─> Workloads can run                              │
│                                                         │
│  ✓ System fully booted with verified integrity          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Key Security Properties

✅ **Measured Boot** - Every component measured before execution  
✅ **Sealed Encryption** - Disk unlocks only on original hardware + firmware  
✅ **Automatic Unlock** - No manual password if TPM attestation passes  
✅ **Fallback Protection** - Optional manual passphrase for recovery  
✅ **Remote Attestation** - Prove to remote systems that boot was secure  

---

## TPM 2.0 Architecture

### Hardware Components

```
┌──────────────────────────────────────────────────────┐
│  TPM 2.0 Chip (Physical Hardware)                   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │  Cryptographic Co-Processor                │    │
│  │  • RSA (2048/4096-bit)                     │    │
│  │  • ECC (256/384-bit curves)                │    │
│  │  • AES (128/256-bit)                       │    │
│  │  • SHA-1, SHA-256, SHA-384                 │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │  Platform Configuration Registers (PCRs)   │    │
│  │  • 24 registers (PCR[0-23])                │    │
│  │  • SHA-256 hashes (32 bytes each)          │    │
│  │  • Extend-only (can't overwrite)           │    │
│  │  • Reset only on reboot                    │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │  Non-Volatile Storage (NVRAM)              │    │
│  │  • Storage Root Key (SRK)                  │    │
│  │  • Endorsement Key (EK)                    │    │
│  │  • Platform certificates                   │    │
│  │  • Sealed blobs                            │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │  Random Number Generator (RNG)             │    │
│  │  • Hardware entropy source                 │    │
│  │  • FIPS 140-2 compliant                    │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### TPM Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  TPM Hierarchies (Access Control)                   │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Platform Hierarchy                                 │
│  ├─> Owner: BIOS/UEFI firmware                     │
│  ├─> Controls: Platform configuration              │
│  └─> Keys: Platform Certificates                   │
│                                                     │
│  Storage Hierarchy (SRK)                            │
│  ├─> Owner: Operating System                       │
│  ├─> Controls: Key storage, sealing                │
│  └─> Keys: Sealed LUKS keys                        │
│                                                     │
│  Endorsement Hierarchy (EK)                         │
│  ├─> Owner: TPM manufacturer                       │
│  ├─> Controls: Attestation identity                │
│  └─> Keys: Endorsement Key (never leaves TPM)      │
│                                                     │
│  NULL Hierarchy                                     │
│  ├─> Owner: Anyone                                 │
│  ├─> Controls: Temporary objects                   │
│  └─> Keys: Ephemeral session keys                  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Boot Process & Attestation Flow

### Complete Boot Sequence with TPM Measurements

```
┌────────────────────────────────────────────────────────────────┐
│  Phase 1: UEFI Firmware (Platform Control)                     │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  1.1 Power On                                                  │
│      └─> TPM resets all PCRs to zero                          │
│                                                                │
│  1.2 UEFI Firmware loads                                       │
│      ├─> Measure firmware into PCR[0]                         │
│      └─> PCR[0] = SHA256(firmware_code)                       │
│                                                                │
│  1.3 UEFI Platform Configuration                               │
│      ├─> Measure platform config into PCR[1]                  │
│      └─> PCR[1] = SHA256(BIOS_settings)                       │
│                                                                │
│  1.4 Option ROMs (Network, RAID, etc.)                         │
│      ├─> Measure each ROM into PCR[2]                         │
│      └─> PCR[2] = SHA256(PCR[2] || option_rom_code)           │
│                                                                │
│  1.5 Secure Boot Database                                      │
│      ├─> Measure SecureBoot keys into PCR[7]                  │
│      └─> PCR[7] = SHA256(allowed_signing_keys)                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 2: Bootloader (systemd-boot)                            │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  2.1 UEFI loads systemd-boot EFI binary                        │
│      ├─> Verify signature (SecureBoot)                        │
│      ├─> Measure bootloader into PCR[4]                       │
│      └─> PCR[4] = SHA256(systemd_boot_efi)                    │
│                                                                │
│  2.2 systemd-boot reads boot entries                           │
│      └─> Finds Talos UKI (Unified Kernel Image)               │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 3: Talos UKI (Unified Kernel Image)                     │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  3.1 systemd-boot loads Talos UKI                              │
│      ├─> UKI contains: kernel + initramfs + cmdline           │
│      ├─> Verify UKI signature (SecureBoot)                    │
│      ├─> Measure UKI sections into PCR[11]                    │
│      │   (systemd-stub does this automatically)               │
│      └─> PCR[11] = SHA256(kernel || initramfs || cmdline)     │
│                                                                │
│  3.2 Kernel boots, init starts                                 │
│      └─> Control passes to Talos init                         │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 4: Talos Init (OS Control)                              │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  4.1 Talos measures boot phases into PCR[11]                   │
│      ├─> Each phase extends PCR[11]:                          │
│      │   PCR[11] = SHA256(PCR[11] || phase_data)              │
│      │                                                        │
│      └─> Phases measured:                                     │
│          • Mounting boot partition                            │
│          • Loading system config                              │
│          • Initializing network                               │
│          • Starting system services                           │
│                                                                │
│  4.2 Talos prepares to mount STATE partition                   │
│      └─> STATE contains machine configuration                 │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 5: Decrypt STATE Partition (Critical!)                  │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  5.1 Read LUKS2 header from STATE partition                    │
│      └─> Header contains: cipher, keyslots, metadata          │
│                                                                │
│  5.2 Identify TPM-sealed keyslot                               │
│      └─> Keyslot 0 is sealed to TPM                           │
│                                                                │
│  5.3 Request TPM to unseal the encryption key                  │
│      ├─> TPM checks PCR policy:                               │
│      │   "Unseal only if PCR[0,1,2,4,7,11] match expected"    │
│      │                                                        │
│      ├─> TPM compares current PCR values with policy          │
│      │   If match: ✓ Unseals key                             │
│      │   If mismatch: ✗ Refuses to unseal                    │
│      │                                                        │
│      └─> If unsealed: encryption key returned                 │
│          If failed: boot hangs OR prompts for manual password │
│                                                                │
│  5.4 Decrypt STATE partition with unsealed key                 │
│      └─> cryptsetup luksOpen /dev/disk STATE-key              │
│                                                                │
│  5.5 Mount decrypted STATE as /system/state                    │
│      └─> Machine config now accessible                        │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 6: Decrypt EPHEMERAL Partition (/var)                   │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  6.1 Read machine config from STATE                            │
│      └─> Config contains EPHEMERAL encryption settings        │
│                                                                │
│  6.2 Request TPM to unseal EPHEMERAL encryption key            │
│      ├─> Same PCR policy check as STATE                       │
│      └─> Key unsealed if PCRs match                           │
│                                                                │
│  6.3 Decrypt EPHEMERAL partition                               │
│      └─> cryptsetup luksOpen /dev/disk EPHEMERAL-key          │
│                                                                │
│  6.4 Mount decrypted EPHEMERAL as /var                         │
│      └─> Container runtime storage ready                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 7: Start Kubernetes                                     │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  7.1 Start kubelet                                             │
│  7.2 Start containerd                                          │
│  7.3 Join/form Kubernetes cluster                              │
│  7.4 Ready for workloads                                       │
│                                                                │
│  ✓ Boot complete with verified integrity                       │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### What Gets Measured in Each PCR?

| PCR | Contents | Who Measures | When |
|-----|----------|--------------|------|
| **PCR[0]** | UEFI firmware code | UEFI firmware | Power-on |
| **PCR[1]** | UEFI configuration | UEFI firmware | Boot |
| **PCR[2]** | Option ROM code | UEFI firmware | During init |
| **PCR[3]** | Option ROM config | UEFI firmware | During init |
| **PCR[4]** | Boot loader (systemd-boot) | UEFI firmware | Before execute |
| **PCR[5]** | Boot partition table | UEFI firmware | During boot |
| **PCR[7]** | SecureBoot state + keys | UEFI firmware | Boot |
| **PCR[8]** | Kernel command line | systemd-stub | Before kernel |
| **PCR[9]** | Kernel initrd | systemd-stub | Before kernel |
| **PCR[11]** | Kernel + Talos phases | systemd-stub + Talos | Throughout boot |
| **PCR[12]** | Kernel events | Kernel | Runtime |
| **PCR[14]** | MOK (Machine Owner Keys) | shim | If using shim |

**Key insight:** PCR values are **cumulative** and **extend-only**:
```
PCR[N]_new = SHA256(PCR[N]_old || new_measurement)
```

This means:
- You can't "undo" a measurement
- Order matters (same measurements in different order = different final PCR)
- Any change to boot components = different PCR values

---

## LUKS2 Encryption Implementation

### LUKS2 Structure

```
┌─────────────────────────────────────────────────────────────┐
│  Physical Disk: /dev/sda                                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Partition 1: EFI System Partition (ESP)                   │
│  ├─> /boot/efi                                             │
│  ├─> Unencrypted (bootloader must read it)                 │
│  └─> Contains: systemd-boot, Talos UKI                     │
│                                                             │
│  Partition 2: STATE (Encrypted with LUKS2)                  │
│  ├─> Physical: /dev/sda2                                   │
│  ├─> Virtual: /dev/mapper/luks2-STATE                      │
│  ├─> Mount: /system/state                                  │
│  └─> Contains: Machine config, certs, keys                 │
│                                                             │
│  Partition 3: EPHEMERAL (Encrypted with LUKS2)              │
│  ├─> Physical: /dev/sda3                                   │
│  ├─> Virtual: /dev/mapper/luks2-EPHEMERAL                  │
│  ├─> Mount: /var                                           │
│  └─> Contains: Container images, logs, /tmp                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### LUKS2 Header Anatomy

```
┌─────────────────────────────────────────────────────────────┐
│  LUKS2 Header (16 MB at start of partition)                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  JSON Metadata:                                             │
│  {                                                          │
│    "version": 2,                                            │
│    "label": "STATE",                                        │
│    "subsystem": "talos",                                    │
│    "keyslots": {                                            │
│      "0": {                                                 │
│        "type": "luks2",                                     │
│        "key_size": 64,                                      │
│        "af": {                                              │
│          "type": "luks1",                                   │
│          "stripes": 4000,                                   │
│          "hash": "sha256"                                   │
│        },                                                   │
│        "area": {                                            │
│          "encryption": "aes-xts-plain64",                   │
│          "key_size": 64                                     │
│        },                                                   │
│        "kdf": {                                             │
│          "type": "argon2id",                                │
│          "salt": "...",                                     │
│          "time": 4,                                         │
│          "memory": 1048576,    # 1GB                        │
│          "cpus": 4                                          │
│        }                                                    │
│      },                                                     │
│      "1": {                                                 │
│        "type": "luks2",                                     │
│        # Optional: recovery passphrase keyslot              │
│      }                                                      │
│    },                                                       │
│    "segments": {                                            │
│      "0": {                                                 │
│        "type": "crypt",                                     │
│        "offset": "16777216",    # After header              │
│        "size": "dynamic",                                   │
│        "iv_tweak": 0,                                       │
│        "encryption": "aes-xts-plain64",                     │
│        "sector_size": 4096                                  │
│      }                                                      │
│    },                                                       │
│    "digests": {                                             │
│      "0": {                                                 │
│        "type": "pbkdf2",                                    │
│        "keyslots": ["0", "1"],                              │
│        "hash": "sha256",                                    │
│        "iterations": 1000000,                               │
│        "salt": "..."                                        │
│      }                                                      │
│    },                                                       │
│    "tokens": {                                              │
│      "0": {                                                 │
│        "type": "systemd-tpm2",                              │
│        "keyslots": ["0"],                                   │
│        "tpm2-blob": "...",      # TPM-sealed key            │
│        "tpm2-pcrs": [0,1,2,4,7,11],                         │
│        "tpm2-bank": "sha256",                               │
│        "tpm2-primary-alg": "ecc"                            │
│      }                                                      │
│    }                                                        │
│  }                                                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Encryption Process

**Initial Setup (First Boot):**

```
1. Talos generates random master key
   └─> 512-bit (64 bytes) AES-XTS key
       (256-bit for data encryption + 256-bit for XTS tweak)

2. Master key encrypted with Argon2id KDF
   ├─> Input: Master key
   ├─> Salt: Random 256-bit value
   ├─> Parameters:
   │   • Memory: 1GB (prevents brute-force with GPUs)
   │   • Iterations: 4
   │   • Parallelism: 4 threads
   └─> Output: Encrypted master key for LUKS header

3. Master key sealed to TPM
   ├─> TPM_Seal(master_key, PCR_policy)
   ├─> PCR_policy = "Unseal if PCR[0,1,2,4,7,11] = expected_values"
   └─> Sealed blob stored in LUKS header as token

4. Partition encrypted with AES-XTS
   ├─> Cipher: aes-xts-plain64
   ├─> Key size: 512-bit
   ├─> Sector size: 4096 bytes
   └─> Each sector encrypted independently (XTS mode)
```

**Daily Boot (Automatic Unlock):**

```
1. cryptsetup reads LUKS header
   └─> Finds TPM token with sealed key

2. cryptsetup requests TPM unseal
   ├─> Provides: sealed blob, PCR policy
   ├─> TPM checks: Current PCR[0,1,2,4,7,11] vs policy
   └─> If match: Returns master key
       If mismatch: Refuses (boot fails or prompts for password)

3. cryptsetup decrypts partition
   ├─> Uses master key from TPM
   └─> Creates /dev/mapper/luks2-STATE

4. Talos mounts decrypted device
   └─> Machine config now accessible
```

### ITL.Talos.HardenedOS Configuration

**Your security-hardening.yaml:**

```yaml
machine:
  systemDiskEncryption:
    # STATE partition (machine configuration)
    state:
      provider: luks2
      keys:
        # Primary key: TPM-sealed (automatic unlock)
        - slot: 0
          tpm: {}
        
        # Optional: Recovery passphrase (manual unlock)
        # Uncomment for disaster recovery capability
        # - slot: 1
        #   static:
        #     passphrase: "ask-during-install"
      
      options:
        # Encryption cipher: AES-256 in XTS mode
        - cipher=aes-xts-plain64
        
        # Key size: 512-bit (256-bit data + 256-bit tweak)
        - key-size=512
        
        # Key derivation: Argon2id (memory-hard, GPU-resistant)
        - pbkdf=argon2id
        
        # PBKDF parameters (resist brute-force)
        - pbkdf-memory=1048576      # 1GB RAM for KDF
        - pbkdf-parallel=4           # 4 threads
        - pbkdf-iterations=4         # Time cost
        
        # Sector size: 4096 bytes (modern SSD-friendly)
        - sector-size=4096
    
    # EPHEMERAL partition (/var - container storage)
    ephemeral:
      provider: luks2
      keys:
        # Primary key: TPM-sealed
        - slot: 0
          tpm: {}
        
        # Optional: Recovery passphrase
        # - slot: 1
        #   static:
        #     passphrase: "ask-during-install"
      
      options:
        # Same strong encryption as STATE
        - cipher=aes-xts-plain64
        - key-size=512
        - pbkdf=argon2id
        - pbkdf-memory=1048576
        - pbkdf-parallel=4
        - pbkdf-iterations=4
        - sector-size=4096
```

**Why these parameters?**

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| **cipher** | aes-xts-plain64 | Industry standard, hardware-accelerated (AES-NI), XTS prevents certain attacks |
| **key-size** | 512 | 256-bit effective security (AES-256), plus 256-bit XTS tweak |
| **pbkdf** | argon2id | Memory-hard KDF, resistant to GPU/ASIC brute-force |
| **pbkdf-memory** | 1GB | Forces attacker to use 1GB RAM per guess (expensive) |
| **pbkdf-iterations** | 4 | Balance between security and boot time |
| **sector-size** | 4096 | Matches modern SSD/NVMe physical sector size |

---

## PCR (Platform Configuration Registers)

### How PCR Extending Works

```
Initial state (after TPM reset):
PCR[11] = 0x0000000000000000000000000000000000000000000000000000000000000000

Measurement 1: Kernel loaded
PCR[11] = SHA256(PCR[11] || kernel_hash)
        = SHA256(0x00...00 || 0xABCD...1234)
        = 0x7F3E...29A1

Measurement 2: Initramfs loaded
PCR[11] = SHA256(PCR[11] || initramfs_hash)
        = SHA256(0x7F3E...29A1 || 0x5678...CDEF)
        = 0xB2D4...8E7C

Measurement 3: Talos boot phase 1
PCR[11] = SHA256(PCR[11] || "talos.boot.phase1")
        = SHA256(0xB2D4...8E7C || 0x...)
        = 0x91A3...5F2E

...and so on. Final PCR[11] value is unique to:
- Exact kernel version
- Exact initramfs content
- Exact boot sequence
- In exact order
```

### PCR Policy Example

When sealing a key to TPM:

```
Policy: "Unseal ONLY if:"
  AND PCR[0] == 0x3A7B... (this specific firmware)
  AND PCR[1] == 0x8F2C... (this specific BIOS config)
  AND PCR[2] == 0xD1E4... (these specific option ROMs)
  AND PCR[4] == 0x5C91... (this specific bootloader)
  AND PCR[7] == 0x2B6D... (SecureBoot enabled with these keys)
  AND PCR[11] == 0x91A3... (this specific kernel + boot sequence)
```

**Result:**
- Key unseals: ✓ On this exact hardware + firmware + software
- Key refuses: ✗ If ANY component changes
  - Firmware update → PCR[0] changes
  - BIOS setting change → PCR[1] changes
  - Kernel update → PCR[11] changes
  - Bootkit installed → PCR[4] or PCR[11] changes

### PCR Policy Signing (Advanced)

Instead of fixed PCR values, use **signed policies**:

```
┌─────────────────────────────────────────────────────────┐
│  Fixed PCR Policy (Basic)                               │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Problem: Kernel update changes PCR[11]                 │
│           → TPM refuses to unseal                       │
│           → Must manually re-seal key after every update│
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Signed PCR Policy (Advanced)                           │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Solution: Policy signed by trusted key                 │
│                                                         │
│  1. Generate PCR signing key (during install)           │
│     └─> Private key stored securely                    │
│                                                         │
│  2. For each Talos version:                             │
│     ├─> Measure expected PCR[11] value                 │
│     ├─> Sign policy with private key                   │
│     └─> Embed signature in UKI                         │
│                                                         │
│  3. TPM unsealing:                                      │
│     ├─> Check: Current PCR[11] matches expected?       │
│     ├─> Check: Expected value signed by trusted key?   │
│     └─> If both: Unseal key                            │
│                                                         │
│  Result: Kernel updates work automatically              │
│          (as long as signed by your key)                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

This is what Talos uses with SecureBoot + TPM!

---

## Key Management & Sealing

### Master Key Generation

```bash
# What happens on first boot:

# 1. Generate random master key
dd if=/dev/urandom bs=64 count=1 of=/tmp/master.key

# 2. Seal to TPM
tpm2_createpolicy --pcr-list=sha256:0,1,2,4,7,11 \
                  --policy /tmp/pcr.policy

tpm2_create -C primary.ctx \
            -g sha256 \
            -G keyedhash \
            -r /tmp/sealed.priv \
            -u /tmp/sealed.pub \
            -L /tmp/pcr.policy \
            -i /tmp/master.key

# 3. Store sealed blob in LUKS header
cryptsetup token add --token-type systemd-tpm2 \
                      --tpm2-device=auto \
                      --tpm2-pcrs=0,1,2,4,7,11 \
                      /dev/sda2

# 4. Shred original key (never stored on disk unencrypted)
shred -vfz /tmp/master.key
```

### Key Unsealing

```bash
# During boot:

# 1. Read sealed blob from LUKS header
TOKEN=$(cryptsetup luksDump /dev/sda2 | grep -A10 "systemd-tpm2")

# 2. Request TPM to unseal
tpm2_unseal -c sealed.ctx \
            -p pcr:sha256:0,1,2,4,7,11 \
            -o /tmp/master.key

# If TPM unseals successfully:
# 3. Use key to unlock LUKS
cryptsetup luksOpen /dev/sda2 STATE --key-file /tmp/master.key

# 4. Shred key from RAM
shred -vfz /tmp/master.key

# If TPM refuses (PCRs don't match):
# → Boot fails or prompts for recovery passphrase
```

### Recovery Passphrase (Optional)

**Adding a recovery passphrase:**

```yaml
# In your config
machine:
  systemDiskEncryption:
    state:
      keys:
        - slot: 0
          tpm: {}
        - slot: 1
          static:
            passphrase: "YourVeryStrongPassphrase123!@#"
```

**What this enables:**

```
Scenario 1: Normal boot (TPM works)
├─> TPM unseals key from slot 0
└─> Automatic unlock ✓

Scenario 2: TPM fails (hardware replacement, firmware update)
├─> TPM refuses to unseal slot 0
├─> System prompts: "Enter recovery passphrase"
├─> User enters passphrase for slot 1
└─> Manual unlock ✓

Scenario 3: Disk moved to different machine
├─> TPM on new machine doesn't have sealed key
├─> System prompts for passphrase
└─> Can unlock with slot 1 ✓
```

**Best practice:** Generate strong passphrases:

```bash
# Use diceware for high-entropy passphrase
# Example: "correct horse battery staple momentum"
# 5 words = ~64 bits entropy

# Store passphrase in password manager or HSM
# NOT in machine config (defeats purpose)
```

---

## Security Guarantees

### What TPM + LUKS2 Protects Against

✅ **Disk theft**
- Attacker steals physical disk
- Cannot decrypt without TPM on original hardware
- Recovery passphrase needed (if configured)

✅ **Cold boot attack**
- Attacker reboots machine to extract keys from RAM
- Keys sealed in TPM, not in RAM during boot
- Minimal exposure window

✅ **Bootkit / rootkit**
- Malware tries to infect bootloader or kernel
- Changes PCR measurements
- TPM refuses to unseal → boot fails
- Integrity verified before every boot

✅ **Firmware tampering**
- Attacker modifies UEFI firmware
- PCR[0] changes
- TPM refuses to unseal → boot fails

✅ **Evil maid attack** (limited)
- Attacker has physical access while machine off
- Can't modify firmware (PCR[0] would change)
- Can't modify kernel (PCR[11] would change)
- Could potentially replace entire TPM chip (advanced)

✅ **Online attacks while running**
- If attacker compromises running system
- Encrypted partitions already unlocked
- TPM doesn't protect runtime (use other controls)
- But: prevents offline analysis of disk

### What TPM + LUKS2 Does NOT Protect Against

❌ **DMA attacks**
- Attacker uses PCIe device to read RAM
- Encryption keys in RAM after unlock
- Mitigation: IOMMU (VT-d), disable Thunderbolt

❌ **Running system compromise**
- If root on running system → game over
- Keys already in RAM
- Mitigation: Runtime protections (SELinux, seccomp)

❌ **Supply chain attacks**
- TPM chip compromised at manufacture
- Firmware backdoors
- Mitigation: Trusted supply chain, attestation

❌ **Physical access attacks** (advanced)
- Chip decapping
- Glitching attacks
- Laser fault injection
- Mitigation: Physical security, tamper detection

❌ **Side-channel attacks**
- Timing attacks
- Power analysis
- EM emanation
- Mitigation: Constant-time crypto, shielding

### Security Model Summary

```
┌──────────────────────────────────────────────────────┐
│  Threat Model Coverage                               │
├──────────────────────────────────────────────────────┤
│                                                      │
│  Data at Rest (Disk theft)           ████████ High  │
│  Boot Integrity (Rootkits)            ████████ High  │
│  Firmware Tampering                   ████████ High  │
│  Physical Access (Basic)              ██████░░ Med   │
│  Physical Access (Advanced)           ███░░░░░ Low   │
│  Runtime Compromise                   ░░░░░░░░ None  │
│  Network Attacks                      ░░░░░░░░ N/A   │
│                                                      │
└──────────────────────────────────────────────────────┘
```

---

## Attack Vectors & Mitigations

### Attack Vector 1: Disk Cloning Attack

**Scenario:**
Attacker clones your encrypted disk, boots it on their own hardware with TPM 2.0

**Attack steps:**
1. Clone /dev/sda to /dev/sdb
2. Boot attacker's machine with cloned disk
3. Attacker's TPM tries to unseal key

**Why it fails:**
- PCR values on attacker's TPM are different:
  - PCR[0] = different firmware
  - PCR[1] = different BIOS settings
  - PCR[2] = different option ROMs
  - PCR[7] = different SecureBoot keys
- TPM refuses to unseal
- Boot fails without recovery passphrase

**Mitigation strength:** ✅ **Strong**

---

### Attack Vector 2: STATE Partition Replacement

**Scenario:**
Attacker replaces STATE partition with their own (containing malicious config)

**From GitHub issue #8972:**
> "I believe this would enable an attacker to overwrite the STATE with their 
> talos STATE partition (created by the attacker using the same installer image)"

**Attack steps:**
1. Attacker creates malicious Talos system
2. Extracts their STATE partition
3. Replaces victim's STATE partition with malicious one
4. Boots victim's machine

**Why it might work (theoretical):**
- PCR[0-7,11] measure boot components (firmware, kernel)
- NOT machine-specific data from STATE
- Attacker using same installer → same PCR values
- TPM might unseal EPHEMERAL key

**Why it fails in practice:**
- EPHEMERAL encryption key is in machine config
- Machine config is in STATE
- Replacing STATE changes encryption key for EPHEMERAL
- EPHEMERAL data becomes inaccessible (from issue):
  > "Overwriting the STATE partition would destroy the static passphrase 
  > and render EPHEMERAL inaccessible"

**Mitigation:**
- Use different keys for STATE and EPHEMERAL
- Add machine-specific measurement to PCR
- Talos working on this improvement

**Current strength:** ⚠️ **Medium** (being improved)

---

### Attack Vector 3: TPM Chip Replacement

**Scenario:**
Attacker physically replaces TPM chip

**Attack steps:**
1. Desolder original TPM chip
2. Solder in attacker's TPM with known keys
3. Boot machine

**Why it fails:**
- Sealed keys are in original TPM
- New TPM doesn't have sealed keys
- Cannot generate correct sealed blobs (no access to original SRK)
- Boot fails without recovery passphrase

**However:**
- If attacker has recovery passphrase → attack succeeds
- If no recovery passphrase → disk is bricked

**Mitigation strength:** ✅ **Strong** (if no recovery passphrase)

---

### Attack Vector 4: Firmware Downgrade

**Scenario:**
Attacker downgrades firmware to vulnerable version

**Attack steps:**
1. Flash older UEFI firmware with known vulnerability
2. Exploit vulnerability to extract keys
3. Decrypt disk

**Why it fails:**
- Firmware downgrade changes PCR[0]
- TPM refuses to unseal
- Boot fails

**Mitigation strength:** ✅ **Strong**

---

### Attack Vector 5: DMA Attack (Thunderbolt/PCIe)

**Scenario:**
Attacker plugs malicious Thunderbolt device while machine is running

**Attack steps:**
1. Machine already booted (keys in RAM)
2. Plug Thunderbolt device
3. Device uses DMA to read RAM
4. Extract encryption keys from memory

**Why it works:**
- Keys are in RAM after unlock
- DMA can read all RAM (unless IOMMU)
- TPM doesn't protect runtime

**Mitigation:**
```yaml
# Disable Thunderbolt in BIOS
# OR enable IOMMU (VT-d on Intel, AMD-Vi on AMD)

# Kernel parameters (in UKI):
intel_iommu=on
```

**Mitigation strength:** ✅ **Strong** (with IOMMU)

---

### Attack Vector 6: Cold Boot Attack

**Scenario:**
Attacker reboots machine while running to extract keys from RAM

**Attack steps:**
1. Machine is running (keys in RAM)
2. Attacker forces hard reboot
3. Quickly boots custom OS
4. Scans RAM for encryption keys (RAM retains data briefly)

**Why it's difficult:**
- Talos zeros memory on shutdown
- Keys only in RAM during unlock (seconds)
- Modern RAM loses data quickly without power
- Requires liquid nitrogen to preserve RAM

**Mitigation:**
```yaml
# Talos already does:
# - Zero keys after use
# - Minimal time keys are in RAM
# - Clear memory on shutdown

# Additional: Disable sleep/hibernate
machine:
  sysctls:
    kernel.poweroff_cmd: /sbin/poweroff
```

**Mitigation strength:** ✅ **Strong** (already implemented)

---

## ITL.Talos.HardenedOS Implementation

### Your Current Security Configuration

**File: `config/patches/security-hardening.yaml`**

```yaml
machine:
  # Kernel hardening (prevent exploits)
  sysctls:
    # Hide kernel pointers (prevent info leak)
    kernel.kptr_restrict: "2"
    
    # Maximum ASLR (randomize memory addresses)
    kernel.randomize_va_space: "2"
    
    # Disable unprivileged BPF (prevent container escape)
    kernel.unprivileged_bpf_disabled: "1"
    
    # Restrict ptrace (prevent process debugging)
    kernel.yama.ptrace_scope: "2"
    
    # Network hardening
    net.ipv4.conf.all.rp_filter: "1"              # Prevent IP spoofing
    net.ipv4.conf.all.log_martians: "1"           # Log invalid packets
    net.ipv4.tcp_syncookies: "1"                  # SYN flood protection
    net.ipv4.conf.all.accept_redirects: "0"       # No ICMP redirects
    net.ipv6.conf.all.accept_redirects: "0"
  
  # Disk encryption (TPM-based)
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}  # Automatic unlock via TPM attestation
      options:
        - cipher=aes-xts-plain64   # AES-256 encryption
        - key-size=512             # 512-bit key (256+256 XTS)
        - pbkdf=argon2id           # Memory-hard KDF
        - pbkdf-memory=1048576     # 1GB RAM for KDF
        - pbkdf-parallel=4
        - pbkdf-iterations=4
    
    ephemeral:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
      options:
        - cipher=aes-xts-plain64
        - key-size=512
        - pbkdf=argon2id
        - pbkdf-memory=1048576
        - pbkdf-parallel=4
        - pbkdf-iterations=4
```

### Recommended Enhancements

**Add recovery passphrase:**

```yaml
systemDiskEncryption:
  state:
    keys:
      - slot: 0
        tpm: {}
      - slot: 1
        static:
          passphrase: ""  # Leave empty; will prompt during install
```

**Enable audit logging:**

```yaml
machine:
  features:
    auditLog:
      enabled: true
      destinations:
        - endpoint: tcp://siem.itlusions.local:514
          format: json_lines
```

**Add kernel module verification:**

```yaml
machine:
  kernel:
    modules:
      # Only allow signed modules
      - name: kernel.modules_disabled
        parameters:
          - "1"
```

---

## Operational Procedures

### Verifying TPM Attestation

**Check TPM is active:**

```bash
# View TPM information
talosctl --nodes <ip> get tpm -o yaml

# Expected output:
# spec:
#   version: 2.0
#   manufacturer: INTC  # Intel
#   owned: true
```

**Check PCR values:**

```bash
# Read current PCR values
talosctl --nodes <ip> dmesg | grep -i tpm
talosctl --nodes <ip> dmesg | grep -i pcr

# Or directly from TPM (requires debug mode)
tpm2_pcrread sha256:0,1,2,4,7,11
```

**Check disk encryption:**

```bash
# View encryption status
talosctl --nodes <ip> get volumestatus STATE -o yaml

# Expected output:
# spec:
#   encrypted: true
#   encryptionProvider: luks2
#   phase: ready

# Check which keyslot is active
talosctl --nodes <ip> get systemdiskencryption -o yaml
```

**Test unsealing:**

```bash
# Reboot and watch boot process
talosctl --nodes <ip> reboot

# Monitor for successful unlock
talosctl --nodes <ip> logs -f | grep -E 'luks|tpm|unseal'

# Successful boot should show:
# [talos] unlocking STATE partition
# [talos] STATE partition unlocked
# [talos] unlocking EPHEMERAL partition  
# [talos] EPHEMERAL partition unlocked
```

### Adding Recovery Passphrase (Post-Install)

```bash
# This requires physical access or console

# 1. Boot into maintenance mode
talosctl --nodes <ip> upgrade \
  --image ghcr.io/siderolabs/installer:v1.9.0 \
  --preserve \
  --reboot

# 2. During boot, interrupt to maintenance shell

# 3. Add passphrase to existing LUKS
cryptsetup luksAddKey /dev/sda2
# Enter existing key (from TPM) when prompted
# Enter new recovery passphrase twice

# 4. Verify
cryptsetup luksDump /dev/sda2 | grep "Key Slot"
# Should show:
# Key Slot 0: ENABLED (tpm2)
# Key Slot 1: ENABLED (passphrase)

# 5. Reboot
reboot
```

### Firmware Update Procedure

**Problem:** Firmware update changes PCR[0], TPM won't unseal

**Solution: Planned firmware update**

```bash
# BEFORE firmware update:

# 1. Add recovery passphrase (if not already done)
cryptsetup luksAddKey /dev/sda2

# 2. Update firmware in BIOS

# 3. After firmware update:
#    System will prompt for passphrase (TPM PCRs changed)
#    Enter recovery passphrase

# 4. Re-seal to new PCR values
#    (Talos does this automatically on first successful boot)

# 5. Remove recovery passphrase (optional)
cryptsetup luksRemoveKey /dev/sda2
# Enter passphrase to remove
```

**Solution: Emergency firmware recovery**

```bash
# If you forgot to add recovery passphrase:

# 1. Boot from Talos ISO
# 2. Reset node (data loss!)
talosctl reset --nodes <ip> --graceful=false

# 3. Re-install with new firmware
talosctl apply-config --nodes <ip> --file config.yaml

# 4. Rejoin cluster
```

### Hardware Replacement

**Scenario: Replacing failed disk**

```bash
# 1. Drain node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# 2. Power off
talosctl --nodes <ip> shutdown

# 3. Replace disk

# 4. Boot from network (PXE/iPXE)
#    Uses your ITL netboot infrastructure!

# 5. Install ITL.Talos.HardenedOS
#    Automatic from netboot menu

# 6. Node rejoins cluster
#    New TPM sealing automatically configured
```

**Scenario: Replacing failed motherboard (with TPM)**

```bash
# Data on encrypted disk is LOST (TPM sealed keys gone)

# 1. If you have recovery passphrase:
#    Boot with new motherboard
#    Enter recovery passphrase
#    System re-seals to new TPM
#    Data recovered! ✓

# 2. If no recovery passphrase:
#    Data is permanently inaccessible
#    Must reset and reinstall
#    (This is a feature, not a bug - prevents theft)
```

---

## Troubleshooting

### Boot Hangs at "Waiting for TPM"

**Symptoms:**
- System hangs during boot
- Message: "Waiting for TPM to unseal encryption key"
- Never progresses

**Causes:**
1. TPM disabled in BIOS
2. PCR values changed (firmware update, BIOS change)
3. TPM hardware failure
4. Wrong TPM policy in LUKS header

**Diagnosis:**

```bash
# Boot from ISO and check:

# Is TPM enabled?
ls /dev/tpm*
# Should show: /dev/tpm0 /dev/tpmrm0

# Is TPM accessible?
tpm2_getcap properties-fixed
# Should show TPM properties

# Check LUKS header
cryptsetup luksDump /dev/sda2 | grep -A10 "systemd-tpm2"
# Should show TPM token

# Try manual unseal
tpm2_unseal -c /path/to/sealed.ctx
# If fails: PCRs don't match or TPM issue
```

**Solutions:**

```bash
# Solution 1: Enable TPM in BIOS
# - Enter BIOS setup
# - Security → TPM Configuration
# - Enable TPM 2.0

# Solution 2: Use recovery passphrase
# - Boot will eventually timeout
# - System prompts for passphrase
# - Enter recovery passphrase

# Solution 3: Re-seal to new PCRs
# - Boot with recovery passphrase
# - Talos automatically re-seals to current PCRs
# - Next boot will use TPM again

# Solution 4: Reset node (data loss)
talosctl reset --nodes <ip> --graceful=false
# Reinstall from netboot
```

### TPM Unseals but Boot Still Fails

**Symptoms:**
- TPM successfully unseals key
- Boot continues but fails later
- Error: "Failed to mount STATE partition"

**Causes:**
1. Disk corruption
2. Filesystem errors
3. Wrong encryption key (corrupted LUKS header)

**Diagnosis:**

```bash
# Check if partition decrypts
cryptsetup luksOpen /dev/sda2 STATE --test-passphrase
# Success: Key is correct
# Failure: LUKS header or key corrupted

# Check decrypted device
cryptsetup luksOpen /dev/sda2 STATE
ls -la /dev/mapper/luks2-STATE
# Should exist

# Check filesystem
fsck /dev/mapper/luks2-STATE
# Shows filesystem errors
```

**Solutions:**

```bash
# Fix filesystem
fsck -y /dev/mapper/luks2-STATE

# If unfixable: Restore from backup
# (You do have backups, right?)
```

### "Invalid PCR Policy" Error

**Symptoms:**
- Error: "TPM policy verification failed"
- TPM refuses to unseal

**Causes:**
- Kernel updated (PCR[11] changed)
- Firmware updated (PCR[0] changed)
- SecureBoot keys changed (PCR[7] changed)

**Diagnosis:**

```bash
# Check which PCRs changed
tpm2_pcrread sha256:0,1,2,4,7,11

# Compare with expected (from LUKS header)
cryptsetup luksDump /dev/sda2 | grep "tpm2-pcrs"
```

**Solution:**

```bash
# Use recovery passphrase to boot
# System will automatically re-seal to new PCRs
```

---

## Compliance & Certification

### Standards Met by TPM + LUKS2

✅ **NIST SP 800-171** - Protecting Controlled Unclassified Information
- 3.13.11: Cryptographic protection of data at rest
- 3.13.16: Hardware-based encryption

✅ **SOC 2 Type II**
- CC6.1: Logical and physical access controls
- CC6.6: Encryption of data at rest
- CC6.7: Encryption key management

✅ **ISO 27001/27002**
- A.10.1.1: Cryptographic controls
- A.10.1.2: Key management
- A.18.1.5: Cryptographic regulations

✅ **PCI DSS**
- Requirement 3.4: Encryption of cardholder data at rest
- Requirement 3.5: Key management procedures

✅ **FIPS 140-2**
- Level 2: Physical tamper-evidence (TPM chip)
- Approved algorithms: AES-256, SHA-256, RSA-2048

✅ **HIPAA**
- 164.312(a)(2)(iv): Encryption and decryption
- 164.312(e)(2)(ii): Encryption of ePHI at rest

### Certification Evidence

**For auditors:**

```bash
# Demonstrate encryption is active
talosctl --nodes <node> get volumestatus -o json | \
  jq '.spec.encrypted'
# Output: true

# Show encryption algorithm
cryptsetup luksDump /dev/sda2 | grep -E 'Cipher|Key'
# Output:
# Cipher: aes-xts-plain64
# Key:    512 bits

# Prove TPM is used
cryptsetup luksDump /dev/sda2 | grep "systemd-tpm2"
# Output: token 0: systemd-tpm2

# Show TPM is FIPS-compliant
tpm2_getcap properties-fixed | grep FIPS
# Output: FIPS_140_2: 1 (if TPM is FIPS-certified)

# Demonstrate boot integrity
talosctl --nodes <node> dmesg | grep -i "measured boot"
# Shows TPM measurements during boot
```

### Audit Report Template

```markdown
# Disk Encryption Audit - ITL.Talos.HardenedOS

## Configuration

- **Encryption Standard:** LUKS2
- **Cipher:** AES-XTS-Plain64
- **Key Size:** 512-bit (AES-256 effective)
- **Key Derivation:** Argon2id
- **Hardware Security:** TPM 2.0

## Partitions Encrypted

- STATE: /dev/sda2 (Machine configuration)
- EPHEMERAL: /dev/sda3 (Container storage)

## Key Management

- **Primary:** TPM-sealed (automatic unlock)
- **Backup:** Recovery passphrase (optional)
- **Storage:** Keys never stored on disk unencrypted
- **Rotation:** Manual (requires re-encryption)

## Compliance

✅ NIST SP 800-171  
✅ SOC 2 Type II  
✅ ISO 27001  
✅ PCI DSS 3.x  
✅ FIPS 140-2 Level 2  
✅ HIPAA  

## Evidence

See attached:
- cryptsetup luksDump output
- TPM capabilities
- Boot logs showing TPM attestation
```

---

## Conclusion

ITL.Talos.HardenedOS implements **defense-in-depth** security:

1. **Hardware Root of Trust** - TPM 2.0 chip
2. **Measured Boot** - Every component verified
3. **Sealed Encryption** - Keys locked to hardware+firmware+software
4. **Automatic Unlock** - No passwords if attestation passes
5. **Fallback Recovery** - Manual password for emergencies
6. **Compliance-Ready** - Meets NIST, SOC2, ISO, PCI, FIPS, HIPAA

**This is enterprise-grade security that "just works"** - no manual cryptsetup, no complicated key management, no passwords to remember (unless you want them).

**Your competitive advantage:**
- Customers get security by default
- Auditors love the TPM attestation
- IT teams don't need crypto expertise
- Just boot the server - TPM handles the rest

---

## References

### Official Documentation

- **Talos Linux:** https://www.talos.dev/
- **TPM 2.0 Spec:** https://trustedcomputinggroup.org/resource/tpm-library-specification/
- **LUKS2:** https://gitlab.com/cryptsetup/cryptsetup
- **systemd-cryptenroll:** https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html

### Security Standards

- **NIST SP 800-171:** https://csrc.nist.gov/publications/detail/sp/800-171/rev-2/final
- **FIPS 140-2:** https://csrc.nist.gov/publications/detail/fips/140/2/final
- **ISO 27001:** https://www.iso.org/isoiec-27001-information-security.html

### ITlusions Resources

- **Repository:** https://github.com/ITlusions/ITL.Talos.HardenedOS
- **Support:** support@itlusions.com
- **Documentation:** https://docs.itlusions.com

---

**Document Maintained By:** ITlusions Security Team  
**Last Security Review:** May 2026  
**Next Review:** November 2026

*ITlusions - Enterprise Kubernetes Infrastructure*  
*Hardened • Supported • Production-Ready*
