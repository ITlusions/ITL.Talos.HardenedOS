#!/usr/bin/env pwsh
<#
.SYNOPSIS
Check Talos Master Node Status

.DESCRIPTION
Checks connectivity, VM status, and attempts various talosctl commands to diagnose initialization issues.
#>

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Talos Master Node Diagnostic" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$targetIP = "172.29.228.45"
$env:TALOSCONFIG = "$PWD\config\output\talosconfig"

# 1. Ping check
Write-Host "[1] Network Connectivity..."
if (Test-Connection -ComputerName $targetIP -Count 1 -Quiet) {
    Write-Host "    ✓ PING: Reachable" -ForegroundColor Green
} else {
    Write-Host "    ✗ PING: Unreachable" -ForegroundColor Red
    exit 1
}

# 2. VM Status
Write-Host "`n[2] Hyper-V VM Status..."
$vm = Get-VM | Where-Object {$_.Name -like "*Talos*"} -ErrorAction SilentlyContinue
if ($vm) {
    Write-Host "    Name:   $($vm.Name)"
    Write-Host "    State:  $($vm.State)" -ForegroundColor Green
    Write-Host "    Uptime: $($vm.Uptime)"
    Write-Host "    Memory: $([Math]::Round($vm.MemoryAssigned/1GB,2)) GB"
} else {
    Write-Host "    ✗ VM not found" -ForegroundColor Red
}

# 3. Port checks
Write-Host "`n[3] Port Connectivity..."
$ports = @(6443, 50000, 22)
foreach ($port in $ports) {
    $connection = New-Object System.Net.Sockets.TcpClient
    try {
        $connection.Connect($targetIP, $port)
        if ($connection.Connected) {
            Write-Host "    ✓ Port $port: OPEN" -ForegroundColor Green
        }
    } catch {
        Write-Host "    ✗ Port $port: CLOSED" -ForegroundColor Yellow
    } finally {
        $connection.Close()
    }
}

# 4. Talosctl version
Write-Host "`n[4] Talosctl Connection..."
try {
    $version = talosctl -n $targetIP version 2>&1
    if ($version -match "Server:") {
        Write-Host "    ✓ API Responding" -ForegroundColor Green
    }
} catch {
    Write-Host "    ✗ API Not Responding (Expected during boot)" -ForegroundColor Yellow
    Write-Host "    Error: $($_)" -ForegroundColor Gray
}

# 5. Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "If you see:"
Write-Host "  • ✓ Ping working, ports closed" -ForegroundColor Yellow
Write-Host "    → Node is BOOTING, wait 2-3 more minutes`n"

Write-Host "  • ✓ Ping working, port 6443 open" -ForegroundColor Green
Write-Host "    → Run: talosctl bootstrap -n $targetIP`n"

Write-Host "  • ✗ Ping failing" -ForegroundColor Red
Write-Host "    → Network issue or VM not responding`n"

Write-Host "Next: Check the VM console in Hyper-V Manager for any errors"
Write-Host ""
