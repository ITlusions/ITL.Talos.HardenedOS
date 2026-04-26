# ─────────────────────────────────────────────────────────────────────────────
# ITL Talos HardenedOS — Imager-based ISO build (Windows / Docker Desktop)
#
# Uses the official Talos imager to bake ITL extensions directly into the ISO.
# Requires Docker Desktop with WSL2 backend.
#
# Usage:
#   .\build-iso.ps1
#   .\build-iso.ps1 -TalosVersion v1.9.0 -ExtraExtensions @("ghcr.io/myorg/myext:v1")
# ─────────────────────────────────────────────────────────────────────────────

param(
    [string]$OutputDir        = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\iso-output",
    [string]$TalosVersion     = "v1.9.0",
    [string]$ITLBrandingTag   = "latest",
    [string]$ITLSecurityTag   = "latest",
    # Check https://github.com/siderolabs/extensions for compatible tags per Talos version
    [string]$GvisorTag        = "v20231214.0-v1.9.0",
    [string]$IntelUcodeTag    = "20240312-v1.9.0",
    # Optional: additional OCI image refs to bake in on top of the core set
    # e.g.: @("ghcr.io/siderolabs/hello-world:v1.0.0", "ghcr.io/myorg/myext:latest")
    [string[]]$ExtraExtensions = @()
)

$ErrorActionPreference = "Stop"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  ITL Talos HardenedOS — Imager Build" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Talos Version : $TalosVersion" -ForegroundColor Yellow
Write-Host "  Output Dir    : $OutputDir" -ForegroundColor Yellow
Write-Host ""

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutDir = (Resolve-Path $OutputDir).Path

# ── Build extension argument list ─────────────────────────────────────────────
$ExtensionArgs = @(
    "--system-extension-image", "ghcr.io/itlusions/itl-talos-hardened-os-branding:$ITLBrandingTag",
    "--system-extension-image", "ghcr.io/itlusions/itl-talos-hardened-os-security:$ITLSecurityTag",
    "--system-extension-image", "ghcr.io/siderolabs/gvisor:$GvisorTag",
    "--system-extension-image", "ghcr.io/siderolabs/intel-ucode:$IntelUcodeTag"
)

foreach ($ext in $ExtraExtensions) {
    $ExtensionArgs += "--system-extension-image", $ext
}

Write-Host "[*] Extensions to be baked into ISO:" -ForegroundColor Yellow
$ExtensionArgs | Where-Object { $_ -notlike "--*" } | ForEach-Object {
    Write-Host "    - $_" -ForegroundColor White
}
Write-Host ""

# ── Check Docker ───────────────────────────────────────────────────────────────
Write-Host "[*] Checking Docker..." -ForegroundColor Yellow
try {
    $dockerVersion = docker version --format "{{.Server.Version}}" 2>&1
    Write-Host "  [OK] Docker $dockerVersion" -ForegroundColor Green
}
catch {
    Write-Host "  [ERROR] Docker not available. Install Docker Desktop with WSL2 backend." -ForegroundColor Red
    exit 1
}

# ── Run imager ────────────────────────────────────────────────────────────────
# On Windows with Docker Desktop (WSL2 backend), /dev/mapper/control is handled
# inside the WSL2 VM — no host mount required.
Write-Host ""
Write-Host "[*] Running Talos imager (ghcr.io/siderolabs/imager:$TalosVersion)..." -ForegroundColor Yellow
Write-Host "    This pulls extensions from GHCR and builds the ISO." -ForegroundColor DarkGray
Write-Host "    First run may take a few minutes." -ForegroundColor DarkGray
Write-Host ""

$ImagerArgs = @(
    "run", "--rm",
    "-v", "${OutDir}:/out",
    "ghcr.io/siderolabs/imager:$TalosVersion",
    "iso"
) + $ExtensionArgs + @(
    "--extra-kernel-arg", "console=ttyS0,115200",
    "--extra-kernel-arg", "console=tty0"
)

docker @ImagerArgs

# ── Rename output ─────────────────────────────────────────────────────────────
$IsoSrc = Join-Path $OutDir "metal-amd64.iso"
$IsoDst = Join-Path $OutDir "itl-talos-$TalosVersion.iso"

if (-not (Test-Path $IsoSrc)) {
    Write-Host "[ERROR] Imager did not produce output at $IsoSrc" -ForegroundColor Red
    Get-ChildItem $OutDir | Format-Table
    exit 1
}

Move-Item -Path $IsoSrc -Destination $IsoDst -Force

# ── Checksums ─────────────────────────────────────────────────────────────────
$hash = (Get-FileHash -Algorithm SHA256 $IsoDst).Hash.ToLower()
"$hash  itl-talos-$TalosVersion.iso" | Set-Content "$IsoDst.sha256" -Encoding UTF8
Write-Host "[OK] SHA256: $hash" -ForegroundColor Green

$isoSize = [math]::Round((Get-Item $IsoDst).Length / 1MB, 1)

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  ISO  : $IsoDst" -ForegroundColor Cyan
Write-Host "  Size : $isoSize MB" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Extensions baked in:" -ForegroundColor Yellow
Write-Host "    ghcr.io/itlusions/itl-talos-hardened-os-branding:$ITLBrandingTag" -ForegroundColor White
Write-Host "    ghcr.io/itlusions/itl-talos-hardened-os-security:$ITLSecurityTag" -ForegroundColor White
Write-Host "    ghcr.io/siderolabs/gvisor:$GvisorTag" -ForegroundColor White
Write-Host "    ghcr.io/siderolabs/intel-ucode:$IntelUcodeTag" -ForegroundColor White
foreach ($ext in $ExtraExtensions) {
    Write-Host "  + $ext" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  NOTE: machine.install.extensions is no longer required for the" -ForegroundColor DarkGray
Write-Host "        above extensions — they are already baked into this ISO." -ForegroundColor DarkGray
Write-Host "        Use it only for additional cluster-specific extensions." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Next: Flash to USB with Rufus (GPT/UEFI), boot node, run setup-cluster-baremetal.ps1" -ForegroundColor Yellow

    Get-Item "$OutputDir\*.iso" | ForEach-Object {
        "  - $($_.FullName) ($([math]::Round($_.Length/1MB, 2)) MB)"
    }
    
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Boot from ISO on target hardware" -ForegroundColor White
    Write-Host "  2. Run talosctl apply-config to deploy Kubernetes" -ForegroundColor White
    Write-Host "  3. Configure network, storage, and security policies" -ForegroundColor White
} else {
    Write-Host "Docker image built successfully: $ImageTag" -ForegroundColor Green
    Write-Host ""
    Write-Host "To generate a production ISO, install talosctl and run:" -ForegroundColor Yellow
    Write-Host "  talosctl iso --installer $ImageTag --output itl-talos-v1.9.0.iso" -ForegroundColor Cyan
}
