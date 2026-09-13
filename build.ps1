#Requires -Version 7.0
<#
.SYNOPSIS
  DeepSeek Harness Desktop 完整构建脚本。

.DESCRIPTION
  代码已迁入 .\dsh-desktop（Yarn 工作区根目录）。本脚本从当前目录启动，
  自动进入 dsh-desktop，检查环境、初始化 pinned 上游子模块、安装依赖，
  再按目标执行编译 / 检查 / 打包。

  图形启动（dev / start）必须显式指定，默认构建保持无界面。

.PARAMETER Target
  构建目标：
    build              只编译 JS/类型声明（默认，无界面）
    check              完整无界面门禁
    typecheck          仅类型检查
    test               仅单元测试
    package-dir        当前平台解包目录
    dist-win           Windows x64 NSIS 安装包
    dist-win-portable  Windows x64 便携 ZIP
    dist-mac           macOS 签名发布（需凭证）
    dist-mac-smoke     macOS 未签名烟雾包
    dev                编译后启动图形界面
    start              使用已有产物启动
    all                build + typecheck + test

.PARAMETER SkipSubmodule
  跳过 git submodule 初始化（子模块已就绪时使用）。

.PARAMETER SkipInstall
  跳过 yarn install（node_modules 已就绪时使用）。

.PARAMETER SkipPull
  跳过 git pull（dsh-desktop 已存在时使用，纯本地构建；
  GitHub 网络不可用时避免构建在第 1 步失败）。

.PARAMETER Upstream
  额外在子模块内执行 pnpm install + pnpm build。
  产品编译默认不链接这份源码，只解析已发布的 DSH 包。

.PARAMETER KeepGoing
  某一步失败后继续后续步骤（默认遇错即停）。

.PARAMETER Proxy
  HTTP/HTTPS 代理地址，用于加速 electron-builder 下载（默认 http://127.0.0.1:15715）。

.PARAMETER NoProxy
  禁用代理（即使设置了 Proxy 参数）。

.PARAMETER Force
  跳过“与上次编译的 GitHub 版本相同”时的确认询问（无人值守 / 自动化时使用）。

.PARAMETER NoZip
  打包目标（dist-win / dist-win-portable / dist-mac / dist-mac-smoke）改为生成解包目录
  （dist\win-unpacked），不生成 ZIP / 安装包。等效于 -Target package-dir。

.PARAMETER Overlay
  应用本地覆盖层（默认关闭）。开启后会在 pull 之后自动重应用本地定制：
  electron 版本覆盖、.yarnrc.yml 年龄门禁、托盘图标/资源复制、tray-icon.svg 清洗、
  pnpm.mjs 补丁。不带此参数时构建上游原样代码（仍会应用 Windows 打包必需修复）。
  quick-build-overlay.bat 携带 -Overlay。

.PARAMETER KeepTimestamps
  保留 Electron 官方 zip 的 1980-01-01 时间戳（可复现构建行为）。
  默认关闭：打包后会把 dist\win-unpacked 内文件时间戳规整为当前时间。

.EXAMPLE
  .\build.ps1
  .\build.ps1 -Target package-dir              # 解包打包（无覆盖层）
  .\build.ps1 -Overlay -Target package-dir     # 应用本地覆盖层（quick-build-overlay 默认）
  .\build.ps1 -Target build                    # 编译
  .\build.ps1 -Target dist-win-portable
  .\build.ps1 -Target dist-win -Proxy http://127.0.0.1:7890
  .\build.ps1 -Target check -Upstream -NoProxy
  .\build.ps1 -Target build -SkipSubmodule -SkipInstall
  .\build.ps1 -Force                           # 版本相同时不再询问，直接构建
  .\build.ps1 -Target dist-win-portable -NoZip # 生成解包目录，不打 ZIP
#>

[CmdletBinding()]
param(
  [ValidateSet(
    'build',
    'check',
    'typecheck',
    'test',
    'package-dir',
    'dist-win',
    'dist-win-portable',
    'dist-mac',
    'dist-mac-smoke',
    'dev',
    'start',
    'all'
  )]
  [string]$Target = 'build',

  [switch]$SkipSubmodule,
  [switch]$SkipInstall,
  [switch]$SkipPull,
  [switch]$Upstream,
  [switch]$KeepGoing,
  [string]$Proxy = 'http://127.0.0.1:15715',
  [switch]$NoProxy,
  [switch]$Force,
  [switch]$NoZip,
  [switch]$Overlay,
  [switch]$KeepTimestamps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:Root = $PSScriptRoot
$script:Src = Join-Path $script:Root 'dsh-desktop'
# dsh-desktop 是否作为本仓库的 git 子模块注册：决定 Ensure-Source 采用
# submodule 工作流（对齐 pinned commit）还是回退到手动放置源码。
$script:SrcRegisteredAsSubmodule = $false
$script:GitmodulesPath = Join-Path $script:Root '.gitmodules'
if (Test-Path -LiteralPath $script:GitmodulesPath) {
  $script:GitmodulesText = Get-Content -LiteralPath $script:GitmodulesPath -Raw -ErrorAction SilentlyContinue
  if ($script:GitmodulesText -match '(?m)^\s*path\s*=\s*dsh-desktop\s*$') {
    $script:SrcRegisteredAsSubmodule = $true
  }
}
$script:StartedAt = Get-Date
$script:StepIndex = 0
$script:Failed = 0
$script:LogPath = $null
$script:YarnCmd = $null
$script:StatePath = Join-Path $script:Root '.build-state.json'
$script:GithubVersion = $null
# 产品线固定为 stable：只构建 dsh-plugin-desktop（beta 通道已移除）
$script:Channel = 'stable'
$script:ChannelWsName = 'dsh-plugin-desktop'
$script:ElectronOverride = '44.3.0'   # 本地覆盖层：electron 固定版本
# deepseek-harness（dsh 运行时）版本固定：本地把 stable 通道从上游的 0.1.5-rc.1
# 升到 0.1.5-rc.2（上游 master 尚未合并 rc.2，pull 会把依赖重置回 rc.1，所以每次
# 构建后由 Set-RuntimeVersionPinned 重新固定）。改版本 = 改这两个值 + 重新生成
# vendor/dsh-runtime/<版本>/（yarn upstream:prepare-runtime && sync-vendored-runtime）。
$script:RuntimeVersion = '0.1.5-rc.2'
$script:HarnessCommit  = 'fb2c4b9e698e30edb738bca4cf0618587db7d203'  # dsh-v0.1.5-rc.2 tag
# 排除 beta 通道：不再安装 dsh-plugin-desktop-beta 的依赖、不参与任何编译，
# 其 manifest 也不再被 AA 准备脚本读取/改写。设为 $false 可临时恢复 beta。
$script:DisableBeta = $true
# AA（Agents-Anywhere）源固定：默认跟随 main，但 main 上游 10300fd5 的 typecheck
# 是坏的（TS2717/TS2344 重复类型声明），全量重建必然失败。固定到最后一个成功
# 构建过的 commit（00df092，产物 c00df092…tgz 已验证），prepare 脚本会走
# “Reusing verified AA artifact” 快路径，不重建。上游修好后再改回 'main'。
$script:AaSourceRef = '00df092c98b271098cba18b4f96d91f5008c2cd4'

# ---- src 覆盖层（用户自定义源码改动，-Overlay 时自动生效）----
# 覆盖层目录（包根 overlay\，不属于 dsh-desktop 仓库，pull 不受影响）：
#   overlay\src\<basename>         新建文件副本（pull 前备份，pull 后恢复）
#   overlay\patches\<basename>.patch  已跟踪文件的修改（pull 前 git diff 导出，pull 后 git apply）
# 往下面两个数组加仓库相对路径即可扩展；覆盖层构建时若检测到工作区里这些文件
# 有未保存的改动/新文件，会自动先导出再重置，因此“改了源码 → 跑 quick-build-overlay”
# 就能把改动固化进覆盖层。
$script:SrcOverlayDir = Join-Path $script:Root 'overlay'
$script:SrcOverlayFiles = @(
  'dsh-plugin-desktop/src/startup-config.ts'          # 新建文件（上游无此文件）
  'dsh-plugin-desktop/tests/startup-config.spec.ts'   # 新建测试文件（上游无此文件）
)
$script:SrcPatchFiles = @(
  'dsh-plugin-desktop/src/main.ts'                     # 已跟踪文件的修改
  'dsh-plugin-desktop/README.md'                       # 启动配置文件使用文档（构建时注入）
  'dsh-plugin-desktop/README.zh.md'                    # 同上（中文版）
)

function Write-Banner {
  param([string]$Text, [ConsoleColor]$Color = 'Cyan')
  $line = ('=' * 72)
  Write-Host $line -ForegroundColor $Color
  Write-Host $Text -ForegroundColor $Color
  Write-Host $line -ForegroundColor $Color
}

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO ] $Message" -ForegroundColor Gray
}

function Write-Ok {
  param([string]$Message)
  Write-Host "[ OK  ] $Message" -ForegroundColor Green
}

function Write-WarnLine {
  param([string]$Message)
  Write-Host "[WARN ] $Message" -ForegroundColor Yellow
}

function Write-ErrLine {
  param([string]$Message)
  Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Log {
  param([string]$Message)
  if ($script:LogPath) {
    Add-Content -LiteralPath $script:LogPath -Value $Message -Encoding utf8
  }
}

function Initialize-Log {
  $logDir = Join-Path $script:Root 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $script:LogPath = Join-Path $logDir "build-$stamp.log"
  $header = @(
    "DSH Desktop build log"
    "started : $($script:StartedAt.ToString('o'))"
    "root    : $script:Root"
    "src     : $script:Src"
    "target  : $Target"
    "host    : $([System.Environment]::OSVersion.VersionString)"
    "arch    : $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
    ""
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath $script:LogPath -Value $header -Encoding utf8
  Write-Info "日志: $script:LogPath"
}

function Invoke-Logged {
  param(
    [Parameter(Mandatory)]
    [scriptblock]$ScriptBlock,
    [string]$Title
  )
  Write-Log "---- $Title ----"
  $output = & $ScriptBlock 2>&1
  foreach ($item in @($output)) {
    $text = if ($null -eq $item) { '' } else { [string]$item }
    Write-Host $text
    Write-Log $text
  }
}

function Assert-Command {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Hint
  )
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) {
    $suffix = if ($Hint) { " $Hint" } else { '' }
    throw "未找到命令 `$Name`。$suffix"
  }
  return $cmd
}

function Get-JsonObject {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "缺少文件: $Path"
  }
  return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

# 当前 GitHub 版本：dsh-desktop 仓库（origin = github.com/anywhere-labs/dsh-desktop）的 HEAD commit。
function Get-GithubVersion {
  $head = (git -C $script:Src rev-parse HEAD).Trim()
  if (-not $head) {
    throw "无法读取 $($script:Src) 的 HEAD commit（GitHub 版本）。"
  }
  return [pscustomobject]@{
    Full  = $head
    Short = $head.Substring(0, [Math]::Min(12, $head.Length))
  }
}

function Get-ShortHash {
  param([string]$Hash)
  if (-not $Hash) { return '' }
  return $Hash.Substring(0, [Math]::Min(12, $Hash.Length))
}

function Read-BuildState {
  if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
  try {
    return Get-Content -LiteralPath $script:StatePath -Raw -Encoding utf8 | ConvertFrom-Json
  } catch {
    Write-WarnLine "无法解析 $script:StatePath，本次跳过版本确认。"
    return $null
  }
}

function Save-BuildState {
  $state = [ordered]@{
    lastCompiledVersion = $script:GithubVersion.Full
    lastCompiledAt      = (Get-Date).ToString('o')
    lastTarget          = $Target
    lastChannel         = $script:Channel
    lastLockHash        = (Get-FileHash (Join-Path $script:Src 'yarn.lock') -Algorithm SHA256).Hash
  }
  Set-Content -LiteralPath $script:StatePath -Value ($state | ConvertTo-Json) -Encoding utf8
  Write-Info "已记录本次编译版本 $($script:GithubVersion.Short)（通道 $script:Channel），写入 $script:StatePath"
}

function Invoke-VersionGuard {
  $state = Read-BuildState
  if (-not $state -or -not $state.lastCompiledVersion) { return }

  $stateChannel = $null
  if ($state.PSObject.Properties.Name -contains 'lastChannel') { $stateChannel = $state.lastChannel }

  if ($stateChannel -and $stateChannel -ne $script:Channel) {
    Write-Info "通道切换：上次编译 $stateChannel，本次 $script:Channel（版本 $($script:GithubVersion.Short)）。"
    return
  }

  if ($state.lastCompiledVersion -ne $script:GithubVersion.Full) {
    Write-Info "检测到新版本：$($script:GithubVersion.Short)（上次编译 $(Get-ShortHash $state.lastCompiledVersion)）"
    if ($SkipInstall) {
      Write-WarnLine '检测到新版本但使用了 -SkipInstall：依赖可能不匹配，编译很可能失败。'
      Write-WarnLine '建议先执行一次完整构建（不带 -SkipInstall）更新依赖，再使用 quick-build.bat 增量编译。'
    }
    return
  }

  Write-WarnLine "当前 GitHub 版本 ($($script:GithubVersion.Short)) 与上次编译的版本相同（通道 $script:Channel）。"
  Write-WarnLine "上次编译时间 $($state.lastCompiledAt)，目标 $($state.lastTarget)。"
  if ($Force) {
    Write-WarnLine '-Force 已指定：跳过询问，继续构建。'
    return
  }
  if ([Console]::IsInputRedirected) {
    Write-WarnLine '非交互环境（输入已重定向）：无法询问，继续构建。'
    return
  }
  $answer = Read-Host '  直接回车继续构建；输入 N 跳过本次构建'
  if ($answer -match '^\s*n(?:o)?\s*$' -or $answer -match '^\s*(不|否)\s*$') {
    Write-Info '已跳过本次构建（版本未变化）。'
    exit 0
  }
}

function Test-NodeVersion {
  param([string]$Raw)
  $version = $Raw.TrimStart('v')
  $parts = $version.Split('.')
  $major = [int]$parts[0]
  $minor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
  if ($major -eq 22 -and $minor -ge 19) { return $true }
  if ($major -ge 24) { return $true }
  return $false
}

function Get-YarnLauncher {
  $corepack = Get-Command corepack.cmd -ErrorAction SilentlyContinue
  if (-not $corepack) {
    $corepack = Get-Command corepack -ErrorAction SilentlyContinue
  }
  if (-not $corepack) {
    throw '未找到 corepack。请安装 Node.js 22.19+ / 24.x（官方发行版自带 Corepack）。'
  }
  # Do not run `corepack enable`: it writes shims into Program Files and
  # fails with EPERM on a non-admin Windows Node install. Invoking
  # `corepack yarn` from dsh-desktop/ is enough for the pinned Yarn 4.18.0.
  if (-not $env:COREPACK_ENABLE_DOWNLOAD_PROMPT) {
    $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
  }
  return @{
    FileName = $corepack.Source
    Prefix   = @('yarn')
  }
}

function Invoke-Yarn {
  param([Parameter(Mandatory)][string[]]$Args)
  $yarn = $script:YarnCmd
  & $yarn.FileName @($yarn.Prefix + $Args)
  if ($LASTEXITCODE -ne 0) {
    throw "yarn $($Args -join ' ') 失败 (exit $LASTEXITCODE)"
  }
}

function Invoke-External {
  param(
    [Parameter(Mandatory)][string]$FileName,
    [string[]]$Args = @(),
    [string]$WorkingDirectory
  )
  $prev = Get-Location
  try {
    if ($WorkingDirectory) {
      Set-Location -LiteralPath $WorkingDirectory
    }
    & $FileName @Args
    if ($LASTEXITCODE -ne 0) {
      throw "$FileName $($Args -join ' ') 失败 (exit $LASTEXITCODE)"
    }
  } finally {
    Set-Location $prev
  }
}

function Invoke-Step {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Action,
    [switch]$Optional
  )
  $script:StepIndex++
  $label = ('[{0:00}] {1}' -f $script:StepIndex, $Name)
  Write-Host ''
  Write-Host $label -ForegroundColor Cyan
  Write-Log "`n$label"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $Action
    $sw.Stop()
    Write-Ok ("{0} 完成 ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds)
  } catch {
    $sw.Stop()
    $script:Failed++
    Write-ErrLine ("{0} 失败 ({1:n1}s): {2}" -f $Name, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
    Write-Log $_.ToString()
    if ($Optional -or $KeepGoing) {
      Write-WarnLine "已按 KeepGoing/Optional 继续。"
      return
    }
    throw
  }
}

function Show-Environment {
  $pkg = Get-JsonObject (Join-Path $script:Src 'package.json')
  $upstream = Get-JsonObject (Join-Path $script:Src 'upstream.json')
  $channelInfo = $upstream.channels.$script:Channel
  $wsPkg = Get-JsonObject (Get-ChannelWsPath 'package.json')
  $node = (node -v)
  $git = (git --version)
  $corepackVer = try { corepack --version } catch { 'unavailable' }

  Write-Banner "DSH Desktop ($script:Channel)  $($wsPkg.version)"
  Write-Info "目标        : $Target"
  Write-Info "通道        : $script:Channel（$script:ChannelWsName）"
  Write-Info "覆盖层      : $(if ($Overlay) { '开（-Overlay）' } else { '关（上游原样）' })"
  Write-Info "仓库根      : $script:Src"
  Write-Info "操作系统    : $([System.Environment]::OSVersion.VersionString)"
  Write-Info "架构        : $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
  Write-Info "Node        : $node"
  Write-Info "Corepack    : $corepackVer"
  Write-Info "Yarn pin    : $($pkg.packageManager)"
  Write-Info "Git         : $git"
  Write-Info "上游仓库    : $($upstream.repository)"
  if ($channelInfo) {
    Write-Info "上游 commit : $($channelInfo.commit)（$script:Channel 通道）"
    Write-Info "上游版本    : $($channelInfo.sourceVersion)"
    Write-Info "运行时包    : $($channelInfo.runtimePackageVersion)"
  }
  Write-Info "GitHub HEAD  : $($script:GithubVersion.Short)"
  if ($NoProxy) {
    Write-Info "代理        : 已禁用"
  } elseif ($Proxy) {
    Write-Info "代理        : $Proxy"
  }
}

function Assert-Prerequisites {
  if (-not (Test-Path -LiteralPath (Join-Path $script:Src 'package.json'))) {
    throw "未找到 dsh-desktop\package.json。请确认代码位于 $script:Src"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $script:Src 'yarn.lock'))) {
    throw '缺少 dsh-desktop\yarn.lock，无法执行不可变安装。'
  }

  Assert-Command git '请先安装 Git。' | Out-Null
  Assert-Command node '需要 Node.js ^22.19.0 或 >=24.0.0。' | Out-Null
  $nodeVersion = (node -v)
  if (-not (Test-NodeVersion $nodeVersion)) {
    throw "当前 Node 为 $nodeVersion，需要 ^22.19.0 或 >=24.0.0。"
  }

  $script:YarnCmd = Get-YarnLauncher
  Write-Ok "环境检查通过 (Node $nodeVersion)"
}

function Initialize-Submodule {
  $gitDir = Join-Path $script:Src '.git'
  if (-not (Test-Path -LiteralPath $gitDir)) {
    throw "dsh-desktop 不是 Git 仓库（缺少 .git）。子模块只能在 Git checkout 中初始化。"
  }

  $upstream = Get-JsonObject (Join-Path $script:Src 'upstream.json')
  $channelInfo = $upstream.channels.$script:Channel
  if (-not $channelInfo -or -not $channelInfo.commit) {
    throw "upstream.json 中找不到通道 $script:Channel 的 pinned commit。"
  }
  $harness = Join-Path $script:Src 'deepseek-harness'
  $harnessPkg = Join-Path $harness 'package.json'

  Invoke-External git @(
    '-C', $script:Src,
    'submodule', 'update', '--init', '--recursive'
  ) 

  if (-not (Test-Path -LiteralPath $harnessPkg)) {
    throw '子模块初始化后仍缺少 deepseek-harness\package.json。请检查网络或 Git 凭据。'
  }

  $head = (git -C $harness rev-parse HEAD).Trim()
  if ($head -ne $channelInfo.commit) {
    Write-WarnLine "检出 commit 为 $head，期望 $($channelInfo.commit)（通道 $script:Channel），正在强制对齐 pinned commit。"
    Invoke-External git @('-C', $harness, 'fetch', '--depth', '1', 'origin', $channelInfo.commit)
    Invoke-External git @('-C', $harness, 'checkout', '--detach', $channelInfo.commit)
  }

  $head = (git -C $harness rev-parse HEAD).Trim()
  if ($head -ne $channelInfo.commit) {
    throw "上游子模块 HEAD=$head，与 upstream.json 中通道 $script:Channel 的 $($channelInfo.commit) 不一致。"
  }
  Write-Ok "上游子模块已固定到 $head（通道 $script:Channel）"
}

# 构建资源（如托盘图标）若被置为只读，sharp 覆写时报 Permission denied，
# 导致 yarn build 直接失败。编译前统一清除只读标记。
function Clear-ReadOnlyAssets {
  $dirs = @(
    (Get-ChannelWsPath 'build')
  )
  foreach ($dir in $dirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $ro = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.IsReadOnly })
    if ($ro.Count -gt 0) {
      $ro | ForEach-Object { $_.IsReadOnly = $false }
      Write-WarnLine ("已清除 {0} 个只读构建资源（例：{1}）" -f $ro.Count, $ro[0].Name)
    }
  }
}

# 打包环境准备（仅网络受限的机器需要，幂等）：
#   @electron/rebuild 需要 Electron 头文件，其硬编码从 www.electronjs.org 下载（本机不通），
#   改为从 npmmirror 预置到 ~/.electron-gyp/<version>，node-gyp 命中缓存即不再联网。
#   注意：package:dir / dist:* 均已用 npmRebuild=false 跳过原生重编译（node-pty 走预编译
#   二进制），此步骤仅在确实需要重编译原生模块时兜底。
function Prepare-PackagingEnvironment {
  $electronPkg = Get-ChannelWsPath 'node_modules\electron\package.json'
  if (-not (Test-Path -LiteralPath $electronPkg)) {
    Write-WarnLine '未找到已安装的 electron，跳过打包环境准备。'
    return
  }
  $electronVersion = (Get-JsonObject $electronPkg).version

  # Electron 头文件缓存（@electron/rebuild 的 node-gyp devDir）
  $gypDir = Join-Path $HOME '.electron-gyp'
  $devDir = Join-Path $gypDir $electronVersion
  $configGypi = Join-Path $devDir 'include\node\config.gypi'
  $nodeLib = Join-Path $devDir 'x64\node.lib'
  if (-not (Test-Path -LiteralPath $configGypi) -or -not (Test-Path -LiteralPath $nodeLib)) {
    Write-WarnLine "缺少 Electron $electronVersion 头文件缓存，正在从 npmmirror 准备 $devDir ..."
    New-Item -ItemType Directory -Force -Path $devDir | Out-Null
    $tar = Join-Path $env:TEMP "node-v$electronVersion-headers.tar.gz"
    Invoke-WebRequest -Uri "https://npmmirror.com/mirrors/electron/$electronVersion/node-v$electronVersion-headers.tar.gz" `
      -OutFile $tar -UseBasicParsing -TimeoutSec 180
    tar -xzf $tar -C $devDir --strip-components=1
    New-Item -ItemType Directory -Force -Path (Join-Path $devDir 'x64') | Out-Null
    Invoke-WebRequest -Uri "https://npmmirror.com/mirrors/electron/$electronVersion/win-x64/node.lib" `
      -OutFile (Join-Path $devDir 'x64\node.lib') -UseBasicParsing -TimeoutSec 60
    Set-Content -LiteralPath (Join-Path $devDir 'installVersion') -Value '11' -NoNewline -Encoding ascii
    Write-Ok "Electron 头文件缓存已就绪: $devDir"
  }

  Ensure-ElectronDist
}

# electron-builder 现在优先使用本地 node_modules\electron\dist，而 .yarnrc.yml 的
# enableScripts:false 让 electron 的 postinstall 不执行 → dist 缺失 → 打包报
# "The specified electronDist does not exist"。这里按需运行 electron 自带 install.js
# （优先复用 @electron/get 缓存，缺失时走 ELECTRON_MIRROR 镜像）。
function Ensure-ElectronDist {
  $elDir = Get-ChannelWsPath 'node_modules\electron'
  $installer = Join-Path $elDir 'install.js'
  if (-not (Test-Path -LiteralPath $installer)) { return }
  $distDir = Join-Path $elDir 'dist'
  if (Test-Path -LiteralPath $distDir) {
    Write-Info "electron dist 已就绪：$distDir"
    return
  }
  Write-WarnLine "缺少 $distDir，正在运行 electron install.js 解包（复用缓存/镜像）..."
  Push-Location $elDir
  try {
    & node install.js
    if ($LASTEXITCODE -ne 0) { Write-WarnLine "electron install.js 退出码 $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
  if (Test-Path -LiteralPath $distDir) {
    Write-Ok "electron dist 已就绪：$distDir"
  } else {
    Write-WarnLine 'electron dist 仍缺失，electron-builder 打包会失败。'
  }
}

# ---- 本地覆盖层（pull 后自动重应用，保留本地定制）----
# 覆盖层管理的仓库内文件：pull 前丢弃其本地改动（避免冲突），pull 后重新应用。

function Export-SrcOverlay {
  # 覆盖层构建前，把工作区里 src 覆盖层文件的新改动固化到包根 overlay\：
  #   1) $script:SrcPatchFiles（已跟踪）→ git diff 导出为 overlay\patches\<basename>.patch
  #   2) $script:SrcOverlayFiles（新建/未跟踪）→ 复制为 overlay\src\<basename>
  # 仅 -Overlay 时执行（无覆盖层构建不应收走用户源码改动）；随后 Reset-OverlayTrackedFiles
  # 会 checkout 掉跟踪文件的改动、移除未跟踪文件，pull 后才由 Apply-SrcOverlay 恢复。
  if (-not $script:Overlay) { return }
  if (-not $script:SrcOverlayDir) { return }
  New-Item -ItemType Directory -Force -Path (Join-Path $script:SrcOverlayDir 'patches') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $script:SrcOverlayDir 'src') | Out-Null
  foreach ($rel in $script:SrcPatchFiles) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
      $diff = @(& git -C $script:Src diff -- $rel)
      $diffCode = $LASTEXITCODE
    } finally {
      $PSNativeCommandUseErrorActionPreference = $prevNative
    }
    if ($diffCode -ne 0) { throw "git diff 失败: $rel (exit $diffCode)" }
    if ($diff.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(($diff -join ''))) {
      $patch = Join-Path (Join-Path $script:SrcOverlayDir 'patches') "$([IO.Path]::GetFileName($rel)).patch"
      # git diff 在 PowerShell 中按行拆成 string[]，必须显式用 LF 重新连接
      # （WriteAllText 直接收数组会用空格拼，破坏补丁格式）。
      [System.IO.File]::WriteAllText($patch, [string]::Join("`n", $diff) + "`n")
      Write-WarnLine "覆盖层：已导出 $rel 的本地改动 → $patch"
    }
  }
  foreach ($rel in $script:SrcOverlayFiles) {
    $repoPath = Join-Path $script:Src $rel
    if (Test-Path -LiteralPath $repoPath) {
      $dst = Join-Path (Join-Path $script:SrcOverlayDir 'src') ([IO.Path]::GetFileName($rel))
      Copy-Item -LiteralPath $repoPath -Destination $dst -Force
      Write-WarnLine "覆盖层：已备份 $rel → $dst"
    }
  }
}

function Get-ChannelWsPath {
  param([string]$SubPath = '')
  if ($SubPath) {
    return Join-Path $script:Src (Join-Path $script:ChannelWsName $SubPath)
  }
  return Join-Path $script:Src $script:ChannelWsName
}

function Reset-OverlayTrackedFiles {
  # pull 前丢弃覆盖层文件的本地改动，避免与上游改动冲突。
  Push-Location $script:Src
  try {
    # 先导出/备份 src 覆盖层改动（仅 -Overlay 时，见 Export-SrcOverlay），
    # 否则下面的 checkout 会把这些改动直接丢掉。
    Export-SrcOverlay
    # 说明：除覆盖层文件外，还包括“构建过程会改写”的受跟踪文件（AA 依赖对齐 /
    # 本地定制 app-icon.ico）。它们每次构建都会被重新生成或重新拷贝，pull 前丢弃
    # 本地改动不会丢东西；不丢弃则上游一改这些文件 pull 就会失败。
    # 注意：不要加入 vendor/agents-anywhere/provenance.json —— 其 commit 必须与
    # AA main 解析结果一致，prepare 脚本才会走 “Reusing verified AA artifact”
    # 快路径；重置为上游旧值会触发全量重建，撞上 “Existing artifact differs” 守卫。
    $exact = @('.yarnrc.yml', 'yarn.lock', 'package.json', 'upstream.json') + @(
      'package.json',
      'dsh-plugin-desktop/package.json',
      'dsh-plugin-desktop-beta/package.json',
      'dsh-community-market/package.json',
      'dsh-plugin-desktop/scripts/package-dir.mjs',
      'dsh-plugin-desktop/scripts/generate-windows-app-icon.mjs',
      'dsh-plugin-desktop/build/app-icon.ico',
      'scripts/prepare-agents-anywhere-release.mjs',
      'vendor/agents-anywhere/provenance.json'
    ) + $script:SrcPatchFiles
    $targets = @()
    foreach ($line in @(git status --porcelain)) {
      if ($line.Length -lt 4) { continue }
      $p = $line.Substring(3).Trim().Trim('"')
      if ($exact -contains $p) { $targets += $p; continue }
      if ($p -match '^dsh-plugin-desktop/build/tray-icon') { $targets += $p }
    }
    if ($targets.Count -gt 0) {
      Write-Info "丢弃覆盖层文件的本地改动（$($targets.Count) 个），以便拉取上游：$($targets -join ', ')"
      & git -C $script:Src checkout -- $targets
      if ($LASTEXITCODE -ne 0) {
        throw "git checkout -- $($targets -join ' ') 失败 (exit $LASTEXITCODE)"
      }
    }
    # 移除 src 覆盖层里的未跟踪新文件（已备份到 overlay\src\）：防止上游未来新增
    # 同名文件时 pull 报 “untracked working tree files would be overwritten”。
    if ($script:Overlay) {
      foreach ($rel in $script:SrcOverlayFiles) {
        $repoPath = Join-Path $script:Src $rel
        if (-not (Test-Path -LiteralPath $repoPath)) { continue }
        # 脚本顶部 $PSNativeCommandUseErrorActionPreference=$true：ls-files 对未跟踪
        # 文件返回非零会直接抛异常，先临时关闭，用退出码判断是否已跟踪。
        $prevNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        try {
          $trackedLines = @(& git -C $script:Src ls-files -- $rel 2>$null)
        } finally {
          $PSNativeCommandUseErrorActionPreference = $prevNative
        }
        if ($trackedLines.Count -eq 0) {
          Remove-Item -LiteralPath $repoPath -Force
          Write-WarnLine "覆盖层：已暂存未跟踪的 $rel（pull 前移除，构建后恢复）"
        }
      }
    }
  } finally {
    Pop-Location
  }
}

function Set-ElectronOverride {
  # <channel>/package.json 的 devDependencies.electron → $script:ElectronOverride
  $pkgPath = Get-ChannelWsPath 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) {
    throw "通道 $script:Channel 的工作区不存在：$pkgPath。请先同步到最新 master（双通道目录结构）。"
  }
  $text = Get-Content -LiteralPath $pkgPath -Raw -Encoding utf8
  if ($text -match '("electron"\s*:\s*")([^"]+)(")') {
    $current = $Matches[2]
    if ($current -ne $script:ElectronOverride) {
      $fixed = [regex]::Replace($text, '("electron"\s*:\s*")([^"]+)(")', "`${1}$($script:ElectronOverride)`${3}", 1)
      Set-Content -LiteralPath $pkgPath -Value $fixed -Encoding utf8 -NoNewline
      Write-WarnLine "覆盖层：$script:ChannelWsName electron $current → $($script:ElectronOverride)"
      return $true
    }
  } else {
    Write-WarnLine "覆盖层：$pkgPath 中未找到 electron 声明，跳过。"
  }
  return $false
}

function Set-AgeGateConfig {
  # .yarnrc.yml 确保 npmMinimalAgeGate: 0（Yarn 4.18 默认 1 天会拒绝刚发布的版本）
  $rc = Join-Path $script:Src '.yarnrc.yml'
  if (-not (Test-Path -LiteralPath $rc)) { return }
  $text = Get-Content -LiteralPath $rc -Raw -Encoding utf8
  if ($text -notmatch 'npmMinimalAgeGate') {
    $addition = "npmMinimalAgeGate: 0`n"
    Set-Content -LiteralPath $rc -Value ($text.TrimEnd() + "`n`n# 本地覆盖层：关闭版本年龄门禁（支持自行指定的新版本，如 electron 44.3.0）`n" + $addition) -Encoding utf8 -NoNewline
    Write-WarnLine '覆盖层：.yarnrc.yml 已加入 npmMinimalAgeGate: 0'
  }
}

function Set-PackageDirRebuildDisabled {
  # <ws>/scripts/package-dir.mjs 跳过原生重编译（与官方 dist:win* 一致）。
  # 本机必需：node-pty 重编译需要 Spectre 库 / Electron 头文件下载（网络受限），
  # 关掉它才能在这台机器上打包。适配 PR #829 重写后的数组结构，也兼容旧写法。
  param([string]$WorkspaceName = $script:ChannelWsName)
  $mjs = Join-Path $script:Src (Join-Path $WorkspaceName 'scripts\package-dir.mjs')
  if (-not (Test-Path -LiteralPath $mjs)) { return }
  $text = Get-Content -LiteralPath $mjs -Raw -Encoding utf8
  if ($text -match "'--config\.npmRebuild=false'") {
    Write-Info "npmRebuild=false 已生效：$mjs"
    return
  }

  # 新版（PR #829 起）：在 UNSIGNED_DIRECTORY_BUILD_ARGS 数组的 '--dir' 后追加
  if ($text -match "'--dir',\r?\n\s*'--publish'") {
    $fixed = $text -replace "'--dir',(\r?\n)(\s*)'--publish'", "'--dir',`$1`$2'--config.npmRebuild=false',`$1`$2'--publish'"
    Set-Content -LiteralPath $mjs -Value $fixed -Encoding utf8 -NoNewline
    Write-WarnLine "修复：$WorkspaceName\scripts\package-dir.mjs 已禁用原生重编译（新版数组）"
    return
  }

  # 旧版：直接给 builderCli 调用行追加参数
  if ($text -match "\[builderCli,\s*'--dir'\]") {
    $fixed = $text -replace "\[builderCli,\s*'--dir'\]", "[builderCli, '--dir', '--config.npmRebuild=false']"
    Set-Content -LiteralPath $mjs -Value $fixed -Encoding utf8 -NoNewline
    Write-WarnLine "修复：$WorkspaceName\scripts\package-dir.mjs 已禁用原生重编译"
    return
  }

  Write-WarnLine "修复：$WorkspaceName\scripts\package-dir.mjs 未找到可插入 npmRebuild=false 的位置，打包可能触发原生重编译。"
}

function Set-AllArtifactVerifyDisabled {
  # PR #829 新增了 build.afterAllArtifactBuild（scripts/verify-electron-fuses.ts）这个
  # 事后校验钩子。在 win --dir 打包下它有两个上游缺陷，必然导致打包失败：
  #   1) 架构误判：electron-builder 的 WinPackager.createTargets 直接跳过 'dir' 目标
  #      （不写入 platformToTargets 的 target map），win 平台 --dir 构建的 Map 为空，
  #      钩子拿不到架构，抛 "cannot determine requested Electron architecture(s) for win"；
  #   2) 即使放行，其调用的 packaged-runtime 冒烟会用字面路径断言 rgPath 必须位于
  #      app.asar.unpacked，但 Electron smartUnpack 下 require.resolve 必然返回逻辑
  #      app.asar 路径（访问时才重定向），断言无法满足。
  # fuses 本身已由 electron-builder 应用（executing @electron/fuses），该钩子仅是事后
  # 复核。本机必需修复：从 package.json 移除该钩子，恢复 PR #829 之前的打包行为。
  param([string]$WorkspaceName = $script:ChannelWsName)
  $pkgPath = Join-Path $script:Src (Join-Path $WorkspaceName 'package.json')
  if (-not (Test-Path -LiteralPath $pkgPath)) { return }
  $text = Get-Content -LiteralPath $pkgPath -Raw -Encoding utf8
  if ($text -notmatch 'afterAllArtifactBuild') {
    Write-Info "已无 afterAllArtifactBuild 钩子：$pkgPath"
    return
  }
  $fixed = $text -replace '(?m)^[ \t]*"afterAllArtifactBuild"\s*:\s*"[^"]*",?\r?\n', ''
  if ($fixed -eq $text) {
    Write-WarnLine "修复：$pkgPath 中未能移除 afterAllArtifactBuild（格式异常），跳过。"
    return
  }
  try {
    $null = $fixed | ConvertFrom-Json
  } catch {
    Write-WarnLine "修复：移除 afterAllArtifactBuild 后 $pkgPath 不是合法 JSON，已跳过。"
    return
  }
  Set-Content -LiteralPath $pkgPath -Value $fixed -Encoding utf8 -NoNewline
  Write-WarnLine "修复：已从 $pkgPath 移除 build.afterAllArtifactBuild（禁用 PR #829 事后校验钩子）"
}

# 排除 beta 通道（$script:DisableBeta = $true）：
#   1) 根 package.json 的 workspaces 移除 "dsh-plugin-desktop-beta" → yarn install 不再
#      安装 beta 的依赖，beta 完全不参与编译；
#   2) 给 scripts/prepare-agents-anywhere-release.mjs 打补丁：两处桌面 manifest 列表
#      （读 peer ranges 处、复用校验/重建时改写处）改为仅 stable → beta 的
#      package.json 不再被 AA 流程读取/改写。
#   两个文件都在 pull 前重置清单里，pull 后重新应用，幂等。
function Disable-BetaWorkspace {
  if (-not $script:DisableBeta) { return }

  # 1) 根 workspaces
  $pkgPath = Join-Path $script:Src 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) { return }
  $text = [System.IO.File]::ReadAllText($pkgPath)
  if ($text -notmatch '"dsh-plugin-desktop-beta"') {
    Write-Info 'beta 排除：根 workspaces 已不含 dsh-plugin-desktop-beta'
  } else {
    $fixed = [regex]::Replace($text, '(?m)^[ \t]*"dsh-plugin-desktop-beta",[ \t]*\r?\n', '')
    if ($fixed -eq $text) {
      # 兜底 1：条目可能是数组最后一个（无尾逗号）
      $fixed = [regex]::Replace($text, '(?m)^[ \t]*,[ \t]*\r?\n[ \t]*"dsh-plugin-desktop-beta"[ \t]*\r?\n', '')
    }
    if ($fixed -eq $text) {
      # 兜底 2：单行格式
      $fixed = [regex]::Replace($text, '"dsh-plugin-desktop-beta",?\s*', '')
    }
    if ($fixed -eq $text) {
      Write-WarnLine 'beta 排除：未能从根 workspaces 移除 dsh-plugin-desktop-beta（格式变化？）'
      return
    }
    try {
      $null = $fixed | ConvertFrom-Json
    } catch {
      Write-WarnLine "beta 排除：移除后 JSON 解析失败，已放弃修改（$($_.Exception.Message)）"
      return
    }
    [System.IO.File]::WriteAllText($pkgPath, $fixed)
    Write-WarnLine 'beta 排除：根 workspaces 已移除 dsh-plugin-desktop-beta（不再安装/编译 beta 依赖）'
  }

  # 2) AA 准备脚本
  $aaPath = Join-Path $script:Src 'scripts\prepare-agents-anywhere-release.mjs'
  if (-not (Test-Path -LiteralPath $aaPath)) { return }
  $raw = [System.IO.File]::ReadAllText($aaPath)
  $old = "['dsh-plugin-desktop/package.json', 'dsh-plugin-desktop-beta/package.json']"
  $new = "['dsh-plugin-desktop/package.json']"
  if ($raw.Contains('dsh-plugin-desktop-beta')) {
    if (-not $raw.Contains($old)) {
      Write-WarnLine 'beta 排除：AA 脚本中的 beta 引用格式已变（无法打补丁），跳过。'
    } else {
      [System.IO.File]::WriteAllText($aaPath, $raw.Replace($old, $new))
      Write-WarnLine 'beta 排除：AA 准备脚本已改为仅处理 stable manifest'
    }
  } else {
    Write-Info 'beta 排除：AA 准备脚本已不含 beta 引用'
  }
}

# AA（Agents-Anywhere）桥接产物依赖对齐：
#   上游 package:dir 先跑 aa:prepare-release，其“复用已验证产物”的校验要求每个桌面
#   工作区的 "@agents-anywhere/dsh-bridge-next" 依赖行都指向 provenance.json 记录的
#   产物文件。pull 前的覆盖层清理会把该行还原成上游版本（可能指向旧产物），于是复用
#   失败 → 重新打包 → 与既有产物字节不同 → "refusing to overwrite it" 打包失败。
#   这里按 provenance 把相关工作区的依赖行对齐（幂等）。
#   默认只对齐 stable；仅当 AA 脚本补丁未生效（上游改过格式、仍会校验 beta）时才继续
#   对齐 beta，保证复用校验不失败。
# 运行时版本固定：把 stable 通道固定到 $script:RuntimeVersion（deepseek-harness 子模块
# commit / upstream.json / dsh-plugin-desktop 依赖 / 根 package.json resolutions）。
# pull 会把这些文件重置回上游（目前仍是 rc.1），每次构建后调用本函数恢复本地固定值，
# 幂等。vendor/dsh-runtime/<版本>/ 由上游 sync 流程生成（yarn upstream:prepare-runtime
# + node scripts/sync-vendored-runtime.mjs --write --channel stable）。
function Set-RuntimeVersionPinned {
  $v = $script:RuntimeVersion
  $vendorRelative = "vendor/dsh-runtime/$v"
  $manifestPath = Join-Path $script:Src ($vendorRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
  $manifestPath = Join-Path $manifestPath 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "运行时版本 $v 的 vendor manifest 缺失：$manifestPath。请先运行 yarn upstream:prepare-runtime 与 node scripts/sync-vendored-runtime.mjs --write --channel stable 生成。"
  }
  $manifest = Get-JsonObject $manifestPath
  $entryByName = @{}
  foreach ($p in @($manifest.packages)) { $entryByName[$p.name] = $p.filename }
  if ($entryByName.Count -eq 0) { throw "运行时 manifest 为空：$manifestPath" }

  # 1) upstream.json：stable 通道的 commit / 版本 / runtimeSource 固定
  $upPath = Join-Path $script:Src 'upstream.json'
  $up = Get-JsonObject $upPath
  $stable = $up.channels.stable
  $stable.commit = $script:HarnessCommit
  $stable.sourceVersion = $v
  $stable.runtimePackageVersion = $v
  $stable.runtimeSource = "$vendorRelative/manifest.json"
  Set-Content -LiteralPath $upPath -Value (ConvertTo-Json $up -Depth 10) -Encoding utf8 -NoNewline

  # 2) dsh-plugin-desktop + dsh-community-market 的 @deepseek-ai/dsh* 依赖 → $v
  #    （上游 stable 两包同版本；market 若仍声明 rc.1 会让 Yarn 嵌套安装 rc.1 副本，
  #    与 rc.2 的类型定义冲突 → TS2717/TS2344。）
  $pkgPaths = @(
    (Get-ChannelWsPath 'package.json'),
    (Join-Path $script:Src 'dsh-community-market\package.json')
  )
  foreach ($pkgPath in $pkgPaths) {
    if (-not (Test-Path -LiteralPath $pkgPath)) { continue }
    $pkg = Get-JsonObject $pkgPath
    $changed = $false
    foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
      $prop = $pkg.PSObject.Properties[$field]
      if (-not $prop -or $null -eq $prop.Value) { continue }
      $dep = $prop.Value
      foreach ($name in @($dep.PSObject.Properties.Name)) {
        $isDsh = $name -eq '@deepseek-ai/dsh' -or $name.StartsWith('@deepseek-ai/dsh-')
        if ($isDsh -and $entryByName.ContainsKey($name) -and $dep.$name -ne $v) {
          $dep.$name = $v
          $changed = $true
        }
      }
    }
    if ($changed) {
      Set-Content -LiteralPath $pkgPath -Value (ConvertTo-Json $pkg -Depth 100) -Encoding utf8 -NoNewline
      Write-WarnLine "运行时版本固定：$([IO.Path]::GetFileNameWithoutExtension($pkgPath)) 的 @deepseek-ai/dsh* 依赖 → $v"
    }
  }

  # 3) 根 package.json resolutions：删掉旧 stable 通道的 dsh 条目（@npm:$v / @npm:^$v，
  #    保留其他版本如 beta 的 rc.1），再从 manifest 重建指向 vendor/$v 的条目。
  $rootPkgPath = Join-Path $script:Src 'package.json'
  $rootPkg = Get-JsonObject $rootPkgPath
  $newRes = [ordered]@{}
  foreach ($sel in @($rootPkg.resolutions.PSObject.Properties.Name)) {
    $isStableDsh = ($sel -eq '@deepseek-ai/dsh' -or $sel.StartsWith('@deepseek-ai/dsh@') -or $sel.StartsWith('@deepseek-ai/dsh-')) `
      -and ($sel.EndsWith("@npm:$v") -or $sel.EndsWith("@npm:^$v"))
    if ($isStableDsh) { continue }
    $newRes[$sel] = $rootPkg.resolutions.$sel
  }
  foreach ($p in @($manifest.packages)) {
    $src = "file:$vendorRelative/$($p.filename)"
    $unscoped = $p.name.Substring('@deepseek-ai/'.Length)
    $patchRel = "patches/$unscoped@$v.patch"
    $patchPath = Join-Path $script:Src ($patchRel -replace '/', [IO.Path]::DirectorySeparatorChar)
    # 补丁版本迁移（自愈）：升级运行时版本时（如 rc.1→rc.2），旧版本补丁文件
    # （patches\<pkg>@<旧版本>.patch）不会自动适配新版本文件名。若这里检测不到
    # 新版本补丁，resolutions 会静默回退成无补丁的 file: 形式 → 桌面关键补丁
    # （agent-presets / app-boot 等）全部丢失 → Agent 预设 24 行插件无法解析。
    # 因此自动从同包"最新旧版本"补丁复制一份为新版本：pnpm install 会校验补丁与
    # 新版本 tarball 是否匹配，不匹配会显式失败（比静默丢补丁好，此时需人工按
    # 上游代码差异更新补丁内容）。
    if (-not (Test-Path -LiteralPath $patchPath)) {
      $oldPatch = Get-ChildItem -LiteralPath (Split-Path -Parent $patchPath) -Filter "$unscoped@*.patch" -File |
        Where-Object { $_.BaseName -ne "$unscoped@$v" } |
        Sort-Object Name -Descending | Select-Object -First 1
      if ($null -ne $oldPatch) {
        Copy-Item -LiteralPath $oldPatch.FullName -Destination $patchPath
        Write-WarnLine "补丁迁移：$($oldPatch.Name) → $(Split-Path -Leaf $patchPath)（pnpm install 将校验匹配性，不匹配需人工更新）"
      }
    }
    $val = if (Test-Path -LiteralPath $patchPath) { "patch:$($p.name)@$($src -replace ':', '%3A')#./$patchRel" } else { $src }
    $newRes["$($p.name)@npm:$v"] = $val
    $newRes["$($p.name)@npm:^$v"] = $val
  }
  $rootPkg.resolutions = $newRes
  Set-Content -LiteralPath $rootPkgPath -Value (ConvertTo-Json $rootPkg -Depth 100) -Encoding utf8 -NoNewline

  # 4) AA provenance 同步：runtimePeers 是 AA prepare 复用检查的关键条件（读 plugin
  #    的 dsh peer 依赖版本对比）。升级运行时版本后若不更新，AA prepare 会放弃复用
  #    已验证产物、进入全量重建，而重建在临时目录从 registry 拉包（rc.2 已发布 →
  #    混装 rc.1/rc.2）→ typecheck TS2717/TS2344 失败。commit 也固定为 AA 源
  #    （避免 pull 重置后回落）。
  $provPath = Join-Path $script:Src 'vendor\agents-anywhere\provenance.json'
  if (Test-Path -LiteralPath $provPath) {
    $prov = Get-JsonObject $provPath
    $provChanged = $false
    if ($prov.commit -ne $script:AaSourceRef) { $prov.commit = $script:AaSourceRef; $provChanged = $true }
    foreach ($peer in @('@deepseek-ai/dsh-typert-protocol', '@deepseek-ai/dsh-llm', '@deepseek-ai/dsh-session')) {
      $peerProp = $prov.runtimePeers.PSObject.Properties[$peer]
      if ($peerProp -and $peerProp.Value -ne $v) {
        $prov.runtimePeers.$peer = $v
        $provChanged = $true
      }
    }
    if ($provChanged) {
      Set-Content -LiteralPath $provPath -Value (ConvertTo-Json $prov -Depth 10) -Encoding utf8 -NoNewline
      Write-WarnLine "AA provenance 已同步（commit $($script:AaSourceRef.Substring(0,10))，runtimePeers → $v）"
    }
  }

  Write-Ok "运行时版本已固定：dsh $v（commit $($script:HarnessCommit.Substring(0,10))，$($entryByName.Count) 个包）"
}

function Set-AAVendorDependency {
  $provPath = Join-Path $script:Src 'vendor\agents-anywhere\provenance.json'
  if (-not (Test-Path -LiteralPath $provPath)) { return }
  $prov = Get-JsonObject $provPath
  if (-not $prov.artifact) { return }
  $expected = "file:../vendor/agents-anywhere/$($prov.artifact)"
  $aaScript = Join-Path $script:Src 'scripts\prepare-agents-anywhere-release.mjs'
  $alignBeta = (-not $script:DisableBeta) -or
    ((Test-Path -LiteralPath $aaScript) -and ([System.IO.File]::ReadAllText($aaScript)).Contains('dsh-plugin-desktop-beta'))
  $targets = @((Join-Path $script:Src 'dsh-plugin-desktop\package.json'))
  if ($alignBeta) { $targets += (Join-Path $script:Src 'dsh-plugin-desktop-beta\package.json') }
  foreach ($pkg in $targets) {
    if (-not (Test-Path -LiteralPath $pkg)) { continue }
    $text = Get-Content -LiteralPath $pkg -Raw -Encoding utf8
    if ($text -notmatch '"@agents-anywhere/dsh-bridge-next"\s*:\s*"([^"]+)"') { continue }
    if ($Matches[1] -eq $expected) { continue }
    $fixed = [regex]::Replace($text, '("@agents-anywhere/dsh-bridge-next"\s*:\s*")[^"]+(")', "`${1}$expected`${2}", 1)
    Set-Content -LiteralPath $pkg -Value $fixed -Encoding utf8 -NoNewline
    Write-WarnLine "修复：$(Split-Path (Split-Path $pkg) -Leaf) 的 AA 依赖已对齐 provenance（$($prov.artifact)）"
  }
}

# Windows 打包必需修复（不依赖 -Overlay）：
# 没有它们本机 win --dir 打包必然失败（原生重编译 / PR #829 钩子缺陷 / AA 复用校验）。
function Invoke-RequiredWinFixes {
  Disable-BetaWorkspace
  Set-PackageDirRebuildDisabled -WorkspaceName $script:ChannelWsName
  Set-AllArtifactVerifyDisabled -WorkspaceName $script:ChannelWsName
  Set-AAVendorDependency
  # 覆盖层/修复步骤会重写 package.json，且覆盖层里的 Reset-OverlayTrackedFiles
  # 会把 upstream.json / 根 package.json / 依赖版本还原回上游（目前仍是 rc.1）。
  # 必须在安装依赖之前把 stable 通道固定回本地版本，否则装出来的是旧运行时。
  Set-RuntimeVersionPinned
  Write-Ok 'Windows 打包必需修复已应用（beta 排除 / npmRebuild=false / 移除 PR #829 事后校验钩子 / AA 依赖对齐 / 运行时版本固定）'
}

function Copy-TrayIconAssets {
  # 本地定制图标（包根 build\*）→ 当前通道的 build 目录
  $srcDir = Join-Path $script:Root 'build'
  $dstDir = Get-ChannelWsPath 'build'
  if (-not (Test-Path -LiteralPath $srcDir) -or -not (Test-Path -LiteralPath $dstDir)) { return }
  $copied = 0
  Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $dstDir -Force
    $copied++
    $dst = Join-Path $dstDir $_.Name
    # 源文件常带只读属性，复制后会一并带过去，导致后续写入（svg 清洗 / 构建覆写）失败。
    try { [System.IO.File]::SetAttributes($dst, [System.IO.FileAttributes]::Normal) } catch {}
    # tray-icon.svg 必须是“裸 <svg>…</svg>”文档：上游 generate-windows-app-icon 用
    # ^<svg 剥壳再包一层 <g>，若 <svg> 之前有 XML 声明 / DOCTYPE / 注释（iconfont、
    # Axialis 等导出常见），剥壳会漏掉开标签 → 嵌套未闭合 <svg> → librsvg 报
    # “Opening and ending tag mismatch: g … and svg”。这里直接截取
    # 首个 '<svg' 到最后一个 '</svg>'。
    if ($_.Name -eq 'tray-icon.svg') {
      $svg = [System.IO.File]::ReadAllText($dst)
      $start = $svg.IndexOf('<svg')
      $end = $svg.LastIndexOf('</svg>')
      if ($start -gt 0 -or ($end -ge 0 -and $end + 6 -lt $svg.Length)) {
        if ($start -lt 0) { $start = 0 }
        $stop = if ($end -ge 0) { $end + 6 } else { $svg.Length }
        $cleaned = $svg.Substring($start, $stop - $start)
        [System.IO.File]::WriteAllText($dst, $cleaned)
        Write-WarnLine '覆盖层：tray-icon.svg 已规整为裸 <svg> 文档（去前导声明/注释）'
      }
    }
  }
  if ($copied -gt 0) {
    Write-WarnLine "覆盖层：已复制 $copied 个本地资源（$srcDir → $dstDir）"
  }
  if (Test-Path -LiteralPath (Join-Path $dstDir 'app-icon.ico')) {
    Set-WindowsAppIconKeepPatch
  }
}

# pnpm 的 dist/pnpm.mjs 本地补丁：getPublishedByPolicy 用 Number 规范化 minimumReleaseAge
# （原版对字符串配置（如 "0"）按 truthy 处理，导致年龄过滤被误启用）
$script:PnpmPristineBlock = @(
  'function getPublishedByPolicy(opts3) {'
  '  return {'
  '    publishedBy: opts3.minimumReleaseAge ? new Date(Date.now() - opts3.minimumReleaseAge * 60 * 1e3) : void 0,'
  '    publishedByExclude: opts3.minimumReleaseAgeExclude ? createPackageVersionPolicyOrThrow(opts3.minimumReleaseAgeExclude, "minimumReleaseAgeExclude") : void 0'
  '  };'
  '}'
)
$script:PnpmFixedBlock = @(
  'function getPublishedByPolicy(opts3) {'
  '  const minimumReleaseAge = Number(opts3.minimumReleaseAge);'
  '  const publishedBy = Number.isFinite(minimumReleaseAge) && minimumReleaseAge > 0 ? new Date(Date.now() - minimumReleaseAge * 60 * 1e3) : void 0;'
  '  return {'
  '    publishedBy: publishedBy instanceof Date && Number.isNaN(publishedBy.getTime()) ? void 0 : publishedBy,'
  '    publishedByExclude: opts3.minimumReleaseAgeExclude ? createPackageVersionPolicyOrThrow(opts3.minimumReleaseAgeExclude, "minimumReleaseAgeExclude") : void 0'
  '  };'
  '}'
)

function Set-PnpmDistPatch {
  # 在当前通道 workspace 的 node_modules/pnpm/dist/pnpm.mjs 上重应用补丁（yarn install 后调用）
  $targets = @(
    (Get-ChannelWsPath 'node_modules\pnpm\dist\pnpm.mjs')
  )
  foreach ($f in $targets) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $lines = [System.IO.File]::ReadAllLines($f)
    $raw = [System.IO.File]::ReadAllText($f)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($raw.Contains('Number.isFinite(minimumReleaseAge)')) {
      Write-Info "pnpm 补丁已生效：$f"
      continue
    }
    # 定位原版函数块（按行匹配）
    $startIdx = -1
    for ($i = 0; $i -le $lines.Length - $script:PnpmPristineBlock.Count; $i++) {
      $ok = $true
      for ($j = 0; $j -lt $script:PnpmPristineBlock.Count; $j++) {
        if ($lines[$i + $j] -ne $script:PnpmPristineBlock[$j]) { $ok = $false; break }
      }
      if ($ok) { $startIdx = $i; break }
    }
    if ($startIdx -lt 0) {
      Write-WarnLine "pnpm 补丁：$f 中未找到匹配的原版函数（pnpm 版本可能已变），跳过。"
      continue
    }
    $out = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $startIdx; $k++) { $out.Add($lines[$k]) }
    foreach ($ln in $script:PnpmFixedBlock) { $out.Add($ln) }
    for ($k = $startIdx + $script:PnpmPristineBlock.Count; $k -lt $lines.Length; $k++) { $out.Add($lines[$k]) }
    [System.IO.File]::WriteAllText($f, ($out -join $eol) + $eol)
    Write-WarnLine "pnpm 补丁已重应用：$f"
  }
}

# generate-windows-app-icon.mjs 本地补丁：保留仓库里自带的 build/app-icon.ico。
# 上游打包前会用 tray-icon.svg 重新生成并覆盖该文件，本地定制图标会被冲掉；
# 打了补丁后只要目标 ICO 已存在且 DSH_KEEP_APP_ICON=1 就直接返回。
$script:AppIconAnchor = 'export async function generateWindowsAppIcon(source = sourcePath, output = outputPath) {'
$script:AppIconKeepBlock = @(
  '  if (process.env.DSH_KEEP_APP_ICON === ''1'') {'
  '    const { access } = await import(''node:fs/promises'')'
  '    const present = await access(output).then(() => true).catch(() => false)'
  '    if (present) {'
  '      console.log(`[overlay] 保留已有应用图标: ${output}`)'
  '      return'
  '    }'
  '  }'
)

function Set-WindowsAppIconKeepPatch {
  $f = Get-ChannelWsPath 'scripts\generate-windows-app-icon.mjs'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $env:DSH_KEEP_APP_ICON = '1'
  $raw = [System.IO.File]::ReadAllText($f)
  if ($raw.Contains('DSH_KEEP_APP_ICON')) {
    Write-Info "app-icon 保留补丁已生效：$f"
    return
  }
  $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = $raw -split "`r?`n"
  $idx = -1
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i].Trim() -eq $script:AppIconAnchor) { $idx = $i; break }
  }
  if ($idx -lt 0) {
    Write-WarnLine "app-icon 补丁：$f 中未找到 generateWindowsAppIcon 定义，跳过。"
    return
  }
  $out = New-Object System.Collections.Generic.List[string]
  for ($k = 0; $k -le $idx; $k++) { $out.Add($lines[$k]) }
  foreach ($ln in $script:AppIconKeepBlock) { $out.Add($ln) }
  for ($k = $idx + 1; $k -lt $lines.Length; $k++) { $out.Add($lines[$k]) }
  [System.IO.File]::WriteAllText($f, ($out -join $eol))
  Write-WarnLine "app-icon 保留补丁已应用：$f"
}

function Test-InstalledElectron {
  # 返回当前通道 node_modules 里已安装的 electron 版本（不存在返回 $null）
  $pkg = Get-ChannelWsPath 'node_modules\electron\package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return $null }
  return (Get-JsonObject $pkg).version
}

function Apply-SrcOverlay {
  # pull 后恢复 src 覆盖层：
  #   1) overlay\src\<basename> → 复制回仓库（新建文件）
  #   2) overlay\patches\<basename>.patch → git apply（已跟踪文件的修改）
  # 补丁应用失败（上游改动了同一区域）时抛错中止，避免“构建成功但没带上自定义”。
  if (-not $script:SrcOverlayDir -or -not (Test-Path -LiteralPath $script:SrcOverlayDir)) { return }
  $srcDir = Join-Path $script:SrcOverlayDir 'src'
  $patchDir = Join-Path $script:SrcOverlayDir 'patches'
  foreach ($rel in $script:SrcOverlayFiles) {
    $bak = Join-Path $srcDir ([IO.Path]::GetFileName($rel))
    $repoPath = Join-Path $script:Src $rel
    if (-not (Test-Path -LiteralPath $bak)) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoPath) | Out-Null
    Copy-Item -LiteralPath $bak -Destination $repoPath -Force
    Write-WarnLine "覆盖层：已恢复 $rel（新建文件）"
  }
  if (Test-Path -LiteralPath $patchDir) {
    Push-Location $script:Src
    try {
      foreach ($rel in $script:SrcPatchFiles) {
        $patch = Join-Path $patchDir "$([IO.Path]::GetFileName($rel)).patch"
        if (-not (Test-Path -LiteralPath $patch)) { continue }
        # 脚本顶部 $PSNativeCommandUseErrorActionPreference=$true：git apply 非零会
        # 直接抛原生异常，先临时关闭，才能给出友好的冲突提示。
        $prevNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $checkCode = -1
        $applyCode = -1
        try {
          & git apply --check $patch
          $checkCode = $LASTEXITCODE
          if ($checkCode -eq 0) {
            & git apply $patch
            $applyCode = $LASTEXITCODE
          }
        } finally {
          $PSNativeCommandUseErrorActionPreference = $prevNative
        }
        if ($checkCode -ne 0) {
          throw "覆盖层补丁无法应用：$patch（上游可能已改动 $rel 的同一区域）。" +
                '请手动合并后重新导出，或删除该补丁文件以放弃这处定制。'
        }
        if ($applyCode -ne 0) { throw "git apply 失败: $patch (exit $applyCode)" }
        Write-WarnLine "覆盖层：已应用补丁 $patch"
      }
    } finally {
      Pop-Location
    }
  }
}

function Invoke-ChannelOverlayPreInstall {
  # 用户定制覆盖层（安装前，仅 -Overlay）：electron 版本 / .yarnrc.yml 门禁 / 图标
  # / src 覆盖层（新建文件 + 修改补丁）
  # （npmRebuild=false 与 afterAllArtifactBuild 移除属本机必需修复，另行无条件应用）
  Reset-OverlayTrackedFiles  # 确保工作树覆盖层文件与上游一致后再改（幂等）
  $null = Set-ElectronOverride
  Set-AgeGateConfig
  Copy-TrayIconAssets
  Apply-SrcOverlay
  Write-Ok "本地覆盖层已应用（通道 $script:Channel → $script:ChannelWsName）"
}

function Invoke-ChannelOverlayPostInstall {
  # 覆盖层（安装后）：pnpm.mjs 补丁（install 会还原为原版）
  Set-PnpmDistPatch
}

function Invoke-SubmoduleUpdate {
  # dsh-desktop 是本仓库的 git 子模块：构建前用 `git submodule update` 对齐到
  # 父仓库记录的 pinned commit（gitlink）。--force 会丢弃上次构建注入的覆盖层
  # 改动，确保每次从干净快照开始、构建产物可复现。--init --recursive 同时处理
  # 嵌套子模块 deepseek-harness。
  $prevEap = $ErrorActionPreference
  $prevNative = $PSNativeCommandUseErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $output = @(& git -C $script:Root submodule update --init --recursive --force 2>&1)
    $code = $LASTEXITCODE

    foreach ($line in $output) {
      $text = if ($null -eq $line) { '' } else { [string]$line }
      Write-Host $text
      Write-Log $text
    }

    if ($code -eq 0) {
      Write-Ok '子模块已对齐到 pinned commit。'
      return
    }
    Write-WarnLine '子模块拉取 / 对齐失败。请检查网络 / 代理（-NoProxy 可禁用代理）与 Git 凭据。'
    throw "git submodule update --init --recursive --force 失败 (exit $code)。"
  } finally {
    $ErrorActionPreference = $prevEap
    $PSNativeCommandUseErrorActionPreference = $prevNative
  }
}

function Ensure-Source {
  $gitDir = Join-Path $script:Src '.git'
  if (Test-Path -LiteralPath $gitDir) {
    if ($SkipPull) {
      Write-WarnLine '已跳过子模块对齐（-SkipPull），使用现有代码。'
    } else {
      Write-Info "dsh-desktop 是本仓库子模块，正在对齐到 pinned commit ..."
      Invoke-SubmoduleUpdate
    }
  } elseif (Test-Path -LiteralPath $script:Src) {
    throw "目录 $($script:Src) 已存在但不是 Git 仓库（缺少 .git）。请手动处理该目录后再运行本脚本。"
  } elseif ($script:SrcRegisteredAsSubmodule) {
    Write-Info "未找到 $($script:Src)，正在初始化子模块（git submodule update --init --recursive）..."
    Invoke-SubmoduleUpdate
  } else {
    throw "未找到 $($script:Src)，且本仓库未注册 dsh-desktop 子模块。" +
          '请先执行 git submodule update --init --recursive，或手动放置源码到该目录。'
  }
  Write-Ok "代码已就绪: $script:Src"
}

function Install-Workspace {
  Push-Location $script:Src
  try {
    $yarnVersion = (& $script:YarnCmd.FileName @($script:YarnCmd.Prefix + @('--version')) | Select-Object -Last 1).ToString().Trim()
    Write-Info "使用 Corepack Yarn $yarnVersion（无需 corepack enable）"
    if ($yarnVersion -ne '4.18.0') {
      throw "期望 Yarn 4.18.0，实际为 $yarnVersion。请在 dsh-desktop 目录通过 corepack yarn 运行。"
    }
    # 覆盖层会改动 package.json（electron 44.3.0），锁文件需随之刷新，故用可变 install
    Invoke-Yarn @('install')
  } finally {
    Pop-Location
  }
}

function Invoke-YarnScript {
  # 执行根脚本（如 package:dir / dist:win）
  param([Parameter(Mandatory)][string]$ScriptName)
  Push-Location $script:Src
  try {
    Invoke-Yarn @($ScriptName)
  } finally {
    Pop-Location
  }
}

function Invoke-ChannelWorkspaceScript {
  # 直接对 dsh-plugin-desktop workspace 执行脚本：yarn workspace <ws> <script>
  param([Parameter(Mandatory)][string]$ScriptName)
  Push-Location $script:Src
  try {
    Invoke-Yarn @('workspace', $script:ChannelWsName, $ScriptName)
  } finally {
    Pop-Location
  }
}

function Invoke-MarketBuild {
  Push-Location $script:Src
  try {
    Invoke-Yarn @('workspace', 'dsh-community-market', 'build')
  } finally {
    Pop-Location
  }
}

function Invoke-UpstreamBuild {
  $harness = Join-Path $script:Src 'deepseek-harness'
  if (-not (Test-Path -LiteralPath (Join-Path $harness 'package.json'))) {
    throw '无法构建上游：deepseek-harness 尚未初始化。'
  }
  Write-WarnLine '产品编译默认使用已发布的 DSH npm 包，不会链接这份源码。'
  Push-Location $script:Src
  try {
    Invoke-Yarn @('upstream:install')
    Invoke-Yarn @('upstream:build')
  } finally {
    Pop-Location
  }
}

function Get-ArtifactHints {
  $desktopDist = Get-ChannelWsPath 'dist'
  $desktopLib = Get-ChannelWsPath 'lib'
  $marketLib = Join-Path $script:Src 'dsh-community-market\lib'
  $items = @()

  if (Test-Path -LiteralPath $desktopLib) {
    $items += "$script:Channel 编译产物  $desktopLib"
  }
  if (Test-Path -LiteralPath $marketLib) {
    $items += "市场编译产物  $marketLib"
  }
  if (Test-Path -LiteralPath $desktopDist) {
    Get-ChildItem -LiteralPath $desktopDist -File -ErrorAction SilentlyContinue |
      ForEach-Object { $items += "打包产物        $($_.FullName)" }
    $unpackedExe = Get-ChildItem (Join-Path $desktopDist 'win-unpacked\*.exe') -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($unpackedExe) {
      $items += "Windows 解包    $($unpackedExe.FullName)"
    }
  }
  return $items
}

function Show-Summary {
  $elapsed = (Get-Date) - $script:StartedAt
  Write-Host ''
  if ($script:Failed -gt 0) {
    Write-Banner "构建结束：有 $script:Failed 步失败  ($([int]$elapsed.TotalSeconds)s)" 'Yellow'
  } else {
    Write-Banner "构建成功  ($([int]$elapsed.TotalSeconds)s)" 'Green'
  }

  $artifacts = @(Get-ArtifactHints)
  if ($artifacts.Count -gt 0) {
    Write-Host '产物：' -ForegroundColor White
    foreach ($item in $artifacts) {
      Write-Host "  - $item"
    }
  } else {
    Write-Info '当前目标没有生成 dist 安装包。使用 -Target dist-win 可打 Windows 安装程序。'
  }

  Write-Info "日志已写入 $script:LogPath"
  Write-Host ''
  Write-Host '常用命令：' -ForegroundColor White
  Write-Host '  .\build.ps1                          # 默认：yarn build'
  Write-Host '  .\build.ps1 -Overlay ...             # 应用本地覆盖层'
  Write-Host '  .\build.ps1 -Target package-dir      # 解包目录（不打 ZIP）'
  Write-Host '  .\build.ps1 -Target dist-win-portable # Windows 便携 ZIP（推荐）'
  Write-Host '  .\build.ps1 -Target check            # 完整无界面门禁'
  Write-Host '  .\build.ps1 -Target dev              # 编译并启动图形界面'
  Write-Host '  .\build.ps1 -NoProxy                 # 禁用代理（默认 127.0.0.1:15715）'
}

# ---- 目标调度 ----
# 返回上游根脚本名（stable 线不带后缀）。
function Get-RootScriptName {
  param([Parameter(Mandatory)][string]$Target)
  switch ($Target) {
    'package-dir'       { return 'package:dir' }
    'dist-win'          { return 'dist:win' }
    'dist-win-portable' { return 'dist:win-portable' }
    'dist-mac'          { return 'dist:mac' }
    'dist-mac-smoke'    { return 'dist:mac-smoke' }
    'dev'               { return 'dev' }
    'start'             { return 'start' }
  }
  throw "目标 $Target 没有对应的根脚本。"
}

# build/typecheck/test/check/all 使用通道 workspace 级脚本（上游根脚本会同时构建两个通道）
function Invoke-ChannelBuild {
  Invoke-MarketBuild
  Invoke-ChannelWorkspaceScript 'build'
}
function Invoke-ChannelAll {
  Invoke-MarketBuild
  Invoke-ChannelWorkspaceScript 'build'
  Invoke-ChannelWorkspaceScript 'typecheck'
  Invoke-ChannelWorkspaceScript 'test'
}

function Update-PackagedTimestamps {
  # Electron 官方 zip 内条目时间是 1980-01-01（可复现构建），解包后 dist\win-unpacked
  # 里除主程序外都是 1980/1/1 8:00。这里把解包目录内的文件/目录时间统一改成当前时间。
  # 用 -KeepTimestamps 可跳过（保留上游原样时间）。
  $distDir = Get-ChannelWsPath 'dist'
  $unpacked = Join-Path $distDir 'win-unpacked'
  if (-not (Test-Path -LiteralPath $unpacked)) {
    Write-WarnLine "未找到 $unpacked，跳过产物时间戳规整。"
    return
  }
  $now = Get-Date
  $files = 0
  $dirs = 0
  $entries = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue)
  # 先改文件，再改目录，避免子项写入又把父目录时间顶掉
  foreach ($item in ($entries | Where-Object { -not $_.PSIsContainer })) {
    try {
      [System.IO.File]::SetCreationTime($item.FullName, $now)
      [System.IO.File]::SetLastWriteTime($item.FullName, $now)
      $files++
    } catch {
      Write-Log "时间戳规整失败（跳过）：$($item.FullName) -> $($_.Exception.Message)"
    }
  }
  foreach ($item in ($entries | Where-Object { $_.PSIsContainer })) {
    try {
      [System.IO.Directory]::SetCreationTime($item.FullName, $now)
      [System.IO.Directory]::SetLastWriteTime($item.FullName, $now)
      $dirs++
    } catch {
      Write-Log "时间戳规整失败（跳过）：$($item.FullName) -> $($_.Exception.Message)"
    }
  }
  foreach ($item in @(Get-ChildItem -LiteralPath $unpacked -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
    try { [System.IO.Directory]::SetLastWriteTime($item.FullName, $now) } catch {}
  }
  try {
    [System.IO.Directory]::SetCreationTime($unpacked, $now)
    [System.IO.Directory]::SetLastWriteTime($unpacked, $now)
  } catch {}
  Write-Ok "已将 $files 个文件、$dirs 个目录的时间戳规整为当前时间（$($now.ToString('yyyy-MM-dd HH:mm:ss'))）。"
}

try {
  # 配置代理环境变量
  if (-not $NoProxy -and $Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
    $env:ALL_PROXY = $Proxy
    Write-Info "已设置代理: $Proxy"
  }

  # Yarn 4.18 默认拒绝“发布不足 1 天”的版本（npmMinimalAgeGate），而 AA 准备阶段会在
  # 临时目录里跑独立 yarn install，那里没有 .yarnrc.yml，只有环境变量能覆盖到子进程。
  $env:YARN_NPM_MINIMAL_AGE_GATE = '0'

  # 不生成 ZIP / 安装包：打包目标改为解包目录（package-dir，输出到 dist\win-unpacked）
  if ($NoZip -and $Target -in @('dist-win', 'dist-win-portable', 'dist-mac', 'dist-mac-smoke')) {
    Write-WarnLine "-NoZip：目标 $Target 改为解包目录（dist\win-unpacked），不生成 ZIP / 安装包。"
    $Target = 'package-dir'
  }

  Initialize-Log
  Invoke-Step '获取 / 更新 dsh-desktop 源码' { Ensure-Source }
  Invoke-Step "固定运行时版本（deepseek-harness $($script:RuntimeVersion)）" { Set-RuntimeVersionPinned }
  $script:GithubVersion = Get-GithubVersion
  Invoke-VersionGuard
  Show-Environment
  Assert-Prerequisites
  if ($Overlay) {
    Invoke-Step '应用本地覆盖层（electron/门禁/图标等）' { Invoke-ChannelOverlayPreInstall }
  } else {
    Write-WarnLine '未应用本地覆盖层（未指定 -Overlay）：构建上游原样代码。'
  }
  Invoke-Step '应用 Windows 打包必需修复（npmRebuild=false / 移除 #829 钩子）' { Invoke-RequiredWinFixes }

  if ($SkipSubmodule) {
    Write-WarnLine '已跳过子模块初始化。'
    $harnessPkg = Join-Path $script:Src 'deepseek-harness\package.json'
    if (-not (Test-Path -LiteralPath $harnessPkg)) {
      throw 'deepseek-harness 为空。不要使用 -SkipSubmodule，或先执行 git submodule update --init --recursive。'
    }
  } else {
    Invoke-Step '初始化 pinned 上游子模块' { Initialize-Submodule }
  }

  if ($SkipInstall) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:Src 'node_modules'))) {
      throw 'dsh-desktop\node_modules 不存在。不要使用 -SkipInstall。'
    }
    # 跳过安装前检查依赖是否真的与上次一致：已装 electron 版本、以及 yarn.lock 指纹
    # （上游更新过依赖 / 覆盖层改过 electron 都会改变锁文件 → 必须补装，否则打包崩溃）。
    $needInstall = @()
    $installedElectron = Test-InstalledElectron
    if ($Overlay -and $installedElectron -and $installedElectron -ne $script:ElectronOverride) {
      $needInstall += "electron 已装 $installedElectron ≠ 覆盖层目标 $($script:ElectronOverride)"
    }
    $state = Read-BuildState
    $lastLockHash = $null
    if ($state -and $state.PSObject.Properties.Name -contains 'lastLockHash') { $lastLockHash = $state.lastLockHash }
    $curLockHash = (Get-FileHash (Join-Path $script:Src 'yarn.lock') -Algorithm SHA256).Hash
    if ($lastLockHash -and $lastLockHash -ne $curLockHash) {
      $needInstall += 'yarn.lock 已变化（上游或覆盖层更新了依赖）'
    }
    if ($needInstall.Count -gt 0) {
      Write-WarnLine "已跳过 yarn install，但检测到依赖变化：$($needInstall -join '；')"
      Write-WarnLine '正在执行 yarn install 补装依赖 ...'
      Invoke-Step '安装 Yarn 工作区依赖（依赖已变化）' { Install-Workspace }
    } else {
      Write-WarnLine '已跳过 yarn install（依赖与上次一致）。'
    }
  } else {
    Invoke-Step '安装 Yarn 工作区依赖' { Install-Workspace }
  }

  if ($Overlay) {
    Invoke-Step '重应用 pnpm 补丁（install 后）' { Invoke-ChannelOverlayPostInstall }
  }

  if ($Upstream) {
    Invoke-Step '构建上游 deepseek-harness（可选）' { Invoke-UpstreamBuild }
  }

  if (-not $env:ELECTRON_MIRROR) {
    $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
  }

  # AA 源固定（见 $script:AaSourceRef 注释）：阻止 prepare 脚本跟踪已损坏的 AA main。
  if (-not $env:DSH_AA_SOURCE_REF) {
    $env:DSH_AA_SOURCE_REF = $script:AaSourceRef
    Write-Info "AA 源固定为 $($script:AaSourceRef.Substring(0,12))（复用已验证产物；设 DSH_AA_SOURCE_REF 可覆盖）"
  }

  switch ($Target) {
    'build' {
      Clear-ReadOnlyAssets
      Invoke-Step "编译 ($script:Channel / yarn build)" { Invoke-ChannelBuild }
    }
    'check' {
      Clear-ReadOnlyAssets
      Invoke-Step "门禁检查 ($script:Channel / yarn check)" { Invoke-ChannelWorkspaceScript 'check' }
    }
    'typecheck' {
      Invoke-Step "类型检查 ($script:Channel)" { Invoke-ChannelWorkspaceScript 'typecheck' }
    }
    'test' {
      Invoke-Step "单元测试 ($script:Channel)" { Invoke-ChannelWorkspaceScript 'test' }
    }
    'all' {
      Clear-ReadOnlyAssets
      Invoke-Step '编译 (yarn build)' { Invoke-ChannelAll }
    }
    default {
      $yarnScript = Get-RootScriptName $Target
      $graphical = $Target -in @('dev', 'start')
      if ($graphical) {
        Write-WarnLine '该目标会启动图形界面。'
      }
      if ($Target -in @('package-dir', 'dist-win', 'dist-win-portable', 'dist-mac', 'dist-mac-smoke')) {
        Prepare-PackagingEnvironment
      }
      Clear-ReadOnlyAssets
      Invoke-Step "执行 yarn $yarnScript" { Invoke-YarnScript $yarnScript }
    }
  }

  if (-not $KeepTimestamps -and $script:Failed -eq 0 -and
      $Target -in @('package-dir', 'dist-win', 'dist-win-portable', 'dist-mac', 'dist-mac-smoke')) {
    Invoke-Step '规整产物时间戳为当前时间' { Update-PackagedTimestamps }
  }

  if ($script:Failed -eq 0) {
    Save-BuildState
  }

  Show-Summary
  if ($script:Failed -gt 0) { exit 1 }
  exit 0
} catch {
  Write-ErrLine $_.Exception.Message
  if ($_.ScriptStackTrace) {
    Write-Log $_.ScriptStackTrace
  }
  Write-Host ''
  Write-Host '排查建议：' -ForegroundColor Yellow
  Write-Host '  1. 确认 Node.js 为 22.19+ 或 24.x，并可用 corepack。'
  Write-Host '  2. 空的 deepseek-harness 不会在打包时自动下载，必须先初始化子模块。'
  Write-Host '  3. 不要手改 deepseek-harness/；产品构建解析的是已发布 npm 包。'
  Write-Host "  4. 查看日志: $script:LogPath"
  exit 1
}
