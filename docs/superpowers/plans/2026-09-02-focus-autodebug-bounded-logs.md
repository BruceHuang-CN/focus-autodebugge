# Focus Auto Debug Bounded Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 `collect-only` 入口中加入有界、只读、Focus 归属明确的 logcat 与崩溃证据采集，同时确保其他应用日志、完整序列号和常见密钥不会进入报告。

**Architecture:** 继续使用现有单一 `debug-focus.ps1` 和可注入 fake ADB，不在本阶段拆分 PowerShell 模块。脚本只调用带显式 `-s <serial>` 的 `logcat -d -T ... -v threadtime`，原始 logcat 仅存在内存中；先解析 PID/包名归属、再脱敏、最后只写 Focus 相关行。明确 Focus 崩溃使 `overall=FAIL` 和退出码为 `30`，其他应用崩溃不得生成 Focus 崩溃附件。

**Tech Stack:** PowerShell 7.6、Windows/.NET `System.Diagnostics.Process`、Android Platform Tools ADB、threadtime logcat、JSON、自包含 fake-ADB 测试，无 Pester 或其他新增依赖。

**Spec:** `D:\focus-autodebug\docs\specs\2026-09-02-focus-autodebug-collect-only-design.md`；安全边界补充见 `D:\focus-autodebug\docs\specs\2026-09-02-focus-autodebug-safe-automation-roadmap-design.md`

## Global Constraints

- 工具根目录固定为 `D:\focus-autodebug`。
- 当前实现基线固定为 `8906662aba6d11b42100e9a0ca5a04c386c8bb75`；执行前必须确认分支为 `codex/collect-only-small-tests`，不得直接修改 `main`。
- 本计划只实现路线图方案 A；不实现 preflight、构建、安装、instrumentation、UI Automator、权限修改或 ColorOS 自动点击。
- 默认模式保持 `collect-only`；`schemaVersion` 保持 `1`；检查 ID 保持现有九项。
- 目标包名必须来自现有 `-PackageName`，生产日志代码不得硬编码 `com.example.focus_app`。
- `LogWindowMinutes` 保持 `1..60`，默认 `10`。
- 唯一新增真实设备命令为 `adb -s <serial> logcat -d -T <timestamp> -v threadtime`；不得使用 `logcat -c`、`--clear`、`-f` 或全量落盘。
- 原始 logcat 只能保存在进程内存；附件只能包含已判定属于 Focus 的行。
- 完整设备序列号、其他应用日志行、其他应用崩溃、Authorization token 和 API Key 不得写入附件、摘要或控制台。
- 日志读取失败是诊断项失败：`logs.focus=FAIL`、`logs.crash=SKIP`，但必需检查全部通过时不单独改变 `overall` 或退出码。
- 明确 Focus 崩溃：`logs.crash=FAIL`、`overall=FAIL`、进程退出码 `30`。
- 其他应用崩溃：`logs.crash=PASS`、`overall` 不受影响、不得创建 `crash-focus.txt`。
- 任一日志附件写入失败：`collectionFailed=true`、对应 artifact 为 `null`、`overall=FAIL`、退出码 `30`。
- 全部测试必须显式使用 `tests/fixtures/fake-adb.ps1`；离线任务不得连接真实 ADB 或手机。
- 不新增 Pester、第三方 PowerShell 模块、日志解析库、数据库或网络上传。
- 本计划中的提交只保存在本地功能分支，未经用户再次明确要求不得推送。

---

## File Map

| 文件 | 本计划职责 |
|---|---|
| `debug-focus.ps1` | 保存内部 PID 列表；形成 logcat 时间窗口；解析 threadtime；判定 Focus 归属；脱敏；写有限日志/崩溃附件；更新检查、overall 和退出码。 |
| `tests/fixtures/fake-adb.ps1` | 为正常、无匹配、其他应用崩溃、Focus 崩溃、读取失败和密钥日志提供确定输出；严格拒绝所有未定义 logcat 参数向量。 |
| `tests/debug-focus.Tests.ps1` | 扩展动态只读白名单；断言日志归属、崩溃隔离、密钥脱敏、附件失败语义、退出码和原 20 个场景不回归。 |
| `README.md` | 说明日志窗口、输出文件、退出码、隐私限制和离线测试命令。 |

生产接口在本计划中固定为：

```powershell
ConvertFrom-ThreadtimeLine -Line <string> -> PSCustomObject|null {
    Raw, Timestamp, ProcessId, ThreadId, Priority, Tag, Message
}

Protect-FocusLogLine -Line <string> -> <string>

Get-FocusLogSnapshot `
    -AdbPath <string> `
    -Serial <string> `
    -PackageName <string> `
    -ProcessIds <string[]> `
    -Since <DateTimeOffset> `
    -> PSCustomObject {
        FocusLines: string[]
        CrashLines: string[]
        FocusCrashDetected: bool
        Error: string|null
    }
```

`Get-AppSnapshot` 增加仅供进程内使用的 `ProcessIds: string[]`。`summary.json` 和 `focus-state.txt` 不新增 PID 字段。

---

### Task 1: 正常 Focus 日志的命令契约、归属过滤和附件

**Files:**
- Modify: `tests/fixtures/fake-adb.ps1:23-82`
- Modify: `tests/debug-focus.Tests.ps1:19-119,214-275,448-490`
- Modify: `debug-focus.ps1:232-347,349-364,366-539`

**Interfaces:**
- Consumes: `Invoke-Adb`、`Get-AppSnapshot`、`Write-DebugAttachment`、`LogWindowMinutes`、已选 `Serial` 和 `PackageName`。
- Produces: `Get-AppSnapshot.ProcessIds`、`ConvertFrom-ThreadtimeLine`、`Protect-FocusLogLine`、`Get-FocusLogSnapshot` 的正常日志路径、`logcat-focus.txt`、`logs.focus=PASS` 和 `logs.crash=PASS`。

- [ ] **Step 1: 在 fake ADB 中定义精确 logcat 参数识别和健康输出**

在 `tests/fixtures/fake-adb.ps1` 计算 `$tail` 后加入结构化判定。参数必须恰好为六段尾参数，时间戳必须匹配固定格式：

```powershell
$isLogcatRead = $tail.Count -eq 6 -and
    $tail[0] -ceq 'logcat' -and
    $tail[1] -ceq '-d' -and
    $tail[2] -ceq '-T' -and
    $tail[3] -cmatch '^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$' -and
    $tail[4] -ceq '-v' -and
    $tail[5] -ceq 'threadtime'

if ($isLogcatRead) {
    @"
09-02 20:00:00.000  2468  2468 I FocusDebug: Focus startup complete
09-02 20:00:00.010  9000  9000 I OtherApp: OTHER_PRIVATE_SENTINEL
09-02 20:00:00.020  2468  2469 I FocusDebug: package=$fixturePackage ready
"@
    exit 0
}
```

将 fixture 中的默认包名插值为 `$fixturePackage`，不要在动态输出中固定默认包名。严格白名单测试还要直接拒绝：`LOGCAT`、`logcat -c`、缺少 `-T`、非法时间戳和尾部 `EXTRA`。

- [ ] **Step 2: 扩展测试侧动态 ADB 白名单**

在 `Assert-FakeAdbReadOnlyCalls` 中保留现有静态 `$allowedShellTails`，另为八段完整参数加入唯一动态分支：

```powershell
$allowedLogcat = $parts.Count -eq 8 -and
    $parts[0] -ceq '-s' -and
    $parts[1] -ceq $SelectedSerial -and
    $parts[2] -ceq 'logcat' -and
    $parts[3] -ceq '-d' -and
    $parts[4] -ceq '-T' -and
    $parts[5] -cmatch '^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$' -and
    $parts[6] -ceq '-v' -and
    $parts[7] -ceq 'threadtime'
```

只有 `$allowedLogcat` 为真时才允许该调用；显式断言调用记录不包含 tab 分隔的 `-c` 或 `--clear`。

- [ ] **Step 3: 写正常日志失败测试**

在健康场景中新增断言：

```powershell
Assert-Equal 'PASS' (Get-Check $healthy.Summary 'logs.focus').status 'Focus 日志检查状态错误'
Assert-Equal 'PASS' (Get-Check $healthy.Summary 'logs.crash').status '无崩溃场景状态错误'
Assert-Equal 'logcat-focus.txt' $healthy.Summary.artifacts.focusLogcat 'Focus 日志附件路径错误'
Assert-Equal $null $healthy.Summary.artifacts.crashLog '健康场景不应存在崩溃附件'

$focusLog = Get-Content -LiteralPath (Join-Path $healthy.OutputRoot 'logcat-focus.txt') -Raw -Encoding UTF8
if ($focusLog -notmatch 'Focus startup complete') { throw 'Focus PID 日志未保留' }
if ($focusLog -notmatch [regex]::Escape($healthy.PackageName)) { throw 'Focus 包名日志未保留' }
if ($focusLog -match 'OTHER_PRIVATE_SENTINEL') { throw '其他应用日志泄露到 Focus 附件' }
```

清理仍放在该场景原有 `finally` 中。本任务扩展既有 `healthy-device-and-app-state`，不重复运行同一个健康 fixture，也不新增虚假的场景计数。

- [ ] **Step 4: 运行完整离线套件，确认 RED**

Run:

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
```

Expected: 退出码 `1`；新增健康日志断言失败，原因是 `logs.focus`/`logs.crash` 仍为 `SKIP` 或附件不存在；原 20 个场景继续通过。

- [ ] **Step 5: 保存 `pidof` 的内部 PID 列表**

在 `Get-AppSnapshot` 的 `$snapshot` 中加入：

```powershell
ProcessIds = @()
```

`pidof` 退出 `0` 且输出非空时保持既有 `ProcessAlive=true` 语义，同时只把纯数字 token 保存为内部 PID：

```powershell
$snapshot.ProcessIds = @(
    $processOutput -split '\s+' |
        Where-Object { $_ -cmatch '^\d+$' }
)
```

退出 `0` 空输出或退出 `1` 且 stdout/stderr 为空时，`ProcessIds=@()`；其他失败也保持空数组。不得把 PID 加入 summary 或 `focus-state.txt`。

- [ ] **Step 6: 实现 threadtime 解析和密钥脱敏基础函数**

在 `Write-DebugAttachment` 前加入：

```powershell
function ConvertFrom-ThreadtimeLine {
    param([string]$Line)
    $pattern = '^(?<timestamp>\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+(?<pid>\d+)\s+(?<tid>\d+)\s+(?<priority>[VDIWEF])\s+(?<tag>[^:]+):\s?(?<message>.*)$'
    if ($Line -cnotmatch $pattern) { return $null }
    [pscustomobject]@{
        Raw = $Line
        Timestamp = $matches.timestamp
        ProcessId = $matches.pid
        ThreadId = $matches.tid
        Priority = $matches.priority
        Tag = $matches.tag.Trim()
        Message = $matches.message
    }
}

function Protect-FocusLogLine {
    param([string]$Line)
    $redacted = $Line -replace '(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+', '$1[REDACTED]'
    $redacted = $redacted -replace '(?i)((?:api[-_ ]?key|token)\s*[:=]\s*)[^\s,;]+', '$1[REDACTED]'
    return $redacted
}
```

第一任务只验证函数不会扩大日志范围；密钥专门回归在 Task 3 完成。

- [ ] **Step 7: 实现 `Get-FocusLogSnapshot` 的正常归属路径**

使用设备本地格式的 host 时间字符串：

```powershell
$timestamp = $Since.LocalDateTime.ToString(
    'MM-dd HH:mm:ss.fff',
    [Globalization.CultureInfo]::InvariantCulture
)
$result = Invoke-Adb -AdbPath $AdbPath -Arguments @(
    '-s', $Serial, 'logcat', '-d', '-T', $timestamp, '-v', 'threadtime'
)
```

函数先解析所有 threadtime 行。第一遍从传入 `$ProcessIds` 和匹配 `Process: <PackageName>, PID: <digits>` 的行建立 Focus PID 集合；第二遍仅保留以下行：

```powershell
$packagePattern = [regex]::Escape($PackageName)
$belongsToFocus = $parsed.ProcessId -in $focusPidSet -or
    $parsed.Raw -cmatch $packagePattern
```

只对 `$belongsToFocus` 的原始行调用 `Protect-FocusLogLine`。不得收集固定前后行窗口，因为相邻行可能属于微信或其他应用。正常路径返回 `FocusLines`；Task 1 暂时返回空 `CrashLines` 和 `FocusCrashDetected=false`。

- [ ] **Step 8: 编排日志检查和附件**

仅在 `$appSnapshot.Installed -eq $true` 后调用：

```powershell
$logSnapshot = Get-FocusLogSnapshot `
    -AdbPath $resolvedAdb `
    -Serial $selectedSerial `
    -PackageName $PackageName `
    -ProcessIds $appSnapshot.ProcessIds `
    -Since ([DateTimeOffset]::Now.AddMinutes(-$LogWindowMinutes))
```

正常有匹配时写 `logcat-focus.txt` 并设置 `artifacts.focusLogcat`；无匹配时不创建附件，`logs.focus=PASS`，message 为“时间窗口内没有 Focus 相关日志”。Task 1 没有崩溃时设置 `logs.crash=PASS`。

附件写入必须包在局部 `try/catch`；catch 设置 `$collectionFailed=true`，不设置 artifact。把最终退出码计算移到日志编排之后，并固定：

```powershell
$exitCode = if ($requiredNotPassed) {
    10
} elseif ($collectionFailed -or $focusCrashDetected) {
    30
} else {
    0
}
```

- [ ] **Step 9: 运行完整离线套件，确认 GREEN**

Run:

```powershell
& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
```

Expected: 新健康日志场景通过；完整套件退出 `0`；调用记录只有原八类读取命令和一个精确 `logcat -d -T ... -v threadtime`，不存在 `-c`。

- [ ] **Step 10: 提交 Task 1**

```powershell
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug add debug-focus.ps1 tests/debug-focus.Tests.ps1 tests/fixtures/fake-adb.ps1
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug commit -m "feat: collect bounded focus logs"
```

---

### Task 2: Focus 崩溃归属与其他应用崩溃隔离

**Files:**
- Modify: `tests/fixtures/fake-adb.ps1`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1` (`Get-FocusLogSnapshot` 和日志编排分支)

**Interfaces:**
- Consumes: Task 1 的 threadtime 解析结果、Focus PID 集合、`Get-FocusLogSnapshot` 返回对象和 `$focusCrashDetected`。
- Produces: `foreign-crash`/`focus-crash` 场景、明确的 Focus 崩溃归属算法、`crash-focus.txt`、`logs.crash` 和崩溃退出码 `30`。

- [ ] **Step 1: 增加其他应用与 Focus 崩溃 fixture**

在 `$isLogcatRead` 分支中先按 scenario 返回：

```powershell
if ($scenario -ceq 'foreign-crash') {
    @"
09-02 20:00:00.000  9000  9000 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  9000  9000 E AndroidRuntime: Process: com.other.app, PID: 9000
09-02 20:00:00.002  9000  9000 E AndroidRuntime: java.lang.IllegalStateException: FOREIGN_CRASH_SENTINEL
09-02 20:00:01.000  2468  2468 I FocusDebug: package=$fixturePackage healthy
"@
    exit 0
}
if ($scenario -ceq 'focus-crash') {
    @"
09-02 20:00:00.000  2468  2468 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  2468  2468 E AndroidRuntime: Process: $fixturePackage, PID: 2468
09-02 20:00:00.002  2468  2468 E AndroidRuntime: java.lang.IllegalStateException: FOCUS_CRASH_SENTINEL
"@
    exit 0
}
```

这两个场景仍返回正常的 `pm path`、provenance、pidof 和无障碍状态。

- [ ] **Step 2: 写崩溃隔离失败测试**

```powershell
$foreign = Invoke-DebugCase -Scenario 'foreign-crash'
try {
    Assert-Equal 0 $foreign.ExitCode '其他应用崩溃不应使脚本失败'
    Assert-Equal 'PASS' $foreign.Summary.overall '其他应用崩溃被计入总体结果'
    Assert-Equal 'PASS' (Get-Check $foreign.Summary 'logs.crash').status '其他应用崩溃被误报'
    Assert-Equal $null $foreign.Summary.artifacts.crashLog '其他应用崩溃不应生成 Focus 崩溃附件'
    $focusText = Get-Content -LiteralPath (Join-Path $foreign.OutputRoot 'logcat-focus.txt') -Raw -Encoding UTF8
    if ($focusText -match 'FOREIGN_CRASH_SENTINEL|com\.other\.app') { throw '其他应用崩溃泄露到 Focus 日志' }
}
finally { Remove-Item -LiteralPath $foreign.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }

$focusCrash = Invoke-DebugCase -Scenario 'focus-crash'
try {
    Assert-Equal 30 $focusCrash.ExitCode 'Focus 崩溃必须返回诊断失败退出码'
    Assert-Equal 'FAIL' $focusCrash.Summary.overall 'Focus 崩溃必须使 overall 失败'
    Assert-Equal 'FAIL' (Get-Check $focusCrash.Summary 'logs.crash').status 'Focus 崩溃检查状态错误'
    Assert-Equal 'crash-focus.txt' $focusCrash.Summary.artifacts.crashLog 'Focus 崩溃附件路径错误'
    $crashText = Get-Content -LiteralPath (Join-Path $focusCrash.OutputRoot 'crash-focus.txt') -Raw -Encoding UTF8
    if ($crashText -notmatch 'FOCUS_CRASH_SENTINEL') { throw 'Focus 崩溃附件缺少异常证据' }
}
finally { Remove-Item -LiteralPath $focusCrash.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }
```

把两个 scenario 加入 `Invoke-DebugCase` 的 `$expectedSerial='TEST123'` 集合。

- [ ] **Step 3: 运行新增测试，确认 RED**

Run:

```powershell
& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
```

Expected: `foreign-crash` 可以继续为绿，但 `focus-crash` 因 `logs.crash=PASS`、缺少附件或退出码仍为 0 而失败。

- [ ] **Step 4: 实现两遍式崩溃归属**

第一遍收集 Focus PID：

- `pidof` 返回的数字 PID。
- message 严格匹配 `^Process:\s*<escapedPackage>,\s*PID:\s*(\d+)\s*$` 时捕获的 PID。
- tombstone 行严格包含 `>>> <escapedPackage> <<<` 时，从同一行解析 `pid: <digits>`。

第二遍只在 Focus 归属行中检测：

```powershell
$fatal = $parsed.Message -cmatch '^FATAL EXCEPTION:' -and $parsed.ProcessId -in $focusPidSet
$anr = $parsed.Message -cmatch "^ANR in $packagePattern(?:\s|$)"
$tombstone = $parsed.Message -cmatch ">>>\s*$packagePattern\s*<<<"
```

`FocusCrashDetected = $fatal -or $anr -or $tombstone`。`CrashLines` 只包含：

- 属于已确认 Focus PID 的 `AndroidRuntime` 行；
- 包含 `ANR in <package>` 的行；
- 包含 `>>> <package> <<<` 的 tombstone 行。

不得使用“崩溃行前后固定 N 行”的算法。

- [ ] **Step 5: 编排 `crash-focus.txt` 与总体结果**

`FocusCrashDetected=false` 时：

```powershell
Set-DebugCheck -Summary $summary -Id 'logs.crash' -Status 'PASS' -Message $null
```

`true` 时写 `crash-focus.txt`，设置 artifact 和检查：

```powershell
$focusCrashDetected = $true
Set-DebugCheck -Summary $summary -Id 'logs.crash' -Status 'FAIL' -Message '检测到明确属于 Focus 的崩溃或 ANR'
```

确保 `Write-DebugSummary -FocusCrashDetected $focusCrashDetected` 使用最终值，并确保最终退出码在日志处理之后计算为 `30`。

- [ ] **Step 6: 运行完整离线套件，确认 GREEN**

Expected: `foreign-crash` 和 `focus-crash` 均通过；其他应用 sentinel 不出现在任何 Focus 附件；完整套件退出 `0`。

- [ ] **Step 7: 提交 Task 2**

```powershell
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug add debug-focus.ps1 tests/debug-focus.Tests.ps1 tests/fixtures/fake-adb.ps1
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug commit -m "feat: attribute focus crashes safely"
```

---

### Task 3: 日志失败语义、密钥脱敏和附件写入失败

**Files:**
- Modify: `tests/fixtures/fake-adb.ps1`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1`

**Interfaces:**
- Consumes: Task 1/2 的日志命令、归属过滤、脱敏函数、附件写入和摘要计算。
- Produces: `no-focus-log`、`logcat-failed`、`secret-log` 场景；可操作的日志失败语义；两个日志附件的失败闭合测试。

- [ ] **Step 1: 增加无匹配、读取失败和密钥 fixture**

```powershell
if ($scenario -ceq 'no-focus-log') {
    '09-02 20:00:00.000  9000  9000 I OtherApp: OTHER_ONLY_SENTINEL'
    exit 0
}
if ($scenario -ceq 'logcat-failed') {
    [Console]::Error.WriteLine('模拟 logcat 读取失败')
    exit 8
}
if ($scenario -ceq 'secret-log') {
    @"
09-02 20:00:00.000  2468  2468 I FocusDebug: package=$fixturePackage apiKey=sk-secret-value
09-02 20:00:00.001  2468  2468 I FocusDebug: Authorization: Bearer bearer-secret-value
"@
    exit 0
}
```

把 `no-focus-log`、`logcat-failed` 和 `secret-log` 加入 `Invoke-DebugCase` 的 `$expectedSerial='TEST123'` 场景集合，确保每次 selected 场景的 logcat 调用都经过动态白名单断言。

- [ ] **Step 2: 写无匹配和读取失败测试**

```powershell
$empty = Invoke-DebugCase -Scenario 'no-focus-log'
try {
    Assert-Equal 0 $empty.ExitCode '无 Focus 日志场景应正常完成'
    Assert-Equal 'PASS' (Get-Check $empty.Summary 'logs.focus').status '无匹配仍应完成日志检查'
    Assert-Equal $null $empty.Summary.artifacts.focusLogcat '无匹配时不应创建空附件'
    if ((Get-Check $empty.Summary 'logs.focus').message -notmatch '没有 Focus 相关日志') { throw '无匹配消息不可操作' }
}
finally { Remove-Item -LiteralPath $empty.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }

$failed = Invoke-DebugCase -Scenario 'logcat-failed'
try {
    Assert-Equal 0 $failed.ExitCode '可选日志读取失败不应覆盖必需检查结果'
    Assert-Equal 'PASS' $failed.Summary.overall '可选日志失败不应单独使 overall 失败'
    Assert-Equal 'FAIL' (Get-Check $failed.Summary 'logs.focus').status '日志读取失败状态错误'
    Assert-Equal 'SKIP' (Get-Check $failed.Summary 'logs.crash').status '无法读取日志时崩溃检查应跳过'
    Assert-Equal $null $failed.Summary.artifacts.focusLogcat '日志失败不应创建附件'
}
finally { Remove-Item -LiteralPath $failed.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 3: 写密钥脱敏失败测试**

```powershell
$secret = Invoke-DebugCase -Scenario 'secret-log'
try {
    $text = Get-Content -LiteralPath (Join-Path $secret.OutputRoot 'logcat-focus.txt') -Raw -Encoding UTF8
    if ($text -match 'sk-secret-value|bearer-secret-value') { throw '日志附件泄露密钥或 bearer token' }
    if ($text -notmatch '\[REDACTED\]') { throw '日志脱敏没有保留明确替换标记' }
}
finally { Remove-Item -LiteralPath $secret.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 4: 写日志附件路径冲突测试**

新增 `Invoke-LogAttachmentWriteFailureCase -Scenario <string> -FileName <string>`，沿用 `Invoke-FocusStateWriteFailureCase` 的环境保存/恢复模式：先创建输出目录，再把目标附件名预创建为目录。

对 `healthy/logcat-focus.txt` 断言：

```powershell
Assert-Equal 30 $result.ExitCode 'Focus 日志附件写入失败退出码错误'
Assert-Equal 'FAIL' $result.Summary.overall 'Focus 日志附件写入失败必须使 overall 失败'
Assert-Equal $true $result.Summary.collectionFailed '日志附件失败信号错误'
Assert-Equal $null $result.Summary.artifacts.focusLogcat '写入失败不得保留日志附件指针'
```

对 `focus-crash/crash-focus.txt` 断言 `artifacts.crashLog=null`、`collectionFailed=true`、退出码 `30`。两个场景都要在 `finally` 删除临时目录。

- [ ] **Step 5: 运行新增测试，确认 RED**

Expected: 至少日志读取失败语义、密钥脱敏或附件写入失败场景失败；原日志归属和崩溃隔离场景继续通过。

- [ ] **Step 6: 完成失败闭合实现**

`Get-FocusLogSnapshot` 捕获 ADB 进程异常、非零退出码并返回：

```powershell
[pscustomobject]@{
    FocusLines = @()
    CrashLines = @()
    FocusCrashDetected = $false
    Error = 'logcat 读取失败'
}
```

编排层遇到 `Error` 时只设置 `logs.focus=FAIL` 和 `logs.crash=SKIP`，不设置 `$collectionFailed`。两个附件写入 catch 必须设置 `$collectionFailed=true`，且只有 `Write-DebugAttachment` 成功后才设置 artifact。

补齐 `Protect-FocusLogLine` 测试暴露的大小写、冒号、等号和 Bearer 形式；不尝试通用识别所有用户文本，README 仍需说明日志是私密本地证据。

- [ ] **Step 7: 运行完整套件和差异检查，确认 GREEN**

```powershell
& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
$testExit = $LASTEXITCODE
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug diff --check
$diffExit = $LASTEXITCODE
if ($testExit -ne 0 -or $diffExit -ne 0) { exit 1 }
```

Expected: 所有场景通过，最终退出 `0`，`git diff --check` 退出 `0`。

- [ ] **Step 8: 提交 Task 3**

```powershell
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug add debug-focus.ps1 tests/debug-focus.Tests.ps1 tests/fixtures/fake-adb.ps1
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug commit -m "fix: close bounded log privacy failures"
```

---

### Task 4: README、最终结构护栏和离线验收

**Files:**
- Modify: `README.md`
- Modify: `tests/debug-focus.Tests.ps1`
- Verify: `debug-focus.ps1`
- Verify: `tests/fixtures/fake-adb.ps1`

**Interfaces:**
- Consumes: 完整 collect-only CLI、九个检查、四个附件字段和 Task 1-3 的日志行为。
- Produces: 可运行的使用说明、最终结构/危险命令/隐私断言和离线验收记录。

- [ ] **Step 1: 增加最终结构断言**

健康场景断言：

```powershell
Assert-Equal 1 $healthy.Summary.schemaVersion 'schemaVersion 错误'
Assert-Equal 'collect-only' $healthy.Summary.mode 'mode 错误'
[void][DateTimeOffset]::Parse($healthy.Summary.startedAt)
[void][DateTimeOffset]::Parse($healthy.Summary.completedAt)

$ids = @($healthy.Summary.checks | ForEach-Object id)
foreach ($id in @(
    'environment.adb','device.authorized','device.info','app.installed',
    'app.provenance','app.process','permission.accessibility','logs.focus','logs.crash'
)) {
    Assert-Equal 1 @($ids | Where-Object { $_ -ceq $id }).Count "检查项数量错误: $id"
}
```

对所有非空 artifact 断言它是简单文件名：不包含 `..`、`/`、`\`，并且文件确实位于该场景 `OutputRoot`。

- [ ] **Step 2: 增加生产源码危险命令护栏**

读取 `debug-focus.ps1` 原文，断言不存在真正的状态修改调用。使用针对调用参数的正则，避免 `installed` 或 artifact 名称造成误报：

```powershell
$source = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
$forbiddenPatterns = @(
    "(?i)@\([^\)]*'logcat'[^\)]*'-c'",
    "(?i)@\([^\)]*'install'",
    "(?i)@\([^\)]*'uninstall'",
    "(?i)@\([^\)]*'pm'\s*,\s*'clear'",
    "(?i)@\([^\)]*'pm'\s*,\s*'grant'",
    "(?i)@\([^\)]*'settings'\s*,\s*'put'",
    "(?i)@\([^\)]*'input'\s*,\s*'(?:tap|swipe|keyevent|text)'"
)
foreach ($pattern in $forbiddenPatterns) {
    if ($source -match $pattern) { throw "生产脚本包含禁止的状态修改调用: $pattern" }
}
```

另从 fake ADB 调用日志断言每个 selected 场景恰好出现一个合法 logcat 调用，未授权/多设备未指定/ADB 失败场景出现零个设备命令。

- [ ] **Step 3: 增加参数边界测试**

调用生产脚本并传入 `-LogWindowMinutes 0` 和 `61`，二者都必须由参数绑定拒绝，且不能调用 fake ADB。测试捕获 PowerShell 退出码和输出，断言包含 `ValidationMetadataException` 或范围验证消息；调用日志不存在。

- [ ] **Step 4: 运行新增护栏，确认 RED**

Expected: README 内容检查或最终结构测试至少一项失败；若全部既有实现已满足，则临时将一个健康 artifact 改为 `nested/log.txt` 证明测试会失败，然后立即恢复该 mutation，不得提交 mutation。

- [ ] **Step 5: 完整编写 README**

`README.md` 必须包含：

1. 工具目的和 `collect-only` 边界。
2. Windows、PowerShell 7、Android Platform Tools 和 USB 调试要求。
3. `-AdbPath`、`-Serial`、`-PackageName`、`-OutputRoot`、`-LogWindowMinutes` 的命令示例。
4. `summary.json`、`device-info.txt`、`focus-state.txt`、`logcat-focus.txt` 和 `crash-focus.txt` 的含义。
5. 退出码：`0` 正常且未检测到 Focus 崩溃；`10` 必需前提失败；`20` 摘要写入失败；`30` 采集/附件失败或检测到明确 Focus 崩溃。
6. `PASS/FAIL/SKIP` 与业务 `true/false/null` 的区别。
7. 日志只读取、不清空；原始 logcat 不落盘；其他应用崩溃不计入 Focus。
8. 基础 token/API Key 脱敏不是完整隐私保证；报告目录仍属于私密数据，分享前人工检查。
9. 明确不包含构建、安装、卸载、清数据、权限修改、UI 操作和网络上传。
10. 精确离线测试命令。

- [ ] **Step 6: 连续运行完整离线套件两次**

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
if ($LASTEXITCODE -ne 0) { exit 1 }
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
if ($LASTEXITCODE -ne 0) { exit 1 }
```

Expected: 两次均退出 `0`；第二次不依赖第一次的临时目录或文件。

- [ ] **Step 7: 做提交前静态验证**

```powershell
$repo = 'D:\focus-autodebug'
git -c safe.directory=$repo -C $repo diff --check
if ($LASTEXITCODE -ne 0) { exit 1 }
git -c safe.directory=$repo -C $repo status --short
rg -n "Invoke-Adb|logcat|FocusCrashDetected" "$repo\debug-focus.ps1"
```

人工确认每条生产 ADB 调用都属于允许集合，所有设备命令带显式 `-s`，唯一 logcat 参数包含 `-d` 和 `-T`，不包含 `-c`。

- [ ] **Step 8: 提交 Task 4**

```powershell
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug add README.md tests/debug-focus.Tests.ps1
git -c safe.directory=D:\focus-autodebug -C D:\focus-autodebug commit -m "docs: document bounded log collection"
```

---

## Final Review and Real-Device Gate

完成 Task 1-4 后，在任何真机运行前执行独立代码审查，至少检查：

1. fake ADB 是否拒绝大小写变化、额外参数、`-c` 和非法时间戳。
2. 归属算法是否可能把相邻的其他应用日志写入 Focus 附件。
3. `PackageName` 是否完全参数化。
4. 其他应用崩溃是否不影响 overall。
5. Focus 崩溃是否使 summary 和进程退出码同时失败。
6. 日志失败、附件失败和 summary 失败语义是否一致。
7. 所有原 20 个离线场景是否继续通过。

审查通过后，控制器才可在用户已授权的 RMX3350 上进行一次只读运行：

```powershell
$serial = $env:FOCUS_DEVICE_SERIAL
if ([string]::IsNullOrWhiteSpace($serial)) { throw '请先设置本次运行的 FOCUS_DEVICE_SERIAL' }
$adb = 'D:\Program\Android\SDK\platform-tools\adb.exe'
$out = 'D:\focus-autodebug\debug-results\latest'
& $adb devices -l
if ($LASTEXITCODE -ne 0) { exit 1 }
& $PSHOME\pwsh.exe -NoProfile -File 'D:\focus-autodebug\debug-focus.ps1' `
    -AdbPath $adb `
    -Serial $serial `
    -OutputRoot $out `
    -LogWindowMinutes 10
```

真机门禁：

- 目标必须唯一匹配且状态为 `device`；否则停止。
- 先读取 `summary.json`；只有 summary 指向日志附件时才读取对应附件。
- 不在聊天中回显完整附件；只报告行数、崩溃结论和隐私扫描结果。
- 扫描完整序列号、已知其他应用包名、`Authorization`、`apiKey` 和 `Bearer`；命中即记为隐私 FAIL，不分享附件。
- 不运行 Gradle、构建、安装、instrumentation、UI、权限或设置命令。

最终交付分别报告：

```text
离线测试：PASS/FAIL，场景数，两次退出码
代码审查：APPROVED/CHANGES REQUIRED
真机只读日志：PASS/FAIL/BLOCKED，设备型号，summary 路径
隐私扫描：PASS/FAIL，禁止内容命中数
未验证：preflight、构建、安装、UI Automator、提醒完整验收、ColorOS 权限自动化
```

## Plan Self-Review Record

- Scope check: 路线图中的 preflight 和 build-only 是独立子系统，不进入本计划；本计划只实现方案 A。
- Spec coverage: 覆盖现有 collect-only 规范中的日志时间窗口、Focus 归属、其他应用崩溃隔离、附件、检查状态、overall、退出码和隐私要求。
- Interface consistency: `Get-AppSnapshot.ProcessIds` 只在进程内传给 `Get-FocusLogSnapshot`；summary 和附件接口保持 schema v1。
- Command consistency: 生产和测试都只允许一个动态形状 `-s serial logcat -d -T timestamp -v threadtime`。
- Failure consistency: 可选日志读取失败不改变 overall；附件写入失败和明确 Focus 崩溃都返回 30，但 summary 检查项可区分根因。
- Privacy consistency: 不保存全量原始 logcat，不使用固定上下文窗口，不写其他应用 crash；常见 token 经替换后才写盘。
- Completion scan: 计划没有空白实现标记、未定义接口或省略式实现步骤；真机序列号从本次运行的受控环境变量读取，不写入文档。
- YAGNI decision: 不拆 PowerShell 模块，不引入日志库，不实现 preflight/build/install/UI，也不尝试完整 Android 事件解析器。
