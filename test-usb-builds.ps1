# test-usb-builds.ps1
#
# Build and test both USB ISOs without QEMU installed locally.
# QEMU runs inside a Docker container (TCG software emulation — no KVM needed).
#
# Tests:
#   1. iPXE chainloader USB  (netboot/Dockerfile.ipxe-usb)
#      - Builds the ISO via Docker
#      - Validates it is a real ISO9660 image
#      - Boots it in QEMU-in-Docker and captures serial output
#      - Verifies "iPXE" and "DHCP" appear in boot output
#
#   2. Alpine USB agent      (provisioner/usb-agent/Dockerfile.usb-builder)
#      - Builds the ISO via Docker  (slow — full Alpine mkimage build)
#      - Validates it is a real ISO9660 image
#      - Boots it in QEMU-in-Docker and verifies Alpine kernel boot line
#
# Usage:
#   .\test-usb-builds.ps1                        # test both
#   .\test-usb-builds.ps1 -Target ipxe           # only iPXE USB
#   .\test-usb-builds.ps1 -Target alpine         # only Alpine USB
#   .\test-usb-builds.ps1 -SkipBuild             # skip docker build (use existing dist/)
#   .\test-usb-builds.ps1 -NetbootServer http://192.168.1.10
#
# Requirements: Docker Desktop (default / Windows engine context)
# ─────────────────────────────────────────────────────────────────────────────

param(
    [ValidateSet("both", "ipxe", "alpine")]
    [string]$Target        = "both",
    [string]$NetbootServer = "http://192.168.1.10",
    [string]$IpxeRef       = "v1.21.1",
    [string]$RegUrl        = "https://reg.itlusions.com",
    [string]$Role          = "worker-app",
    [switch]$SkipBuild,
    # How many seconds to let QEMU run before we kill it and inspect output
    [int]$QemuTimeout      = 45
)

$ErrorActionPreference = "Stop"
$RepoRoot  = $PSScriptRoot
$DistDir   = Join-Path $RepoRoot "dist"
$PassCount = 0
$FailCount = 0
$Results   = @()

# Use the Windows Docker engine (works without Docker Desktop Linux VM running)
$env:DOCKER_CONTEXT = "default"

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function Write-Header($msg) {
    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host "  $msg"
    Write-Host ("=" * 60)
}

function Write-Pass($msg) {
    Write-Host "  [PASS] $msg" -ForegroundColor Green
    $script:PassCount++
    $script:Results += [PSCustomObject]@{ Result = "PASS"; Test = $msg }
}

function Write-Fail($msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:FailCount++
    $script:Results += [PSCustomObject]@{ Result = "FAIL"; Test = $msg }
}

function Write-Info($msg) {
    Write-Host "  [info] $msg" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Build an ISO via Docker
# ─────────────────────────────────────────────────────────────────────────────

function Build-IpxeIso {
    param([string]$OutputIso)

    Write-Header "Build — iPXE chainloader USB"
    Write-Info "Dockerfile : netboot/Dockerfile.ipxe-usb"
    Write-Info "Output     : $OutputIso"
    Write-Info "Netboot    : $NetbootServer"

    $tmpOut = Join-Path $DistDir "__ipxe_out"
    New-Item -ItemType Directory -Force -Path $tmpOut | Out-Null

    $env:DOCKER_BUILDKIT = "1"
    docker build `
        --file "$RepoRoot\netboot\Dockerfile.ipxe-usb" `
        --build-arg "NETBOOT_SERVER=$NetbootServer" `
        --build-arg "IPXE_REF=$IpxeRef" `
        --output "type=local,dest=$tmpOut" `
        "$RepoRoot\netboot"

    if ($LASTEXITCODE -ne 0) { Write-Fail "iPXE Docker build failed"; return $false }

    $built = Join-Path $tmpOut "ipxe-usb.iso"
    if (-not (Test-Path $built)) { Write-Fail "iPXE ISO not produced by build"; return $false }

    Move-Item -Force $built $OutputIso
    Remove-Item -Recurse -Force $tmpOut
    Write-Pass "iPXE ISO built: $([math]::Round((Get-Item $OutputIso).Length/1KB)) KB"
    return $true
}

function Build-AlpineIso {
    param([string]$OutputIso)

    Write-Header "Build — Alpine USB agent"
    Write-Info "Dockerfile : provisioner/usb-agent/Dockerfile.usb-builder"
    Write-Info "Output     : $OutputIso"
    Write-Info "RegUrl     : $RegUrl  Role: $Role"
    Write-Info "NOTE: this takes 5-15 minutes (full Alpine mkimage build)"

    $tmpOut = Join-Path $DistDir "__alpine_out"
    New-Item -ItemType Directory -Force -Path $tmpOut | Out-Null

    $env:DOCKER_BUILDKIT = "1"
    docker build `
        --file "$RepoRoot\provisioner\usb-agent\Dockerfile.usb-builder" `
        --build-arg "ITL_REG_URL=$RegUrl" `
        --build-arg "ITL_ROLE=$Role" `
        --output "type=local,dest=$tmpOut" `
        "$RepoRoot\provisioner\usb-agent"

    if ($LASTEXITCODE -ne 0) { Write-Fail "Alpine Docker build failed"; return $false }

    $built = Join-Path $tmpOut "usb-agent.iso"
    if (-not (Test-Path $built)) { Write-Fail "Alpine ISO not produced by build"; return $false }

    Move-Item -Force $built $OutputIso
    Remove-Item -Recurse -Force $tmpOut
    $sizeMB = [math]::Round((Get-Item $OutputIso).Length/1MB, 1)
    Write-Pass "Alpine ISO built: $sizeMB MB"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Structural validation (no boot needed)
# Uses a tiny Docker container with the 'file' command to inspect the ISO
# ─────────────────────────────────────────────────────────────────────────────

function Test-IsoStructure {
    param([string]$IsoPath, [string]$Label)

    Write-Header "Validate ISO structure — $Label"

    if (-not (Test-Path $IsoPath)) {
        Write-Fail "$Label ISO not found at $IsoPath"
        return $false
    }

    $sizeMB = [math]::Round((Get-Item $IsoPath).Length/1MB,1)
    Write-Info "File: $IsoPath ($sizeMB MB)"

    # Run 'file' inside Alpine to check ISO magic
    $fileOutput = docker run --rm `
        -v "${IsoPath}:/test.iso:ro" `
        alpine:3.21 `
        sh -c "apk add --no-cache file 2>/dev/null; file /test.iso" 2>&1

    Write-Info "file: $fileOutput"

    if ($fileOutput -match "ISO 9660") {
        Write-Pass "$Label is a valid ISO 9660 image"
    } else {
        Write-Fail "$Label file type unexpected: $fileOutput"
        return $false
    }

    # Check minimum size (iPXE should be >100 KB, Alpine >50 MB)
    $minBytes = if ($Label -eq "iPXE") { 100KB } else { 50MB }
    if ((Get-Item $IsoPath).Length -gt $minBytes) {
        Write-Pass "$Label ISO size looks correct ($sizeMB MB)"
    } else {
        Write-Fail "$Label ISO suspiciously small ($sizeMB MB) — build may have failed silently"
        return $false
    }

    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Boot test — QEMU in Docker, capture serial output
# QEMU runs with TCG (software emulation), -nographic, serial to stdout.
# We kill it after $QemuTimeout seconds and check what it printed.
# ─────────────────────────────────────────────────────────────────────────────

function Test-QemuBoot {
    param(
        [string]$IsoPath,
        [string]$Label,
        [string[]]$ExpectStrings     # strings that must appear in serial output
    )

    Write-Header "QEMU boot test — $Label"
    Write-Info "ISO       : $IsoPath"
    Write-Info "Timeout   : $QemuTimeout s  (TCG software emulation — slow but no KVM needed)"
    Write-Info "Expecting : $($ExpectStrings -join ', ')"

    # Mount the ISO read-only into the QEMU container
    # -accel tcg        : pure software emulation (no KVM / nested-virt needed)
    # -nographic        : no display window — all output on serial
    # -serial stdio     : serial port → container stdout (captured by docker run)
    # -no-reboot        : don't loop on reboot
    # -net nic,model=virtio -net user : simple user-mode networking (for DHCP test)
    # timeout: GNU coreutils timeout kills qemu after N seconds

    $logFile = Join-Path $DistDir "qemu-boot-${Label}.log"

    Write-Info "Running QEMU inside Docker... (output: $logFile)"

    docker run --rm `
        --name "itl-qemu-test-$Label" `
        -v "${IsoPath}:/boot.iso:ro" `
        alpine:3.21 sh -c @"
apk add --no-cache qemu-system-x86_64 ovmf seabios 2>/dev/null
timeout $QemuTimeout qemu-system-x86_64 \
    -cdrom /boot.iso \
    -m 512M \
    -accel tcg \
    -nographic \
    -serial mon:stdio \
    -boot d \
    -no-reboot \
    -net nic,model=virtio \
    -net user \
    2>&1 || true
"@ 2>&1 | Tee-Object -FilePath $logFile

    $bootLog = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
    if (-not $bootLog) {
        Write-Fail "$Label QEMU produced no output"
        return $false
    }

    $allPassed = $true
    foreach ($expect in $ExpectStrings) {
        if ($bootLog -match [regex]::Escape($expect)) {
            Write-Pass "$Label boot output contains '$expect'"
        } else {
            Write-Fail "$Label boot output missing '$expect'"
            $allPassed = $false
        }
    }

    Write-Info "Full log saved: $logFile"
    return $allPassed
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

$today      = Get-Date -Format "yyyyMMdd"
$ipxeIso    = Join-Path $DistDir "itl-ipxe-usb-$today.iso"
$alpineIso  = Join-Path $DistDir "itl-talos-usb-agent-$today.iso"

# ── iPXE USB ──────────────────────────────────────────────────────────────────
if ($Target -in "both", "ipxe") {
    $ipxeBuilt = $true
    if (-not $SkipBuild) {
        $ipxeBuilt = Build-IpxeIso -OutputIso $ipxeIso
    } else {
        $existing = Get-ChildItem $DistDir -Filter "itl-ipxe-usb-*.iso" |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($existing) {
            $ipxeIso = $existing.FullName
            Write-Info "Using existing iPXE ISO: $ipxeIso"
        } else {
            Write-Fail "No existing iPXE ISO found in dist/ — run without -SkipBuild"
            $ipxeBuilt = $false
        }
    }

    if ($ipxeBuilt) {
        Test-IsoStructure -IsoPath $ipxeIso -Label "iPXE" | Out-Null
        Test-QemuBoot -IsoPath $ipxeIso -Label "ipxe" -ExpectStrings @(
            "iPXE",
            "DHCP"
        ) | Out-Null
    }
}

# ── Alpine USB agent ──────────────────────────────────────────────────────────
if ($Target -in "both", "alpine") {
    if (-not $SkipBuild) {
        $ok = Build-AlpineIso -OutputIso $alpineIso
        if (-not $ok) { Write-Host "Skipping Alpine tests (build failed)" }
        else {
            Test-IsoStructure -IsoPath $alpineIso -Label "Alpine" | Out-Null

            # Alpine ISO should show kernel boot line and login/agent start
            Test-QemuBoot -IsoPath $alpineIso -Label "alpine" -ExpectStrings @(
                "Alpine Linux",
                "ITL"
            ) | Out-Null
        }
    } else {
        $existing = Get-ChildItem $DistDir -Filter "itl-talos-usb-agent-*.iso" |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($existing) {
            $alpineIso = $existing.FullName
            Write-Info "Using existing Alpine ISO: $alpineIso"
            Test-IsoStructure -IsoPath $alpineIso -Label "Alpine" | Out-Null
            Test-QemuBoot -IsoPath $alpineIso -Label "alpine" -ExpectStrings @(
                "Alpine Linux",
                "ITL"
            ) | Out-Null
        } else {
            Write-Fail "No existing Alpine ISO found in dist/ — run without -SkipBuild"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Results"
$Results | Format-Table -AutoSize

Write-Host ""
Write-Host "  PASSED : $PassCount" -ForegroundColor Green
Write-Host "  FAILED : $FailCount" -ForegroundColor $(if ($FailCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($FailCount -gt 0) { exit 1 }
