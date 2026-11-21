<# : batch launcher, the PowerShell updater follows below
@echo off
title ATM10 Updater
set "ATM10_UPDATER_SOURCE=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText('%~f0')))"
set "updater_exit=%errorlevel%"
echo.
pause
exit /b %updater_exit%
#>
param([switch]$Background)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleasePage = 'https://github.com/petterblaasmo/atm10-client-mods/releases/latest'
$ManifestUrl = if ($env:ATM10_MANIFEST_URL) { $env:ATM10_MANIFEST_URL } else { "$ReleasePage/download/manifest.json" }
$SupportedSchema = 1
$SettingsFile = Join-Path $env:APPDATA 'ATM10-Updater\settings.json'
$InstallDir = Join-Path $env:LOCALAPPDATA 'ATM10-Updater'
$InstalledScript = Join-Path $InstallDir 'ATM10-Updater.ps1'
$LogFile = Join-Path $InstallDir 'updater.log'
$MaxLogBytes = 256KB
$TaskName = 'ATM10 Updater'
$CheckIntervalMinutes = 30
$NotifierAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$StateFileName = '.atm10-updater-state.json'
$AllowedPath = '^mods/[A-Za-z0-9._+\-]+\.jar$'
$AllowedReplaces = '^[A-Za-z0-9._+\-]{3,}\*?[A-Za-z0-9._+\-]*\.jar$'
$InstanceNamePattern = 'All the Mods 10|ATM10|ATM 10'
$UserAgent = 'ATM10-Updater/2.0'

# ---------------------------------------------------------------- output

function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes) {
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
    }
    Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format s) $Message" -Encoding UTF8
}

function Write-Step([string]$Message) { if ($Background) { Write-Log $Message } else { Write-Host "==> $Message" -ForegroundColor Cyan } }
function Write-Done([string]$Message) { if ($Background) { Write-Log "  $Message" } else { Write-Host "    $Message" -ForegroundColor Green } }
function Write-Note([string]$Message) { if ($Background) { Write-Log "  $Message" } else { Write-Host "    $Message" -ForegroundColor Yellow } }

function Show-Notification([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $escape = { param($text) [Security.SecurityElement]::Escape($text) }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$(& $escape $Title)</text><text>$(& $escape $Body)</text></binding></visual></toast>")
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($NotifierAppId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    }
    catch {
        Write-Log "notification failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- settings and instance

function Get-Settings {
    $settings = @{}
    if (Test-Path -LiteralPath $SettingsFile) {
        try { (Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } }
        catch { Write-Log "ignoring unreadable settings: $($_.Exception.Message)" }
    }
    $settings
}

function Save-Settings([hashtable]$Settings) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsFile) | Out-Null
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
}

function Test-Instance([string]$Path) {
    $Path -and (Test-Path -LiteralPath (Join-Path $Path 'minecraftinstance.json')) -and (Test-Path -LiteralPath (Join-Path $Path 'mods'))
}

function Find-Candidates {
    $root = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -match $InstanceNamePattern -and (Test-Instance $_.FullName) } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { $_.FullName })
}

function Select-FromList([string[]]$Paths) {
    Write-Host 'Several ATM10 instances were found:'
    for ($i = 0; $i -lt $Paths.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $Paths[$i]) }
    while ($true) {
        $answer = Read-Host "Which one do you play on the server? (1-$($Paths.Count))"
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Paths.Count) { return $Paths[$index - 1] }
    }
}

function Select-WithDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select your ATM10 instance folder (the one that contains the "mods" folder)'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'No instance folder selected.' }
    $dialog.SelectedPath
}

function Resolve-Instance([hashtable]$Settings) {
    if ($env:ATM10_INSTANCE) { return $env:ATM10_INSTANCE }
    if (Test-Instance $Settings.instance) { return $Settings.instance }
    if ($Background) { throw 'No ATM10 instance chosen yet; run ATM10-Updater.cmd once.' }
    $candidates = @(Find-Candidates)
    $chosen = switch ($candidates.Count) {
        0 { Write-Note 'Could not find ATM10 in the default CurseForge folder.'; Select-WithDialog }
        1 { $candidates[0] }
        default { Select-FromList $candidates }
    }
    if (-not (Test-Instance $chosen)) { throw "Not a valid ATM10 instance folder: $chosen" }
    $Settings.instance = $chosen
    Save-Settings $Settings
    $chosen
}

function Test-GameRunning([string]$Instance) {
    $instancePattern = [regex]::Escape($Instance.TrimEnd('\')) + '(\\|"|\s|$)'
    [bool](Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $instancePattern })
}

# ---------------------------------------------------------------- manifest and downloads

function Get-Manifest {
    $manifest = Invoke-RestMethod -Uri $ManifestUrl -UserAgent $UserAgent -UseBasicParsing
    if ($manifest.schema -ne $SupportedSchema) { throw "This updater is outdated. Download the newest one from $ReleasePage" }
    foreach ($file in $manifest.files) {
        if ($file.path -notmatch $AllowedPath) { throw "Refusing unsafe path in manifest: $($file.path)" }
        if ($file.replaces -and $file.replaces -notmatch $AllowedReplaces) { throw "Refusing unsafe pattern in manifest: $($file.replaces)" }
        if ($file.url -notmatch '^https://') { throw "Refusing non-HTTPS download: $($file.url)" }
    }
    if ($manifest.updater -and $manifest.updater.url -notmatch '^https://') { throw "Refusing non-HTTPS updater: $($manifest.updater.url)" }
    $manifest
}

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Save-VerifiedDownload([string]$Url, [string]$Sha256, [string]$Target) {
    $temporary = "$Target.download"
    Invoke-WebRequest -Uri $Url -OutFile $temporary -UserAgent $UserAgent -UseBasicParsing
    if ((Get-Sha256 $temporary) -ne $Sha256) {
        Remove-Item -LiteralPath $temporary -Force
        throw "Download of $(Split-Path $Target -Leaf) is corrupted (checksum mismatch). Try again later."
    }
    Move-Item -LiteralPath $temporary -Destination $Target -Force
}

function Get-ManagedPaths([string]$StateFile) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
    try { return @((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).managed | Where-Object { $_ -match $AllowedPath }) } catch { return @() }
}

# ---------------------------------------------------------------- mod sync

function Get-PendingChanges([string]$Instance, $Manifest) {
    $modsDir = Join-Path $Instance 'mods'
    $wanted = @($Manifest.files | ForEach-Object { $_.path })
    $installs = @($Manifest.files | Where-Object {
        $target = Join-Path $Instance $_.path
        -not (Test-Path -LiteralPath $target) -or (Get-Sha256 $target) -ne $_.sha256
    })
    $removals = @(foreach ($file in $Manifest.files) {
        if (-not $file.replaces) { continue }
        $keep = Split-Path $file.path -Leaf
        Get-ChildItem -LiteralPath $modsDir -File -Filter $file.replaces | Where-Object { $_.Name -ne $keep } | ForEach-Object { $_.FullName }
    })
    $removals += @(Get-ManagedPaths (Join-Path $modsDir $StateFileName) |
        Where-Object { $wanted -notcontains $_ } |
        ForEach-Object { Join-Path $Instance $_ } |
        Where-Object { Test-Path -LiteralPath $_ })
    $removals = @($removals | Select-Object -Unique)
    @{ installs = $installs; removals = $removals; count = $installs.Count + $removals.Count }
}

function Invoke-Changes([string]$Instance, $Manifest, [hashtable]$Pending) {
    foreach ($file in $Pending.installs) {
        Save-VerifiedDownload $file.url $file.sha256 (Join-Path $Instance $file.path)
        Write-Done "installed $(Split-Path $file.path -Leaf)"
    }
    foreach ($path in $Pending.removals) {
        Remove-Item -LiteralPath $path -Force
        Write-Done "removed $(Split-Path $path -Leaf)"
    }
    $state = @{ version = $Manifest.version; managed = @($Manifest.files | ForEach-Object { $_.path }) }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Instance "mods\$StateFileName") -Encoding UTF8
}

# ---------------------------------------------------------------- background updates

function Update-InstalledUpdater($Manifest) {
    if (-not $Manifest.updater -or -not (Test-Path -LiteralPath $InstalledScript)) { return }
    if ((Get-Sha256 $InstalledScript) -eq $Manifest.updater.sha256) { return }
    Save-VerifiedDownload $Manifest.updater.url $Manifest.updater.sha256 $InstalledScript
    Write-Done 'updated the background updater to the newest version'
}

function Test-AutoUpdateInstalled {
    (Test-Path -LiteralPath $InstalledScript) -and [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Register-AutoUpdate([string]$Source) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $Source -Destination $InstalledScript -Force
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -Background"
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $user),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $CheckIntervalMinutes))
    )
    $options = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $options -Principal $principal `
        -Description 'Keeps the ATM10 server mods up to date.' -Force | Out-Null
}

function Initialize-AutoUpdate([hashtable]$Settings) {
    $source = $env:ATM10_UPDATER_SOURCE
    if (-not $source -or -not (Test-Path -LiteralPath $source)) { return }
    if ($null -eq $Settings.autoUpdate) {
        Write-Host ''
        $answer = Read-Host 'Keep the server mods updated automatically in the background? (Y/n)'
        $Settings.autoUpdate = $answer -notmatch '^\s*n'
        Save-Settings $Settings
    }
    if (-not $Settings.autoUpdate -or (Test-AutoUpdateInstalled)) { return }
    Register-AutoUpdate $source
    Write-Done "Automatic updates are on: checks at sign-in and every $CheckIntervalMinutes minutes, with a notification when mods change."
}

# ---------------------------------------------------------------- main

function Invoke-Update {
    $settings = Get-Settings
    Write-Step 'Finding your ATM10 instance'
    $instance = Resolve-Instance $settings
    Write-Done $instance

    Write-Step 'Checking for server mod updates'
    $manifest = Get-Manifest
    Write-Done "latest server mods: $($manifest.version) ($($manifest.pack))"
    Update-InstalledUpdater $manifest

    $pending = Get-PendingChanges $instance $manifest
    if ($pending.count -gt 0 -and (Test-GameRunning $instance)) {
        if (-not $Background) { throw 'Minecraft is running from this instance. Close the game and run the updater again.' }
        if ($settings.notifiedVersion -ne $manifest.version) {
            Show-Notification 'ATM10 update ready' 'Close Minecraft and the new server mods install automatically within 30 minutes.'
            $settings.notifiedVersion = $manifest.version
            Save-Settings $settings
        }
        Write-Note 'update waiting until Minecraft is closed'
        return
    }

    Write-Step 'Updating mods'
    if ($pending.count -eq 0) { Write-Done 'Everything is already up to date.' }
    else {
        Invoke-Changes $instance $manifest $pending
        if ($Background) { Show-Notification 'ATM10 mods updated' "Server mods $($manifest.version) installed. You are ready to play." }
    }

    if (-not $Background) {
        Initialize-AutoUpdate $settings
        Write-Host ''
        Write-Host 'Done! You can start the game from CurseForge now.' -ForegroundColor Green
    }
}

try {
    Invoke-Update
}
catch {
    if ($Background) { Write-Log "update failed: $($_.Exception.Message)" }
    else {
        Write-Host ''
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
