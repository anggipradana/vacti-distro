# install-connector.Tests.ps1 - Pester smoke for install-connector.ps1.
#
# Exercises the installer in dry-run + sandbox (Prefix) mode so it needs no admin
# rights, no network and no real service. The connector binary is never executed
# here (the shared Go binary's live enrollment is covered by the Linux/macOS
# install-connector.test.sh): the enrollment path is reached via its skip branch
# by pre-seeding state.json. These tests assert the installer parses, renders the
# sc.exe VactiConnector registration, installs the binary file, is idempotent, and
# uninstalls cleanly.
#
# Run: Invoke-Pester -Path connector/scripts/install-connector.Tests.ps1

BeforeAll {
    $script:Here   = Split-Path -Parent $PSCommandPath
    $script:Script = Join-Path $Here 'install-connector.ps1'

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("vacti-conn-test-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $Work | Out-Null

    # A placeholder binary file: it is only ever copied by the installer, never run.
    $script:Stub = Join-Path $Work 'vacti-connector-stub.exe'
    'placeholder' | Set-Content -Path $Stub -Encoding Ascii

    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

    function Invoke-Installer {
        param([string]$Prefix, [string[]]$InstallerArgs)
        $all = @('-NoProfile', '-NonInteractive', '-File', $script:Script,
                 '-Binary', $script:Stub, '-Prefix', $Prefix) + $InstallerArgs
        $out = & $psExe @all 2>&1
        return @{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
    }

    # Pre-seed an identity so Invoke-Enroll takes its skip branch (no execution).
    function Seed-State {
        param([string]$Prefix)
        $state = Join-Path $Prefix 'Vacti\connector'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        '{"connectorId":"t","token":"t","relayUrl":"wss://x/","grantKey":"AAAA","install":"d"}' |
            Set-Content -Path (Join-Path $state 'state.json') -Encoding Ascii
    }
}

AfterAll {
    Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
}

Describe 'install-connector.ps1' {

    It 'parses without syntax errors' {
        $tokens = $null; $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
    }

    It 'dry-run plans the VactiConnector service registration without touching the system' {
        $prefix = Join-Path $script:Work 'dry'
        $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-DryRun', '-Token', 't', '-ApiUrl', 'https://cp.example')
        $r.Code | Should -Be 0
        $r.Out  | Should -Match 'sc\.exe'
        $r.Out  | Should -Match 'VactiConnector'
        $r.Out  | Should -Match 'binPath='
        $r.Out  | Should -Match '\[skip\]'
    }

    It 'sandbox install writes the binary and registers the service (enroll skipped when identity exists)' {
        $prefix = Join-Path $script:Work 'install'
        Seed-State -Prefix $prefix
        $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-Token', 't', '-ApiUrl', 'https://cp.example', '-Cidrs', '10.0.0.0/24')
        $r.Code | Should -Be 0
        (Join-Path $prefix 'Vacti\connector\bin\vacti-connector.exe') | Should -Exist
        $r.Out  | Should -Match 'skipping enrollment'
        $r.Out  | Should -Match 'VactiConnector'
    }

    It 're-run is idempotent' {
        $prefix = Join-Path $script:Work 'install'
        $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-Token', 't', '-ApiUrl', 'https://cp.example')
        $r.Code | Should -Be 0
        (Join-Path $prefix 'Vacti\connector\bin\vacti-connector.exe') | Should -Exist
    }

    It 'dry-run on an existing install leaves the binary untouched' {
        $prefix = Join-Path $script:Work 'install'
        $exe = Join-Path $prefix 'Vacti\connector\bin\vacti-connector.exe'
        'live-binary' | Set-Content -Path $exe -Encoding Ascii  # differs from the stub
        $before = (Get-FileHash -Algorithm SHA256 -Path $exe).Hash
        $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-DryRun')
        $r.Code | Should -Be 0
        (Get-FileHash -Algorithm SHA256 -Path $exe).Hash | Should -Be $before
        $u = Invoke-Installer -Prefix $prefix -InstallerArgs @('-Uninstall', '-DryRun')
        $u.Code | Should -Be 0
        $exe | Should -Exist
    }

    It 'reads -Token/-ApiUrl from env so the iwr | iex one-liner works' {
        $prefix = Join-Path $script:Work 'envdefault'
        $env:VACTI_INSTALL_ID = 'envtoken000000000001'
        $env:VACTI_API_URL    = 'https://cp.example'
        try {
            $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-DryRun')
        } finally {
            Remove-Item env:VACTI_INSTALL_ID, env:VACTI_API_URL -ErrorAction SilentlyContinue
        }
        $r.Code | Should -Be 0
        $r.Out  | Should -Match 'would enrol with the supplied token against https://cp\.example'
    }

    It 'uninstall removes the install tree' {
        $prefix = Join-Path $script:Work 'install'
        $r = Invoke-Installer -Prefix $prefix -InstallerArgs @('-Uninstall')
        $r.Code | Should -Be 0
        (Join-Path $prefix 'Vacti\connector') | Should -Not -Exist
    }
}
