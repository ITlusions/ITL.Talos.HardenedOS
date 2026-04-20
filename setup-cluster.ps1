# ============================================================
#  ITL Talos HardenedOS — Cluster Setup Script
#  1 Control Plane + 2 Workers on Hyper-V
#
#  Usage: Run as Administrator in PowerShell
#  .\setup-cluster.ps1 [-ClusterName itl] [-IsoPath .\iso-download\itl-talos-v1.9.0.iso]
# ============================================================
[CmdletBinding()]
param(
    [string]$ClusterName   = "itl",
    [string]$IsoPath       = "$PSScriptRoot\iso-download\itl-talos-v1.9.0.iso",
    [string]$VhdBase       = "C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks",
    [string]$Switch        = "Default Switch",
    [int]$CpuCount         = 2,
    [long]$RamBytes        = 2GB,
    [long]$DiskBytes       = 40GB
)

$ErrorActionPreference = "Stop"

# ── Node definitions ─────────────────────────────────────────────────
$nodes = @(
    @{ Name = "$ClusterName-cp1";  Role = "controlplane" },
    @{ Name = "$ClusterName-w1";   Role = "worker" },
    @{ Name = "$ClusterName-w2";   Role = "worker" }
)

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

# ── Validate prerequisites ───────────────────────────────────────────
Write-Step "Checking prerequisites"

if (-not (Test-Path $IsoPath)) {
    Write-Err "ISO not found: $IsoPath"
    Write-Warn "Download it from: https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest"
    exit 1
}
Write-OK "ISO found: $IsoPath"

$talosctl = Get-Command talosctl -ErrorAction SilentlyContinue
if (-not $talosctl) {
    Write-Err "talosctl not found in PATH."
    Write-Host "  Install from: https://github.com/siderolabs/talos/releases" -ForegroundColor White
    exit 1
}
Write-OK "talosctl: $($talosctl.Source)"

# ── Create Hyper-V VMs ───────────────────────────────────────────────
Write-Step "Creating Hyper-V VMs"

foreach ($node in $nodes) {
    $name    = $node.Name
    $vhdPath = Join-Path $VhdBase "$name.vhdx"

    # Remove existing VM with the same name
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Warn "VM '$name' already exists — removing"
        $vm = Get-VM -Name $name
        if ($vm.State -eq "Running") { Stop-VM -Name $name -Force -TurnOff }
        Remove-VM -Name $name -Force
        if (Test-Path $vhdPath) { Remove-Item $vhdPath -Force }
    }

    # Create
    New-VM -Name $name `
        -MemoryStartupBytes $RamBytes `
        -Generation 2 `
        -NewVHDPath $vhdPath `
        -NewVHDSizeBytes $DiskBytes `
        -SwitchName $Switch | Out-Null

    Set-VMProcessor -VMName $name -Count $CpuCount
    Set-VMProcessor -VMName $name -ExposeVirtualizationExtensions $true
    Set-VMMemory    -VMName $name -DynamicMemoryEnabled $false

    # Mount ISO and set boot order
    Add-VMDvdDrive -VMName $name -Path $IsoPath
    $dvd = Get-VMDvdDrive -VMName $name
    Set-VMFirmware -VMName $name -FirstBootDevice $dvd -EnableSecureBoot Off

    Write-OK "$name  ($($node.Role))  vhd=$vhdPath"
}

# ── Start VMs ────────────────────────────────────────────────────────
Write-Step "Starting VMs"
foreach ($node in $nodes) {
    Start-VM -Name $node.Name
    Write-OK "$($node.Name) started"
}

Write-Host @"

  VMs are booting from the ISO.
  Hyper-V assigns IPs via DHCP on the 'Default Switch' (NAT).
  Wait ~30 seconds, then find the IPs:

"@ -ForegroundColor White

# ── Discover IPs via Hyper-V NIC ─────────────────────────────────────
Write-Step "Waiting 40 seconds for VMs to get a DHCP lease..."
Start-Sleep -Seconds 40

$ipMap = @{}
foreach ($node in $nodes) {
    $name = $node.Name
    $ips  = (Get-VMNetworkAdapter -VMName $name).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.' }
    if ($ips) {
        $ipMap[$name] = $ips[0]
        Write-OK "$name  →  $($ips[0])"
    } else {
        Write-Warn "$name — no IP yet. Get it manually after the VMs finish booting:"
        Write-Host "    (Get-VMNetworkAdapter -VMName '$name').IPAddresses" -ForegroundColor Gray
        $ipMap[$name] = "UNKNOWN"
    }
}

# ── Generate Talos configs ────────────────────────────────────────────
Write-Step "Generating Talos cluster configs"

$configDir = Join-Path $PSScriptRoot "config\generated\$ClusterName"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

$cpIp = $ipMap["$ClusterName-cp1"]

if ($cpIp -eq "UNKNOWN") {
    Write-Warn "CP IP unknown. Update `$cpIp in the generated config or re-run after boot."
    $cpIp = "REPLACE_WITH_CP_IP"
}

talosctl gen config $ClusterName "https://${cpIp}:6443" `
    --output $configDir `
    --config-patch "@$PSScriptRoot\config\patches\security-hardening.yaml" `
    --config-patch "@$PSScriptRoot\config\patches\network-hardening.yaml" `
    --force

Write-OK "Configs written to: $configDir"
Write-Host "  controlplane.yaml  worker.yaml  talosconfig" -ForegroundColor Gray

# ── Apply configs ─────────────────────────────────────────────────────
Write-Step "Applying configs to nodes"

$cpIp = $ipMap["$ClusterName-cp1"]
$w1Ip = $ipMap["$ClusterName-w1"]
$w2Ip = $ipMap["$ClusterName-w2"]

if (@($cpIp,$w1Ip,$w2Ip) -contains "UNKNOWN") {
    Write-Warn "One or more IPs are unknown. Applying configs manually after boot:"
    Write-Host @"

  # Control plane:
  talosctl apply-config --nodes <CP_IP>  --file $configDir\controlplane.yaml --insecure

  # Workers:
  talosctl apply-config --nodes <W1_IP>  --file $configDir\worker.yaml --insecure
  talosctl apply-config --nodes <W2_IP>  --file $configDir\worker.yaml --insecure

"@ -ForegroundColor Yellow
} else {
    Write-Host "  Applying to $ClusterName-cp1 ($cpIp)..." -ForegroundColor Gray
    talosctl apply-config --nodes $cpIp --file "$configDir\controlplane.yaml" --insecure

    Write-Host "  Applying to $ClusterName-w1  ($w1Ip)..." -ForegroundColor Gray
    talosctl apply-config --nodes $w1Ip --file "$configDir\worker.yaml" --insecure

    Write-Host "  Applying to $ClusterName-w2  ($w2Ip)..." -ForegroundColor Gray
    talosctl apply-config --nodes $w2Ip --file "$configDir\worker.yaml" --insecure

    Write-OK "Configs applied — nodes are rebooting into Talos"
}

# ── Bootstrap Kubernetes ──────────────────────────────────────────────
Write-Host @"

  ────────────────────────────────────────────────
   NEXT STEP: Bootstrap Kubernetes (run ONCE after
   the control plane node has finished booting)
  ────────────────────────────────────────────────

  # 1. Set talosconfig
  `$env:TALOSCONFIG = "$configDir\talosconfig"

  # 2. Bootstrap (only once, on the control plane)
  talosctl bootstrap --nodes $cpIp --endpoints $cpIp

  # 3. Wait ~3 minutes, then get kubeconfig
  talosctl kubeconfig .\kubeconfig --nodes $cpIp --endpoints $cpIp

  # 4. Verify cluster
  `$env:KUBECONFIG = "`$PWD\kubeconfig"
  kubectl get nodes

  Expected output:
  NAME            STATUS   ROLES           AGE   VERSION
  $ClusterName-cp1    Ready    control-plane   3m    v1.29.0
  $ClusterName-w1     Ready    <none>          2m    v1.29.0
  $ClusterName-w2     Ready    <none>          2m    v1.29.0

"@ -ForegroundColor Cyan

# ── Open VM consoles ──────────────────────────────────────────────────
Write-Step "Opening VM consoles"
foreach ($node in $nodes) {
    Start-Process "vmconnect.exe" -ArgumentList "localhost", $node.Name
}

Write-Host "`nDone. Watch the consoles — Talos will install to disk and reboot automatically.`n" -ForegroundColor Green
