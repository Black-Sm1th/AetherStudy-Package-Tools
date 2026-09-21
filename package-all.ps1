[CmdletBinding()]
param(
    [string]$BackendRoot = 'E:\openclaw\MedClaw',
    [string]$ClientRoot = 'E:\MedClaw',
    [ValidateSet('Main', 'Government')]
    [string]$Edition = 'Main',
    [switch]$Fast,
    [switch]$Clean,
    [switch]$SkipBackend,
    [switch]$SkipClient,
    [string]$KbEnvSource = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WorkRoot = $PSScriptRoot
$RepoRoot = $WorkRoot
$EditionKey = $Edition.ToLowerInvariant()
$IsGovernmentEdition = $Edition -eq 'Government'
$OutputRoot = Join-Path $WorkRoot $(if ($IsGovernmentEdition) { 'output-government' } else { 'output' })
$LogRoot = Join-Path $WorkRoot 'logs'
$IssPath = Join-Path $WorkRoot 'MedClaw.iss'
$NodeRunner = Join-Path $WorkRoot 'node-runner\node.exe'
$NodeRunnerPnpm = Join-Path $WorkRoot 'node-runner\pnpm.cmd'
$NodeRunnerPnpmModule = Join-Path $WorkRoot 'node-runner\node_modules\pnpm\bin\pnpm.mjs'
$Iscc = Join-Path $WorkRoot 'tools\Inno\ISCC.exe'
$ClientSource = Join-Path $WorkRoot $(if ($IsGovernmentEdition) { 'client-source-government' } else { 'client-source-current' })
$ClientBuild = Join-Path $WorkRoot $(if ($IsGovernmentEdition) { 'client-build-government' } else { 'client-build-current' })
$ClientPayloadRelative = if ($IsGovernmentEdition) { 'package\client-government' } else { 'package\client' }
$ClientPayload = Join-Path $WorkRoot $ClientPayloadRelative
$ViewerPayload = Join-Path $ClientPayload 'viewer-web\dist'
$ClientRuntimeDllRoot = Join-Path $WorkRoot 'client-runtime'
$ClientRuntimeDlls = @('libcrypto-1_1-x64.dll', 'libssl-1_1-x64.dll')
$DeployConfig = Join-Path $WorkRoot 'medclaw.deploy.json'
$BackendPackage = Join-Path $BackendRoot 'dist\prod\medbuddy'
$KbEnvDestination = Join-Path $BackendPackage 'python-envs\kb'
$BackendBootstrap = Join-Path $BackendRoot 'bootstrap.ps1'
$InstallerBootstrap = Join-Path $WorkRoot 'package\tools\bootstrap.ps1'
$BuildClientCmd = Join-Path $WorkRoot 'build-client-current.cmd'
$KbToolsInstallScript = Join-Path $WorkRoot 'package\tools\install-kb-tools.mjs'
$PwshArchive = Join-Path $WorkRoot 'cache\PowerShell-7.4.6-win-x64.zip'
$NssmCache = Join-Path $WorkRoot 'cache\nssm.exe'
$PackageStatePath = Join-Path $WorkRoot $(if ($IsGovernmentEdition) { 'cache\package-state-government.json' } else { 'cache\package-state.json' })
$TotalTimer = [Diagnostics.Stopwatch]::StartNew()

function Format-Duration {
    param([Parameter(Mandatory)] [TimeSpan]$Elapsed)
    return '{0:00}:{1:00}:{2:00}' -f [math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds
}

function Get-TextSha256 {
    param([Parameter(Mandatory)] [string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TreeFingerprint {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }

    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $lines = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        "$relative|$($file.Length)|$hash"
    }
    return Get-TextSha256 -Text ($lines -join "`n")
}

function Get-GitSourceFingerprint {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string[]]$ExtraTrees = @()
    )

    Push-Location $Root
    try {
        $head = (& git.exe rev-parse HEAD 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read Git HEAD in $Root"
        }

        # Include the actual tracked diff, not only `git status`, so editing an already-dirty file
        # changes the fingerprint. Hash untracked files separately because Git diff omits them.
        $trackedDiff = (& git.exe diff --binary --no-ext-diff HEAD -- .) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read Git changes in $Root"
        }
        $untrackedFiles = @(& git.exe ls-files --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read untracked Git files in $Root"
        }

        $parts = New-Object Collections.Generic.List[string]
        $parts.Add("HEAD=$head")
        $parts.Add("DIFF=$trackedDiff")
        foreach ($relative in ($untrackedFiles | Sort-Object)) {
            $filePath = Join-Path $Root $relative
            if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                $parts.Add("UNTRACKED=$relative|$((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash)")
            }
        }
        foreach ($extraTree in $ExtraTrees) {
            $parts.Add("EXTRA=$extraTree|$(Get-TreeFingerprint -Path (Join-Path $Root $extraTree))")
        }
        return Get-TextSha256 -Text ($parts -join "`n")
    }
    finally {
        Pop-Location
    }
}

function Read-PackageState {
    if (-not (Test-Path -LiteralPath $PackageStatePath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $PackageStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "Ignoring invalid package state: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Write-PackageState {
    param($State)

    $json = $State | ConvertTo-Json -Depth 10
    $tempPath = "$PackageStatePath.tmp"
    [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $PackageStatePath -Force
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [string[]]$Arguments = @(),
        [Parameter()] [string]$WorkingDirectory = $RepoRoot
    )

    $commandTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n> $FilePath $($Arguments -join ' ')" -ForegroundColor Cyan
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
        }
    }
    finally {
        Pop-Location
        $commandTimer.Stop()
        Write-Host "[time] $(Split-Path -Leaf $FilePath): $(Format-Duration $commandTimer.Elapsed)" -ForegroundColor DarkGray
    }
}

function Assert-Path {
    param([Parameter(Mandatory)] [string]$Path, [string]$Label = 'Required path')
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Get-ClientVersion {
    param([Parameter(Mandatory)] [string]$Root)

    $versionFile = Join-Path $Root 'updatecontroller.cpp'
    Assert-Path $versionFile 'Client version source'
    $text = [IO.File]::ReadAllText($versionFile)
    $match = [regex]::Match(
        $text,
        'clientVersion\s*\(\s*QStringLiteral\("v?(?<version>\d+(?:\.\d+){2,3})"\)'
    )
    if (-not $match.Success) {
        throw "Client version was not found in $versionFile"
    }
    return $match.Groups['version'].Value
}

function Get-NextVersion {
    param(
        [Parameter(Mandatory)] [string]$ClientVersion,
        [Parameter()] $PreviousState
    )

    $packageCount = 1
    if ($null -ne $PreviousState -and [string]$PreviousState.clientVersion -eq $ClientVersion) {
        $packageCount = [int]$PreviousState.packageCount
        if ($packageCount -lt 1) {
            $previousVersion = [string]$PreviousState.packageVersion
            $versionPattern = '^{0}[.-](?<count>\d+)$' -f [regex]::Escape($ClientVersion)
            $previousMatch = [regex]::Match($previousVersion, $versionPattern)
            $packageCount = if ($previousMatch.Success) {
                [int]$previousMatch.Groups['count'].Value
            } else {
                0
            }
        }
        $packageCount++
    }

    return "$ClientVersion-$packageCount"
}

function Set-InstallerVersion {
    param([Parameter(Mandatory)] [string]$Version)
    $text = [IO.File]::ReadAllText($IssPath)
    $versionPattern = [regex]'#define MyAppVersion "\d+\.\d+\.\d+[.-]\d+"'
    if (-not $versionPattern.IsMatch($text)) {
        throw "Failed to find MyAppVersion in $IssPath"
    }
    $updated = $versionPattern.Replace($text, "#define MyAppVersion `"$Version`"", 1)
    if ($updated -ne $text) {
        [IO.File]::WriteAllText($IssPath, $updated, [Text.UTF8Encoding]::new($false))
    }
}

function Assert-CleanPiEmbeddedBundles {
    param([Parameter(Mandatory)] [string]$DistRoot)

    $bundleFiles = @(Get-ChildItem -LiteralPath $DistRoot -Filter 'pi-embedded-*.js' -File -ErrorAction SilentlyContinue)
    if ($bundleFiles.Count -eq 0) {
        throw "No pi-embedded bundles found in $DistRoot"
    }

    $queueBundles = @($bundleFiles | Where-Object { $_.Name -like 'pi-embedded-queue.runtime-*.js' })
    $mainBundles = @($bundleFiles | Where-Object { $_.Name -notlike 'pi-embedded-queue.runtime-*.js' })
    if ($queueBundles.Count -ne 1 -or $mainBundles.Count -ne 1) {
        throw "Unexpected pi-embedded bundle set. Expected one main and one queue bundle; found: $($bundleFiles.Name -join ', ')"
    }

    if (-not (Select-String -LiteralPath $mainBundles[0].FullName -Pattern 'sessionOutputDir' -SimpleMatch -Quiet)) {
        throw "The main pi-embedded bundle does not contain the current sessionOutputDir injection: $($mainBundles[0].Name)"
    }

    foreach ($pattern in @('gateway-cli-*.js', 'agent-runner-utils-*.js')) {
        $chainBundles = @(Get-ChildItem -LiteralPath $DistRoot -Filter $pattern -File -ErrorAction SilentlyContinue)
        if ($chainBundles.Count -eq 0 -or -not ($chainBundles | Where-Object {
            Select-String -LiteralPath $_.FullName -Pattern 'sessionOutputDir' -SimpleMatch -Quiet
        })) {
            throw "The chat.send output-directory chain is missing from production bundle pattern: $pattern"
        }
    }

    Write-Host ("Validated pi-embedded bundle set: {0}" -f ($bundleFiles.Name -join ', ')) -ForegroundColor Green
}

New-Item -ItemType Directory -Path $OutputRoot, $LogRoot -Force | Out-Null
$logPath = Join-Path $LogRoot ("package-{0}-{1}.log" -f $EditionKey, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $logPath -Force | Out-Null

try {
    Assert-Path $IssPath 'Inno Setup project'
    Assert-Path $Iscc 'Inno Setup compiler'
    Assert-Path $NodeRunner 'Bundled Node runner'
    Assert-Path $NodeRunnerPnpm 'Bundled pnpm launcher'
    Assert-Path $NodeRunnerPnpmModule 'Bundled pnpm module'
    Assert-Path $KbToolsInstallScript 'KB tool installation script'
    Assert-Path $PwshArchive 'Cached portable PowerShell archive'
    Assert-Path $BackendBootstrap 'Backend installer bootstrap script'
    Assert-Path $DeployConfig 'Private deployment configuration'
    $clientVersion = Get-ClientVersion -Root $ClientRoot
    Write-Host "Client version: v$clientVersion" -ForegroundColor Green

    try {
        $deployConfigObject = Get-Content -LiteralPath $DeployConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Private deployment configuration is not valid JSON: $DeployConfig ($($_.Exception.Message))"
    }
    foreach ($requiredProperty in @('embedding', 'tavilyApiKey', 'overwriteIdentity')) {
        if ($null -eq $deployConfigObject.PSObject.Properties[$requiredProperty]) {
            throw "Private deployment configuration is missing required property: $requiredProperty"
        }
    }

    $mode = if ($Fast) { 'FAST' } else { 'RELEASE' }
    Write-Host "Package mode: $mode" -ForegroundColor Green
    Write-Host "Package edition: $Edition" -ForegroundColor Green

    $fingerprintTimer = [Diagnostics.Stopwatch]::StartNew()
    $backendFingerprint = Get-GitSourceFingerprint -Root $BackendRoot
    $clientFingerprint = Get-GitSourceFingerprint -Root $ClientRoot -ExtraTrees @('viewer-web\dist')
    $fingerprintTimer.Stop()
    Write-Host "[time] Source fingerprint: $(Format-Duration $fingerprintTimer.Elapsed)" -ForegroundColor DarkGray

    $previousState = Read-PackageState
    $backendPayloadReady = Test-Path -LiteralPath (Join-Path $BackendPackage 'dist\index.js')
    $clientPayloadReady = (Test-Path -LiteralPath (Join-Path $ClientPayload 'AetherStudy.exe')) -and
        (Test-Path -LiteralPath (Join-Path $ViewerPayload 'index.html'))
    $backendChanged = $null -eq $previousState -or $previousState.backendFingerprint -ne $backendFingerprint
    $clientChanged = $null -eq $previousState -or $previousState.clientFingerprint -ne $clientFingerprint

    $BuildBackend = -not $SkipBackend -and (-not $Fast -or $Clean -or $backendChanged -or -not $backendPayloadReady)
    $BuildClient = -not $SkipClient -and (-not $Fast -or $Clean -or $clientChanged -or -not $clientPayloadReady)

    Write-Host "Backend: $(if ($BuildBackend) { 'build' } else { 'reuse' }) (changed=$backendChanged, ready=$backendPayloadReady)"
    Write-Host "Client:  $(if ($BuildClient) { 'build' } else { 'reuse' }) (changed=$clientChanged, ready=$clientPayloadReady)"

    # Seed the offline NSSM cache before a clean backend build removes dist/prod.
    $existingNssm = Join-Path $BackendPackage 'runtime\nssm\nssm.exe'
    if (-not (Test-Path -LiteralPath $NssmCache) -and (Test-Path -LiteralPath $existingNssm)) {
        Copy-Item -LiteralPath $existingNssm -Destination $NssmCache -Force
        Write-Host "Cached NSSM from the existing production runtime." -ForegroundColor Green
    }

    if ($BuildBackend) {
        $backendTimer = [Diagnostics.Stopwatch]::StartNew()
        Assert-Path (Join-Path $BackendRoot 'package.json') 'Backend project'
        $sourceDist = Join-Path $BackendRoot 'dist'
        if (Test-Path -LiteralPath $sourceDist) {
            Write-Host "Cleaning generated backend dist before build: $sourceDist" -ForegroundColor Yellow
            Remove-Item -LiteralPath $sourceDist -Recurse -Force
        }
        Invoke-Checked -FilePath 'pnpm.cmd' -Arguments @('install') -WorkingDirectory $BackendRoot
        Invoke-Checked -FilePath 'pnpm.cmd' -Arguments @('build') -WorkingDirectory $BackendRoot
        $packArguments = @(
            (Join-Path $BackendRoot 'scripts\pack-tenant-prod.mjs'),
            '--tenant', 'medbuddy',
            '--pwsh-from', $PwshArchive
        )
        if (Test-Path -LiteralPath $NssmCache) {
            $packArguments += @('--nssm-from', $NssmCache)
        }
        Invoke-Checked -FilePath $NodeRunner -Arguments $packArguments -WorkingDirectory $BackendRoot
        if (-not (Test-Path -LiteralPath $NssmCache)) {
            Copy-Item -LiteralPath (Join-Path $BackendPackage 'runtime\nssm\nssm.exe') -Destination $NssmCache -Force
        }
        $backendTimer.Stop()
        Write-Host "[time] Backend build: $(Format-Duration $backendTimer.Elapsed)" -ForegroundColor Green
    }
    else {
        Write-Host 'Reusing current backend production runtime.' -ForegroundColor Yellow
    }

    # Keep credentials outside the source repository. pack-tenant-prod.mjs ships the
    # example template by design; replace only the production payload copy.
    Copy-Item -LiteralPath $DeployConfig -Destination (Join-Path $BackendPackage 'medclaw.deploy.example.json') -Force
    Write-Host 'Packaged private deployment configuration.' -ForegroundColor Green

    Assert-Path (Join-Path $BackendPackage 'dist\index.js') 'Backend production bundle'
    Assert-Path (Join-Path $BackendPackage 'runtime\node\node.exe') 'Backend bundled Node'
    Assert-Path (Join-Path $BackendPackage 'scripts\medclaw-deploy.mjs') 'Backend deploy script'
    Assert-Path (Join-Path $BackendPackage 'scripts\medclaw-gateway-restart.mjs') 'Backend restart script'
    Assert-Path (Join-Path $BackendPackage 'scripts\medclaw-uninstall.mjs') 'Backend uninstall script'
    Assert-Path (Join-Path $BackendPackage 'node_modules\@line\bot-sdk') '@line/bot-sdk dependency'
    Assert-Path (Join-Path $BackendPackage 'dist\extensions\kb\index.js') 'Bundled KB plugin'
    Assert-Path (Join-Path $BackendPackage 'dist\extensions\kb\openclaw.plugin.json') 'Bundled KB plugin manifest'
    Assert-Path (Join-Path $BackendPackage 'extensions\kb\requirements.txt') 'Bundled KB Python requirements'
    $deployerScript = Join-Path $BackendPackage 'scripts\medclaw-deploy.mjs'
    $deployerText = Get-Content -LiteralPath $deployerScript -Raw -Encoding UTF8
    if ($deployerText -notmatch 'EAGER_PROVISION_PLUGINS\s*=\s*\[[^\]]*\"kb\"') {
        throw 'Bundled deploy script does not eagerly provision the KB Python environment.'
    }
    if ([string]::IsNullOrWhiteSpace($KbEnvSource)) {
        $KbEnvSource = Join-Path $env:USERPROFILE '.openclaw\envs\kb'
    }
    Assert-Path (Join-Path $KbEnvSource 'python.exe') 'Verified Windows KB Python environment'
    & robocopy.exe $KbEnvSource $KbEnvDestination /MIR /R:2 /W:1 /XD '__pycache__' /XF '*.pyc' '*.pyo' '*.pdb'
    if ($LASTEXITCODE -ge 8) {
        throw "KB Python environment mirror failed with robocopy exit code $LASTEXITCODE"
    }
    Assert-Path (Join-Path $KbEnvDestination 'python.exe') 'Packaged KB Python environment'
    Assert-Path (Join-Path $BackendPackage 'dist\extensions\kb\node_modules\@lancedb\lancedb-win32-x64-msvc\lancedb.win32-x64-msvc.node') 'Bundled KB LanceDB native runtime'
    Assert-CleanPiEmbeddedBundles -DistRoot (Join-Path $BackendPackage 'dist')
    # Keep the installer bootstrap synchronized with the backend source. A stale desktop copy once
    # reintroduced an immediate gateway restart and caused SERVICE_PAUSED on clean installations.
    Copy-Item -LiteralPath $BackendBootstrap -Destination $InstallerBootstrap -Force
    Invoke-Checked -FilePath (Join-Path $BackendPackage 'runtime\node\node.exe') -Arguments @(
        (Join-Path $BackendPackage 'dist\index.js'), '--version'
    ) -WorkingDirectory $BackendPackage

    $kbVerificationConfig = Join-Path $WorkRoot ("kb-config-verification-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath (Join-Path $BackendPackage 'openclaw.tenant.json') -Destination $kbVerificationConfig -Force
        Invoke-Checked -FilePath (Join-Path $BackendPackage 'runtime\node\node.exe') -Arguments @(
            $KbToolsInstallScript,
            '--config', $kbVerificationConfig,
            '--pkg-root', $BackendPackage
        ) -WorkingDirectory $BackendPackage
        Invoke-Checked -FilePath (Join-Path $BackendPackage 'runtime\node\node.exe') -Arguments @(
            $KbToolsInstallScript,
            '--verify-only',
            '--config', $kbVerificationConfig,
            '--pkg-root', $BackendPackage
        ) -WorkingDirectory $BackendPackage
    }
    finally {
        Remove-Item -LiteralPath $kbVerificationConfig -Force -ErrorAction SilentlyContinue
    }

    if ($BuildClient) {
        $clientTimer = [Diagnostics.Stopwatch]::StartNew()
        Assert-Path (Join-Path $ClientRoot 'MedClaw.pro') 'Client project'
        $incrementalClient = $Fast -and -not $Clean
        if (-not $incrementalClient -and (Test-Path -LiteralPath $ClientSource)) {
            Remove-Item -LiteralPath $ClientSource -Recurse -Force
        }
        if (-not $incrementalClient -and (Test-Path -LiteralPath $ClientBuild)) {
            Remove-Item -LiteralPath $ClientBuild -Recurse -Force
        }
        New-Item -ItemType Directory -Path $ClientSource -Force | Out-Null

        & robocopy.exe $ClientRoot $ClientSource /MIR /XD build 'build-*' .git .vs .agents node_modules /XF '*.user' /R:2 /W:1
        if ($LASTEXITCODE -ge 8) {
            throw "Client source copy failed with robocopy exit code $LASTEXITCODE"
        }

        $buildClientCommandLine = '"{0}" {1}' -f $BuildClientCmd, $Edition
        Invoke-Checked -FilePath 'cmd.exe' -Arguments @('/d', '/c', $buildClientCommandLine) -WorkingDirectory $WorkRoot
        $builtClient = Join-Path $ClientBuild 'release\AetherStudy.exe'
        $builtClientDir = Split-Path -Parent $builtClient
        $builtViewerDist = Join-Path $ClientSource 'viewer-web\dist'
        Assert-Path $builtClient 'Built client executable'
        Assert-Path (Join-Path $builtViewerDist 'index.html') 'Built viewer index'
        foreach ($viewerDirectory in @('assets', 'lib', 'markdown', 'pdf')) {
            Assert-Path (Join-Path $builtViewerDist $viewerDirectory) "Built viewer $viewerDirectory directory"
        }
        # Mirror the Qt deployment output into the installer payload. A plain
        # exe copy leaves stale Qt5 DLLs from previous package runs, allowing
        # mixed Qt5/Qt6 runtimes to be shipped. Exclude build intermediates and
        # viewer-web because that tree is packaged separately below.
        New-Item -ItemType Directory -Path $ClientPayload -Force | Out-Null
        & robocopy.exe $builtClientDir $ClientPayload /MIR /XD 'viewer-web' /XF '*.obj' '*.cpp' '*.h' '*.res' /R:2 /W:1
        if ($LASTEXITCODE -ge 8) {
            throw "Client Qt runtime mirror failed with robocopy exit code $LASTEXITCODE"
        }
        foreach ($obsoleteClient in @('Aether_ClawDESK.exe', 'Aether_ClawDESK.candidate.exe', 'MedClaw.exe')) {
            Remove-Item -LiteralPath (Join-Path $ClientPayload $obsoleteClient) -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath $builtClient -Destination (Join-Path $ClientPayload 'AetherStudy.exe') -Force
        Copy-Item -LiteralPath $builtClient -Destination (Join-Path $ClientPayload 'AetherStudy.candidate.exe') -Force

        # The desktop client resolves the local document viewer relative to AetherStudy.exe as
        # viewer-web/dist. Mirror the complete generated tree so removed or renamed frontend
        # bundles cannot survive from an older package.
        New-Item -ItemType Directory -Path $ViewerPayload -Force | Out-Null
        & robocopy.exe $builtViewerDist $ViewerPayload /MIR /R:2 /W:1
        if ($LASTEXITCODE -ge 8) {
            throw "Viewer payload mirror failed with robocopy exit code $LASTEXITCODE"
        }
        $clientTimer.Stop()
        Write-Host "[time] Client build: $(Format-Duration $clientTimer.Elapsed)" -ForegroundColor Green
    }
    else {
        Write-Host 'Reusing current client payload.' -ForegroundColor Yellow
    }

    # office.json is no longer distributed. Remove any copy left by an older
    # package run so fast/incremental builds cannot silently ship stale settings.
    $staleOfficeConfig = Join-Path $ClientPayload 'config\office.json'
    if (Test-Path -LiteralPath $staleOfficeConfig) {
        Remove-Item -LiteralPath $staleOfficeConfig -Force
    }
    if (Test-Path -LiteralPath $staleOfficeConfig) {
        throw "Obsolete client office configuration is still present: $staleOfficeConfig"
    }
    $staleOfficeConfigDirectory = Split-Path -Parent $staleOfficeConfig
    if ((Test-Path -LiteralPath $staleOfficeConfigDirectory) -and
        -not (Get-ChildItem -LiteralPath $staleOfficeConfigDirectory -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $staleOfficeConfigDirectory -Force
    }

    # OpenSSL 1.1 is loaded by the Qt client at runtime. Always place these
    # dependencies beside AetherStudy.exe, including fast/reuse package runs.
    foreach ($runtimeDll in $ClientRuntimeDlls) {
        $runtimeDllSource = Join-Path $ClientRuntimeDllRoot $runtimeDll
        $runtimeDllDestination = Join-Path $ClientPayload $runtimeDll
        Assert-Path $runtimeDllSource "Client runtime dependency $runtimeDll"
        Copy-Item -LiteralPath $runtimeDllSource -Destination $runtimeDllDestination -Force
        Assert-Path $runtimeDllDestination "Packaged client runtime dependency $runtimeDll"
    }

    Assert-Path (Join-Path $ClientPayload 'AetherStudy.exe') 'Client installer payload'
    Assert-Path (Join-Path $ViewerPayload 'index.html') 'Client viewer index payload'
    foreach ($viewerDirectory in @('assets', 'lib', 'markdown', 'pdf')) {
        Assert-Path (Join-Path $ViewerPayload $viewerDirectory) "Client viewer $viewerDirectory payload"
    }
    $viewerFileCount = @(Get-ChildItem -LiteralPath $ViewerPayload -Recurse -File).Count
    Write-Host "Packaged client/viewer-web/dist ($viewerFileCount files)." -ForegroundColor Green

    $version = Get-NextVersion -ClientVersion $clientVersion -PreviousState $previousState
    Set-InstallerVersion $version
    $compressionMode = if ($Fast) { 'lzma2/fast, non-solid' } else { 'lzma2/ultra64, solid' }
    Write-Host "`nInstaller version: $version" -ForegroundColor Green
    Write-Host "Compression: $compressionMode" -ForegroundColor Green
    $isccArguments = @('/Qp', "/O$OutputRoot")
    if ($Fast) {
        $isccArguments += '/DFastPackage=1'
    }
    $installerPrefix = if ($IsGovernmentEdition) { 'AetherStudy-Government-Setup' } else { 'AetherStudy-Setup' }
    $isccArguments += "/DClientPayloadDir=$ClientPayloadRelative"
    $isccArguments += "/DInstallerNamePrefix=$installerPrefix"
    $isccArguments += $IssPath
    Invoke-Checked -FilePath $Iscc -Arguments $isccArguments -WorkingDirectory $RepoRoot

    $installer = Join-Path $OutputRoot "$installerPrefix-$version-x64.exe"
    Assert-Path $installer 'Generated installer'
    $file = Get-Item -LiteralPath $installer
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash

    $state = [ordered]@{
        schema = 2
        edition = $Edition
        backendFingerprint = if ($BuildBackend) { $backendFingerprint } elseif ($null -ne $previousState) { $previousState.backendFingerprint } else { $null }
        clientFingerprint = if ($BuildClient) { $clientFingerprint } elseif ($null -ne $previousState) { $previousState.clientFingerprint } else { $null }
        clientVersion = $clientVersion
        packageCount = [int]([regex]::Match($version, '\d+$').Value)
        packageVersion = $version
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-PackageState -State $state
    $TotalTimer.Stop()

    Write-Host "`nPackage completed." -ForegroundColor Green
    Write-Host "Path:    $($file.FullName)"
    Write-Host "Edition: $Edition"
    Write-Host "Version: $version"
    Write-Host ("Size:    {0:N2} MB" -f ($file.Length / 1MB))
    Write-Host "SHA256:  $hash"
    Write-Host "Log:     $logPath"
    Write-Host "Total:   $(Format-Duration $TotalTimer.Elapsed)"
}
catch {
    $TotalTimer.Stop()
    Write-Host "`nPackaging failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $logPath" -ForegroundColor Yellow
    Write-Host "Elapsed: $(Format-Duration $TotalTimer.Elapsed)" -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
