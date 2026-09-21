param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$legacyInstallRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA "Programs\AetherStudy")
).TrimEnd('\')
$installRoots = @($installRootFull)
if (-not $legacyInstallRoot.Equals($installRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    $installRoots += $legacyInstallRoot
}

$targetExecutables = @()
$lockTargets = @()
foreach ($root in $installRoots) {
    $backendRoot = Join-Path $root "runtime\backend"
    $backendNode = Join-Path $backendRoot "runtime\node\node.exe"
    $targetExecutables += @(
        $backendNode,
        (Join-Path $root "client\AetherStudy.exe"),
        (Join-Path $root "client\Aether_ClawDESK.exe")
    )
    $lockTargets += @(
        $backendNode,
        (Join-Path $backendRoot "dist\extensions\kb\node_modules\@lancedb\lancedb-win32-x64-msvc\lancedb.win32-x64-msvc.node")
    )
}
$scheduledTasks = @("OpenClaw Gateway", "MedClaw Gateway Watchdog")
$gatewayServicePrefix = "AetherClawGateway"
$gatewayPort = 18789

$logDir = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Test-PathEquals {
    param([string]$Left, [string]$Right)

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        return [System.IO.Path]::GetFullPath($Left).Equals(
            [System.IO.Path]::GetFullPath($Right),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Test-IsUnderInstallRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        foreach ($root in $installRoots) {
            if ($fullPath.StartsWith(
                $root + '\',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Test-CommandLineReferencesInstallRoot {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }
    foreach ($root in $installRoots) {
        if ($CommandLine.IndexOf(
            $root,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0) {
            return $true
        }
    }
    return $false
}

function Stop-GatewayServices {
    try {
        $services = @(Get-Service -Name "$gatewayServicePrefix*" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name.Equals($gatewayServicePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith($gatewayServicePrefix + '-', [System.StringComparison]::OrdinalIgnoreCase)
        })
    } catch {
        Write-Log "Gateway service scan failed: $($_.Exception.Message)"
        return
    }

    foreach ($service in $services) {
        try {
            $service.Refresh()
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Write-Log "Gateway service '$($service.Name)' is already stopped."
                continue
            }

            Write-Log "Stopping Gateway service '$($service.Name)' (status: $($service.Status))."
            Stop-Service -InputObject $service -Force -ErrorAction Stop
            $service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(20)
            )
            $service.Refresh()
            Write-Log "Gateway service '$($service.Name)' stopped."
        } catch {
            Write-Log "Failed to stop Gateway service '$($service.Name)': $($_.Exception.Message)"
        }
    }
}

function Stop-AndDeleteScheduledTasks {
    $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
    foreach ($task in $scheduledTasks) {
        foreach ($action in @("/End", "/Delete /F")) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $schtasks
            $psi.Arguments = "$action /TN `"$task`""
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            try {
                $process = [System.Diagnostics.Process]::Start($psi)
                $process.WaitForExit()
                Write-Log "Scheduled task action '$action' for '$task' exited $($process.ExitCode)."
            } catch {
                Write-Log "Scheduled task action '$action' for '$task' failed: $($_.Exception.Message)"
            }
        }
    }
}

function Get-GatewayPortProcessIds {
    $ids = @{}
    try {
        Get-NetTCPConnection -LocalPort $gatewayPort -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $ids[[int]$_.OwningProcess] = $true
        }
    } catch {
        Write-Log "Gateway port scan unavailable: $($_.Exception.Message)"
    }
    return $ids
}

function Get-TargetProcesses {
    $found = @{}
    $gatewayProcessIds = Get-GatewayPortProcessIds

    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            $processId = [int]$_.ProcessId
            if ($processId -eq $PID) {
                return
            }

            $executablePath = [string]$_.ExecutablePath
            $commandLine = [string]$_.CommandLine
            $isExactTarget = $false
            foreach ($target in $targetExecutables) {
                if (Test-PathEquals -Left $executablePath -Right $target) {
                    $isExactTarget = $true
                    break
                }
            }

            $isInstalledProcess = $isExactTarget -or (Test-IsUnderInstallRoot -Path $executablePath)
            $isLauncher = $_.Name -match '^(node|cmd|powershell|pwsh|wscript|cscript)\.exe$'
            $referencesInstall = $isLauncher -and (Test-CommandLineReferencesInstallRoot -CommandLine $commandLine)
            $isGatewayListener = $gatewayProcessIds.ContainsKey($processId) -and
                $_.Name -ieq 'node.exe' -and
                $commandLine -match '\bgateway(?:\s+run)?(?:\s|$)'

            if ($isInstalledProcess -or $referencesInstall -or $isGatewayListener) {
                $found[$processId] = [pscustomobject]@{
                    Path = $executablePath
                    Name = $_.Name
                    CommandLine = $commandLine
                }
            }
        }
    } catch {
        Write-Log "CIM process scan unavailable: $($_.Exception.Message)"
    }

    foreach ($processName in @("node", "AetherStudy", "Aether_ClawDESK")) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Id -eq $PID) {
                return
            }
            try {
                $processPath = $_.Path
                $isTarget = Test-IsUnderInstallRoot -Path $processPath
                if (-not $isTarget) {
                    foreach ($target in $targetExecutables) {
                        if (Test-PathEquals -Left $processPath -Right $target) {
                            $isTarget = $true
                            break
                        }
                    }
                }
                if ($isTarget) {
                    $found[[int]$_.Id] = [pscustomobject]@{
                        Path = $processPath
                        Name = $_.ProcessName
                        CommandLine = ''
                    }
                }
            } catch {
                # Protected processes that do not expose Path cannot be part of this per-user install.
            }
        }
    }

    return $found
}

function Stop-TargetProcesses {
    $processes = Get-TargetProcesses
    foreach ($entry in $processes.GetEnumerator()) {
        $info = $entry.Value
        Write-Log "Stopping PID $($entry.Key) ($($info.Name)): $($info.Path) $($info.CommandLine)"
        try {
            Stop-Process -Id $entry.Key -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to stop PID $($entry.Key): $($_.Exception.Message)"
        }
    }
    return $processes.Count
}

function Test-FileUnlocked {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

Write-Log "Stopping applications from: $($installRoots -join ', ')"
Stop-GatewayServices
Stop-AndDeleteScheduledTasks

$deadline = [DateTime]::UtcNow.AddSeconds(30)
do {
    [void](Stop-TargetProcesses)
    Start-Sleep -Milliseconds 300

    $remaining = Get-TargetProcesses
    $lockedFiles = @($lockTargets | Where-Object { -not (Test-FileUnlocked -Path $_) })
    if ($remaining.Count -eq 0 -and $lockedFiles.Count -eq 0) {
        Write-Log "All target processes stopped and backend files are unlocked."
        exit 0
    }

    if ($remaining.Count -gt 0) {
        Write-Log "Waiting for processes: $(($remaining.Keys | Sort-Object) -join ', ')"
    }
    if ($lockedFiles.Count -gt 0) {
        Write-Log "Waiting for file locks: $($lockedFiles -join ', ')"
    }
} while ([DateTime]::UtcNow -lt $deadline)

$remainingIds = ($remaining.Keys | Sort-Object) -join ", "
$lockedSummary = $lockedFiles -join ", "

if ($remaining.Count -eq 0 -and $lockedFiles.Count -gt 0) {
    # Endpoint security software can retain a read handle after the owning Node
    # process exits. Inno Setup's restartreplace flag safely defers these files
    # until reboot, so a lock alone must not block the installer before extraction.
    Write-Log "All target processes stopped. Continuing with restart-replace for locked files: $lockedSummary"
    exit 0
}

Write-Log "Failed to release upgrade resources. Processes: $remainingIds; locked files: $lockedSummary"
exit 1
