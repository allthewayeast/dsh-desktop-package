# DeepSeek Harness Desktop - 构建指南

## 快速开始

### Windows 一键构建

```batch
REM 首次构建或依赖有更新时（完整构建）
build.bat dist-win-portable

REM 增量编译（代码修改后快速重编译，不打 ZIP）
quick-build.bat
```

⚠️ **重要**：`build.bat`（无参数）只会编译代码到 `dsh-desktop\dsh-plugin-desktop\lib` 等目录，**不会生成** `dist` 安装包。要生成安装包，必须指定打包目标如 `dist-win-portable`。

💡 **只编译不打包**：给任何打包目标加 `-NoZip` 即可只编译、不生成 ZIP/安装包，例如 `.\build.ps1 -Target dist-win-portable -NoZip`。

> `dsh-desktop` 是本仓库的 git 子模块。`build.ps1` 每次构建前会先执行
> `git submodule update --init --recursive --force` 把子模块对齐到 pinned commit，
> 再（`-Overlay` 时）注入本地覆盖层——无需手动 clone / pull。

## 详细用法

### 批处理脚本 (build.bat)

```batch
REM 默认构建（仅编译，不打包）
build.bat

REM 构建 Windows 便携 ZIP（推荐）
build.bat dist-win-portable

REM 构建 Windows NSIS 安装包
build.bat dist-win

REM 完整门禁检查（编译 + 类型检查 + 测试）
build.bat check

REM 编译并启动图形界面
build.bat dev

REM 禁用代理
build.bat dist-win-portable --no-proxy

REM 跳过依赖安装 / 子模块对齐（增量构建）
build.bat dist-win-portable --skip-install --skip-submodule
```

### PowerShell 脚本 (build.ps1)

```powershell
# 使用默认代理 http://127.0.0.1:15715
.\build.ps1 -Target dist-win-portable

# 使用自定义代理
.\build.ps1 -Target dist-win-portable -Proxy http://127.0.0.1:7890

# 禁用代理
.\build.ps1 -Target dist-win-portable -NoProxy

# 跳过子模块对齐和依赖安装
.\build.ps1 -Target dist-win-portable -SkipSubmodule -SkipInstall

# 跳过子模块对齐（使用现有 dsh-desktop 工作区，含上次注入的覆盖层）
.\build.ps1 -Target dist-win-portable -SkipPull

# 应用本地覆盖层（electron 版本对齐 / ASAR / 图标 / startup.json 功能 / 文档）
.\build.ps1 -Target dist-win-portable -Overlay

# 同时构建上游 deepseek-harness 源码
.\build.ps1 -Target check -Upstream

# 只编译，不生成 ZIP / 安装包（打包目标 + -NoZip）
.\build.ps1 -Target dist-win-portable -NoZip
```

## 构建目标

| 目标 | 说明 |
|------|------|
| `build` | 只编译 JS/类型声明（默认，无界面） |
| `dist-win-portable` | Windows x64 便携 ZIP（推荐） |
| `dist-win` | Windows x64 NSIS 安装包 |
| `dist-mac` | macOS 签名发布（需凭证） |
| `dist-mac-smoke` | macOS 未签名测试包 |
| `package-dir` | 当前平台解包目录 |
| `check` | 完整门禁：build + typecheck + test |
| `typecheck` | 仅类型检查 |
| `test` | 仅单元测试 |
| `dev` | 编译后启动图形界面 |
| `start` | 使用已有产物启动 |
| `all` | build + typecheck + test |

> 任何 `dist-*` 打包目标均可追加 `-NoZip` 只编译、不打包（等效于 `build`）。

## 构建产物

构建成功后，产物位于：

- **便携 ZIP**：`dsh-desktop\dsh-plugin-desktop\dist\DSH-Desktop-2.0.1-x64-Portable.zip`
- **解包目录**：`dsh-desktop\dsh-plugin-desktop\dist\win-unpacked\DSH Desktop.exe`
- **编译产物**：`dsh-desktop\dsh-plugin-desktop\lib\` 和 `dsh-desktop\dsh-community-market\lib\`

## 环境要求

- **Node.js**: ^22.19.0 或 >=24.0.0
- **PowerShell**: 7.0+
- **Git**: 任意版本（需支持 `git submodule`）
- **Corepack**: Node.js 自带（用于管理 Yarn 4.18.0）

## 代理配置

脚本默认使用 `http://127.0.0.1:15715` 作为代理，用于加速 electron-builder 下载。

- 使用 `--no-proxy` 或 `-NoProxy` 禁用
- 使用 `-Proxy <url>` 自定义代理地址

## 增量构建

首次构建后，后续修改代码可使用增量构建加速：

```batch
REM 快捷方式：stable 通道编译 + 解包（不打 ZIP）
quick-build.bat

REM 或手动指定（增量编译，不打 ZIP）
build.bat dist-win-portable --skip-install --skip-submodule
```

> `quick-build-overlay.bat` 与 `quick-build.bat` 相同，但会附加 `-Overlay`
> （本地定制覆盖层）。

## DSH NEXT 通道（实验性）

`dsh-desktop-next`（产品名 **DSH NEXT**）是独立的实验性桌面，构建入口单独一套：

```batch
REM 一键：编译 + 打包到 dsh-desktop-next\dist\win-unpacked（不打 ZIP）
quick-build-next.bat

REM 透传参数
quick-build-next.bat -ElectronVersion 44.4.5
quick-build-next.bat -SkipPull
```

或直接用 PowerShell：

```powershell
pwsh -File .\build-next.ps1 -Target package-dir
pwsh -File .\build-next.ps1 -Target package-dir -SkipSubmodule   # 等同 bat
```

### 为什么单独一个脚本

`build.ps1` 深度绑定 stable 通道（工作区名、插件清单、补丁路径、AA/dshmarket 校验的工作区列表、产物核对项都写死为 stable）。next 的源码结构、构建入口、运行形态都不同，硬塞会牵动 stable 的既有行为。

### 与 stable 的关键差异

| 项 | stable | next |
|----|--------|------|
| 工作区目录 | `dsh-plugin-desktop` | `dsh-desktop-next` |
| 覆盖层目录 | `overlay\` | `overlay-next\` |
| 构建入口 | `package:dir` | `yarn workspace dsh-desktop-next package:dir` |
| 产物 | `dsh-plugin-desktop\dist\win-unpacked` | `dsh-desktop-next\dist\win-unpacked` |
| beta 工作区 | 排除 | **保留**（见下） |
| 嵌套子模块 | `deepseek-harness` | 同一个 |

**beta 工作区必须保留**：next 的 `vite.client.config.ts` 直接 re-export beta 的配置，且有多处 `import` 来自 `beta/src`。所以 beta 保留在工作区里以安装依赖，只从**构建/打包**中排除；stable 则完全不引用 next，可以整个排除。详见故障排查 3.2。

### 覆盖层（overlay-next）

| 文件 | 内容 |
|------|------|
| `overlay-next\patches\main.ts.patch` | 接入 `startup-config`（`applyDesktopStartupConfig`）+ 让 `DSH_HOME` 生效 |
| `overlay-next\patches\package.json.patch` | 重新启用 ASAR（`smartUnpack` + fuses + `asarUnpack`） |
| `overlay-next\patches\verify-packaged.ts.patch` | 产物门禁改为兼容 ASAR / 普通目录两种布局 |
| `overlay-next\patches\verify-fuses.ts.patch` | fuse 校验按实际布局传 `isAsar` |
| `overlay-next\src\startup-config.ts` | 新文件：exe 同级 `startup.json` 启动配置 |
| `overlay-next\src\startup-config.spec.ts` | 新文件：配套单测 |
| `overlay-next\startup.json` | 运行时数据文件，构建后拷到 exe 同级 |

> 修改 next 工作区源码后跑 `quick-build-next.bat`，脚本会在 pull 前自动把改动导出回 `overlay-next\patches\`。
> 导出规则与注意事项（最小上下文、构建脚本托管字段、幂等性）见故障排查第一节。

## 覆盖层（Overlay）

`-Overlay` 开关在构建前应用本地定制（每次构建先重置子模块再注入，保证可复现）：

- electron 对齐到 `-ElectronVersion`（默认值见 `build.ps1` 参数；与上游官方声明一致时**跳过**不改写）
- `.yarnrc.yml` 追加 `npmMinimalAgeGate: 0`（允许使用刚发布的版本）
- 定制托盘 / 应用图标（源在仓库 `build/` 目录）
- `overlay/src/*.ts` 复制为 `dsh-plugin-desktop` 新文件（`startup-config.ts` 及其测试）
- `overlay/patches/*.patch` 经 `git apply` 应用到 `dsh-plugin-desktop`（`main.ts` 接入、README 文档）
- `overlay/patches/package.json.patch` 重新启用 **ASAR**（`smartUnpack` + 两个 fuse + `asarUnpack`），
  把产物从 `resources\app\`（2 万+ 文件）收进 `app.asar`（千级文件）
- ~~`overlay/patches/dshmarket-desktop.patch.patch`~~ **已于 2026-10 移除**：上游已收编该改动，
  本地策展版本反而更旧；且它的基准是旧版上游补丁，`git apply` 必然失配并中止整个 `[03]` 阶段，
  连带 ASAR / 白名单 / `main.ts` / 图标都拿不到应用机会。
  现改由 `Set-MarketPatchDisabled`（`build.ps1`）让 dshmarket 补丁彻底不参与安装

修改 `dsh-desktop` 工作区里的源码后，跑 `quick-build-overlay.bat` 会自动把改动导出到 `overlay/`（`Export-SrcOverlay`），下一次干净 clone 后仍能重现。

⚠️ **导出补丁时注意两点**，否则会踩坑（详见故障排查第一节）：

1. **剔除构建脚本托管的字段**（`electron` 版本、`build.afterAllArtifactBuild`），
   它们由 `Set-ElectronOverride` / `Set-AllArtifactVerifyDisabled` 管理，写进补丁会互相打架。
2. **需要同时满足多版本的补丁要用 `git diff -U1`** 最小上下文导出，
   并加进 `NoAutoExportPatchFiles`，防止被自动导出覆盖回 `-U3` 版本。

## 故障排查

### 排查方法（先读这节）

失败时按这四步走，比直接猜原因快得多。这些是本仓库真实踩过的坑总结出来的。

**1. 先定位失败阶段。** 脚本每个阶段都打 `[0N]` 前缀，日志最后几行就是失败点。阶段基本决定了问题类别：

| 阶段 | 失败通常是 |
|------|-----------|
| `[02]` 源码 | 网络 / 代理 / Git 凭据 |
| `[03]` 覆盖层 | 补丁失配（上游改了同一区域） |
| `[05]` 依赖安装 | 网络、缓存、版本漂移、补丁多点应用 |
| `[07]` package:dir | electron-builder、afterPack 门禁、vite 编译、electron dist |
| `[09]` 产物核对 | 覆盖层代码没真正进产物 |

**2. 读完整日志，不要只看控制台。** 控制台输出可能被截断——例如在管道里用 `| Select-Object -First N`，PowerShell 会在收满 N 行后**提前终止上游命令**，看起来像构建中途死掉，其实是被管道杀了。完整日志在：

```text
logs\build-YYYYMMDD-HHMMSS.log
```

**3. 按证据判断，不要按代码猜测。** 本仓库踩过的坑里有一半是「看起来在覆盖」的代码其实无辜。典型例子：`desktop-runtime.ts` 里 `DSH_HOME: actualHome` 看着像覆盖用户配置，实际只是把**已解析的** home 传给子进程，改它没用。判断依据要用：

- 文件系统状态（目标目录/文件是否真的生成）
- 产物里的实际内容（解包 `app.asar` 抽查）
- 工具的客观读数（`@electron/fuses` 读 fuse 位）

**4. 构建通过 ≠ 修好，必须重跑并验证修复本身。** 见每节末尾的「验证」。

**附：版本固定点速查。** 「装错运行时 / 版本不匹配」类问题先看这几处：

| 常量 / 文件 | 位置 | 说明 |
|------|------|------|
| `$script:RuntimeVersion` | `build.ps1` | 固定的 dsh 运行时版本 |
| `$script:HarnessCommit` | `build.ps1` | `deepseek-harness` 子模块对齐的 commit（取 `dsh-v<版本>` 标签指向的 commit） |
| `$script:ElectronOverride` | `build.ps1` | = `-ElectronVersion` 参数；与官方声明一致时跳过 |
| `upstream.json` | `dsh-desktop\upstream.json` | 各通道的 `commit` / `sourceVersion` / `runtimeSource` |

改版本时要**同时**改这些值并确认对应的 `vendor/dsh-runtime/<版本>/` 与 `patches/*@<版本>.patch` 已存在。

一致性检查（两者应相同）：

```powershell
cd X:\dsh-desktop-package
$u = Get-Content dsh-desktop\upstream.json -Raw | ConvertFrom-Json
"upstream <通道>.commit = " + $u.channels.stable.commit
"submodule HEAD         = " + (git -C dsh-desktop\deepseek-harness rev-parse HEAD)
```

不一致说明子模块没对齐——常见于用了 `-SkipSubmodule`，或子模块还停在旧 commit。

---

### 一、补丁类问题

#### 1.1 覆盖层补丁无法应用

`git apply` 冲突时构建**中止**（不静默跳过），报：

```text
覆盖层补丁无法应用：main.ts.patch（上游可能已改动同一区域，需按新代码更新补丁）
```

处理办法：手动合并 `dsh-desktop` 中对应文件，重新导出补丁。

```powershell
cd dsh-desktop
# 1) 手动把改动做到工作区源码里（或参考 --check 报的 hunk 位置合并）
# 2) 导出（注意按下面的「最小上下文」规则）
git diff HEAD -- dsh-desktop-next/src/main.ts > ..\overlay-next\patches\main.ts.patch
# 3) 用干净 HEAD 验证补丁真的能应用
git stash
git apply --check ..\overlay-next\patches\main.ts.patch   # 应为 exit 0
git stash pop
```

**关键点：导出前先把构建脚本托管的字段还原。** 见 1.3。

#### 1.2 一个补丁要满足多个版本 → 用 `-U1` 最小上下文

同一份补丁可能要在**不同版本**的同一文件上生效。

本项目最典型的是 dshmarket。`market:prepare` 会**跟随 npm latest**（查 `registry.npmjs.org/dshmarket/latest`），并把 lockfile 里的 `resolutions` 一起改写成最新版；而补丁是按某个具体版本写的。npm 一发新版，补丁就可能失配。当时的形态是：

| 步骤 | 用到的 dshmarket 版本 | 对补丁的要求 |
|------|---------------------|-------------|
| `[05]` yarn install | lockfile / `resolutions` 里固定的版本 | 必须匹配该版本 |
| `[07]` market:prepare | 被改写成 npm latest | 必须匹配 latest |

两处若不是同一版本，补丁就得同时满足两个。当时的触发点很隐蔽：新版把改动行**旁边**一行的变量改了名（**改动行本身完全没变**），补丁默认的 3 行上下文因此失配，报：

```text
Cannot apply hunk #2
```

**先查当前两个版本是否一致：**

```powershell
# market:prepare 会跟到的版本
(Invoke-RestMethod https://registry.npmjs.org/dshmarket/latest).version
# 当前 lockfile / resolutions 固定的版本
Select-String -Path dsh-desktop\package.json -Pattern 'dshmarket@npm:'
```

若不一致，或你就是要让补丁跨版本，就用**最小上下文**重新生成：

```powershell
# 默认 -U3 上下文太大，改 -U1
git diff -U1 -- <file> > overlay\patches\<file>.patch
```

判断能不能用 `-U1`：**改动行本身 + 其紧邻行在所有目标版本中是否一致**。一致就可以。

> ⚠️ **最容易踩空的地方：** 如果只把那一行上下文改成新版本的正确写法，`[07]` 能过，但 `[05]` 反而挂了——因为同一份补丁要**同时**满足两个版本。所以不要「改上下文去迁就某一版」，而要用 `-U1` 让补丁只依赖两版都相同的片段。
>
> 改完必须**两个阶段都验证**：`[05]` 依赖安装和 `[07]` market:prepare 都要通过。

#### 1.3 补丁不要包含构建脚本托管的字段

导出补丁时，工作区里可能已经带有**构建脚本自己注入**的改动（不是你的定制）。这些必须从补丁里剔除，否则补丁会和脚本互相打架。

已知由脚本托管的字段（`Set-ElectronOverride` / `Set-AllArtifactVerifyDisabled`）：

| 字段 | 由谁管理 |
|------|---------|
| `devDependencies.electron` / `peerDependencies.electron` | `Set-ElectronOverride` |
| `build.afterAllArtifactBuild` | `Set-AllArtifactVerifyDisabled` |

导出前先把它们还原成上游值，再 `git diff`：

```powershell
# 以 next 通道为例（stable 同理）
$f = 'dsh-desktop\dsh-desktop-next\package.json'
$saved = [System.IO.File]::ReadAllText($f)
$tmp = $saved.Replace('"electron": "44.4.5"', '"electron": "44.0.0"')
$tmp = $tmp.Replace("<afterPack 行>`n", "<afterPack 行>`n    `"afterAllArtifactBuild`": ...`n")
[System.IO.File]::WriteAllText($f, $tmp)
git -C dsh-desktop diff HEAD -- dsh-desktop-next/package.json > overlay-next\patches\package.json.patch
[System.IO.File]::WriteAllText($f, $saved)   # 还原工作区
```

> 历史事故：`package.json.patch` 曾退化成「纯版本串改写」，把上游的 `@deepseek-ai/dsh*` 依赖整体降级回旧版本，导致每次构建都装错运行时（YN0060 一片版本不匹配）。所以导出后务必**先看 diff 内容**再收工，确认只有你想要的改动。

#### 1.4 补丁应用要幂等（支持 `-SkipPull` 重跑）

`-SkipPull` 在**已应用过补丁**的工作区上重跑时，正向 `git apply --check` 会失败。不能直接当成失配报错。用反向检查识别「已应用」：

```powershell
git apply --check $patch            # 成功 → 可以打
if ($LASTEXITCODE -ne 0) {
  git apply --reverse --check $patch   # 成功 → 已经打过了，跳过
}
```

`build-next.ps1` 的 `Apply-Overlay` 已实现这个逻辑。

#### 1.5 补丁的导出 / 保护机制

排查补丁问题前先搞清楚这几条规则，否则你的改动会被覆盖或丢失：

| 列表 | 位置 | 作用 |
|------|------|------|
| `SrcPatchFiles` | `build.ps1` | pull 后自动 `git apply` 的补丁清单 |
| `SrcOverlayFiles` | `build.ps1` | 复制进工作区的**新文件**（上游无此文件） |
| `NoAutoExportPatchFiles` | `build.ps1` | **禁止**自动导出的补丁（防止策展内容被退化版本覆盖） |

`Export-SrcOverlay` 会在 pull 前把工作区改动导出到 `overlay\`，所以「改源码 → 跑脚本」不会丢改动。但如果某个补丁是**策展过的**（例如按 1.2 手写的最小上下文版本），必须加进 `NoAutoExportPatchFiles`，否则下次会被自动导出覆盖回 `-U3` 版本。

#### 1.6 补丁缺失时的版本迁移（加固行为）

当上游升级某个工作区依赖，而配套补丁只有旧版本时，脚本**拒绝**把旧补丁硬套到新版本上（这正是最早 `types-DxezulnA.js` 故障的成因），改为告警并回退：

```text
[WARN] 补丁缺失且无可用的兼容旧版本：dsh-settings@0.2.0-rc.2 将不带补丁
```

看到这个告警时，判断该补丁是否还有必要：

```powershell
# 在 deepseek-harness 子模块里对比新旧版本，确认改动是否已并入上游
git -C dsh-desktop\deepseek-harness show <old-ref>:<path> | Select-String '<补丁特征串>'
git -C dsh-desktop\deepseek-harness show <new-ref>:<path> | Select-String '<补丁特征串>'
```

- **已并入上游** → 补丁可删，把告警一起消掉
- **确实还需要** → 按新版本代码重写补丁

---

### 二、打包 / 门禁类问题

#### 2.1 electron dist 缺失

```text
The specified electronDist does not exist: ...\node_modules\electron\dist
```

原因：`.yarnrc.yml` 的 `enableScripts:false` 让 electron 的 postinstall 不执行，`dist` 没被解包；而 electron-builder 优先用这个本地目录。

两个脚本都内置了 `Ensure-ElectronDist`（按需跑 electron 自带 `install.js`，复用 `@electron/get` 缓存，缺失时走 `ELECTRON_MIRROR`）。若仍失败：

```powershell
cd dsh-desktop\dsh-desktop-next\node_modules\electron
node install.js
```

#### 2.2 afterPack 门禁拒绝产物

`afterPack` 脚本会校验产物，报错信息通常很具体，直接按关键字处理：

| 报错关键字 | 含义 | 处理 |
|-----------|------|------|
| `non-allowlisted package roots` | smartUnpack 解出了清单外的包 | 确认该包含原生二进制后加入 `ALLOWED_SMART_UNPACK_PACKAGE_PREFIXES` |
| `exceeds selective ASAR file budget` | 解包文件数超上限 | 排除无用的跨架构包（见 3.2）或提高上限 |
| `exceeds selective ASAR byte budget` | 解包体积超上限 | 同上；若都是必需的原生负载，则提高上限并在常量旁写明体积清单 |
| `must use the same asar:false runtime layout` | 硬断言拒绝 ASAR 布局 | 见 2.3 |
| `Missing Next payload` / `Missing packaged dependency` | 产物缺条目/依赖 | 检查 `files` 列表与依赖闭包 |

**提高上限时必须在常量上方写清理由和逐项体积**，否则以后会被当成随意放宽。

#### 2.3 上游把 ASAR 关掉了（要重新启用）

上游 `83cc4f821c` / `09070dd72e` 曾把桌面打包整体切成 `asar:false`（产物落到 `resources\app\`，文件数 2 万+）。重新启用**不是改一个开关**，要同时恢复 4 处：

1. `build.asar` → `{ "smartUnpack": true }`
2. `electronFuses.enableEmbeddedAsarIntegrityValidation` → `true`
3. `electronFuses.onlyLoadAppFromAsar` → `true`
4. 各平台 `asarUnpack`（必须物理解出的原生负载 + 图标）

同时注意：`next` 通道原本有一条**硬断言**拒绝 ASAR（`verify-packaged.ts`），需要重构成兼容两种布局（归档用 `@electron/asar` 的 `listPackage`/`extractFile`，目录用 `fs`）。

**验证（必做）：**

```powershell
# fuse 位：49 = ENABLED
cd dsh-desktop\dsh-desktop-next
@'
import pkg from '@electron/fuses'
const { getCurrentFuseWire, FuseV1Options } = pkg
const wire = await getCurrentFuseWire(process.argv[2])
const names = Object.fromEntries(Object.entries(FuseV1Options).map(([k,v])=>[v,k]))
for (const [k,v] of Object.entries(wire)) {
  const n = names[k] ?? k
  if (['OnlyLoadAppFromAsar','EnableEmbeddedAsarIntegrityValidation'].includes(n)) console.log(n, '=', v)
}
'@ | Set-Content fusecheck.mjs -Encoding utf8
node fusecheck.mjs (Resolve-Path 'dist\win-unpacked\DSH NEXT.exe').Path
Remove-Item fusecheck.mjs
```

`OnlyLoadAppFromAsar` 打开意味着 Electron **拒绝**从 asar 之外加载应用——能正常启动就证明归档完整有效。再实机启动一次确认无 asar 相关报错。

---

### 三、依赖 / 安装类问题

#### 3.1 Yarn 安装失败（EBUSY 错误）

```batch
REM 清理缓存后重试
cd dsh-desktop
del .yarn\install-state.gz
cd ..
build.bat dist-win-portable
```

#### 3.2 依赖解析失败（vite / rolldown 找不到模块）

```text
Rolldown failed to resolve import "lucide-react" from "...dsh-plugin-desktop-beta\src\client\DesktopNativeActions.tsx"
```

这类错误的关键在**报错文件所在的包**，不是你的工作区。诊断方法：

1. 确认报错包里**确实声明了**该依赖（`package.json`）
2. 确认该依赖**装到了报错包能解析的位置**（Node 从**文件自身所在目录**逐级向上找 `node_modules`）

本项目实际情形：`next` 的 `vite.client.config.ts` 直接 re-export `beta` 的配置，并且有 10 处 `import` 来自 `beta/src`，所以 **beta 必须保留依赖安装**（只从构建/打包里排除）。而 `stable` 完全不引用，可以整个排除。

排查用：

```powershell
# 谁引用了谁
Select-String -Path <ws>\src\*.ts -Pattern "dsh-plugin-desktop-beta/src"
# 依赖装在哪儿了
Test-Path <ws>\node_modules\<dep>
```

#### 3.3 electron-builder 下载超时

```batch
REM 确认代理可用
curl -x http://127.0.0.1:15715 https://github.com

REM 或使用 --no-proxy 禁用代理
build.bat dist-win-portable --no-proxy
```

#### 3.4 子模块未初始化 / 拉取失败

```batch
REM 手动初始化子模块（含嵌套的 deepseek-harness）
git submodule update --init --recursive
build.bat dist-win-portable
```

若拉取失败，请检查网络 / 代理（`-NoProxy` 可禁用）与 Git 凭据。

#### 3.5 运行 `node -e` / 探针脚本报 MODULE_NOT_FOUND

Node 按**脚本自身所在目录**逐级向上找 `node_modules`，**与 cwd 无关**。所以：

- 探针脚本不要放在仓库根或 `overlay\` 下（那里没有依赖）
- 需要某个工作区的依赖时，把脚本写进**那个工作区内部**（例如 `dist\` 下），用完删掉

`build-next.ps1` 的 `Get-ArchiveHelper` 就是这么做的（写到 `dist\.asar-probe.cjs`，结束清理）。

---

### 四、运行时行为类问题

#### 4.1 运行时配置不生效（例如 `DSH_HOME` 被忽略）

**方法：追完整的解析链，不要只看「看起来在覆盖」的那一行。**

以「`DSH_HOME` 不生效、home 固定成 `%UserProfile%\.dsh`」为例，实际排查过程：

1. **先用文件系统证据确认现象**（不要只读代码）：

   ```powershell
   "目标目录是否存在 : " + (Test-Path $target)      # 不存在 → 说明被忽略
   # 再看应用实际写在哪里、时间戳是否活跃
   Get-ChildItem $env:USERPROFILE\.dsh | Sort-Object LastWriteTime -Descending | Select-Object -First 6
   ```

2. **找解析链的入口**，即在模块作用域真正算 home 的地方：

   ```powershell
   Select-String -Path <ws>\src\*.ts -Pattern 'DSH_HOME|defaultDataDirectory|readDataDirectory'
   ```

3. **对比 stable 的实现**（同一个仓库里通常有正确实现可参考）。stable 在 `desktop-channel-home.ts` 里明确把 `DSH_HOME` 当作 `status: 'explicit'` 的输入，next 缺这段 → 属于**漏接线**，不是有意设计。

4. **注意优先级**。多个来源同时存在时要理清顺序，本项目（与 stable 一致）：

   ```text
   启动环境变量 > startup.json > %UserProfile%\.dsh
   ```

   `startup.json` 只填充环境里**不存在**的变量，所以 shell 里已导出的 `DSH_HOME` 会盖过 `startup.json`——测试时容易因此得出错误结论。

5. **改完两条路径都要验证**：启动环境设值、以及只靠 `startup.json` 设值。

---

### 五、诊断用脚本片段

**解包 `app.asar` 抽查内容**（注意 `@electron/asar` 的路径要用反斜杠，且脚本要在有依赖的工作区里）：

```powershell
cd dsh-desktop\dsh-desktop-next
@'
const { listPackage, extractFile } = require('@electron/asar')
const [, , mode, archive, arg] = process.argv
if (mode === 'list') process.stdout.write(listPackage(archive, { isPack: false }).join('\n'))
else process.stdout.write(extractFile(archive, arg).toString('utf8'))
'@ | Set-Content dist\.probe.cjs -Encoding utf8
node dist\.probe.cjs list 'dist\win-unpacked\resources\app.asar' | Select-String 'lib\\main.js'
node dist\.probe.cjs read 'dist\win-unpacked\resources\app.asar' 'lib\main.js' | Select-String 'applyDesktopStartupConfig'
Remove-Item dist\.probe.cjs
```

**确认覆盖层代码真的进了产物**：搜一个补丁引入的唯一标识串（例如 `applyDesktopStartupConfig`），而不是只看构建成功。

**统计产物规模**（判断 ASAR 是否生效）：

```powershell
(Get-ChildItem 'dist\win-unpacked\resources' -Recurse -File | Measure-Object).Count
# ASAR 生效时应为千级；asar:false 时是 2 万+
```

### 六、溯源与防丢（改动到底丢了没有）

> 本节存在的原因：本仓库位于 **`X:`（Romex Primo RamDisk，24 GB，重启即丢）**。
> 2026-10 曾据此误判「提交之后还有改动被丢了」，白查了一轮。结论与取证方法记在这里。

#### 6.1 先认清什么会丢

| 位置 | 重启后 | 说明 |
|------|--------|------|
| GitHub（`origin/main`） | **不丢** | 唯一可靠的持久化位置 |
| `X:\dsh-desktop-package\.git` | **丢** | 在内存盘上，本地提交一起没 |
| 工作树里未提交的改动 | **丢** | 无法恢复 |
| `dsh-desktop\`（独立 clone） | **丢** | 可重建，`build.ps1` 会重新克隆/更新 |
| `dist\` `logs\` `.build-state.json` | **丢** | 全是派生物，重跑即可 |

已核实 Romex 没有有效镜像（`E:\软件备份\RamDisk.vdf` 仅 16 MB，不是 24 GB 盘的完整镜像），
所以**内存盘上的内容没有离线备份可救**。推论：**改动做完就提交并推送**，别停在 X: 上。

#### 6.2 判断「改动是否被推送」——别用本地引用

重新克隆之后，`HEAD` 与本地缓存的 `origin/main` 引用必然相等，所以下面这些**不能**作为证据：

```powershell
git status        # 干净 ≠ 已推送，也可能只是改动已经没了
git branch -vv    # origin/main 是克隆时写入的缓存，不是远端实时状态
```

两个可靠判据：

```powershell
# 1) 直连远端查真实 SHA，与本地 HEAD 比对
git ls-remote origin refs/heads/main
git rev-parse HEAD

# 2) reflog：只有一条 clone 记录 ⇒ .git 是重新克隆的，本地提交已随内存盘丢失
git reflog
#    6ba3529 HEAD@{0}: clone: from https://github.com/allthewayeast/dsh-desktop-package
```

#### 6.3 权威证据是 DSH 会话记录，不是工作树

DSH 把会话落在 **`E:`**（非内存盘），所以工作树丢了它还在：

```text
E:\AppData\YMZ\.dsh-desktop\sessions\<工作区目录>\session-<id>\session.v4.jsonl.zstd
# 工作区目录名 = 转义后的 cwd，例如 X:\dsh-desktop-package → --X-dsh-desktop-package--
```

**坑：这些 `.zstd` 是多帧拼接容器。** 用错 API 会以为"文件里没内容"：

| 用法 | 结果 |
|------|------|
| `zlib.zstdDecompressSync(buf)` | **只解第一帧**，拿到会话头 203 B 就"成功" |
| `zlib.createZstdDecompress()` 流式 | 第二帧起抛 `Unknown frame descriptor` |
| 按帧 magic `28 B5 2F FD` 切分后逐帧解压 | 正确（已封装为工具） |

```powershell
# 1) 解压某工作区的全部会话
node tools\dsh-session-read.mjs expand `
  'E:\AppData\YMZ\.dsh-desktop\sessions\--X-dsh-desktop-package--' `
  "$env:TEMP\dsh-plain"

# 2) 覆盖地图：每个会话覆盖的 turn / 时间范围（判断"那段时间在哪个会话里"）
node tools\dsh-session-read.mjs map "$env:TEMP\dsh-plain"

# 3) 编辑年表：所有 edit/write 调用的时间与文件路径（可加正则过滤）
node tools\dsh-session-read.mjs edits "$env:TEMP\dsh-plain\session-<id>__session.v4.jsonl" "build\.ps1"

# 4) 任意检索：在全部记录（含推理与工具输出）里找字符串
node tools\dsh-session-read.mjs find "dsh-community-market" "$env:TEMP\dsh-plain\session-<id>__session.v4.jsonl"
```

会话文件会增长／轮转：v4 可能只含最近记录，旧内容留在同目录的 `session.v2/v3.jsonl.zstd`。
用 `map` 输出的 `turn=.. time=..` 确认「要找的那段在哪个文件里」。

**判据示例**（2026-10 实测）：本工作区会话 `session-e96a7b40` 覆盖 turn 1..12、09-25 → 10-04、
652 次工具调用；其中 `build.ps1` 共 22 次编辑，**最后一条在 `2026-10-02 23:28:33`，早于提交
`6ba3529`（23:38:08）**。⇒ 该提交之后没有任何源码改动，不存在"丢失的差异"。

#### 6.4 别把构建期改写误判成"丢了的改动"

`dsh-desktop` 是独立 clone，`git status` 里十几项 ` M ` **全部是构建期注入**，属正常：

| 看到的改动 | 来源 |
|-----------|------|
| `dsh-plugin-desktop/build/tray-icon*.png` | 覆盖层图标替换 |
| `dsh-plugin-desktop/package.json` | `overlay/patches/package.json.patch`（ASAR） |
| `dsh-plugin-desktop/src/main.ts`、`scripts/verify-packaged-runtime.ts` | 对应 overlay 补丁 |
| `scripts/prepare-dsh-market.mjs`、`scripts/agents-anywhere-release-policy.mjs`、`upstream.json`、`yarn.lock` | `Disable-MarketWorkspaceCheck` / AA 对齐 / 版本固定 |
| `dsh-community-market/package.json` | `Set-RuntimeVersionPinned` 改写 `@deepseek-ai/dsh*` 版本串 |

关键是**一对方向相反、互相抵消的操作**，不是丢改动：

- **`Reset-OverlayTrackedFiles`**（`build.ps1`）：pull 前把一批受跟踪文件 `git checkout --`
  还原成**上游原始状态**。名单是函数内的 `$exact` 数组，含 `dsh-community-market/package.json`、
  `dsh-plugin-desktop/package.json` 等。
- **`Set-RuntimeVersionPinned`**（`build.ps1`）：pull 后再把 `@deepseek-ai/dsh*` 依赖统一改写成
  pin 的 `$script:RuntimeVersion`。

以 `dsh-community-market/package.json` 为例（2026-10 实测，99 增 99 删、无键增删）：

| hunk | 上游值 | 注入后 |
|------|--------|--------|
| `-89,42`（`peerDependencies`） | `0.2.0-rc.2 \|\| 0.2.1-alpha.1` | `0.2.0-rc.2` |
| `-216,57` | `0.2.1-alpha.1` | `0.2.0-rc.2` |

该行为自 0.1.5 时代（`62dc01b`）就存在，**不是某次改动引入的**。判定某个 modified 是否纯注入：

```powershell
$repo = 'X:\dsh-desktop-package\dsh-desktop'
$d = & git -C $repo diff --unified=0 -- dsh-community-market/package.json
@($d | Where-Object { $_ -like '@@*' })     # 改动落在哪些 JSON 段
@($d | Where-Object { $_ -like '+*' -and $_ -notlike '+++*' }) | Select-Object -First 20
```

出现**非版本串**的增删行（键名增删、逻辑行）时，才需要怀疑是人改的。

---

## 构建日志

每次构建的详细日志保存在 `logs\build-YYYYMMDD-HHMMSS.log`。

## 相关文件

### stable 通道

- `build.ps1` - PowerShell 构建脚本（主脚本）
- `build.bat` - 批处理包装器（简化调用）
- `quick-build.bat` - stable 通道一键编译+解包（先对齐子模块，不打 ZIP）
- `quick-build-overlay.bat` - 同上，附加 `-Overlay` 覆盖层
- `overlay\` - stable 覆盖层（`src\` 新文件 + `patches\` 补丁）

### DSH NEXT 通道

- `build-next.ps1` - next 通道构建脚本（独立，理由见「DSH NEXT 通道」）
- `quick-build-next.bat` - next 通道一键编译+解包
- `overlay-next\` - next 覆盖层（`src\` 新文件 + `patches\` 补丁 + `startup.json`）

### 子模块 / 上游

- `dsh-desktop\package.json` - Yarn 工作区配置（子模块）
- `dsh-desktop\upstream.json` - 上游 deepseek-harness 版本信息（子模块）
- `dsh-desktop\.yarn\patches\` - 工作区依赖补丁（上游跟踪文件；其中 `dshmarket-desktop.patch`
  仍在但**不再被引用**，见 `Set-MarketPatchDisabled`）
- `dsh-desktop\dsh-community-market\package.json` - 市场工作区；构建期被 `Set-RuntimeVersionPinned`
  改写版本串，pull 前由 `Reset-OverlayTrackedFiles` 还原（详见「六、溯源与防丢」6.4）

### 诊断用

- `logs\build-*.log` - 完整构建日志（控制台可能被截断，以这里为准）
- `tools\dsh-session-read.mjs` - DSH 会话记录读取工具（溯源取证，见「六、溯源与防丢」）
