# Create Hyper-V VM for Talos HardenedOS Testing
# Run as Administrator

param(
    [string]$VMName = "ITL-Talos-Test",
    [string]$Generation = "2",
    [int]$MemoryMB = 4096,
    [int]$CPUCount = 2,
    [int]$DiskSizeGB = 20,
    [string]$ISOPath = "$PSScriptRoot\iso-download\itl-talos-v1.9.0.iso"
)

# Check if running as administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Verify ISO exists
if (-not (Test-Path $ISOPath)) {
    Write-Error "ISO not found at: $ISOPath"
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Creating Hyper-V VM: $VMName" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "VM Name:      $VMName"
Write-Host "Generation:   $Generation"
Write-Host "Memory:       ${MemoryMB}MB"
Write-Host "CPUs:         $CPUCount"
Write-Host "Disk Size:    ${DiskSizeGB}GB"
Write-Host "ISO:          $ISOPath"
Write-Host ""

# Check if VM already exists
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "[!] VM '$VMName' already exists" -ForegroundColor Yellow
    $choice = Read-Host "Delete existing VM? (Y/n)"
    if ($choice -ne "n") {
        Write-Host "[*] Removing existing VM..."
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-VM -Name $VMName -Force | Out-Null
        Write-Host "[OK] VM removed"
    } else {
        Write-Host "[*] Skipping VM creation"
        exit 0
    }
}

# Create VM
Write-Host "[*] Creating VM '$VMName'..." -ForegroundColor Green
New-VM -Name $VMName `
    -Generation $Generation `
    -MemoryStartupBytes ($MemoryMB * 1MB) `
    -NewVHDPath "$env:USERPROFILE\AppData\Local\Hyper-V\$VMName.vhdx" `
    -NewVHDSizeBytes ($DiskSizeGB * 1GB) | Out-Null

Write-Host "[OK] VM created" -ForegroundColor Green

# Configure VM
Write-Host "[*] Configuring VM..." -ForegroundColor Green

# Set CPU count
Set-VMProcessor -VMName $VMName -Count $CPUCount | Out-Null

# Disable secure boot (Talos doesn't require it)
if ($Generation -eq "2") {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
    Write-Host "[OK] Secure Boot disabled"
}

# Enable nested virtualization (if supported)
Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction SilentlyContinue | Out-Null

# Mount ISO
Write-Host "[*] Mounting ISO..." -ForegroundColor Green
$isoPath = (Resolve-Path $ISOPath).Path
Add-VMDvdDrive -VMName $VMName -Path $isoPath | Out-Null
Write-Host "[OK] ISO mounted at: $isoPath"

# Set boot order (CD first)
if ($Generation -eq "2") {
    $vmFirmware = Get-VMFirmware -VMName $VMName
    $dvdDrive = Get-VMDvdDrive -VMName $VMName | Select-Object -First 1
    Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive | Out-Null
    Write-Host "[OK] Boot order set to DVD first"
}

# Get VM info
Write-Host ""
Write-Host "[*] VM Configuration:" -ForegroundColor Green
Get-VM -Name $VMName | Select-Object Name, State, ProcessorCount, MemoryAssigned | Format-Table

Write-Host ""
Write-Host "[*] Starting VM '$VMName'..." -ForegroundColor Green
Start-VM -Name $VMName

# Wait for VM to start
Start-Sleep -Seconds 2

# Get VM state
$vm = Get-VM -Name $VMName
Write-Host "[OK] VM started - State: $($vm.State)" -ForegroundColor Green

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "VM Ready for Testing" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Connect to console:" -ForegroundColor Yellow
Write-Host "  vmconnect.exe localhost $VMName"
Write-Host ""
Write-Host "Or use Hyper-V Manager:" -ForegroundColor Yellow
Write-Host "  virtmgmt.msc"
Write-Host ""
