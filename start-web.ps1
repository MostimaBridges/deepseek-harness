# =============================================================================
# DeepSeek Harness 一键启动脚本 (Windows / PowerShell)
#
# 功能：检查环境 -> (可选)检查并安全拉取 GitHub 更新 -> 智能安装/构建 -> 后台启动 dsh web
# 用法：
#   .\start-web.ps1                 # 默认端口 3080，自动开浏览器
#   .\start-web.ps1 -Port 9090      # 自定义端口
#   .\start-web.ps1 -SkipUpdate     # 跳过 GitHub 更新检查
#   .\start-web.ps1 -SkipInstall -SkipBuild  # 跳过安装/构建
#   .\start-web.ps1 -Clean          # 强制清理旧构建产物后重新构建
#   .\start-web.ps1 -Stop           # 停止已运行的服务（仅识别 dsh web 进程，防误杀）
#   .\start-web.ps1 -NoBrowser      # 启动后不自动打开浏览器
# 也可直接双击同目录的 start-web.bat
# =============================================================================

[CmdletBinding()]
param(
  [int]$Port = 3080,
  [switch]$SkipInstall,
  [switch]$SkipBuild,
  [switch]$SkipUpdate,
  [switch]$Clean,
  [switch]$Stop,
  [switch]$NoBrowser
)

# 用 Continue：原生命令（git/pnpm）写 stderr 在 PowerShell 5.1 下若为 Stop 会
# 抛致命 NativeCommandError 直接中止脚本。改为 Continue 后，关键步骤通过
# 显式检查 $LASTEXITCODE / $proc.HasExited 来控制失败退出，避免网络失败时整体崩掉。
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

# 服务进程 PID 记录与日志路径（-Stop 依此停止；日志供排障）
$PidFile = Join-Path $env:TEMP ('dsh-web-' + $Port + '.pid')
$OutLog  = Join-Path $env:TEMP ('dsh-web-' + $Port + '.out.log')
$ErrLog  = Join-Path $env:TEMP ('dsh-web-' + $Port + '.err.log')

# 记录本次是否发生了 Git 拉取，以及变更文件列表（用于 install/build 决策）
$script:PullUpdated = $false
$script:ChangedFiles = @()

function Test-Cmd {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Port {
  param([int]$Port)
  # localhost:port 的 Connect 在端口关闭时立即返回 refused（不会长阻塞）。
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $c.Connect('127.0.0.1', $Port)
    $c.Close()
    return $true
  } catch {
    $c.Dispose()
    return $false
  }
}

# 占用给定端口的监听进程 PID（若存在）
function Get-PortPid {
  param([int]$Port)
  $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($conn) { return $conn.OwningProcess }
  return $null
}

# 判断某 PID 是否为 dsh web：命令行包含 apps\cli / bin.ts / dsh
# 注意：参数名不能叫 $Pid（与只读自动变量 $PID 冲突）
function Test-IsDshProcess {
  param([int]$ProcessId)
  if (-not $ProcessId) { return $false }
  $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $p) { return $false }
  return [bool]($p.CommandLine -match 'dsh|apps\\cli|bin\.ts')
}

# 当前 Git 分支与其 upstream（不硬编码 main/master）
function Get-GitUpstream {
  if (-not (Test-Cmd git)) { return $null }
  $branch = git rev-parse --abbrev-ref HEAD 2>$null
  if (-not $branch -or $branch -eq 'HEAD') { return $null }
  $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
  if (-not $upstream) { return $null }
  $remote = $upstream.Split('/')[0]
  return @{ Branch = $branch; Upstream = $upstream; Remote = $remote }
}

# 变更文件是否影响依赖解析（决定是否 pnpm install）
function Test-DepsChanged {
  param([string[]]$Files)
  foreach ($f in $Files) {
    $n = $f -replace '\\', '/'
    if ($n -in @('pnpm-lock.yaml', 'pnpm-workspace.yaml', 'package.json')) { return $true }
    if ($n -match '^packages/.*/package\.json$|^apps/.*/package\.json$') { return $true }
    if ($n -match 'pnpmfile(\.cjs|\.js)?$|\.npmrc$') { return $true }
  }
  return $false
}

# 变更文件是否可能影响运行产物（排除纯文档 / workflow / 资源）
function Test-BuildRelevant {
  param([string[]]$Files)
  foreach ($f in $Files) {
    $n = $f -replace '\\', '/'
    if ($n -match '^(docs|website|snapshots|examples|\.github|\.vscode|\.idea)/') { continue }
    if ($n -match '\.(md|i18n\.yaml|zh\.md|png|jpg|jpeg|svg|gif|webmanifest)$') { continue }
    if ($n -match '^(README|CONTRIBUTING|SAFETY|BRAND_GUIDELINES|LICENSE|BENCHMARK|CHANGELOG|THIRD_PARTY)(\.|$)') { continue }
    if ($n -in @('.gitignore', 'lefthook.yml')) { continue }
    return $true
  }
  return $false
}

# 关键原生模块是否已编译（用于 --ignore-scripts 后的“假成功”提醒）
function Test-FsExtNative {
  $p = Get-ChildItem (Join-Path $Root 'node_modules\.pnpm\fs-ext@*\node_modules\fs-ext\build\Release\fs_ext.node') -ErrorAction SilentlyContinue |
    Select-Object -First 1
  return [bool]$p
}

# 提取一次性的鉴权 token，拼出可直接访问的 URL。
# 子进程 stdout 重定向到文件有时有缓冲，读不到时重试最多约 5 秒。
function Get-DshWebUrl {
  param([int]$Port)
  for ($i = 0; $i -lt 20; $i++) {
    if (Test-Path $OutLog) {
      $content = (Get-Content $OutLog -Raw -ErrorAction SilentlyContinue)
      if ($content -match '\?token=([A-Za-z0-9_\-]+)') {
        return ('http://127.0.0.1:' + $Port + '/?token=' + $Matches[1])
      }
    }
    Start-Sleep -Milliseconds 250
  }
  return ('http://127.0.0.1:' + $Port)
}

# 在启动失败/超时时清理 PID 文件，并终止我们启动的进程树
function Stop-FailedLaunch {
  param($Proc)
  Remove-Item $PidFile -ErrorAction SilentlyContinue
  if ($Proc -and -not $Proc.HasExited) {
    taskkill /PID $Proc.Id /T /F 2>$null | Out-Null
  }
}

# ---- 0. 停止服务 (-Stop) 与端口校验 --------------------------------------
if ($Port -lt 1 -or $Port -gt 65535) {
  Write-Host ('无效端口: ' + $Port + ' (范围 1-65535)') -ForegroundColor Red
  exit 1
}

if ($Stop) {
  $targetPid = $null
  # 优先 PID 文件，但必须确认它是 dsh web（防止 PID 复用误杀）
  if (Test-Path $PidFile) {
    $candidate = [int](Get-Content $PidFile -Raw).Trim()
    if (Test-IsDshProcess $candidate) { $targetPid = $candidate }
  }
  # 没有可靠的 PID 文件时，回退到端口占用进程（同样要求是 dsh web）
  if ($null -eq $targetPid) {
    $pidOnPort = Get-PortPid $Port
    if (Test-IsDshProcess $pidOnPort) { $targetPid = $pidOnPort }
  }
  if ($null -ne $targetPid) {
    Write-Host ('停止 dsh web (PID ' + $targetPid + ')...') -ForegroundColor Yellow
    taskkill /PID $targetPid /T /F 2>$null | Out-Host
    Remove-Item $PidFile -ErrorAction SilentlyContinue
  } else {
    Write-Host '未发现可安全停止的 dsh web 服务（其它程序占用时不会误杀）。' -ForegroundColor DarkGray
    Remove-Item $PidFile -ErrorAction SilentlyContinue
  }
  exit 0
}

Write-Host ''
Write-Host '=== DeepSeek Harness 一键启动 ===' -ForegroundColor Cyan

# ---- 1. 环境检查 ----------------------------------------------------------
if (-not (Test-Cmd node)) {
  Write-Host '未找到 node，请先安装 Node.js' -ForegroundColor Red
  exit 1
}
if (-not (Test-Cmd pnpm)) {
  Write-Host '未找到 pnpm，尝试通过 corepack 启用...'
  corepack enable 2>$null
  if (-not (Test-Cmd pnpm)) {
    Write-Host '无法获取 pnpm，请先安装 (npm i -g pnpm)' -ForegroundColor Red
    exit 1
  }
}

# Node 版本校验（package.json engines: ^22.19.0 || >=24.0.0）
$nodeRaw = (node -v).TrimStart('v')
$nodeMajor = 0; $nodeMinor = 0
if ($nodeRaw -match '^(\d+)\.(\d+)') { $nodeMajor = [int]$Matches[1]; $nodeMinor = [int]$Matches[2] }
$nodeOk = ($nodeMajor -eq 22 -and $nodeMinor -ge 19) -or ($nodeMajor -ge 24)
if (-not $nodeOk) {
  Write-Host ('Node 版本过低：' + $nodeRaw + '（需 >=22.19 或 >=24）') -ForegroundColor Red
  exit 1
}
$pnpmRaw = (pnpm -v).Trim()
Write-Host ('node ' + (node -v) + ' / pnpm ' + $pnpmRaw) -ForegroundColor Green

# pnpm 版本是否匹配项目 packageManager（软提示，不阻断）
$pkgMgr = node -e "process.stdout.write(require('./package.json').packageManager||'')" 2>$null
if ($pkgMgr) {
  $wantMajor = 0; $wantMinor = 0
  if ($pkgMgr -match 'pnpm@(\d+)\.(\d+)') { $wantMajor = [int]$Matches[1]; $wantMinor = [int]$Matches[2] }
  $curMajor = 0; $curMinor = 0
  if ($pnpmRaw -match '^(\d+)\.(\d+)') { $curMajor = [int]$Matches[1]; $curMinor = [int]$Matches[2] }
  if ($curMajor -ne $wantMajor -or $curMinor -ne $wantMinor) {
    Write-Host ('提示：项目要求 pnpm@' + $wantMajor + '.' + $wantMinor + '，当前 ' + $pnpmRaw + '（可用 corepack 切换）') -ForegroundColor Yellow
  }
}

# ---- 2. GitHub 更新检查 ---------------------------------------------------
if (-not $SkipUpdate -and (Test-Cmd git) -and (Test-Path (Join-Path $Root '.git'))) {
  $up = Get-GitUpstream
  if ($null -eq $up) {
    Write-Host ('Git 未配置 upstream（当前分支 ' + (git rev-parse --abbrev-ref HEAD 2>$null) + '），跳过更新检查。') -ForegroundColor Yellow
  } else {
    Write-Host ('检查上游更新：' + $up.Upstream) -ForegroundColor Cyan
    git fetch 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Host 'git fetch 失败（无网络/代理不可用），继续使用当前本地版本。' -ForegroundColor Yellow
    } else {
      $localHead = git rev-parse HEAD 2>$null
      $remoteHead = git rev-parse '@{u}' 2>$null
      if ($localHead -eq $remoteHead) {
        Write-Host '当前已是最新版本。' -ForegroundColor Green
      } else {
        $behind = 0; $ahead = 0
        try { $behind = [int](git rev-list --count HEAD..'@{u}' 2>$null) } catch { $behind = 0 }
        try { $ahead = [int](git rev-list --count '@{u}'..HEAD 2>$null) } catch { $ahead = 0 }
        Write-Host ('上游有新提交（ahead ' + $ahead + ' / behind ' + $behind + '）') -ForegroundColor Cyan
        if ($behind -gt 0) {
          $dirty = @(git status --porcelain 2>$null)
          $trackedDirty = @($dirty | Where-Object { -not ($_ -match '^\?\?') })
          if ($trackedDirty.Count -gt 0) {
            Write-Host '本地存在未提交修改，为保护工作区本次跳过自动 pull。' -ForegroundColor Yellow
            Write-Host '若要更新：请先 commit 或 stash，再重新运行本脚本。' -ForegroundColor Yellow
            Write-Host '继续使用当前本地代码启动。' -ForegroundColor Yellow
          } else {
            $oldHead = $localHead
            Write-Host '拉取更新 (git pull --ff-only)...'
            git pull --ff-only 2>$null
            if ($LASTEXITCODE -eq 0) {
              $newHead = git rev-parse HEAD 2>$null
              $script:PullUpdated = $true
              $script:ChangedFiles = @(git diff --name-only $oldHead $newHead 2>$null)
              Write-Host ('更新完成：' + $oldHead.Substring(0, [Math]::Min(8, $oldHead.Length)) + ' -> ' + $newHead.Substring(0, [Math]::Min(8, $newHead.Length))) -ForegroundColor Green
            } else {
              Write-Host 'git pull --ff-only 失败，已保留原工作区，继续使用当前本地代码。' -ForegroundColor Yellow
            }
          }
        } else {
          Write-Host '本地领先/无落后，无需拉取。' -ForegroundColor DarkGray
        }
      }
    }
  }
} else {
  if (-not $SkipUpdate) {
    Write-Host '跳过 GitHub 更新检查（未安装 git 或非 Git 仓库）。' -ForegroundColor DarkGray
  } else {
    Write-Host '跳过 GitHub 更新检查 (-SkipUpdate)' -ForegroundColor DarkGray
  }
}

# ---- 3. 处理已运行的服务 --------------------------------------------------
$portPid = Get-PortPid $Port
$portIsDsh = Test-IsDshProcess $portPid

if ($portPid -and -not $portIsDsh) {
  Write-Host ('端口 ' + $Port + ' 被其它程序占用（PID ' + $portPid + '），不会自动处理。') -ForegroundColor Red
  Write-Host '请先释放该端口，或改用 -Port 指定其它端口。' -ForegroundColor Red
  exit 1
}

if ($portPid -and $portIsDsh) {
  if ($script:PullUpdated) {
    Write-Host '检测到更新且当前运行的正是本项目的 dsh web，先停止旧版本...' -ForegroundColor Cyan
    taskkill /PID $portPid /T /F 2>$null | Out-Host
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
  } else {
    Write-Host ('端口 ' + $Port + ' 已运行本项目的 dsh web，且无更新，直接打开现有服务。') -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process (Get-DshWebUrl $Port) }
    exit 0
  }
}

# ---- 4. 依赖安装 ----------------------------------------------------------
if ($SkipInstall) {
  Write-Host '跳过依赖安装 (-SkipInstall)' -ForegroundColor DarkGray
} else {
  $nmDir = Join-Path $Root 'node_modules'
  $installNeed = -not (Test-Path $nmDir)
  # Git 更新带来的依赖变化（git diff 优先于 mtime）
  if (-not $installNeed -and $script:PullUpdated) {
    if (Test-DepsChanged $script:ChangedFiles) { $installNeed = $true }
  }
  # mtime 兜底（非 Git 环境或手工改动依赖）
  if (-not $installNeed -and (Test-Path (Join-Path $Root 'pnpm-lock.yaml')) -and (Test-Path $nmDir)) {
    if ((Get-Item (Join-Path $Root 'pnpm-lock.yaml')).LastWriteTime -gt (Get-Item $nmDir).LastWriteTime) {
      $installNeed = $true
    }
  }
  if ($Clean) { $installNeed = $true }

  if ($installNeed) {
    Write-Host '安装依赖 (pnpm install --frozen-lockfile)...'
    pnpm install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) {
      Write-Host '常规安装失败（原生模块 needs VS C++ toolchain），改用 --ignore-scripts 重试...' -ForegroundColor Yellow
      pnpm install --frozen-lockfile --ignore-scripts
      if ($LASTEXITCODE -ne 0) {
        Write-Host 'pnpm install 失败' -ForegroundColor Red
        exit 1
      }
      if (-not (Test-FsExtNative)) {
        Write-Host '注意：原生模块可能未编译（如 fs-ext），运行可能报缺模块（假成功）。' -ForegroundColor Yellow
        Write-Host '请安装 Visual Studio C++ 工具后执行：pnpm rebuild fs-ext' -ForegroundColor Yellow
      }
    }
  } else {
    Write-Host '依赖无需安装（node_modules 存在且依赖未变化）' -ForegroundColor DarkGray
  }
}

# ---- 5. 构建 --------------------------------------------------------------
$libOk = Test-Path (Join-Path $Root 'apps\cli\lib')
$webOk = Test-Path (Join-Path $Root 'apps\web\dist\index.html')
$prodOk = $libOk -and $webOk
$needBuild = $false

if ($SkipBuild) {
  Write-Host '跳过构建 (-SkipBuild)' -ForegroundColor DarkGray
} else {
  if (-not $prodOk) {
    $needBuild = $true
    Write-Host '构建产物缺失，需要构建。' -ForegroundColor Yellow
  } elseif ($script:PullUpdated) {
    if (Test-BuildRelevant $script:ChangedFiles) {
      $needBuild = $true
      Write-Host '本次更新涉及源码/构建配置，需要重新构建。' -ForegroundColor Yellow
    } else {
      Write-Host '本次更新仅涉及文档/无关内容，跳过构建。' -ForegroundColor DarkGray
    }
  } else {
    # 无 Git 更新时使用 mtime 兜底：源码比产物新则重建
    $prodLatest = [Math]::Max(
      (Get-Item (Join-Path $Root 'apps\cli\lib')).LastWriteTime.Ticks,
      (Get-Item (Join-Path $Root 'apps\web\dist')).LastWriteTime.Ticks
    )
    $prodLatest = [DateTime]::new($prodLatest)
    # 轻量兜底：比较根级构建配置与产物目录 mtime
    $srcTime = (Get-Item (Join-Path $Root 'package.json')).LastWriteTime
    if ($srcTime -gt $prodLatest) { $needBuild = $true; Write-Host '检测到构建配置更新，需要重新构建。' -ForegroundColor Yellow }
    else { Write-Host '构建产物已是最新，跳过 pnpm run build' -ForegroundColor DarkGray }
  }
  if ($Clean) {
    $needBuild = $true
    Write-Host '强制重新构建 (-Clean)' -ForegroundColor Yellow
  }
}

if ($needBuild) {
  if ($Clean) {
    Write-Host '清理旧构建产物 (pnpm run clean)...' -ForegroundColor Yellow
    pnpm run clean
    if ($LASTEXITCODE -ne 0) { Write-Host 'pnpm run clean 失败' -ForegroundColor Red; exit 1 }
  }
  Write-Host '构建 (pnpm run build)，可能需要数分钟...'
  pnpm run build
  if ($LASTEXITCODE -ne 0) {
    Write-Host '构建失败，尝试先清理旧产物再重建（常见于大版本源码更新后）...' -ForegroundColor Yellow
    pnpm run clean
    if ($LASTEXITCODE -ne 0) { Write-Host 'pnpm run clean 失败' -ForegroundColor Red; exit 1 }
    pnpm run build
    if ($LASTEXITCODE -ne 0) { Write-Host '构建失败' -ForegroundColor Red; exit 1 }
  }
}

# ---- 6. 启动 dsh web ------------------------------------------------------
# 清空旧日志，避免残留 token 干扰提取
Remove-Item $OutLog, $ErrLog -ErrorAction SilentlyContinue
Write-Host ('启动 dsh web (端口 ' + $Port + ')...')
# 服务在独立隐藏控制台运行：不共享本窗口 (-WindowStyle Hidden)，
# 关闭启动窗口/脚本不会终止服务。停止：.start-web.ps1 -Stop
$proc = Start-Process -FilePath 'cmd.exe' `
  -ArgumentList @('/c', 'pnpm', 'dsh', 'web', '--port', "$Port", '--no-open') `
  -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
$proc.Id | Out-File -FilePath $PidFile -Encoding ascii

# ---- 7. 等待端口就绪 ------------------------------------------------------
Write-Host '等待服务就绪（首次从源码加载较慢）...'
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Port $Port)) {
  if ($proc.HasExited) {
    Write-Host ('服务进程异常退出 (exit ' + $proc.ExitCode + ')') -ForegroundColor Red
    Write-Host ('  stdout 日志: ' + $OutLog)
    Write-Host ('  stderr 日志: ' + $ErrLog)
    Stop-FailedLaunch $proc
    exit 1
  }
  if ((Get-Date) -gt $deadline) {
    Write-Host ('等待服务就绪超时 (5 分钟)，日志见 ' + $OutLog) -ForegroundColor Red
    Stop-FailedLaunch $proc
    exit 1
  }
  Start-Sleep -Milliseconds 500
}

# ---- 7b. 等待 API 真正可响应（端口监听 ≠ RPC 层就绪）----------------------
Write-Host '等待 API 就绪...'
Write-Host ('  stdout 日志: ' + $OutLog)
Write-Host ('  stderr 日志: ' + $ErrLog)
$apiReady = $false
$apiDeadline = (Get-Date).AddMinutes(3)
while (-not $apiReady) {
  if ($proc.HasExited) {
    Write-Host ('服务进程已退出 (exit ' + $proc.ExitCode + ')，启动失败。') -ForegroundColor Red
    if (Test-Path $ErrLog) { Write-Host '--- stderr 末尾 ---'; Get-Content $ErrLog -Tail 30 }
    if (Test-Path $OutLog) { Write-Host '--- stdout 末尾 ---'; Get-Content $OutLog -Tail 30 }
    Stop-FailedLaunch $proc
    exit 1
  }
  try {
    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/api/host.describe') `
      -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 5 -UseBasicParsing
    # 任一 HTTP 响应（含 200/401 等）都说明服务已就绪；仅连接失败/超时才算未就绪
    $apiReady = $true
  } catch {
    if ($_.Exception.Response) { $apiReady = $true }
  }
  if (-not $apiReady) {
    if ((Get-Date) -gt $apiDeadline) {
      Write-Host '等待 API 就绪超时 (3 分钟)，请查看日志或检查端口占用' -ForegroundColor Red
      Stop-FailedLaunch $proc
      exit 1
    }
    Start-Sleep -Seconds 1
  }
}

# ---- 8. 完成并打开系统默认浏览器 ------------------------------------------
$webUrl = Get-DshWebUrl $Port
Write-Host ('服务已就绪：' + $webUrl) -ForegroundColor Green
Write-Host ('停止服务：taskkill /PID ' + $proc.Id + ' /T /F   或   .\start-web.ps1 -Stop') -ForegroundColor DarkGray
if (-not $NoBrowser) {
  Start-Process $webUrl
} else {
  Write-Host '已跳过自动打开浏览器 (-NoBrowser)' -ForegroundColor DarkGray
}
