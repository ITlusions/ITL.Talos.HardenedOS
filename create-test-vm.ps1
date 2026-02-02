# Create Hyper-V VM for Talos OS Testing
# Run this script as Administrator

$ErrorActionPreference = "Stop"

$vmName = "ITL-Talos-Test"
$isoPath = "D:\repos\ITL.Talos.HardenedOS\iso-download\itl-talos-v1.9.0.iso"
$vhdPath = "C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks\$vmName.vhdx"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Creating Hyper-V VM for Talos OS" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# Check if VM already exists
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    Write-Host "[!] VM '$vmName' already exists. Removing..." -ForegroundColor Yellow
    if ((Get-VM -Name $vmName).State -eq "Running") {
        Stop-VM -Name $vmName -Force
    }
    Remove-VM -Name $vmName -Force
    if (Test-Path $vhdPath) {
        Remove-Item $vhdPath -Force
    }
}

# Check if ISO exists
if (-not (Test-Path $isoPath)) {
    Write-Host "[ERROR] ISO not found: $isoPath" -ForegroundColor Red
    exit 1
}

Write-Host "[*] Creating VM: $vmName" -ForegroundColor Yellow

# Create VM
New-VM -Name $vmName `
    -MemoryStartupBytes 4GB `
    -Generation 2 `
    -NewVHDPath $vhdPath `
    -NewVHDSizeBytes 20GB `
    -SwitchName "Default Switch" | Out-Null

Write-Host "  [OK] VM created" -ForegroundColor Green

# Configure VM
Set-VMProcessor -VMName $vmName -Count 2
Write-Host "  [OK] CPU: 2 cores" -ForegroundColor Green

Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false
Write-Host "  [OK] Memory: 4GB (static)" -ForegroundColor Green

# Add DVD drive with ISO
Add-VMDvdDrive -VMName $vmName -Path $isoPath
$dvd = Get-VMDvdDrive -VMName $vmName
Write-Host "  [OK] ISO mounted: itl-talos-v1.9.0.iso" -ForegroundColor Green

# Set boot order and disable secure boot (Talos doesn't need it)
Set-VMFirmware -VMName $vmName -FirstBootDevice $dvd -EnableSecureBoot Off
Write-Host "  [OK] Boot order: DVD first, Secure Boot disabled" -ForegroundColor Green

# Enable nested virtualization (optional, for testing gVisor)
Set-VMProcessor -VMName $vmName -ExposeVirtualizationExtensions $true
Write-Host "  [OK] Nested virtualization enabled" -ForegroundColor Green

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  VM Ready for Talos Installation" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""

# Display VM info
Get-VM -Name $vmName | Format-List Name, State, CPUUsage, MemoryAssigned, Uptime

Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Start VM:    Start-VM -Name $vmName" -ForegroundColor White
Write-Host "  2. Connect:     vmconnect.exe localhost $vmName" -ForegroundColor White
Write-Host "  3. Or combined: Start-VM -Name $vmName; vmconnect.exe localhost $vmName" -ForegroundColor White
Write-Host ""
Write-Host "Talos will boot from ISO automatically" -ForegroundColor Cyan
