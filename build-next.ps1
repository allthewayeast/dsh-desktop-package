<#
.SYNOPSIS
  编译打包 dsh-desktop-next（实验性 DSH NEXT 桌面），产物为 dist\win-unpacked。

.DESCRIPTION
  为什么单独一个脚本，而不是复用 build.ps1：
  build.ps1 深度绑定 stable 通道（dsh-plugin-desktop）：通道工作区名、插件清单、
  overlay 补丁路径、AA/dshmarket 校验的工作区列表、产物核对项都写死为 stable。
  next 的源码结构、构建入口（tsdown + vite + scripts/package.ts）、运行形态
  （私有 loopback webserver + shim）都与 stable 不同，硬塞进 build.ps1 会牵动
  stable 的既有行为。因此这里独立成脚本，共享的只是"拉源码 / 固定运行时版本 /
  yarn install / 覆盖层"这些通用步骤。

  与 stable 的主要差异：
    1. overlay 目录独立为 overlay-next\，避免与 stable 的 overlay\ 互相污染；
    2. 需要把 dsh-desktop-next 加回根 workspaces（build.ps1 的 DisableNext 会移除它）；
    3. dshmarket / AA 校验的工作区列表必须同时包含 next；
    4. 产物核对项按 next 的实际布局（lib/main.js、host.cordis.patch.yml 等）。
    5. 不做图标处理（按需求）。
    6. 运行时跟随上游（不再钉 0.1.7-rc.2），deepseek-harness 子模块对齐上游 HEAD 的 gitlink。

  overlay-next 现在只承担一件事：把 exe 同级的 startup.json 接进启动流程。
    overlay-next\src\startup-config.ts        新文件：启动配置解析（网络/环境变量开关）
    overlay-next\src\startup-config.spec.ts   新文件：配套单测
    overlay-next\patches\main.ts.patch        接入 applyDesktopStartupConfig + 让 DSH_HOME 生效
    overlay-next\startup.json                 运行时数据，构建后拷到 exe 同级
  "让 DSH_HOME 生效"不是附加功能：startup.json 里配置的就是 DSH_HOME，而 next 原本只认
  DSH_DESKTOP_NEXT_HOME，不补这段启动配置就落不到 home 上。

  2026-10-14 起 ASAR 相关的策展全部撤掉，因为上游自己接过去了，且我们的旧做法会与新门禁冲突：
    - 上游 dsh-desktop-next\package.json 现在自带 "asar": true + build.asarUnpack（含
      bundled-connector / pnpm / node-bin / assets 的完整清单）→ 已无需我们重新启用 ASAR；
    - 上游 scripts\verify-packaged.ts 现在**要求** app.asar 存在、且禁止并列的 resources\app
      目录（afterPack 里 archivedPayload/auditNextPayload/sealNextPayload）→ 我们旧补丁
      "兼容两种布局"的写法反而与该门禁矛盾；
    - 上游 scripts\verify-fuses.ts 明确按"两个 archive fuse 全关"校验（注释：archive 由代码
      签名封存），传 requiresAsar=false，与上游 fuses 配置一致 → 旧补丁把 fuses 打开会让这条
      校验直接失败；
    - LibreOffice 其他平台包、source map、.d.ts 等由上游 scripts\runtime-file-policy.ts +
      auditNextPayload 负责剔除（含 "must not be packaged" 断言）→ 旧的 win.files 排除项
      已多余，而且它有害：见下。
  保留 afterAllArtifactBuild（上游 verify-fuses.ts）：它会用打包后的 exe 以 Node 模式真启动
  一次 Host 做冒烟，是本仓库最强的产物验收，不要像以前那样删掉它。

.PARAMETER Target
  构建目标。默认 package-dir（编译 + 解包目录，不打安装包）。

.PARAMETER SkipPull
  跳过源码拉取，使用当前工作区代码（调试脚本本身时有用）。

.PARAMETER SkipSubmodule
  跳过 deepseek-harness 子模块对齐（与 quick-build-overlay.bat 同名参数语义一致）。

.PARAMETER ElectronVersion
  Electron 目标版本。默认沿用上游声明，不覆盖。

.PARAMETER KeepGoing
  出错继续，最后汇总。

.EXAMPLE
  pwsh -File .\build-next.ps1
  pwsh -File .\build-next.ps1 -Target package-dir -SkipSubmodule -ElectronVersion 44.4.5
#>
[CmdletBinding()]
param(
  [ValidateSet('build', 'package-dir', 'check', 'typecheck', 'test')]
  [string]$Target = 'package-dir',

  [switch]$SkipPull,
  [switch]$SkipSubmodule,
  [switch]$SkipInstall,
  [switch]$KeepGoing,
  [switch]$NoProxy,
  [string]$Proxy = 'http://127.0.0.1:15715',
  [string]$ElectronVersion
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# ---------------- 常量 ----------------

$script:Root = $PSScriptRoot
$script:Src = Join-Path $script:Root 'dsh-desktop'
$script:SrcRepository = 'https://github.com/anywhere-labs/dsh-desktop'
$script:SrcBranch = 'master'

# 通道工作区（next 自己的目录名）
$script:WsName = 'dsh-desktop-next'
$script:WsDir = Join-Path $script:Src $script:WsName

# 运行时：跟随上游（不再硬钉 0.1.7-rc.2）
# next 的 dsh 运行时由上游决定，三处必须一致：next 工作区声明的 @deepseek-ai/dsh 版本、
# 根 package.json 的 resolutions 里该版本 → file:vendor/dsh-runtime/<ver>/... 的映射、
# vendor\dsh-runtime\<ver> 目录本身。本脚本只校验并报告，不改写依赖串。
# 2026-09-29：上游把 next/beta 一律升到 0.2.0-rc.1，而旧代码仍把 next 的依赖串改写成
# 0.1.7-rc.2；resolutions 的键是带版本的（@deepseek-ai/dsh@npm:0.2.0-rc.1），降版本后
# 不再匹配 → install 会绕过 vendored 产物退到 npm 解析，且与按 0.2.0-rc.1 peer 构建的
# AA 产物（vendor\agents-anywhere）不一致。stable 通道仍由 build.ps1 钉 0.1.7-rc.2。

# 本脚本不构建的工作区（只让它们不参与编译/打包），但其中有些仍需安装依赖：
#   - dsh-plugin-desktop（stable）：next 完全不引用，排除即可。
#   - dsh-plugin-desktop-beta：**必须保留依赖**。next 的 vite.client.config.ts
#     直接 re-export beta 的配置（"Native onboarding and its assets use the same
#     renderer build as Beta"），native-ui 配置也注明 "Shared components live in
#     another workspace"，且 next 有 10 处 import 来自 beta/src。beta 的 vite
#     配置把 lucide-react 等当作外部包解析，因此 beta 的 node_modules 必须存在，
#     否则构建报 "Rolldown failed to resolve import lucide-react from
#     dsh-plugin-desktop-beta/src/client/DesktopNativeActions.tsx"。
$script:ExcludedWorkspaces = @('dsh-plugin-desktop')

# overlay-next：next 专属覆盖层（与 stable 的 overlay\ 隔离）
$script:OverlayDir = Join-Path $script:Root 'overlay-next'
# 新建文件（上游无此文件）：overlay-next\src\<basename> -> <工作区相对路径>
$script:OverlayFiles = @{
  'dsh-desktop-next/src/startup-config.ts'      = 'startup-config.ts'
  'dsh-desktop-next/tests/startup-config.spec.ts' = 'startup-config.spec.ts'
}
# 已跟踪文件的修改：overlay-next\patches\<basename>.patch
$script:OverlayPatches = @(
  'dsh-desktop-next/src/main.ts'
)

# 注意：dsh-desktop-next\package.json **不再**需要覆盖层补丁（见文件头 2026-10-14 说明：
# 上游已自带 asar + asarUnpack + 平台剔除策略）。同时它也是唯一会被构建期注入的文件
# （本脚本的 -ElectronVersion、stable 侧 Set-AAVendorDependency 都会改写它），本来就不该
# 自动导出。既然不再需要补丁，这里直接把该文件从 OverlayPatches 移除，避免"注入被当成
# 策展内容导出"的老坑再次出现。

# 产物核对：应用负载（app.asar 或 resources\app）内必须具备的条目。
# 与上游 scripts\verify-packaged.ts → verifyNextPayload() 的必查清单保持一致，外加
# 官方 Web 前端入口（上游靠依赖闭包查它）。保持一致的好处：上游 afterPack 报错前，
# 这里就能先给出更短的清单式诊断。
$script:RequiredPayloadEntries = @(
  'lib/main.js'
  'lib/host.js'
  'lib/client.js'
  'lib/preload-app.cjs'
  'lib/preload-shell.cjs'
  'lib/native-ui/index.html'
  'cordis.patch.yml'
  'host.cordis.patch.yml'
  'scripts/node-bin/node'
  'scripts/node-bin/node.cmd'
  'assets/tray-iconTemplate.png'
  'assets/tray-icon-blue.png'
  'node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html'
)
# 覆盖层专属断言：只有我们的补丁会引入这些字符串。
#   lib/main.js 必须含 startup-config 的集成点（否则 exe 同级的 startup.json 不会被读）
$script:RequiredMarkers = @{
  'lib/main.js' = 'applyDesktopStartupConfig'
}

# ---------------- 日志 ----------------

$script:LogDir = Join-Path $script:Root 'logs'
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
$script:LogPath = Join-Path $script:LogDir ("build-next-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:StepIndex = 0
$script:Failed = 0

function Write-Log {
  param([string]$Text)
  Add-Content -LiteralPath $script:LogPath -Value $Text -Encoding utf8
}
function Write-Info { param([string]$Message) Write-Host "[INFO ] $Message" -ForegroundColor Gray; Write-Log "[INFO ] $Message" }
function Write-Ok { param([string]$Message) Write-Host "[ OK  ] $Message" -ForegroundColor Green; Write-Log "[ OK  ] $Message" }
function Write-WarnLine { param([string]$Message) Write-Host "[WARN ] $Message" -ForegroundColor Yellow; Write-Log "[WARN ] $Message" }
function Write-ErrLine { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; Write-Log "[ERROR] $Message" }

function Invoke-Step {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Action
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
    if ($KeepGoing) { Write-WarnLine '已按 -KeepGoing 继续。'; return }
    throw
  }
}

function Get-JsonObject {
  param([Parameter(Mandatory)][string]$Path)
  return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
}

# ---------------- Git / 源码 ----------------

function Update-SourceRepository {
  Push-Location $script:Src
  try {
    Write-Info "拉取 $script:SrcBranch 并重置本地分支 ..."
    & git fetch origin 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "git fetch 失败 (exit $LASTEXITCODE)" }
    # --force 丢弃上次构建注入的覆盖层改动，保证每次都从干净快照开始
    & git checkout --force -B $script:SrcBranch "origin/$script:SrcBranch" 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "git checkout 失败 (exit $LASTEXITCODE)" }
    $head = (& git rev-parse --short=10 HEAD).Trim()
    Write-Ok "源码已更新（HEAD=$head）"
  } finally {
    Pop-Location
  }
}

function Ensure-Submodule {
  if ($SkipSubmodule) { Write-WarnLine '已跳过子模块初始化（-SkipSubmodule）。'; return }
  $sub = Join-Path $script:Src 'deepseek-harness'

  # 跟随上游：上游 HEAD 记录的 gitlink 就是本通道应有的 harness commit。
  # （stable 由 build.ps1 钉 477b4f42 = 0.1.7-rc.2；next 跟随上游，随 beta 通道为
  #  0.2.0-rc.1 对应 commit，硬编码会在上游升级时把子模块降级。）
  $expected = $null
  $prevNative = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $link = @(& git -C $script:Src ls-tree HEAD deepseek-harness) -join ' '
    $gl = [regex]::Match($link, 'commit\s+([0-9a-f]{40})')
    if ($gl.Success) { $expected = $gl.Groups[1].Value }
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prevNative
  }

  if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) {
    Write-Info '初始化 deepseek-harness 子模块 ...'
    & git -C $script:Src submodule update --init --recursive deepseek-harness 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "submodule update 失败 (exit $LASTEXITCODE)" }
  }
  if (-not $expected) {
    Write-WarnLine '未读到上游记录的 deepseek-harness gitlink（上游结构变化？），跳过子模块核对。'
    return
  }
  $actual = (& git -C $sub rev-parse HEAD).Trim()
  if ($actual -ne $expected) {
    Write-Info "对齐 deepseek-harness 到上游记录 $($expected.Substring(0,10)) ..."
    & git -C $sub checkout --force $expected 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "子模块 checkout 失败 (exit $LASTEXITCODE)" }
  }
  Write-Ok "deepseek-harness = $($expected.Substring(0,10))（跟随上游 gitlink）"
}

# ---------------- 覆盖层 ----------------

function Export-Overlay {
  # 把工作区里这些文件的本地改动导出成 overlay-next\patches，然后再 pull。
  # 这样"改了源码 → 跑本脚本"就能固化改动，且 pull 不会丢。
  # 现在列表里只有 main.ts：它是纯策展文件（工作区改动 = 我们的接线），可以安全导出。
  # package.json 已不在列表里 —— 它的改动只会是构建期注入，导出会覆盖策展内容。
  if ($SkipPull) { return }
  Push-Location $script:Src
  try {
    $patchDir = Join-Path $script:OverlayDir 'patches'
    New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
    foreach ($rel in $script:OverlayPatches) {
      $prevNative = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
      try {
        $diff = @(& git diff -- $rel)
        $diffCode = $LASTEXITCODE
      } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
      }
      if ($diffCode -ne 0) { continue }
      if ($diff.Count -eq 0) { continue }
      $out = Join-Path $patchDir ("$([IO.Path]::GetFileName($rel)).patch")
      [System.IO.File]::WriteAllText($out, ([string]::Join("`n", $diff) + "`n"))
      Write-WarnLine "覆盖层：已导出 $rel 的本地改动 → $(Split-Path -Leaf $out)"
    }
  } finally {
    Pop-Location
  }
}

function Apply-Overlay {
  Push-Location $script:Src
  try {
    # 1) 新建文件：从 overlay-next\src 复制进工作区
    foreach ($rel in $script:OverlayFiles.Keys) {
      $src = Join-Path (Join-Path $script:OverlayDir 'src') $script:OverlayFiles[$rel]
      $dst = Join-Path $script:Src ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $src)) {
        throw "覆盖层缺少源文件：$src"
      }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      Copy-Item -LiteralPath $src -Destination $dst -Force
      Write-WarnLine "覆盖层：已放置新文件 $rel"
    }

    # 2) 已跟踪文件的修改：git apply
    foreach ($rel in $script:OverlayPatches) {
      $patch = Join-Path (Join-Path $script:OverlayDir 'patches') ("$([IO.Path]::GetFileName($rel)).patch")
      if (-not (Test-Path -LiteralPath $patch)) {
        Write-WarnLine "覆盖层：无补丁文件 $(Split-Path -Leaf $patch)，跳过 $rel"
        continue
      }
      # 行尾规范化（CRLF 会让 git apply 把 \r 当成正文）
      $text = [System.IO.File]::ReadAllText($patch)
      $lf = $text -replace "`r`n", "`n"
      if ($lf -cne $text) { [System.IO.File]::WriteAllText($patch, $lf) }

      # 幂等：若补丁已经打上（例如上一轮构建留下的工作区，配合 -SkipPull 重跑），
      # 正向 --check 会失败、反向 --check 会成功，这时跳过即可，不要当成失配报错。
      $prevNative = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
      try {
        & git apply --check $patch 2>$null
        $canApply = ($LASTEXITCODE -eq 0)
        if (-not $canApply) {
          & git apply --reverse --check $patch 2>$null
          $alreadyApplied = ($LASTEXITCODE -eq 0)
        } else { $alreadyApplied = $false }
      } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
      }
      if ($alreadyApplied) {
        Write-Info "覆盖层：$(Split-Path -Leaf $patch) 已处于已应用状态，跳过"
        continue
      }
      if (-not $canApply) {
        throw "覆盖层补丁无法应用：$(Split-Path -Leaf $patch)（上游可能已改动同一区域，需按新代码更新补丁）"
      }
      & git apply $patch
      if ($LASTEXITCODE -ne 0) { throw "git apply 失败：$(Split-Path -Leaf $patch) (exit $LASTEXITCODE)" }
      Write-WarnLine "覆盖层：已应用补丁 $(Split-Path -Leaf $patch)"
    }
    Write-Ok '覆盖层已应用（next 通道）'
  } finally {
    Pop-Location
  }
}

# ---------------- 工作区 / 版本固定 ----------------

function Set-WorkspaceSelection {
  # next 必须出现在根 workspaces 里，否则 yarn install 不装它的依赖。
  # 同时把本脚本不构建的 stable/beta 移出，避免连带安装与编译。
  $rootPkgPath = Join-Path $script:Src 'package.json'
  $text = [System.IO.File]::ReadAllText($rootPkgPath)
  $m = [regex]::Match($text, '(?s)("workspaces"\s*:\s*\[)(.*?)(\])')
  if (-not $m.Success) { throw '根 package.json 未找到 workspaces 数组（上游格式变化？）' }
  $items = @([regex]::Matches($m.Groups[2].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
  if ($items.Count -eq 0) { throw '根 workspaces 为空（上游格式变化？）' }
  $keep = @($items | Where-Object { $script:ExcludedWorkspaces -notcontains $_ })
  if ($keep -notcontains $script:WsName) { $keep += $script:WsName }
  $rendered = ($keep | Sort-Object -Unique | ForEach-Object { "    `"$_`"" }) -join ",`n"
  $text = $text.Remove($m.Groups[2].Index, $m.Groups[2].Length).Insert($m.Groups[2].Index, "`n$rendered`n  ")
  [System.IO.File]::WriteAllText($rootPkgPath, $text)
  Write-WarnLine "工作区：保留 $((($keep | Sort-Object -Unique)) -join '、')（排除 $($script:ExcludedWorkspaces -join '、')）"
}

function Get-NextDeclaredRuntime {
  # next 工作区自己声明的 dsh 运行时版本（上游的权威来源）。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) { return $null }
  $text = Get-Content -LiteralPath $pkgPath -Raw -Encoding utf8
  $m = [regex]::Match($text, '"@deepseek-ai/dsh"\s*:\s*"([^"]+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Test-NextRuntimeVersion {
  # 只校验、不改写：next 的运行时跟随上游（2026-09-29 起上游为 0.2.0-rc.1）。
  # 旧实现把 next 的 @deepseek-ai/dsh* 依赖串改写成硬钉的 0.1.7-rc.2，与上游根
  # resolutions 的带版本键（@deepseek-ai/dsh@npm:0.2.0-rc.1 → file:vendor/...）不再
  # 匹配，install 会绕过 vendored 产物退到 npm 解析，也与按 0.2.0-rc.1 peer 构建的
  # AA 产物不一致。这里改成三处一致性校验，缺一处只告警（上游可能重构）。
  $declared = Get-NextDeclaredRuntime
  if (-not $declared) {
    Write-WarnLine '未读到 next 工作区的 @deepseek-ai/dsh 声明（上游格式变化？），跳过运行时校验。'
    return
  }

  # ① vendored 运行时目录
  $manifest = Join-Path $script:Src "vendor\dsh-runtime\$declared\manifest.json"
  if (Test-Path -LiteralPath $manifest) {
    Write-Info "运行时：next 声明 $declared，vendor\dsh-runtime\$declared 已就位"
  } else {
    Write-WarnLine "运行时：vendor\dsh-runtime\$declared\manifest.json 缺失（install 会退到 npm 解析）"
  }

  # ② 根 resolutions 是否把该版本映射到 vendored 产物
  $rootPkgPath = Join-Path $script:Src 'package.json'
  if (Test-Path -LiteralPath $rootPkgPath) {
    $rootText = Get-Content -LiteralPath $rootPkgPath -Raw -Encoding utf8
    $key = '"@deepseek-ai/dsh@npm:' + $declared + '"'
    if ($rootText.Contains($key)) {
      Write-Info "运行时：根 resolutions 已把 @deepseek-ai/dsh@npm:$declared 指向 vendored 产物"
    } else {
      Write-WarnLine "运行时：根 resolutions 没有 @deepseek-ai/dsh@npm:$declared 的映射（install 可能走 npm）"
    }
  }

  # ③ 与 upstream.json 的通道声明对照（只为发现上游自身不一致）
  $upPath = Join-Path $script:Src 'upstream.json'
  if (Test-Path -LiteralPath $upPath) {
    $up = Get-JsonObject $upPath
    if ($up.channels.PSObject.Properties.Name -notcontains 'next') {
      Write-Info '运行时：upstream.json 无 next 通道条目（上游未把 next 纳入通道表），以工作区声明为准'
    }
    $betaVer = $null
    if ($up.channels.beta) { $betaVer = $up.channels.beta.sourceVersion }
    if ($betaVer -and $betaVer -ne $declared) {
      Write-WarnLine "运行时：next 声明 $declared，而 upstream.json 的 beta 通道是 $betaVer（上游 desktop 家族版本不一致，请确认是否预期）"
    }
  }

  Write-Ok "运行时已按上游确定：$declared（本脚本不改写依赖版本）"
}

function Set-ElectronOverride {
  if (-not $ElectronVersion) { Write-Info '未指定 -ElectronVersion，沿用上游声明。'; return }
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  if ($text -notmatch '("electron"\s*:\s*")([^"]+)(")') { Write-WarnLine '未找到 electron 依赖声明，跳过覆盖。'; return }
  $current = $Matches[2]
  if ($current -eq $ElectronVersion) { Write-Info "electron 已是 $ElectronVersion"; return }
  $fixed = [regex]::Replace($text, '("electron"\s*:\s*")[^"]+(")', "`${1}$ElectronVersion`${2}", 1)
  [System.IO.File]::WriteAllText($pkgPath, $fixed)
  Write-WarnLine "覆盖层：electron $current → $ElectronVersion"
}

function Test-PackagingPosture {
  # 只读检查：next 的打包姿态由上游决定，我们只依赖其中几项。旧版这里会**改文件**
  # （删掉 build.afterAllArtifactBuild 关掉上游的事后校验），见文件头说明：那会让上游
  # 最强的产物验收从来不跑，已撤销。现在只在姿态变化时提前告警，避免构建跑到一半才炸在
  # 难懂的地方。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $pkg = Get-JsonObject $pkgPath
  $build = $pkg.build

  # ① ASAR 必须开着：上游 afterPack（verify-packaged.ts）要求 app.asar 存在、且禁止并列的
  #    resources\app 目录；本脚本的产物核对也按归档读条目。
  if ($build.asar -eq $false) {
    Write-WarnLine '打包姿态：build.asar 被关掉 —— 上游 afterPack（要求 app.asar、禁止 resources\app）与本脚本的产物核对都会失败。'
  } else {
    Write-Info '打包姿态：asar 已启用（上游自带 asarUnpack 清单）'
  }

  # ② npmRebuild：本机没有完整原生编译环境，必须保持 false。
  if ($build.npmRebuild -ne $false) {
    Write-WarnLine "打包姿态：build.npmRebuild = $($build.npmRebuild)（期望 false）—— 缺少原生编译环境时打包会失败。"
  }

  # ③ ★ 平台段 files 一旦出现，就会顶掉整份 app 文件白名单。
  #    electron-builder 26 的 util\config\config.js normalizeFiles() 把顶层字符串数组折成
  #    [{filter:[...]}] 的单个 FileSet；于是 fileMatcher.js getFileMatchers() 里
  #    defaultMatcher 只剩平台段那些字符串，而 getMainFileMatchers() 只取 matchers[0]
  #    （=defaultMatcher）。平台段若全是排除项 → containsOnlyIgnore() 成立 → 遍历器被前置
  #    **/* → 白名单失效，包目录里没被默认规则排除的东西全都会进 app.asar。对 next 来说
  #    这直接撞上游 auditNextPayload 的 stray root 断言（src/、tests/、.desktop-build 等）。
  $platformFiles = @()
  foreach ($key in 'mac', 'win', 'linux') {
    if ($build.PSObject.Properties.Name -contains $key) {
      $section = $build.$key
      if ($section -and ($section.PSObject.Properties.Name -contains 'files')) { $platformFiles += $key }
    }
  }
  if ($platformFiles.Count -gt 0) {
    Write-WarnLine ("打包姿态：build." + ($platformFiles -join '/build.') + ' 声明了平台段 files —— 它会顶掉顶层白名单（matchers[0] 只取平台段），产物可能多出 src/、tests/、.desktop-build 等游离条目，并在 afterPack 的 auditNextPayload 处失败。排除项请写在顶层 build.files 里。')
  }

  # ④ afterAllArtifactBuild：上游 verify-fuses.ts 会用打包后的 exe 以 Node 模式真启动一次
  #    Host（外加 fuse 与 runtime 校验），是本仓库最强的产物验收，不要删。
  if ($build.PSObject.Properties.Name -contains 'afterAllArtifactBuild') {
    Write-Info "打包姿态：afterAllArtifactBuild = $($build.afterAllArtifactBuild)（打包后会跑一次真实 Host 冒烟）"
  } else {
    Write-WarnLine '打包姿态：build 未声明 afterAllArtifactBuild —— 上游的 fuse / runtime / Host 冒烟验收不会执行。'
  }
}

function Set-PayloadExclusions {
  # 把上游 scripts\runtime-file-policy.ts（nextRuntimeFileExclusion）的"不得打包"策略落到
  # electron-builder 的文件集上。该策略由 afterPack 的 auditNextPayload 强制（命中即失败），
  # 所以文件集必须与它一致。本机构建遇到的两类：
  #   ① LibreOffice 只允许目标平台/架构的引擎包。本机是 win32-x64，但 .yarnrc.yml 的
  #      supportedArchitectures cpu 含 x64+arm64（为通用 macOS 准备），于是
  #      @deepseek-ai/libreoffice-kit-win32-arm64 也被装进来 → 1470 个文件触发
  #      "LibreOffice other platform must not be packaged"。
  #   ② @koromix/koffi-win32-x64\win32_x64\koffi.lib 是链接期导入库，运行期不需要
  #      → "Koffi import library must not be packaged"。
  # 位置必须是**顶层** build.files：electron-builder 26 把顶层字符串数组归一化成单个
  # {filter:[...]}（util\config\config.js normalizeFiles），而 app 遍历器只取 matchers[0]；
  # 写成平台段 build.win.files 反而会顶掉整份白名单（见 Test-PackagingPosture ③）。
  # 顶层排除项同时进入 node_modules 遍历器 —— 上游 beforePack 注入 node-pty 排除项用的正是同一位置。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  $m = [regex]::Match($text, '(?s)("files"\s*:\s*\[)(.*?)(\r?\n\s*\])')
  if (-not $m.Success) { Write-WarnLine '打包排除项：未找到 build.files 数组（上游格式变化？），跳过 —— 注意产物可能因此被 afterPack 的 auditNextPayload 拒绝。'; return }
  $body = $m.Groups[2].Value
  $wanted = @(
    '!node_modules/@deepseek-ai/libreoffice-kit-win32-arm64/**'
    '!node_modules/@koromix/koffi-win32-x64/win32_x64/koffi.lib'
  )
  $add = @($wanted | Where-Object { $body -notmatch [regex]::Escape('"' + $_ + '"') })
  if ($add.Count -eq 0) { Write-Info '打包排除项：已就位（无需注入）'; return }
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $addition = ($add | ForEach-Object { ",$nl      `"$_`"" }) -join ''
  $text = $text.Substring(0, $m.Groups[2].Index) + $body + $addition + $text.Substring($m.Groups[2].Index + $body.Length)
  [System.IO.File]::WriteAllText($pkgPath, $text)
  Write-WarnLine "打包排除项：已注入 $($add.Count) 条（与 runtime-file-policy.ts 对齐）：$($add -join '、')"
}

function Set-MarketWorkspaceCheck {
  # 上游 package:dir 会先跑 yarn market:prepare，其 MARKET_WORKSPACES 硬编码
  # desktop + beta + next 并逐个断言 dshmarket 已安装。本脚本排除了 desktop/beta，
  # 断言必然失败。这里把列表收缩为实际参与构建的工作区。
  $marketPath = Join-Path $script:Src 'scripts\prepare-dsh-market.mjs'
  if (-not (Test-Path -LiteralPath $marketPath)) { return }
  $text = [System.IO.File]::ReadAllText($marketPath)
  if (-not $text.Contains('MARKET_WORKSPACES')) { return }
  if ($text.Contains('MARKET_WORKSPACES_EXCLUDED')) { Write-Info 'dshmarket 校验工作区已收缩'; return }
  $anchor = [regex]::Match($text, "export const MARKET_WORKSPACES = \[[^\]]*\]")
  if (-not $anchor.Success) { Write-WarnLine 'dshmarket 脚本 MARKET_WORKSPACES 格式已变，跳过。'; return }
  $declared = @([regex]::Matches($anchor.Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  $keep = @($declared | Where-Object { $script:ExcludedWorkspaces -notcontains $_ })
  if ($keep.Count -eq 0) { Write-WarnLine 'dshmarket 校验工作区收缩后为空，跳过。'; return }
  $keepList = ($keep | ForEach-Object { "'$_'" }) -join ', '
  $replacement = "export const MARKET_WORKSPACES_EXCLUDED = ['$((($script:ExcludedWorkspaces | ForEach-Object { "'$_'" }) -join ', '))']`nexport const MARKET_WORKSPACES = [$keepList]"
  $text = $text.Remove($anchor.Index, $anchor.Length).Insert($anchor.Index, $replacement)
  [System.IO.File]::WriteAllText($marketPath, $text)
  Write-WarnLine "dshmarket 校验工作区已收缩为 [$keepList]"
}

function Set-AAWorkspaceCheck {
  # 同理：AA 策略文件的 assert 会遍历 beta 的 node_modules。排除后必须收缩。
  $policyPath = Join-Path $script:Src 'scripts\agents-anywhere-release-policy.mjs'
  if (-not (Test-Path -LiteralPath $policyPath)) { return }
  $text = [System.IO.File]::ReadAllText($policyPath)
  if ($text.Contains('AA_WORKSPACES_CHECKED')) { Write-Info 'AA 策略文件已含 AA_WORKSPACES_CHECKED'; return }
  $ws = [regex]::Match($text, "export const AA_WORKSPACES\s*=\s*\[(?<items>[^\]]*)\]")
  if (-not $ws.Success) { Write-WarnLine 'AA 策略文件 workspace 声明格式已变，跳过。'; return }
  $declared = @([regex]::Matches($ws.Groups['items'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  $keep = @($declared | Where-Object { $script:ExcludedWorkspaces -notcontains $_ })
  if ($keep.Count -eq 0) { Write-WarnLine 'AA 工作区收缩后为空，跳过。'; return }
  $keepList = ($keep | ForEach-Object { "'$_'" }) -join ', '
  $insertAt = $ws.Index + $ws.Length
  $text = $text.Insert($insertAt, "`nexport const AA_WORKSPACES_CHECKED = [$keepList]")
  $oldLoop = 'for (const workspace of AA_WORKSPACES) {'
  if ($text.Contains($oldLoop)) {
    $text = $text.Replace($oldLoop, 'for (const workspace of AA_WORKSPACES_CHECKED) {')
  }
  [System.IO.File]::WriteAllText($policyPath, $text)
  Write-WarnLine "AA 策略文件 assert 已收缩为 [$keepList]"
}

# ---------------- 安装 / 构建 ----------------

function Get-YarnCommand {  $corepack = Get-Command corepack.cmd -ErrorAction SilentlyContinue
  if (-not $corepack) { $corepack = Get-Command corepack -ErrorAction SilentlyContinue }
  if (-not $corepack) { throw '未找到 corepack。请安装 Node.js 22.19+ / 24.x。' }
  if (-not $env:COREPACK_ENABLE_DOWNLOAD_PROMPT) { $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0' }
  return @{ FileName = $corepack.Source; Prefix = @('yarn') }
}

function Invoke-Yarn {
  param([Parameter(Mandatory)][string[]]$Args)
  $yarn = Get-YarnCommand
  & $yarn.FileName @($yarn.Prefix + $Args)
  if ($LASTEXITCODE -ne 0) { throw "yarn $($Args -join ' ') 失败 (exit $LASTEXITCODE)" }
}

function Invoke-Workspace {
  $yarn = Get-YarnCommand
  Push-Location $script:Src
  try {
    $ver = (& $yarn.FileName @($yarn.Prefix + @('--version')) | Select-Object -Last 1).ToString().Trim()
    Write-Info "Corepack Yarn $ver"
    Invoke-Yarn @('install')
  } finally {
    Pop-Location
  }
}

function Ensure-ElectronDist {
  # .yarnrc.yml 的 enableScripts:false 让 electron 的 postinstall 不执行，于是
  # node_modules\electron\dist 缺失，而 electron-builder 现在优先用这个本地目录，
  # 报 "The specified electronDist does not exist"。这里按需补齐 dist：
  #   ① 先 HEAD 探出真正含该版本的镜像再设为 ELECTRON_MIRROR —— Electron 发新版后
  #      npmmirror 常有滞后（44.7.2 发布 8 小时后仍 404），不探测就会空跑一次大下载；
  #   ② install.js 之后仍无 electron.exe 时，自己下载 zip 并解包兜底。
  #   版式差异：npmmirror 是 <ver>/，GitHub release 是 v<ver>/（写错即 404）。
  $elDir = Join-Path $script:WsDir 'node_modules\electron'
  $installer = Join-Path $elDir 'install.js'
  if (-not (Test-Path -LiteralPath $installer)) {
    Write-WarnLine "未找到 $installer（依赖未安装？），跳过 electron dist 解包。"
    return
  }
  $distDir = Join-Path $elDir 'dist'
  $exePath = Join-Path $distDir 'electron.exe'
  if (Test-Path -LiteralPath $exePath) {
    Write-Info "electron dist 已就绪：$distDir"
    return
  }
  $version = (Get-JsonObject (Join-Path $elDir 'package.json')).version
  $archTag = if ("$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)".ToUpperInvariant() -like '*ARM64*') { 'arm64' } else { 'x64' }
  $zipName = "electron-v$version-win32-$archTag.zip"
  $mirrors = @(
    @{ Name = 'npmmirror'; Mirror = 'https://npmmirror.com/mirrors/electron/'; Dir = '{0}' },
    @{ Name = 'github'; Mirror = 'https://github.com/electron/electron/releases/download/'; Dir = 'v{0}' }
  )

  $mirror = $null
  foreach ($m in $mirrors) {
    $probeUrl = "$($m.Mirror)$($m.Dir -f $version)/$zipName"
    try {
      $r = Invoke-WebRequest -Uri $probeUrl -Method Head -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
      if ([int]$r.StatusCode -eq 200) {
        $mirror = $m
        Write-Info "electron dist 镜像已确认含 $version：$($m.Name)"
        break
      }
    } catch {
      Write-Info "electron dist 镜像 $($m.Name) 未确认（$(($_.Exception.Message -replace '\s+', ' '))）"
    }
  }
  if ($mirror) {
    $env:ELECTRON_MIRROR = $mirror.Mirror
    $env:ELECTRON_CUSTOM_DIR = ($mirror.Dir -f $version)
  } else {
    Write-WarnLine "没有镜像被确认含 $version 的 $zipName，按现有 ELECTRON_MIRROR 继续尝试。"
  }

  Write-WarnLine "缺少 $distDir，正在运行 electron install.js 解包（复用缓存/镜像）..."
  Push-Location $elDir
  try {
    # @electron/get v5 用 Node 的 fetch：Node 24+ 配 NODE_USE_ENV_PROXY 才会认 HTTPS_PROXY。
    $env:NODE_USE_ENV_PROXY = '1'
    $env:ELECTRON_GET_USE_PROXY = '1'
    # 非零退出不能被 $PSNativeCommandUseErrorActionPreference 抛成致命错误，否则到不了兜底。
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
      & node install.js
      if ($LASTEXITCODE -ne 0) { Write-WarnLine "electron install.js 退出码 $LASTEXITCODE" }
    } finally {
      $PSNativeCommandUseErrorActionPreference = $prevNative
    }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $exePath) -and $mirror) {
    $url = "$($mirror.Mirror)$($mirror.Dir -f $version)/$zipName"
    try {
      $zip = Join-Path $env:TEMP $zipName
      Write-WarnLine "install.js 未产出 dist，改为直接下载并解包：$url"
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 1800
      New-Item -ItemType Directory -Force -Path $distDir | Out-Null
      Expand-Archive -LiteralPath $zip -DestinationPath $distDir -Force
      Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    } catch {
      Write-WarnLine "electron dist 直接下载/解包失败：$($_.Exception.Message)"
    }
  }

  if (Test-Path -LiteralPath $exePath) {
    Write-Ok "electron dist 已就绪：$distDir"
  } elseif (Test-Path -LiteralPath $distDir) {
    Write-WarnLine "electron dist 目录存在但未找到 electron.exe：$distDir"
  } else {
    Write-WarnLine 'electron dist 仍缺失，electron-builder 打包会失败。'
  }
}

function Invoke-NextScript {
  param([Parameter(Mandatory)][string]$ScriptName)
  Push-Location $script:Src
  try {
    Invoke-Yarn @('workspace', $script:WsName, $ScriptName)
  } finally {
    Pop-Location
  }
}

# ---------------- 产物核对 ----------------

function Get-PackagedDir {
  $candidates = @(
    (Join-Path $script:WsDir 'dist\win-unpacked'),
    (Join-Path $script:WsDir 'dist\linux-unpacked')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  return $null
}

function Publish-OverlayRuntimeAssets {
  # startup.json 必须落在 exe 同级，应用才会读到。
  $exeDir = Get-PackagedDir
  if (-not $exeDir) { Write-WarnLine '未找到打包目录，跳过 startup.json 部署。'; return }
  $src = Join-Path $script:OverlayDir 'startup.json'
  if (-not (Test-Path -LiteralPath $src)) { Write-Info '覆盖层无 startup.json，跳过部署。'; return }
  $dst = Join-Path $exeDir 'startup.json'
  Copy-Item -LiteralPath $src -Destination $dst -Force
  Write-Ok "startup.json 已部署到 $dst"
}

function Get-ArchiveHelper {
  # 探针用 @electron/asar 读归档条目表 / 读单个条目。该模块**不再**由 next 自己声明，
  # 而是随 electron-builder 的依赖树进来，落地位置可能是 dsh-desktop-next\node_modules，
  # 也可能是仓库根 dsh-desktop\node_modules（yarn workspaces 会提升）。Node 按"脚本自身
  # 所在目录"逐级向上找 node_modules，两处都能被覆盖 —— 所以探针必须写在工作区内部
  # （放 overlay-next\ 下会 MODULE_NOT_FOUND），这里落到 dist\ 下的临时文件，结束清理。
  $distDir = Join-Path $script:WsDir 'dist'
  New-Item -ItemType Directory -Force -Path $distDir | Out-Null
  $entry = Join-Path $distDir '.asar-probe.cjs'
  if (Test-Path -LiteralPath $entry) { return $entry }
  $code = @'
// Read one payload entry, or list the archive entry table. Lives inside the
// workspace so `require('@electron/asar')` resolves to the installed copy.
let asar
try {
  asar = require('@electron/asar')
} catch (error) {
  process.stderr.write('asar-probe: cannot resolve @electron/asar (workspace dependencies missing?): '
    + String(error && error.message ? error.message : error) + '\n')
  process.exit(3)
}
const [, , mode, archive, arg] = process.argv
if (mode === 'list') {
  process.stdout.write(asar.listPackage(archive, { isPack: false }).join('\n'))
} else if (mode === 'read') {
  try {
    process.stdout.write(asar.extractFile(archive, arg).toString('utf8'))
  } catch (error) {
    process.stderr.write(String(error && error.message ? error.message : error))
    process.exit(2)
  }
} else {
  process.stderr.write('usage: asar-probe.cjs list|read <archive> [entry]')
  process.exit(2)
}
'@
  Set-Content -LiteralPath $entry -Value $code -Encoding utf8
  return $entry
}

function Invoke-ArchiveProbe {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $helper = Get-ArchiveHelper
  $prev = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $stdout = @(& node $helper @Arguments 2>&1)
    $code = $LASTEXITCODE
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prev
  }
  if ($code -ne 0) {
    # read 失败 = 条目不存在（或不可读），由调用方按"缺条目"处理。
    # 但 list 失败说明**探针本身跑不起来**（最典型：@electron/asar 解析不到）。这种情况
    # 必须直接报出来，否则会被误报成"产物缺一堆条目"，把人引到错误的方向。
    if ($Arguments[0] -eq 'read') { return @() }
    throw "asar 探针执行失败 (exit $code)：$($stdout -join ' ')"
  }
  return $stdout
}

function Get-ArchiveEntries {
  param([Parameter(Mandatory)][string]$Archive)
  return @(Invoke-ArchiveProbe -Arguments @('list', $Archive) |
    ForEach-Object { $_ -replace '\\', '/' -replace '^/+', '' })
}

function Get-ArchiveFileText {
  param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Entry
  )
  $out = @(Invoke-ArchiveProbe -Arguments @('read', $Archive, $Entry))
  if ($out.Count -eq 0) { return $null }
  return ($out -join "`n")
}

function Assert-OverlayArtifacts {
  $exeDir = Get-PackagedDir
  if (-not $exeDir) { throw '未找到打包目录（dist\win-unpacked）。' }
  $rows = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[string]

  # 1) 主程序
  $exe = @(Get-ChildItem -LiteralPath $exeDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
  if ($exe.Count -gt 0) {
    $rows.Add([pscustomobject]@{ 项目 = '主程序 exe'; 结果 = 'OK'; 说明 = "$($exe[0].Name) · $([int]($exe[0].Length / 1MB)) MB" })
  } else {
    $rows.Add([pscustomobject]@{ 项目 = '主程序 exe'; 结果 = '缺失'; 说明 = '目录下没有 .exe' })
    $missing.Add('主程序 exe')
  }

  # 2) startup.json（exe 同级）
  $cfg = Join-Path $exeDir 'startup.json'
  if (Test-Path -LiteralPath $cfg) {
    $rows.Add([pscustomobject]@{ 项目 = 'startup.json'; 结果 = 'OK'; 说明 = "exe 同级 · $((Get-Item $cfg).Length) 字节" })
  } else {
    $rows.Add([pscustomobject]@{ 项目 = 'startup.json'; 结果 = '缺失'; 说明 = '启动配置不会被读取' })
    $missing.Add('startup.json')
  }

  # 3) 应用负载：ASAR 或普通目录两种布局都要认
  $resources = Join-Path $exeDir 'resources'
  $archive = Join-Path $resources 'app.asar'
  $plain = Join-Path $resources 'app'
  $useArchive = Test-Path -LiteralPath $archive
  $payload = if ($useArchive) { $archive } else { $plain }
  $layoutName = if ($useArchive) { 'app.asar' } else { 'resources\app' }

  if (-not (Test-Path -LiteralPath $payload)) {
    $rows.Add([pscustomobject]@{ 项目 = '应用负载'; 结果 = '缺失'; 说明 = "既无 $archive 也无 $plain" })
    $missing.Add('应用负载')
  } else {
    $rows.Add([pscustomobject]@{ 项目 = '应用负载'; 结果 = 'OK'; 说明 = $layoutName })

    # 3a) 必备条目
    $probe = if ($useArchive) { @(Get-ArchiveEntries $archive) } else { @() }
    foreach ($item in $script:RequiredPayloadEntries) {
      $present = if ($useArchive) { $probe -contains $item } else { Test-Path -LiteralPath (Join-Path $plain ($item -replace '/', '\')) }
      if (-not $present) { $missing.Add("负载条目 $item") }
    }

    # 3b) 覆盖层集成点必须真的打进去了
    foreach ($entry in $script:RequiredMarkers.Keys) {
      $marker = $script:RequiredMarkers[$entry]
      $found = $false
      if ($useArchive) {
        $snippet = Get-ArchiveFileText $archive $entry
        $found = ($null -ne $snippet) -and $snippet.Contains($marker)
      } else {
        $target = Join-Path $plain ($entry -replace '/', '\')
        $found = (Test-Path -LiteralPath $target) -and ((Select-String -Path $target -Pattern $marker -List -ErrorAction SilentlyContinue) -ne $null)
      }
      if ($found) {
        $rows.Add([pscustomobject]@{ 项目 = "补丁代码 ($entry)"; 结果 = 'OK'; 说明 = "$marker 已打包（$layoutName）" })
      } else {
        $rows.Add([pscustomobject]@{ 项目 = "补丁代码 ($entry)"; 结果 = '缺失'; 说明 = "$layoutName 的 $entry 中没有 $marker" })
        $missing.Add("补丁代码（$entry 的 $marker）")
      }
    }
  }

  # 4) resources 文件数（ASAR 生效应显著下降）
  if (Test-Path -LiteralPath $resources) {
    $count = (Get-ChildItem -LiteralPath $resources -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    $rows.Add([pscustomobject]@{ 项目 = 'resources 文件数'; 结果 = 'OK'; 说明 = "$count 个（ASAR 启用时应为千级）" })
  }

  Write-Host ''
  Write-Host '产物核对：' -ForegroundColor White
  foreach ($row in $rows) {
    $color = if ($row.结果 -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-16} " -f $row.项目) -NoNewline
    Write-Host ("{0,-6}" -f $row.结果) -NoNewline -ForegroundColor $color
    Write-Host $row.说明
  }
  if ($missing.Count -gt 0) {
    throw "产物不完整：$($missing -join '、')"
  }
  Write-Ok '产物已确认（启动配置 + 应用负载 + 补丁代码）'
}

function Remove-ArchiveHelper {
  # 探针脚本写在 dist\ 下，完成后清掉，避免留在产物目录里。
  $entry = Join-Path $script:WsDir 'dist\.asar-probe.cjs'
  if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Force -ErrorAction SilentlyContinue }
}

function Update-PackagedTimestamps {  $exeDir = Get-PackagedDir
  if (-not $exeDir) { return }
  $now = Get-Date
  $files = 0; $dirs = 0
  Get-ChildItem -LiteralPath $exeDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.LastWriteTime = $now; $files++ }
  Get-ChildItem -LiteralPath $exeDir -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.LastWriteTime = $now; $dirs++ }
  Write-Ok "已将 $files 个文件、$dirs 个目录的时间戳规整为当前时间"
}

# ---------------- 主流程 ----------------

try {
  $bannerRuntime = Get-NextDeclaredRuntime
  if (-not $bannerRuntime) { $bannerRuntime = '(跟随上游，待校验)' }
  $banner = @"
DSH NEXT build log
started : $(Get-Date -Format o)
root    : $script:Root
src     : $script:Src
workspace: $script:WsName
target  : $Target
runtime : $bannerRuntime（跟随上游）
"@
  Write-Log $banner
  Write-Host $banner -ForegroundColor DarkGray

  if (-not $NoProxy -and $Proxy) {
    $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy
    $env:http_proxy = $Proxy; $env:https_proxy = $Proxy
    # Node 的原生 fetch（undici）**默认不认** HTTP_PROXY/HTTPS_PROXY —— Node 24 起需要
    # NODE_USE_ENV_PROXY=1 才会读。而上游 scripts/primary-runtime.ts 下载运行时载荷用的
    # 正是 fetch + AbortSignal.timeout（默认 300000ms），少了这个变量就是直连：
    # 本机直连 github.com 不通、直连 nodejs.org 很慢，于是 package:dir 会在 300s 后以
    # "DOMException [TimeoutError]" 失败（2026-10-14 实测对照：不设该变量时 github HEAD
    # 19.5s 后 fetch failed、nodejs.org 直连 4.9s；设置后两者分别 4.4s / 3.4s 返回 200）。
    $env:NODE_USE_ENV_PROXY = '1'
    $env:ELECTRON_GET_USE_PROXY = '1'
    if (-not $env:DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS) {
      # 上游那个 5 分钟上限在代理链路上偏紧（Python 载荷是上百 MB），给足余量。
      # 显式设置过就不动，尊重调用方。
      $env:DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS = '900000'
    }
    Write-Info "已设置代理: $Proxy（NODE_USE_ENV_PROXY=1；运行时载荷下载超时 $($env:DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS)ms，可用同名环境变量覆盖）"
  } elseif ($NoProxy) {
    Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    $env:NODE_USE_ENV_PROXY = '0'
    Write-Info '已禁用代理（-NoProxy）'
  }
  Write-Info "日志: $script:LogPath"

  if (-not (Test-Path -LiteralPath (Join-Path $script:Src '.git'))) {
    throw "未找到 $script:Src（或缺少 .git）。请先运行一次 stable 的构建以完成克隆。"
  }

  Invoke-Step '导出覆盖层改动（pull 前保护）' { Export-Overlay }
  Invoke-Step '获取 / 更新 dsh-desktop 源码' {
    if ($SkipPull) { Write-WarnLine '已跳过源码拉取（-SkipPull）。' } else { Update-SourceRepository }
  }
  Invoke-Step '对齐 deepseek-harness 子模块' { Ensure-Submodule }
  Invoke-Step '选择工作区（加入 next / 排除 stable+beta）' { Set-WorkspaceSelection }
  Invoke-Step '应用 next 覆盖层（代码补丁）' { Apply-Overlay }
  Invoke-Step '校验运行时版本与打包姿态' {
    Test-NextRuntimeVersion
    Set-ElectronOverride
    Test-PackagingPosture
    Set-PayloadExclusions
    Set-MarketWorkspaceCheck
    Set-AAWorkspaceCheck
  }

  if (-not $SkipInstall) {
    Invoke-Step '安装工作区依赖' { Invoke-Workspace }
  } else {
    Write-WarnLine '已跳过 yarn install（-SkipInstall）'
  }

  if (-not $env:ELECTRON_MIRROR) { $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/' }

  Invoke-Step '准备 Electron 运行时（dist 解包）' { Ensure-ElectronDist }

  switch ($Target) {
    'build' { Invoke-Step "编译 ($script:WsName / yarn build)" { Invoke-NextScript 'build' } }
    'typecheck' { Invoke-Step "类型检查 ($script:WsName)" { Invoke-NextScript 'typecheck' } }
    'test' { Invoke-Step "单元测试 ($script:WsName)" { Invoke-NextScript 'test' } }
    'check' { Invoke-Step "门禁检查 ($script:WsName)" { Invoke-NextScript 'check' } }
    'package-dir' {
      Invoke-Step "执行 yarn package:dir ($script:WsName)" { Invoke-NextScript 'package:dir' }
      Invoke-Step '部署覆盖层运行时资源（startup.json → exe 同级）' { Publish-OverlayRuntimeAssets }
      Invoke-Step '核对产物' { Assert-OverlayArtifacts }
      Invoke-Step '规整产物时间戳为当前时间' { Update-PackagedTimestamps }
      Remove-ArchiveHelper
    }
  }

  Write-Host ''
  Write-Host ('=' * 72) -ForegroundColor Green
  if ($script:Failed -eq 0) {
    Write-Host '构建成功' -ForegroundColor Green
  } else {
    Write-Host "构建结束但有 $($script:Failed) 个步骤失败" -ForegroundColor Yellow
  }
  Write-Host ('=' * 72) -ForegroundColor Green
  $exeDir = Get-PackagedDir
  if ($exeDir) { Write-Host "产物：$exeDir" }
  Write-Info "日志已写入 $script:LogPath"

  if ($script:Failed -gt 0) { exit 1 }
  exit 0
} catch {
  Write-ErrLine $_.Exception.Message
  if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
  Write-Host ''
  Write-Host '排查建议：' -ForegroundColor Yellow
  Write-Host '  1. 确认 Node.js 为 22.19+ 或 24.x，并可用 corepack。'
  Write-Host '  2. 覆盖层补丁失配时，按提示用 git diff 重新导出 overlay-next\patches\*.patch。'
  Write-Host "  3. 查看日志: $script:LogPath"
  exit 1
}
