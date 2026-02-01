# Local build script for ITL Talos HardenedOS
# This script builds the custom Talos installer locally with branding and security hardening

param(
    [switch]$SkipBranding,
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BrandingDir = Join-Path $ProjectRoot "branding"
$BuildDir = Join-Path $ProjectRoot "build"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  ITL Talos HardenedOS - Local Build" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Build Branding Assets
if (-not $SkipBranding) {
    Write-Host "[*] Step 1: Building branding assets..." -ForegroundColor Yellow
    
    # Ensure directories exist
    New-Item -ItemType Directory -Path "$BrandingDir\logos" -Force | Out-Null
    New-Item -ItemType Directory -Path "$BrandingDir\output" -Force | Out-Null
    
    # Check if Docker is available
    $dockerAvailable = $false
    try {
        docker --version | Out-Null
        $dockerAvailable = $true
        Write-Host "  [OK] Docker is available" -ForegroundColor Green
    }
    catch {
        Write-Host "  [!] Docker not found - will use local tools if available" -ForegroundColor Yellow
    }
    
    if ($dockerAvailable) {
        # Use Docker container to generate banners (portable)
        Write-Host "  [>] Generating ASCII art banners (Docker)..." -ForegroundColor Cyan
        
        $bannerScript = "apt-get update > /dev/null 2>&1`napt-get install -y figlet toilet > /dev/null 2>&1`n`nfiglet -f standard 'ITL TALOS' > /output/title.txt`ntoilet -f future 'HARDENED OS' >> /output/title.txt`n`ncat > /output/console-banner.txt << 'EOF'`n================================================`n   ITL TALOS HARDENED OS FOR KUBERNETES`n================================================`n`nVersion: v1.9.0`nSecurity: MAXIMUM`nEncryption: LUKS2+TPM`nAuthentication: Keycloak`n`n================================================`nEOF`n`necho '[OK] Banners generated'"
        
        docker run --rm `
            -v "$BrandingDir\output:/output" `
            ubuntu:24.04 bash -c $bannerScript | Out-Host
    }
    else {
        Write-Host "  [!] Docker not available - creating minimal banner files" -ForegroundColor Yellow
        
        # Create simple text files without figlet/toilet
        @"
ITL TALOS
HARDENED OS
"@ | Set-Content "$BrandingDir\output\title.txt"
        
        @"
================================================
   ITL TALOS HARDENED OS FOR KUBERNETES
================================================

Version: v1.9.0
Security: MAXIMUM
Encryption: LUKS2+TPM
Authentication: Keycloak

================================================
"@ | Set-Content "$BrandingDir\output\console-banner.txt"
    }
    
    # Create placeholder boot logo
    Write-Host "  [>] Creating boot logo..." -ForegroundColor Cyan
    
    if ($dockerAvailable) {
        # Use ImageMagick in Docker
        $bootLogoScript = "apt-get update > /dev/null 2>&1`napt-get install -y imagemagick netpbm > /dev/null 2>&1`n`nconvert -size 224x224 xc:navy -pointsize 20 -fill white -gravity center -annotate +0+0 'ITL' /logos/boot-logo.png`n`nconvert /logos/boot-logo.png -resize 224x224 /output/boot-logo.png`n`nconvert /output/boot-logo.png /output/boot-logo.ppm`n`nppmquant 224 /output/boot-logo.ppm | pnmtoplainpnm > /output/logo_custom_clut224.ppm`n`necho '[OK] Boot logo created'"
        
        docker run --rm `
            -v "$BrandingDir\logos:/logos" `
            -v "$BrandingDir\output:/output" `
            ubuntu:24.04 bash -c $bootLogoScript | Out-Host
    }
    else {
        Write-Host "  [!] Cannot create boot logo without Docker/ImageMagick" -ForegroundColor Yellow
        Write-Host "      Skipping boot logo generation" -ForegroundColor Yellow
    }
    
    Write-Host "  [OK] Branding assets complete" -ForegroundColor Green
}

# Step 2: Build Docker Images
Write-Host ""
Write-Host "[*] Step 2: Building Docker images..." -ForegroundColor Yellow

if (-not (Test-Path variable:dockerAvailable)) {
    try {
        docker --version | Out-Null
        $dockerAvailable = $true
    }
    catch {
        Write-Host "  [ERROR] Docker is required for image building!" -ForegroundColor Red
        exit 1
    }
}

# Build installer image
Write-Host "  [>] Building installer image..." -ForegroundColor Cyan
docker build `
    -f "$BuildDir\Dockerfile.installer" `
    -t "itl-talos-hardened:installer-v1.9.0" `
    --build-arg TALOS_VERSION=v1.9.0 `
    --build-arg BUILD_DATE="$(Get-Date -Format o)" `
    "$ProjectRoot" | Out-Host

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Installer build failed!" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] Installer image built successfully" -ForegroundColor Green

# Step 3: Summary
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Built images:" -ForegroundColor Cyan
docker images | Select-String "itl-talos" | ForEach-Object { "  $_" }

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Review the build logs above for any issues" -ForegroundColor White
Write-Host "  2. Test with: docker run --rm itl-talos-hardened:installer-v1.9.0" -ForegroundColor White
Write-Host "  3. Push to registry (if needed): docker push <registry>/itl-talos-hardened:installer-v1.9.0" -ForegroundColor White
