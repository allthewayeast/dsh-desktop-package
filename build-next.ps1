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

  overlay-next 负责三件事：启动配置、主窗口几何持久化、页面缩放（Ctrl/Cmd `+` `-` `0`）。
    overlay-next\src\startup-config.ts        新文件：启动配置解析（网络/环境变量开关）
    overlay-next\src\startup-config.spec.ts   新文件：配套单测
    overlay-next\src\window-state.ts          新文件：主窗口位置/大小持久化
    overlay-next\src\window-state.spec.ts     新文件：配套单测
    overlay-next\patches\main.ts.patch        接入 applyDesktopStartupConfig、DSH_HOME 回退、
                                              窗口几何恢复/保存、主进程页面缩放快捷键
    overlay-next\startup.json                 运行时数据，构建后拷到 exe 同级
  "让 DSH_HOME 生效"不是附加功能：startup.json 里配置的就是 DSH_HOME，而 next 原本只认
  DSH_DESKTOP_NEXT_HOME，不补这段启动配置就落不到 home 上。

  页面缩放同理：next 自己不做任何缩放接线，Ctrl/Cmd `+`/`-` 于是落到客户端 ui-theme 的
  **字号**绑定上 —— 那套只步进字号 token，px 定的外壳（最显眼的就是左侧面板）纹丝不动，
  看起来像"只缩放了半个窗口"。现在由主进程拦下这三个手势并 setZoomLevel（范围
  -4..4，与 stable 的 handleZoomShortcut 一致），整页一个缩放级别，面板跟着一起动。

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
  Electron 目标版本（改写 next 工作区 devDependencies.electron）。**未指定时沿用上游声明**，
  构建上游原样；语义与 build.ps1 的同名参数一致。

.PARAMETER HarnessVersion
  dsh 运行时（deepseek-harness）目标版本。**未指定时沿用上游声明**（next 工作区自己声明的
  @deepseek-ai/dsh 版本），不改写任何依赖。指定时把 next 工作区的 @deepseek-ai/dsh* 依赖、
  伴随包（@deepseek-ai/cordis* / schemastery 等）与根 resolutions 固定到该版本；该版本的
  vendor\dsh-runtime\<版本>\manifest.json 必须已存在（缺则直接失败，见 Resolve-HarnessVersion）。

.PARAMETER HarnessCommit
  -HarnessVersion 对应的 deepseek-harness commit。**通常无需指定**：版本有同线通道时取
  upstream.json 的 commit，否则取标签 dsh-v<版本>。显式给出时以参数为准（与标签不一致只告警）。

.PARAMETER PnpmVersion
  pnpm 目标版本（改写 next 工作区 dependencies.pnpm，并把根 resolutions 的 pnpm 补丁条目
  重指到该版本；补丁取自 overlay\pnpm\pnpm@<版本>.patch）。**未指定时沿用上游声明**。

.PARAMETER Preview
  只做「拉源码 + 解析 / 固定版本 + 应用覆盖层 + 注入」，打印改动摘要后退出，**不安装、
  不编译**。用于在跑一次 6 分钟构建之前先看参数到底改了什么。

.PARAMETER KeepGoing
  出错继续，最后汇总。

.PARAMETER FixedTokenPatch
  【补丁开关，不是值】把「启动 token 可由外部定住」这个能力编进产物：
  给 dsh-client-connection 的产物加一条 config.launchToken ?? $env:DSH_WEB_TOKEN 的来源链。
  **不给这个开关就不打补丁**，token 仍是每次启动随机（上游行为）。

  打了之后 token 从哪来？**不在编译参数里**，写进 exe 同级的 startup.json：
      { "version": 1, "env": { "DSH_WEB_TOKEN": "<至少 16 位，A-Za-z0-9_- >" } }
  也可以直接用同名环境变量（优先级高于文件）。换 token 重启即可，不必重编。

.PARAMETER ListenAllInterfacesPatch
  【补丁开关，不是值】把「可以绑定 0.0.0.0（本机所有网卡）」这个能力编进产物，共两处：
    · 运行时产物（tools\dsh-web-access.ps1 的 listen 组）：放行通配地址、通配绑定时的 URL
      回落成回环、删掉 `dsh web --host` 的 CLI 守卫；
    · 源码补丁（overlay-next\patches\index.ts.patch）：Host 把 webserver 的 host 从写死的
      127.0.0.1 改成读 DSH_NEXT_WEB_HOST。
  **不给这个开关就不打补丁**，产物仍只监听 127.0.0.1（上游行为）。

  打了之后监听地址从哪来？同样写进 startup.json：
      { "version": 1, "env": { "DSH_NEXT_WEB_HOST": "0.0.0.0" } }
  通配绑定时 /api 围栏**不会**自动信任别的机器，每个要用的入口都得登记：
      "DSH_WEB_TRUSTED_HOSTS": "[\"192.168.1.9\",\"139.9.73.189\"]"
  格式与上游 DSH_NEXT_TRUSTED_HOSTS 一致：JSON 数组字符串（env 只能存字符串，所以要转义引号）；
  也接受逗号分隔的 "192.168.1.9,139.9.73.189"，两种都认。格式写错会启动报错，不会静默放过。
  （172.16/192.168 这类局域网地址由桌面自己采样，公网/NAT 地址必须显式给。）

  ⚠️ 别在这里写具体网卡 IP：真正的单网卡绑定会打断主窗口 —— main.ts 的 WebSocket 桥把目标
  钉在 127.0.0.1，单网卡绑定后回环不再监听，窗口立刻连不上。要「只有某个地址能访问」，
  用 0.0.0.0 + DSH_WEB_TRUSTED_HOSTS 收窄围栏。

  别名为 -ListenAllInterfacesPatch / -WildcardListenPatch（语义更准确：监听所有**网卡**，
  不是「所有网段」）。

  注意：外部浏览器要能打开，还必须在 DSH NEXT 设置里勾选「允许在浏览器中打开」
  （browserAccess；它是 Desktop 自己的门，与 token 无关）。

.EXAMPLE
  pwsh -File .\build-next.ps1
  pwsh -File .\build-next.ps1 -Target package-dir -SkipSubmodule -ElectronVersion 44.4.5
  pwsh -File .\build-next.ps1 -HarnessVersion 0.2.1-rc.2 -PnpmVersion 11.28.5
  pwsh -File .\build-next.ps1 -Preview -ElectronVersion 44.9.2 -PnpmVersion 11.28.5
  pwsh -File .\build-next.ps1 -FixedTokenPatch -ListenAllInterfacesPatch
  # ↑ 只决定「打不打补丁」；IP / Token 另写到 exe 同级的 startup.json（见上）
#>
[CmdletBinding()]
param(
  [ValidateSet('build', 'package-dir', 'check', 'typecheck', 'test')]
  [string]$Target = 'package-dir',

  [switch]$SkipPull,
  [switch]$SkipSubmodule,
  [switch]$SkipInstall,
  [switch]$Preview,
  [switch]$KeepGoing,
  [switch]$NoProxy,
  [string]$Proxy = 'http://127.0.0.1:15715',

  # --- 三个版本覆盖参数：语义与 build.ps1 完全一致（'' = 未指定 = 跟随上游，不改写）---
  # ValidatePattern 允许空串（= 未指定），并挡住把 "-ElectronVersion 44" 这类半截版本号
  # 悄悄写进 package.json（_yarn install_ 会以一个很难读的解析错误收场）。
  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$ElectronVersion = '',

  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$HarnessVersion = '',

  [ValidatePattern('^(?:[0-9a-fA-F]{7,40})?$')]
  [string]$HarnessCommit = '',

  [ValidatePattern('^(?:\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)?$')]
  [string]$PnpmVersion = '',

  # --- 可控 Web 入口的两个**补丁开关**（不是值！）---
  # 只决定「要不要把这段代码能力编进产物」；IP / Token 写在 exe 同级的 startup.json 里，
  # 与编译无关，换值不必重编。两个开关都不给 = 产物与上游完全一致。
  [switch]$FixedTokenPatch,
  [Alias('ListenAllInterfacesPatch', 'WildcardListenPatch')]
  [switch]$ListenAllInterfacesPatch
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

# ---------------- 可控 Web 入口（两个补丁开关）----------------
# 两个开关各管一件事，都只决定「代码能力编不编进产物」，**不承载任何值**：
#
#   -FixedTokenPatch        [token]  让启动 token 可以从外部定住
#                                    改 dsh-client-connection 产物：config.launchToken ?? $env:DSH_WEB_TOKEN
#   -ListenAllInterfacesPatch  [listen] 允许绑定 0.0.0.0（本机所有网卡）
#                                    改 dsh-host-webserver / dsh-web-app 产物（放行通配 + URL 回落环 + 删 CLI 守卫），
#                                    外加 overlay-next\patches\index.ts.patch（Host 把 host 读成 DSH_NEXT_WEB_HOST）
#
# 值写在哪：exe 同级的 startup.json（或真实环境变量），**编译期不写死**，换 IP/Token 不必重编。
# 详见 BUILD_GUIDE.md 的「远端访问」一节。
#
# ⚠️ 两个开关都不给时，一层补丁都不打，产物保持上游行为（只监听回环 + 每次启动随机 token）。
#    唯一的例外是 startup-config 本身（overlay-next\src\startup-config.ts）：它是覆盖层的既有能力
#    （读 exe 同级的 startup.json），始终生效；它只是「允许」这三个 DSH_* 键，不代表补丁打了。
$script:WebAccessModule = Join-Path $script:Root 'tools\dsh-web-access.ps1'
if (-not (Test-Path -LiteralPath $script:WebAccessModule)) {
  throw "缺少补丁模块：$script:WebAccessModule"
}
. $script:WebAccessModule
$script:TokenPatchActive = [bool]$FixedTokenPatch
$script:ListenPatchActive = [bool]$ListenAllInterfacesPatch
# 任意一组要打就跑运行时补丁；具体打哪组由 -Groups 决定。
$script:WebAccessActive = $script:TokenPatchActive -or $script:ListenPatchActive
$script:WebAccessGroups = @()
if ($script:TokenPatchActive) { $script:WebAccessGroups += 'token' }
if ($script:ListenPatchActive) { $script:WebAccessGroups += 'listen' }

# 运行时：跟随上游（不再硬钉 0.1.7-rc.2）
# next 的 dsh 运行时由上游决定，三处必须一致：next 工作区声明的 @deepseek-ai/dsh 版本、
# 根 package.json 的 resolutions 里该版本 → file:vendor/dsh-runtime/<ver>/... 的映射、
# vendor\dsh-runtime\<ver> 目录本身。未指定 -HarnessVersion 时本脚本只校验并报告，
# 不改写依赖串；指定时才固定到该版本（见 Resolve-HarnessVersion / Set-HarnessVersionPinned）。
# 2026-09-29：上游把 next/beta 一律升到 0.2.0-rc.1，而旧代码仍把 next 的依赖串改写成
# 0.1.7-rc.2；resolutions 的键是带版本的（@deepseek-ai/dsh@npm:0.2.0-rc.1），降版本后
# 不再匹配 → install 会绕过 vendored 产物退到 npm 解析，且与按 0.2.0-rc.1 peer 构建的
# AA 产物（vendor\agents-anywhere）不一致。stable 通道仍由 build.ps1 钉 0.1.7-rc.2。
$script:HarnessRepository = 'https://github.com/deepseek-ai/deepseek-harness.git'

# ---------------- 版本覆盖参数（与 build.ps1 同款语义）----------------
# 三个参数都是「'' = 未指定 = 完全跟随上游、一个字都不改」。把「是否显式指定」单独记成
# *Active 布尔值，是为了区分「参数写成空串」与「参数根本没传」—— 后者才是跟随上游。
$script:ElectronOverride = $ElectronVersion
$script:ElectronOverrideActive = $MyInvocation.BoundParameters.ContainsKey('ElectronVersion') -and
  (-not [string]::IsNullOrWhiteSpace($ElectronVersion))

# ⚠️ 命名铁律（从 build.ps1 抄来的教训）：解析结果必须叫 $script:ResolvedRuntimeVersion /
# $script:ResolvedHarnessCommit，**绝不能写回 $script:HarnessVersion / $script:HarnessCommit**
# —— PowerShell 里参数就是脚本作用域变量，写回同名变量会把用户传的参数静默覆盖掉。
$script:HarnessVersionOverride = $HarnessVersion
$script:HarnessCommitOverride = $HarnessCommit
$script:HarnessOverrideActive = $MyInvocation.BoundParameters.ContainsKey('HarnessVersion') -and
  (-not [string]::IsNullOrWhiteSpace($HarnessVersion))
$script:ResolvedRuntimeVersion = $null      # Resolve-HarnessVersion 写入
$script:ResolvedHarnessCommit = $null
$script:DeclaredRuntimeVersion = $null      # next 工作区自己声明的版本（上游权威来源）

$script:PnpmOverride = $PnpmVersion
$script:PnpmOverrideActive = $MyInvocation.BoundParameters.ContainsKey('PnpmVersion') -and
  (-not [string]::IsNullOrWhiteSpace($PnpmVersion))
# pnpm 补丁的存放处：与 stable 共用 overlay\pnpm\（补丁本身是按版本策展的，与通道无关）。
# 不用 overlay-next\patches\：那里是「对已跟踪文件 git apply」的机制，而 pnpm 补丁是 Yarn
# patch: 协议的产物，必须原样落到 <src>\patches\ 供根 resolutions 引用。
$script:PnpmPatchSourceDir = Join-Path $script:Root 'overlay\pnpm'


# 本脚本不构建的工作区（只让它们不参与编译/打包）—— 现在是空的：**一个都不能排除**。
# 2026-10-24 上游 ba41476b10（"migrate dsh-plugin-desktop-beta to dsh-desktop-next
# framework"）把 next 的渲染层依赖整体翻到了 stable 一侧，于是 next 同时需要 beta 和
# stable 的 node_modules：
#   1) 渲染层：dsh-desktop-next/vite.client.config.ts 现在 re-export
#      ../dsh-plugin-desktop/vite.client.config.ts（此前是 ../dsh-plugin-desktop-beta/…），
#      编译的是 dsh-plugin-desktop/src/client/*.tsx —— 那些文件按 Node 解析顺序从自己
#      目录往上找 node_modules，永远走不到 dsh-desktop-next/node_modules（不在上溯路径上）。
#   2) 打包脚本：next 的 scripts/package.ts、verify-fuses.ts、prepare-runtime.ts、
#      mac-runtime.ts 共 10+ 处 import 来自 ../../dsh-plugin-desktop/scripts/*。
#   3) beta：仍是 next 的共享组件来源（native-ui "Shared components live in another
#      workspace"），dshmarket / AA 的两处工作区校验也以它为准。
# 排除 stable 的后果（2026-10-24 实测）：yarn install 会把它已有的 node_modules
# 一并删掉，接着 [11] 客户端构建直接失败：
#   Rolldown failed to resolve import "lucide-react" from
#   .../dsh-plugin-desktop/src/client/DesktopNativeActions.tsx
# 代价是 install 会连 stable 的依赖一起装（约 +1.6 GB / +1~2 分钟）；这是上游布局
# 决定的必需开销，不能靠"少装一个工作区"省掉。
$script:ExcludedWorkspaces = @()

# overlay-next：next 专属覆盖层（与 stable 的 overlay\ 隔离）
$script:OverlayDir = Join-Path $script:Root 'overlay-next'
# 新建文件（上游无此文件）：overlay-next\src\<basename> -> <工作区相对路径>
$script:OverlayFiles = @{
  'dsh-desktop-next/src/startup-config.ts'      = 'startup-config.ts'
  'dsh-desktop-next/tests/startup-config.spec.ts' = 'startup-config.spec.ts'
  # 主窗口位置/大小持久化：上游没有这个模块，main.ts 补丁里 import './window-state.ts'。
  # ⚠️ 它**只能**以「新建文件」交付：dsh-desktop\ 是被本仓库 gitignore 的独立仓库，
  #    写在那边的文件既不进本仓库、换机器/重新克隆后也不存在 —— 那样补丁会剩下一句
  #    指向空处的 import（TS2307），构建直接失败。2026-10-21 复盘时就是这样差点漏推。
  'dsh-desktop-next/src/window-state.ts'         = 'window-state.ts'
  'dsh-desktop-next/tests/window-state.spec.ts'  = 'window-state.spec.ts'
}
# 已跟踪文件的修改：overlay-next\patches\<basename>.patch
$script:OverlayPatches = @(
  'dsh-desktop-next/src/main.ts'
  # 主窗口几何回归用例：main.ts 的窗口状态接线需要假 Electron 提供窗口几何 API
  # （isMaximized/maximize/getNormalBounds/screen），否则每个主窗口用例都会中断。
  'dsh-desktop-next/tests/main-lifecycle.spec.ts'
  # 可控 Web 入口（监听地址 / Token）的第一半：Host 把 webserver 的 host 从写死的
  # 127.0.0.1 改成读 DSH_NEXT_WEB_HOST，并把绑定地址/额外入口登记进 connection.trustedHosts。
  # ⚠️ 补丁文件名由 basename 决定，所以是 index.ts.patch（指 src\host\index.ts）。
  # 另一半是 tools\dsh-web-access.ps1 改的 @deepseek-ai 运行时产物，两半缺一不可。
  'dsh-desktop-next/src/host/index.ts'
)

# 只应用、不自动导出的补丁目标（Export-Overlay 会跳过）：
# host\index.ts 是上游高频改动点，且它的本地改动里可能混着别人的实验性修改 ——
# 让它自动导出，一次误改就会把策展补丁覆盖成半成品。改它就手工重生成补丁。
$script:OverlayPatchesApplyOnly = @(
  'dsh-desktop-next/src/host/index.ts'
)

# 「监听所有网卡」补丁的**源码侧**那一半：只有给了 -ListenAllInterfacesPatch 才应用。
#   host\index.ts 让 webserver 的 host 读 DSH_NEXT_WEB_HOST、并把绑定地址登记进 trustedHosts。
#   另一半是 tools\dsh-web-access.ps1 的 listen 组（dsh-host-webserver / dsh-web-app 产物）——
#   两半缺一不可：只改源码不改产物，通配地址仍会被上游守卫拒掉。
#   （固定 Token 补丁只有产物那一半，不涉及工作区源码。）
$script:OverlayPatchesRequireListenAllNetwork = @(
  'dsh-desktop-next/src/host/index.ts'
)
# 二进制资源：把本仓库 build\ 里的托盘图标覆盖到 next 的 assets\。
#   为什么必须走这一步：它们是 **git 跟踪文件**，[01]/[02] 拉源码时的 checkout --force 会把
#   手工替换的版本无条件抹掉（2026-10-21 实测：手改 deploy 目录 → 部署一次就回到旧图）；
#   而 PNG 既进不了 git patch，也不适合 base64 塞进补丁。所以每次构建在覆盖层里按字节重放。
#   目标 = 运行时真正读取的路径（lib/main.js: unpackedPath(join(root,'assets',
#   platform==='darwin' ? 'tray-iconTemplate.png' : 'tray-icon-blue.png'))）。
$script:OverlayAssets = [ordered]@{
  # 目标（工作区相对路径）                              = 源（相对本仓库根）
  'dsh-desktop-next/assets/tray-icon-blue.png'          = 'build/tray-icon-blue.png'
  'dsh-desktop-next/assets/tray-icon-blue@1.25x.png'    = 'build/tray-icon-blue@1.25x.png'
  'dsh-desktop-next/assets/tray-icon-blue@1.5x.png'     = 'build/tray-icon-blue@1.5x.png'
  'dsh-desktop-next/assets/tray-icon-blue@2x.png'       = 'build/tray-icon-blue@2x.png'
}

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
#   lib/main.js 必须含 startup-config 的集成点（否则 exe 同级的 startup.json 不会被读）；
#   同一条目里的 DSH_WEB_TOKEN 来自 startup-config 的白名单字面量，与补丁无关、恒存在。
$script:RequiredMarkers = @{
  'lib/main.js'                                                  = @('applyDesktopStartupConfig', 'DSH_WEB_TOKEN')
}

# 补丁专属断言：**只在该补丁被要求时才检查**。默认构建两个补丁都不打，产物里当然没有
# 这些标记 —— 按组判断，避免「没要的东西却报缺失」把人拦在产物核对那一步。
#   token  组：client-connection 产物里必须含 DSH_WEB_TOKEN（否则 startup.json 写了也只是随机值）
#   listen 组：lib/host.js 必须含监听地址读取点（否则 DSH_NEXT_WEB_HOST 写了没人看）
$script:RequiredMarkersWhenTokenPatch = @{
  'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'  = 'DSH_WEB_TOKEN'
}
$script:RequiredMarkersWhenListenPatch = @{
  'lib/host.js'                                                  = 'DSH_NEXT_WEB_HOST'
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

# ---------------- 可控 Web 入口 ----------------

<#
  把两个开关翻译成「要打哪个组」，并把「补丁打完之后你还需要自己做什么」提前讲清楚。
  放在最前面执行：让人在装依赖之前就知道这次构建会多出哪些代码能力。
  参数本身没有值可校验（IP / Token 不在构建期），所以这里不抛错，只报告。
#>
function Resolve-WebAccessPlan {
  if (-not $script:WebAccessActive) {
    Write-Info '可控 Web 入口：两个补丁都不打（未给 -FixedTokenPatch / -ListenAllInterfacesPatch）'
    Write-Info '  → 产物保持上游行为：只监听 127.0.0.1、启动 token 每次随机'
    return
  }
  $parts = New-Object System.Collections.Generic.List[string]
  if ($script:TokenPatchActive) { $parts.Add('- 固定 Token 补丁：代码会读 DSH_WEB_TOKEN') }
  if ($script:ListenPatchActive) { $parts.Add('- 监听所有网卡补丁：代码会读 DSH_NEXT_WEB_HOST（0.0.0.0）') }
  Write-Info ("可控 Web 入口（本次会打这些补丁）：`n  " + ($parts -join "`n  "))
  Write-Info '  注意：补丁只管「代码认这些变量」，具体 IP / Token 要你自己写进 exe 同级的 startup.json'
}

<#
  给 next 工作区（以及任何装了同一批运行时的 node_modules）打运行时补丁。
  install 之后、编译/打包之前执行：payload 里的 node_modules 是打包时从这棵树拷过去的。
  只打 $script:WebAccessGroups 里的组 —— 开关没给的组一行都不碰。
#>
function Invoke-WebAccessPatch {
  $roots = @(Find-DshWebAccessRoots -SearchRoot $script:Src)
  if ($roots.Count -eq 0) {
    throw "没找到可打补丁的 @deepseek-ai 包根（期望 <工作区>\node_modules\@deepseek-ai 下有 dsh-client-connection / dsh-host-webserver / dsh-web-app）。依赖装了吗？"
  }
  foreach ($root in $roots) {
    $result = Invoke-DshWebAccessPatch -PackagesRoot $root -Groups $script:WebAccessGroups
    foreach ($line in $result.Messages) { Write-Info $line }
    foreach ($file in $result.Written) { Write-Ok "运行时补丁：$file" }
  }
  Write-Ok ("可控 Web 入口的运行时补丁已就位（$($script:WebAccessGroups -join '、') · $($roots.Count) 处 node_modules）")
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
  # -HarnessVersion 生效时以解析出的 commit 为准（否则子模块会停在「上游声明那条线」上，
  # 与本次固定的运行时版本不一致 —— 只有需要重新生成 vendor 产物时才会真正用到子模块，
  # 但这种不一致最容易在事后排查时误导人）。
  if ($script:HarnessOverrideActive -and $script:ResolvedHarnessCommit) {
    if ($script:ResolvedHarnessCommit -ne $expected) {
      Write-WarnLine "子模块：按 -HarnessVersion $($script:ResolvedRuntimeVersion) 对齐到 $($script:ResolvedHarnessCommit.Substring(0,10))（上游 gitlink 是 $($expected.Substring(0,10))）"
    }
    $expected = $script:ResolvedHarnessCommit
  }
  $actual = (& git -C $sub rev-parse HEAD).Trim()
  if ($actual -ne $expected) {
    Write-Info "对齐 deepseek-harness 到 $(if ($script:HarnessOverrideActive -and $script:ResolvedHarnessCommit -eq $expected) { "-HarnessVersion 指定的" } else { '上游记录的' }) $($expected.Substring(0,10)) ..."
    & git -C $sub checkout --force $expected 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "子模块 checkout 失败 (exit $LASTEXITCODE)" }
  }
  if ($script:HarnessOverrideActive -and $script:ResolvedHarnessCommit -eq $expected) {
    Write-Ok "deepseek-harness = $($expected.Substring(0,10))（按 -HarnessVersion $($script:ResolvedRuntimeVersion) 对齐）"
  } else {
    Write-Ok "deepseek-harness = $($expected.Substring(0,10))（跟随上游 gitlink）"
  }
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
      if ($script:OverlayPatchesApplyOnly -contains $rel) {
        Write-Info "覆盖层：$rel 是只应用不导出的补丁，跳过导出"
        continue
      }
      $out = Join-Path $patchDir ("$([IO.Path]::GetFileName($rel)).patch")
      $tmp = "$out.tmp"
      # ⚠️ 必须让 git 自己把差异写成文件（--output）：把 git 的标准输出读进 PowerShell
      # 字符串再写回，会按控制台代码页（中文 Windows 是 GBK）解码本该是 UTF-8 的差异内容，
      # 于是上下文里的中文和全角标点全变成乱码，补丁之后再也打不上。
      # 2026-10-27 的 overlay-next\patches\main.ts.patch 就是这样被毁掉的（整个文件变成
      # 只剩乱码的删除补丁）。
      $prevNative = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
      try {
        & git diff --output=$tmp -- $rel
        $diffCode = $LASTEXITCODE
      } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
      }
      if ($diffCode -ne 0) {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        continue
      }
      if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -eq 0) {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        continue
      }
      # 「整文件删除」的差异绝不能当成策展内容保存：工作区里该文件被删掉（或换成了别的
      # 东西）时 git diff 就是一份删除补丁，存下来等于让下一次构建把上游整个文件删掉。
      # 这种状态一律判定为异常，丢弃导出的临时文件、保留仓库里已有的补丁。
      $text = [System.IO.File]::ReadAllText($tmp)
      if ($text -match '(?m)^deleted file mode ') {
        Write-WarnLine "覆盖层：$rel 的本地改动是整文件删除（异常状态），保留原补丁不覆盖"
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        continue
      }
      [System.IO.File]::WriteAllText($out, ($text -replace "`r`n", "`n"))
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
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

      # 监听所有网卡补丁的源码侧：没给 -ListenAllInterfacesPatch 就不应用。
      # 顺手撤掉上一轮可能残留的改动 —— 正常流程里 Update-SourceRepository 的
      # `git checkout --force` 会清干净，但 -SkipPull 复用旧工作区时它不会跑。
      if ($script:OverlayPatchesRequireListenAllNetwork -contains $rel -and -not $script:ListenPatchActive) {
        if (Test-Path -LiteralPath $patch) {
          $prevNative = $PSNativeCommandUseErrorActionPreference
          $PSNativeCommandUseErrorActionPreference = $false
          try {
            & git apply --reverse --check $patch 2>$null
            if ($LASTEXITCODE -eq 0) {
              & git apply --reverse $patch 2>$null
              if ($LASTEXITCODE -eq 0) {
                Write-WarnLine "覆盖层：未给 -ListenAllInterfacesPatch，已撤销 $rel 上残留的补丁"
              } else {
                Write-WarnLine "覆盖层：撤销 $rel 的残留补丁失败（工作区可能有别的改动），请手工确认"
              }
            }
          } finally {
            $PSNativeCommandUseErrorActionPreference = $prevNative
          }
        }
        Write-Info "覆盖层：未给 -ListenAllInterfacesPatch，跳过 $rel（监听所有网卡的 Host 补丁）"
        continue
      }

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

    # 3) 二进制资源：按字节覆盖（PNG 不能走 patch）
    #    ⚠️ 局部变量一律用 $icon* 前缀：PowerShell 变量名不区分大小写，脚本级 $script:Src
    #    与一个裸 $src 同名会让赋值互相覆盖（本文件 2026-10-21 已在 $Target/$target 上踩过
    #    一次同类坑），这里刻意避开。
    foreach ($rel in $script:OverlayAssets.Keys) {
      $iconSrcRel = $script:OverlayAssets[$rel]
      $iconSrc = Join-Path $script:Root ($iconSrcRel -replace '/', [IO.Path]::DirectorySeparatorChar)
      $iconDst = Join-Path $script:Src ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $iconSrc)) {
        throw "覆盖层缺少资源文件：$iconSrc（托盘图标源应放在本仓库 build\ 下）"
      }
      if ((Test-Path -LiteralPath $iconDst) -and
        ((Get-FileHash -LiteralPath $iconSrc -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $iconDst -Algorithm SHA256).Hash)) {
        Write-Info "覆盖层：$(Split-Path -Leaf $iconDst) 已是 build\ 那一份（跳过）"
        continue
      }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $iconDst) | Out-Null
      Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
      Write-WarnLine "覆盖层：已用 $iconSrcRel 替换 $rel（$((Get-Item -LiteralPath $iconSrc).Length) B）"
    }
    Write-Ok '覆盖层已应用（next 通道）'
  } finally {
    Pop-Location
  }
}

# ---------------- 工作区 / 版本固定 ----------------

function Set-WorkspaceSelection {
  # next 必须出现在根 workspaces 里，否则 yarn install 不装它的依赖。
  # 其余工作区默认全部保留（见 $script:ExcludedWorkspaces 的说明：next 现在同时需要
  # stable 的渲染层源码与打包脚本依赖，排除任何一个都会在 [11] 客户端构建失败）。
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

# ---------------- 运行时版本（-HarnessVersion / -HarnessCommit）----------------

function Get-UpstreamChannelByRuntimeVersion {
  # 在 upstream.json 里找「声明了这个运行时版本」的通道（stable / beta …）。
  # 用途：-HarnessVersion 的目标版本若正好是上游某条线，commit 直接取 upstream.json，
  # 不必去打远端查标签。返回 @{ Name; Commit; Package } 或 $null。
  param([Parameter(Mandatory)][string]$Version)
  $upPath = Join-Path $script:Src 'upstream.json'
  if (-not (Test-Path -LiteralPath $upPath)) { return $null }
  $up = Get-JsonObject $upPath
  if (-not ($up.PSObject.Properties.Name -contains 'channels')) { return $null }
  foreach ($chName in @($up.channels.PSObject.Properties.Name)) {
    $ch = $up.channels.PSObject.Properties[$chName].Value
    if (-not $ch) { continue }
    if ([string]$ch.sourceVersion -ne $Version) { continue }
    $commit = ''
    if ($ch.PSObject.Properties.Name -contains 'commit') { $commit = [string]$ch.commit }
    $pkg = ''
    if ($ch.PSObject.Properties.Name -contains 'package') { $pkg = [string]$ch.package }
    return @{ Name = $chName; Commit = $commit; Package = $pkg }
  }
  return $null
}

function Resolve-HarnessCommitFromTag {
  # 版本 → commit：查 deepseek-harness 的标签 dsh-v<版本>。
  #   1) 本地子模块优先（离线、无网络开销）；2) 远端 ls-remote 兜底。
  # 解析不出来返回 $null，由调用方决定报错还是告警。
  param([Parameter(Mandatory)][string]$Version)
  $tag = "dsh-v$Version"
  # 探测期间关掉「原生命令非零退出即终止」：标签不存在 / 远端不可达都是**预期内失败**，
  # 不关掉的话 git 的非零退出会直接抛成终止性错误，下面的降级逻辑根本没机会跑。
  $prevNative = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
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

function Resolve-HarnessVersion {
  # 决定本次构建用的 dsh 运行时版本（源码同步之后、任何依赖安装 / 覆盖层之前调用）。
  #   -HarnessVersion 未指定 → 跟随上游：next 工作区声明的 @deepseek-ai/dsh 版本，不改写。
  #   -HarnessVersion 指定   → 固定到该版本。commit 取值优先级：
  #       1) -HarnessCommit 显式给出（与标签核对，不一致只告警 —— 上游会前移同一版本的 commit）
  #       2) 该版本正好是 upstream.json 某条通道的 sourceVersion → 用它的 commit
  #       3) 标签 dsh-v<版本>（Resolve-HarnessCommitFromTag，本地子模块优先、远端兜底）
  #   显式指定的版本必须已有 vendor\dsh-runtime\<版本>\manifest.json：否则固定出来的是
  #   「依赖指向不存在的产物」的半成品，install 会以一个很难读的解析错误收场 —— 这里提前拦住。
  $declared = Get-NextDeclaredRuntime
  $script:DeclaredRuntimeVersion = $declared

  if (-not $script:HarnessOverrideActive) {
    $script:ResolvedRuntimeVersion = $declared
    $script:ResolvedHarnessCommit = $null
    if ($declared) {
      $ch = Get-UpstreamChannelByRuntimeVersion -Version $declared
      if ($ch -and $ch.Commit) { $script:ResolvedHarnessCommit = $ch.Commit }
      $short = if ($script:ResolvedHarnessCommit) { $script:ResolvedHarnessCommit.Substring(0, [Math]::Min(12, $script:ResolvedHarnessCommit.Length)) } else { '(上游未声明 commit)' }
      Write-Info "dsh 运行时：沿用上游声明 $declared（commit $short）—— 未指定 -HarnessVersion，不改写依赖。"
    } else {
      Write-WarnLine '未读到 next 工作区的 @deepseek-ai/dsh 声明（上游格式变化？），跳过运行时版本解析（-HarnessVersion 仍可用）。'
    }
    return
  }

  $v = $script:HarnessVersionOverride
  $manifestPath = Join-Path $script:Src ("vendor\dsh-runtime\$v\manifest.json")
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    $vendored = @()
    $dir = Join-Path $script:Src 'vendor\dsh-runtime'
    if (Test-Path -LiteralPath $dir) { $vendored = @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object { $_.Name }) }
    throw "运行时版本 $v 的 vendor 产物缺失：$manifestPath（已 vendored 的版本：$($vendored -join '、')）。" +
      '先运行 yarn upstream:prepare-runtime 生成该版本的 vendor/dsh-runtime，或换一个已 vendored 的版本。'
  }

  $c = $script:HarnessCommitOverride
  $explicitCommit = -not [string]::IsNullOrWhiteSpace($script:HarnessCommitOverride)
  if (-not $c) {
    $ch = Get-UpstreamChannelByRuntimeVersion -Version $v
    if ($ch -and $ch.Commit) {
      $c = $ch.Commit
      Write-Info "dsh 运行时：-HarnessVersion $v 是 upstream.json 的 $($ch.Name) 通道 → commit 取上游 $($c.Substring(0, [Math]::Min(12, $c.Length)))"
    }
  }
  if (-not $c) {
    $c = Resolve-HarnessCommitFromTag -Version $v
    if (-not $c) {
      throw "-HarnessVersion $v 未能解析出 deepseek-harness commit：upstream.json 没有该版本，标签 dsh-v$v 在本地子模块与远端 $($script:HarnessRepository) 也没查到。" +
        '请核对版本号拼写，或用 -HarnessCommit <sha> 显式指定。'
    }
    Write-Ok "dsh 运行时：-HarnessVersion $v → commit 取自标签 dsh-v$v：$($c.Substring(0, [Math]::Min(12, $c.Length)))"
  }
  if ($explicitCommit) {
    $tagSha = Resolve-HarnessCommitFromTag -Version $v
    if ($tagSha -and $tagSha -ne $c) {
      Write-WarnLine "dsh 运行时：-HarnessCommit $($c.Substring(0, [Math]::Min(12, $c.Length))) 与标签 dsh-v$v（$($tagSha.Substring(0, [Math]::Min(12, $tagSha.Length)))）不一致 —— 按参数值为准。"
    }
  }

  $script:ResolvedRuntimeVersion = $v
  $script:ResolvedHarnessCommit = $c
  if ($declared -and $declared -ne $v) {
    Write-WarnLine "dsh 运行时：next 工作区原本声明 $declared，本次按参数固定到 $v（依赖与会随之改写）。"
  }
  Write-Ok "dsh 运行时已解析：$v @ $($c.Substring(0, [Math]::Min(12, $c.Length)))"
}

function Get-HarnessLineSiblingWorkspace {
  # 上游为每条 harness 线各维护一个通道工作区（upstream.json 的 channels.*.package）。
  # 它的 package.json 就是该线配套依赖的权威版本表 —— 除了 @deepseek-ai/dsh*，还包括
  # @deepseek-ai/cordis*、@deepseek-ai/schemastery 这类**伴随包**（名字里没有 dsh，同样
  # 随 harness 线走）。返回 @{ Name = <工作区目录名>; Pkg = <package.json 对象> }；
  # 找不到（该版本不是上游任何通道的线）返回 $null。
  param([Parameter(Mandatory)][string]$Version)
  $upPath = Join-Path $script:Src 'upstream.json'
  if (-not (Test-Path -LiteralPath $upPath)) { return $null }
  $up = Get-JsonObject $upPath
  if (-not ($up.PSObject.Properties.Name -contains 'channels')) { return $null }
  foreach ($chName in @($up.channels.PSObject.Properties.Name)) {
    $ch = $up.channels.PSObject.Properties[$chName].Value
    if (-not $ch) { continue }
    if ([string]$ch.sourceVersion -ne $Version) { continue }
    $cand = ''
    if ($ch.PSObject.Properties.Name -contains 'package') { $cand = [string]$ch.package }
    if (-not $cand -or $cand -eq $script:WsName) { continue }
    $candPkgPath = Join-Path $script:Src (Join-Path $cand 'package.json')
    if (-not (Test-Path -LiteralPath $candPkgPath)) { continue }
    return @{ Name = $cand; Pkg = (Get-JsonObject $candPkgPath) }
  }
  return $null
}

function Set-HarnessVersionPinned {
  # 把 next 通道固定到 $script:ResolvedRuntimeVersion。三件事必须同时成立，否则 install 会
  # 静默绕过 vendored 产物：
  #   1) next 工作区的 @deepseek-ai/dsh* 依赖 = 目标版本   ← 决定性的一处（devDependencies 才决定安装）
  #   2) 伴随包（cordis / schemastery …）也随这条线走      ← 否则 Yarn 嵌套安装第二份副本 → TS6200
  #   3) 根 resolutions 有 "<包>@npm:<目标版本>" → file:vendor/dsh-runtime/<目标版本>/<tgz>
  # 第 3 步**只加不删**：beta 通道（next 直接 import 它的 src）仍在用旧版本的条目，
  # 删掉会让 beta 退到 registry 解析 —— 这一点与 stable（只有一个消费方）不同。
  $v = $script:ResolvedRuntimeVersion
  if (-not $v) { Write-WarnLine '未解析到运行时版本，跳过固定。'; return }
  if (-not $script:HarnessOverrideActive) {
    Write-Info "运行时版本跟随上游：dsh $v（不改写工作区依赖 / 根 resolutions）"
    return
  }
  $manifestPath = Join-Path $script:Src ("vendor\dsh-runtime\$v\manifest.json")
  if (-not (Test-Path -LiteralPath $manifestPath)) { throw "运行时版本 $v 的 vendor manifest 缺失：$manifestPath" }
  $manifest = Get-JsonObject $manifestPath
  $entryByName = @{}
  foreach ($p in @($manifest.packages)) { $entryByName[[string]$p.name] = [string]$p.filename }
  if ($entryByName.Count -eq 0) { throw "运行时 manifest 为空：$manifestPath" }

  $declared = $script:DeclaredRuntimeVersion
  if ($declared -eq $v) {
    # 目标就是 next 自己声明的版本：依赖无需改写。但仍核对根 resolutions 真的映射到
    # vendored 产物 —— 缺映射时 install 会退到 npm 解析（构建“成功”但装的不是本仓库产物）。
    $rootPkgPath = Join-Path $script:Src 'package.json'
    $rootText = [System.IO.File]::ReadAllText($rootPkgPath)
    $missing = @($entryByName.Keys | Where-Object { -not $rootText.Contains('"' + $_ + '@npm:' + $v + '"') })
    if ($missing.Count -gt 0) {
      Write-WarnLine "运行时固定：$v 与 next 声明一致（依赖无需改），但根 resolutions 缺 $($missing.Count) 条映射（install 可能退到 npm）：$(@($missing)[0]) 等"
    } else {
      Write-Ok "运行时固定：$v 与 next 声明的版本一致 —— 依赖与根 resolutions 均无需改写。"
    }
    return
  }

  # 1) 工作区依赖改写（**文本级**：保持上游原有排版，diff 只显示真正变化的行）
  #    为什么不走 ConvertTo-Json：它会把整份文件重排、并用 CRLF 写回，于是 git diff 变成
  #    “每行都变”，既掩盖真实改动，也会让后续按行锚定的注入（build 段的 appId / files 数组）
  #    失配 —— 2026-10-21 实测踩到过一次（buildVersion 注入因为行尾是 \r 而静默跳过）。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  $rewritten = New-Object System.Collections.Generic.List[string]
  # 只改「版本号形态」的值（[\^~]?\d 开头）：file: / workspace: / link: 之类的引用不动。
  foreach ($name in @($entryByName.Keys)) {
    $pattern = '("' + [regex]::Escape($name) + '"\s*:\s*")[\^~]?\d[^"]*(")'
    $candidate = [regex]::Replace($text, $pattern, "`${1}$v`${2}")
    if ($candidate -ne $text) {
      $rewritten.Add($name)
      $text = $candidate
    }
  }

  # 2) 伴随依赖：照抄「与 $v 同线的兄弟通道工作区」里同名包的版本，不动其余依赖。
  $sibling = Get-HarnessLineSiblingWorkspace -Version $v
  if ($sibling) {
    foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
      $sibProp = $sibling.Pkg.PSObject.Properties[$field]
      if (-not $sibProp -or $null -eq $sibProp.Value) { continue }
      foreach ($name in @($sibProp.Value.PSObject.Properties.Name)) {
        if (-not $name.StartsWith('@deepseek-ai/')) { continue }
        if ($name -eq '@deepseek-ai/dsh' -or $name.StartsWith('@deepseek-ai/dsh-')) { continue }  # 已由 1) 处理
        $sibVal = $sibProp.Value.$name
        if ($sibVal -isnot [string] -or -not $sibVal) { continue }
        $pattern = '("' + [regex]::Escape($name) + '"\s*:\s*")[^"]*(")'
        $candidate = [regex]::Replace($text, $pattern, "`${1}$sibVal`${2}")
        if ($candidate -ne $text) {
          Write-WarnLine "伴随依赖迁移（$($sibling.Name) 线）：$name → $sibVal"
          $rewritten.Add($name)
          $text = $candidate
        }
      }
    }
  } else {
    # 没有同线兄弟工作区 = 上游只声明了别的线的通道（upstream.json 只有 stable / beta）。
    # 伴随包的版本这时无处可抄，只能保持原样 —— 明确点名，别让人以为“固定成功”了。
    $companions = @()
    $before = [System.IO.File]::ReadAllText($pkgPath) | ConvertFrom-Json
    foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
      $prop = $before.PSObject.Properties[$field]
      if (-not $prop -or $null -eq $prop.Value) { continue }
      foreach ($name in @($prop.Value.PSObject.Properties.Name)) {
        if (-not $name.StartsWith('@deepseek-ai/')) { continue }
        if ($name -eq '@deepseek-ai/dsh' -or $name.StartsWith('@deepseek-ai/dsh-')) { continue }
        $companions += "$name=$($prop.Value.$name)"
      }
    }
    Write-WarnLine "运行时固定：upstream.json 里没有与 $v 同线的其他通道工作区 → 伴随依赖无法抄版本，保持原样：" +
      "$($companions -join '、')（若这些版本不属于 $v 那条线，Yarn 会嵌套安装第二份副本，类型门禁可能以 TS6200 失败）"
  }

  if ($rewritten.Count -gt 0) {
    [System.IO.File]::WriteAllText($pkgPath, $text)
    Write-WarnLine "运行时版本固定：$($script:WsName)\package.json 的 $($rewritten.Count) 个 @deepseek-ai/* 依赖 → $v"
  }

  # 2b) 目标版本的 manifest 里没有的同名包会**保持原版本**。跨线固定时这很致命（install 会
  #     去 registry 拉那个包，或干脆解析失败），所以明确列出来，而不是让人事后猜。
  $leftover = @()
  try {
    $after = [System.IO.File]::ReadAllText($pkgPath) | ConvertFrom-Json
    foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')) {
      $prop = $after.PSObject.Properties[$field]
      if (-not $prop -or $null -eq $prop.Value) { continue }
      foreach ($name in @($prop.Value.PSObject.Properties.Name)) {
        $isDsh = ($name -eq '@deepseek-ai/dsh') -or $name.StartsWith('@deepseek-ai/dsh-')
        if ($isDsh -and -not $entryByName.ContainsKey($name)) { $leftover += "$name=$($prop.Value.$name)" }
      }
    }
  } catch {
    throw "改写后的 $pkgPath 不是合法 JSON：$($_.Exception.Message)"
  }
  if ($leftover.Count -gt 0) {
    Write-WarnLine "运行时固定：next 声明的 $($leftover.Count) 个 @deepseek-ai/dsh* 包在 $v 的 manifest 里不存在，保持原版本：$($leftover -join '、')"
    Write-WarnLine '        ⇒ 跨线固定时这些包会去 registry 解析（或直接解析失败）。若要用这条线，先确认上游在同线上确实有这些包。'
  }

  # 3) 根 resolutions：为该版本补 @npm:<v> / @npm:^<v> 两条。**只加不删**：beta 通道
  #    （next 直接 import 它的 src）仍在用旧版本的条目，删掉会让 beta 退到 registry 解析 ——
  #    这一点与 stable（只有一个消费方）不同。文本插入而非 JSON 重写，理由同 1)。
  $rootPkgPath = Join-Path $script:Src 'package.json'
  $rootText = [System.IO.File]::ReadAllText($rootPkgPath)
  $vendorRelative = "vendor/dsh-runtime/$v"
  $anchor = [regex]::Match($rootText, '(?m)^(?<ind>[ \t]*)"@deepseek-ai/dsh[^"]*@npm:[^"]+"\s*:')
  if (-not $anchor.Success) {
    throw "未在根 package.json 的 resolutions 中找到 @deepseek-ai/dsh 映射行（上游格式变化？），无法为 $v 补 resolutions：$rootPkgPath"
  }
  $nl = if ($rootText.Contains("`r`n")) { "`r`n" } else { "`n" }
  $ind = $anchor.Groups['ind'].Value
  $insert = New-Object System.Text.StringBuilder
  $added = 0; $present = 0; $patched = 0
  foreach ($name in @($entryByName.Keys | Sort-Object)) {
    $file = $entryByName[$name]
    $unscoped = $name.Substring('@deepseek-ai/'.Length)
    $patchRel = "patches/$unscoped@$v.patch"
    $patchPath = Join-Path $script:Src ($patchRel -replace '/', [IO.Path]::DirectorySeparatorChar)
    $fileSpec = "file:$vendorRelative/$file"
    $val = if (Test-Path -LiteralPath $patchPath) {
      $patched++
      "patch:$name@$($fileSpec -replace ':', '%3A')#./$patchRel"
    } else { $fileSpec }
    foreach ($sel in @("$name@npm:$v", "$name@npm:^$v")) {
      if ($rootText.Contains('"' + $sel + '"')) { $present++; continue }
      [void]$insert.Append("$ind`"$sel`": `"$val`",$nl")
      $added++
    }
  }
  if ($added -gt 0) {
    $rootText = $rootText.Insert($anchor.Index, $insert.ToString())
    [System.IO.File]::WriteAllText($rootPkgPath, $rootText)
    try { $null = [System.IO.File]::ReadAllText($rootPkgPath) | ConvertFrom-Json }
    catch { throw "改写后的根 package.json 不是合法 JSON：$($_.Exception.Message)" }
  }
  Write-Ok "运行时版本已固定：dsh $v（$($entryByName.Count) 个包；resolutions 新增 $added 条、已存在 $present 条，其中 $patched 个包带版本补丁）"
}

function Test-NextRuntimeVersion {
  # 三处一致性校验（只读）：① vendor 产物 ② 根 resolutions 映射 ③ 与 upstream.json 通道声明对照。
  # -HarnessVersion 生效时校验的是**目标版本**，且跳过 ③（那一步只在“跟随上游”时才有意义）。
  $v = $script:ResolvedRuntimeVersion
  if (-not $v) { $v = Get-NextDeclaredRuntime }
  if (-not $v) {
    Write-WarnLine '未读到运行时版本（上游格式变化？），跳过运行时校验。'
    return
  }
  $source = if ($script:HarnessOverrideActive) { '-HarnessVersion 指定' } else { 'next 工作区声明' }

  # ① vendored 运行时目录
  $manifest = Join-Path $script:Src ("vendor\dsh-runtime\$v\manifest.json")
  if (Test-Path -LiteralPath $manifest) {
    Write-Info "运行时：$source $v，vendor\dsh-runtime\$v 已就位"
  } else {
    Write-WarnLine "运行时：vendor\dsh-runtime\$v\manifest.json 缺失（install 会退到 npm 解析）"
  }

  # ② 根 resolutions 是否把该版本映射到 vendored 产物
  $rootPkgPath = Join-Path $script:Src 'package.json'
  if (Test-Path -LiteralPath $rootPkgPath) {
    $rootText = Get-Content -LiteralPath $rootPkgPath -Raw -Encoding utf8
    $key = '"@deepseek-ai/dsh@npm:' + $v + '"'
    if ($rootText.Contains($key)) {
      Write-Info "运行时：根 resolutions 已把 @deepseek-ai/dsh@npm:$v 指向 vendored 产物"
    } else {
      Write-WarnLine "运行时：根 resolutions 没有 @deepseek-ai/dsh@npm:$v 的映射（install 可能走 npm）"
    }
  }

  # ③ 与 upstream.json 的通道声明对照（只为发现上游自身不一致；固定版本时不适用）
  if (-not $script:HarnessOverrideActive) {
    $upPath = Join-Path $script:Src 'upstream.json'
    if (Test-Path -LiteralPath $upPath) {
      $up = Get-JsonObject $upPath
      if ($up.channels.PSObject.Properties.Name -notcontains 'next') {
        Write-Info '运行时：upstream.json 无 next 通道条目（上游未把 next 纳入通道表），以工作区声明为准'
      }
      $betaVer = $null
      if ($up.channels.beta) { $betaVer = $up.channels.beta.sourceVersion }
      if ($betaVer -and $betaVer -ne $v) {
        Write-WarnLine "运行时：next 声明 $v，而 upstream.json 的 beta 通道是 $betaVer（上游 desktop 家族版本不一致，请确认是否预期）"
      }
    }
  }

  Write-Ok "运行时已确定：dsh $v（$source）"
}

# ---------------- 覆盖参数：electron / pnpm 版本 ----------------

function Set-ElectronOverride {
  # next 工作区 devDependencies.electron → $script:ElectronOverride。
  # **未指定 -ElectronVersion 时完全不改写**（构建上游原样）；上游声明已与目标一致时同样跳过。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  if ($text -notmatch '("electron"\s*:\s*")([^"]+)(")') {
    Write-WarnLine '覆盖层：next\package.json 中未找到 electron 声明，跳过版本覆盖。'
    return
  }
  $current = $Matches[2]
  if (-not $script:ElectronOverrideActive) {
    Write-Info "electron 使用上游声明版本（$current）：未指定 -ElectronVersion，跳过版本覆盖。"
    return
  }
  if ($current -eq $script:ElectronOverride) {
    Write-Info "electron 上游声明已与覆盖目标一致（$current），跳过版本覆盖。"
    return
  }
  # 注意：这里**不传**[regex]::Replace 的第 4 个参数。看着像“只替换第一处（count=1）”的那个
  # 位置实际是 RegexOptions（传 1 = IgnoreCase）—— 旧写法会连同 peerDependencies 一起改写
  # （恰好是需要的：devDependencies 才决定实际安装的版本）。显式写成“替换全部”。
  $fixed = [regex]::Replace($text, '("electron"\s*:\s*")([^"]+)(")', "`${1}$($script:ElectronOverride)`${3}")
  [System.IO.File]::WriteAllText($pkgPath, $fixed)
  Write-WarnLine "覆盖层：next electron $current → $($script:ElectronOverride)"
}

function Set-PnpmOverride {
  # next 工作区 dependencies.pnpm → $script:PnpmOverride，并把根 resolutions 的 pnpm 补丁条目
  # 补到同一版本。**未指定 -PnpmVersion 时完全不改写**；上游声明已一致时同样跳过。
  # 指定了不同版本时，下面三件事必须同时成立，否则 age-gate 修复会**静默**消失：
  #   1) 依赖版本 = 目标版本                                    ← 第 1 段
  #   2) <src>\patches\pnpm@<目标>.patch 存在（从 overlay\pnpm\ 拷入）  ← 第 2 段
  #   3) 根 resolutions 里有 "pnpm@npm:<目标>": "patch:…" 条目            ← 第 3 段
  # 为什么 2) 3) 不能省：resolution 键是**版本化**的（"pnpm@npm:11.8.0"）。把依赖换成别的版本后，
  # 原键不再匹配任何依赖 → Yarn 不再打补丁，**而且不报错** —— node_modules 里就是未打补丁的
  # 原版，Desktop 的 --config.minimumReleaseAge=0 缺陷随之复现（pnpm 11 把字符串 "0" 按 truthy
  # 处理）。这属于「构建成功但定制没生效」，必须避免。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  # 只匹配键恰为 "pnpm" 的条目：exports 里的 "./pnpm"（引号前是斜杠）不会命中。
  $pattern = '("pnpm"\s*:\s*")([^"]+)(")'
  if ($text -notmatch $pattern) {
    Write-WarnLine '覆盖层：next\package.json 中未找到 pnpm 依赖声明，跳过版本覆盖。'
    return
  }
  $current = $Matches[2]
  if (-not $script:PnpmOverrideActive) {
    Write-Info "pnpm 使用上游声明版本（$current）：未指定 -PnpmVersion，跳过版本覆盖。"
    return
  }
  if ($current -eq $script:PnpmOverride) {
    Write-Info "pnpm 上游声明已与覆盖目标一致（$current），跳过版本覆盖。"
    return
  }
  $fixed = [regex]::Replace($text, $pattern, "`${1}$($script:PnpmOverride)`${3}")
  [System.IO.File]::WriteAllText($pkgPath, $fixed)
  Write-WarnLine "覆盖层：next pnpm $current → $($script:PnpmOverride)"

  # --- 第 2 段：把该版本的策展补丁落到 <src>\patches\ ---
  $patchName = "pnpm@$($script:PnpmOverride).patch"
  $srcPatch = Join-Path $script:PnpmPatchSourceDir $patchName
  if (-not (Test-Path -LiteralPath $srcPatch)) {
    Write-WarnLine "覆盖层：缺少 $srcPatch —— 无法为 pnpm $($script:PnpmOverride) 重指 age-gate 补丁。"
    Write-WarnLine "        ⇒ 该版本的 pnpm 将以**未打补丁的原版**打包（最小发布年龄缺陷可能复现）。"
    Write-WarnLine '        ⇒ 补丁生成方法见 BUILD_GUIDE.md「pnpm 版本覆盖」：对该版本的 dist/pnpm.mjs 重新 diff。'
    return
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
      throw "未在根 package.json 的 resolutions 中找到 pnpm 补丁条目，无法为 $($script:PnpmOverride) 补上 resolution。请检查上游是否改写了该条目。"
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
}

# ---------------- Windows 版本资源（ProductVersion / FileVersion）----------------

function Get-WindowsVersionQuad {
  # semver → Windows 四段数字版本（x.y.z.0）。electron-builder 的
  # AppInfo.getVersionInWeirdWindowsForm() 就是这么算的（缺省段补 0，buildNumber 取配置文件里的
  # 或 0），这里复刻同一规则，好让注入值与 electron-builder 自己算出来的 ProductVersion 一致。
  param([Parameter(Mandatory)][string]$Version)
  $m = [regex]::Match($Version, '^(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value).0"
}

function Set-WindowsVersionInfo {
  # exe 的版本资源由 electron-builder 的 winPackager.signAndEditResources() 写入：
  #   fileVersion    = appInfo.shortVersion || appInfo.buildVersion
  #   productVersion = appInfo.shortVersionWindows || appInfo.getVersionInWeirdWindowsForm()
  # 本仓库的版本是**带预发布的 semver**（"2.0.19-next"）：
  #   · productVersion 走 getVersionInWeirdWindowsForm → "2.0.19.0"（正确）
  #   · fileVersion 却没有 shortVersion/buildVersion 可用 → 直接把 "2.0.19-next" 塞给
  #     resedit.setFileVersion()：字符串值变成 "2.0.19-next"，而**数字段（VS_FIXEDFILEINFO）
  #     退化成 2.0.0.0** —— 任务管理器 / FileVersionRaw / 部分安装器读的就是这个数字段。
  # 实测（X:\App\DSH-Next\DSH NEXT.exe）：
  #   FileVersion="2.0.19-next"  FileVersionRaw=2.0.0.0  ProductVersion="2.0.19.0"
  # 修法：给 build 段注入 buildVersion = <major>.<minor>.<patch>.0（electron-builder 的
  # 公开配置项，appInfo.buildVersion 优先于 version）。注入后两个字段都是 2.0.19.0，
  # 数字段与字符串值一致。
  # 为什么写在 build 段而不是 package.json 顶层 shortVersion：payload 的 package.json 是
  # 工作区那份的逐字拷贝（scripts/prepare-payload.ts 第 230 行），两处都能到 appInfo —— 但
  # build 段是 electron-builder 自己的配置，不受“manifest 转换”影响，且与 Set-PayloadExclusions
  # / Set-ElectronOverride 注入的是同一个文件、同一种机制，好定位。
  $pkgPath = Join-Path $script:WsDir 'package.json'
  $text = [System.IO.File]::ReadAllText($pkgPath)
  $vm = [regex]::Match($text, '(?m)^\s*"version"\s*:\s*"([^"]+)"')
  if (-not $vm.Success) { Write-WarnLine '版本信息：未找到 package.json 的 version 字段，跳过（exe 版本资源将沿用上游形态）。'; return }
  $semver = $vm.Groups[1].Value
  $quad = Get-WindowsVersionQuad -Version $semver
  if (-not $quad) {
    Write-WarnLine "版本信息：version '$semver' 不是 x.y.z 形态，跳过注入（exe 版本资源将沿用上游形态）。"
    return
  }

  $existing = [regex]::Match($text, '(?m)^(?<ind>[ \t]*)"buildVersion"\s*:\s*"(?<val>[^"]*)"')
  if ($existing.Success) {
    if ($existing.Groups['val'].Value -eq $quad) {
      Write-Info "版本信息：build.buildVersion 已是 $quad（与 version $semver 对齐）"
      return
    }
    $old = $existing.Groups['val'].Value
    $text = $text.Remove($existing.Groups['val'].Index, $existing.Groups['val'].Length).Insert($existing.Groups['val'].Index, $quad)
    [System.IO.File]::WriteAllText($pkgPath, $text)
    Write-WarnLine "版本信息：build.buildVersion $old → $quad"
    return
  }

  # 插到 build 段的 "appId" 行之后（该行在 next\package.json 里唯一且必在 build 段内）。
  # 行尾用 [ \t]*\r?$ 而不是 [ \t]*$：...\r 存在时 $ 只匹配到 \n 之前，普通 $ 会漏掉这一行。
  $anchor = [regex]::Match($text, '(?m)^(?<ind>[ \t]*)"appId"\s*:\s*"[^"]*",[ \t]*\r?$')
  if (-not $anchor.Success) {
    Write-WarnLine '版本信息：build 段没有 appId 可作锚点（上游格式变化？），跳过注入。'
    return
  }
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $ind = $anchor.Groups['ind'].Value
  $insertAt = $anchor.Index + $anchor.Length
  $text = $text.Insert($insertAt, "$nl$ind`"buildVersion`": `"$quad`",")
  [System.IO.File]::WriteAllText($pkgPath, $text)
  Write-WarnLine "版本信息：build.buildVersion = $quad（由 version $semver 推出；让 exe 的 ProductVersion/FileVersion 都是 $quad）"
}

# ---------------- 安装后核对（覆盖参数最容易“成功但没换版本”）----------------

function Test-InstalledElectron {
  # next 工作区（找不到再看仓库根，Yarn 可能提升）里已安装的 electron 版本
  foreach ($p in @((Join-Path $script:WsDir 'node_modules\electron\package.json'),
                   (Join-Path $script:Src 'node_modules\electron\package.json'))) {
    if (Test-Path -LiteralPath $p) { return (Get-JsonObject $p).version }
  }
  return $null
}

function Test-InstalledPnpm {
  foreach ($p in @((Join-Path $script:WsDir 'node_modules\pnpm\package.json'),
                   (Join-Path $script:Src 'node_modules\pnpm\package.json'))) {
    if (Test-Path -LiteralPath $p) { return (Get-JsonObject $p).version }
  }
  return $null
}

function Test-ElectronAddonSupport {
  # dsh 宿主用 node-addon-require-builtin 在 Electron 里 require Node 内置模块，而这个 addon 是
  # **按 V8 指纹**白名单放行的预编译二进制：表里没有的 Electron 版本，打包后的 Host 一启动就抛
  #   node-addon-require-builtin unsupported: Unsupported/no-context
  #   (unsupported Electron runtime fingerprint: Node 24.22.0, V8 15.2.124.43-electron.0
  #    (supported Electron versions: 43.0.0, 44.0.0, 44.7.0, 45.0.0-alpha.6))
  # 2026-10-21 实测：-ElectronVersion 44.9.2 就是这样在 afterAllArtifactBuild 的 Host 冒烟里失败的 ——
  # 编译、打包、afterPack 全部通过，只有最后那条最强验收能看出来。所以这里提前判定：
  # 白名单是从 addon 二进制里读出来的（版本号以明文串排列），读不到就只告警不拦。
  if (-not $script:ElectronOverrideActive) { return }
  $archTag = if ("$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)".ToUpperInvariant() -like '*ARM64*') { 'arm64' } else { 'x64' }
  $dir = Join-Path $script:WsDir "node_modules\node-addon-require-builtin-win32-$archTag-msvc\prebuilt"
  if (-not (Test-Path -LiteralPath $dir)) {
    Write-Info "electron 支持表：未找到 node-addon-require-builtin（win32-$archTag-msvc），跳过指纹核对。"
    return
  }
  $bin = Get-ChildItem -LiteralPath $dir -Filter '*.node' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $bin) { Write-Info 'electron 支持表：prebuilt 目录下没有 .node，跳过指纹核对。'; return }
  $bytes = [System.IO.File]::ReadAllBytes($bin.FullName)
  $text = [System.Text.Encoding]::Latin1.GetString($bytes)
  $versions = @([regex]::Matches($text, '(?<![\d.])([45][0-9]\.\d+\.\d+(?:-alpha\.\d+)?)(?![\d.])') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  if ($versions.Count -lt 2) {
    Write-WarnLine "electron 支持表：从 $($bin.Name) 里只读到 $($versions.Count) 个版本号，跳过指纹核对（避免误拦）。"
    return
  }
  # ⚠️ 变量名必须避开 $Target：PowerShell 不区分大小写，$target 与脚本参数 $Target 是同一个
  # 变量 —— 2026-10-21 实测踩到：写了 $target = <electron 版本>，把 $Target（package-dir）
  # 覆盖成版本号，导致下面的 throw 分支永远不成立，守卫只告警不拦。
  $electronTarget = $script:ElectronOverride
  if ($versions -contains $electronTarget) {
    Write-Ok "electron $electronTarget 在 dsh 原生 addon 的支持表里（$($versions -join '、')）"
    return
  }
  # 建议值取「支持表里最高的稳定版」——按字符串排序会把 45.0.0-alpha.6 排到最后，误导人去用 alpha。
  $stableSupported = @($versions | Where-Object { $_ -notmatch '-' } |
      Sort-Object -Property @{ Expression = { [version]$_ } } -Descending)
  $hint = if ($stableSupported.Count -gt 0) { "（推荐 -ElectronVersion $($stableSupported[0])）" } else { '' }
  $message = "electron $electronTarget 不在 dsh 原生 addon（node-addon-require-builtin）的支持表里：$($versions -join '、')$hint。" +
    '这种组合编译 / 打包都会“成功”，但打包后的 Host 一启动就抛 "node-addon-require-builtin unsupported: Unsupported/no-context"' +
    '（afterAllArtifactBuild 的 Host 冒烟会失败）。'
  if ($Target -eq 'package-dir') { throw $message }
  Write-WarnLine $message
}

function Test-InstalledOverrides {
  # 覆盖参数最典型的失败形态是「构建成功但版本没换」：install 没跑、锁文件没变、或者
  # pnpm 的版本化 resolution 没重指（补丁静默失效）。装完立刻核对，把它变成显式失败，
  # 而不是等到用户看见 exe 里还是旧版本才发现。
  $problems = New-Object System.Collections.Generic.List[string]
  if ($script:ElectronOverrideActive) {
    $got = Test-InstalledElectron
    if ($got -eq $script:ElectronOverride) {
      Write-Ok "已安装 electron $got（= -ElectronVersion 目标）"
    } else {
      $problems.Add("electron 已安装 '$got' ≠ 目标 '$($script:ElectronOverride)'")
    }
  }
  if ($script:PnpmOverrideActive) {
    $got = Test-InstalledPnpm
    if ($got -ne $script:PnpmOverride) {
      $problems.Add("pnpm 已安装 '$got' ≠ 目标 '$($script:PnpmOverride)'")
    } else {
      Write-Ok "已安装 pnpm $got（= -PnpmVersion 目标）"
      # 补丁是否真的打上了：resolution 是版本化键，写错就静默退回原版。
      $specs = @(
        (Join-Path $script:WsDir 'node_modules\pnpm\dist\pnpm.mjs'),
        (Join-Path $script:Src 'node_modules\pnpm\dist\pnpm.mjs')
      )
      $mjs = $specs | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      if ($mjs) {
        if ([System.IO.File]::ReadAllText($mjs).Contains('Number.isFinite(minimumReleaseAge)')) {
          Write-Ok 'pnpm age-gate 补丁已生效（dist/pnpm.mjs 含 Number.isFinite(minimumReleaseAge)）'
        } else {
          $problems.Add("pnpm $got 的 dist/pnpm.mjs 里没有 age-gate 补丁标记（根 resolutions 是否重指了该版本？）")
        }
      } else {
        Write-WarnLine '未找到 node_modules/pnpm/dist/pnpm.mjs（pnpm 12+ 是原生二进制），无法核对补丁标记。'
      }
    }
  }
  if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-WarnLine "版本核对：$p" }
    throw "覆盖参数未生效：$($problems -join '；')。请检查 yarn install 的输出与根 resolutions。"
  }
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
  # 注意（2026-10-15 修复）：内层表达式已经产出带引号的字面量（'dsh-plugin-desktop'），
  # 所以这里**不能再套一层引号** —— 旧写法 `['$(… )']` 会写出 `[''dsh-plugin-desktop'']`，
  # 那是 JS 语法错误；因为本次构建并不 import 这个文件（next 通道走的是工作区级
  # package:dir），错误会潜伏到下一次别的入口调用 `yarn market:prepare` 时才炸
  # （实测：stable 通道 package:dir 的第一步 market:prepare 直接 SyntaxError 退出）。
  $replacement = "export const MARKET_WORKSPACES_EXCLUDED = [$((($script:ExcludedWorkspaces | ForEach-Object { "'$_'" }) -join ', '))]`nexport const MARKET_WORKSPACES = [$keepList]"
  $original = $text
  $text = $text.Remove($anchor.Index, $anchor.Length).Insert($anchor.Index, $replacement)
  [System.IO.File]::WriteAllText($marketPath, $text)
  # 自检：注入结果必须是合法 JS，否则回滚为上游原样（宁可收缩失效也不要留下语法错误）。
  $prevNativeCheck = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $syntax = @(& node --check $marketPath 2>&1)
    $syntaxCode = $LASTEXITCODE
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prevNativeCheck
  }
  if ($syntaxCode -ne 0) {
    [System.IO.File]::WriteAllText($marketPath, $original)
    Write-WarnLine "dshmarket 校验工作区：注入后语法校验失败，已回滚为上游原样 —— $($syntax -join ' ')"
    return
  }
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

function Test-PeerRangeSatisfied {
  # 只用来判断「某个工作区里已装的那一份能不能顶上这个 peer」：先认完全相等，
  # 再认 ~ / ^ 前缀的「同 major.minor」。不是完整的 semver 解析 —— 这里的 peer 范围
  # 全是上游写死的精确版本或 ~x.y.z，够用且不会误判。
  param([string]$Version, [string]$Range)
  if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
  foreach ($part in ($Range -split '\|\|')) {
    $r = $part.Trim()
    if (-not $r) { continue }
    if ($r -eq $Version) { return $true }
    $prefix = $null
    if ($r.StartsWith('~') -or $r.StartsWith('^')) { $prefix = $r.Substring(1) }
    if (-not $prefix) { continue }
    $want = $prefix -split '\.'
    $have = $Version -split '\.'
    if ($want.Count -ge 2 -and $have.Count -ge 2 -and $have[0] -eq $want[0] -and $have[1] -eq $want[1]) { return $true }
  }
  return $false
}

function Repair-WorkspacePeers {
  # 为什么需要这一步（2026-10-28 上游 e7d0170dde 起）：
  #   dsh-community-market 把 75 个 @deepseek-ai/* 列进 devDependencies（0.2.2-alpha.2），
  #   而这些包彼此之间的 peerDependencies 并没有一起声明。yarn **从不自动安装 peer**，
  #   于是 market\node_modules\@deepseek-ai\dsh-agent 缺 19 个 peer（dsh-scope /
  #   dsh-system-prompt / dsh-fs …）。dsh-desktop-next\scripts\prepare-payload.ts 在收集
  #   生产闭包时把「非 optional 的 peer」当必装项，打包阶段直接失败：
  #     Next payload: dependency @deepseek-ai/dsh-scope required by @deepseek-ai/dsh-agent is not installed
  #   这是上游 devDependencies 的缺口，不是我们的覆盖层问题，也不该靠改上游源码去补。
  # 做法：install 之后，逐个工作区扫描已安装的 @deepseek-ai/* 包，发现 peer 在
  #   <包自身> / <工作区> / <仓库根> 三级 node_modules 里都解析不到时，从「别的已经装了
  #   同版本的工作区」复制一份过去（beta 装的就是 0.2.2-alpha.2，正好能顶 market 的那份）。
  # 只补缺、不覆盖已存在的包；找不到可用版本时只告警，让打包阶段报更具体的错。
  $wsDirs = @(Get-ChildItem -LiteralPath $script:Src -Directory | Where-Object {
      (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')) -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'node_modules'))
    })
  if ($wsDirs.Count -eq 0) { Write-Info '工作区 peer：未找到已安装的工作区，跳过。'; return }

  # 已安装副本索引：包名 -> @(@{ Version; Path })
  $installed = @{}
  foreach ($ws in $wsDirs) {
    $scopeDir = Join-Path $ws.FullName 'node_modules\@deepseek-ai'
    if (-not (Test-Path -LiteralPath $scopeDir)) { continue }
    foreach ($pkg in @(Get-ChildItem -LiteralPath $scopeDir -Directory)) {
      $manifest = Join-Path $pkg.FullName 'package.json'
      if (-not (Test-Path -LiteralPath $manifest)) { continue }
      $key = "@deepseek-ai/$($pkg.Name)"
      if (-not $installed.ContainsKey($key)) { $installed[$key] = @() }
      $installed[$key] += @{ Version = [string](Get-JsonObject $manifest).version; Path = $pkg.FullName }
    }
  }

  $repaired = 0
  $unresolved = @()
  foreach ($ws in $wsDirs) {
    $scopeDir = Join-Path $ws.FullName 'node_modules\@deepseek-ai'
    if (-not (Test-Path -LiteralPath $scopeDir)) { continue }
    foreach ($pkg in @(Get-ChildItem -LiteralPath $scopeDir -Directory)) {
      $manifest = Join-Path $pkg.FullName 'package.json'
      if (-not (Test-Path -LiteralPath $manifest)) { continue }
      $obj = Get-JsonObject $manifest
      if (-not ($obj.PSObject.Properties.Name -contains 'peerDependencies')) { continue }
      $meta = if ($obj.PSObject.Properties.Name -contains 'peerDependenciesMeta') { $obj.peerDependenciesMeta } else { $null }
      foreach ($name in @($obj.peerDependencies.PSObject.Properties.Name)) {
        if ($name -notlike '@deepseek-ai/*') { continue }
        if ($meta -and ($meta.PSObject.Properties.Name -contains $name) -and $meta.$name.optional -eq $true) { continue }
        $present = $false
        foreach ($candidate in @(
            (Join-Path $pkg.FullName "node_modules\$name"),
            (Join-Path $ws.FullName "node_modules\$name"),
            (Join-Path $script:Src "node_modules\$name"))) {
          if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { $present = $true; break }
        }
        if ($present) { continue }
        $range = [string]$obj.peerDependencies.$name
        $source = $null
        if ($installed.ContainsKey($name)) {
          $source = $installed[$name] | Where-Object { Test-PeerRangeSatisfied -Version $_.Version -Range $range } | Select-Object -First 1
        }
        if (-not $source) {
          $unresolved += "$name ($range) ← $($ws.Name)"
          continue
        }
        Copy-Item -LiteralPath $source.Path -Destination $scopeDir -Recurse -Force
        $installed[$name] += @{ Version = $source.Version; Path = (Join-Path $scopeDir ($name -replace '^@deepseek-ai/', '')) }
        $repaired++
      }
    }
  }
  if ($repaired -gt 0) {
    Write-WarnLine "工作区 peer：已从其它工作区补齐 $repaired 个缺失 peer（上游 devDependencies 没声明，yarn 不装 peer）"
  } else {
    Write-Info '工作区 peer：无需补齐'
  }
  if ($unresolved.Count -gt 0) {
    Write-WarnLine "工作区 peer：$($unresolved.Count) 个 peer 在任何工作区都找不到可用版本 —— $($unresolved -join '；')"
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
  # ⚠️ 这里只**原样拷贝模板**，不写任何 IP / Token —— 补丁开关不承载值，
  #    要固定地址或 token 请自己编辑 overlay-next\startup.json（构建时带过去）
  #    或直接改部署出去的那一份（换值不必重编）。
  $exeDir = Get-PackagedDir
  if (-not $exeDir) { Write-WarnLine '未找到打包目录，跳过 startup.json 部署。'; return }
  $dst = Join-Path $exeDir 'startup.json'
  $src = Join-Path $script:OverlayDir 'startup.json'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Info '覆盖层无 startup.json 模板，跳过部署。'
    return
  }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  Write-Ok "startup.json 已部署到 $dst（模板原样拷贝）"
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

  # 1b) exe 版本资源：ProductVersion / FileVersion 必须都是 <version 前三段>.0
  #     这一条是 Assert 级的：只写在构建日志里没人看，装到用户机器上才发现「版本显示不对」。
  if ($exe.Count -gt 0) {
    $expected = $null
    $wsPkgPath = Join-Path $script:WsDir 'package.json'
    if (Test-Path -LiteralPath $wsPkgPath) {
      $wsVer = (Get-JsonObject $wsPkgPath).version
      if ($wsVer) { $expected = Get-WindowsVersionQuad -Version $wsVer }
    }
    $vi = $exe[0].VersionInfo
    $fileRaw = [string]$vi.FileVersionRaw
    $productRaw = [string]$vi.ProductVersionRaw
    $fileName = [string]$vi.FileVersion
    $productName = [string]$vi.ProductVersion
    if (-not $expected) {
      $rows.Add([pscustomobject]@{ 项目 = '版本资源'; 结果 = '跳过'; 说明 = '未能从 package.json 推出四段版本' })
    } elseif ($fileRaw -eq $expected -and $productRaw -eq $expected -and $fileName -eq $expected -and $productName -eq $expected) {
      $rows.Add([pscustomobject]@{ 项目 = '版本资源'; 结果 = 'OK'; 说明 = "FileVersion/ProductVersion = $expected（数字段与字符串值一致）" })
    } else {
      $rows.Add([pscustomobject]@{ 项目 = '版本资源'; 结果 = '不符'; 说明 = "期望 $expected；实际 FileVersion=$fileName($fileRaw) ProductVersion=$productName($productRaw)" })
      $missing.Add("exe 版本资源（期望 $expected）")
    }
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

    # 3b) 覆盖层集成点必须真的打进去了。
    #     两类标记：常态要求的（startup-config 集成点），以及可控 Web 入口专属的 ——
    #     后者只在给了 -FixedTokenPatch / -ListenAllNetworkPatch 的构建里才要求，默认构建
    #     没打那两个补丁，自然没有这些字符串，不该在这里报缺失。
    $markerChecks = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $script:RequiredMarkers.Keys) {
      # 一个条目可以有多个标记（同一个文件里要同时验两处，例如 startup-config 的集成点
      # 与它放行的 DSH_* 白名单）。
      foreach ($marker in @($script:RequiredMarkers[$entry])) {
        $markerChecks.Add([pscustomobject]@{ Entry = $entry; Marker = $marker; Requires = '' })
      }
    }
    foreach ($entry in $script:RequiredMarkersWhenTokenPatch.Keys) {
      foreach ($marker in @($script:RequiredMarkersWhenTokenPatch[$entry])) {
        $markerChecks.Add([pscustomobject]@{ Entry = $entry; Marker = $marker; Requires = 'token' })
      }
    }
    foreach ($entry in $script:RequiredMarkersWhenListenPatch.Keys) {
      foreach ($marker in @($script:RequiredMarkersWhenListenPatch[$entry])) {
        $markerChecks.Add([pscustomobject]@{ Entry = $entry; Marker = $marker; Requires = 'listen' })
      }
    }
    foreach ($chk in $markerChecks) {
      $required = switch ($chk.Requires) {
        'token'  { $script:TokenPatchActive }
        'listen' { $script:ListenPatchActive }
        default  { $true }
      }
      if (-not $required) {
        $which = if ($chk.Requires -eq 'token') { '-FixedTokenPatch' } else { '-ListenAllInterfacesPatch' }
        $rows.Add([pscustomobject]@{ 项目 = "补丁代码 ($($chk.Entry))"; 结果 = '跳过'; 说明 = "未给 $which，该补丁未打" })
        continue
      }
      $found = $false
      if ($useArchive) {
        $snippet = Get-ArchiveFileText $archive $chk.Entry
        $found = ($null -ne $snippet) -and $snippet.Contains($chk.Marker)
      } else {
        $target = Join-Path $plain ($chk.Entry -replace '/', '\')
        $found = (Test-Path -LiteralPath $target) -and ((Select-String -Path $target -Pattern $chk.Marker -SimpleMatch -List -ErrorAction SilentlyContinue) -ne $null)
      }
      if ($found) {
        $rows.Add([pscustomobject]@{ 项目 = "补丁代码 ($($chk.Entry))"; 结果 = 'OK'; 说明 = "$($chk.Marker) 已打包（$layoutName）" })
      } else {
        $rows.Add([pscustomobject]@{ 项目 = "补丁代码 ($($chk.Entry))"; 结果 = '缺失'; 说明 = "$layoutName 的 $($chk.Entry) 中没有 $($chk.Marker)" })
        $missing.Add("补丁代码（$($chk.Entry) 的 $($chk.Marker)）")
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
  $bannerHarness = if ($script:HarnessOverrideActive) { "$($script:HarnessVersionOverride)（-HarnessVersion 指定）" } else { "$bannerRuntime（跟随上游）" }
  $bannerElectron = if ($script:ElectronOverrideActive) { "$($script:ElectronOverride)（-ElectronVersion 指定）" } else { 'upstream' }
  $bannerPnpm = if ($script:PnpmOverrideActive) { "$($script:PnpmOverride)（-PnpmVersion 指定）" } else { 'upstream' }
  $banner = @"
DSH NEXT build log
started : $(Get-Date -Format o)
root    : $script:Root
src     : $script:Src
workspace: $script:WsName
target  : $Target
runtime : $bannerHarness
electron: $bannerElectron
pnpm    : $bannerPnpm
preview : $($Preview.IsPresent)
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

  # 补丁开关的处理放在这里：让人在装依赖之前就看到「这次会多出哪些代码能力」。
  Resolve-WebAccessPlan

  if (-not (Test-Path -LiteralPath (Join-Path $script:Src '.git'))) {
    throw "未找到 $script:Src（或缺少 .git）。请先运行一次 stable 的构建以完成克隆。"
  }

  Invoke-Step '导出覆盖层改动（pull 前保护）' { Export-Overlay }
  Invoke-Step '获取 / 更新 dsh-desktop 源码' {
    if ($SkipPull) { Write-WarnLine '已跳过源码拉取（-SkipPull）。' } else { Update-SourceRepository }
  }
  Invoke-Step '解析 dsh 运行时版本（-HarnessVersion / 上游声明）' { Resolve-HarnessVersion }
  Invoke-Step "固定运行时版本（dsh $($script:ResolvedRuntimeVersion)）" { Set-HarnessVersionPinned }
  Invoke-Step '对齐 deepseek-harness 子模块' { Ensure-Submodule }
  Invoke-Step '选择工作区（next + stable + beta 全部保留）' { Set-WorkspaceSelection }
  Invoke-Step '应用 next 覆盖层（代码补丁）' { Apply-Overlay }
  Invoke-Step '校验运行时版本与打包姿态（含 electron / pnpm / 版本资源注入）' {
    Test-NextRuntimeVersion
    Set-ElectronOverride
    Set-PnpmOverride
    Set-WindowsVersionInfo
    Test-PackagingPosture
    Set-PayloadExclusions
    Set-MarketWorkspaceCheck
    Set-AAWorkspaceCheck
  }

  if ($Preview) {
    # 预演：把上面那一步「实际改了什么」摊开给人看，然后退出。
    # 加这个开关的原因很实际：三个版本参数改的是 dsh-desktop 工作区里的已跟踪文件，跑一次
    # 完整构建要 6 分钟以上，而「参数写错」通常看一眼 diff 就能发现。
    Write-Host ''
    Write-Host 'git diff --stat（dsh-desktop 工作区）：' -ForegroundColor White
    $stat = @(& git -C $script:Src --no-pager diff --stat 2>&1)
    foreach ($line in $stat) { Write-Host "  $line"; Write-Log "[preview] $line" }
    $wsPkg = Get-JsonObject (Join-Path $script:WsDir 'package.json')
    Write-Host ''
    Write-Host '关键注入值（next 工作区 package.json）：' -ForegroundColor White
    $rows = [ordered]@{
      'version'                 = [string]$wsPkg.version
      'build.buildVersion'      = [string]$wsPkg.build.buildVersion
      'devDependencies.electron'= [string]$wsPkg.devDependencies.electron
      'dependencies.pnpm'       = [string]$wsPkg.dependencies.pnpm
      '@deepseek-ai/dsh'        = [string]$wsPkg.dependencies.'@deepseek-ai/dsh'
      '@deepseek-ai/cordis'     = [string]$wsPkg.dependencies.'@deepseek-ai/cordis'
      '@deepseek-ai/schemastery'= [string]$wsPkg.dependencies.'@deepseek-ai/schemastery'
      'dsh 运行时（解析结果）'   = [string]$script:ResolvedRuntimeVersion
      'harness commit'          = [string]$script:ResolvedHarnessCommit
    }
    foreach ($k in $rows.Keys) {
      $v = $rows[$k]
      if ([string]::IsNullOrEmpty($v)) { $v = '(未注入 / 上游未声明)' }
      Write-Host ("  {0,-26}: {1}" -f $k, $v)
      Write-Log "[preview] $k = $v"
    }
    Write-Host ''
    Write-Host '预演结束（-Preview）：未安装依赖、未编译、未打包。' -ForegroundColor Yellow
    Write-Info "预演日志：$script:LogPath"
    exit 0
  }

  if (-not $SkipInstall) {
    Invoke-Step '安装工作区依赖' { Invoke-Workspace }
    # install 之后才有的树：补齐上游 devDependencies 漏声明的 peer（见 Repair-WorkspacePeers）。
    Invoke-Step '补齐工作区缺失 peer（打包闭包前置）' { Repair-WorkspacePeers }
  } else {
    Write-WarnLine '已跳过 yarn install（-SkipInstall）'
  }
  # 覆盖参数最容易的失败形态是「构建成功但版本没换」，装完立刻核对一次。
  if ($script:ElectronOverrideActive -or $script:PnpmOverrideActive) {
    Invoke-Step '核对已安装的 electron / pnpm 版本（含 dsh 原生 addon 支持表）' {
      Test-InstalledOverrides
      Test-ElectronAddonSupport
    }
  }

  # 运行时补丁必须在「编译/打包」之前：payload 里的 node_modules 是打包时从这棵树拷的，
  # 打完包再改就只改到磁盘上的产物、下次 install 还会还原。
  # ⚠️ 默认**不打**：只有给了 -FixedTokenPatch / -ListenAllInterfacesPatch 才应用。
  #    不给开关时产物保持上游行为（回环 + 每次随机 token），运行时补丁不该出现在产物里。
  if ($script:WebAccessActive) {
    Invoke-Step "应用运行时补丁（$($script:WebAccessGroups -join ' / ')）" { Invoke-WebAccessPatch }
  } else {
    Write-Info '未给 -FixedTokenPatch/-ListenAllInterfacesPatch：跳过运行时补丁（产物保持上游的回环 + 随机 token 行为）'
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
  if ($script:WebAccessActive) {
    Write-Host ''
    Write-Host '可控 Web 入口（已打的补丁）：' -ForegroundColor White
    if ($script:TokenPatchActive) { Write-Host '  · 固定启动 Token —— 产物会读 DSH_WEB_TOKEN' }
    if ($script:ListenPatchActive) { Write-Host '  · 监听所有网卡 —— 产物会读 DSH_NEXT_WEB_HOST' }
    Write-Host ''
    Write-Host '  ↓ 值**不在编译里**，写进 exe 同级的 startup.json（改完重启生效，不必重编）：' -ForegroundColor White
    Write-Host '    {'
    Write-Host '      "version": 1,'
    Write-Host '      "env": {'
    $guide = @(Get-DshWebAccessStartupGuide -FixedToken:$script:TokenPatchActive -ListenAllNetwork:$script:ListenPatchActive)
    for ($i = 0; $i -lt $guide.Count; $i++) {
      $comma = if ($i -lt $guide.Count - 1) { ',' } else { '' }
      Write-Host ("        {0}{1}" -f $guide[$i], $comma)
    }
    Write-Host '      }'
    Write-Host '    }'
    Write-Host '  想长期生效就写进 overlay-next\startup.json 模板（构建时会原样拷过去）；'
    Write-Host '  临时试一次可用同名环境变量（它能压过文件里的值）。'
    Write-Host '  DSH_WEB_TRUSTED_HOSTS 是 JSON 数组字符串（与上游 DSH_NEXT_TRUSTED_HOSTS 同格式，'
    Write-Host '  只从本机访问可整行删掉）；嫌引号转义麻烦就写 "1.2.3.4,5.6.7.8"，两种都认。'
    Write-Host '  外部浏览器还需在 DSH NEXT 设置里勾选「允许在浏览器中打开」，端口取设置里的 port。'
    Write-Log ("[web-access] patches=$($script:WebAccessGroups -join ',')")
  }
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
