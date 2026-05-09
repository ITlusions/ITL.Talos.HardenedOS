param(
    [string] $SourceRepo  = "D:\repos\ITL.Talos.HardenedOS",
    [string] $OutputBase  = "D:\repos",
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$components = @(
    @{
        Name   = 'ITL.Talos.Flavors'
        Remote = 'https://github.com/ITlusions/ITL.Talos.Flavors.git'
        Paths  = @('flavors', '.github/workflows/build-controlplane-stack-flavor.yaml')
    }
    @{
        Name   = 'ITL.Talos.NetBoot'
        Remote = 'https://github.com/ITlusions/ITL.Talos.NetBoot.git'
        Paths  = @('netboot', 'build-ipxe-usb.ps1', 'build-ipxe-usb.sh', '.github/workflows/sync-to-netboot.yaml')
    }
    @{
        Name   = 'ITL.Talos.Provisioner'
        Remote = 'https://github.com/ITlusions/ITL.Talos.Provisioner.git'
        Paths  = @('services', 'provisioner')
    }
    @{
        Name   = 'ITL.Talos.Agent'
        Remote = 'https://github.com/ITlusions/ITL.Talos.Agent.git'
        Paths  = @('agents', '.github/agents')
    }
)

function Run-Step {
    param([string]$Label, [scriptblock]$Cmd)
    Write-Host "[>] $Label" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    (dry-run - skipped)" -ForegroundColor DarkGray
    } else {
        & $Cmd
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Step failed: $Label" }
    }
}

Write-Host "ITL.Talos.HardenedOS - repo split" -ForegroundColor Yellow
Write-Host "Source : $SourceRepo  |  Output : $OutputBase  |  DryRun : $DryRun"

foreach ($comp in $components) {
    $destDir = Join-Path $OutputBase $comp.Name
    Write-Host "" 
    Write-Host "== $($comp.Name) ==" -ForegroundColor Magenta
    Write-Host "   dest   : $destDir"
    Write-Host "   remote : $($comp.Remote)"
    Write-Host "   paths  : $($comp.Paths -join ', ')"

    Run-Step "Clone from source" {
        if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
        git clone --no-local $SourceRepo $destDir
    }

    if ($DryRun) { continue }

    Push-Location $destDir
    try {
        $filterArgs = foreach ($p in $comp.Paths) { '--path'; $p }
        Run-Step "Filter history to selected paths" {
            git filter-repo @filterArgs --force
        }
        Run-Step "Add remote origin" {
            git remote add origin $comp.Remote
        }
        Run-Step "Push to GitHub" {
            $branch = (git symbolic-ref --short HEAD).Trim()
            git push -u origin $branch
        }
        Write-Host "Done: $($comp.Remote)" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "All components processed." -ForegroundColor Green
if (-not $DryRun) {
    Write-Host "Run cleanup-source-repo.ps1 next to remove extracted paths from source repo."
}