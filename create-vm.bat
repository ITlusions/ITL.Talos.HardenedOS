@echo off
REM Create Hyper-V VM for Talos HardenedOS
cd /d %~dp0
powershell -NoProfile -ExecutionPolicy Bypass -Command "& {.\create-hyperv-vm.ps1}"
pause
