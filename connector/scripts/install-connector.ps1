<#
.SYNOPSIS
    Install (or remove) the vacti connector as a Windows service.

.DESCRIPTION
    The connector is the only vacti component that runs inside a customer network
    (see ..\cmd\connector\main.go). This script downloads the signed release .exe
    for the host, verifies it against SHA256SUMS, enrols it once with the
    dashboard-issued token, and registers it with the Service Control Manager as
    the "VactiConnector" service so it reconnects on boot. The Go binary detects
    it is running under the SCM and installs a service control handler
    (cmd\connector\platform_windows.go), so Stop/Shutdown are handled cleanly.

    Re-running the script converges the install (updates the binary and service)
    instead of duplicating it. Enrollment is skipped once an identity exists,
    because the install token is single-use.

.PARAMETER Token
    Dashboard enrollment id (a single-use install token). Required on first install.

.PARAMETER ApiUrl
    Control-plane base URL the connector enrols against. Required on first install.

.PARAMETER Cidrs
    Comma-separated CIDRs this connector is expected to reach. Informational only;
    the authoritative reach is the per-session grant the control plane signs.

.PARAMETER Version
    Connector release to install (default: latest connector-v* on GitHub).

.PARAMETER Repo
    GitHub repo to fetch releases from (default: anggipradana/vacti-distro).

.PARAMETER Binary
    Install this local .exe instead of downloading one (air-gapped / testing).

.PARAMETER ReleaseBase
    Override the release asset base URL (for a mirror, e.g. HuggingFace).

.PARAMETER Prefix
    Path prefix for every install location (sandbox install for testing: skips the
    admin check and all sc.exe/registry calls, still renders the plan).

.PARAMETER DryRun
    Print what would happen; touch nothing.

.PARAMETER Uninstall
    Stop and delete the service, then remove the binary and state.

.EXAMPLE
    .\install-connector.ps1 -Token <id> -ApiUrl https://cp.example
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$ApiUrl,
    [string]$Cidrs,
    [string]$Version,
    [string]$Repo = 'anggipradana/vacti-distro',
    [string]$Binary = $env:VACTI_CONNECTOR_BINARY,
    [string]$ReleaseBase = $env:VACTI_CONNECTOR_RELEASE_BASE,
    [string]$Prefix = $env:VACTI_CONNECTOR_PREFIX,
    [switch]$DryRun,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------- #
# constants + layout
# ---------------------------------------------------------------------------- #

$ServiceName = 'VactiConnector'
$BinName     = 'vacti-connector.exe'

# Sandbox mode (a Prefix is set): redirect paths, skip the admin check and the
# SCM/registry mutations so the installer can be exercised without a real system.
$Sandbox = [bool]$Prefix

$ProgramData = if ($Prefix) { $Prefix } else { $env:ProgramData }
if (-not $ProgramData) { $ProgramData = 'C:\ProgramData' }

$RootDir   = Join-Path $ProgramData 'Vacti\connector'
$BinDir    = Join-Path $RootDir 'bin'
$StateDir  = $RootDir
$ExePath   = Join-Path $BinDir $BinName
$StateJson = Join-Path $StateDir 'state.json'

# ---------------------------------------------------------------------------- #
# helpers
# ---------------------------------------------------------------------------- #

function Write-Step { param([string]$Message) Write-Host "==> $Message" }
function Write-Skip { param([string]$Message) Write-Host "    [skip] $Message" }
function Die        { param([string]$Message) Write-Error $Message; exit 1 }

# Invoke-Priv runs a native command, or prints it in sandbox/dry-run mode.
function Invoke-Priv {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    if ($Sandbox -or $DryRun) {
        Write-Skip "$FilePath $($Arguments -join ' ')"
        return 0
    }
    & $FilePath @Arguments
    return $LASTEXITCODE
}

function Test-Admin {
    if ($Sandbox -or $DryRun) { return }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Die 'must run as Administrator (registers a Windows service and writes to ProgramData)'
    }
}

function Get-HostArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { return 'amd64' }
    }
}

# ---------------------------------------------------------------------------- #
# version resolution + download
# ---------------------------------------------------------------------------- #

function Resolve-Version {
    if ($Version)  { return $Version }
    if ($Binary)   { return 'local' }
    Write-Step "resolving latest connector release from $Repo"
    $api = "https://api.github.com/repos/$Repo/releases"
    $releases = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'vacti-connector-installer' }
    $tag = ($releases |
        Where-Object { $_.tag_name -like 'connector-v*' } |
        Select-Object -First 1).tag_name
    if (-not $tag) { Die "no connector-v* release found in $Repo" }
    $v = $tag -replace '^connector-v', ''
    Write-Step "latest connector release is $v"
    return $v
}

# Get-ConnectorBinary leaves the connector .exe at $Destination.
function Get-ConnectorBinary {
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Arch,
          [Parameter(Mandatory)][string]$Ver)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

    if ($Binary) {
        if (-not (Test-Path $Binary)) { Die "-Binary $Binary does not exist" }
        Write-Step "using local binary $Binary"
        Copy-Item -Path $Binary -Destination $Destination -Force
        return
    }
    if ($DryRun) {
        Write-Step "[dry-run] would download vacti-connector $Ver for windows/$Arch"
        New-Item -ItemType File -Force -Path $Destination | Out-Null
        return
    }
    if ($Arch -ne 'amd64') {
        Die "no published connector binary for windows/$Arch; pass -Binary to install a local build"
    }

    $base  = if ($ReleaseBase) { $ReleaseBase } else { "https://github.com/$Repo/releases/download/connector-v$Ver" }
    $asset = "vacti-connector_${Ver}_windows_amd64.zip"
    $work  = Join-Path ([IO.Path]::GetTempPath()) ("vacti-conn-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        Write-Step "downloading $asset"
        Invoke-WebRequest -Uri "$base/$asset" -OutFile (Join-Path $work $asset) -UseBasicParsing
        Write-Step 'downloading SHA256SUMS'
        Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -UseBasicParsing

        $want = (Get-Content (Join-Path $work 'SHA256SUMS') |
            Where-Object { $_ -match [regex]::Escape($asset) + '$' } |
            Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if (-not $want) { Die "SHA256SUMS has no entry for $asset" }
        $got = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $work $asset)).Hash.ToLower()
        if ($want.ToLower() -ne $got) { Die "checksum mismatch for $asset (want $want, got $got)" }
        Write-Step 'checksum verified'

        Expand-Archive -Path (Join-Path $work $asset) -DestinationPath $work -Force
        $exe = Join-Path $work $BinName
        if (-not (Test-Path $exe)) { Die "archive did not contain $BinName" }
        Copy-Item -Path $exe -Destination $Destination -Force
    }
    finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------- #
# enrollment
# ---------------------------------------------------------------------------- #

function Invoke-Enroll {
    if (Test-Path $StateJson) {
        Write-Step "existing identity found at $StateJson; skipping enrollment"
        return
    }
    if ($DryRun) {
        Write-Step "[dry-run] would enrol with the supplied token against $ApiUrl"
        return
    }
    if (-not $Token)  { Die 'no identity yet and -Token was not supplied' }
    if (-not $ApiUrl) { Die 'no identity yet and -ApiUrl was not supplied' }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Write-Step "enrolling connector (one-time) against $ApiUrl"

    $saved = @{
        id    = $env:VACTI_INSTALL_ID
        api   = $env:VACTI_API_URL
        state = $env:VACTI_CONNECTOR_STATE
        cidrs = $env:VACTI_CONNECTOR_CIDRS
    }
    $env:VACTI_INSTALL_ID      = $Token
    $env:VACTI_API_URL         = $ApiUrl
    $env:VACTI_CONNECTOR_STATE = $StateDir
    $env:VACTI_CONNECTOR_CIDRS = $Cidrs
    try {
        $proc = Start-Process -FilePath $ExePath -PassThru -WindowStyle Hidden
        $ok = $false
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-Path $StateJson) { $ok = $true; break }
            if ($proc.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        if (-not $ok) { Die 'enrollment failed: no identity was written (check the token and -ApiUrl)' }
        Write-Step 'enrollment succeeded'
    }
    finally {
        $env:VACTI_INSTALL_ID      = $saved.id
        $env:VACTI_API_URL         = $saved.api
        $env:VACTI_CONNECTOR_STATE = $saved.state
        $env:VACTI_CONNECTOR_CIDRS = $saved.cidrs
    }
}

# ---------------------------------------------------------------------------- #
# service registration
# ---------------------------------------------------------------------------- #

function Install-Service {
    # sc.exe needs the quoted exe path as a single binPath= token. The service
    # reads its state dir from a per-service Environment value so it never depends
    # on the machine environment.
    $binPath = "`"$ExePath`""
    $exists = $false
    if (-not ($Sandbox -or $DryRun)) {
        & sc.exe query $ServiceName *> $null
        $exists = ($LASTEXITCODE -eq 0)
    }

    if ($exists) {
        Write-Step "service $ServiceName exists; updating configuration"
        Invoke-Priv -FilePath 'sc.exe' -Arguments @('config', $ServiceName, "binPath=", $binPath, 'start=', 'auto') | Out-Null
    }
    else {
        Write-Step "creating service $ServiceName"
        Invoke-Priv -FilePath 'sc.exe' -Arguments @('create', $ServiceName, "binPath=", $binPath, 'start=', 'auto', 'DisplayName=', 'Vacti Connector') | Out-Null
    }
    Invoke-Priv -FilePath 'sc.exe' -Arguments @('description', $ServiceName, 'Vacti outbound-only in-network connector') | Out-Null

    # Per-service environment: VACTI_CONNECTOR_STATE for the SCM-started process.
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if ($Sandbox -or $DryRun) {
        Write-Skip "set $svcKey\Environment = VACTI_CONNECTOR_STATE=$StateDir"
    }
    else {
        New-ItemProperty -Path $svcKey -Name 'Environment' -PropertyType MultiString `
            -Value @("VACTI_CONNECTOR_STATE=$StateDir") -Force | Out-Null
    }

    Write-Step "starting service $ServiceName"
    if ($Sandbox -or $DryRun) {
        Write-Skip "sc.exe start $ServiceName"
    }
    else {
        & sc.exe start $ServiceName *> $null  # ignore "already running"
    }
}

function Show-Status {
    if ($Sandbox -or $DryRun) { Write-Step 'sandbox/dry-run: skipping live status check'; return }
    & sc.exe query $ServiceName
    $running = (& sc.exe query $ServiceName | Select-String 'STATE' | Select-String 'RUNNING')
    if ($running) { Write-Step "connector service is RUNNING" }
    else { Write-Warning "connector service is not RUNNING yet; check the service and $StateDir" }
}

# ---------------------------------------------------------------------------- #
# uninstall
# ---------------------------------------------------------------------------- #

function Uninstall-Connector {
    Write-Step 'uninstalling vacti connector'
    if (-not ($Sandbox -or $DryRun)) {
        & sc.exe stop $ServiceName   *> $null
        & sc.exe delete $ServiceName *> $null
    }
    else {
        Write-Skip "sc.exe stop $ServiceName"
        Write-Skip "sc.exe delete $ServiceName"
    }
    Remove-Item -Recurse -Force $RootDir -ErrorAction SilentlyContinue
    Write-Step 'removed service, binary and state'
}

# ---------------------------------------------------------------------------- #
# main
# ---------------------------------------------------------------------------- #

function Invoke-Main {
    if ($Uninstall) {
        Test-Admin
        Uninstall-Connector
        return
    }

    if (-not (Test-Path $StateJson) -and -not $Token -and -not $DryRun) {
        Die '-Token is required for a first install (or pass -Uninstall)'
    }

    Test-Admin
    $arch = Get-HostArch
    $ver = Resolve-Version
    Write-Step "installing vacti connector $ver for windows/$arch"
    if ($Cidrs) { Write-Step "declared reach (informational): $Cidrs" }

    Get-ConnectorBinary -Destination $ExePath -Arch $arch -Ver $ver
    Write-Step "installed binary at $ExePath"

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Invoke-Enroll
    Install-Service
    Show-Status
    Write-Step 'done'
}

Invoke-Main
