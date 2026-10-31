#Requires -Version 7.0
<#
  github-proxy —— 「GitHub 加速前缀」的接线模块。
  build.ps1（stable 通道）与 build-next.ps1（DSH NEXT）共用，不单独执行。

  用法：脚本拿到 -GitHubProxy 的值后调 Initialize-GitHubProxy 一次，之后
  GitHub 的 HTTPS 地址就会自动套上前缀，不需要逐处改仓库地址。

  为什么用 git 的 insteadOf 而不是替换 URL 字符串：
    一次配置同时覆盖 clone / fetch / submodule update / ls-remote / 嵌套子模块，
    而且 .git/config 里的 origin、.gitmodules 里的子模块地址都不用动 ——
    去掉前缀就完全回到原状，没有「改过的仓库地址」残留在工作区里。

  生效方式（两条腿，互为兜底）：
    ① 进程环境变量 GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n
       （git ≥ 2.31）：本脚本随后调用的所有 git 命令、以及 git 自己 fork 出来的
       子进程（submodule 的嵌套 clone）都会读到，yarn / pnpm 内部调 git 也一样；
    ② 显式 -c 参数（Get-GitHubProxyGitArgs）：调用点可见、可读，且不依赖
       git 版本（老版本会静默忽略 ①，②仍然有效）。

  注意：只匹配 https://github.com/ —— SSH 形式（git@github.com:…）不会被重写。
  GitHub 的加速前缀服务对 SSH 无意义（它们只在 HTTP 层转发），要加速得先把
  remote 切成 HTTPS。
#>

<#
  归一化并校验加速前缀。'' / 空白 = 不启用（返回 ''），其余必须是 http(s) 地址。
  末尾斜杠会自动补齐 —— 服务端要求「前缀 + 完整原 URL」，少一个斜杠就变成
  https://gh-proxy.comhttps://github.com/... 这种拼坏的地址。
  @param Value 用户给的值，例如 'https://gh-proxy.com/' 或 'https://gh-proxy.com'
  @returns 归一化后的前缀（以 / 结尾）；未启用时返回 ''
#>
function Resolve-GitHubProxyPrefix {
  param([string]$Value = '')
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $prefix = $Value.Trim()
  if ($prefix -notmatch '^https?://') {
    throw "github-proxy: -GitHubProxy 必须以 http:// 或 https:// 开头（收到 '$Value'）。例如 https://gh-proxy.com/"
  }
  if ($prefix -match '\s') {
    throw "github-proxy: -GitHubProxy 不能包含空白字符（收到 '$Value'）。"
  }
  if ($prefix -notmatch '/$') { $prefix += '/' }
  return $prefix
}

<#
  把 insteadOf 映射写进当前进程的环境，让随后所有 git 命令都走前缀。
  幂等：先把「已有条目里同样指向 https://github.com/ 的映射」摘掉再写回，
  所以换前缀不会留下旧映射（否则两条同时匹配，git 会挑其中一条，结果看运气）。
  其它与 GitHub 无关的 GIT_CONFIG_* 条目原样保留。
  @param Prefix Resolve-GitHubProxyPrefix 的返回值；'' 时什么都不做
  @returns 实际写入的配置键（未启用时返回 $null）
#>
function Set-GitHubProxyGitConfig {
  param([string]$Prefix = '')
  if ([string]::IsNullOrEmpty($Prefix)) { return $null }
  $key = "url.${Prefix}https://github.com/.insteadOf"
  $value = 'https://github.com/'

  # 1) 收集现有条目，剔除「也作用于 https://github.com/」的旧映射（本模块自己写的那些）。
  $pairs = New-Object System.Collections.Generic.List[object]
  $count = 0
  if ($env:GIT_CONFIG_COUNT) {
    $parsed = 0
    if ([int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$parsed)) { $count = $parsed }
  }
  for ($i = 0; $i -lt $count; $i++) {
    $k = Get-Item -Path "Env:GIT_CONFIG_KEY_$i" -ErrorAction SilentlyContinue
    $v = Get-Item -Path "Env:GIT_CONFIG_VALUE_$i" -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    $isOurFamily = ($k.Value -like 'url.*https://github.com/.insteadOf') -and ($v -and $v.Value -eq $value)
    if ($isOurFamily) { continue }
    $pairs.Add([pscustomobject]@{ Key = $k.Value; Value = if ($v) { $v.Value } else { '' } })
  }

  # 2) 清空再按顺序写回，末尾追加本次的映射。
  foreach ($n in @([System.Environment]::GetEnvironmentVariables().Keys)) {
    if ($n -like 'GIT_CONFIG_COUNT' -or $n -like 'GIT_CONFIG_KEY_*' -or $n -like 'GIT_CONFIG_VALUE_*') {
      [System.Environment]::SetEnvironmentVariable($n, $null)
    }
  }
  $pairs.Add([pscustomobject]@{ Key = $key; Value = $value })
  $index = 0
  foreach ($pair in $pairs) {
    Set-Item -Path "Env:GIT_CONFIG_KEY_$index" -Value $pair.Key
    Set-Item -Path "Env:GIT_CONFIG_VALUE_$index" -Value $pair.Value
    $index++
  }
  Set-Item -Path 'Env:GIT_CONFIG_COUNT' -Value ([string]$index)
  return $key
}

<#
  给 git 命令准备的显式 -c 参数。未启用时返回空数组，调用点可以直接 splat：
    $gp = @(Get-GitHubProxyGitArgs $script:GitHubProxy)
    & git @gp -C $src fetch origin
  @param Prefix Resolve-GitHubProxyPrefix 的返回值
#>
function Get-GitHubProxyGitArgs {
  param([string]$Prefix = '')
  if ([string]::IsNullOrEmpty($Prefix)) { return @() }
  return @('-c', "url.${Prefix}https://github.com/.insteadOf=https://github.com/")
}

<#
  给一个普通 URL 套前缀（Electron 发行包之类直接走 HTTP 下载的地址）。
  未启用时原样返回。
  @param Prefix 归一化后的前缀
  @param Url    原始地址
#>
function Add-GitHubProxyToUrl {
  param(
    [string]$Prefix = '',
    [Parameter(Mandatory)][string]$Url
  )
  if ([string]::IsNullOrEmpty($Prefix)) { return $Url }
  return "$Prefix$Url"
}

<#
  一次性初始化：归一化 + 写环境变量，并把结果留在脚本作用域里给调用点用。
  @param Value  -GitHubProxy 的原始值
  @returns 归一化后的前缀（'' = 未启用）
#>
function Initialize-GitHubProxy {
  param([string]$Value = '')
  $prefix = Resolve-GitHubProxyPrefix $Value
  if ($prefix -ne '') { $null = Set-GitHubProxyGitConfig $prefix }
  return $prefix
}

<#
  兜底：把「被写进 .git/config 的前缀」还原掉。

  git 正常情况下**保存的是原始地址**（insteadOf 只在传输层改写），所以带前缀 clone 之后
  `.git/config` 里仍是 https://github.com/...；但 `git remote get-url` / `ls-remote --get-url`
  输出的是**改写后**的地址 —— 构建日志里看到带前缀的 URL 属于正常现象，不是工作区被污染。
  只有在有人手工 `git remote set-url` 成带前缀的地址、或别的工具这么写过时，才需要这条兜底：
  否则下次**不带** -GitHubProxy 的构建会悄悄继续走代理，代理挂了报错还很难懂。

  @param RepoPath 仓库根（其 .git/config 与 .git/modules 下的 config 都会被处理）
  @param Prefix   归一化后的前缀；'' 时什么都不做
  @returns 实际改回的条目（"key -> url" 形式），空数组表示无需改动
#>
function Reset-GitHubProxyRemotes {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$Prefix = ''
  )
  if ([string]::IsNullOrEmpty($Prefix)) { return @() }
  $changed = New-Object System.Collections.Generic.List[string]
  $configs = New-Object System.Collections.Generic.List[string]
  $top = Join-Path $RepoPath '.git\config'
  if (Test-Path -LiteralPath $top) { $configs.Add($top) }
  $modules = Join-Path $RepoPath '.git\modules'
  if (Test-Path -LiteralPath $modules) {
    Get-ChildItem -LiteralPath $modules -Recurse -Filter 'config' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $configs.Add($_.FullName) }
  }
  foreach ($cfg in $configs) {
    $lines = @(& git config --file $cfg --get-regexp '^(remote\..*\.url|submodule\..*\.url)$' 2>$null)
    foreach ($line in $lines) {
      $idx = $line.IndexOf(' ')
      if ($idx -lt 0) { continue }
      $key = $line.Substring(0, $idx)
      $val = $line.Substring($idx + 1).Trim()
      if (-not $val.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
      $clean = $val.Substring($Prefix.Length)
      & git config --file $cfg $key $clean 2>$null
      if ($LASTEXITCODE -eq 0) { $changed.Add("$key -> $clean") }
    }
  }
  return @($changed)
}
