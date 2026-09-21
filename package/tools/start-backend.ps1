param(
    [string]$InstallRoot = "",
    [string]$StateDir = "",
    [int]$Port = 18789
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -StateDir "{2}" -Port {3}' -f `
        $PSCommandPath, $InstallRoot, $StateDir, $Port
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -Verb RunAs
    exit 0
}

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path $env:USERPROFILE ".openclaw"
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
$logDir = Join-Path $StateDir "logs"
$logPath = Join-Path $logDir "manual-start.log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $Message
}

function Test-GatewayPort {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(800, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-GatewayPort {
    param([int]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-GatewayPort) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Resolve-InstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        return [IO.Path]::GetFullPath($InstallRoot)
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles "AetherStudy"),
        (Join-Path $env:LOCALAPPDATA "Programs\AetherStudy")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "runtime\backend\runtime\node\node.exe")) {
            return $candidate
        }
    }
    return $candidates[0]
}

try {
    Write-Log "Manual OpenClaw backend start requested."
    if (Test-GatewayPort) {
        Write-Log "OpenClaw Gateway is already listening on 127.0.0.1:$Port."
        exit 0
    }

    $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
    $taskName = "OpenClaw Gateway"
    & $schtasks /Query /TN $taskName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Starting scheduled task: $taskName"
        & $schtasks /Run /TN $taskName *> $null
        if ($LASTEXITCODE -eq 0 -and (Wait-GatewayPort -Seconds 30)) {
            Write-Log "OpenClaw Gateway started from Task Scheduler."
            exit 0
        }
        Write-Log "Scheduled task did not open port $Port; trying the hidden launcher."
    } else {
        Write-Log "Scheduled task is unavailable; trying the hidden launcher."
    }

    $gatewayVbs = Join-Path $StateDir "gateway.vbs"
    if (Test-Path -LiteralPath $gatewayVbs) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot "System32\wscript.exe"
        $psi.Arguments = '//B //Nologo "{0}"' -f $gatewayVbs
        $psi.WorkingDirectory = $StateDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        [void][Diagnostics.Process]::Start($psi)
        if (Wait-GatewayPort -Seconds 30) {
            Write-Log "OpenClaw Gateway started from the hidden launcher."
            exit 0
        }
        Write-Log "Hidden launcher did not open port $Port; trying bundled Node directly."
    }

    $resolvedRoot = Resolve-InstallRoot
    $backendRoot = Join-Path $resolvedRoot "runtime\backend"
    $nodePath = Join-Path $backendRoot "runtime\node\node.exe"
    $distIndex = Join-Path $backendRoot "dist\index.js"
    foreach ($requiredPath in @($nodePath, $distIndex)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required backend file is missing: $requiredPath"
        }
    }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $nodePath
    $psi.Arguments = '"{0}" gateway --port {1}' -f $distIndex, $Port
    $psi.WorkingDirectory = $backendRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $psi.EnvironmentVariables["OPENCLAW_STATE_DIR"] = $StateDir
    $psi.EnvironmentVariables["NODE_TLS_REJECT_UNAUTHORIZED"] = "0"
    [void][Diagnostics.Process]::Start($psi)

    if (-not (Wait-GatewayPort -Seconds 60)) {
        throw "Gateway did not listen on 127.0.0.1:$Port within 60 seconds."
    }
    Write-Log "OpenClaw Gateway started directly with bundled Node."
    exit 0
} catch {
    Write-Log "Backend start failed: $($_.Exception.Message)"
    Write-Host "Log: $logPath" -ForegroundColor Yellow
    exit 1
}
