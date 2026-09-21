param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [string]$DataRoot = "",

    [string]$PurgeMarker = "",

    [switch]$RemoveAllData
)

$ErrorActionPreference = "Continue"
$cleanupLog = Join-Path ([IO.Path]::GetTempPath()) "AetherStudy-uninstall.log"
try { Start-Transcript -Path $cleanupLog -Append -Force | Out-Null } catch {}
$backendRoot = Join-Path $InstallRoot "runtime\backend"
$nodePath = Join-Path $backendRoot "runtime\node\node.exe"
$distIndex = Join-Path $backendRoot "dist\index.js"
$uninstallScript = Join-Path $backendRoot "scripts\medclaw-uninstall.mjs"
$userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if ([string]::IsNullOrWhiteSpace($userProfile)) {
    $userProfile = $env:USERPROFILE
}
$stateRoot = Join-Path $userProfile ".openclaw"
$env:OPENCLAW_STATE_DIR = $stateRoot

# Inno Setup passes the interactive uninstall choice through a temporary marker.
# This avoids relying on two conditional UninstallRun entries, which can be
# evaluated before the custom options form state is available.
if (-not $RemoveAllData -and -not [string]::IsNullOrWhiteSpace($PurgeMarker) -and
    (Test-Path -LiteralPath $PurgeMarker)) {
    $markerValue = (Get-Content -LiteralPath $PurgeMarker -Raw -ErrorAction SilentlyContinue).Trim()
    if ($markerValue -eq 'all') {
        $RemoveAllData = $true
    }
}
Write-Host "RemoveAllData=$RemoveAllData"

function Remove-DataTree {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }
    Write-Host "Removing user data: $Path"
    # Clear read-only attributes and grant the current administrator full access.
    & attrib.exe -R "$Path\*" /S /D 2>$null | Out-Null
    & takeown.exe /F $Path /R /D Y 2>$null | Out-Null
    & icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        # PowerShell can leave a stubborn junction/locked tree behind; use the
        # native remover as a second pass before retrying.
        & cmd.exe /d /c "rmdir /s /q `"$Path`"" 2>$null
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $Path) {
        Write-Warning "Unable to remove user data directory: $Path"
    }
}

# Stop the installed client before removing QSettings. Otherwise a still-running
# process can write its settings back while exiting after the uninstall cleanup.
$clientPath = [IO.Path]::GetFullPath((Join-Path $InstallRoot "client\AetherStudy.exe"))
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @("AetherStudy.exe", "Aether_ClawDESK.exe", "ClawDESK.exe") -and
    $_.ExecutablePath -and
    [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
        ([IO.Path]::GetDirectoryName($clientPath) + [IO.Path]::DirectorySeparatorChar),
        [System.StringComparison]::OrdinalIgnoreCase
    )
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}

# Also stop Node processes whose command line still points into this install.
# This covers partial installs where the service uninstall command is missing.
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf(
        $backendRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}

# Stop service/watchdog processes that may not expose the backend path in their
# command line (NSSM/schtasks can launch these through an intermediate host).
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '(?i)openclaw|medclaw|gateway|aetherstudy|aether_clawdesk' -or
    ($_.CommandLine -and $_.CommandLine -match '(?i)openclaw|medclaw|18789')
} | ForEach-Object {
    if ($_.ProcessId -ne $PID) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '(?i)openclaw|medclaw|aether' -or $_.DisplayName -match '(?i)openclaw|medclaw|aether'
} | ForEach-Object {
    Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
}

if ((Test-Path -LiteralPath $nodePath) -and (Test-Path -LiteralPath $uninstallScript)) {
    $uninstallArguments = @(
        $uninstallScript,
        "--pkg-root", $backendRoot,
        "--state-dir", $stateRoot
    )
    if ($RemoveAllData) {
        $uninstallArguments += "--all"
    }
    & $nodePath @uninstallArguments
} elseif ((Test-Path -LiteralPath $nodePath) -and (Test-Path -LiteralPath $distIndex)) {
    & $nodePath $distIndex gateway uninstall
}

Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.Equals($nodePath, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}

if ($RemoveAllData) {
    # Do not rely on Inno's post-uninstall directory phase: user data may be
    # outside {app}, and locked/readonly files can make that phase incomplete.
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    $roamingAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ApplicationData
    )
    $dataRoots = @(
        $stateRoot,
        # OpenClaw profiles and legacy Windows locations.
        (Join-Path $userProfile ".openclaw-dev"),
        (Join-Path $userProfile ".openclaw-medbuddy"),
        (Join-Path $userProfile ".openclaw-aetherstudy"),
        (Join-Path $localAppData "openclaw"),
        (Join-Path $localAppData "OpenClaw"),
        (Join-Path $roamingAppData "openclaw"),
        (Join-Path $roamingAppData "OpenClaw"),
        (Join-Path $localAppData "AetherStudy"),
        (Join-Path $localAppData "Aether_ClawDESK"),
        (Join-Path $localAppData "AetherMED\Aether study"),
        (Join-Path $localAppData "AetherMED\AetherStudy"),
        (Join-Path $localAppData "AetherMED\Aether_ClawDESK"),
        (Join-Path $localAppData "AetherMED\ClawDESK"),
        (Join-Path $localAppData "AetherMED"),
        (Join-Path $localAppData "AETHERMIND"),
        (Join-Path $localAppData "MedClaw"),
        (Join-Path $roamingAppData "AetherStudy"),
        (Join-Path $roamingAppData "Aether_ClawDESK"),
        (Join-Path $roamingAppData "AetherMED\Aether study"),
        (Join-Path $roamingAppData "AetherMED\AetherStudy"),
        (Join-Path $roamingAppData "AetherMED\Aether_ClawDESK"),
        (Join-Path $roamingAppData "AetherMED\ClawDESK"),
        (Join-Path $roamingAppData "AetherMED"),
        (Join-Path $roamingAppData "AETHERMIND"),
        (Join-Path $roamingAppData "MedClaw")
    )
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
        $dataRoots += $DataRoot
    }

    # Profiles are user-defined, so discover any additional .openclaw* state
    # directories instead of relying on a fixed list of profile names.
    $dataRoots += Get-ChildItem -LiteralPath $userProfile -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.openclaw*' } |
        Select-Object -ExpandProperty FullName

    $dataRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique | ForEach-Object {
        Remove-DataTree -Path ([IO.Path]::GetFullPath($_))
    }

    # QSettings uses HKCU\Software\<organization>\<application> on Windows.
    # Remove current and historical names, but preserve unrelated AetherMED apps.
    foreach ($applicationName in @(
        "Aether study", "Aether study Government", "AetherStudy", "Aether_ClawDESK", "ClawDESK", "MedClaw"
    )) {
        $settingsPath = "HKCU:\Software\AetherMED\$applicationName"
        Remove-Item -LiteralPath $settingsPath -Recurse -Force
    }
    $organizationPath = "HKCU:\Software\AetherMED"
    if ((Test-Path -LiteralPath $organizationPath) -and
        -not (Get-ChildItem -LiteralPath $organizationPath | Select-Object -First 1)) {
        Remove-Item -LiteralPath $organizationPath -Recurse -Force
    }
}

exit 0
