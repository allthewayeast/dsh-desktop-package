# DSH Desktop 构建工具包

DeepSeek Harness Desktop（DSH Desktop）的本地构建与定制工具包。本仓库**不含上游源码**——`dsh-desktop` 以 **git 子模块**收录（pin 在 v2.0.9 / `63e160ab43`），clone 后一次 `git submodule update --init --recursive` 即获得完整构建环境；自定义功能通过 `overlay/` 覆盖层在构建时自动注入，构建产物可复现。

## 仓库结构

| 路径 | 说明 |
|------|------|
| `build.ps1` | 主构建脚本（PowerShell 7+） |
| `build.bat` | 批处理入口（参数透传给 build.ps1） |
| `quick-build.bat` | 增量编译 + 解包目录（stable 通道，不打 ZIP） |
| `quick-build-overlay.bat` | 同左，并应用 `-Overlay` 覆盖层 |
| `update-app.bat` | 把 `dist\win-unpacked` 部署到 `X:\App\DSH-Desktop` |
| `overlay/` | 自定义覆盖层（构建时注入 dsh-desktop） |
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
- `overlay/patches/*.patch` → `git apply` 到 `dsh-desktop/dsh-plugin-desktop`（`main.ts` 接入启动配置、README 使用文档）
- 附加覆盖层（由 build.ps1 自动处理）：electron 固定 `44.4.3`、`.yarnrc.yml` 年龄门禁、定制图标、`npmRebuild=false`
- 工作区排除（由 build.ps1 自动处理，见 `$script:DisableBeta` / `$script:DisableNext`）：从根 `package.json` 的 `workspaces` 移除 `dsh-plugin-desktop-beta`（beta 通道）与 `dsh-desktop-next`（实验性 Next 桌面，独立 Electron 应用）——两者都不安装依赖、不参与编译 / 类型检查 / 打包，只有 stable 通道 `dsh-plugin-desktop` 会被构建。改 `$false` 可临时恢复。

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
