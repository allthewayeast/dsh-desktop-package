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

# 应用本地覆盖层（electron 44.3.0 / 图标 / startup.json 功能 / README 文档）
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

## 覆盖层（Overlay）

`-Overlay` 开关在构建前应用本地定制（每次构建先重置子模块再注入，保证可复现）：

- electron 固定 `44.3.0`（`dsh-plugin-desktop/package.json`）
- `.yarnrc.yml` 追加 `npmMinimalAgeGate: 0`（允许使用刚发布的版本）
- 定制托盘 / 应用图标（源在仓库 `build/` 目录）
- `overlay/src/*.ts` 复制为 `dsh-plugin-desktop` 新文件（`startup-config.ts` 及其测试）
- `overlay/patches/*.patch` 经 `git apply` 应用到 `dsh-plugin-desktop`（`main.ts` 接入、README 文档）

修改 `dsh-desktop` 工作区里的源码后，跑 `quick-build-overlay.bat` 会自动把改动导出到 `overlay/`（`Export-SrcOverlay`），下一次干净 clone 后仍能重现。

## 故障排查

### 1. Yarn 安装失败（EBUSY 错误）

```batch
REM 清理缓存后重试
cd dsh-desktop
del .yarn\install-state.gz
cd ..
build.bat dist-win-portable
```

### 2. electron-builder 下载超时

```batch
REM 确认代理可用
curl -x http://127.0.0.1:15715 https://github.com

REM 或使用 --no-proxy 禁用代理
build.bat dist-win-portable --no-proxy
```

### 3. 子模块未初始化 / 拉取失败

```batch
REM 手动初始化子模块（含嵌套的 deepseek-harness）
git submodule update --init --recursive
build.bat dist-win-portable
```

若拉取失败，请检查网络 / 代理（`-NoProxy` 可禁用）与 Git 凭据。

### 4. 覆盖层补丁无法应用

`git apply` 冲突时构建会中止（不静默跳过）。处理：手动合并 `dsh-desktop` 中对应文件后重新 `git diff` 导出 patch，或删除该 patch 文件放弃这处定制。

## 构建日志

每次构建的详细日志保存在 `logs\build-YYYYMMDD-HHMMSS.log`。

## 相关文件

- `build.ps1` - PowerShell 构建脚本（主脚本）
- `build.bat` - 批处理包装器（简化调用）
- `quick-build.bat` - stable 通道一键编译+解包（先对齐子模块，不打 ZIP）
- `quick-build-overlay.bat` - 同上，附加 `-Overlay` 覆盖层
- `overlay\` - 自定义覆盖层（src 新文件 + patches 补丁）
- `dsh-desktop\package.json` - Yarn 工作区配置（子模块）
- `dsh-desktop\upstream.json` - 上游 deepseek-harness 版本信息（子模块）
