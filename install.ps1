<#
.SYNOPSIS
    One-line installer for Claude Multiverse.

.DESCRIPTION
    Downloads the scripts to %LOCALAPPDATA%\ClaudeMultiverse, adds a Start Menu
    entry that opens the interactive menu, puts a 'cmv' command on your PATH and
    finishes with a quick environment check (doctor).

    Run from PowerShell:
        irm https://raw.githubusercontent.com/normannormalmann/Claude-Multiverse/main/install.ps1 | iex

    Or, from a local clone:
        .\install.ps1
#>

$ErrorActionPreference = 'Stop'

# Older systems do not enable TLS 1.2 by default; GitHub requires it.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {

    # Edit this once after forking - it's the only place the repository is named.
    $Repo   = 'normannormalmann/Claude-Multiverse'
    $Branch = 'main'

    $Base   = "https://raw.githubusercontent.com/$Repo/$Branch"
    $Dest   = Join-Path $env:LOCALAPPDATA 'ClaudeMultiverse'
    $Files  = @('claude-multiverse.ps1', 'tools\New-InstanceIcon.ps1')

    Write-Host ''
    Write-Host 'Claude Multiverse installer' -ForegroundColor Cyan
    Write-Host '---------------------------'

    New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'tools') | Out-Null

    # Local clone next to install.ps1? Copy instead of downloading.
    $localRoot = $null
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'claude-multiverse.ps1'))) { $localRoot = $PSScriptRoot }

    foreach ($f in $Files) {
        $target = Join-Path $Dest $f
        if ($localRoot) {
            Copy-Item (Join-Path $localRoot $f) $target -Force
            Write-Host "  OK    copied  $f" -ForegroundColor Green
        }
        else {
            if ($Repo -like '<*') { throw 'install.ps1 still has the <your-user> placeholder - edit $Repo first.' }
            $url = "$Base/" + ($f -replace '\\', '/')
            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
            Write-Host "  OK    fetched $f" -ForegroundColor Green
        }
        Unblock-File $target -ErrorAction SilentlyContinue
    }

    # Start Menu entry opening the interactive menu
    $smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Multiverse'
    New-Item -ItemType Directory -Force -Path $smDir | Out-Null
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $smDir 'Claude Multiverse.lnk'))
    $lnk.TargetPath  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments   = "-NoProfile -ExecutionPolicy Bypass -File `"$Dest\claude-multiverse.ps1`" menu"
    $lnk.Description = 'Manage multiple Claude Desktop instances'
    $lnk.Save()
    Write-Host "  OK    Start Menu entry: Claude Multiverse" -ForegroundColor Green

    # Optional: 'cmv' shim on the user PATH
    $binDir = Join-Path $Dest 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    # %LOCALAPPDATA% stays unexpanded on purpose: the .cmd file is ASCII and user names
    # with accented characters would otherwise break the path.
    $shim = @(
        '@echo off',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\ClaudeMultiverse\claude-multiverse.ps1" %*'
    )
    Set-Content -Path (Join-Path $binDir 'cmv.cmd') -Value $shim -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if (($userPath -split ';') -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir).TrimStart(';'), 'User')
        Write-Host "  OK    'cmv' command added to your PATH (new terminals pick it up automatically)" -ForegroundColor Green
    } else {
        Write-Host "  OK    'cmv' command already on PATH" -ForegroundColor Green
    }
    if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$env:Path;$binDir" }

    Write-Host ''
    Write-Host "  Installed to $Dest" -ForegroundColor Gray
    Write-Host "  Next: cmv new private      (or use the Start Menu entry)" -ForegroundColor Gray
    Write-Host ''

    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File "$Dest\claude-multiverse.ps1" doctor
}
catch {
    Write-Host ''
    Write-Host "  FAIL  Install failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  ..    Nothing needs cleaning up - just run the installer again.' -ForegroundColor Gray
    exit 1
}
