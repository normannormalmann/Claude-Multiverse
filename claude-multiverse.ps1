<#
.SYNOPSIS
    Run multiple isolated Claude Desktop instances side by side on Windows.

.DESCRIPTION
    Claude Desktop is an Electron app and accepts --user-data-dir, which
    redirects the entire application data directory. Every instance gets its
    own login, connectors, MCP servers, settings and Cowork environment.

    Windows ships Claude Desktop as an MSIX package. Arguments only reach an
    MSIX app through Invoke-CommandInDesktopPackage, which needs elevation.
    To avoid a UAC prompt on every launch, "register" creates a Task Scheduler
    task that runs with highest privileges; shortcuts then trigger the task.

.EXAMPLE
    .\claude-multiverse.ps1                 # interactive menu
    .\claude-multiverse.ps1 new private     # guided setup: dir, icon, task, shortcut
    .\claude-multiverse.ps1 launch private
    .\claude-multiverse.ps1 list
    .\claude-multiverse.ps1 doctor
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'new', 'launch', 'stop', 'list', 'shortcut', 'register', 'unregister',
                 'remove', 'clone-config', 'open', 'doctor', 'help')]
    [string]$Command = 'menu',

    [Parameter(Position = 1)]
    [string]$Instance,

    [Parameter(Position = 2)]
    [string]$Target,

    [string]$Label,
    [string]$Icon,
    [string]$Letter,
    [string]$Color,
    [switch]$StartMenu,
    [switch]$Force,
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'

$Script:Version       = '1.0.0'
$Script:InstancesBase = Join-Path $env:USERPROFILE '.claude-instances'
$Script:IconsBase     = Join-Path $env:USERPROFILE '.claude-icons'
$Script:ErrorLog      = Join-Path $Script:InstancesBase 'last-error.log'
$Script:TaskPrefix    = 'ClaudeMultiverse-'
$Script:Ps51          = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Script:IconTool      = Join-Path $PSScriptRoot 'tools\New-InstanceIcon.ps1'
$Script:Palette       = @('#D97757', '#4A7DBF', '#5B9A6B', '#8E6BBF', '#C9973A', '#3E8E9E')
$Script:ColorPattern  = '^#?[0-9A-Fa-f]{6}$'

# ---------------------------------------------------------------- output ---

function Write-Ok    { param($m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Note  { param($m) Write-Host "  ..    $m" -ForegroundColor Gray }
function Write-Warn2 { param($m) Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red }
function Write-Head  { param($m) Write-Host ''; Write-Host $m -ForegroundColor Cyan; Write-Host ('-' * $m.Length) }

function Read-Answer {
    <# Read-Host with trimmed result, so pasted or piped input with stray whitespace works. #>
    param([string]$Prompt)
    $in = Read-Host $Prompt
    if ($null -eq $in) { return '' }
    return $in.Trim()
}

# -------------------------------------------------------------- self-exec ---

function Get-SelfArgs {
    <# Rebuild the current invocation so the script can re-launch itself. #>
    param([string]$OverrideCommand, [string]$InstanceName, [switch]$AddNoTask, [switch]$AddForce)

    $cmd = $Command
    if ($OverrideCommand) { $cmd = $OverrideCommand }
    $inst = $Instance
    if ($InstanceName) { $inst = $InstanceName }

    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $cmd)
    $named = @{ Instance = $inst; Target = $Target }
    foreach ($k in 'Label', 'Icon', 'Letter', 'Color') {
        $named[$k] = Get-Variable -Name $k -ValueOnly -ErrorAction SilentlyContinue
    }
    foreach ($k in 'Instance', 'Target', 'Label', 'Icon', 'Letter', 'Color') {
        $v = $named[$k]
        if (-not $v) { continue }
        # Values are re-quoted for a child command line; a literal quote would break out of it.
        if ($v -match '"') { throw "Value for -$k must not contain a double quote." }
        $list += "-$k"; $list += "`"$v`""
    }
    if ($StartMenu)             { $list += '-StartMenu' }
    if ($Force -or $AddForce)   { $list += '-Force' }
    if ($NoTask -or $AddNoTask) { $list += '-NoTask' }
    return $list
}

# Everything here is Windows PowerShell 5.1 territory (Appx, ScheduledTasks).
# PowerShell 7 users are transparently bounced to 5.1.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $p = Start-Process -FilePath $Script:Ps51 -ArgumentList (Get-SelfArgs) -Wait -NoNewWindow -PassThru
    exit $p.ExitCode
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AdminCapable {
    <# True when the user can elevate: already elevated, or Administrators SID in the
       token - including the deny-only entry a UAC-filtered token carries. WindowsIdentity.Groups
       misses that entry on some Entra ID accounts, so ask whoami and match the SID. #>
    if (Test-Admin) { return $true }
    try { return [bool]((whoami.exe /groups) -match 'S-1-5-32-544') } catch { return $false }
}

function Test-HiddenConsole {
    <# True when this process was started with -WindowStyle Hidden (scheduled task or
       shortcut). Nobody can see the console then, so never wait for a key press. #>
    try {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).CommandLine
        return [bool]($cl -match '-WindowStyle\s+Hidden')
    } catch { return $false }
}

function Invoke-Elevated {
    <# Run this script elevated with the given command and wait for it. #>
    param([string]$Cmd, [string]$InstanceName, [switch]$AddNoTask, [switch]$AddForce)
    $argList = Get-SelfArgs -OverrideCommand $Cmd -InstanceName $InstanceName -AddNoTask:$AddNoTask -AddForce:$AddForce
    try {
        $p = Start-Process -FilePath $Script:Ps51 -ArgumentList $argList -Verb RunAs -Wait -PassThru
        return $p.ExitCode
    } catch {
        return 1223   # ERROR_CANCELLED - user declined the UAC prompt
    }
}

# --------------------------------------------------------------- helpers ---

function Test-InstanceName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]*$') { return $false }
    if ($Name -eq 'default') { return $false }
    return $true
}

function Assert-InstanceName {
    param([string]$Name)
    if (-not (Test-InstanceName $Name)) {
        throw "Invalid or missing instance name '$Name' - letters, digits, dots, dashes; not 'default'."
    }
}

function Get-InstanceDir  { param([string]$Name) Join-Path $Script:InstancesBase $Name }
function Get-TaskName     { param([string]$Name) "$($Script:TaskPrefix)$Name" }
function Get-DefaultLabel { param([string]$Name) 'Claude ' + $Name.Substring(0, 1).ToUpper() + $Name.Substring(1) }

function Test-Task {
    param([string]$Name)
    return [bool](Get-ScheduledTask -TaskName (Get-TaskName $Name) -ErrorAction SilentlyContinue)
}

function Get-Instances {
    if (-not (Test-Path $Script:InstancesBase)) { return @() }
    return @(Get-ChildItem -Path $Script:InstancesBase -Directory | Select-Object -ExpandProperty Name)
}

function Get-ClaudePackage {
    <# The Claude Desktop MSIX package: exact name first, then any Claude* app package
       that actually ships Claude.exe (skips frameworks and broken registrations). #>
    $all = @(Get-AppxPackage -Name 'Claude*' -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework })
    $exact = @($all | Where-Object { $_.Name -eq 'Claude' })
    if ($exact.Count) { $all = $exact }
    $withExe = @($all | Where-Object { Test-Path (Join-Path $_.InstallLocation 'app\Claude.exe') })
    if ($withExe.Count) { return $withExe[0] }
    if ($all.Count) { return $all[0] }
    return $null
}

function Get-ClaudeInstall {
    <# Locate Claude Desktop and describe how it must be launched. #>
    $pkg = Get-ClaudePackage
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (-not (Test-Path $exe)) {
            $found = Get-ChildItem -Path $pkg.InstallLocation -Filter 'Claude.exe' -Recurse `
                     -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $exe = $found.FullName }
        }
        # MSIX Claude is not virtualised: the built-in instance writes to the plain
        # Roaming path, not to Packages\...\LocalCache. Prefer whichever actually exists.
        $cfg = Join-Path $env:APPDATA 'Claude'
        $pkgCfg = Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude"
        if (-not (Test-Path $cfg) -and (Test-Path $pkgCfg)) { $cfg = $pkgCfg }
        return [pscustomobject]@{
            Type = 'MSIX'; Exe = $exe; Version = $pkg.Version
            PackageFamilyName = $pkg.PackageFamilyName; AppId = 'Claude'
            ConfigDir = $cfg
        }
    }

    $root = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path $root) {
        $app = Get-ChildItem -Path $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
               Sort-Object -Descending -Property @{ Expression = {
                   $v = $null
                   if ([version]::TryParse(($_.Name -replace '^app-', ''), [ref]$v)) { $v } else { [version]'0.0' }
               } }, Name | Select-Object -First 1
        if ($app -and (Test-Path (Join-Path $app.FullName 'claude.exe'))) {
            return [pscustomobject]@{
                Type = 'Classic'; Exe = (Join-Path $app.FullName 'claude.exe'); Version = $app.Name
                ConfigDir = Join-Path $env:APPDATA 'Claude'
            }
        }
    }

    foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
                     (Join-Path $env:ProgramFiles 'Claude\Claude.exe'))) {
        if (Test-Path $c) {
            return [pscustomobject]@{ Type = 'Classic'; Exe = $c; Version = 'unknown'
                                      ConfigDir = Join-Path $env:APPDATA 'Claude' }
        }
    }
    return $null
}

function Get-RequiredInstall {
    $install = Get-ClaudeInstall
    if (-not $install) { throw 'Claude Desktop not found. Install it from https://claude.ai/download' }
    return $install
}

function Get-StartMenuFolder { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Multiverse' }

function Get-Shortcuts {
    <# Shortcuts this tool created: only in the two folders it writes to, and only when
       the target is one of our three launch modes - so a third-party shortcut can never
       be mistaken for (and deleted as) an instance shortcut. #>
    $ws = New-Object -ComObject WScript.Shell
    $roots = @([Environment]::GetFolderPath('Desktop'), (Get-StartMenuFolder))
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $lnk = $ws.CreateShortcut($_.FullName)
            $a = $lnk.Arguments
            $t = $lnk.TargetPath
            $name = $null
            if     ($t -like '*\schtasks.exe' -and $a -match [regex]::Escape($Script:TaskPrefix) + '([^"\s]+)') { $name = $Matches[1] }
            elseif ($t -eq $Script:Ps51 -and $a -match 'claude-multiverse\.ps1"\s+launch\s+"?([^"\s]+)"?')      { $name = $Matches[1] }
            elseif ($t -like '*\claude.exe' -and $a -match '\.claude-instances[\\/]([^"\s\\/]+)')                 { $name = $Matches[1] }
            if ($name) { [pscustomobject]@{ Path = $_.FullName; Instance = $name } }
        }
    }
}

function Get-DirSizeMb {
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { return 0 }
        return [math]::Round($sum / 1MB)
    } catch { return 0 }
}

function Test-DirEmpty {
    param([string]$Path)
    return (@(Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue).Count -eq 0)
}

function Show-LoginHint {
    Write-Host ''
    Write-Host '  Before signing in to the new instance:' -ForegroundColor Yellow
    Write-Host '   1. Close every other Claude instance, including the tray icon.'
    Write-Host '   2. Sign out of Google / Microsoft in your default browser, or open the'
    Write-Host '      account picker - otherwise SSO silently reuses the account that is'
    Write-Host '      already signed in and the new instance gets the wrong account.'
    Write-Host '   3. Sign in, then sign back into your other account in the browser.'
    Write-Host '  Email-code sign-in skips all of this.'
    Write-Host ''
}

# ------------------------------------------------------------- processes ---

function Get-InstanceProcesses {
    <# The instance's process tree: every claude.exe started with exactly this data
       directory, plus everything below those (MCP servers, Cowork helpers).
       Note: a non-elevated shell cannot read the command line of elevated processes,
       so from there this only sees the sandboxed child processes. #>
    param([string]$Name)
    $dir = Get-InstanceDir $Name
    $pattern = [regex]::Escape($dir) + '(["\\\s]|$)'
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID })

    $found = @{}
    foreach ($p in $all) {
        if ($p.Name -eq 'claude.exe' -and $p.CommandLine -and $p.CommandLine -match $pattern) { $found[$p.ProcessId] = $p }
    }
    $added = $true
    while ($added) {
        $added = $false
        foreach ($p in $all) {
            if (-not $found.ContainsKey($p.ProcessId) -and $found.ContainsKey($p.ParentProcessId)) {
                $found[$p.ProcessId] = $p
                $added = $true
            }
        }
    }
    return @($found.Values)
}

function Test-InstanceLock {
    <# Electron keeps <dir>\lockfile open for as long as the instance runs. A sharing
       violation on it means "running" - visible even from a non-elevated shell. #>
    param([string]$Name)
    $lock = Join-Path (Get-InstanceDir $Name) 'lockfile'
    if (-not (Test-Path $lock)) { return $false }
    try {
        $fs = [System.IO.File]::Open($lock, 'Open', 'Read', 'None')
        $fs.Close()
        return $false
    }
    catch [System.IO.IOException] { return $true }
    catch { return $false }
}

function Test-InstanceRunning {
    param([string]$Name)
    if (Test-InstanceLock $Name) { return $true }
    return (@(Get-InstanceProcesses $Name).Count -gt 0)
}

function Stop-Instance {
    <# Ask (unless -Force) and stop every process of the instance. MSIX instances run
       elevated, so a plain shell cannot kill them - re-run elevated when needed. #>
    param([string]$Name)
    if (-not (Test-InstanceRunning $Name)) { return $true }

    $procs = @(Get-InstanceProcesses $Name)
    Write-Warn2 "Instance '$Name' is still running."
    if (-not $Force) {
        $ok = Read-Answer '  Close it now? [y/N]'
        if ($ok -notmatch '^[yYjJ]') { return $false }
    }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    if (Test-InstanceRunning $Name) {
        if (Test-Admin) { Write-Fail 'Processes survived even elevated.'; return $false }
        Write-Note 'The instance runs elevated - retrying with elevation (UAC prompt)...'
        $rc = Invoke-Elevated -Cmd 'stop' -InstanceName $Name -AddForce
        Start-Sleep -Seconds 1
        if ($rc -ne 0 -or (Test-InstanceRunning $Name)) { return $false }
    }
    Write-Ok "Instance '$Name' closed."
    return $true
}

# -------------------------------------------------------------- commands ---

function Invoke-Launch {
    param([string]$Name)
    Assert-InstanceName $Name
    $install = Get-RequiredInstall

    $dir = Get-InstanceDir $Name
    if (-not (Test-Path $dir)) { throw "Instance '$Name' does not exist. Create it with: new $Name" }
    $fresh = Test-DirEmpty $dir

    if ($install.Type -eq 'MSIX') {
        if (-not $NoTask -and (Test-Task $Name)) {
            schtasks.exe /run /tn (Get-TaskName $Name) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks could not start task '$(Get-TaskName $Name)' (exit code $LASTEXITCODE)." }
            Write-Ok "Launched '$Name' via scheduled task (no UAC)."
        }
        else {
            if (-not (Test-Admin)) {
                $argList = @('-WindowStyle', 'Hidden') + (Get-SelfArgs -OverrideCommand 'launch' -InstanceName $Name -AddNoTask)
                Start-Process -FilePath $Script:Ps51 -ArgumentList $argList -Verb RunAs
                Write-Ok "Launching '$Name' elevated (UAC prompt)."
                return
            }
            Invoke-CommandInDesktopPackage -PackageFamilyName $install.PackageFamilyName `
                -AppId $install.AppId -Command $install.Exe -Args "--user-data-dir=`"$dir`""
            Write-Ok "Launched '$Name'."
        }
    }
    else {
        Start-Process -FilePath $install.Exe -ArgumentList "--user-data-dir=`"$dir`""
        Write-Ok "Launched '$Name'."
    }

    Write-Note "Data: $dir"
    if ($fresh) { Show-LoginHint }
}

function Invoke-Register {
    param([string]$Name)
    Assert-InstanceName $Name
    $install = Get-RequiredInstall
    if ($install.Type -ne 'MSIX') { Write-Note 'Classic install - no task needed, launches without elevation.'; return }

    if (-not (Test-Admin)) {
        $rc = Invoke-Elevated -Cmd 'register' -InstanceName $Name
        if ($rc -ne 0) { throw "Task registration was cancelled or failed (code $rc)." }
        if (-not (Test-Task $Name)) { throw 'Elevated process finished but the task does not exist.' }
        Write-Ok "Scheduled task registered for '$Name' - launches skip UAC from now on."
        return
    }

    $dir = Get-InstanceDir $Name
    if (-not (Test-Path $dir)) { throw "Instance '$Name' does not exist. Create it with: new $Name" }

    $taskName  = Get-TaskName $Name
    $action    = New-ScheduledTaskAction -Execute $Script:Ps51 -Argument (Get-TaskLaunchArgument -Dir $dir -PackageFamilyName $install.PackageFamilyName)
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -MultipleInstances Parallel -Compatibility Win8
    $settings.ExecutionTimeLimit = 'PT0S'   # never kill the launched app
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                 -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Principal $principal -Force `
        -Description "Claude Multiverse: starts the Claude Desktop instance '$Name' with its own data directory. Self-contained - runs no script file." | Out-Null
    Write-Ok "Scheduled task '$taskName' registered - launches without UAC from now on."
}

function ConvertTo-PsLiteral {
    <# Single-quoted PowerShell string literal. #>
    param([string]$s)
    return "'" + ($s -replace "'", "''") + "'"
}

function Get-TaskLaunchArgument {
    <# The powershell.exe argument string for the scheduled task. The task runs elevated
       without a UAC prompt, so it must not depend on anything a non-elevated process could
       tamper with: no script file, no profile, the Appx module loaded by absolute path
       from System32. The package is resolved at run time because its install folder
       changes with every Claude update. Only single quotes are used so the string
       survives the powershell.exe command line intact. #>
    param([string]$Dir, [string]$PackageFamilyName)
    $appx  = ConvertTo-PsLiteral (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\Appx\Appx.psd1')
    $pfn   = ConvertTo-PsLiteral $PackageFamilyName
    $udd   = ConvertTo-PsLiteral $Dir
    $code  = 'try { '
    $code += "Import-Module $appx -ErrorAction Stop; "
    $code += "`$p = Get-AppxPackage | Where-Object { `$_.PackageFamilyName -eq $pfn } | Select-Object -First 1; "
    $code += "if (-not `$p) { throw ('Claude Desktop package not found: ' + $pfn) }; "
    $code += "`$e = Join-Path `$p.InstallLocation 'app\Claude.exe'; "
    $code += "if (-not (Test-Path `$e)) { `$e = (Get-ChildItem `$p.InstallLocation -Filter 'Claude.exe' -Recurse | Select-Object -First 1).FullName }; "
    $code += "Invoke-CommandInDesktopPackage -PackageFamilyName `$p.PackageFamilyName -AppId 'Claude' -Command `$e -Args ('--user-data-dir=' + [char]34 + $udd + [char]34) "
    $code += '} catch { '
    $code += 'Add-Type -AssemblyName System.Windows.Forms; '
    $code += "[void][System.Windows.Forms.MessageBox]::Show(`$_.Exception.Message, 'Claude Multiverse', 0, 16); exit 1 "
    $code += '}'
    return "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command $code"
}

function Invoke-Unregister {
    param([string]$Name)
    Assert-InstanceName $Name
    if (-not (Test-Task $Name)) { Write-Note 'No task registered for this instance.'; return }
    if (-not (Test-Admin)) {
        $rc = Invoke-Elevated -Cmd 'unregister' -InstanceName $Name
        if ($rc -ne 0) { throw "Task removal was cancelled or failed (code $rc)." }
        Write-Ok "Scheduled task removed for '$Name'."
        return
    }
    Unregister-ScheduledTask -TaskName (Get-TaskName $Name) -Confirm:$false
    Write-Ok "Scheduled task removed for '$Name'."
}

function Invoke-Shortcut {
    param([string]$Name, [string]$DisplayLabel, [string]$IconPath, [switch]$Overwrite)
    Assert-InstanceName $Name
    $install = Get-RequiredInstall

    if (-not $DisplayLabel) { $DisplayLabel = Get-DefaultLabel $Name }
    if ($DisplayLabel.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $DisplayLabel -match '^\.+$') {
        throw "Label '$DisplayLabel' contains characters that are not allowed in a file name."
    }
    $dir = Get-InstanceDir $Name
    if (-not (Test-Path $dir)) { throw "Instance '$Name' does not exist. Create it with: new $Name" }

    $folder = [Environment]::GetFolderPath('Desktop')
    if ($StartMenu) {
        $folder = Get-StartMenuFolder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    $lnkPath = Join-Path $folder "$DisplayLabel.lnk"
    if ((Test-Path $lnkPath) -and -not ($Force -or $Overwrite)) {
        throw "Shortcut already exists: $lnkPath  (use -Force to overwrite)"
    }

    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)

    if ($install.Type -eq 'MSIX' -and (Test-Task $Name)) {
        $lnk.TargetPath  = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $lnk.Arguments   = "/run /tn `"$(Get-TaskName $Name)`""
        $lnk.WindowStyle = 7   # minimized - hides the console flash
        $mode = 'scheduled task, no UAC'
    }
    elseif ($install.Type -eq 'MSIX') {
        $lnk.TargetPath  = $Script:Ps51
        $lnk.Arguments   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" launch `"$Name`""
        $lnk.WindowStyle = 7
        $mode = 'elevated launch, UAC prompt each time - run "register" to avoid it'
    }
    else {
        $lnk.TargetPath = $install.Exe
        $lnk.Arguments  = "--user-data-dir=`"$dir`""
        $mode = 'direct launch'
    }

    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Description      = "Claude Desktop - instance '$Name'"

    if (-not $IconPath) {
        $auto = Join-Path $Script:IconsBase "$Name.ico"
        if (Test-Path $auto) { $IconPath = $auto }
    }
    if ($IconPath -and (Test-Path $IconPath)) { $lnk.IconLocation = ((Resolve-Path $IconPath).Path + ',0') }
    elseif ($install.Type -eq 'Classic')     { $lnk.IconLocation = ($install.Exe + ',0') }

    $lnk.Save()
    Write-Ok "Shortcut created: $lnkPath"
    Write-Note "Mode: $mode"
}

function New-Icon {
    param([string]$Name, [string]$Ltr, [string]$Clr)
    if (-not (Test-Path $Script:IconTool)) { Write-Warn2 "Icon tool not found at $($Script:IconTool) - skipping icon."; return $null }
    if (-not $Ltr) { $Ltr = $Name.Substring(0, 1).ToUpper() }
    if (-not $Clr) { $Clr = $Script:Palette[(Get-Instances).Count % $Script:Palette.Count] }
    $out = Join-Path $Script:IconsBase "$Name.ico"
    & $Script:IconTool -Letter $Ltr -Color $Clr -OutFile $out -Quiet
    Write-Ok "Icon: $out  ($Ltr, $Clr)"
    return $out
}

function Invoke-New {
    <# Guided setup: directory, icon, scheduled task, shortcut. #>
    param([string]$Name)

    Write-Head 'New Claude instance'
    if (-not $Name) { $Name = Read-Answer '  Instance name (e.g. private, work)' }
    Assert-InstanceName $Name
    if ((Test-Path (Get-InstanceDir $Name)) -and (-not $Force)) {
        throw "Instance '$Name' already exists. Use -Force to re-run setup for it."
    }
    $install = Get-RequiredInstall

    $defaultLtr = $Name.Substring(0, 1).ToUpper()
    $ltr = $Letter
    if (-not $ltr) {
        $in = Read-Answer "  Icon letter [$defaultLtr]"
        $ltr = if ($in) { $in } else { $defaultLtr }
    }
    $ltr = $ltr.Substring(0, 1).ToUpper()

    $defaultClr = $Script:Palette[(Get-Instances).Count % $Script:Palette.Count]
    $clr = $Color
    while ($clr -notmatch $Script:ColorPattern) {
        if ($clr) { Write-Warn2 "'$clr' is not a #RRGGBB colour." }
        $in = Read-Answer "  Icon colour as #RRGGBB [$defaultClr]"
        $clr = if ($in) { $in } else { $defaultClr }
    }
    if ($clr -notlike '#*') { $clr = "#$clr" }

    New-Item -ItemType Directory -Force -Path (Get-InstanceDir $Name) | Out-Null
    Write-Ok "Data directory: $(Get-InstanceDir $Name)"

    $iconPath = New-Icon -Name $Name -Ltr $ltr -Clr $clr

    if ($install.Type -eq 'MSIX') {
        if (Test-AdminCapable) {
            Write-Note 'Registering a scheduled task so launches skip the UAC prompt (one UAC prompt now)...'
            $rc = Invoke-Elevated -Cmd 'register' -InstanceName $Name
            if ($rc -eq 0 -and (Test-Task $Name)) { Write-Ok "Scheduled task registered for '$Name'." }
            else { Write-Warn2 'Skipped - the shortcut will prompt for UAC on each launch. Run "register" later to fix.' }
        } else {
            Write-Warn2 'Your account is not an administrator - MSIX instances need admin rights to launch.'
        }
    }

    Invoke-Shortcut -Name $Name -DisplayLabel $Label -IconPath $iconPath -Overwrite

    if ($install.Type -eq 'MSIX' -and -not (Test-AdminCapable)) {
        Write-Host ''
        Write-Warn2 'This account cannot elevate. The shortcut will ask for administrator credentials on'
        Write-Warn2 'every launch, and running instances as a different (admin) user is untested.'
    }

    Write-Host ''
    $go = Read-Answer '  Launch it now? [Y/n]'
    if ($go -eq '' -or $go -match '^[yYjJ]') { Invoke-Launch -Name $Name }
    else { Show-LoginHint }
}

function Invoke-List {
    $install   = Get-ClaudeInstall
    $shortcuts = @(Get-Shortcuts)

    Write-Head 'Claude Desktop instances'
    if ($install) { Write-Host ('  install  : {0} {1}' -f $install.Type, $install.Version) }
    else          { Write-Warn2 'Claude Desktop not found.' }
    Write-Host ('  base dir : {0}' -f $Script:InstancesBase)
    Write-Host ''
    $row = '  {0,-14} {1,-9} {2,-8} {3,-9} {4,-5}'
    Write-Host ($row -f 'name', 'size', 'running', 'shortcut', 'task')
    Write-Host ($row -f 'default', '-', '-', 'built-in', '-')

    foreach ($n in (Get-Instances)) {
        $hasLnk  = if ($shortcuts | Where-Object { $_.Instance -eq $n }) { 'yes' } else { 'no' }
        $hasTask = if ($install -and $install.Type -eq 'MSIX') { if (Test-Task $n) { 'yes' } else { 'no' } } else { 'n/a' }
        $running = if (Test-InstanceRunning $n) { 'yes' } else { 'no' }
        Write-Host ($row -f $n, "$(Get-DirSizeMb (Get-InstanceDir $n)) MB", $running, $hasLnk, $hasTask)
    }
    Write-Host ''
}

function Invoke-Stop {
    param([string]$Name)
    Assert-InstanceName $Name
    if (-not (Test-InstanceRunning $Name)) { Write-Note "Instance '$Name' is not running."; return }
    if (-not (Stop-Instance $Name)) { throw "Instance '$Name' could not be closed." }
}

function Remove-InstanceArtifacts {
    <# Shortcuts, icon and data directory - the parts that need no elevation. #>
    param([string]$Name)
    foreach ($s in (Get-Shortcuts)) {
        if ($s.Instance -eq $Name) { Remove-Item $s.Path -Force -ErrorAction SilentlyContinue; Write-Ok "Shortcut removed: $($s.Path)" }
    }
    $ico = Join-Path $Script:IconsBase "$Name.ico"
    if (Test-Path $ico) { Remove-Item $ico -Force -ErrorAction SilentlyContinue }

    # Never follow a junction or symlink: a redirected instance folder must not turn
    # "delete this instance" into "delete whatever it points at".
    $dir  = Get-InstanceDir $Name
    $item = Get-Item -Path $dir -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$dir is a junction or symlink - refusing to delete through it. Remove the link yourself."
    }
    Remove-Item -Path $dir -Recurse -Force
    Write-Ok "Instance '$Name' removed."
}

function Invoke-Remove {
    param([string]$Name)
    Assert-InstanceName $Name
    $dir = Get-InstanceDir $Name
    if (-not (Test-Path $dir)) { throw "Instance '$Name' does not exist." }
    $install = Get-ClaudeInstall

    Write-Warn2 "This deletes $dir including its login, connectors and Cowork data."
    if (-not $Force) {
        $confirm = Read-Answer '  Type the instance name to confirm'
        if ($confirm -ne $Name) { Write-Note 'Cancelled.'; return }
    }

    $running = Test-InstanceRunning $Name
    if ($running -and -not $Force) {
        Write-Warn2 "Instance '$Name' is still running."
        $ok = Read-Answer '  Close it now? [y/N]'
        if ($ok -notmatch '^[yYjJ]') { Write-Note 'Cancelled.'; return }
    }

    # MSIX instances and their tasks live in elevated land: do the whole removal in
    # one elevated pass instead of prompting for UAC twice.
    $isMsix = $install -and $install.Type -eq 'MSIX'
    if ($isMsix -and -not (Test-Admin) -and ($running -or (Test-Task $Name))) {
        Write-Note 'Closing the instance and removing its task needs elevation (one UAC prompt)...'
        $rc = Invoke-Elevated -Cmd 'remove' -InstanceName $Name -AddForce
        if ($rc -ne 0) { throw "Removal was cancelled or failed (code $rc)." }
        if (Test-Path $dir) { throw "Elevated removal finished but $dir still exists." }
        Write-Ok "Instance '$Name' removed (task, shortcuts, icon and data)."
        return
    }

    if (-not (Stop-Instance $Name)) { throw 'Cannot delete a running instance. Close it first.' }
    if (Test-Task $Name) { Invoke-Unregister -Name $Name }
    Remove-InstanceArtifacts -Name $Name
}

function Invoke-CloneConfig {
    <# Copy claude_desktop_config.json (local MCP servers) between instances. #>
    param([string]$From, [string]$To)

    $install = Get-RequiredInstall
    if (-not $To -or -not $From) { throw 'Usage: clone-config <from> <to>   (use "default" for the built-in instance)' }
    if ($From -ne 'default') { Assert-InstanceName $From }
    if ($To   -ne 'default') { Assert-InstanceName $To }

    $srcDir = if ($From -eq 'default') { $install.ConfigDir } else { Get-InstanceDir $From }
    $dstDir = if ($To   -eq 'default') { $install.ConfigDir } else { Get-InstanceDir $To }
    $src = Join-Path $srcDir 'claude_desktop_config.json'
    $dst = Join-Path $dstDir 'claude_desktop_config.json'

    if (-not (Test-Path $src)) { throw "No config found at $src" }
    if (-not (Test-Path $dstDir)) { throw "Target instance '$To' does not exist." }

    try {
        $cfg = Get-Content $src -Raw | ConvertFrom-Json
        $servers = @()
        if ($cfg.mcpServers) { $servers = @($cfg.mcpServers.PSObject.Properties) }
        Write-Head "Config from '$From'"
        foreach ($s in $servers) {
            $envKeys = @()
            if ($s.Value.env) { $envKeys = @($s.Value.env.PSObject.Properties.Name) }
            $envNote = if ($envKeys.Count) { "env: $($envKeys -join ', ')" } else { 'no env' }
            Write-Host ('  {0,-24} {1}' -f $s.Name, $envNote)
        }
        if ($servers.Count -eq 0) { Write-Note 'No MCP servers in this config.' }
    } catch { Write-Warn2 "Could not parse config, copying anyway: $_" }

    Write-Host ''
    Write-Warn2 "Close the '$To' instance first - a running instance overwrites the file on exit."
    Write-Warn2 'Remote connectors are account-bound and will NOT come along - re-authorise them in the target.'
    if (-not $Force) {
        $ok = Read-Answer "  Copy to '$To' and overwrite its config? [y/N]"
        if ($ok -notmatch '^[yYjJ]') { Write-Note 'Cancelled.'; return }
    }
    if (Test-Path $dst) { Copy-Item $dst "$dst.bak" -Force; Write-Note "Backup: $dst.bak" }
    Copy-Item $src $dst -Force
    Write-Ok "Config copied to $dst"
}

function Invoke-Open {
    param([string]$Name)
    if ($Name -ne 'default') { Assert-InstanceName $Name }
    $install = Get-ClaudeInstall
    $dir = if ($Name -eq 'default' -and $install) { $install.ConfigDir } else { Get-InstanceDir $Name }
    if (-not (Test-Path $dir)) { throw "Not found: $dir" }
    explorer.exe $dir
}

function Invoke-Doctor {
    Write-Head "Claude Multiverse $($Script:Version) - diagnostics"
    Write-Note ('PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-Note ('Script: {0}' -f $PSCommandPath)

    $install = Get-ClaudeInstall
    if (-not $install) { Write-Fail 'Claude Desktop not found. Install from https://claude.ai/download'; return }

    Write-Ok ('Claude Desktop: {0} install, version {1}' -f $install.Type, $install.Version)
    Write-Note ('Executable : {0}' -f $install.Exe)
    Write-Note ('Config dir : {0}' -f $install.ConfigDir)

    if ($install.Type -eq 'MSIX') {
        if (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue) { Write-Ok 'Invoke-CommandInDesktopPackage available' }
        else { Write-Fail 'Invoke-CommandInDesktopPackage missing - Appx module not loaded?' }
        if (Test-AdminCapable) { Write-Ok 'Account is in the Administrators group' }
        else { Write-Fail 'Account is NOT an administrator - MSIX instances cannot be launched with this account' }
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) { Write-Ok 'ScheduledTasks module available' }
        else { Write-Warn2 'ScheduledTasks module missing - "register" will not work' }
    }

    if (Test-Path $Script:IconTool) { Write-Ok 'Icon tool present' } else { Write-Warn2 "Icon tool missing at $($Script:IconTool)" }

    $inst = Get-Instances
    if ($inst.Count) { Write-Ok "$($inst.Count) instance(s): $($inst -join ', ')" } else { Write-Note 'No instances yet - run "new".' }

    $shortcuts = @(Get-Shortcuts)
    if ($shortcuts.Count) { foreach ($s in $shortcuts) { Write-Note ('shortcut {0} -> {1}' -f (Split-Path $s.Path -Leaf), $s.Instance) } }
    if ($install.Type -eq 'MSIX') {
        foreach ($n in $inst) { if (Test-Task $n) { Write-Ok "task registered: $n" } else { Write-Note "no task: $n (UAC on launch)" } }
    }
    if (Test-Path $Script:ErrorLog) { Write-Note "Last launch errors: $($Script:ErrorLog)" }
    Write-Host ''
}

function Invoke-Help {
    Write-Head "Claude Multiverse $($Script:Version)"
    Write-Host '  Multiple isolated Claude Desktop instances on Windows.'
    Write-Host ''
    Write-Host '  new [name]                  Guided setup: directory, icon, task, shortcut'
    Write-Host '  launch <name>               Start an instance'
    Write-Host '  stop <name>                 Close an instance (all its processes)'
    Write-Host '  shortcut <name>             Desktop shortcut  [-Label "..."] [-Icon x.ico] [-StartMenu] [-Force]'
    Write-Host '  register <name>             Scheduled task so launches skip UAC (MSIX)'
    Write-Host '  unregister <name>           Remove that task'
    Write-Host '  clone-config <from> <to>    Copy local MCP config between instances ("default" = built-in)'
    Write-Host '  open <name>                 Open the instance data folder'
    Write-Host '  list                        Instances, size, running, shortcut and task status'
    Write-Host '  remove <name>               Delete an instance, its task, shortcuts and icon'
    Write-Host '  doctor                      Check the environment'
    Write-Host ''
    Write-Host '  No arguments = interactive menu.'
    Write-Host ''
}

function Invoke-Menu {
    while ($true) {
        Write-Head "Claude Multiverse $($Script:Version)"
        $inst = Get-Instances
        if ($inst.Count) { Write-Host "  Instances: $($inst -join ', ')" } else { Write-Host '  No instances yet.' }
        Write-Host ''
        Write-Host '  1  Create a new instance (guided)'
        Write-Host '  2  Launch an instance'
        Write-Host '  3  Create a shortcut'
        Write-Host '  4  List instances'
        Write-Host '  5  Clone MCP config between instances'
        Write-Host '  6  Stop an instance'
        Write-Host '  7  Remove an instance'
        Write-Host '  8  Diagnostics'
        Write-Host '  0  Exit'
        $c = Read-Answer '  Choice'
        try {
            switch ($c) {
                '1' { Invoke-New -Name (Read-Answer '  Instance name') }
                '2' { $n = Read-Answer "  Instance ($($inst -join ', '))"; if ($n) { Invoke-Launch -Name $n } }
                '3' { $n = Read-Answer "  Instance ($($inst -join ', '))"; if ($n) { Invoke-Shortcut -Name $n -Overwrite } }
                '4' { Invoke-List }
                '5' { $f = Read-Answer '  From (default or instance)'; $t = Read-Answer '  To (instance)'; Invoke-CloneConfig -From $f -To $t }
                '6' { $n = Read-Answer "  Instance ($($inst -join ', '))"; if ($n) { Invoke-Stop -Name $n } }
                '7' { $n = Read-Answer "  Instance ($($inst -join ', '))"; if ($n) { Invoke-Remove -Name $n } }
                '8' { Invoke-Doctor }
                '0' { return }
                default { }
            }
        }
        catch { Write-Fail $_.Exception.Message }
        Write-Host ''
        Read-Host '  Enter to continue' | Out-Null
    }
}

# ------------------------------------------------------------------ main ---

try {
    switch ($Command) {
        'menu'         { Invoke-Menu }
        'new'          { Invoke-New         -Name $Instance }
        'launch'       { Invoke-Launch      -Name $Instance }
        'stop'         { Invoke-Stop        -Name $Instance }
        'list'         { Invoke-List }
        'shortcut'     { Invoke-Shortcut    -Name $Instance -DisplayLabel $Label -IconPath $Icon }
        'register'     { Invoke-Register    -Name $Instance }
        'unregister'   { Invoke-Unregister  -Name $Instance }
        'remove'       { Invoke-Remove      -Name $Instance }
        'clone-config' { Invoke-CloneConfig -From $Instance -To $Target }
        'open'         { Invoke-Open        -Name $Instance }
        'doctor'       { Invoke-Doctor }
        default        { Invoke-Help }
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Fail $msg
    if (Test-HiddenConsole) {
        # Started from a shortcut or the scheduled task: no console to read, so log
        # the error and show it in a message box instead of waiting for a key press.
        try {
            New-Item -ItemType Directory -Force -Path $Script:InstancesBase | Out-Null
            "$(Get-Date -Format s)  $Command $Instance  $msg" | Add-Content -Path $Script:ErrorLog
        } catch { }
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show("$msg`n`nLogged to $($Script:ErrorLog)", 'Claude Multiverse',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } catch { }
    }
    elseif (($Command -in 'register', 'unregister', 'launch', 'stop', 'remove') -and (Test-Admin)) {
        # Elevated helper window that would otherwise vanish with the error.
        Read-Host '  Enter to close' | Out-Null
    }
    exit 1
}
