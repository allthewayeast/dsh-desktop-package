#Requires -Version 7.0
<#
  dsh-web-access —— 「可控监听地址 + 可控启动 Token」的运行时补丁模块。
  build.ps1（stable 通道）与 build-next.ps1（DSH NEXT）共用，不单独执行。

  ⚠️ 这个补丁**默认不应用**。调用方只在显式要求时才调 Invoke-DshWebAccessPatch：
    build.ps1      看 -FixedTokenPatch
    build-next.ps1 看 -FixedTokenPatch / -ListenAllNetworkPatch
  不带开关的构建产物必须与上游一致，所以本模块不做任何自动调用，也不在 dot-source
  时产生副作用。

  两个开关对应两组改动（-Groups token / listen），互不依赖：
    token  = 让代码认识 DSH_WEB_TOKEN，启动 token 可以由外部定住
    listen = 允许绑定 0.0.0.0（本机所有网卡）

  ⚠️ 本模块**只管代码**，不写任何值。IP / Token 由用户在 exe 同级的 startup.json
  （或真实环境变量）里自己给 —— 构建参数不承载它们。

  改动对象是 @deepseek-ai 的**构建产物**（lib/*.js），不是源码：

    [token] 启动 token 的来源链变成  config.launchToken ?? $env:DSH_WEB_TOKEN ?? ""（空串=保持随机）
      旧结构（dsh 0.2.2 及以前）：dsh-client-connection/lib/index.js
      新结构（dsh 0.2.3+，上游把 token 逻辑拆成独立插件）：dsh-host-authentication-token/lib/index.js
      两套改动表并存，按包根里哪个文件真的含 BrowserAuth 选一套，另一套连读都不读。
      stable 通道仍是旧结构，next / beta 已是新结构 —— 共用本模块时不能只认一边。
    dsh-host-webserver/lib/index.js      [listen]
        ① host transform 放行通配地址（0.0.0.0 / ::）
        ② bindUrlHost 在通配绑定时给出回环 URL（否则打印/自动打开得到连不上的 http://0.0.0.0:…）
    dsh-web-app/lib/startup.js           [listen]
        ③ 删掉 `dsh web --host <通配地址>` 的 CLI 守卫

  移植自两个独立补丁项目（E:\开发代码\dsh-web-token-patch、dsh-wildcard-host-patch），
  保持同样的策略：**按代码形状锚定的正则**（空白容忍、不依赖行号）→ 命中就改，任一处
  不命中就整体放弃、零写入 → 写完跑 node --check，语法不过立刻从备份还原。

  与那两个脚本的有意差异：
    * 备份后缀统一成 .dsh-web-access.bak：dsh-host-webserver 同一个文件会被两类改动
      同时命中，用两个后缀分开备份会互相覆盖。
    * 一次处理多个 node_modules 根（工作区布局 <repo>/<ws>/node_modules/@deepseek-ai）。
    * 改动集仍是同样 8 处，不多不少。

  为什么要按「产物」而不是「源码」打：上游把 browser-auth / webserver 打包成单文件
  lib/index.js，版本间行号与周边代码都会漂移，静态 .diff 跨版本基本无法应用；而
  正则锚点在中版本升级里通常仍然命中。
#>

Set-StrictMode -Version Latest

$script:DshWebAccessBackupSuffix = '.dsh-web-access.bak'

# token 组有两个互斥的变体（旧/新结构），其余两个是 listen 组的必需产物。
$script:DshWebAccessFiles = @(
  'dsh-client-connection/lib/index.js'          # token · 旧结构
  'dsh-host-authentication-token/lib/index.js'  # token · 新结构
  'dsh-host-webserver/lib/index.js'             # listen
  'dsh-web-app/lib/startup.js'                  # listen
)

<#
  改动按能力分两组，由调用方的开关选择（-FixedTokenPatch / -ListenAllNetworkPatch）：

    token  —— 固定启动 Token：只动 token 来源链（旧结构 client-connection / 新结构 host-authentication-token）
    listen —— 监听所有网卡：放行 0.0.0.0 绑定 + 通配 URL 改回回环 + 删 CLI 守卫

  分组与文件是对应的（listen 只在 webserver/web-app）；token 的两个文件是**同一能力的
  两个版本变体**，Invoke-DshWebAccessPatch 会按代码形状二选一，不会同时打两套。
#>
$script:DshWebAccessGroups = @{
  'dsh-client-connection/lib/index.js'         = 'token'
  'dsh-host-authentication-token/lib/index.js' = 'token'
  'dsh-host-webserver/lib/index.js'            = 'listen'
  'dsh-web-app/lib/startup.js'                 = 'listen'
}

<# 已知的组名（拼错就报错，别静默什么都不打）。 #>
$script:DshWebAccessGroupNames = @('token', 'listen')

<#
  12 处改动 = 旧结构 token 5 + 新结构 token 4 + listen 3。字段含义：
    File        相对 @deepseek-ai 包根的目标文件
    Label       人读的改动说明（日志 / 报错都用它）
    Pattern     .NET 正则；凡不承载语义的空白一律写成 [\t ]* / \r?\n，以便跨版本存活
    Replacement .NET 替换串（$1=${1}，逐字保留原缩进与换行符）
    Count       替换次数：1=只替换首处（与原脚本的非全局正则等价），0=全部替换
    Multiline   是否开启 ^$ 多行语义（原脚本 /gm 的两条删除改动）
    Applied     判断「这处改动是否已经生效」的谓词，用于幂等与 --revert 后的核对
#>
$script:DshWebAccessEdits = @(
  # ---------------- dsh-client-connection：token 来源链 ----------------
  [pscustomobject]@{
    File        = 'dsh-client-connection/lib/index.js'
    Label       = 'client-connection Config：增加可选的 launchToken 键'
    Pattern     = '(cookieMaxAgeDays: z\.natural\(\)\.min\(1\)\.default\(30\),)(\r?\n)([ \t]*)(maxRequestBodyBytes: z\.natural\(\)\.min\(1\)\.default\(DEFAULT_MAX_REQUEST_BODY_BYTES\))'
    Replacement = '${1}${2}${3}launchToken: z.string(),${2}${3}${4}'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('launchToken: z.string()') }
  }
  [pscustomobject]@{
    File        = 'dsh-client-connection/lib/index.js'
    Label       = 'client-connection BrowserAuth 构造函数：接受固定 token'
    Pattern     = 'constructor\(processOwner, secret, maxAgeDays\) \{(\r?\n)([ \t]*)this\.secret = secret;(\r?\n)([ \t]*)this\.launchToken = processLaunchToken\(processOwner\);'
    Replacement = 'constructor(processOwner, secret, maxAgeDays, fixedToken) {${1}${2}this.secret = secret;${3}${4}this.launchToken = fixedToken === void 0 || fixedToken === "" ? processLaunchToken(processOwner) : fixedToken;'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('fixedToken') }
  }
  [pscustomobject]@{
    File        = 'dsh-client-connection/lib/index.js'
    Label       = 'client-connection BrowserAuth.create：透传固定 token'
    Pattern     = 'static async create\(processOwner, credentials, maxAgeDays\) \{(\r?\n)([ \t]*)return new BrowserAuth\(processOwner, await initializeSecret\(credentials\), maxAgeDays\);'
    Replacement = 'static async create(processOwner, credentials, maxAgeDays, fixedToken) {${1}${2}return new BrowserAuth(processOwner, await initializeSecret(credentials), maxAgeDays, fixedToken);'
    Count       = 1
    Multiline   = $false
    # 上一处改动同时引入了 fixedToken；两处都靠这个串判断已生效。
    Applied     = { param($text) $text.Contains('fixedToken') }
  }
  [pscustomobject]@{
    File        = 'dsh-client-connection/lib/index.js'
    Label       = 'client-connection apply()：解析 config > DSH_WEB_TOKEN > 空串，并校验长度'
    Pattern     = '([ \t]*)const cookieMaxAgeDays = config\?\.cookieMaxAgeDays \?\? 30;(\r?\n)'
    Replacement = '${1}const cookieMaxAgeDays = config?.cookieMaxAgeDays ?? 30;${2}${1}const launchToken = config?.launchToken ?? process.env.DSH_WEB_TOKEN ?? "";${2}${1}if (launchToken !== "" && !/^[A-Za-z0-9_-]{16,}$/u.test(launchToken)) throw new Error("client-connection: launchToken/DSH_WEB_TOKEN must be at least 16 characters from [A-Za-z0-9_-]");${2}'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('const launchToken = config?.launchToken') }
  }
  [pscustomobject]@{
    File        = 'dsh-client-connection/lib/index.js'
    Label       = 'client-connection apply()：把 token 传给 HostConnectionService'
    Pattern     = 'const connection = new HostConnectionService\(ctx, trustedHosts, await BrowserAuth\.create\(ctx\.root, ctx\.credentials, cookieMaxAgeDays\)\);'
    Replacement = 'const connection = new HostConnectionService(ctx, trustedHosts, await BrowserAuth.create(ctx.root, ctx.credentials, cookieMaxAgeDays, launchToken));'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('cookieMaxAgeDays, launchToken)') }
  }

  # ---------------- dsh-host-authentication-token：新结构（dsh 0.2.3+）的 token 来源链 ----------------
  # 上游把 BrowserAuth / processLaunchToken / Config 从 client-connection 拆成独立插件。
  # 锚点风格与旧结构一致（按代码形状、不依赖行号），语义也一致：
  #   config.launchToken > process.env.DSH_WEB_TOKEN > 随机（空串=保持上游行为）
  # Config 里其它字段都带 default，所以新键也用 default("")，避免无 default 字段在校验时变成必填。
  [pscustomobject]@{
    File        = 'dsh-host-authentication-token/lib/index.js'
    Label       = 'host-authentication-token Config：增加可选的 launchToken 键'
    Pattern     = 'const Config = z\.object\(\{ cookieMaxAgeDays: z\.natural\(\)\.min\(1\)\.default\(30\) \}\);'
    Replacement = 'const Config = z.object({ cookieMaxAgeDays: z.natural().min(1).default(30), launchToken: z.string().default("") });'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('launchToken: z.string().default("")') }
  }
  [pscustomobject]@{
    File        = 'dsh-host-authentication-token/lib/index.js'
    Label       = 'host-authentication-token BrowserAuth 构造函数：接受固定 token'
    Pattern     = 'constructor\(processOwner, secret, maxAgeDays\) \{(\r?\n)([ \t]*)this\.secret = secret;(\r?\n)([ \t]*)this\.launchToken = processLaunchToken\(processOwner\);'
    Replacement = 'constructor(processOwner, secret, maxAgeDays, fixedToken) {${1}${2}this.secret = secret;${3}${4}this.launchToken = fixedToken === void 0 || fixedToken === "" ? processLaunchToken(processOwner) : fixedToken;'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('this.launchToken = fixedToken === void 0') }
  }
  [pscustomobject]@{
    File        = 'dsh-host-authentication-token/lib/index.js'
    Label       = 'host-authentication-token BrowserAuth.create：透传固定 token'
    Pattern     = 'static async create\(processOwner, credentials, maxAgeDays\) \{(\r?\n)([ \t]*)return new BrowserAuth\(processOwner, await initializeSecret\(credentials\), maxAgeDays\);'
    Replacement = 'static async create(processOwner, credentials, maxAgeDays, fixedToken) {${1}${2}return new BrowserAuth(processOwner, await initializeSecret(credentials), maxAgeDays, fixedToken);'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('maxAgeDays, fixedToken);') }
  }
  [pscustomobject]@{
    File        = 'dsh-host-authentication-token/lib/index.js'
    Label       = 'host-authentication-token apply()：解析 config > DSH_WEB_TOKEN > 空串，校验长度并传给 BrowserAuth.create'
    Pattern     = '([ \t]*)const auth = await BrowserAuth\.create\(ctx\[Context\.root\], ctx\.credentials, config\.cookieMaxAgeDays\);(\r?\n)'
    Replacement = '${1}const launchToken = config?.launchToken ?? process.env.DSH_WEB_TOKEN ?? "";${2}${1}if (launchToken !== "" && !/^[A-Za-z0-9_-]{16,}$/u.test(launchToken)) throw new Error("host-authentication-token: launchToken/DSH_WEB_TOKEN must be at least 16 characters from [A-Za-z0-9_-]");${2}${1}const auth = await BrowserAuth.create(ctx[Context.root], ctx.credentials, config.cookieMaxAgeDays, launchToken);${2}'
    Count       = 1
    Multiline   = $false
    Applied     = { param($text) $text.Contains('const launchToken = config?.launchToken') }
  }

  # ---------------- dsh-host-webserver：通配地址 ----------------
  [pscustomobject]@{
    File        = 'dsh-host-webserver/lib/index.js'
    Label       = 'host-webserver Config：删除「通配地址即抛错」的 transform 守卫'
    Pattern     = '^[ \t]*if \(isWildcardAddress\(parsed\)\) throw new Error\(`webserver: host [^\r\n]*\r?\n'
    Replacement = ''
    Count       = 0
    Multiline   = $true
    Applied     = { param($text) -not $text.Contains('if (isWildcardAddress(parsed))') }
  }
  [pscustomobject]@{
    File        = 'dsh-host-webserver/lib/index.js'
    Label       = 'host-webserver bindUrlHost：通配地址的 URL 形式改写为回环'
    Pattern     = '(^[ \t]*)(const bare = zoneAt === -1 \? host : host\.slice\(0, zoneAt\);)(\r?\n)'
    Replacement = '${1}${2}${3}${1}if (isWildcardHost(bare)) return isIP(bare) === 6 ? "[::1]" : "127.0.0.1";${3}'
    Count       = 1
    Multiline   = $true
    Applied     = { param($text) $text.Contains('isWildcardHost(bare)') }
  }

  # ---------------- dsh-web-app：CLI 守卫 ----------------
  [pscustomobject]@{
    File        = 'dsh-web-app/lib/startup.js'
    Label       = 'web-app CLI：删除 `--host <通配地址>` 的 program.error 守卫'
    Pattern     = '^[ \t]*if \(options\.host !== void 0 && isWildcardHost\(options\.host\)\) program\.error\(`error: --host [^\r\n]*\r?\n'
    Replacement = ''
    Count       = 0
    Multiline   = $true
    Applied     = { param($text) -not $text.Contains('isWildcardHost(options.host)') }
  }
)

# ---------------- 目标发现 ----------------

<#
  判断一个目录是不是合格的 @deepseek-ai 包根。
  listen 组两个产物必须都在；token 组新旧两个变体**至少一个**在（stable 只有旧的，
  next / beta 只有新的）。两套都没有的根不是目标，避免把无关目录误当包根。
  @param Path 候选目录
  @returns 是否可用
#>
function Test-DshWebAccessRoot {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $tokenSeen = $false
  foreach ($rel in $script:DshWebAccessFiles) {
    $exists = Test-Path -LiteralPath (Join-Path $Path ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)) -PathType Leaf
    $group = $script:DshWebAccessGroups[$rel]
    if ($group -eq 'listen') {
      if (-not $exists) { return $false }
    } elseif ($group -eq 'token' -and $exists) {
      $tokenSeen = $true
    }
  }
  return $tokenSeen
}

<#
  在仓库里找出所有可打补丁的 @deepseek-ai 包根。
  yarn workspaces + nmHoistingLimits=workspaces 的布局是 <repo>/<workspace>/node_modules/@deepseek-ai，
  但也兼容 <repo>/node_modules/@deepseek-ai（提升后的单一 node_modules）。
  @param SearchRoot 仓库根（build 脚本里的 $script:Src），可给多个
  @returns 去重后的绝对路径数组；找不到时返回空数组（由调用方决定是报错还是跳过）
#>
function Find-DshWebAccessRoots {
  param([Parameter(Mandatory)][string[]]$SearchRoot)
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($root in $SearchRoot) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidates = New-Object System.Collections.Generic.List[string]
    # ① 调用方直接给了 @deepseek-ai 包根
    $candidates.Add($root)
    # ② 仓库根自己的 node_modules
    $candidates.Add((Join-Path $root 'node_modules\@deepseek-ai'))
    # ③ 每个工作区各自的 node_modules（本仓库的实际布局）
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
      $candidates.Add((Join-Path $dir.FullName 'node_modules\@deepseek-ai'))
    }
    foreach ($candidate in $candidates) {
      if (Test-DshWebAccessRoot -Path $candidate) {
        $full = (Resolve-Path -LiteralPath $candidate).Path
        if (-not ($found | Where-Object { $_ -eq $full })) { $found.Add($full) }
      }
    }
  }
  # 越深的路径越具体（工作区优先于仓库根），保持不变即可 —— 调用方按顺序全部处理。
  return $found.ToArray()
}

# ---------------- 正则编辑引擎 ----------------

function ConvertTo-DshWebAccessRegex {
  param(
    [Parameter(Mandatory)][string]$Pattern,
    [Parameter(Mandatory)][bool]$Multiline
  )
  $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
  if ($Multiline) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::Multiline }
  return [System.Text.RegularExpressions.Regex]::new($Pattern, $options, [TimeSpan]::FromSeconds(5))
}

<#
  覆盖一个文件的内容，**且断开硬链接**。
  yarn 的 node-modules linker 默认从全局缓存硬链接文件（nmMode: hardlinks-global）：
  原地截断重写会连带改掉缓存里那份原件，进而污染其它工程 / 让后续 install 的校验失败。
  所以先写同目录临时文件，再删原文件、把临时文件改名过去 —— 新文件是独立 inode，
  缓存那份保持 pristine，下一次 install 也能正常还原。
  @param Path    目标文件
  @param Content 新内容
  @param KeepBom 原文件带 UTF-8 BOM 时继续带（编译产物通常没有）
#>
function Set-DshWebAccessFileContent {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
    [switch]$KeepBom
  )
  $tmp = "$Path.dsh-web-access.tmp"
  $utf8 = [System.Text.UTF8Encoding]::new($KeepBom.IsPresent)
  [System.IO.File]::WriteAllText($tmp, $Content, $utf8)
  # File.Delete + Move 是「换 inode」的最小写法；File.Replace 需要目标已存在且语义更绕。
  [System.IO.File]::Delete($Path)
  [System.IO.File]::Move($tmp, $Path)
}

<#
  读一个文件，同时告诉调用方它原本有没有 UTF-8 BOM。
  @param Path 目标文件
  @returns @{ Text = [string]; HasBom = [bool] }
#>
function Read-DshWebAccessFileContent {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  return [pscustomobject]@{ Text = [System.IO.File]::ReadAllText($Path); HasBom = $hasBom }
}

<#
  在内存里把某一份产物的改动全部算出来，不做任何写盘。
  @param Path   目标文件绝对路径
  @param File   相对包根的路径（用来筛改动集）
  @returns @{ Path, File, Original, Content, HasBom, Applied=@(), Pending=@(), Failed=@() }
#>
function Get-DshWebAccessFilePlan {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$File
  )
  $read = Read-DshWebAccessFileContent -Path $Path
  $original = $read.Text
  $content = $original
  $applied = New-Object System.Collections.Generic.List[string]
  $pending = New-Object System.Collections.Generic.List[string]
  $failed = New-Object System.Collections.Generic.List[string]
  foreach ($edit in $script:DshWebAccessEdits) {
    if ($edit.File -cne $File) { continue }
    # Applied 一律对**原始内容**求值，不看中间结果：
    # 同一文件上相邻的两处改动可能共用同一个指纹（构造函数与 create 都由 fixedToken 标记），
    # 若拿改完的中间内容判断，后一处会被误判成「已生效」而永远打不上。
    if (& $edit.Applied $original) { $applied.Add($edit.Label); continue }
    $regex = ConvertTo-DshWebAccessRegex -Pattern $edit.Pattern -Multiline $edit.Multiline
    # 注意：.NET 的 Replace(input, replacement, 0) 表示「一次都不替换」，不是「全部替换」。
    # 「全部替换」必须走两参数重载，所以 Count<=0 在这里单独分支。
    $next = if ([int]$edit.Count -le 0) { $regex.Replace($content, $edit.Replacement) } else { $regex.Replace($content, $edit.Replacement, [int]$edit.Count) }
    if ($next -ceq $content) { $failed.Add($edit.Label); continue }
    $content = $next
    $pending.Add($edit.Label)
  }
  return [pscustomobject]@{
    Path     = $Path
    File     = $File
    Original = $original
    Content  = $content
    HasBom   = $read.HasBom
    Applied  = $applied.ToArray()
    Pending  = $pending.ToArray()
    Failed   = $failed.ToArray()
  }
}

<#
  用 node --check 校验一个文件。只把真正的语法错误当失败：
  子进程因环境原因起不来、或 .js 被当 CJS 解析（"Cannot use import statement outside a module"）
  都只算警告 —— 原补丁脚本就是这套语义，照搬以免误把好文件回滚。
  @param Path 目标文件
  @returns @{ Ok = [bool]; Message = [string] }
#>
function Test-DshWebAccessSyntax {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ Ok = $true; Message = '未找到 node，跳过语法校验' }
  }
  $prev = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $output = @(& node --check $Path 2>&1)
    $code = $LASTEXITCODE
  } catch {
    return [pscustomobject]@{ Ok = $true; Message = "无法执行 node --check（$($_.Exception.Message)）" }
  } finally {
    $PSNativeCommandUseErrorActionPreference = $prev
  }
  if ($code -eq 0) { return [pscustomobject]@{ Ok = $true; Message = 'node --check 通过' } }
  $text = ($output | Out-String)
  if ($text -match 'outside a module|Unexpected token ''export''') {
    return [pscustomobject]@{ Ok = $true; Message = 'node --check 以 CJS 模式解析了 ESM（可忽略）' }
  }
  if ($text -notmatch 'SyntaxError') {
    return [pscustomobject]@{ Ok = $true; Message = "node --check 异常退出但无语法错误（exit $code）" }
  }
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 3)
  return [pscustomobject]@{ Ok = $false; Message = ($lines -join ' | ') }
}

# ---------------- 对外入口 ----------------

<#
  给一个 @deepseek-ai 包根打/检/还原 web 访问补丁。
  @param PackagesRoot 包根（含 token 变体之一 + dsh-host-webserver / dsh-web-app）
  @param Groups       只处理这些组：token（固定 Token）/ listen（监听所有网卡）；默认两组都处理
  @param Check        只报告能不能打，不写盘
  @param Revert       从 .dsh-web-access.bak 还原
  @returns @{ Root; Written=@(); Already=@(); Restored=@(); Messages=@() }
#>
function Invoke-DshWebAccessPatch {
  param(
    [Parameter(Mandatory)][string]$PackagesRoot,
    [string[]]$Groups = $script:DshWebAccessGroupNames,
    [switch]$Check,
    [switch]$Revert
  )
  foreach ($group in $Groups) {
    if ($script:DshWebAccessGroupNames -notcontains $group) {
      throw "dsh-web-access: 未知的补丁组 '$group'（可用：$($script:DshWebAccessGroupNames -join '、')）"
    }
  }
  # 先按组筛出这次要碰的文件；不相关的文件连读都不读。
  $targets = @($script:DshWebAccessFiles | Where-Object {
      $fileGroup = $script:DshWebAccessGroups[$_]
      ($null -eq $fileGroup) -or ($Groups -contains $fileGroup)
    })
  # token 组是「旧/新结构二选一」：按文件里是否真的有 BrowserAuth 判断，而不是按文件
  # 存在与否 —— next 的 client-connection 仍在，但 token 代码已被拆到新包，旧改动表必然失配。
  # 两个变体都不适用时（上游又挪一次）就把 token 组整个跳过、只打 listen，由产物核对
  # 暴露能力缺失，比在这里把整个构建卡死更稳妥。
  if ($Groups -contains 'token') {
    $legacy = 'dsh-client-connection/lib/index.js'
    $modern = 'dsh-host-authentication-token/lib/index.js'
    $hasBrowserAuth = {
      param($rel)
      $full = Join-Path $PackagesRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
      return ([System.IO.File]::ReadAllText($full)).Contains('class BrowserAuth')
    }
    if (& $hasBrowserAuth $modern) {
      $drop = @($legacy)
    } elseif (& $hasBrowserAuth $legacy) {
      $drop = @($modern)
    } else {
      $drop = @($legacy, $modern)
    }
    $targets = @($targets | Where-Object { $drop -notcontains $_ })
  }
  $result = [pscustomobject]@{
    Root     = $PackagesRoot
    Written  = @()
    Already  = @()
    Restored = @()
    Messages = @()
  }
  $messages = New-Object System.Collections.Generic.List[string]

  if ($Revert) {
    foreach ($rel in $targets) {
      $file = Join-Path $PackagesRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      $backup = "$file$($script:DshWebAccessBackupSuffix)"
      if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { continue }
      $restore = Read-DshWebAccessFileContent -Path $backup
      Set-DshWebAccessFileContent -Path $file -Content $restore.Text -KeepBom:$restore.HasBom
      $result.Restored += $rel
    }
    $result.Messages = $messages.ToArray()
    return $result
  }

  # 计划：全部在内存里算完。任何一处锚点失配 → 整体放弃、零写入。
  $plans = New-Object System.Collections.Generic.List[object]
  foreach ($rel in $targets) {
    $file = Join-Path $PackagesRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw "dsh-web-access: 缺少目标文件 $file（这个版本的包结构变了？）"
    }
    $plan = Get-DshWebAccessFilePlan -Path $file -File $rel
    if ($plan.Failed.Count -gt 0) {
      throw ("dsh-web-access: 以下改动无法匹配，未写入任何文件：`n" +
        (($plan.Failed | ForEach-Object { "  - $_" }) -join "`n") +
        "`n目标：$file`n上游重构了这段代码；请按新结构更新 tools\dsh-web-access.ps1 的改动表。")
    }
    $plans.Add($plan)
  }

  $writes = @($plans | Where-Object { $_.Pending.Count -gt 0 })
  $result.Already = @($plans | Where-Object { $_.Pending.Count -eq 0 } | ForEach-Object { $_.File })

  if ($writes.Count -eq 0) {
    $messages.Add("已打过补丁，无需处理（$($Groups -join '、')）：$PackagesRoot")
    $result.Messages = $messages.ToArray()
    return $result
  }

  if ($Check) {
    foreach ($plan in $writes) {
      foreach ($label in $plan.Pending) { $messages.Add("可打上：$($plan.File) — $label") }
    }
    $result.Messages = $messages.ToArray()
    $result.Written = @($writes | ForEach-Object { $_.File })
    return $result
  }

  # 写盘：先备份（pristine 原件才配当备份），再写内容，最后逐个语法校验；任何一步失败整体回滚。
  $touched = New-Object System.Collections.Generic.List[object]
  try {
    foreach ($plan in $writes) {
      $backup = "$($plan.Path)$($script:DshWebAccessBackupSuffix)"
      $pristine = ($plan.Applied.Count -eq 0)
      if ($pristine -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        Copy-Item -LiteralPath $plan.Path -Destination $backup -Force
      }
      Set-DshWebAccessFileContent -Path $plan.Path -Content $plan.Content -KeepBom:$plan.HasBom
      $touched.Add($plan)
      # ⚠️ 变量别叫 $check：PowerShell 变量不区分大小写，会撞上本函数的 [switch]$Check 参数。
      $syntax = Test-DshWebAccessSyntax -Path $plan.Path
      if (-not $syntax.Ok) {
        throw "dsh-web-access: $($plan.File) 打补丁后语法校验失败：$($syntax.Message)"
      }
      $messages.Add("已打补丁：$($plan.File)（$($plan.Pending.Count) 处）· $($syntax.Message)")
    }
  } catch {
    foreach ($plan in $touched) {
      $backup = "$($plan.Path)$($script:DshWebAccessBackupSuffix)"
      if (Test-Path -LiteralPath $backup -PathType Leaf) {
        $restore = Read-DshWebAccessFileContent -Path $backup
        Set-DshWebAccessFileContent -Path $plan.Path -Content $restore.Text -KeepBom:$restore.HasBom
      }
    }
    throw "$($_.Exception.Message)`n已从备份还原，目标目录未被改动。"
  }

  $result.Written = @($writes | ForEach-Object { $_.File })
  $result.Messages = $messages.ToArray()
  return $result
}

# ---------------- startup.json 配置指引 ----------------

<#
  补丁只解决「代码能不能读这些环境变量」。**值本身不由构建参数承载** ——
  用户在 exe 同级的 startup.json（或真实环境变量）里自己写。
  这里生成一段可直接抄进 startup.json 的样例，构建结束时打印给人看。
  @param FixedToken       打了固定 Token 补丁
  @param ListenAllNetwork 打了监听所有网卡补丁
  @returns 若干行 "键": "值" 文本（不含外层花括号与缩进，调用方自行排版）
#>
function Get-DshWebAccessStartupGuide {
  param(
    [switch]$FixedToken,
    [switch]$ListenAllNetwork
  )
  $lines = New-Object System.Collections.Generic.List[string]
  if ($ListenAllNetwork) {
    $lines.Add('"DSH_WEB_HOST": "0.0.0.0"')
    # 与上游 DSH_NEXT_TRUSTED_HOSTS 同格式：JSON 数组（在 env 里要当字符串写，所以引号需转义）。
    # 引擎侧同时接受逗号分隔，嫌转义麻烦可以整行换成 "1.2.3.4,5.6.7.8"。
    $lines.Add('"DSH_WEB_TRUSTED_HOSTS": "[\"<其它机器的 IP>\"]"')
  }
  # 端口：两个开关任一给了就认这个变量（源码侧补丁是共用的）。
  # 不写 = 沿用设置里的 port；写 0 = 让系统挑一个（每次启动都会变，远程访问别用）。
  if ($FixedToken -or $ListenAllNetwork) {
    $lines.Add('"DSH_WEB_PORT": "<1-65535，例如 3080>"')
  }
  if ($FixedToken) {
    $lines.Add('"DSH_WEB_TOKEN": "<至少 16 位，字符集 A-Za-z0-9_- >"')
  }
  return $lines.ToArray()
}

