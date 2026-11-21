<# : batch launcher, the PowerShell updater follows below
@echo off
title ATM10 Updater
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText('%~f0')))"
set "updater_exit=%errorlevel%"
echo.
pause
exit /b %updater_exit%
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleasePage = 'https://github.com/petterblaasmo/atm10-client-mods/releases/latest'
$ManifestUrl = if ($env:ATM10_MANIFEST_URL) { $env:ATM10_MANIFEST_URL } else { "$ReleasePage/download/manifest.json" }
$SupportedSchema = 1
$SettingsFile = Join-Path $env:APPDATA 'ATM10-Updater\settings.json'
$StateFileName = '.atm10-updater-state.json'
$AllowedPath = '^mods/[A-Za-z0-9._+\-]+\.jar$'
$AllowedReplaces = '^[A-Za-z0-9._+\-]{3,}\*?[A-Za-z0-9._+\-]*\.jar$'
$InstanceNamePattern = 'All the Mods 10|ATM10|ATM 10'
$UserAgent = 'ATM10-Updater/1.0'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Done([string]$Message) { Write-Host "    $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Test-Instance([string]$Path) {
    $Path -and (Test-Path -LiteralPath (Join-Path $Path 'minecraftinstance.json')) -and (Test-Path -LiteralPath (Join-Path $Path 'mods'))
}

function Get-SavedInstance {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $null }
    try { return (Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json).instance } catch { return $null }
}

function Save-Instance([string]$Path) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsFile) | Out-Null
    @{ instance = $Path } | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
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
    if (-not (Test-Instance $dialog.SelectedPath)) { throw "That folder is not a CurseForge instance: $($dialog.SelectedPath)" }
    $dialog.SelectedPath
}

function Resolve-Instance {
    if ($env:ATM10_INSTANCE) { return $env:ATM10_INSTANCE }
    $saved = Get-SavedInstance
    if (Test-Instance $saved) { return $saved }
    $candidates = Find-Candidates
    $chosen = switch ($candidates.Count) {
        0 { Write-Note 'Could not find ATM10 in the default CurseForge folder.'; Select-WithDialog }
        1 { $candidates[0] }
        default { Select-FromList $candidates }
    }
    Save-Instance $chosen
    $chosen
}

function Assert-GameClosed([string]$Instance) {
    $running = Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Instance) }
    if ($running) { throw 'Minecraft is running from this instance. Close the game and run the updater again.' }
}

function Get-Manifest {
    $manifest = Invoke-RestMethod -Uri $ManifestUrl -UserAgent $UserAgent -UseBasicParsing
    if ($manifest.schema -ne $SupportedSchema) { throw "This updater is outdated. Download the newest one from $ReleasePage" }
    foreach ($file in $manifest.files) {
        if ($file.path -notmatch $AllowedPath) { throw "Refusing unsafe path in manifest: $($file.path)" }
        if ($file.replaces -and $file.replaces -notmatch $AllowedReplaces) { throw "Refusing unsafe pattern in manifest: $($file.replaces)" }
        if ($file.url -notmatch '^https://') { throw "Refusing non-HTTPS download: $($file.url)" }
    }
    $manifest
}

function Get-ManagedPaths([string]$StateFile) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
    try { return @((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).managed | Where-Object { $_ -match $AllowedPath }) } catch { return @() }
}

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Install-File([string]$Instance, $File) {
    $target = Join-Path $Instance $File.path
    if ((Test-Path -LiteralPath $target) -and (Get-Sha256 $target) -eq $File.sha256) { return $false }
    $temporary = "$target.download"
    Invoke-WebRequest -Uri $File.url -OutFile $temporary -UserAgent $UserAgent -UseBasicParsing
    if ((Get-Sha256 $temporary) -ne $File.sha256) {
        Remove-Item -LiteralPath $temporary -Force
        throw "Download of $($File.path) is corrupted (checksum mismatch). Try again later."
    }
    Move-Item -LiteralPath $temporary -Destination $target -Force
    $true
}

function Remove-Replaced([string]$ModsDir, $File) {
    if (-not $File.replaces) { return }
    $keep = Split-Path $File.path -Leaf
    Get-ChildItem -LiteralPath $ModsDir -File -Filter $File.replaces |
        Where-Object { $_.Name -ne $keep } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Done "removed old $($_.Name)" }
}

function Sync-Instance([string]$Instance, $Manifest) {
    $modsDir = Join-Path $Instance 'mods'
    $stateFile = Join-Path $modsDir $StateFileName
    $wanted = @($Manifest.files | ForEach-Object { $_.path })
    $changes = 0

    foreach ($file in $Manifest.files) {
        if (Install-File $Instance $file) { Write-Done "installed $(Split-Path $file.path -Leaf)"; $changes++ }
        Remove-Replaced $modsDir $file
    }
    foreach ($stale in (Get-ManagedPaths $stateFile | Where-Object { $wanted -notcontains $_ })) {
        $path = Join-Path $Instance $stale
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Done "removed $(Split-Path $stale -Leaf)"; $changes++ }
    }
    @{ version = $Manifest.version; managed = $wanted } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    $changes
}

try {
    Write-Step 'Finding your ATM10 instance'
    $instance = Resolve-Instance
    Write-Done $instance
    Assert-GameClosed $instance

    Write-Step 'Checking for server mod updates'
    $manifest = Get-Manifest
    Write-Done "latest server mods: $($manifest.version) ($($manifest.pack))"

    Write-Step 'Updating mods'
    $changes = Sync-Instance $instance $manifest
    if ($changes -eq 0) { Write-Done 'Everything is already up to date.' }
    Write-Host ''
    Write-Host 'Done! You can start the game from CurseForge now.' -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
