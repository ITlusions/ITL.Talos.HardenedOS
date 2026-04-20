#!/usr/bin/env pwsh
<#
.SYNOPSIS
Test talosctl connectivity to running Talos VM

.DESCRIPTION
Runs a series of talosctl commands to verify the Talos node is reachable and functional.

.PARAMETER TalosIP
IP address of the Talos VM (required)

.EXAMPLE
.\test-talosctl.ps1 -TalosIP 192.168.1.100
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TalosIP
)

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "Talos Control Plane Tests" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Target Node: $TalosIP`n"

$passed = 0
$failed = 0

# Test 1: Client version
Write-Host "[*] Check talosctl version..." -ForegroundColor Cyan
try {
    talosctl version --client
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Test 2: Node version
Write-Host "[*] Get node version..." -ForegroundColor Cyan
try {
    talosctl -n $TalosIP version
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Test 3: Members (etcd)
Write-Host "[*] Get node members..." -ForegroundColor Cyan
try {
    talosctl -n $TalosIP get members
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Test 4: Health check
Write-Host "[*] Check cluster health..." -ForegroundColor Cyan
try {
    talosctl -n $TalosIP health
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Test 5: Node info
Write-Host "[*] Get node information..." -ForegroundColor Cyan
try {
    talosctl -n $TalosIP get node
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Test 6: Kubelet status
Write-Host "[*] Check kubelet service..." -ForegroundColor Cyan
try {
    talosctl -n $TalosIP service kubelet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[✓] PASS`n" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[✗] FAIL`n" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[✗] ERROR: $_`n" -ForegroundColor Red
    $failed++
}

# Summary
Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failed -eq 0) {
    Write-Host "[OK] All tests passed! Talos node is operational." -ForegroundColor Green
} else {
    Write-Host "[!] Some tests failed. Check the node status." -ForegroundColor Yellow
    Write-Host "`nTroubleshooting tips:"
    Write-Host "  1. Verify IP address is correct: $TalosIP"
    Write-Host "  2. Check VM is running and booted"
    Write-Host "  3. Ensure Talos finished initialization"
    Write-Host "  4. Try: talosctl -n $TalosIP dmesg for kernel logs"
    Write-Host "  5. Try: talosctl -n $TalosIP logs kubelet for kubelet logs"
}

Write-Host ""
