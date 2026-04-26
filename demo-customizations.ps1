#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Demo all ITL Talos HardenedOS customizations.

.DESCRIPTION
    Displays every customization layer applied to ITL Talos HardenedOS:
      1. Branding extension (console banner, MOTD)
      2. Security extension (sysctl hardening, audit rules, kernel module policy)
      3. TPM Registration extension (hardware attestation on first boot)
      4. Config patches (LUKS2, kubelet CIS hardening, OIDC, network)
      5. Flavor (controlplane-stack: helm overlays, manifests, patches)

    Pass -TalosIP to also pull live data from a running node.

.PARAMETER TalosIP
    Optional IP of a running Talos node. When supplied the script also queries
    the node for live verification of each customization layer.

.EXAMPLE
    # Offline demo (no node needed)
    .\demo-customizations.ps1

    # Live demo against a running node
    .\demo-customizations.ps1 -TalosIP 192.168.1.100
#>
param(
    [string]$TalosIP
)

$root = $PSScriptRoot

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
function Section([string]$title) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function SubSection([string]$title) {
    Write-Host ""
    Write-Host "  ── $title" -ForegroundColor Yellow
}

function ShowFile([string]$label, [string]$path, [int]$maxLines = 30) {
    if (Test-Path $path) {
        Write-Host "  [FILE] $label" -ForegroundColor DarkCyan
        Write-Host "         $path" -ForegroundColor DarkGray
        $lines = Get-Content $path | Select-Object -First $maxLines
        $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
        $total = (Get-Content $path).Count
        if ($total -gt $maxLines) {
            Write-Host "    ... ($($total - $maxLines) more lines)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [MISSING] $path" -ForegroundColor Red
    }
}

function LiveCheck([string]$label, [string]$cmd) {
    Write-Host ""
    Write-Host "  [LIVE] $label" -ForegroundColor Magenta
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [!] Command returned exit code $LASTEXITCODE" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [ERR] $_" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        ITL Talos HardenedOS — Customization Demo                    ║" -ForegroundColor Cyan
Write-Host "║        Talos v1.9.0  |  ITL Extensions v1.0.0                       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
if ($TalosIP) {
    Write-Host "  Live node: $TalosIP" -ForegroundColor Green
} else {
    Write-Host "  Mode: offline (pass -TalosIP [ip] for live checks)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. EXTENSION: itl-branding
# ─────────────────────────────────────────────────────────────────────────────
Section "1. Extension: itl-branding"
Write-Host "  Adds custom ITLusions console banner, MOTD (/etc/issue) and" -ForegroundColor Gray
Write-Host "  release metadata visible on every SSH/console login." -ForegroundColor Gray

SubSection "Extension manifest"
ShowFile "manifest.yaml" "$root\extensions\itl-branding\manifest.yaml"

SubSection "Branding files injected into rootfs"
Get-ChildItem "$root\extensions\itl-branding\rootfs" -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Replace("$root\extensions\itl-branding\rootfs", "")
    Write-Host "    $rel" -ForegroundColor White
}

SubSection "Config patch (branding-patch.yaml) — /etc/issue banner preview"
ShowFile "branding-patch.yaml" "$root\config\patches\branding-patch.yaml" 35

if ($TalosIP) {
    LiveCheck "Read /etc/issue from node" "talosctl -n $TalosIP read /etc/issue"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. EXTENSION: itl-security
# ─────────────────────────────────────────────────────────────────────────────
Section "2. Extension: itl-security"
Write-Host "  Injects kernel sysctl hardening, audit rules, and kernel-module" -ForegroundColor Gray
Write-Host "  deny-list directly into the Talos image rootfs." -ForegroundColor Gray

SubSection "Extension manifest"
ShowFile "manifest.yaml" "$root\extensions\itl-security\manifest.yaml"

SubSection "sysctl hardening (99-itl-hardening.conf)"
ShowFile "99-itl-hardening.conf" "$root\extensions\itl-security\rootfs\etc\sysctl.d\99-itl-hardening.conf"

SubSection "Audit rules"
Get-ChildItem "$root\extensions\itl-security\rootfs\etc\audit\rules.d" -File -ErrorAction SilentlyContinue | ForEach-Object {
    ShowFile $_.Name $_.FullName
}

SubSection "Kernel module policy (modprobe.d)"
Get-ChildItem "$root\extensions\itl-security\rootfs\etc\modprobe.d" -File -ErrorAction SilentlyContinue | ForEach-Object {
    ShowFile $_.Name $_.FullName
}

SubSection "Config patch (security-hardening.yaml)"
ShowFile "security-hardening.yaml" "$root\config\patches\security-hardening.yaml"

if ($TalosIP) {
    LiveCheck "Read kernel.kptr_restrict from node" "talosctl -n $TalosIP get runtimesecuritystate"
    LiveCheck "List loaded kernel modules" "talosctl -n $TalosIP get modules"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. EXTENSION: itl-tpm-register
# ─────────────────────────────────────────────────────────────────────────────
Section "3. Extension: itl-tpm-register"
Write-Host "  Adds tpm2-tools to the Talos rootfs and a one-shot attestation" -ForegroundColor Gray
Write-Host "  service.  On first boot after installation the EK certificate is" -ForegroundColor Gray
Write-Host "  sent to the ITL Registration Service for hardware-bound identity." -ForegroundColor Gray

SubSection "Extension manifest"
ShowFile "manifest.yaml" "$root\extensions\itl-tpm-register\manifest.yaml"

SubSection "Rootfs contents"
Get-ChildItem "$root\extensions\itl-tpm-register\rootfs" -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Replace("$root\extensions\itl-tpm-register\rootfs", "")
    Write-Host "    $rel" -ForegroundColor White
}

if ($TalosIP) {
    LiveCheck "TPM attestation service status" "talosctl -n $TalosIP service itl-tpm-register"
    LiveCheck "Read TPM EK certificate (base64)" "talosctl -n $TalosIP read /var/lib/itl/tpm-attestation.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIG PATCHES
# ─────────────────────────────────────────────────────────────────────────────
Section "4. Config Patches (applied via talosctl machineconfig)"

SubSection "4a. security-hardening.yaml — LUKS2 + TPM2 + CIS kubelet"
Write-Host "  Key settings:" -ForegroundColor Gray
Write-Host "    • LUKS2 encryption on STATE and EPHEMERAL partitions" -ForegroundColor White
Write-Host "    • TPM PCR sealing for auto-unlock (slot 1)" -ForegroundColor White
Write-Host "    • nodeID key as fallback (slot 0)" -ForegroundColor White
Write-Host "    • kubelet: read-only-port=0, protect-kernel-defaults=true" -ForegroundColor White
Write-Host "    • kubelet: RotateKubeletServerCertificate=true" -ForegroundColor White
Write-Host "    • Kernel modules: tpm, tpm_crb, tpm_tis, integrity, dm_crypt" -ForegroundColor White
ShowFile "security-hardening.yaml (full)" "$root\config\patches\security-hardening.yaml" 60

SubSection "4b. oidc-patch.yaml — Keycloak OIDC on kube-apiserver"
Write-Host "  Key settings:" -ForegroundColor Gray
Write-Host "    • Issuer:   https://auth.itlusions.com/realms/itl" -ForegroundColor White
Write-Host "    • Client:   talos-cluster" -ForegroundColor White
Write-Host "    • Username: preferred_username (prefix: oidc:)" -ForegroundColor White
Write-Host "    • Groups:   groups claim         (prefix: oidc:)" -ForegroundColor White
Write-Host "    • Audit log: /var/log/kubernetes/audit.log (30d / 10 backups)" -ForegroundColor White
Write-Host "    • Encryption at rest: encryption-config.yaml" -ForegroundColor White
ShowFile "oidc-patch.yaml (full)" "$root\config\patches\oidc-patch.yaml" 40

SubSection "4c. network-hardening.yaml — DNS / NTP / etcd / kube-proxy"
Write-Host "  Key settings:" -ForegroundColor Gray
Write-Host "    • Nameservers: 1.1.1.1, 8.8.8.8" -ForegroundColor White
Write-Host "    • NTP: time.cloudflare.com, pool.ntp.org" -ForegroundColor White
Write-Host "    • kube-proxy: iptables mode, metrics on 127.0.0.1 only" -ForegroundColor White
Write-Host "    • etcd: metrics on 127.0.0.1:2381, auto-compaction 8h" -ForegroundColor White
ShowFile "network-hardening.yaml (full)" "$root\config\patches\network-hardening.yaml" 40

SubSection "4d. branding-patch.yaml — /etc/issue + /etc/issue.net"
Write-Host "  Writes ITL ASCII banner to /etc/issue and /etc/issue.net" -ForegroundColor Gray

if ($TalosIP) {
    LiveCheck "Show active machineconfig patches" "talosctl -n $TalosIP get machineconfigs"
    LiveCheck "Verify disk encryption state" "talosctl -n $TalosIP get encryptionconfig"
    LiveCheck "OIDC flags on kube-apiserver" "talosctl -n $TalosIP get apiserverconfig"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. FLAVOR: controlplane-stack
# ─────────────────────────────────────────────────────────────────────────────
Section "5. Flavor: controlplane-stack"
Write-Host "  A curated set of Helm value overlays, Kubernetes manifests and" -ForegroundColor Gray
Write-Host "  additional Talos patches that turn the base hardened OS into a" -ForegroundColor Gray
Write-Host "  full ITL control-plane node." -ForegroundColor Gray

$flavorRoot = "$root\flavors\controlplane-stack"

SubSection "Helm value overlays"
Get-ChildItem "$flavorRoot" -Filter "*.yaml" -File | ForEach-Object {
    ShowFile $_.Name $_.FullName 20
}

SubSection "Kubernetes manifests"
Get-ChildItem "$flavorRoot\manifests" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Replace("$flavorRoot\manifests\", "")
    Write-Host "    $rel" -ForegroundColor White
}

SubSection "Flavor-specific Talos patches"
Get-ChildItem "$flavorRoot\patches" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    ShowFile $_.Name $_.FullName 20
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. BUILD ARTIFACTS
# ─────────────────────────────────────────────────────────────────────────────
Section "6. Build Artifacts"
Write-Host "  Artifacts produced by build-local.ps1 + build-iso.ps1" -ForegroundColor Gray

$isoPath = "$root\iso-output\itl-talos-v1.9.0.iso"
if (Test-Path $isoPath) {
    $sz = [math]::Round((Get-Item $isoPath).Length / 1MB, 2)
    Write-Host "  [OK] ISO:  $isoPath  ($sz MB)" -ForegroundColor Green
} else {
    Write-Host "  [--] ISO not built yet - run build-iso.ps1" -ForegroundColor DarkGray
}

$dockerImage = "itl-talos-hardened:installer-v1.9.0"
$dockerCheck = docker image inspect $dockerImage 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] Docker image: $dockerImage  (available locally)" -ForegroundColor Green
} else {
    Write-Host "  [--] Docker image not found - run build-local.ps1" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Section "Summary"
Write-Host ""
Write-Host "  Layer                       Description" -ForegroundColor White
    Write-Host "  -------------------------   ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Extension: itl-branding     Console banner, MOTD, release metadata" -ForegroundColor White
Write-Host "  Extension: itl-security     sysctl + audit rules + modprobe policy" -ForegroundColor White
Write-Host "  Extension: itl-tpm-register TPM EK attestation on first boot" -ForegroundColor White
Write-Host "  Patch: security-hardening   LUKS2/TPM2 encryption + CIS kubelet" -ForegroundColor White
Write-Host "  Patch: oidc-patch           Keycloak OIDC on kube-apiserver" -ForegroundColor White
Write-Host "  Patch: network-hardening    DNS/NTP/etcd/kube-proxy hardening" -ForegroundColor White
Write-Host "  Patch: branding-patch       /etc/issue ASCII banner" -ForegroundColor White
Write-Host "  Flavor: controlplane-stack  Helm overlays + manifests + patches" -ForegroundColor White
Write-Host ""
Write-Host "  Build scripts:" -ForegroundColor DarkGray
    Write-Host "    build-local.ps1  - builds Docker installer image + branding" -ForegroundColor Gray
    Write-Host "    build-iso.ps1    - extracts kernel/initramfs, generates UEFI ISO" -ForegroundColor Gray
Write-Host ""
