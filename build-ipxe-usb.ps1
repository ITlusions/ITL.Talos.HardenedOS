# build-ipxe-usb.ps1
# Windows wrapper for netboot/build-ipxe-usb.sh
#
# Builds a minimal bootable iPXE USB image that chainloads to your ITL netboot
# menu.  No Talos ISO, no Alpine, no agent — just iPXE + DHCP + chain.
#
# Usage:
#   .\build-ipxe-usb.ps1
#   .\build-ipxe-usb.ps1 -NetbootServer https://netboot.itlusions.local
#
# Requirements: Docker Desktop for Windows (Linux containers)
# Output: .\dist\itl-ipxe-usb-<date>.iso

param(
    [string]$NetbootServer = "http://192.168.1.10",
    [string]$IpxeRef       = "v1.21.1",
    [string]$OutputDir     = "$PSScriptRoot\dist"
)

$ErrorActionPreference = "Stop"

$today      = Get-Date -Format "yyyyMMdd"
$outputIso  = Join-Path $OutputDir "itl-ipxe-usb-$today.iso"
$dockerfile = "$PSScriptRoot\netboot\Dockerfile.ipxe-usb"
$context    = "$PSScriptRoot\netboot"
$tmpOut     = Join-Path $OutputDir "__ipxe_out"

Write-Host ""
Write-Host "========================================="
Write-Host " ITL — Build iPXE Chainload USB"
Write-Host "========================================="
Write-Host " Netboot server : $NetbootServer"
Write-Host " iPXE ref       : $IpxeRef"
Write-Host " Output         : $outputIso"
Write-Host ""

# ── Prereq check ──────────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "docker not found. Install Docker Desktop for Windows."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $tmpOut    | Out-Null

# ── Build using Docker BuildKit ──────────────────────────────────────────────
$env:DOCKER_BUILDKIT = "1"
docker build `
    --file $dockerfile `
    --build-arg "NETBOOT_SERVER=$NetbootServer" `
    --build-arg "IPXE_REF=$IpxeRef" `
    --output "type=local,dest=$tmpOut" `
    $context

if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker build failed (exit $LASTEXITCODE)"
}

# ── Extract ISO ───────────────────────────────────────────────────────────────
$builtIso = Join-Path $tmpOut "ipxe-usb.iso"
if (-not (Test-Path $builtIso)) {
    Write-Error "Expected output not found: $builtIso"
}

Move-Item -Force $builtIso $outputIso
Remove-Item -Recurse -Force $tmpOut

$sizeMB = [math]::Round((Get-Item $outputIso).Length / 1MB, 1)

Write-Host ""
Write-Host "========================================="
Write-Host " ISO ready : $outputIso"
Write-Host " Size      : $sizeMB MB"
Write-Host "========================================="
Write-Host ""
Write-Host "Write to USB with Rufus:"
Write-Host "  - Boot selection : select $outputIso"
Write-Host "  - Write mode     : DD Image"
Write-Host "  - Partition      : GPT"
Write-Host "  - Target system  : UEFI (non-CSM)"
Write-Host ""
Write-Host "Boot sequence:"
Write-Host "  USB -> iPXE -> DHCP -> $NetbootServer/menu.ipxe -> role selection"
