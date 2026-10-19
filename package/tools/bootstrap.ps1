param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true)]
    [string]$DataRoot
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$backendRoot = Join-Path $InstallRoot "runtime\backend"
$nodePath = Join-Path $backendRoot "runtime\node\node.exe"
$deployScript = Join-Path $backendRoot "scripts\medclaw-deploy.mjs"
$kbToolsInstallScript = Join-Path $InstallRoot "tools\install-kb-tools.mjs"
$distIndex = Join-Path $backendRoot "dist\index.js"
$tenantTemplate = Join-Path $backendRoot "openclaw.tenant.json"
$deployConfigPath = Join-Path $backendRoot "medclaw.deploy.json"
$logRoot = Join-Path $DataRoot "logs"
$logPath = Join-Path $logRoot "install.log"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfig = Join-Path $openClawRoot "openclaw.json"
$gatewayPort = 18789

New-Item -ItemType Directory -Force -Path $logRoot, $openClawRoot | Out-Null
Start-Transcript -Path $logPath -Append | Out-Null

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertTo-WindowsArgumentString {
    # 把参数数组拼成一条 Windows 命令行字符串，遵循 CommandLineToArgvW 的转义规则
    # （反斜杠只在紧邻结尾引号时才需要成对转义；引号本身转义成 \"）。
    # ProcessStartInfo.Arguments 是从 .NET 1.0 就有的老接口，比 .ArgumentList 集合属性
    # （部分 .NET Framework 版本上不存在，Windows 自带的 PowerShell 5.1 就跑在 .NET
    # Framework 上）更保险，所以走这条手动拼接的路。
    param([string[]]$ArgumentList)

    $parts = foreach ($arg in $ArgumentList) {
        if ($arg -eq $null -or $arg -eq "") {
            '""'
            continue
        }
        if ($arg -notmatch '[\s"]') {
            $arg
            continue
        }
        $escaped = $arg -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return ($parts -join ' ')
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    # 参数判空：ArgumentList 里混进 $null/空字符串是已知会让 PowerShell 原生命令的
    # `& $FilePath @ArgumentList` 展开在部分版本上炸出难懂的 IndexOutOfRangeException
    # 的诱因之一——这里先显式校验，真出问题也能一眼看出是哪个参数、而不是猜。
    for ($i = 0; $i -lt $ArgumentList.Length; $i++) {
        if ($ArgumentList[$i] -eq $null -or $ArgumentList[$i] -eq "") {
            throw "$Description：第 $($i + 1) 个参数为空（ArgumentList[$i]），拒绝调用 $FilePath"
        }
    }

    Write-Host "    $Description"
    # 不用 `& $FilePath @ArgumentList`：PowerShell 原生命令调用这条路径本身有已知的诱因会
    # 抛出 IndexOutOfRangeException（"索引超出了数组界限"）——不管具体是控制台状态探测还是
    # 参数展开机制导致，都发生在这条调用路径内部。改走 .NET 的 Process.Start，完全绕开
    # PowerShell 自己的原生命令调用/参数绑定逻辑。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-WindowsArgumentString -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # 不重定向 stdout/stderr：保持子进程直接继承父进程的控制台句柄，行为与原来的
    # `&` 调用一致（子进程输出照样流进 Start-Transcript 的捕获）。

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw "$Description：启动进程失败（$FilePath）：$($_.Exception.Message)"
    }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "$Description failed with exit code $($proc.ExitCode)"
    }
}

function New-GatewayToken {
    $bytes = New-Object byte[] 24
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Get-ExistingGatewayToken {
    if (-not (Test-Path -LiteralPath $openClawConfig)) {
        return $null
    }

    try {
        $config = Get-Content -LiteralPath $openClawConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $token = $config.gateway.auth.token
        if ($token -is [string] -and -not [string]::IsNullOrWhiteSpace($token)) {
            $token = $token.Trim()
            if ($token -match '^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$') {
                $resolved = [Environment]::GetEnvironmentVariable($Matches[1])
                if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                    return $resolved.Trim()
                }
                Write-Host "    旧 Gateway Token 是未解析的环境变量占位符，将生成新的 Token。" -ForegroundColor Yellow
                return $null
            }
            if ($token -match '^__.+__$' -or $token -match '^REPLACE_WITH_') {
                Write-Host "    旧 Gateway Token 是部署占位符，将生成新的 Token。" -ForegroundColor Yellow
                return $null
            }
            return $token
        }
    } catch {
        Write-Host "    现有 OpenClaw 配置无法读取，将生成新的 Gateway Token。" -ForegroundColor Yellow
    }
    return $null
}

function Import-LegacyClientConfig {
    $targetConfig = Join-Path $DataRoot "AppData\config\config.json"
    if (Test-Path -LiteralPath $targetConfig) {
        return
    }

    $legacyConfig = Join-Path $env:LOCALAPPDATA "Aether_ClawDESK\AppData\config\config.json"
    if (-not (Test-Path -LiteralPath $legacyConfig)) {
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetConfig) | Out-Null
    Copy-Item -LiteralPath $legacyConfig -Destination $targetConfig -Force
    Write-Host "    已将旧版 Aether_ClawDESK 客户端配置迁移到 AetherStudy。"
}

function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    } else {
        $property.Value = $Value
    }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $json = $Value | ConvertTo-Json -Depth 100
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8)
}

function Read-DeployTemplate {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Production deploy template is missing: $Path"
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Production deploy template is invalid JSON: $Path. $($_.Exception.Message)"
    }
}

function Stop-PreviousGateway {
    param([int]$Port)

    try {
        $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($listener in $listeners) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
            if ($null -eq $processInfo) {
                continue
            }

            $isNode = $processInfo.Name -ieq "node.exe"
            $isGateway = $processInfo.CommandLine -match "\bgateway(?:\s+run)?(?:\s|$)"
            if ($isNode -and $isGateway) {
                Write-Host "    停止占用端口 $Port 的旧 Gateway 进程（PID $($listener.OwningProcess)）。"
                Stop-Process -Id $listener.OwningProcess -Force -ErrorAction Stop
            }
        }
    } catch {
        Write-Host "    未能自动停止旧 Gateway：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

try {
    foreach ($requiredPath in @($nodePath, $deployScript, $kbToolsInstallScript, $distIndex, $tenantTemplate)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Production backend payload is missing: $requiredPath"
        }
    }

    Import-LegacyClientConfig

    $token = Get-ExistingGatewayToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = New-GatewayToken
    }

    # Model source is decided by medclaw-deploy.mjs, not here: if the packaged template
    # already has a real model configured it is used as-is (legacy baked-in-model
    # packages keep working); otherwise the gateway comes up with a placeholder model
    # and the client is expected to provision the real one after login (see
    # scripts/medclaw-deploy.mjs's modelConfigured/modelFromClient handling). The
    # installer only adds installation-specific Gateway settings here.
    $deployTemplatePath = Join-Path $backendRoot "medclaw.deploy.example.json"
    $deployConfig = Read-DeployTemplate -Path $deployTemplatePath
    Set-JsonProperty -Object $deployConfig -Name "gatewayPort" -Value $gatewayPort
    Set-JsonProperty -Object $deployConfig -Name "gatewayToken" -Value $token
    Write-Utf8Json -Path $deployConfigPath -Value $deployConfig

    $env:OPENCLAW_STATE_DIR = $openClawRoot
    $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"

    # Do not invoke the CLI before writing the new config: an older OpenClaw
    # configuration can be invalid for this production runtime and would block upgrades.
    Write-Step "停止旧 Gateway 进程"
    Stop-PreviousGateway -Port $gatewayPort

    Write-Step "部署 MedBuddy 预构建生产运行时"
    Invoke-Checked -FilePath $nodePath -ArgumentList @(
        $deployScript,
        "--config", $deployConfigPath,
        "--pkg-root", $backendRoot,
        "--state-dir", $openClawRoot
    ) -Description "完整部署 Aether Study（零 build，包含 Miniconda 和 Gateway）"

    Write-Step "安装并启用 KB 工具"
    Invoke-Checked -FilePath $nodePath -ArgumentList @(
        $kbToolsInstallScript,
        "--state-dir", $openClawRoot,
        "--pkg-root", $backendRoot
    ) -Description "安装 kb_ingest、kb_search、kb_manage 并注册到 main.tools.alsoAllow"

    # 无需显式重启：deploy 内的 gateway install 已按正确配置启动网关；KB 工具写入的是
    # agents.list[main].tools.alsoAllow，gateway 的 config-watch（默认 hybrid）会热更（dynamic
    # reads）、不重启即生效（实测：改 agents.list 不触发重启，PID 不变）。此前在此紧接 gateway
    # restart 属冗余，且会与 deploy 的 install --force 撞在服务过渡态、触发 nssm 的 STOP_PENDING
    # 报错把服务留在 stopped，故移除。真需重启的场景由 config-watch/服务自身负责。

    Write-Step "写入 Aether study 客户端连接配置"
    $clientConfigPath = Join-Path $DataRoot "AppData\config\config.json"
    if (Test-Path -LiteralPath $clientConfigPath) {
        $clientConfig = Get-Content -LiteralPath $clientConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $clientConfig = [pscustomobject]@{}
    }
    Set-JsonProperty -Object $clientConfig -Name "serverUrl" -Value "ws://127.0.0.1:$gatewayPort"
    Set-JsonProperty -Object $clientConfig -Name "token" -Value $token
    Set-JsonProperty -Object $clientConfig -Name "clientId" -Value "openclaw-control-ui"
    Set-JsonProperty -Object $clientConfig -Name "skillsStoragePath" -Value "~/AetherStudy/skills"
    Write-Utf8Json -Path $clientConfigPath -Value $clientConfig

    Write-Step "检查 Gateway 监听端口"
    $ready = $false
    # Gateway installation is asynchronous on Windows. Allow up to 10 minutes
    # so a delayed but healthy service does not make the installer fail early.
    $gatewayWaitAttempts = 300
    for ($attempt = 1; $attempt -le $gatewayWaitAttempts; $attempt++) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect("127.0.0.1", $gatewayPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000, $false) -and $client.Connected) {
                $client.EndConnect($async)
                $ready = $true
                break
            }
        } catch {
            # Gateway may still be starting.
        } finally {
            $client.Close()
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        $gatewayLogPath = Join-Path $openClawRoot "logs\gateway.log"
        if (Test-Path -LiteralPath $gatewayLogPath) {
            Write-Host ""
            Write-Host "Gateway 日志末尾：$gatewayLogPath" -ForegroundColor Yellow
            Get-Content -LiteralPath $gatewayLogPath -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host "    $_"
            }
        }
        throw "Gateway did not start listening on 127.0.0.1:$gatewayPort within 5 minutes. Gateway log: $gatewayLogPath"
    }

    Write-Host ""
    Write-Host "Aether study 和 MedBuddy 生产服务安装完成。" -ForegroundColor Green
    exit 0
} catch {
    Write-Host ""
    Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "安装日志：$logPath" -ForegroundColor Yellow
    exit 1
} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
    }
}
