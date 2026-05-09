param(
    [string] $RepoRoot = "D:\repos\ITL.Talos.HardenedOS",
    [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toRemove = @(
    'flavors',
    '.github/workflows/build-controlplane-stack-flavor.yaml',
    'netboot',
    'build-ipxe-usb.ps1',
    'build-ipxe-usb.sh',
    '.github/workflows/sync-to-netboot.yaml',
    'services',
    'provisioner',
    'agents',
    '.github/agents'
)

Write-Host "ITL.Talos.HardenedOS - source repo cleanup" -ForegroundColor Yellow
Write-Host "RepoRoot : $RepoRoot  |  WhatIf : $WhatIf"

Push-Location $RepoRoot
try {
    foreach ($rel in $toRemove) {
        $abs = Join-Path $RepoRoot $rel
        if (-not (Test-Path $abs)) {
            Write-Host "  skip (not found): $rel" -ForegroundColor DarkGray
            continue
        }
        if ($WhatIf) {
            Write-Host "  would remove: $rel" -ForegroundColor Cyan
        } else {
            Write-Host "  removing: $rel" -ForegroundColor Cyan
            git rm -r --cached $rel 2>$null
            Remove-Item $abs -Recurse -Force
        }
    }

    if (-not $WhatIf) {
        git add -A
        $msg = "chore: remove extracted components (Flavors, NetBoot, Provisioner, Agent)"
        Write-Host "Committing: $msg" -ForegroundColor Green
        git commit -m $msg
        Write-Host "Done. Review with: git show --stat HEAD"
        Write-Host "Then push: git push origin <branch>"
    }
} finally {
    Pop-Location
}