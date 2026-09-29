# DSH Desktop 构建工具包

DeepSeek Harness Desktop（DSH Desktop）的本地构建与定制工具包。本仓库**不含上游源码**——`dsh-desktop` 以 **git 子模块**收录（pin 在 v2.0.9 / `63e160ab43`），clone 后一次 `git submodule update --init --recursive` 即获得完整构建环境；自定义功能通过 `overlay/` 覆盖层在构建时自动注入，构建产物可复现。

## 仓库结构

| 路径 | 说明 |
|------|------|
| `build.ps1` | 主构建脚本（PowerShell 7+） |
| `build.bat` | 批处理入口（参数透传给 build.ps1） |
| `quick-build.bat` | 增量编译 + 解包目录（stable 通道，不打 ZIP） |
| `quick-build-overlay.bat` | 同左，并应用 `-Overlay` 覆盖层 |
| `build-next.ps1` | Next 通道构建脚本（实验性 DSH NEXT，见下文「Next 通道」） |
| `quick-build-next.bat` | Next 通道入口（`-Target package-dir -SkipSubmodule`） |
| `update-app.bat` | 把 `dist\win-unpacked` 部署到 `X:\App\DSH-Desktop` |
| `overlay/` | 自定义覆盖层（构建时注入 dsh-desktop） |
| `overlay-next/` | Next 通道专属覆盖层（与 `overlay/` 隔离） |
| `build/` | 定制图标资源（托盘 / 应用图标源） |
| `dsh-desktop/` | **子模块**：上游 `anywhere-labs/dsh-desktop`（v2.0.9） |
| `BUILD_GUIDE.md` | 构建指南（目标、参数、故障排查） |

## 快速开始

```bash
git clone --recursive https://github.com/allthewayeast/dsh-desktop-package.git
cd dsh-desktop-package
build.bat dist-win-portable     # 或 quick-build.bat（增量编译）
```

> 若已用普通 `git clone` 拉取，请先执行 `git submodule update --init --recursive`。
> `build.ps1` 每次构建前会自动对齐子模块（`git submodule update --force` 重置到 pinned commit 后重新注入覆盖层），无需手动处理。

## 覆盖层机制

构建脚本在每次构建时先把 `dsh-desktop` 重置到 pinned commit，再注入覆盖层，保证构建可复现：

- `overlay/src/*.ts` → 复制为 `dsh-desktop/dsh-plugin-desktop` 下的新文件（`startup-config.ts` 及其测试）
- `overlay/patches/*.patch` → `git apply` 到 `dsh-desktop/dsh-plugin-desktop`（`main.ts` 接入启动配置、`package.json` 重新启用 ASAR + 三平台 `asarUnpack`、产物运行时校验白名单）
- `overlay/aa/` → Agents Anywhere 本机发布记录（`provenance.json` + 本机构建出的 `*.tgz`）。AA 产物名含本机 peer 联合范围的哈希，与上游发布的产物不同名，而上游 `aa:prepare-release` 的「复用已验证产物」快路径要求发布记录与产物同时在场；该记录写在受跟踪文件里、每次 pull 都会被 `git checkout -f` 重置，所以构建脚本把它也当覆盖层：打包成功后固化到此，pull 后恢复回 `vendor/agents-anywhere/`，并把三个 AA 工作区与根 `resolutions` 的依赖对齐到该产物。缺失时每次构建都会全量重打包（≈7 分钟、需联网）并可能撞上上游的 `Existing artifact differs` 守卫。需要刷新到新的 AA 源时：删除 `overlay/aa/` 后跑一次构建即可。恢复是有前提的：脚本先核对 `overlay/aa/record.json` 里记录的 `runtimeVersion`，与当前固定的运行时版本不一致（含旧格式、无该文件）就跳过恢复，改用上游自带的那份发布 —— 否则用异 peer 的本机记录覆盖上游产物会让快路径失效，进而重打包出与上游同名不同字节的产物，撞上 `Existing artifact differs` 守卫硬失败。
- `dsh-plugin-desktop/package.json` 的补丁为**手工维护**：构建期会改写该文件的依赖版本串与打包钩子，自动导出会把注入误当成用户改动、整份覆盖策展内容。build.ps1 用 `$script:NoAutoExportPatchFiles` 明确跳过它的自动导出（改了它请直接编辑 `overlay/patches/package.json.patch` 并在包根仓库提交）。
- 附加覆盖层（由 build.ps1 自动处理）：electron 固定 `44.4.5`、`.yarnrc.yml` 年龄门禁、定制图标、`npmRebuild=false`
- 工作区排除（由 build.ps1 自动处理，见 `$script:DisableBeta` / `$script:DisableNext`）：从根 `package.json` 的 `workspaces` 移除 `dsh-plugin-desktop-beta`（beta 通道）与 `dsh-desktop-next`（实验性 Next 桌面，独立 Electron 应用）——两者都不安装依赖、不参与编译 / 类型检查 / 打包，只有 stable 通道 `dsh-plugin-desktop` 会被构建。改 `$false` 可临时恢复。

## Next 通道（实验性）

`build-next.ps1` / `quick-build-next.bat` 构建上游的实验性桌面 `dsh-desktop-next`（产物在其 `dist\win-unpacked`），与 stable 通道共享拉源码 / 子模块 / `yarn install` / 覆盖层这几步，差异在于：

- 工作区：把 `dsh-desktop-next` 加回根 `workspaces`、移除 `dsh-plugin-desktop`（stable）；`dsh-plugin-desktop-beta` **必须保留依赖**（next 的 vite 配置直接复用 beta 的 renderer 构建）。
- 覆盖层独立为 `overlay-next/`（`src/` 新文件 + `patches/` 补丁），不与 stable 的 `overlay/` 互相污染。
- **运行时跟随上游（不钉版本）**：next 的 `@deepseek-ai/dsh*` 由上游决定，脚本只校验「工作区声明 / 根 `resolutions` 里 `vendor/dsh-runtime/<ver>` 的映射 / vendor 目录」三者一致，并在不一致时告警而不改写；`deepseek-harness` 子模块对齐上游 HEAD 记录的 gitlink。stable 通道自 2026-09-29 起也跟随上游（`build.ps1` 里 `$script:RuntimeVersion = '0.2.0-rc.1'` / `$script:HarnessCommit = 4878cdabd8`，与上游 `upstream.json` 的 stable 通道一致 → `Set-RuntimeVersionPinned` 直接跳过改写），两个通道现在对齐同一份运行时，交替构建不再来回移动子模块。
- 不做图标处理；不经过 `aa:prepare-release`（next 走 workspace 级 `package:dir`，AA 的「复用已验证产物」守卫只存在于该脚本内），因此 `overlay/aa/` 那套固化机制对 next 不适用。
- `overlay-next/patches/package.json.patch` 同样是**手工维护**的（ASAR 重新启用 + 双 ASAR fuse + 三平台 `asarUnpack`）：构建期会注入 electron 版本、移除 `afterAllArtifactBuild`，而 stable 的构建也会把 AA 依赖对齐写进同一文件。脚本用 `$script:NoAutoExportPatchFiles` 跳过它的自动导出；要改它请直接编辑补丁并在包根仓库提交。

## 启动配置文件（startup.json）

启动器会读取可执行文件同目录的 `startup.json`（或用环境变量 `DSH_STARTUP_CONFIG` 指定绝对路径），在解析 DSH home / Safe Mode 状态**之前**注入环境变量，并在 app ready **之前**追加 Electron/Chromium 开关：

```json
{
  "version": 1,
  "env": {
    "DSH_HOME": "E:\\AppData\\YMZ\\.dsh-desktop",
    "DSH_TELEMETRY_DISABLED": "1"
  },
  "electron": {
    "switches": [
      { "name": "disable-gpu", "value": null },
      { "name": "proxy-server", "value": "http://127.0.0.1:7890" }
    ]
  }
}
```

安全边界（完整说明见构建时注入到 `dsh-desktop/dsh-plugin-desktop/README.md` 的「Startup configuration」章节）：

- `env` 仅接受普通变量 + `DSH_HOME` / `DSH_TELEMETRY_DISABLED` 两个特例；`PATH`、`NODE_OPTIONS`、`LD_PRELOAD`、代理 / CA 证书变量及其余 `DSH_*` / `XDG_*` / `DYLD_*` 一律拒绝；已存在于环境中的变量优先（**只补缺、不覆盖**）。
- `electron.switches` 名称须为小写 kebab-case；只作用于 Electron / Chromium 层，不做危险开关过滤（信任用户自己的机器）。
- 配置文件必须是真实普通文件（拒绝符号链接）、≤ 64 KiB、UTF-8、`version: 1`；文件损坏时**大声失败进入恢复模式**，而非静默忽略。

## 升级 dsh-desktop 子模块

```bash
git submodule update --remote dsh-desktop     # 拉取上游最新并移动 gitlink
git add dsh-desktop .gitmodules
git commit -m "chore: bump dsh-desktop to <new-commit>"
git push
```

## 环境要求

- Node.js ^22.19.0 或 >=24.0.0（自带 Corepack，管理 Yarn 4.18.0）
- PowerShell 7+、Git
- 默认代理 `http://127.0.0.1:15715`（`-NoProxy` 禁用，`-Proxy <url>` 自定义）

## 说明

- 上游 `dsh-desktop` 版权归其作者；本仓库仅提供构建脚本、覆盖层与文档。
- 本机 `fork-sync-notes.md`（fork 同步备忘，含本机路径与敏感信息）保留在本地，**未随仓库发布**。
