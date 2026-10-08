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

.PARAMETER ElectronVersion
  覆盖 Electron 版本（可选）。**不指定时使用上游声明的版本**：完全不改写
  <通道>/package.json 的 electron，构建上游原样。仅在 -Overlay 时生效；指定后把
  devDependencies.electron 改写为该版本，已装版本与之不一致时自动补装依赖（含 Electron
  头文件缓存与 dist 解包）。
  与 build-next.ps1 的 -ElectronVersion 同款语义（未指定 = 沿用上游声明）；上游声明与
  目标一致时同样跳过改写。例：-ElectronVersion 45.0.0。

.PARAMETER HarnessVersion
  覆盖 deepseek-harness（dsh 运行时）版本（可选）。**不指定时使用上游 upstream.json
  stable 通道声明的版本**：不固定、不改写任何文件，构建上游原样。指定后把 stable 通道
  固定到该版本 —— 改写 upstream.json 的 commit / sourceVersion / runtimePackageVersion /
  runtimeSource，以及当前通道工作区的 @deepseek-ai/dsh* 依赖、**同属该 harness 线的伴随依赖**
  （@deepseek-ai/cordis*、@deepseek-ai/schemastery 等，按上游同线通道工作区的声明照抄）
  与根 package.json resolutions。
  该版本的 vendor/dsh-runtime/<版本>/manifest.json 必须已存在（由 yarn upstream:prepare-runtime
  + node scripts/sync-vendored-runtime.mjs --write --channel stable 生成）。
  目标版本与上游声明**不同**时，commit 自动取自 deepseek-harness 仓库里 dsh-v<版本> 标签
  指向的 commit（先查本地子模块标签，再退回远端 ls-remote）；只有该版本查不到标签时，
  才需要 -HarnessCommit 显式指定。

.PARAMETER HarnessCommit
  -HarnessVersion 对应的 deepseek-harness commit（7-40 位十六进制 SHA）。**通常无需指定**：
  不指定时按顺序取 —— 目标版本与上游声明相同时取上游 upstream.json 的 commit；否则取
  deepseek-harness 仓库 dsh-v<版本> 标签指向的 commit（先本地子模块标签，再远端 ls-remote）。
  显式指定时以参数为准，并与标签核对（不一致只告警，因为上游会前移同一版本的 commit）。
  仅在目标版本没有对应标签、或需要临时指向标签以外的 commit 时才用。

.PARAMETER PnpmVersion
  覆盖 pnpm 版本（可选）。**不指定时使用上游声明的版本**：完全不改写
  <通道>/package.json 的 dependencies.pnpm，上游自带的
  "pnpm@npm:<上游版本>": "patch:…/patches/pnpm@<上游版本>.patch" 原样生效。仅在 -Overlay
  时生效；指定后把 dependencies.pnpm 改写为该版本，并把根 resolutions 的 pnpm 补丁条目
  重指到同一版本、把 overlay\pnpm\pnpm@<版本>.patch 拷进 <src>\patches\。
  ⚠️ 与 -ElectronVersion 的关键差别：pnpm 的补丁 resolution 键**是版本化的**
  （"pnpm@npm:11.8.0"），换版本后原键不再匹配任何依赖 → 上游补丁会**静默失效**（Yarn 不
  报错，node_modules 里就是未打补丁的原版）。所以指定该参数时**必须**同时提供该版本的
  补丁 overlay\pnpm\pnpm@<版本>.patch；没有补丁时只告警、不重指 resolution（等于该版本的
  --config.minimumReleaseAge=0 修复缺失）。
  例：-PnpmVersion 11.28.5。

.PARAMETER KeepTimestamps
  保留 Electron 官方 zip 的 1980-01-01 时间戳（可复现构建行为）。
  默认关闭：打包后会把 dist\win-unpacked 内文件时间戳规整为当前时间。

.EXAMPLE
  .\build.ps1
  .\build.ps1 -Target package-dir              # 解包打包（无覆盖层）
  .\build.ps1 -Overlay -Target package-dir     # 应用本地覆盖层（quick-build-overlay 默认）
  .\build.ps1 -Overlay -Target package-dir -ElectronVersion 45.0.0   # 临时换 Electron 版本
  .\build.ps1 -Overlay -Target package-dir -PnpmVersion 11.28.5       # 临时换 pnpm 版本（需 overlay\pnpm\pnpm@11.28.5.patch）
  .\build.ps1 -Target package-dir -HarnessVersion 0.2.1-alpha.1   # 换 dsh 运行时版本（commit 由标签 dsh-v0.2.1-alpha.1 解析）
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
  [switch]$KeepTimestamps,

  # 覆盖层 Electron 版本（仅在 -Overlay 时生效）。**未指定时使用上游声明的版本**：
  # '' = 未指定 → 完全不改写 <通道>/package.json 的 electron（构建上游原样）；指定 → 改写为
  # 该版本（需要临时换版本时在执行时传入，如 45.0.0）。与 build-next.ps1 同款语义。
  # 校验模式允许空串（默认值 '' 表示未指定）。
  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$ElectronVersion = '',

  # deepseek-harness（dsh 运行时）版本覆盖。**未指定时使用上游 upstream.json stable 通道
  # 声明的版本**（不固定 / 不改写）。指定时把 stable 通道固定到该版本，该版本的
  # vendor/dsh-runtime/<版本>/ 必须已存在；与上游声明不同的目标，commit 自动由标签
  # dsh-v<版本> 解析（见 Resolve-HarnessCommitFromTag），无需手抄 sha。
  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$HarnessVersion = '',

  # -HarnessVersion 对应的 deepseek-harness commit（7-40 位十六进制）。**通常无需指定**：
  # 版本 == 上游声明 → 取上游 upstream.json 的 commit；否则 → 取标签 dsh-v<版本> 的 commit。
  # 显式给出时以参数为准，并与标签核对（不一致只告警：上游会前移同一版本的 commit）。
  [ValidatePattern('^(?:[0-9a-fA-F]{7,40})?$')]
  [string]$HarnessCommit = '',

  # 覆盖层 pnpm 版本（仅在 -Overlay 时生效）。**未指定时使用上游声明的版本**：
  # '' = 未指定 → 完全不改写 <通道>/package.json 的 dependencies.pnpm（构建上游原样，
  # 上游自带的 patches/pnpm@<版本>.patch resolution 照旧生效）；指定 → 改写为该版本，
  # 并把根 resolutions 的 pnpm 补丁条目重指到该版本（补丁取自 overlay\pnpm\pnpm@<版本>.patch）。
  # 语义与 -ElectronVersion 一致；差别在于 pnpm 的补丁 resolution 键是版本化的，
  # 换版本必须同时重指，否则补丁静默失效 —— 详见 Set-PnpmOverride。
  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$PnpmVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:Root = $PSScriptRoot
$script:Src = Join-Path $script:Root 'dsh-desktop'
# dsh-desktop 是独立 Git 仓库（不再作为本仓库的子模块）：由 Ensure-Source 直接
# 克隆（不存在时）或 fetch + 重置到上游 $SrcBranch 最新（已存在时），不再依赖
# 父仓库的 gitlink / .gitmodules —— 拉取总是拿到上游最新，不会停在旧版本。
$script:SrcRepository = 'https://github.com/anywhere-labs/dsh-desktop.git'
$script:SrcBranch = 'master'
# deepseek-harness 子模块（嵌套在 dsh-desktop 内）的远端。**只用于把 -HarnessVersion
# 解析成 commit**（查标签 dsh-v<版本>）；构建本体不使用该 URL —— 不做额外 fetch / checkout，
# commit 归属仍由 upstream.json / 标签决定。换目标版本时上游 upstream.json 只声明自己那一版，
# 所以「版本 → commit」只能靠标签。
$script:HarnessRepository = 'https://github.com/deepseek-ai/deepseek-harness.git'
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
# 本地覆盖层：electron 目标版本。取值来源为 -ElectronVersion 参数 —— **未指定（''）时
# 不覆盖，直接使用上游声明的版本**（构建上游原样）；与 build-next.ps1 的
# Set-ElectronOverride 同款语义。Set-ElectronOverride 只在显式指定时才改写
# <通道>/package.json，且官方声明与目标一致时同样跳过 —— 两者都不成立时才真正改写
# （例如官方尚未跟进、本地确需更新的版本）。
$script:ElectronOverride = $ElectronVersion
# 是否由命令行显式指定了**非空**版本（用于日志区分“上游声明”与“参数指定”）。
$script:ElectronVersionExplicit = $MyInvocation.BoundParameters.ContainsKey('ElectronVersion')
$script:ElectronOverrideActive = $script:ElectronVersionExplicit -and
  (-not [string]::IsNullOrWhiteSpace($ElectronVersion))
# deepseek-harness（dsh 运行时）版本：**未指定 -HarnessVersion 时使用上游 upstream.json
# stable 通道声明的版本**（sourceVersion / commit），不做任何固定或改写 —— 构建上游原样。
# 指定 -HarnessVersion 时才固定到该版本；commit 由 Resolve-HarnessVersion 决定
# （显式参数 > 上游 upstream.json > 标签 dsh-v<版本>），通常无需手抄 sha。
#
# ⚠️ 命名铁律：解析结果必须叫 $script:ResolvedRuntimeVersion / $script:ResolvedHarnessCommit，
# **绝不能叫 $script:HarnessCommit** —— PowerShell 里「参数」就是脚本作用域变量，
# $script:HarnessCommit 与参数 $HarnessCommit **是同一个变量**。2026-10-04 实际踩到：
# 变量块先写 $script:HarnessCommit = <常量>，把用户传入的 -HarnessCommit 静默覆盖成常量，
# 于是「版本与上游不同必须显式给 commit」的校验被绕过、直接固定到错误的 commit
# （表现为 -HarnessCommit 被无声忽略）。改写脚本时不要把解析结果写回参数同名变量。
#
# 两个解析结果由 Resolve-HarnessVersion 在源码同步之后写入，此前为 $null 占位。
# 上游声明优先从 `git show HEAD:upstream.json` 读取 —— 工作区那份可能已被上一次构建的
# 固定改写（或已被覆盖层重置），不代表上游声明。
# 基线参考（本脚本最近一次验证过的上游版本，仅供人工比对，不参与运行）：
#   stable / dsh 0.2.0-rc.2 —— 但注意上游会把同一 sourceVersion 的 commit 前移
#   （实测 4878cdabd8 → 639ed01539：前者正是标签 dsh-v0.2.0-rc.1 的 commit），
#   所以「未指定 -HarnessVersion」时 commit 以上游 upstream.json 为准；
#   「指定了版本」时以标签 dsh-v<版本> 为准（upstream.json 只声明自己那一版）。
$script:HarnessVersionOverride = $HarnessVersion
$script:HarnessCommitOverride = $HarnessCommit
$script:HarnessOverrideActive = $MyInvocation.BoundParameters.ContainsKey('HarnessVersion') -and
  (-not [string]::IsNullOrWhiteSpace($HarnessVersion))
$script:ResolvedRuntimeVersion = $null
$script:ResolvedHarnessCommit = $null
# 本地覆盖层：pnpm 目标版本（-PnpmVersion）。语义与 $script:ElectronOverride 完全一致：
# 未指定（''）时不覆盖 —— 上游 dependencies.pnpm 与上游自己的
# "pnpm@npm:<上游版本>": "patch:…" resolution 原样生效。
# ⚠️ 与 electron 的**关键差别**：pnpm 的补丁挂在**版本化的 resolution 键**上
# （"pnpm@npm:11.8.0"）。一旦把依赖换成别的版本，该键不再匹配任何依赖 → Yarn 不再打补丁，
# 而且**不报错**（node_modules 里就是未打补丁的原版）。Desktop 依赖这个补丁：
# provider 每次最终执行 pnpm 都加 --config.minimumReleaseAge=0，而 pnpm 11 对字符串 "0"
# 按 truthy 处理（会把年龄门禁误启用）。所以指定 -PnpmVersion 时必须同时重指 resolution 并
# 提供该版本的补丁（overlay\pnpm\pnpm@<版本>.patch），见 Set-PnpmOverride。
$script:PnpmOverride = $PnpmVersion
$script:PnpmVersionExplicit = $MyInvocation.BoundParameters.ContainsKey('PnpmVersion')
$script:PnpmOverrideActive = $script:PnpmVersionExplicit -and
  (-not [string]::IsNullOrWhiteSpace($PnpmVersion))
# 逐版本策展的 pnpm 补丁存放处（包根仓库 overlay\pnpm\pnpm@<版本>.patch）。
# 之所以不放进 overlay\patches\：那里是「对已跟踪文件打 git apply」的机制，而 pnpm 补丁是
# Yarn 的 patch: 协议产物，必须原样落到 <src>\patches\ 供 resolutions 引用。
$script:PnpmPatchSourceDir = Join-Path $script:Root 'overlay\pnpm'
# 排除 beta 通道：不再安装 dsh-plugin-desktop-beta 的依赖、不参与任何编译，
# 其 manifest 也不再被 AA 准备脚本读取/改写。设为 $false 可临时恢复 beta。
$script:DisableBeta = $true
# 排除实验性 Next 桌面（上游 dsh-desktop-next，独立 Electron 应用 “DSH NEXT”）：与
# beta 同等处理 —— 从根 package.json 的 workspaces 移除 → yarn install 不再安装它的
# 依赖（含它自带的 electron），它也不参与任何编译 / 类型检查 / 打包。本脚本只构建
# stable 通道（dsh-plugin-desktop），上游的 package:dir / dist:win 均不涉及 next。
# 设为 $false 可临时恢复（恢复后 yarn install 会重新安装它的依赖）。
$script:DisableNext = $true
# AA（Agents-Anywhere）源兜底固定：$script:AaSourceRef 只在 vendored provenance
# 自身不自洽时使用（见 Set-RuntimeVersionPinned / 主流程的 DSH_AA_SOURCE_REF 逻辑）。
# 上游 v2.0.14 起 provenance.json 已自带自洽的 commit ↔ 产物对应关系，并被
# aa:prepare-release 的 “artifact version identifies the selected commit” 校验强制；
# 再像旧版本那样无条件把它改写成历史提交 a022d928（0.1.5-rc.2 时代的产物）会让校验
# 直接失败。保留该值仅供自洽性检查失败时回落使用。
$script:AaSourceRef = 'a022d9286dd025bb4ae9f77b59cc2b7581f78b34'

# ---- src 覆盖层（用户自定义源码改动，-Overlay 时自动生效）----
# 覆盖层目录（包根 overlay\，不属于 dsh-desktop 仓库，pull 不受影响）：
#   overlay\src\<basename>         新建文件副本（pull 前备份，pull 后恢复）
#   overlay\patches\<basename>.patch  已跟踪文件的修改（pull 前 git diff 导出，pull 后 git apply）
# 往下面两个数组加仓库相对路径即可扩展；覆盖层构建时若检测到工作区里这些文件
# 有未保存的改动/新文件，会自动先导出再重置，因此“改了源码 → 跑 quick-build-overlay”
# 就能把改动固化进覆盖层。例外：$script:NoAutoExportPatchFiles 列出的文件只告警
# 不导出（其工作区改动里必然混有构建期注入，导出即毁掉手工维护的策展内容）。
$script:SrcOverlayDir = Join-Path $script:Root 'overlay'
$script:SrcOverlayFiles = @(
  'dsh-plugin-desktop/src/startup-config.ts'          # 新建文件（上游无此文件）
  'dsh-plugin-desktop/tests/startup-config.spec.ts'   # 新建测试文件（上游无此文件）
)
$script:SrcPatchFiles = @(
  'dsh-plugin-desktop/src/main.ts'                     # 已跟踪文件的修改
  # 重新启用 ASAR：上游 83cc4f821c/09070dd72e 把桌面打包整体切成 asar:false
  # （产物 resources\app\，文件数巨大）。本覆盖层补丁改回 asar:{smartUnpack:true}
  # 并恢复两个 ASAR 相关 fuse + 三平台 asarUnpack（图标与 bundled-connector 必须
  # 物理解出，spawn 无法进入 asar 归档）。补丁**只含 ASAR 相关改动**：electron
  # 版本与 afterAllArtifactBuild 钩子由 Set-ElectronOverride /
  # Set-AllArtifactVerifyDisabled 单独管理，不能写进补丁（否则会互相打架）。
  # 历史坑（已复发三次）：该文件的本地改动里必然混入构建期注入 —— Set-RuntimeVersionPinned
  # 改写 @deepseek-ai/dsh* 依赖版本串，Invoke-RequiredWinFixes 移除 afterAllArtifactBuild
  # 并补 npmRebuild。过去每次带 -Overlay 的构建都会把这份“工作区 git diff”（= 纯注入）
  # 当成用户改动写回本补丁，把 ASAR 内容整份覆盖掉：asar 退回 false → 产物
  # resources\app\ 变成 2.5 万个散文件 / 730 MB，而构建全程不报错，因此长期不可见。
  # 现列入 NoAutoExportPatchFiles：只应用、不自动导出；内容在包根仓库手工维护并提交。
  'dsh-plugin-desktop/package.json'                    # 重新启用 ASAR（smartUnpack + fuses + asarUnpack）
  'dsh-plugin-desktop/scripts/verify-packaged-runtime.ts'  # 产物运行时校验白名单（@dataiku/uv- 平台前缀）
  # 【已移除】dshmarket 策展补丁（原条目：'.yarn/patches/dshmarket-desktop.patch'）。
  # 它曾用于让 dshmarket 把自身的“可更新”条目算进 selfName（自更新）。上游现已收编
  # 该改动：.yarn/patches/dshmarket-desktop.patch 在 HEAD 上就含 12 个 hunk 与
  # `updates["dshmarket"]` 的 selfName 逻辑，本地策展版本反而更旧更少（仅 client.js），
  # 因此这处定制完全冗余。
  # 之所以必须删除：它的源补丁 overlay/patches/dshmarket-desktop.patch.patch 以“旧版
  # 上游补丁内容”为基准（before 侧带 `ignoredUpdateSet`、7 行上下文），而上游已改写该
  # 文件，git apply 必然失配 → 整个 [03] 覆盖层步骤抛错中止，连带后面的 ASAR / 白名单 /
  # main.ts / 图标补丁都拿不到应用机会（2026-10 实际故障）。
  # 一律使用上游版本；若日后上游再次去掉该逻辑，按上面的规则重新新增一条即可。
)

# 只应用、不自动导出的补丁目标（理由见上）。这里的文件仍由 Apply-SrcOverlay 应用，
# 但 Export-SrcOverlay 不会再覆盖其补丁文件，只打印告警。
$script:NoAutoExportPatchFiles = @(
  'dsh-plugin-desktop/package.json'
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
    "electron: $(if ($Overlay -and $script:ElectronOverrideActive) { $script:ElectronOverride } else { 'upstream' })"
    "harness : $(if ($script:HarnessOverrideActive) { $script:HarnessVersionOverride } else { 'upstream' })"
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
  $excludedWs = @(Get-ExcludedWorkspaceNames)   # @() 必需：单元素时函数返回值会被解包成标量
  if ($excludedWs.Count -gt 0) {
    Write-Info "排除工作区  : $($excludedWs -join '、')（不安装依赖 / 不参与编译）"
  }
  if ($Overlay) {
    $elDesc = if ($script:ElectronOverrideActive) { "$($script:ElectronOverride)（-ElectronVersion 指定）" }
              else { '上游声明版本（未指定 -ElectronVersion，不覆盖）' }
    Write-Info "Electron    : $elDesc"
    $pnpmDesc = if ($script:PnpmOverrideActive) { "$($script:PnpmOverride)（-PnpmVersion 指定）" }
                else { '上游声明版本（未指定 -PnpmVersion，不覆盖）' }
    Write-Info "pnpm        : $pnpmDesc"
  }
  $harnessDesc = if ($script:HarnessOverrideActive) { "$($script:ResolvedRuntimeVersion)（-HarnessVersion 指定，commit $($script:ResolvedHarnessCommit.Substring(0, [Math]::Min(12, $script:ResolvedHarnessCommit.Length)))）" }
                 else { "$($script:ResolvedRuntimeVersion)（上游 upstream.json 声明，未指定 -HarnessVersion，不固定）" }
  Write-Info "dsh 运行时  : $harnessDesc"
  Write-Info "仓库根      : $script:Src"
  Write-Info "操作系统    : $([System.Environment]::OSVersion.VersionString)"
  Write-Info "架构        : $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
  Write-Info "Node        : $node"
  Write-Info "Corepack    : $corepackVer"
  Write-Info "Yarn pin    : $($pkg.packageManager)"
  Write-Info "Git         : $git"
  Write-Info "上游仓库    : $($upstream.repository)"
  if ($channelInfo) {
    # 这三个值来自**工作区** upstream.json，可能已被上一次构建的运行时固定改写（不带
    # -Overlay 时不会重置），只作参考；本次构建真正使用的版本见下面「本次目标」。
    Write-Info "上游 commit : $($channelInfo.commit)（$script:Channel 通道，工作区 upstream.json）"
    Write-Info "上游版本    : $($channelInfo.sourceVersion)"
    Write-Info "运行时包    : $($channelInfo.runtimePackageVersion)"
  }
  $targetShort = if ($script:ResolvedHarnessCommit) { $script:ResolvedHarnessCommit.Substring(0, [Math]::Min(12, $script:ResolvedHarnessCommit.Length)) } else { '(未解析)' }
  Write-Info "本次目标    : dsh $($script:ResolvedRuntimeVersion) @ $targetShort（$(if ($script:HarnessOverrideActive) { '-HarnessVersion 指定' } else { '上游声明' })）"
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
    throw "dsh-desktop 不是 Git 仓库（缺少 .git）。请先运行一次不带 -SkipPull 的构建以克隆 / 更新源码。"
  }

  $upstream = Get-JsonObject (Join-Path $script:Src 'upstream.json')
  $channelInfo = $upstream.channels.$script:Channel
  if (-not $channelInfo -or -not $channelInfo.commit) {
    throw "upstream.json 中找不到通道 $script:Channel 的 pinned commit。"
  }
  # 目标 commit 取 Resolve-HarnessVersion 的解析结果：未指定 -HarnessVersion 时 = 上游
  # upstream.json 声明的 commit；指定时 = 该覆盖版本对应的 commit。
  # **不直接读工作区 upstream.json 的 commit**：那份可能残留上一次构建的固定值（不带
  # -Overlay 构建时不会执行 Reset-OverlayTrackedFiles），会把子模块对齐到错误的 commit。
  $targetCommit = if ($script:ResolvedHarnessCommit) { $script:ResolvedHarnessCommit } else { $channelInfo.commit }
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
  if ($head -ne $targetCommit) {
    Write-WarnLine "检出 commit 为 $head，期望 $targetCommit（通道 $script:Channel），正在强制对齐 pinned commit。"
    Invoke-External git @('-C', $harness, 'fetch', '--depth', '1', 'origin', $targetCommit)
    Invoke-External git @('-C', $harness, 'checkout', '--detach', $targetCommit)
  }

  $head = (git -C $harness rev-parse HEAD).Trim()
  if ($head -ne $targetCommit) {
    throw "上游子模块 HEAD=$head，与通道 $script:Channel 的目标 commit $targetCommit 不一致。"
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
  #   注：$script:NoAutoExportPatchFiles 里的文件只告警不导出（构建期注入会污染 diff）。
  # 仅 -Overlay 时执行（无覆盖层构建不应收走用户源码改动）；随后 Reset-OverlayTrackedFiles
  # 会 checkout 掉跟踪文件的改动、移除未跟踪文件，pull 后才由 Apply-SrcOverlay 恢复。
  if (-not $script:Overlay) { return }
  if (-not $script:SrcOverlayDir) { return }
  New-Item -ItemType Directory -Force -Path (Join-Path $script:SrcOverlayDir 'patches') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $script:SrcOverlayDir 'src') | Out-Null
  foreach ($rel in $script:SrcPatchFiles) {
    if ($script:NoAutoExportPatchFiles -contains $rel) {
      # 只告警、不落盘：该文件的本地改动多半来自构建期注入，导出会覆盖策展补丁。
      $prevNativeGuard = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
      try { $dirty = @(& git -C $script:Src status --porcelain -- $rel) } finally { $PSNativeCommandUseErrorActionPreference = $prevNativeGuard }
      if ($dirty.Count -gt 0) {
        Write-WarnLine "覆盖层：$rel 有本地改动，但该补丁为手工维护（构建期会注入依赖版本/钩子改动）→ 已跳过自动导出。如需固化，请手工更新 overlay\patches\$([IO.Path]::GetFileName($rel)).patch 并提交到包根仓库。"
      }
      continue
    }
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
    # 说明：除覆盖层文件外，还包括“构建过程会改写”的受跟踪文件（AA 依赖对齐）。
    # 它们每次构建都会被重新生成，pull 前丢弃
    # 本地改动不会丢东西；不丢弃则上游一改这些文件 pull 就会失败。
    # 注意：不要加入 vendor/agents-anywhere/provenance.json —— 其 commit 必须与
    # AA main 解析结果一致，prepare 脚本才会走 “Reusing verified AA artifact”
    # 快路径；重置为上游旧值会触发全量重建，撞上 “Existing artifact differs” 守卫。
    $exact = @('.yarnrc.yml', 'yarn.lock', 'package.json', 'upstream.json') + @(
      'package.json',
      'dsh-plugin-desktop/package.json',
      'dsh-plugin-desktop-beta/package.json',
      # market：构建期已不再改写它（见 Set-RuntimeVersionPinned 第 2 步）。保留此条目
      # 仅用于丢弃历史遗留的本地改动，是幂等安全网，不产生任何写入。
      'dsh-community-market/package.json',
      'dsh-plugin-desktop/scripts/package-dir.mjs',
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
  # **未指定 -ElectronVersion 时完全不改写**（使用上游声明的版本，构建上游原样）；
  # 官方声明已与覆盖目标一致时同样跳过。仅在显式指定了不同版本时才实际覆盖。
  $pkgPath = Get-ChannelWsPath 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) {
    throw "通道 $script:Channel 的工作区不存在：$pkgPath。请先同步到最新 master（双通道目录结构）。"
  }
  $text = Get-Content -LiteralPath $pkgPath -Raw -Encoding utf8
  if ($text -notmatch '("electron"\s*:\s*")([^"]+)(")') {
    Write-WarnLine "覆盖层：$pkgPath 中未找到 electron 声明，跳过。"
    return $false
  }
  $current = $Matches[2]
  if (-not $script:ElectronOverrideActive) {
    Write-Info "electron 使用上游声明版本（$current）：未指定 -ElectronVersion，跳过版本覆盖。"
    return $false
  }
  if ($current -eq $script:ElectronOverride) {
    Write-Info "electron 官方声明已与覆盖目标一致（$current），跳过版本覆盖。"
    return $false
  }
  # 注意：这里**不传**[regex]::Replace 的第 4 个参数。看起来像 count 的那个位置实际是
  # RegexOptions（传 1 = IgnoreCase），并非“只替换第一处” —— 于是 peerDependencies 与
  # devDependencies 两处都会被改写（正是需要的结果：devDependencies 才决定实际安装的版本）。
  # 显式写成“替换全部”，避免后人误以为只改了一处。
  $fixed = [regex]::Replace($text, '("electron"\s*:\s*")([^"]+)(")', "`${1}$($script:ElectronOverride)`${3}")
  Set-Content -LiteralPath $pkgPath -Value $fixed -Encoding utf8 -NoNewline
  Write-WarnLine "覆盖层：$script:ChannelWsName electron $current → $($script:ElectronOverride)"
  return $true
}

function Set-PnpmOverride {
  # <channel>/package.json 的 dependencies.pnpm → $script:PnpmOverride，并把根 resolutions 的
  # pnpm 补丁条目补到同一版本。
  # **未指定 -PnpmVersion 时完全不改写**（上游声明 + 上游补丁 resolution 原样生效）；
  # 上游声明已与覆盖目标一致时同样跳过。
  # 指定了不同版本时，下面三件事必须同时成立，否则 age-gate 修复会**静默**消失：
  #   1) 依赖版本 = 目标版本                                  ← 第 1 段
  #   2) <src>\patches\pnpm@<目标>.patch 存在（从 overlay\pnpm\ 拷入）  ← 第 2 段
  #   3) 根 resolutions 里有 "pnpm@npm:<目标>": "patch:…" 条目            ← 第 3 段
  # 为什么 2) 3) 不能省：resolution 键是**版本化**的（"pnpm@npm:11.8.0"）。把依赖换成别的
  # 版本后，原键不再匹配任何依赖 → Yarn 不再打补丁，**而且不报错** —— node_modules 里就是
  # 未打补丁的原版，Desktop 的 --config.minimumReleaseAge=0（pnpm 11 对字符串 "0" 按 truthy
  # 处理）缺陷随之复现。这属于「构建成功但定制没生效」，必须避免。
  $pkgPath = Get-ChannelWsPath 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) {
    throw "通道 $script:Channel 的工作区不存在：$pkgPath。请先同步到最新 master（双通道目录结构）。"
  }
  $text = Get-Content -LiteralPath $pkgPath -Raw -Encoding utf8
  # 只匹配 dependencies 里的 "pnpm": "<版本>"：模式要求键恰为 "pnpm"，
  # exports 里的 "./pnpm"（引号前是斜杠）不会命中。
  $pattern = '("pnpm"\s*:\s*")([^"]+)(")'
  if ($text -notmatch $pattern) {
    Write-WarnLine "覆盖层：$pkgPath 中未找到 pnpm 依赖声明，跳过。"
    return $false
  }
  $current = $Matches[2]
  if (-not $script:PnpmOverrideActive) {
    Write-Info "pnpm 使用上游声明版本（$current）：未指定 -PnpmVersion，跳过版本覆盖。"
    return $false
  }
  if ($current -eq $script:PnpmOverride) {
    Write-Info "pnpm 上游声明已与覆盖目标一致（$current），跳过版本覆盖。"
    return $false
  }
  $fixed = [regex]::Replace($text, $pattern, "`${1}$($script:PnpmOverride)`${3}")
  Set-Content -LiteralPath $pkgPath -Value $fixed -Encoding utf8 -NoNewline
  Write-WarnLine "覆盖层：$script:ChannelWsName pnpm $current → $($script:PnpmOverride)"

  # --- 第 2 段：把该版本的策展补丁落到 <src>\patches\ ---
  $patchName = "pnpm@$($script:PnpmOverride).patch"
  $srcPatch = Join-Path $script:PnpmPatchSourceDir $patchName
  if (-not (Test-Path -LiteralPath $srcPatch)) {
    Write-WarnLine "覆盖层：缺少 $srcPatch —— 无法为 pnpm $($script:PnpmOverride) 重指 age-gate 补丁。"
    Write-WarnLine "        ⇒ 该版本的 pnpm 将以**未打补丁的原版**打包（最小发布年龄缺陷可能复现）。"
    Write-WarnLine "        ⇒ 补丁生成方法见 BUILD_GUIDE.md「pnpm 版本覆盖」：对该版本的 dist/pnpm.mjs 重新 diff。"
    return $true
  }
  $dstPatch = Join-Path $script:Src "patches\$patchName"
  Copy-Item -LiteralPath $srcPatch -Destination $dstPatch -Force
  Write-Info "覆盖层：pnpm 补丁已就位 patches\$patchName"

  # --- 第 3 段：补 resolutions 条目（已存在则不动；保留旧版本的条目） ---
  $rootPkg = Join-Path $script:Src 'package.json'
  $rootText = Get-Content -LiteralPath $rootPkg -Raw -Encoding utf8
  if ($rootText -notmatch [regex]::Escape('"pnpm@npm:' + $script:PnpmOverride + '":')) {
    $anchor = [regex]::Match($rootText, '(?<nl>\r?\n)(?<ind>[ \t]*)("pnpm@npm:[^"]+":\s*"patch:pnpm@npm%3A[^"]+#\./patches/pnpm@[^"]+\.patch",)')
    if (-not $anchor.Success) {
      throw "未在 $rootPkg 的 resolutions 中找到 pnpm 补丁条目，无法为 $($script:PnpmOverride) 补上 resolution。请检查上游是否改写了该条目。"
    }
    $insert = $anchor.Groups['nl'].Value + $anchor.Groups['ind'].Value +
      '"pnpm@npm:' + $script:PnpmOverride + '": "patch:pnpm@npm%3A' + $script:PnpmOverride +
      '#./patches/' + $patchName + '",'
    $rootText = $rootText.Insert($anchor.Index + $anchor.Length, $insert)
    Set-Content -LiteralPath $rootPkg -Value $rootText -Encoding utf8 -NoNewline
    Write-WarnLine "覆盖层：根 resolutions 已补上 pnpm@npm:$($script:PnpmOverride) 的补丁条目（旧的保留）"
  } else {
    Write-Info "根 resolutions 已存在 pnpm@npm:$($script:PnpmOverride) 的补丁条目，保持不动。"
  }
  return $true
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

# 工作区排除（beta 通道 + 实验性 Next 桌面，见 $script:DisableBeta / $script:DisableNext）：
#   1) 根 package.json 的 workspaces 移除这些工作区 → yarn install 不再安装它们的依赖，
#      它们完全不参与编译 / 类型检查 / 打包（Next 与 beta 走的是同一条路径）；
#   2) beta 专项（Disable-BetaAaPipeline）：AA 准备脚本 / AA 策略文件里的 beta 引用改写。
#   根 package.json 在 pull 前重置清单里，所以每次 pull 后都要重新应用 —— 均为幂等操作。
function Get-ExcludedWorkspaceNames {
  # 需要从根 workspaces 排除的工作区名（beta 与 Next 各由一个开关控制）
  # 调用方务必用 @(...) 包裹：PowerShell 会把单元素返回值解包成标量，而标量在
  # Set-StrictMode -Version Latest 下取 .Count 会抛 PropertyNotFoundException。
  $names = @()
  if ($script:DisableBeta) { $names += 'dsh-plugin-desktop-beta' }
  if ($script:DisableNext) { $names += 'dsh-desktop-next' }
  return $names
}

# 从根 package.json 的 workspaces 数组移除一个工作区。只在数组内部操作（不会误删
# scripts 里同名的 "yarn workspace <name> ..." 文案）；幂等；返回 $true 表示确实改写了文件。
function Remove-RootWorkspace {
  param([Parameter(Mandatory)][string]$Name)
  $pkgPath = Join-Path $script:Src 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) { return $false }
  $text = [System.IO.File]::ReadAllText($pkgPath)
  $quoted = '"' + $Name + '"'
  $m = [regex]::Match($text, '(?s)("workspaces"\s*:\s*\[)(.*?)(\])')
  if (-not $m.Success) {
    Write-WarnLine "$Name 排除：根 package.json 未找到 workspaces 数组（格式变化？），跳过。"
    return $false
  }
  $body = $m.Groups[2].Value
  if ($body.IndexOf($quoted, [StringComparison]::Ordinal) -lt 0) {
    Write-Info "$Name 排除：根 workspaces 已不含该工作区"
    return $false
  }
  # 三档兜底：整行带尾逗号 → 逗号单独成行（条目是数组最后一个）→ 单行数组 / 行尾无逗号
  $newBody = [regex]::Replace($body, "(?m)^[ \t]*$quoted,[ \t]*\r?\n", '')
  if ($newBody -eq $body) {
    $newBody = [regex]::Replace($body, "(?m)^[ \t]*,[ \t]*\r?\n[ \t]*$quoted[ \t]*\r?\n", '')
  }
  if ($newBody -eq $body) {
    $newBody = [regex]::Replace($body, "[ \t]*$quoted[ \t]*,?", '')
  }
  if ($newBody -eq $body) {
    Write-WarnLine "$Name 排除：未能从根 workspaces 移除（格式变化？），跳过。"
    return $false
  }
  $fixed = $text.Substring(0, $m.Groups[2].Index) + $newBody + $text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
  try {
    $null = $fixed | ConvertFrom-Json
  } catch {
    # 移除的是数组最后一个条目时，前一行会残留尾逗号 → 修掉再校验一次。
    $repaired = [regex]::Replace($fixed, ',[ \t]*(\r?\n[ \t]*\])', '$1')
    try {
      $null = $repaired | ConvertFrom-Json
      $fixed = $repaired
    } catch {
      Write-WarnLine "$Name 排除：移除后 JSON 解析失败，已放弃修改（$($_.Exception.Message)）"
      return $false
    }
  }
  [System.IO.File]::WriteAllText($pkgPath, $fixed)
  return $true
}

function Disable-ExcludedWorkspaces {
  $excluded = @(Get-ExcludedWorkspaceNames)   # @() 必需：单元素时函数返回值会被解包成标量
  if ($excluded.Count -eq 0) { return }
  $removed = @()
  foreach ($name in $excluded) {
    if (Remove-RootWorkspace -Name $name) { $removed += $name }
  }
  if ($removed.Count -gt 0) {
    Write-WarnLine "工作区排除：根 workspaces 已移除 $($removed -join '、')（不再安装依赖 / 不参与编译）"
  }
}

# beta 专项排除：AA 准备脚本 + AA 策略文件里的 beta 引用改写。
#   上游 prepare-agents-anywhere-release.mjs 的桌面 manifest 列表、以及
#   agents-anywhere-release-policy.mjs 的 workspace 声明与安装校验里都还会读 beta 的
#   package.json；beta 已从 workspaces 移除（不再安装其依赖）后必须同步改写，否则
#   assertPreparedAaRelease 遍历 beta 的 node_modules 会报 ENOENT。
function Disable-BetaAaPipeline {
  if (-not $script:DisableBeta) { return }

  # 本次构建实际排除的工作区（beta 由开关控制；Next 恒随 DisableNext）
  $excludedNames = @('dsh-plugin-desktop-beta')
  if ($script:DisableNext) { $excludedNames += 'dsh-desktop-next' }

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

  # 3) AA 策略文件（agents-anywhere-release-policy.mjs）：beta 禁用后不再安装其依赖，
  #    但 policy 的 assertPreparedAaRelease 仍会遍历 beta 的 node_modules
  #    （ENOENT: …dsh-plugin-desktop-beta\node_modules\@agents-anywhere\…）。给 assert
  #    引入 AA_WORKSPACES_CHECKED（仅 stable）：runtimePeerRanges 仍读 desktop+beta
  #    （保证 provenance.runtimePeers 与已验证产物 peer 的联合范围一致），但安装校验
  #    只检查 stable。每次构建 pull 重置后重新应用，幂等。
  #
  #    注意（2026-09 修复）：旧实现用硬编码锚点
  #    "export const AA_WORKSPACES = ['dsh-plugin-desktop', 'dsh-plugin-desktop-beta']"
  #    来插入声明，但上游后来把 next 也加进了该数组（变成三个元素），锚点失配 →
  #    声明没插进去，而 assert 循环却已经被替换成 AA_WORKSPACES_CHECKED →
  #    运行期直接崩 “AA_WORKSPACES_CHECKED is not defined”。
  #    现在改为：用正则解析实际的工作区数组（不管有几个元素）来生成声明；并且只有在
  #    声明确实存在时才改写 assert 循环，避免再次出现“半打补丁”的破坏状态。
  $policyPath = Join-Path $script:Src 'scripts\agents-anywhere-release-policy.mjs'
  if (Test-Path -LiteralPath $policyPath) {
    $policyText = [System.IO.File]::ReadAllText($policyPath)
    if ($policyText.Contains('AA_WORKSPACES_CHECKED')) {
      Write-Info 'beta 排除：AA 策略文件已含 AA_WORKSPACES_CHECKED'
    } else {
      # 解析实际的 AA_WORKSPACES 声明（容忍任意元素个数与空白）
      $wsMatch = [regex]::Match($policyText, "export const AA_WORKSPACES\s*=\s*\[(?<items>[^\]]*)\]")
      $declared = @()
      if ($wsMatch.Success) {
        $declared = @([regex]::Matches($wsMatch.Groups['items'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
      }
      # 只保留实际参与构建的工作区（排除 beta / Next）
      $keep = @($declared | Where-Object { $excludedNames -notcontains $_ })
      if (-not $wsMatch.Success -or $keep.Count -eq 0) {
        Write-WarnLine 'beta 排除：AA 策略文件 workspace 声明格式已变（无法解析），跳过（不改写 assert 循环，避免半打补丁）。'
      } else {
        $keepList = ($keep | ForEach-Object { "'$_'" }) -join ', '
        $checkDecl = "export const AA_WORKSPACES_CHECKED = [$keepList]"
        $insertAt = $wsMatch.Index + $wsMatch.Length
        $policyText = $policyText.Insert($insertAt, "`n$checkDecl")
        Write-WarnLine "beta 排除：AA 策略文件已加入 AA_WORKSPACES_CHECKED = [$keepList]（仅校验参与构建的工作区）"
        $oldLoop = 'for (const workspace of AA_WORKSPACES) {'
        if ($policyText.Contains($oldLoop)) {
          $policyText = $policyText.Replace($oldLoop, 'for (const workspace of AA_WORKSPACES_CHECKED) {')
          Write-WarnLine 'beta 排除：AA 策略文件 assert 校验已切换到实际工作区列表'
        } else {
          Write-WarnLine 'beta 排除：AA 策略文件 assert 循环格式已变（未改写，声明仍可用）'
        }
        [System.IO.File]::WriteAllText($policyPath, $policyText)
      }
    }
  }
}

# beta / Next 专项排除：上游 dshmarket 校验脚本（scripts/prepare-dsh-market.mjs）。
#   上游 package:dir / build / dev 等入口都会先跑 `yarn market:prepare`，而该脚本把
#   MARKET_WORKSPACES 硬编码为三个工作区（desktop + beta + next），并在 runInstall 之后
#   逐个断言 “installedVersion(...) === version”。本脚本用 $DisableBeta/$DisableNext
#   把 beta 与 next 从根 workspaces 移除后，它们根本不会被安装依赖，于是断言必然抛
#   “dsh-plugin-desktop-beta did not install dshmarket <ver>” → package:dir 直接失败。
#   这里把 MARKET_WORKSPACES 收缩为“实际参与构建的工作区”，与根 workspaces 保持一致。
#   每次构建 pull 重置后重新应用，幂等；格式变化时跳过并告警（不静默破坏）。
function Disable-MarketWorkspaceCheck {
  $marketPath = Join-Path $script:Src 'scripts\prepare-dsh-market.mjs'
  if (-not (Test-Path -LiteralPath $marketPath)) { return }
  $excluded = @()
  if ($script:DisableBeta) { $excluded += 'dsh-plugin-desktop-beta' }
  if ($script:DisableNext) { $excluded += 'dsh-desktop-next' }
  if ($excluded.Count -eq 0) { return }

  $text = [System.IO.File]::ReadAllText($marketPath)
  if (-not $text.Contains('MARKET_WORKSPACES')) {
    Write-WarnLine 'beta/Next 排除：dshmarket 脚本已无 MARKET_WORKSPACES（上游重构？），跳过。'
    return
  }
  if ($text.Contains('MARKET_WORKSPACES_EXCLUDED')) {
    Write-Info 'beta/Next 排除：dshmarket 脚本已应用工作区收缩'
    return
  }

  $anchor = "export const MARKET_WORKSPACES = ['dsh-plugin-desktop', 'dsh-plugin-desktop-beta', 'dsh-desktop-next']"
  if (-not $text.Contains($anchor)) {
    Write-WarnLine 'beta/Next 排除：dshmarket 脚本 MARKET_WORKSPACES 声明格式已变（无法打补丁），跳过。'
    return
  }
  $decl = [string]::Join("', '", $excluded)
  $replacement = @(
    "export const MARKET_WORKSPACES_EXCLUDED = ['$decl']",
    'export const MARKET_WORKSPACES = [' +
      "'dsh-plugin-desktop', 'dsh-plugin-desktop-beta', 'dsh-desktop-next'" +
      '].filter(name => !MARKET_WORKSPACES_EXCLUDED.includes(name))'
  ) -join "`n"
  $text = $text.Replace($anchor, $replacement)
  [System.IO.File]::WriteAllText($marketPath, $text)
  Write-WarnLine "beta/Next 排除：dshmarket 校验工作区已收缩（排除 $($excluded -join '、')）"
}

# dshmarket 兼容补丁停用（本地决定）：
#   上游 .yarn/patches/dshmarket-desktop.patch 给 checkUpdates 增加了一个“host 提供版本”
#   形参（hostProvidedNpmVersions），使市场 UI 把 dshmarket 自身也算作可更新项。该补丁
#   必须**同时**匹配仓库 pin 的版本（步骤[05] 按 pin 装依赖）与 npm latest（package:dir 里的
#   market:prepare 跟随升级后重装）。但 1.66.8 已把第 6 个形参让给 catalogNpmByRepo，改动行
#   的前后文本在两版中不同，单个 hunk 无法同时匹配 → yarn 报 “Cannot apply hunk #2” 并
#   中断整个 package:dir（2026-10 实际故障，此前已因同类上下文漂移复发一次）。
#   本函数让补丁彻底不参与安装：
#     1) scripts/prepare-dsh-market.mjs 的 marketResolution 改为输出纯版本号；
#     2) 根 package.json 里 pin 的 patch: 解析一并改为纯版本号。
#   上游的 .yarn/patches/dshmarket-desktop.patch 文件保留不动（仅失效，不再被引用）。
#   代价：市场 UI 不再提供 dshmarket 自身的更新入口；安装/卸载其它插件不受影响。
#   恢复：删掉 Invoke-RequiredWinFixes 里的调用，并把 marketResolution 还原为
#     `patch:dshmarket@npm%3A${version}#./.yarn/patches/dshmarket-desktop.patch`
#   同时把该补丁更新到当时的 latest（且 pin 与 latest 两版都能应用）。
#   幂等；格式变化时跳过并告警（不静默破坏）。
function Set-MarketPatchDisabled {
  $marketPath = Join-Path $script:Src 'scripts\prepare-dsh-market.mjs'
  if (Test-Path -LiteralPath $marketPath) {
    $text = [System.IO.File]::ReadAllText($marketPath)
    if ($text.Contains('MARKET_PATCH_DISABLED')) {
      Write-Info 'dshmarket 兼容补丁：marketResolution 已停用'
    }
    else {
      $anchor = 'export const marketResolution = version => `patch:dshmarket@npm%3A${version}#./.yarn/patches/dshmarket-desktop.patch`'
      if (-not $text.Contains($anchor)) {
        Write-WarnLine 'dshmarket 兼容补丁：marketResolution 声明格式已变（无法停用），跳过。'
      }
      else {
        $replacement = @(
          '// MARKET_PATCH_DISABLED: DSH Desktop 不再维护 dshmarket 兼容补丁，改为纯 npm 规格。',
          '// 该补丁必须同时匹配 pin 的版本与 npm latest，而 1.66.8 起的形参变化使其无法兼顾，',
          '// 详见 build.ps1 的 Set-MarketPatchDisabled。'
          'export const marketResolution = version => version'
        ) -join "`n"
        $text = $text.Replace($anchor, $replacement)
        $oldNote = @(
          '    // Follow latest while retaining Desktop self-update and rollback fixes. Yarn rejects',
          '    // incompatible patch contexts; never silently ship a new release without these safeguards.'
        ) -join "`n"
        $newNote = @(
          '    // Follow latest. The Desktop self-update patch is deliberately not applied here:',
          '    // no single patch can match both the pinned release and npm latest (see build.ps1).'
        ) -join "`n"
        if ($text.Contains($oldNote)) { $text = $text.Replace($oldNote, $newNote) }
        [System.IO.File]::WriteAllText($marketPath, $text)
        Write-WarnLine 'dshmarket 兼容补丁：已停用（marketResolution → 纯版本号）'
      }
    }
  }

  $rootManifest = Join-Path $script:Src 'package.json'
  if (Test-Path -LiteralPath $rootManifest) {
    $manifest = [System.IO.File]::ReadAllText($rootManifest)
    $match = [regex]::Match($manifest, '"dshmarket@npm:([0-9][^"]*)":\s*"patch:dshmarket@npm%3A[^"]*"')
    if ($match.Success) {
      $version = $match.Groups[1].Value
      $plain = '"dshmarket@npm:' + $version + '": "' + $version + '"'
      $manifest = $manifest.Remove($match.Index, $match.Length).Insert($match.Index, $plain)
      [System.IO.File]::WriteAllText($rootManifest, $manifest)
      Write-WarnLine "dshmarket 兼容补丁：根 package.json 解析已改为纯版本（$version）"
    }
    else {
      Write-Info 'dshmarket 兼容补丁：根 package.json 已无 patch: 形式解析'
    }
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
# 读取上游仓库内某个 JSON 文件，**优先 git HEAD**：工作区那份可能已被上一次构建改写
# （Set-RuntimeVersionPinned 会写 upstream.json 与当前通道工作区 package.json），
# 不能代表“上游声明”。git 读取失败（离线 / 非 git 工作区）时才回落到工作区文件。
function Get-HeadJsonObject {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $rel = $RelativePath -replace '\\', '/'
  try {
    $raw = @(git -C $script:Src show "HEAD:$rel" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $raw.Count -gt 0) {
      try { return (($raw -join [Environment]::NewLine) | ConvertFrom-Json) } catch { }
    }
  } catch { }
  $p = Join-Path $script:Src ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  return Get-JsonObject $p
}

# 上游 upstream.json 里指定通道声明的运行时信息（$null = 读不到）。
function Get-UpstreamStableChannel {
  param([string]$ChannelName = $script:Channel)
  $json = Get-HeadJsonObject 'upstream.json'
  if (-not $json -or -not ($json.PSObject.Properties.Name -contains 'channels')) { return $null }
  $ch = $json.channels
  if (-not $ch -or -not ($ch.PSObject.Properties.Name -contains $ChannelName)) { return $null }
  return $ch.PSObject.Properties[$ChannelName].Value
}

# 把 deepseek-harness 版本解析为 commit：查仓库标签 dsh-v<版本>。
#   1) 本地子模块（$src\deepseek-harness）—— 离线、无网络开销，优先；
#   2) 远端 ls-remote —— 子模块 clone 可能没取全标签时的兜底。
# 解析不出来（该版本无标签 / 网络不可用）返回 $null，由调用方决定报错还是告警。
function Resolve-HarnessCommitFromTag {
  param([Parameter(Mandatory = $true)][string]$Version)
  $tag = "dsh-v$Version"
  # 探测期间关掉「原生命令非零退出即终止」：脚本顶部把
  # $PSNativeCommandUseErrorActionPreference 设为 $true，而「标签不存在」「远端不可达」
  # 都是**本函数预期内的失败** —— 不关掉的话 git 的非零退出会直接抛出（配合
  # $ErrorActionPreference='Stop' 成为终止性错误），下面的 $LASTEXITCODE 降级逻辑根本没机会跑。
  $prevNative = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  # 远端探测不允许交互（凭据提示会让构建挂住）：只查公开上游仓库，失败即降级。
  $prevPrompt = $env:GIT_TERMINAL_PROMPT
  $env:GIT_TERMINAL_PROMPT = '0'
  try {
    $harnessPath = Join-Path $script:Src 'deepseek-harness'
    if (Test-Path -LiteralPath (Join-Path $harnessPath '.git')) {
      # ^{commit} 让注释标签也解到 commit；--quiet 让标签缺失时不打噪音到 stderr。
      $local = @(& git -C $harnessPath rev-parse --verify --quiet "refs/tags/$tag^{commit}" 2>$null)
      if ($LASTEXITCODE -eq 0 -and $local.Count -gt 0) {
        $shaLocal = ([string]$local[0]).Trim()
        if ($shaLocal) { return $shaLocal }
      }
    }
    # 注释标签会同时列出 <标签> 与 <标签>^{} 两行，^{} 指向 commit，优先取它。
    $remote = @(& git ls-remote --tags $script:HarnessRepository "refs/tags/$tag" "refs/tags/$tag^{}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $remote.Count -eq 0) { return $null }
    $peeled = @($remote | Where-Object { $_ -match '\^\{\}\s*$' })
    $line = if ($peeled.Count -gt 0) { [string]$peeled[0] } else { [string]$remote[0] }
    $sha = ($line -split '\s+')[0]
    if ($sha -match '^[0-9a-fA-F]{7,40}$') { return $sha }
    return $null
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prevNative
    $env:GIT_TERMINAL_PROMPT = $prevPrompt
  }
}

# 决定本次构建使用的 deepseek-harness 运行时版本（必须在源码同步之后、任何依赖安装 /
# 覆盖层应用之前调用）：
#   -HarnessVersion 指定 → 固定到该版本。commit 取值优先级：
#                           1) -HarnessCommit 显式给出 → 以它为准（并与标签核对，不一致告警）
#                           2) 目标版本 == 上游声明版本 → 上游 upstream.json 里的 commit
#                           3) 其余 → 标签 dsh-v<版本> 指向的 commit（Resolve-HarnessCommitFromTag）
#                           —— 所以换版本通常**不需要**手抄 sha。
#   未指定               → 使用上游 upstream.json stable 通道声明的版本（不固定 / 不改写）
function Resolve-HarnessVersion {
  $stable = Get-UpstreamStableChannel
  if (-not $stable) {
    throw "无法读取上游 upstream.json 的 $($script:Channel) 通道（$script:Src）。请确认源码已同步（首次克隆不要用 -SkipPull），或改用 -HarnessVersion / -HarnessCommit 显式指定。"
  }
  $props = $stable.PSObject.Properties
  $upVersion = if ($props.Name -contains 'sourceVersion') { [string]$props['sourceVersion'].Value } else { '' }
  $upCommit = if ($props.Name -contains 'commit') { [string]$props['commit'].Value } else { '' }
  if (-not $upVersion) {
    throw "上游 upstream.json 的 $($script:Channel).sourceVersion 为空：$(Join-Path $script:Src 'upstream.json')"
  }
  $shortUp = if ($upCommit) { $upCommit.Substring(0, [Math]::Min(12, $upCommit.Length)) } else { '(无)' }

  if (-not $script:HarnessOverrideActive) {
    $script:ResolvedRuntimeVersion = $upVersion
    $script:ResolvedHarnessCommit = $upCommit
    Write-Info "dsh 运行时：使用上游声明 $upVersion（commit $shortUp）—— 未指定 -HarnessVersion，不固定。"
  } else {
    $v = $script:HarnessVersionOverride
    $c = $script:HarnessCommitOverride
    $explicitCommit = -not [string]::IsNullOrWhiteSpace($script:HarnessCommitOverride)
    if ($v -eq $upVersion) {
      if (-not $c) { $c = $upCommit }
      Write-Info "dsh 运行时：-HarnessVersion $v 与上游声明一致，commit 取上游 $shortUp。"
    } elseif (-not $c) {
      # 未给 commit：上游 upstream.json 只声明自己那一版，换版本时「版本 → commit」只有标签能给。
      $c = Resolve-HarnessCommitFromTag -Version $v
      if (-not $c) {
        throw "-HarnessVersion $v 与上游声明的 $upVersion 不同，且未能从标签 dsh-v$v 解析 commit：本地 deepseek-harness 无此标签，远端 $($script:HarnessRepository) 也未查到（网络不通 / 用了 -NoProxy？）。请核对版本号拼写，或用 -HarnessCommit <sha> 显式指定。"
      }
      Write-Ok "dsh 运行时：-HarnessVersion $v（上游声明 $upVersion）→ commit 取自标签 dsh-v$v：$($c.Substring(0, [Math]::Min(12, $c.Length)))"
    } else {
      Write-WarnLine "dsh 运行时：按 -HarnessVersion 固定到 $v（上游声明为 $upVersion）。"
    }
    if (-not $c) {
      # 只剩「版本与上游相同、但上游 upstream.json 没写 commit」这一种：同样用标签兜底。
      $c = Resolve-HarnessCommitFromTag -Version $v
      if (-not $c) {
        throw "-HarnessVersion $v 缺少对应的 deepseek-harness commit：上游 upstream.json 未声明，标签 dsh-v$v 也未解析到。请用 -HarnessCommit 显式指定。"
      }
      Write-Ok "dsh 运行时：上游未声明 commit → 取自标签 dsh-v$v：$($c.Substring(0, [Math]::Min(12, $c.Length)))"
    }
    # 显式给的 commit 与标签核对，**不一致只告警**：上游会把同一 sourceVersion 的 commit
    # 前移（实测 4878cdabd8 → 639ed01539），标签与 upstream.json 都不必然是唯一真相，
    # 故以显式参数为准，但把差异暴露出来 —— 手抄 sha 抄错就是这个信号。
    if ($explicitCommit) {
      $tagSha = Resolve-HarnessCommitFromTag -Version $v
      if ($tagSha -and $tagSha -ne $c) {
        Write-WarnLine "dsh 运行时：-HarnessCommit $($c.Substring(0, [Math]::Min(12, $c.Length))) 与标签 dsh-v$v（$($tagSha.Substring(0, [Math]::Min(12, $tagSha.Length)))）不一致 —— 按参数值为准。"
      }
    }
    $script:ResolvedRuntimeVersion = $v
    $script:ResolvedHarnessCommit = $c
  }

  # 该版本的 vendor 运行时产物必须齐备（否则后面固定出来的是半成品）。缺失时：
  # 显式指定的版本 → 直接报错；随上游的版本 → 交由 Set-RuntimeVersionPinned 告警后继续。
  if ($script:HarnessOverrideActive) {
    $mp = Join-Path $script:Src ("vendor/dsh-runtime/$($script:ResolvedRuntimeVersion)" -replace '/', [IO.Path]::DirectorySeparatorChar)
    $mp = Join-Path $mp 'manifest.json'
    if (-not (Test-Path -LiteralPath $mp)) {
      throw "运行时版本 $($script:ResolvedRuntimeVersion) 的 vendor manifest 缺失：$mp。请先运行 yarn upstream:prepare-runtime 与 node scripts/sync-vendored-runtime.mjs --write --channel stable 生成。"
    }
  }
}

# 找到与 $Version 同一条 harness 线的**兄弟通道工作区**：上游为每条线各维护一个通道工作区
# （stable → dsh-plugin-desktop 是 rc.2 线；beta → dsh-plugin-desktop-beta 是 alpha.1 线）。
# 它的 package.json 就是该线配套依赖的权威版本表 —— 除了 @deepseek-ai/dsh*，还包括
# @deepseek-ai/cordis*、@deepseek-ai/schemastery 这类**伴随包**（名字里没有 dsh，
# 同样随 harness 线走）。
# 返回 @{ Name = <工作区目录名>; Pkg = <package.json 对象> }；找不到返回 $null。
function Get-HarnessLineSiblingWorkspace {
  param([Parameter(Mandatory = $true)][string]$Version)
  $headUp = Get-HeadJsonObject 'upstream.json'
  if (-not $headUp -or -not ($headUp.PSObject.Properties.Name -contains 'channels')) { return $null }
  foreach ($chName in @($headUp.channels.PSObject.Properties.Name)) {
    $chInfo = $headUp.channels.PSObject.Properties[$chName].Value
    if (-not $chInfo) { continue }
    if ($chInfo.sourceVersion -ne $Version) { continue }
    $candWs = [string]$chInfo.package
    if (-not $candWs -or $candWs -eq $script:ChannelWsName) { continue }
    $candPkg = Get-HeadJsonObject "$candWs/package.json"
    if (-not $candPkg) { continue }
    return @{ Name = $candWs; Pkg = $candPkg }
  }
  return $null
}

# 固定是否已**真正落到工作区**：upstream.json 里写着目标版本，不等于依赖也改过了。
# 旧版本脚本只改写 @deepseek-ai/dsh* 而漏掉伴随包，这时 0c) 的「声明已一致 → 跳过」
# 会让这个半成品**永远无法自愈**（实测：stable 被固定到 0.2.1-alpha.1 之后，
# schemastery 停在 ^3.18.4、cordis 停在 4.0.4，重跑构建一律走跳过路径 → 门禁必然 TS6200）。
function Test-HarnessPinConsistent {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][hashtable]$ManifestByName,
    $Sibling = $null
  )
  $wsPkg = Get-JsonObject (Get-ChannelWsPath 'package.json')
  foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
    $prop = $wsPkg.PSObject.Properties[$field]
    if (-not $prop -or $null -eq $prop.Value) { continue }
    $sibProp = if ($Sibling) { $Sibling.Pkg.PSObject.Properties[$field] } else { $null }
    foreach ($name in @($prop.Value.PSObject.Properties.Name)) {
      $val = $prop.Value.$name
      if ($name -eq '@deepseek-ai/dsh' -or $name.StartsWith('@deepseek-ai/dsh-')) {
        if ($ManifestByName.ContainsKey($name) -and $val -ne $Version) { return $false }
        continue
      }
      if (-not $name.StartsWith('@deepseek-ai/')) { continue }
      if (-not $sibProp -or $null -eq $sibProp.Value) { continue }
      $want = $sibProp.Value.$name
      if ($want -is [string] -and $want -and $val -ne $want) { return $false }
    }
  }
  return $true
}

# 运行时版本固定：把 stable 通道固定到 $script:ResolvedRuntimeVersion（deepseek-harness commit /
# upstream.json / dsh-plugin-desktop 依赖（含同线伴随包）/ 根 package.json resolutions）。
# **$script:ResolvedRuntimeVersion 来自 Resolve-HarnessVersion**：
#   - 未指定 -HarnessVersion → = 上游 upstream.json 声明的版本 → 本函数**不做任何固定**
#     （直接使用上游声明，构建上游原样）；
#   - 指定了 -HarnessVersion   → 与上游一致时跳过、不一致时才固定（幂等）。
# vendor/dsh-runtime/<版本>/ 由上游 sync 流程生成（yarn upstream:prepare-runtime
# + node scripts/sync-vendored-runtime.mjs --write --channel stable）。
function Set-RuntimeVersionPinned {
  $v = $script:ResolvedRuntimeVersion
  $vendorRelative = "vendor/dsh-runtime/$v"
  $manifestPath = Join-Path $script:Src ($vendorRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
  $manifestPath = Join-Path $manifestPath 'manifest.json'
  $entryByName = @{}
  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-JsonObject $manifestPath
    foreach ($p in @($manifest.packages)) { $entryByName[$p.name] = $p.filename }
    if ($entryByName.Count -eq 0) { throw "运行时 manifest 为空：$manifestPath" }
  } elseif ($script:HarnessOverrideActive) {
    # 显式指定的版本必须自带 vendor 产物，否则固定出来的是半成品
    throw "运行时版本 $v 的 vendor manifest 缺失：$manifestPath。请先运行 yarn upstream:prepare-runtime 与 node scripts/sync-vendored-runtime.mjs --write --channel stable 生成。"
  } else {
    # 未指定 -HarnessVersion：按上游声明继续（上游若真缺产物，会在后续解析/安装阶段失败）
    Write-WarnLine "运行时版本 $v（上游声明）的 vendor manifest 缺失：$manifestPath —— 继续按上游声明构建。"
  }

  # 0) AA provenance 同步（始终执行，不受下方“官方一致跳过”影响）：
  #    runtimePeers 是 AA prepare 复用检查的关键条件。必须与 AA policy 的
  #    runtimePeerRanges() 一致（读 desktop + beta 两个 workspace 的 dsh peer 依赖、
  #    去重合并），否则快路径复用失败 → 全量重建 → 临时目录从 registry 拉包混装
  #    rc.1/rc.2 → typecheck TS2717/TS2344 失败。commit 固定为 AA 源（避免 pull
  #    重置后回落）。注意：不要把 runtimePeers 硬编码成 $v —— 已验证产物的 peer
  #    是联合范围（如 "0.1.5-rc.2 || 0.1.6-alpha.2"），硬编码会破坏 provenance 自洽。
  $provPath = Join-Path $script:Src 'vendor\agents-anywhere\provenance.json'
  if (Test-Path -LiteralPath $provPath) {
    $prov = Get-JsonObject $provPath
    # 自洽优先：上游 provenance 的 commit 若已能与 desktopVersion 里的 c<commit12>
    # 对上（即本产物确实由该 commit 构建），就完全不要改写 —— 上游 release 校验
    # 现在会断言 “artifact version identifies the selected commit”，一旦我们把
    # commit 改成别的值（旧实现固定 a022d928…），校验立刻失败：
    #   AA release check failed: artifact version does not identify the selected commit.
    # 只有在上游 provenance 自身不自洽（产物名与 commit 对不上）时，才回落到旧行为。
    $artifactCommit12 = $null
    if ($prov.desktopVersion -match '\.c([0-9a-f]{12})\.') { $artifactCommit12 = $Matches[1] }
    $provSelfConsistent = ($null -ne $artifactCommit12) -and
      ($prov.commit -is [string]) -and $prov.commit.StartsWith($artifactCommit12)
    if ($provSelfConsistent) {
      Write-Info "AA provenance 自洽（commit $($prov.commit.Substring(0,10)) ↔ 产物 c$artifactCommit12），不做本地改写。"
    } else {
      $provChanged = $false
      if ($prov.commit -ne $script:AaSourceRef) { $prov.commit = $script:AaSourceRef; $provChanged = $true }
      if ($provChanged) {
        Set-Content -LiteralPath $provPath -Value (ConvertTo-Json $prov -Depth 10) -Encoding utf8 -NoNewline
        Write-WarnLine "AA provenance 不自洽，已按 AaSourceRef 回写 commit $($script:AaSourceRef.Substring(0,10))"
      }
    }
    # 按 AA policy runtimePeerRanges() 的规则计算联合 peer 范围（键序：typert/llm/session）。
    # 仅在 provenance 不自洽时才对齐（自洽时上游的 peer 范围已是产物真实构建条件，
    # 任何改写都会让 provenance 与 artifact 脱钩）。
    if (-not $provSelfConsistent) {
      $peerNames = @('@deepseek-ai/dsh-typert-protocol', '@deepseek-ai/dsh-llm', '@deepseek-ai/dsh-session')
      $peerWs = @(
        (Join-Path $script:Src 'dsh-plugin-desktop\package.json'),
        (Join-Path $script:Src 'dsh-plugin-desktop-beta\package.json')
      ) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-JsonObject $_ }
      $peerRangesMap = [ordered]@{}
      foreach ($peer in $peerNames) {
        $ranges = @($peerWs | ForEach-Object { $_.dependencies.$peer } | Where-Object { $_ -is [string] -and $_ })
        if ($ranges.Count -gt 0) { $peerRangesMap[$peer] = @($ranges | Sort-Object -Unique) -join ' || ' }
      }
      if ($peerRangesMap.Count -gt 0) {
        $peersDiffer = $false
        foreach ($peer in $peerNames) {
          if ($peerRangesMap.Contains($peer) -and $prov.runtimePeers.$peer -ne $peerRangesMap[$peer]) { $peersDiffer = $true; break }
        }
        if ($peersDiffer) {
          $prov.runtimePeers = [ordered]@{}
          foreach ($peer in $peerNames) { if ($peerRangesMap.Contains($peer)) { $prov.runtimePeers[$peer] = $peerRangesMap[$peer] } }
          $provChanged = $true
        }
      }
      if ($provChanged) {
        Set-Content -LiteralPath $provPath -Value (ConvertTo-Json $prov -Depth 10) -Encoding utf8 -NoNewline
        Write-WarnLine "AA provenance 已同步（commit $($script:AaSourceRef.Substring(0,10))，runtimePeers 与 AA policy 对齐）"
      }
    }
  }

  # 0b) 未指定 -HarnessVersion → 使用上游 upstream.json 声明的版本，不做任何固定/改写。
  #     $script:ResolvedRuntimeVersion / $script:ResolvedHarnessCommit 已被 Resolve-HarnessVersion 置为上游
  #     值（从 `git show HEAD:upstream.json` 读取），因此这里直接返回即可 ——
  #     upstream.json / 依赖版本串 / 根 resolutions 全部保持上游原样。
  #     注意：§0 的 AA provenance 同步仍照常执行（与版本固定正交，见上）。
  if (-not $script:HarnessOverrideActive) {
    Write-Info "运行时版本使用上游声明（dsh $v @ $($script:ResolvedHarnessCommit.Substring(0, [Math]::Min(12, $script:ResolvedHarnessCommit.Length)))）：未指定 -HarnessVersion，不做本地固定。"
    return
  }

  # 0c) 显式指定的版本与官方一致 → 跳过：upstream.json stable 已指向该 commit + 版本
  #     （runtimeSource 也随版本一致），无需改写 upstream.json / dsh 依赖 / resolutions
  #     （AA provenance 已在 0) 同步完成，不在此跳过范围）。
  $upPath = Join-Path $script:Src 'upstream.json'
  $sibling = Get-HarnessLineSiblingWorkspace -Version $v
  if (Test-Path -LiteralPath $upPath) {
    $upNow = Get-JsonObject $upPath
    $stableNow = $upNow.channels.stable
    if ($stableNow.commit -eq $script:ResolvedHarnessCommit -and $stableNow.sourceVersion -eq $v) {
      # 声明一致 ≠ 已经改完：必须再确认工作区依赖真的对齐（见 Test-HarnessPinConsistent）。
      if (Test-HarnessPinConsistent -Version $v -ManifestByName $entryByName -Sibling $sibling) {
        Write-Info "运行时版本已与官方一致（dsh $v @ $($script:ResolvedHarnessCommit.Substring(0,10))），跳过本地固定。"
        return
      }
      Write-WarnLine "upstream.json 已声明 $v，但工作区依赖尚未对齐（旧版本脚本可能只改写了 upstream.json）→ 继续执行完整固定。"
    }
  }

  # 1) upstream.json：stable 通道的 commit / 版本 / runtimeSource 固定
  $up = Get-JsonObject $upPath
  $stable = $up.channels.stable
  $stable.commit = $script:ResolvedHarnessCommit
  $stable.sourceVersion = $v
  $stable.runtimePackageVersion = $v
  $stable.runtimeSource = "$vendorRelative/manifest.json"
  Set-Content -LiteralPath $upPath -Value (ConvertTo-Json $up -Depth 10) -Encoding utf8 -NoNewline

  # 2) 只改写**当前通道工作区**（stable → dsh-plugin-desktop）的 @deepseek-ai/dsh* 依赖 → $v。
  #    【不再触碰 dsh-community-market/package.json】：市场工作区保持上游原样。
  #    上游在那里刻意声明多通道版本串（实测 57 处 "0.2.1-alpha.1" + 42 处联合范围
  #    "0.2.0-rc.2 || 0.2.1-alpha.1"，共 99 行），把它压平成单一 $v 会让工作区每次
  #    构建都变脏（git status 常驻 198 行 diff），且与上游自带 yarn.lock 不一致。
  #    旧理由已失效：当年把 market 加进来是为防 “Yarn 嵌套安装旧版副本，与 $v 的类型
  #    定义冲突 → TS2717/TS2344”。但上游现在自带 vendor/dsh-runtime/0.2.1-alpha.1/
  #    与 321 条 "@deepseek-ai/dsh-*@npm:0.2.1-alpha.1" 形式（另有 ^ 形式）的根
  #    resolutions，全部指向 file:vendor/dsh-runtime/0.2.1-alpha.1/*.tgz —— market 的
  #    beta 依赖会被解析到仓库内已存在的 vendor 产物，不会去 registry 拉嵌套副本，
  #    因此旧冲突前提不再成立。
  #    注意：仅当上游恢复“无 resolutions 覆盖 + registry 拉包”的形态时，才需要把下面
  #    被注释的那行加回 $pkgPaths。
  $pkgPaths = @(
    (Get-ChannelWsPath 'package.json')
    # (Join-Path $script:Src 'dsh-community-market\package.json')
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

  # 2b) 伴随依赖迁移：同属 harness 线、但名字不是 @deepseek-ai/dsh* 的包
  #     （@deepseek-ai/cordis 家族、@deepseek-ai/schemastery）也必须跟着 $v 走。
  #     2) 的过滤条件（$isDsh）**永远碰不到它们** —— 后果是把 stable 通道固定到另一条
  #     harness 线时，工作区仍声明上一条线的版本（实测 0.2.1-alpha.1：cordis 停在 4.0.4、
  #     schemastery 停在 ^3.18.4），而 $v 的运行时要求 4.0.5-alpha.1 / ~3.18.5-alpha.1。
  #     `^3.18.4` 不满足 `~3.18.5-alpha.1`（semver：预发布版本只在 major.minor.patch 三元组
  #     相同时才被普通范围接受，故 ^3.18.4 收不进 3.18.5-alpha.1）→ Yarn 在 dsh-llm 下再装
  #     一份嵌套副本 → schemastery 的两份 lib/types/index.d.ts 都是「全局脚本」且声明同一批
  #     标识符 → tsc 报 TS6200 ×2 + TS2883 → yarn package:dir 直接失败
  #     （2026-10-05 实测，日志 build-20261004-235833.log）。
  #     权威版本表：上游为每条 harness 线各维护一个通道工作区，其 package.json 里的
  #     @deepseek-ai/* 声明就是该线配套的版本（beta/next 工作区已写着 4.0.5-alpha.1 /
  #     ^3.18.5-alpha.1）。所以按 upstream.json（HEAD）找到与 $v 同线的兄弟通道，
  #     只照抄**目标工作区已声明的同名伴随包**，不动其余依赖。
  if ($sibling) {
    $wsPkgPath = Get-ChannelWsPath 'package.json'
    $wsPkg = Get-JsonObject $wsPkgPath
    $wsChanged = $false
    foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
      $wsProp = $wsPkg.PSObject.Properties[$field]
      $sibProp = $sibling.Pkg.PSObject.Properties[$field]
      if (-not $wsProp -or $null -eq $wsProp.Value -or -not $sibProp -or $null -eq $sibProp.Value) { continue }
      foreach ($name in @($wsProp.Value.PSObject.Properties.Name)) {
        if (-not $name.StartsWith('@deepseek-ai/')) { continue }
        # dsh* 已由 2) 按 runtime manifest 处理，这里只补伴随包
        if ($name -eq '@deepseek-ai/dsh' -or $name.StartsWith('@deepseek-ai/dsh-')) { continue }
        $sibVal = $sibProp.Value.$name
        if ($sibVal -isnot [string] -or -not $sibVal) { continue }
        if ($wsProp.Value.$name -ne $sibVal) {
          Write-WarnLine "伴随依赖迁移（$($sibling.Name) 线）：$name $($wsProp.Value.$name) → $sibVal"
          $wsProp.Value.$name = $sibVal
          $wsChanged = $true
        }
      }
    }
    if ($wsChanged) {
      Set-Content -LiteralPath $wsPkgPath -Value (ConvertTo-Json $wsPkg -Depth 100) -Encoding utf8 -NoNewline
      Write-WarnLine "运行时版本固定：$($script:ChannelWsName)\package.json 的伴随依赖已对齐 $v 线（$($sibling.Name)）→ 重装后不再嵌套第二份副本"
    }
  } else {
    Write-WarnLine "运行时版本固定：上游 upstream.json（HEAD）里没有与 $v 同线的其他通道工作区 → 跳过伴随依赖" +
      "（@deepseek-ai/cordis*、@deepseek-ai/schemastery 等）迁移。若这些包停在上一条线的版本，" +
      "Yarn 会嵌套安装第二份副本，类型门禁可能以 TS6200 失败。"
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
    #
    # 注意（2026-09 修复）：旧实现在多个旧版本补丁里用 Sort-Object Name -Descending
    # 取"字典序最大"的那个，会把 @0.1.7-rc.2 的补丁内容复制成 @0.1.5-rc.2 文件名
    # （'7' > '5'），于是一个面向 0.1.7 源码的补丁被拿去打 0.1.5 的 tarball，必然
    # 在 yarn install 阶段炸掉（ENOENT / patch does not apply）。这里改为：
    #   1) 先按语义版本从新到旧排序候选；
    #   2) 逐个用 git apply --check 校验是否真能打到本次固定版本的 tarball 上；
    #   3) 只有校验通过的才复制，否则明确警告并放弃（宁可丢掉该补丁也不要塞一个
    #      内容错版本的文件进去 —— 错版本补丁会以难以定位的 ENOENT 形式失败）。
    if (-not (Test-Path -LiteralPath $patchPath)) {
      # 注意（2026-09-28 修复）：必须用 @() 包裹。Set-StrictMode -Version Latest 下，
      # 对 $null / 单个对象 / 字符串取 .Count 会抛 PropertyNotFoundException；而
      # Get-ChildItem | Where-Object 在 0 个匹配时返回 $null、1 个匹配时返回标量对象。
      $candidates = @(Get-ChildItem -LiteralPath (Split-Path -Parent $patchPath) -Filter "$unscoped@*.patch" -File -ErrorAction SilentlyContinue |
          Where-Object { $_.BaseName -ne "$unscoped@$v" })
      $tarball = Join-Path $script:Src (($vendorRelative -replace '/', [IO.Path]::DirectorySeparatorChar))
      $tarball = Join-Path $tarball $p.filename
      $migrated = $false
      if ($candidates.Count -gt 0 -and (Test-Path -LiteralPath $tarball) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        # 语义版本降序：解析 <pkg>@<ver> 的 <ver>，按 [version] 比较（rc/alpha 前缀转可比较形式）
        $sorted = $candidates | Sort-Object -Property @{ Expression = {
              $raw = $_.BaseName.Substring($unscoped.Length + 1)
              if ($raw -match '^(\d+)\.(\d+)\.(\d+)(?:-([a-zA-Z]+)\.?(\d+))?') {
                [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
              } else { [version]'0.0.0' }
            } } -Descending
        $probe = Join-Path ([IO.Path]::GetTempPath()) ("dsh-patchprobe-" + [guid]::NewGuid().ToString('N'))
        foreach ($cand in $sorted) {
          # 脚本顶部 $PSNativeCommandUseErrorActionPreference=$true：tar / git apply 的非零
          # 退出在这里是“预期结果”（旧补丁打不到新版本 → 试下一个候选或放弃），必须临时降级
          # 成普通 $LASTEXITCODE 读数，否则整个 [02] 会以一个无名 git 错误终止（2026-09-28 修复）。
          $nativePref = $PSNativeCommandUseErrorActionPreference
          $PSNativeCommandUseErrorActionPreference = $false
          try {
            New-Item -ItemType Directory -Force -Path $probe | Out-Null
            & tar -xzf $tarball -C $probe --strip-components=1 2>$null
            if ($LASTEXITCODE -ne 0) { break }
            Copy-Item -LiteralPath $cand.FullName -Destination (Join-Path $probe 'probe.patch') -Force
            Push-Location $probe
            try { & git apply --check -p1 (Join-Path $probe 'probe.patch') 2>$null; $probeCode = $LASTEXITCODE }
            finally { Pop-Location }
            if ($probeCode -eq 0) {
              Copy-Item -LiteralPath $cand.FullName -Destination $patchPath
              Write-WarnLine "补丁迁移：$($cand.Name) → $(Split-Path -Leaf $patchPath)（已校验可应用到 $v tarball）"
              $migrated = $true
              break
            }
          } finally {
            $PSNativeCommandUseErrorActionPreference = $nativePref
            if (Test-Path -LiteralPath $probe) { Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue }
          }
        }
      }
      # 只在“该包确实有过旧版本补丁、但都打不到本次固定版本”时才告警；从未有过补丁的包
      # （manifest 里约 340 个包中的绝大多数）本就无需补丁，静默跳过，避免刷屏 300+ 行。
      if ($candidates.Count -gt 0 -and -not $migrated) {
        Write-WarnLine "补丁缺失且无可用的兼容旧版本：$unscoped@$v 将不带补丁（resolutions 回退为 file:）。" +
          "若该包确需补丁，请人工按 $v 源码更新 patches\$unscoped@$v.patch。"
      }
    }
    $val = if (Test-Path -LiteralPath $patchPath) { "patch:$($p.name)@$($src -replace ':', '%3A')#./$patchRel" } else { $src }
    $newRes["$($p.name)@npm:$v"] = $val
    $newRes["$($p.name)@npm:^$v"] = $val
  }
  $rootPkg.resolutions = $newRes
  Set-Content -LiteralPath $rootPkgPath -Value (ConvertTo-Json $rootPkg -Depth 100) -Encoding utf8 -NoNewline

  Write-Ok "运行时版本已固定：dsh $v（commit $($script:ResolvedHarnessCommit.Substring(0,10))，$($entryByName.Count) 个包）"
}

function Set-AAVendorDependency {
  # 上游 aa:prepare-release 的“复用已验证产物”条件之一：AA policy 的 AA_WORKSPACES 里
  # **每一个**工作区，其 "@agents-anywhere/dsh-bridge-next" 依赖都必须精确等于
  # file:../vendor/agents-anywhere/<provenance.artifact>。上游 31641c3961
  # （Pin coherent AA build dependencies and include Next in release checks）把
  # dsh-desktop-next 也纳入了该列表，而旧实现只对齐 stable（+ beta），于是快路径永远
  # 不成立 → 每次构建都全量重打包（≈7 分钟 + 需联网），并可能撞上 “Existing artifact
  # differs” 守卫中止打包。这里改为按 policy 的 AA_WORKSPACES 动态对齐，不再硬编码。
  $provPath = Join-Path $script:Src 'vendor\agents-anywhere\provenance.json'
  if (-not (Test-Path -LiteralPath $provPath)) { return }
  $prov = Get-JsonObject $provPath
  if (-not $prov.artifact) { return }
  $expected = "file:../vendor/agents-anywhere/$($prov.artifact)"
  $workspaces = @()
  $policyPath = Join-Path $script:Src 'scripts\agents-anywhere-release-policy.mjs'
  if (Test-Path -LiteralPath $policyPath) {
    $policyText = [System.IO.File]::ReadAllText($policyPath)
    $m = [regex]::Match($policyText, 'AA_WORKSPACES\s*=\s*\[([^\]]*)\]')
    if ($m.Success) {
      $workspaces = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
  }
  if ($workspaces.Count -eq 0) {
    # policy 读不到时回落旧行为（stable；beta 启用或脚本仍引用 beta 时含 beta）
    $aaScript = Join-Path $script:Src 'scripts\prepare-agents-anywhere-release.mjs'
    $alignBeta = (-not $script:DisableBeta) -or
      ((Test-Path -LiteralPath $aaScript) -and ([System.IO.File]::ReadAllText($aaScript)).Contains('dsh-plugin-desktop-beta'))
    $workspaces = if ($alignBeta) { @($script:ChannelWsName, 'dsh-plugin-desktop-beta') } else { @($script:ChannelWsName) }
  }
  foreach ($ws in $workspaces) {
    $pkg = Join-Path $script:Src (Join-Path $ws 'package.json')
    if (-not (Test-Path -LiteralPath $pkg)) { continue }
    $text = Get-Content -LiteralPath $pkg -Raw -Encoding utf8
    if ($text -notmatch '"@agents-anywhere/dsh-bridge-next"\s*:\s*"([^"]+)"') { continue }
    if ($Matches[1] -eq $expected) { continue }
    $fixed = [regex]::Replace($text, '("@agents-anywhere/dsh-bridge-next"\s*:\s*")[^"]+(")', "`${1}$expected`${2}", 1)
    Set-Content -LiteralPath $pkg -Value $fixed -Encoding utf8 -NoNewline
    Write-WarnLine "修复：$ws 的 AA 依赖已对齐 provenance（$($prov.artifact)）"
  }

  # 根 package.json resolutions 里的 connector 补丁也必须指向同一产物：上游
  # aaConnectorResolution() 把它写成
  #   patch:@agents-anywhere/dsh-bridge-next@file%3Avendor/agents-anywhere/<artifact>#./patches/agents-anywhere-connector-httpx.patch
  # 只对齐工作区依赖时，assertPreparedAaRelease 会以 “Connector compatibility patch
  # references a different AA artifact” 直接中止打包。保留原有补丁路径，只替换产物名。
  $rootPkgPath = Join-Path $script:Src 'package.json'
  if (Test-Path -LiteralPath $rootPkgPath) {
    $rootText = Get-Content -LiteralPath $rootPkgPath -Raw -Encoding utf8
    $res = [regex]::Match($rootText, '"@agents-anywhere/dsh-bridge-next"\s*:\s*"([^"]*@file%3Avendor/agents-anywhere/)([^"#]+\.tgz)([^"]*)"')
    if ($res.Success -and $res.Groups[2].Value -ne $prov.artifact) {
      $replacement = '"@agents-anywhere/dsh-bridge-next": "' + $res.Groups[1].Value + $prov.artifact + $res.Groups[3].Value + '"'
      $rootText = $rootText.Remove($res.Index, $res.Length).Insert($res.Index, $replacement)
      Set-Content -LiteralPath $rootPkgPath -Value $rootText -Encoding utf8 -NoNewline
      Write-WarnLine "修复：根 package.json 的 AA connector 补丁已对齐 provenance（$($prov.artifact)）"
    }
  }
}

# Windows 打包必需修复（不依赖 -Overlay）：
# 没有它们本机 win --dir 打包必然失败（原生重编译 / PR #829 钩子缺陷 / AA 复用校验）。
function Invoke-RequiredWinFixes {
  # 排除不需要的工作区（beta 通道 / 实验性 Next 桌面）：不装依赖、不参与编译
  Disable-ExcludedWorkspaces
  Disable-BetaAaPipeline
  Disable-MarketWorkspaceCheck
  Set-MarketPatchDisabled
  Set-PackageDirRebuildDisabled -WorkspaceName $script:ChannelWsName
  Set-AllArtifactVerifyDisabled -WorkspaceName $script:ChannelWsName
  Set-AAVendorDependency
  # 覆盖层/修复步骤会重写 package.json，且覆盖层里的 Reset-OverlayTrackedFiles
  # 会把 upstream.json / 根 package.json / 依赖版本还原回上游（目前仍是 rc.1）。
  # 必须在安装依赖之前把 stable 通道固定回本地版本，否则装出来的是旧运行时。
  Set-RuntimeVersionPinned
  Write-Ok 'Windows 打包必需修复已应用（beta/Next 工作区排除 / npmRebuild=false / 移除 PR #829 事后校验钩子 / AA 依赖对齐 / 运行时版本固定 / dshmarket 兼容补丁停用）'
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

# dsh-fs-local 本地补丁：Electron 43/44 的 asar 补丁对 asar 内路径的
# stat/lstat({ bigint: true }) 支持不完整 —— asarStatsToFsStats 完全忽略 bigint
# 选项，返回普通 Stats（mode 为 number，而非 BigInt）。dsh-fs-local 的 probe /
# probeNoFollow 用 `info.mode & 511n`（BigInt 位运算）必然抛
# "Cannot mix BigInt and other types"，导致 ASAR 布局下 afterPack 冒烟
# （verifyBundledSkills 对 asar 内目录 listDir）失败、electron-builder 中止、
# rcedit（exe 图标 + 版本信息编辑）从未执行。这里把 mode 先转 BigInt 再做位
# 运算，number 与 bigint 两种输入等值兼容（真实文件系统返回 bigint，asar
# 补丁返回 number）。
$script:DshFsLocalBigintPristine = @(
  '		mode: Number(info.mode & 511n),'
)
$script:DshFsLocalBigintFixed = @(
  '		mode: Number(BigInt(info.mode) & 511n),'
)

function Set-DshFsLocalBigintPatch {
  $targets = @(
    (Get-ChannelWsPath 'node_modules\@deepseek-ai\dsh-fs-local\lib\index.js')
  )
  foreach ($f in $targets) {
    if (-not (Test-Path -LiteralPath $f)) {
      Write-WarnLine "dsh-fs-local 补丁：未找到 $f（依赖未安装？），跳过。"
      continue
    }
    $raw = [System.IO.File]::ReadAllText($f)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($raw.Contains('BigInt(info.mode) & 511n')) {
      Write-Info "dsh-fs-local 补丁已生效：$f"
      continue
    }
    $lines = [System.IO.File]::ReadAllLines($f)
    $out = New-Object System.Collections.Generic.List[string]
    $patched = 0
    $i = 0
    while ($i -lt $lines.Length) {
      $match = $true
      for ($j = 0; $j -lt $script:DshFsLocalBigintPristine.Count; $j++) {
        if ($i + $j -ge $lines.Length -or $lines[$i + $j] -ne $script:DshFsLocalBigintPristine[$j]) { $match = $false; break }
      }
      if ($match) {
        foreach ($ln in $script:DshFsLocalBigintFixed) { $out.Add($ln) }
        $i += $script:DshFsLocalBigintPristine.Count
        $patched++
      } else {
        $out.Add($lines[$i])
        $i++
      }
    }
    if ($patched -eq 0) {
      Write-WarnLine "dsh-fs-local 补丁：$f 中未找到原版 mode 位运算行（包版本可能已变），跳过。"
      continue
    }
    [System.IO.File]::WriteAllText($f, ($out -join $eol) + $eol)
    Write-WarnLine "dsh-fs-local 补丁已应用：$f（$patched 处）"
  }
}

function Test-InstalledElectron {
  # 返回当前通道 node_modules 里已安装的 electron 版本（不存在返回 $null）
  $pkg = Get-ChannelWsPath 'node_modules\electron\package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return $null }
  return (Get-JsonObject $pkg).version
}

function Test-InstalledPnpm {
  # 返回当前通道 node_modules 里已安装的 pnpm 版本（不存在返回 $null）。
  # 用途与 Test-InstalledElectron 相同：-SkipInstall 时判断覆盖目标是否需要补装。
  $pkg = Get-ChannelWsPath 'node_modules\pnpm\package.json'
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
        # 行尾规范化：patch 若为 CRLF（如 PowerShell 重定向导出所致），git apply 会把 \r
        # 当作行内容的一部分而匹配失败（"上游没变但补丁打不上"）。统一转 LF，幂等。
        $patchText = [System.IO.File]::ReadAllText($patch)
        $patchLf = $patchText -replace "`r`n", "`n"
        if ($patchLf -cne $patchText) {
          [System.IO.File]::WriteAllText(
            $patch,
            $patchLf,
            (New-Object System.Text.UTF8Encoding($false)))
          Write-WarnLine "覆盖层：$([IO.Path]::GetFileName($patch)) 行尾 CRLF→LF 已规范化"
        }
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

# ---- AA（Agents Anywhere）本机发布的固化与恢复 ----
# 上游 package:dir 会先跑 aa:prepare-release。它的“复用已验证产物”快路径要求三条同时成立：
#   ① provenance.commit == AA main 当前 commit
#   ② provenance.runtimePeers == 本机 runtimePeerRanges() 算出的 peer 联合范围
#   ③ 各工作区依赖 + 根 resolutions 指向 provenance.artifact，且该文件存在、sha256 一致
# 本机把运行时钉在 0.1.7-rc.2（本地降级）且按三个桌面工作区求并集，peer 联合范围
# 撑成 “0.1.7-rc.2 || 0.2.0-rc.2”，r-hash（rc########）必然与上游发布的产物（只含
# 0.2.0-rc.2，r27dbe9f7）不同 → 快路径永远不成立 → 每次构建全量重打包（≈7 分钟、需
# 联网，AA 源 clone + install + build + typecheck + pack）；而重打包字节不可复现，于是
# 撞上 “Existing artifact differs: …; refusing to overwrite it” 守卫直接中止打包。
# 更麻烦的是这份发布记录写在受跟踪文件里（vendor/agents-anywhere/provenance.json 等），
# 每次 pull 的 git checkout -f 都把它还原成上游版本，而重打包出来的 .tgz 是未跟踪文件会
# 留下来 —— 同一个坑每次构建重演。
# 对策①：把“本机发布”当覆盖层 —— 打包成功后导出到 overlay\aa\，下次 pull 后恢复回
# vendor\agents-anywhere\，快路径即可命中（打包回到 ≈40 秒），只有 AA main 真的前进时
# 才需要重新打包并再次固化。
# 对策②（2026-09-29 新增，因运行时改为跟随上游 0.2.0-rc.2 而必需）：覆盖层只在本机
# 发布**确实与当前配置匹配**时才恢复 —— 恢复前核对 overlay\aa\record.json 记录的
# runtimeVersion 是否等于 $script:ResolvedRuntimeVersion。理由：pin 一旦等于上游版本，peer 联合
# 范围就与上游自带的那份发布完全一致，此时上游自己 commit 在仓库里的产物（同名
# r27dbe9f7）才是快路径该用的；若仍按旧记录把本机那份（异 hash、异 peers）盖上去，
# 快路径必然不成立 → 全量重打包 → 重新打包出来的产物与上游同名却字节不同 → 直接被
# “Existing artifact differs” 守卫中止（构建 7 分钟后硬失败）。旧格式记录（无
# record.json）同样视为不匹配并跳过，等下一次真正需要本机打包时再重新固化。
$script:AaVendorDir = Join-Path $script:Src 'vendor\agents-anywhere'
$script:AaOverlayDir = Join-Path $script:SrcOverlayDir 'aa'

function Get-AaOverlayRuntimeVersion {
  # overlay\aa\record.json：本机发布记录的自述文件——“这份发布是为哪个运行时版本
  # 建的”。旧格式（没有该文件）返回 $null，调用方按“不匹配”处理。
  $markerPath = Join-Path $script:AaOverlayDir 'record.json'
  if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
  $marker = Get-JsonObject $markerPath
  if ($marker.PSObject.Properties['runtimeVersion']) { return $marker.runtimeVersion }
  return $null
}

function Restore-AaVendorPublication {
  # pull 重置之后、打包之前：恢复本机发布记录，并清理未被引用的未跟踪产物。
  # 清理是必需的：它们与重打包结果同名却字节不同，直接触发上游的守卫。
  # 恢复的前提是记录与当前固定的运行时版本相符（详见上方“对策②”）：pin 跟随上游时
  # 上游自带的那份发布才是快路径该用的，用异 peers 的本机记录覆盖它必然导致重打包，
  # 而重打包产物与上游同名不同字节 → 撞 “Existing artifact differs” 守卫硬失败。
  if (-not $script:Overlay) { return }
  $recordPath = Join-Path $script:AaOverlayDir 'provenance.json'
  if (Test-Path -LiteralPath $recordPath) {
    $record = Get-JsonObject $recordPath
    if ($record.artifact) {
      $recordedArtifact = Join-Path $script:AaOverlayDir $record.artifact
      $recordVersion = Get-AaOverlayRuntimeVersion
      if ($recordVersion -ne $script:ResolvedRuntimeVersion) {
        $label = if ($recordVersion) { $recordVersion } else { '未知（旧格式，无 record.json）' }
        Write-WarnLine "AA 覆盖层：本机发布记录面向运行时 $label，与当前固定的 $($script:ResolvedRuntimeVersion) 不匹配 → 跳过恢复，" +
          '改用上游自带的发布记录（若上游产物同样不匹配，AA 会重新打包并在成功后重新固化本覆盖层）。'
      } elseif (Test-Path -LiteralPath $recordedArtifact) {
        New-Item -ItemType Directory -Force -Path $script:AaVendorDir | Out-Null
        Copy-Item -LiteralPath $recordedArtifact -Destination (Join-Path $script:AaVendorDir $record.artifact) -Force
        Copy-Item -LiteralPath $recordPath -Destination (Join-Path $script:AaVendorDir 'provenance.json') -Force
        Write-WarnLine "AA 覆盖层：已恢复本机发布记录 $($record.artifact) → vendor\agents-anywhere"
      } else {
        Write-WarnLine "AA 覆盖层：overlay\aa 缺少产物 $($record.artifact)，跳过恢复（本次按上游 provenance 走，可能触发全量重打包）。"
      }
    }
  }
  $vendorProv = Join-Path $script:AaVendorDir 'provenance.json'
  $referenced = $null
  if (Test-Path -LiteralPath $vendorProv) { $referenced = (Get-JsonObject $vendorProv).artifact }
  $prevNative = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try { $untracked = @(& git -C $script:Src ls-files --others --exclude-standard -- 'vendor/agents-anywhere') }
  finally { $PSNativeCommandUseErrorActionPreference = $prevNative }
  foreach ($rel in $untracked) {
    if ($rel -notmatch '\.tgz$') { continue }
    $name = [IO.Path]::GetFileName($rel)
    if ($name -eq $referenced) { continue }
    Remove-Item -LiteralPath (Join-Path $script:Src ($rel -replace '/', '\')) -Force -ErrorAction SilentlyContinue
    Write-WarnLine "AA 覆盖层：已清理未被引用的本机产物 $name（防止重打包撞 “Existing artifact differs” 守卫）"
  }
}

function Export-AaVendorPublication {
  # 打包成功后：把 vendor\agents-anywhere 的本机发布记录固化到 overlay\aa\，并写下
  # record.json（自述：这份发布是面向哪个运行时版本建的 —— 恢复时要按它判断是否
  # 仍然适用，见 Restore-AaVendorPublication）。
  if (-not $script:Overlay) { return }
  $vendorProv = Join-Path $script:AaVendorDir 'provenance.json'
  if (-not (Test-Path -LiteralPath $vendorProv)) { return }
  $prov = Get-JsonObject $vendorProv
  if (-not $prov.artifact) {
    Write-WarnLine 'AA 覆盖层：vendor provenance 缺少 artifact 字段，跳过固化。'
    return
  }
  $artifactPath = Join-Path $script:AaVendorDir $prov.artifact
  if (-not (Test-Path -LiteralPath $artifactPath)) {
    Write-WarnLine "AA 覆盖层：vendor 缺少产物 $($prov.artifact)，跳过固化。"
    return
  }
  $recordPath = Join-Path $script:AaOverlayDir 'provenance.json'
  if ((Test-Path -LiteralPath $recordPath) -and
      ((Get-FileHash $recordPath -Algorithm SHA256).Hash -eq (Get-FileHash $vendorProv -Algorithm SHA256).Hash) -and
      (Test-Path -LiteralPath (Join-Path $script:AaOverlayDir $prov.artifact)) -and
      ((Get-AaOverlayRuntimeVersion) -eq $script:ResolvedRuntimeVersion)) {
    Write-Info "AA 覆盖层：本机发布未变化（$($prov.artifact)，运行时 $($script:ResolvedRuntimeVersion)），无需固化。"
    return
  }
  New-Item -ItemType Directory -Force -Path $script:AaOverlayDir | Out-Null
  # 只保留当前产物，避免 overlay\aa 无限膨胀
  Get-ChildItem -LiteralPath $script:AaOverlayDir -File -Filter '*.tgz' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $prov.artifact } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  Copy-Item -LiteralPath $artifactPath -Destination (Join-Path $script:AaOverlayDir $prov.artifact) -Force
  Copy-Item -LiteralPath $vendorProv -Destination $recordPath -Force
  Set-Content -LiteralPath (Join-Path $script:AaOverlayDir 'record.json') -Encoding utf8 -NoNewline -Value (ConvertTo-Json ([ordered]@{
        runtimeVersion = $script:ResolvedRuntimeVersion
        harnessCommit  = $script:ResolvedHarnessCommit
        artifact       = $prov.artifact
        recordedAt     = (Get-Date).ToString('s')
      }) -Depth 5)
  $kb = [math]::Round((Get-Item -LiteralPath $artifactPath).Length / 1KB)
  Write-WarnLine "AA 覆盖层：本机发布已固化 → overlay\aa\$($prov.artifact)（$kb KB，运行时 $($script:ResolvedRuntimeVersion)），下次 pull 后自动恢复"
}

function Invoke-ChannelOverlayPreInstall {
  # 用户定制覆盖层（安装前，仅 -Overlay）：electron 版本 / pnpm 版本 / .yarnrc.yml 门禁
  # / 图标 / src 覆盖层（新建文件 + 修改补丁）/ AA 本机发布记录
  # （npmRebuild=false 与 afterAllArtifactBuild 移除属本机必需修复，另行无条件应用）
  Reset-OverlayTrackedFiles  # 确保工作树覆盖层文件与上游一致后再改（幂等）
  Restore-AaVendorPublication
  $null = Set-ElectronOverride
  $null = Set-PnpmOverride
  Set-AgeGateConfig
  Copy-TrayIconAssets
  Apply-SrcOverlay
  Write-Ok "本地覆盖层已应用（通道 $script:Channel → $script:ChannelWsName）"
}

function Invoke-ChannelOverlayPostInstall {
  # 覆盖层（安装后）：pnpm.mjs 补丁（install 会还原为原版）
  Set-PnpmDistPatch
  # dsh-fs-local bigint 兼容补丁（install 会还原为原版；ASAR 布局打包必需）
  Set-DshFsLocalBigintPatch
}

# ---- 覆盖层产物部署与核对（打包后执行）----
# 打进去的 startup-config.ts 会在启动时读 dirname(process.execPath)\startup.json；
# 文件缺失时 applyDesktopStartupConfig 静默返回“无配置”——app 照常启动但定制不生效。
# 所以构建的最后一步主动把 overlay\startup.json 放到 exe 同级目录，并逐项核对覆盖层
# 是否真的进了产物，避免“构建成功但没带上自定义”。

function Get-PackagedExeDir {
  # 本机 Windows 产物里 exe 所在目录（dist\win-unpacked）；不存在时返回 $null。
  $unpacked = Join-Path (Get-ChannelWsPath 'dist') 'win-unpacked'
  if (Test-Path -LiteralPath $unpacked) { return $unpacked }
  return $null
}

function Publish-OverlayRuntimeAssets {
  # overlay\startup.json → 产物 exe 同级目录（启动配置的唯一来源）
  if (-not $script:SrcOverlayDir) { return }
  $src = Join-Path $script:SrcOverlayDir 'startup.json'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-WarnLine "覆盖层：未找到 $src，跳过 startup.json 部署（产物不会带启动配置）。"
    return
  }
  $exeDir = Get-PackagedExeDir
  if (-not $exeDir) {
    Write-WarnLine '覆盖层：未找到 dist\win-unpacked，跳过 startup.json 部署。'
    return
  }
  # 配置写错会让 app 直接启动失败（applyDesktopStartupConfig 抛错），构建期先拦一道。
  # 这里只做结构自检；bootstrap 名单等语义校验仍在运行时（src\startup-config.ts）执行。
  try {
    $parsed = [System.IO.File]::ReadAllText($src) | ConvertFrom-Json
  } catch {
    throw "覆盖层：overlay\startup.json 不是合法 JSON：$($_.Exception.Message)"
  }
  if ($parsed.version -ne 1) {
    throw "覆盖层：overlay\startup.json 的 version 必须为 1（实际为 $($parsed.version)）。"
  }
  $dst = Join-Path $exeDir 'startup.json'
  Copy-Item -LiteralPath $src -Destination $dst -Force
  try { [System.IO.File]::SetAttributes($dst, [System.IO.FileAttributes]::Normal) } catch {}
  Write-Ok "覆盖层：startup.json 已部署到 $dst"
}

function Test-BinaryContainsAscii {
  # 分块扫描二进制文件里的 ASCII 串（app.asar 达数百 MB，整份读入内存会顶到 500MB+）
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Needle,
    [int]$ChunkBytes = 4MB
  )
  $overlap = $Needle.Length - 1
  $buffer = [byte[]]::new($ChunkBytes + $overlap)
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $carry = 0
    while (($read = $stream.Read($buffer, $carry, $ChunkBytes)) -gt 0) {
      $total = $carry + $read
      $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $total)
      if ($text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) { return $true }
      # 跨块匹配：把尾部不足一个 needle 的部分带到下一块开头
      $carry = [Math]::Min($overlap, $total)
      [Array]::Copy($buffer, $total - $carry, $buffer, 0, $carry)
    }
    return $false
  } finally {
    $stream.Dispose()
  }
}

function Assert-OverlayArtifacts {
  # 覆盖层是否真的进了产物。补丁打不上由 Apply-SrcOverlay 抛错兜住，但 asar 布局 /
  # 部署环节的问题只有产物里才暴露，这里逐项核对，缺项直接失败。
  $exeDir = Get-PackagedExeDir
  if (-not $exeDir) {
    Write-WarnLine '覆盖层核对：未找到 dist\win-unpacked，跳过产物核对。'
    return
  }
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

  # 2) 启动配置：startup-config.ts 读的就是 exe 同级的 startup.json
  $cfg = Join-Path $exeDir 'startup.json'
  if (Test-Path -LiteralPath $cfg) {
    $size = (Get-Item -LiteralPath $cfg).Length
    $rows.Add([pscustomobject]@{ 项目 = 'startup.json'; 结果 = 'OK'; 说明 = "exe 同级 · $size 字节" })
  } else {
    $rows.Add([pscustomobject]@{ 项目 = 'startup.json'; 结果 = '缺失'; 说明 = '启动配置不会被读取' })
    $missing.Add('startup.json')
  }

  # 3) 补丁代码：main.ts 补丁引入的符号必须出现在打包后的应用代码里。
  #    上游 83cc4f821c/09070dd72e 起 Windows 打包主动禁用 ASAR（build.asar=false），
  #    产物布局变成 resources\app\<lib|build|node_modules> 而不是 resources\app.asar。
  #    两种布局都要认，否则会误报“覆盖层没进产物”（实际已进）。
  $asar = Join-Path $exeDir 'resources\app.asar'
  $unpackedApp = Join-Path $exeDir 'resources\app'
  $needle = 'applyDesktopStartupConfig'
  $patchFound = $null   # 命中的说明文字
  if (Test-Path -LiteralPath $asar) {
    if (Test-BinaryContainsAscii -Path $asar -Needle $needle) {
      $patchFound = 'applyDesktopStartupConfig 已打包（app.asar）'
    }
  }
  if (-not $patchFound -and (Test-Path -LiteralPath $unpackedApp)) {
    $hit = @(Get-ChildItem -LiteralPath $unpackedApp -Recurse -File -Include '*.js', '*.mjs', '*.cjs' -ErrorAction SilentlyContinue |
      Select-String -Pattern $needle -List -ErrorAction SilentlyContinue)
    if ($hit.Count -gt 0) {
      $patchFound = "applyDesktopStartupConfig 已打包（$($hit[0].Path.Substring($exeDir.Length).TrimStart('\'))）"
    }
  }
  if ($patchFound) {
    $rows.Add([pscustomobject]@{ 项目 = '补丁代码'; 结果 = 'OK'; 说明 = $patchFound })
  } else {
    $where = if (Test-Path -LiteralPath $asar) { 'app.asar' } elseif (Test-Path -LiteralPath $unpackedApp) { 'resources\app' } else { 'resources（既无 app.asar 也无 app\）' }
    $rows.Add([pscustomobject]@{ 项目 = '补丁代码'; 结果 = '缺失'; 说明 = "$where 中未找到 startup-config 集成点" })
    $missing.Add('补丁代码（startup-config 集成点）')
  }

  # 4) 图标资源：ASAR 启用时解包到 app.asar.unpacked\build；禁用 ASAR 时直接在
  #    resources\app\build。两种位置都检查。
  $wantIcons = @('app-icon.png', 'tray-icon-blue.png', 'tray-icon-blue@1.25x.png', 'tray-icon-blue@1.5x.png', 'tray-icon-blue@2x.png')
  $iconDirs = @(
    (Join-Path $exeDir 'resources\app.asar.unpacked\build'),
    (Join-Path $exeDir 'resources\app\build')
  ) | Where-Object { Test-Path -LiteralPath $_ }
  $iconDir = $null
  foreach ($d in $iconDirs) {
    if (@($wantIcons | Where-Object { Test-Path -LiteralPath (Join-Path $d $_) }).Count -eq $wantIcons.Count) { $iconDir = $d; break }
  }
  if ($null -ne $iconDir) {
    $rows.Add([pscustomobject]@{ 项目 = '图标资源'; 结果 = 'OK'; 说明 = "$($wantIcons.Count) 个已就位（$($iconDir.Substring($exeDir.Length).TrimStart('\'))）" })
  } else {
    $absent = @($wantIcons | Where-Object {
        $found = $false
        foreach ($d in $iconDirs) { if (Test-Path -LiteralPath (Join-Path $d $_)) { $found = $true; break } }
        -not $found
      })
    if ($iconDirs.Count -eq 0) {
      $rows.Add([pscustomobject]@{ 项目 = '图标资源'; 结果 = '缺失'; 说明 = '未找到 build 资源目录（app.asar.unpacked\build 或 resources\app\build）' })
      $missing.Add('图标资源目录')
    } else {
      $rows.Add([pscustomobject]@{ 项目 = '图标资源'; 结果 = '缺失'; 说明 = "缺少：$($absent -join ', ')" })
      $missing.Add("图标资源（$($absent -join '、')）")
    }
  }

  Write-Host ''
  Write-Host '覆盖层产物核对：' -ForegroundColor White
  foreach ($row in $rows) {
    $color = if ($row.结果 -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-16} " -f $row.项目) -NoNewline
    Write-Host ("{0,-6}" -f $row.结果) -NoNewline -ForegroundColor $color
    Write-Host $row.说明
  }
  if ($missing.Count -gt 0) {
    throw "覆盖层未完整进入产物：$($missing -join '、')。构建成功但没有带上自定义，请检查上面的核对结果。"
  }
  Write-Ok '覆盖层已确认进入产物（启动配置 + 补丁代码 + 图标资源）'
}

function Update-SourceRepository {
  # dsh-desktop 为独立仓库：不存在时克隆（--recursive 连带嵌套 deepseek-harness），
  # 已存在时 fetch + 强制重置本地分支到上游 master 最新。--force 会丢弃上次构建
  # 注入的覆盖层改动，确保每次从干净快照开始、构建产物可复现。嵌套子模块
  # deepseek-harness 随 checkout 一起对齐（具体 pinned commit 由 Initialize-Submodule
  # 按 upstream.json 再校准）。
  $gitDir = Join-Path $script:Src '.git'
  if (Test-Path -LiteralPath $gitDir) {
    $prevEap = $ErrorActionPreference
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
      Write-Info "dsh-desktop 已存在，正在拉取上游 $($script:SrcBranch) 最新并重置本地分支 ..."
      $output = @(& git -C $script:Src fetch origin 2>&1)
      foreach ($line in $output) {
        $text = if ($null -eq $line) { '' } else { [string]$line }
        Write-Host $text
        Write-Log $text
      }
      if ($LASTEXITCODE -ne 0) {
        throw "git fetch origin 失败 (exit $LASTEXITCODE)。请检查网络 / 代理（-NoProxy 可禁用代理）与 Git 凭据。"
      }

      $output = @(& git -C $script:Src checkout -B $script:SrcBranch "origin/$script:SrcBranch" --force 2>&1)
      foreach ($line in $output) {
        $text = if ($null -eq $line) { '' } else { [string]$line }
        Write-Host $text
        Write-Log $text
      }
      if ($LASTEXITCODE -ne 0) {
        throw "git checkout -B $($script:SrcBranch) origin/$($script:SrcBranch) --force 失败 (exit $LASTEXITCODE)。"
      }

      $output = @(& git -C $script:Src submodule update --init --recursive --force 2>&1)
      foreach ($line in $output) {
        $text = if ($null -eq $line) { '' } else { [string]$line }
        Write-Host $text
        Write-Log $text
      }
      if ($LASTEXITCODE -ne 0) {
        throw "嵌套子模块 deepseek-harness 更新失败 (exit $LASTEXITCODE)。请检查网络 / 代理与 Git 凭据。"
      }

      $head = (git -C $script:Src rev-parse --short HEAD).Trim()
      Write-Ok "已更新到上游 $($script:SrcBranch) 最新（HEAD=$head）。"
    } finally {
      $ErrorActionPreference = $prevEap
      $PSNativeCommandUseErrorActionPreference = $prevNative
    }
  } elseif (Test-Path -LiteralPath $script:Src) {
    throw "目录 $($script:Src) 已存在但不是 Git 仓库（缺少 .git）。请手动处理该目录后再运行本脚本。"
  } else {
    Write-Info "未找到 $($script:Src)，正在克隆 $script:SrcRepository（--recursive 含嵌套 deepseek-harness）..."
    Invoke-External git @('clone', '--recursive', $script:SrcRepository, $script:Src)
  }
}

function Ensure-Source {
  if ($SkipPull) {
    $gitDir = Join-Path $script:Src '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
      throw "未找到 $($script:Src)（或缺少 .git）。-SkipPull 模式下不会自动克隆 / 更新，请先运行一次不带 -SkipPull 的构建。"
    }
    Write-WarnLine '已跳过源码拉取（-SkipPull），使用现有代码。'
  } else {
    Update-SourceRepository
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
    # 覆盖层可能改动 package.json（electron 版本固定等），锁文件需随之刷新，故用可变 install
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
  Invoke-Step '解析 deepseek-harness 运行时版本（-HarnessVersion / 上游声明）' { Resolve-HarnessVersion }
  Invoke-Step "固定运行时版本（deepseek-harness $($script:ResolvedRuntimeVersion)）" { Set-RuntimeVersionPinned }
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
    if ($Overlay -and $script:ElectronOverrideActive -and $installedElectron -and $installedElectron -ne $script:ElectronOverride) {
      $needInstall += "electron 已装 $installedElectron ≠ 覆盖目标 $($script:ElectronOverride)"
    }
    $installedPnpm = Test-InstalledPnpm
    if ($Overlay -and $script:PnpmOverrideActive -and $installedPnpm -and $installedPnpm -ne $script:PnpmOverride) {
      $needInstall += "pnpm 已装 $installedPnpm ≠ 覆盖目标 $($script:PnpmOverride)"
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

  # AA 源固定：仅在 vendored provenance 自身不自洽时才强制 $script:AaSourceRef。
  # 上游 release 校验会断言 “artifact version identifies the selected commit”
  # （artifact 名含 .c<commit12>.），所以把 DSH_AA_SOURCE_REF 设成一个与已 vendored
  # 产物不同的 commit，会让 aa:prepare-release 直接失败：
  #   AA release check failed: artifact version does not identify the selected commit.
  # provenance 自洽时沿用上游自己的 commit（与 artifact 同名一致），不再干预。
  $aaProvPath = Join-Path $script:Src 'vendor\agents-anywhere\provenance.json'
  $aaSelfConsistent = $false
  $aaProvCommit12 = $null
  if (Test-Path -LiteralPath $aaProvPath) {
    $aaProv = Get-JsonObject $aaProvPath
    if ($aaProv.desktopVersion -match '\.c([0-9a-f]{12})\.') { $aaProvCommit12 = $Matches[1] }
    $aaSelfConsistent = ($null -ne $aaProvCommit12) -and ($aaProv.commit -is [string]) -and $aaProv.commit.StartsWith($aaProvCommit12)
  }
  if (-not $env:DSH_AA_SOURCE_REF) {
    if ($aaSelfConsistent) {
      $env:DSH_AA_SOURCE_REF = $aaProv.commit
      Write-Info "AA 源沿用 vendored provenance 自洽 commit $($aaProv.commit.Substring(0,12))（与产物 c$aaProvCommit12 一致）"
    } else {
      $env:DSH_AA_SOURCE_REF = $script:AaSourceRef
      Write-WarnLine "AA provenance 不自洽，回落到固定源 $($script:AaSourceRef.Substring(0,12))（可能触发 AA 全量重建）"
    }
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

  # 覆盖层部署 + 核对：产物必须自带 startup.json，且补丁代码 / 图标资源都在里面。
  # 放在时间戳规整之前，让新拷入的 startup.json 也一起被规整。
  # AA 本机发布固化必须放在最前：package:dir 里的 aa:prepare-release 若重新发布了产物，
  # 这里把它固化进 overlay\aa\，下次 pull 后才能恢复、避免每次构建都全量重打包。
  if ($Overlay -and $script:Failed -eq 0 -and
      $Target -in @('package-dir', 'dist-win', 'dist-win-portable', 'dist-mac', 'dist-mac-smoke')) {
    Invoke-Step '固化 AA 本机发布（overlay\aa）' { Export-AaVendorPublication }
    Invoke-Step '部署覆盖层运行时资源（startup.json → 产物 exe 同级）' { Publish-OverlayRuntimeAssets }
    Invoke-Step '核对覆盖层已进入产物' { Assert-OverlayArtifacts }
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
