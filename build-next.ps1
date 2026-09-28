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

# 运行时固定（与 stable 保持一致，见 build.ps1）
$script:RuntimeVersion = '0.1.7-rc.2'
$script:HarnessCommit = '477b4f420553e8a52c2fbccc464d7561b239c443'  # dsh-v0.1.7-rc.2

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
  'dsh-desktop-next/package.json'
  'dsh-desktop-next/src/main.ts'
  'dsh-desktop-next/scripts/verify-packaged.ts'
  'dsh-desktop-next/scripts/verify-fuses.ts'
)

# 产物核对：exe 同级 / 应用负载内必须具备的条目
$script:RequiredPayloadEntries = @(
  'lib/main.js'
  'lib/host.js'
  'lib/client.js'
  'cordis.patch.yml'
  'host.cordis.patch.yml'
  'startup-config.ts 集成点'
)
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
  if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) {
    Write-Info '初始化 deepseek-harness 子模块 ...'
    & git -C $script:Src submodule update --init --recursive deepseek-harness 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "submodule update 失败 (exit $LASTEXITCODE)" }
  }
  $actual = (& git -C $sub rev-parse HEAD).Trim()
  if ($actual -ne $script:HarnessCommit) {
    Write-Info "对齐 deepseek-harness 到 $($script:HarnessCommit.Substring(0,10)) ..."
    & git -C $sub checkout --force $script:HarnessCommit 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "子模块 checkout 失败 (exit $LASTEXITCODE)" }
  }
  Write-Ok "deepseek-harness = $($script:HarnessCommit.Substring(0,10))"
}

# ---------------- 覆盖层 ----------------

function Export-Overlay {
  # 把工作区里这些文件的本地改动导出成 overlay-next\patches，然后再 pull。
  # 这样"改了源码 → 跑本脚本"就能固化改动，且 pull 不会丢。
  if ($SkipPull) { return }
  Push-Location $script:Src
  try {
    $patchDir = Join-Path $script:OverlayDir 'patches'
    New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
    foreach ($rel in $script:OverlayPatches) {
      $diff = @(& git diff -- $rel 2>$null)
      if ($LASTEXITCODE -ne 0) { continue }
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

function Set-RuntimeVersionPinned {
  # stable 的 build.ps1 会把运行时固定到 $script:RuntimeVersion。next 这边上游
  # 已经与固定值一致（0.1.7-rc.2），保持一致性与可重复性，这里做同样的校验，
  # 只在真的不一致时才改写，避免无谓地动上游文件。
  $upPath = Join-Path $script:Src 'upstream.json'
  if (-not (Test-Path -LiteralPath $upPath)) { Write-WarnLine '未找到 upstream.json，跳过运行时校验。'; return }
  $up = Get-JsonObject $upPath
  $next = $up.channels.next
  if ($null -eq $next) { Write-WarnLine 'upstream.json 无 next 通道条目，跳过。'; return }
  if ($next.sourceVersion -ne $script:RuntimeVersion) {
    Write-WarnLine "next 通道运行时为 $($next.sourceVersion)，与固定值 $($script:RuntimeVersion) 不一致（本脚本不改写，请确认是否预期）。"
  } else {
    Write-Info "运行时版本一致：next = $($script:RuntimeVersion)"
  }

  # 依赖版本：确保 next 工作区声明的是固定版本
  $wsPkgPath = Join-Path $script:WsDir 'package.json'
  $pkg = Get-JsonObject $wsPkgPath
  $changed = $false
  foreach ($field in @('dependencies', 'devDependencies')) {
    $prop = $pkg.PSObject.Properties[$field]
    if (-not $prop -or $null -eq $prop.Value) { continue }
    $dep = $prop.Value
    foreach ($name in @($dep.PSObject.Properties.Name)) {
      if ($name -like '@deepseek-ai/dsh*' -and $dep.$name -ne $script:RuntimeVersion) {
        Write-WarnLine "依赖不一致：$name = $($dep.$name)（期望 $($script:RuntimeVersion)）"
        $dep.$name = $script:RuntimeVersion
        $changed = $true
      }
    }
  }
  if ($changed) {
    Set-Content -LiteralPath $wsPkgPath -Value (ConvertTo-Json $pkg -Depth 100) -Encoding utf8 -NoNewline
    Write-WarnLine "运行时版本固定：$script:WsName 的 @deepseek-ai/dsh* 依赖 → $($script:RuntimeVersion)"
  }
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

function Set-PackagingFixes {
  # 与 stable 相同的 Windows 打包必需修复。
  # 1) package.ts 的 dir 目标禁用原生重编译（本机没有完整编译环境）
  $dirScript = Join-Path $script:WsDir 'scripts\package.ts'
  if (Test-Path -LiteralPath $dirScript) {
    $t = [System.IO.File]::ReadAllText($dirScript)
    if ($t -notmatch 'npmRebuild' -and $t -match 'electron-builder') {
      Write-Info 'package.ts 未显式设置 npmRebuild（已由 build.npmRebuild=false 覆盖）'
    }
  }
  # 2) 移除 afterAllArtifactBuild（PR #829 事后校验钩子在本机会失败；它只在
  #    dist:win 之类目标里跑，package-dir 不触发，但保持与 stable 一致更安全）
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $pkg = Get-JsonObject $pkgPath
  if ($pkg.build.PSObject.Properties.Name -contains 'afterAllArtifactBuild') {
    $pkg.build.PSObject.Properties.Remove('afterAllArtifactBuild')
    Set-Content -LiteralPath $pkgPath -Value (ConvertTo-Json $pkg -Depth 100) -Encoding utf8 -NoNewline
    Write-WarnLine '修复：已移除 build.afterAllArtifactBuild（禁用 PR #829 事后校验钩子）'
  }
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
  # 报 "The specified electronDist does not exist"。这里按需跑 electron 自带的
  # install.js（优先复用 @electron/get 缓存，缺失时走 ELECTRON_MIRROR 镜像）。
  $elDir = Join-Path $script:WsDir 'node_modules\electron'
  $installer = Join-Path $elDir 'install.js'
  if (-not (Test-Path -LiteralPath $installer)) {
    Write-WarnLine "未找到 $installer（依赖未安装？），跳过 electron dist 解包。"
    return
  }
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
  # @electron/asar 是 dsh-desktop-next 的 devDependency，只在该工作区的
  # node_modules 下可解析。Node 按"脚本自身所在目录"逐级向上找 node_modules，
  # 所以探针脚本必须写在工作区内部（放 overlay-next\ 下会 MODULE_NOT_FOUND），
  # 这里落到 dist\ 下的临时文件，构建结束时清理。
  $distDir = Join-Path $script:WsDir 'dist'
  New-Item -ItemType Directory -Force -Path $distDir | Out-Null
  $entry = Join-Path $distDir '.asar-probe.cjs'
  if (Test-Path -LiteralPath $entry) { return $entry }
  $code = @'
// Read one payload entry, or list the archive entry table. Lives inside the
// workspace so `require('@electron/asar')` resolves to the installed copy.
const { listPackage, extractFile } = require('@electron/asar')
const [, , mode, archive, arg] = process.argv
if (mode === 'list') {
  process.stdout.write(listPackage(archive, { isPack: false }).join('\n'))
} else if (mode === 'read') {
  try {
    process.stdout.write(extractFile(archive, arg).toString('utf8'))
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
    return @(& node $helper @Arguments 2>$null)
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prev
  }
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
    foreach ($item in @('lib/main.js', 'lib/host.js', 'lib/client.js', 'cordis.patch.yml', 'host.cordis.patch.yml')) {
      $present = if ($useArchive) { $probe -contains $item } else { Test-Path -LiteralPath (Join-Path $plain ($item -replace '/', '\')) }
      if (-not $present) { $missing.Add("负载条目 $item") }
    }

    # 3b) startup-config 集成点必须真的打进去了
    $marker = 'applyDesktopStartupConfig'
    $found = $false
    if ($useArchive) {
      $snippet = Get-ArchiveFileText $archive 'lib/main.js'
      $found = ($null -ne $snippet) -and $snippet.Contains($marker)
    } else {
      $mainJs = Join-Path $plain 'lib\main.js'
      $found = (Test-Path -LiteralPath $mainJs) -and ((Select-String -Path $mainJs -Pattern $marker -List -ErrorAction SilentlyContinue) -ne $null)
    }
    if ($found) {
      $rows.Add([pscustomobject]@{ 项目 = '补丁代码'; 结果 = 'OK'; 说明 = "$marker 已打包（$layoutName）" })
    } else {
      $rows.Add([pscustomobject]@{ 项目 = '补丁代码'; 结果 = '缺失'; 说明 = "$layoutName 的 lib/main.js 中没有 $marker" })
      $missing.Add('补丁代码（startup-config 集成点）')
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
  $banner = @"
DSH NEXT build log
started : $(Get-Date -Format o)
root    : $script:Root
src     : $script:Src
workspace: $script:WsName
target  : $Target
runtime : $script:RuntimeVersion
"@
  Write-Log $banner
  Write-Host $banner -ForegroundColor DarkGray

  if (-not $NoProxy -and $Proxy) {
    $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy
    $env:http_proxy = $Proxy; $env:https_proxy = $Proxy
    Write-Info "已设置代理: $Proxy"
  } elseif ($NoProxy) {
    Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
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
  Invoke-Step '固定运行时版本与打包修复' {
    Set-RuntimeVersionPinned
    Set-ElectronOverride
    Set-PackagingFixes
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
