# ============================================================
#  ITL Talos HardenedOS — Bare Metal Cluster Setup
#  Scenario: 3 physical machines
#    Machine 1: Control Plane  (itl-cp1)
#    Machine 2: Worker 1       (itl-w1)
#    Machine 3: Worker 2       (itl-w2)
#
#  Prerequisites on each machine:
#    - Boot from USB with ITL Talos ISO (see Step 0 below)
#    - Each machine needs a wired NIC + DHCP or static IP
#    - This script runs from your management laptop
#
#  Usage:
#    .\setup-cluster-baremetal.ps1
#    .\setup-cluster-baremetal.ps1 -CpIp 192.168.1.100 -W1Ip 192.168.1.101 -W2Ip 192.168.1.102
# ============================================================
[CmdletBinding()]
param(
    [string]$ClusterName  = "itl",
    [string]$IsoPath      = "$PSScriptRoot\iso-download\itl-talos-v1.9.0.iso",

    # Leave empty to enter interactively
    [string]$CpIp = "",
    [string]$W1Ip = "",
    [string]$W2Ip = "",

    # Static IP config — set $UseStaticIps=$true if not using DHCP
    [bool]$UseStaticIps   = $false,

    # OIDC — requires a live Keycloak instance at auth.itlusions.com
    # Set to $true only if Keycloak is already deployed and reachable
    [bool]$EnableOidc     = $false,
    [string]$Gateway      = "192.168.1.1",
    [string]$Nameserver   = "1.1.1.1",
    [string]$SubnetPrefix = "24"          # CIDR prefix length
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg"    -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!]  $msg"    -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERROR] $msg" -ForegroundColor Red; exit 1 }

# ── Step 0: Flash USB ─────────────────────────────────────────────────
Write-Host @"

  ╔══════════════════════════════════════════════════════════╗
  ║   ITL Talos HardenedOS — Bare Metal Cluster Setup       ║
  ║   1 Control Plane  +  2 Workers                         ║
  ╚══════════════════════════════════════════════════════════╝

  STEP 0 — Flash USB drives (do this BEFORE running further)
  ──────────────────────────────────────────────────────────
  ISO: $IsoPath

  Windows (Rufus):
    rufus.exe  →  select ISO  →  GPT/UEFI  →  Write

  Linux/macOS:
    sudo dd if=itl-talos-v1.9.0.iso of=/dev/sdX bs=4M status=progress

  Then:
    1. Plug USB into each of the 3 machines
    2. Boot from USB (F12 / DEL / F2 for BIOS boot menu)
    3. Talos boots into maintenance mode (no install yet)
    4. Each machine gets an IP via DHCP — note them down
    5. Come back here and press Enter

"@ -ForegroundColor White

Read-Host "Press Enter once all 3 machines are booted into Talos maintenance mode"

# ── Step 1: Collect IPs ───────────────────────────────────────────────
Write-Step "Collecting node IP addresses"

function Prompt-IP($label, $hint) {
    do {
        $ip = Read-Host "  $label IP address (e.g. $hint)"
        $valid = $ip -match '^\d{1,3}(\.\d{1,3}){3}$'
        if (-not $valid) { Write-Host "  Invalid IP, try again." -ForegroundColor Red }
    } while (-not $valid)
    return $ip
}

if (-not $CpIp) { $CpIp = Prompt-IP "Control Plane (itl-cp1)" "192.168.1.100" }
if (-not $W1Ip) { $W1Ip = Prompt-IP "Worker 1     (itl-w1)"  "192.168.1.101" }
if (-not $W2Ip) { $W2Ip = Prompt-IP "Worker 2     (itl-w2)"  "192.168.1.102" }

Write-OK "CP:  $CpIp  (itl-cp1)"
Write-OK "W1:  $W1Ip  (itl-w1)"
Write-OK "W2:  $W2Ip  (itl-w2)"

# ── Step 2: Validate connectivity ────────────────────────────────────
Write-Step "Checking connectivity to all nodes"

foreach ($pair in @(
    @("itl-cp1", $CpIp),
    @("itl-w1",  $W1Ip),
    @("itl-w2",  $W2Ip)
)) {
    $name = $pair[0]; $ip = $pair[1]
    $result = Test-NetConnection -ComputerName $ip -Port 50000 -WarningAction SilentlyContinue
    if ($result.TcpTestSucceeded) {
        Write-OK "$name ($ip) — port 50000 reachable (Talos maintenance API)"
    } else {
        Write-Warn "$name ($ip) — port 50000 not reachable yet. Node may still be booting."
        Write-Host "    Continuing anyway — apply-config will retry automatically." -ForegroundColor Gray
    }
}

# ── Step 3: Build static-IP patches if needed ────────────────────────
$patchFiles = @(
    "$PSScriptRoot\config\patches\security-hardening.yaml",
    "$PSScriptRoot\config\patches\network-hardening.yaml",
    "$PSScriptRoot\config\patches\branding-patch.yaml"
)

if ($EnableOidc) {
    $patchFiles += "$PSScriptRoot\config\patches\oidc-patch.yaml"
    Write-Warn "OIDC enabled — ensure Keycloak is reachable at https://auth.itlusions.com before bootstrap"
} else {
    Write-Host "  [i] OIDC disabled (use -EnableOidc `$true to include Keycloak integration)" -ForegroundColor DarkGray
}

$configDir = "$PSScriptRoot\config\generated\$ClusterName"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

if ($UseStaticIps) {
    Write-Step "Generating static IP patches"

    $staticPatchCp = @"
machine:
  network:
    hostname: itl-cp1
    interfaces:
      - interface: eth0
        addresses:
          - $CpIp/$SubnetPrefix
        routes:
          - network: 0.0.0.0/0
            gateway: $Gateway
        dhcp: false
"@
    $cpPatchPath = "$configDir\static-ip-cp.yaml"
    Set-Content -Path $cpPatchPath -Value $staticPatchCp
    Write-OK "CP static patch: $cpPatchPath"

    $workerIps = @($W1Ip, $W2Ip)
    $workerNames = @("itl-w1", "itl-w2")
    for ($i = 0; $i -lt 2; $i++) {
        $wPatch = @"
machine:
  network:
    hostname: $($workerNames[$i])
    interfaces:
      - interface: eth0
        addresses:
          - $($workerIps[$i])/$SubnetPrefix
        routes:
          - network: 0.0.0.0/0
            gateway: $Gateway
        dhcp: false
"@
        $wPatchPath = "$configDir\static-ip-$($workerNames[$i]).yaml"
        Set-Content -Path $wPatchPath -Value $wPatch
        Write-OK "$($workerNames[$i]) static patch: $wPatchPath"
    }

    $patchFiles += $cpPatchPath   # CP patch — we'll handle workers separately below
}

# ── Step 4: Generate Talos configs ───────────────────────────────────
Write-Step "Generating Talos cluster configs"

Write-Host "  Applying patches:" -ForegroundColor Gray
$patchFiles | ForEach-Object { Write-Host "    + $(Split-Path $_ -Leaf)" -ForegroundColor DarkGray }

$patchArgs = $patchFiles | ForEach-Object { "--config-patch", "@$_" }

& talosctl gen config $ClusterName "https://${CpIp}:6443" `
    --output $configDir `
    @patchArgs `
    --force

if ($LASTEXITCODE -ne 0) { Write-Err "talosctl gen config failed" }
Write-OK "Configs written to: $configDir"

# ── Step 5: Apply configs ────────────────────────────────────────────
Write-Step "Applying configs to bare metal nodes"

Write-Host "  → itl-cp1  $CpIp" -ForegroundColor Gray
& talosctl apply-config --nodes $CpIp --file "$configDir\controlplane.yaml" --insecure
if ($LASTEXITCODE -ne 0) { Write-Err "Failed to apply config to $CpIp" }
Write-OK "controlplane.yaml applied to $CpIp"

Write-Host "  → itl-w1   $W1Ip" -ForegroundColor Gray
& talosctl apply-config --nodes $W1Ip --file "$configDir\worker.yaml" --insecure
if ($LASTEXITCODE -ne 0) { Write-Err "Failed to apply config to $W1Ip" }
Write-OK "worker.yaml applied to $W1Ip"

Write-Host "  → itl-w2   $W2Ip" -ForegroundColor Gray
& talosctl apply-config --nodes $W2Ip --file "$configDir\worker.yaml" --insecure
if ($LASTEXITCODE -ne 0) { Write-Err "Failed to apply config to $W2Ip" }
Write-OK "worker.yaml applied to $W2Ip"

Write-Host @"

  Talos is now installing to disk on each machine and will reboot.
  Watch for the machines to finish rebooting (~2-3 minutes).
  The USB drives can be removed after the first reboot.

"@ -ForegroundColor Yellow

Read-Host "Press Enter once all machines have rebooted and are back online"

# ── Step 6: Bootstrap Kubernetes ─────────────────────────────────────
Write-Step "Bootstrapping Kubernetes on the control plane"

$env:TALOSCONFIG = "$configDir\talosconfig"
Write-OK "TALOSCONFIG set to: $env:TALOSCONFIG"

Write-Host "  Running: talosctl bootstrap --nodes $CpIp --endpoints $CpIp" -ForegroundColor Gray
& talosctl bootstrap --nodes $CpIp --endpoints $CpIp
if ($LASTEXITCODE -ne 0) { Write-Err "Bootstrap failed. Check logs with: talosctl logs --nodes $CpIp" }
Write-OK "Bootstrap initiated"

# ── Step 7: Get kubeconfig ────────────────────────────────────────────
Write-Step "Waiting for Kubernetes API server (~3 minutes)..."

$kubeconfigPath = "$PSScriptRoot\kubeconfig-$ClusterName"
$attempts = 0
$maxAttempts = 20

do {
    Start-Sleep -Seconds 15
    $attempts++
    Write-Host "  Attempt $attempts/$maxAttempts — fetching kubeconfig..." -ForegroundColor Gray
    & talosctl kubeconfig $kubeconfigPath --nodes $CpIp --endpoints $CpIp --force 2>$null
    $success = $LASTEXITCODE -eq 0
} while (-not $success -and $attempts -lt $maxAttempts)

if (-not $success) {
    Write-Warn "Could not get kubeconfig automatically. Run manually when ready:"
    Write-Host "  talosctl kubeconfig .\kubeconfig-$ClusterName --nodes $CpIp --endpoints $CpIp" -ForegroundColor Yellow
} else {
    Write-OK "kubeconfig saved to: $kubeconfigPath"
}

# ── Step 8: Verify cluster ────────────────────────────────────────────
Write-Step "Verifying cluster"

$env:KUBECONFIG = $kubeconfigPath

Write-Host ""
& kubectl get nodes -o wide
Write-Host ""

Write-Host @"

  ╔══════════════════════════════════════════════════════════╗
  ║   Cluster setup complete!                               ║
  ╠══════════════════════════════════════════════════════════╣
  ║  Control Plane : itl-cp1  $CpIp                         ║
  ║  Worker 1      : itl-w1   $W1Ip                         ║
  ║  Worker 2      : itl-w2   $W2Ip                         ║
  ╠══════════════════════════════════════════════════════════╣
  ║  kubeconfig    : $kubeconfigPath
  ║  talosconfig   : $env:TALOSCONFIG
  ╠══════════════════════════════════════════════════════════╣
  ║  Useful commands:                                       ║
  ║    kubectl get pods -A                                  ║
  ║    talosctl health --nodes $CpIp --endpoints $CpIp       ║
  ║    talosctl dashboard --nodes $CpIp                      ║
  ╚══════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green
