# Focus Auto Debug Collect-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not use subagents unless the user explicitly authorizes delegation.

**Goal:** 在 Windows 上提供一个严格只读的 PowerShell 入口，通过 ADB 安全采集 Focus 设备、安装、进程、无障碍与有限日志状态，并始终尽力生成结构稳定的 `summary.json`。

**Architecture:** 第一版使用一个生产脚本 `debug-focus.ps1` 完成编排与少量私有函数，使用一个自包含 PowerShell 测试脚本和一个假 ADB 脚本覆盖外部命令边界。生产代码只调用 ADB 的读取命令，所有报告写入用户指定的本地输出目录；测试通过显式 `-AdbPath` 注入假 ADB，不连接真实手机。

**Tech Stack:** PowerShell 7.6、Windows/.NET `System.Diagnostics.Process`、Android Platform Tools ADB、JSON、无第三方 PowerShell 模块。

**Spec:** `D:\focus-autodebug\docs\specs\2026-09-02-focus-autodebug-collect-only-design.md`

## Global Constraints

- 工具根目录固定为 `D:\focus-autodebug`。
- 目标包名默认值固定为 `com.example.focus_app`，但允许通过 `-PackageName` 覆盖。
- 默认模式固定为 `collect-only`。
- 默认日志窗口固定为最近 10 分钟，可配置范围为 1～60 分钟。
- 不编译、不安装、不卸载、不清数据、不改权限、不改系统设置、不启动或停止应用、不发送 UI 输入、不清空 logcat。
- 所有设备侧命令在选定设备后必须带 `-s <serial>`。
- 多个已授权设备且没有 `-Serial` 时必须失败，不得自动猜测。
- 未知值必须写为 JSON `null`，不得用 `false` 代替未知。
- 默认不采集截图和 UI dump，不上传任何报告。
- `debug-results/` 是私密本地数据，必须被 `.gitignore` 排除。
- 测试不得依赖 Pester，也不得连接真实设备。
- Git 远端为 `https://github.com/BruceHuang-CN/focus-autodebugge.git`；所有实现提交都在 `codex/collect-only-small-tests` 或后续非 `main` 分支完成，不直接修改 `main`。

---

## File Map

| 文件 | 职责 |
|---|---|
| `debug-focus.ps1` | 参数解析、ADB 发现、只读命令执行、设备选择、状态采集、日志过滤、摘要与退出码。 |
| `tests/debug-focus.Tests.ps1` | 自包含端到端 CLI 测试运行器；为每个场景建立临时输出目录并断言 JSON、退出码和 ADB 调用记录。 |
| `tests/fixtures/fake-adb.ps1` | 根据 `FOCUS_FAKE_ADB_SCENARIO` 返回确定的 ADB 输出，并把收到的参数写入测试调用日志。 |
| `.gitignore` | 排除 `debug-results/` 和测试临时产物。 |
| `README.md` | 说明只读边界、参数、运行方式、退出码、报告结构、授权步骤和隐私提示。 |

生产脚本内部接口在第一版锁定为：

```powershell
New-DebugSummary -PackageName <string> -StartedAt <DateTimeOffset> -> [ordered] hashtable
Set-DebugCheck -Summary <IDictionary> -Id <string> -Status <PASS|FAIL|SKIP> -Message <string|null>
Write-DebugSummary -Summary <IDictionary> -OutputRoot <string> -FocusCrashDetected <bool> -> <void>
Resolve-AdbExecutable -ExplicitPath <string|null> -> <string|null>
Invoke-ExternalCommand -FilePath <string> -Arguments <string[]> -> PSCustomObject{ExitCode,StdOut,StdErr}
Invoke-Adb -AdbPath <string> -Arguments <string[]> -> PSCustomObject{ExitCode,StdOut,StdErr}
Get-AdbDevices -DevicesOutput <string> -> PSCustomObject[]{Serial,State,Details}
Select-AdbDevice -Devices <object[]> -RequestedSerial <string|null> -> PSCustomObject{Selected,Message,UnauthorizedHint}
Get-DeviceSnapshot -AdbPath <string> -Serial <string> -> PSCustomObject{Values,ArtifactLines,Errors}
Get-AppSnapshot -AdbPath <string> -Serial <string> -PackageName <string> -> PSCustomObject{Values,ArtifactLines,Errors}
Get-FocusLogSnapshot -AdbPath <string> -Serial <string> -PackageName <string> -ProcessId <string|null> -Since <DateTimeOffset> -> PSCustomObject{FocusLines,CrashLines,Error}
Invoke-FocusDebugCollection -> <int exitCode>
```

除 `Invoke-FocusDebugCollection` 外，函数不直接调用 `exit`。顶层只执行：

```powershell
$exitCode = Invoke-FocusDebugCollection
exit $exitCode
```

---

### Task 1: 建立测试入口与“ADB 缺失仍有摘要”的最小闭环

**Files:**
- Create: `.gitignore`
- Create: `tests/debug-focus.Tests.ps1`
- Create: `debug-focus.ps1`

**Interfaces:**
- Consumes: 无。
- Produces: `New-DebugSummary`、`Set-DebugCheck`、`Write-DebugSummary`、`Resolve-AdbExecutable`、`Invoke-ExternalCommand`、`Invoke-Adb` 和稳定的 CLI 参数。

- [ ] **Step 1: 写入最小忽略规则**

`.gitignore` 的完整初始内容：

```gitignore
debug-results/
tests/.tmp/
```

- [ ] **Step 2: 写第一个失败测试**

在 `tests/debug-focus.Tests.ps1` 建立不依赖 Pester 的运行器，并先加入 `missing-adb` 场景：

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptUnderTest = Join-Path $PSScriptRoot '..\debug-focus.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message；期望=[$Expected]，实际=[$Actual]"
    }
}

function Get-Check {
    param($Summary, [string]$Id)
    return @($Summary.checks | Where-Object id -EQ $Id)[0]
}

function Invoke-MissingAdbCase {
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-" + [guid]::NewGuid())
    $missingAdb = Join-Path $outputRoot 'does-not-exist\adb.exe'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    try {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $scriptUnderTest -AdbPath $missingAdb -OutputRoot $outputRoot
        $exitCode = $LASTEXITCODE
        $summaryPath = Join-Path $outputRoot 'summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath)) { throw '未生成 summary.json' }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 10 $exitCode 'ADB 缺失退出码不正确'
        Assert-Equal 'FAIL' $summary.overall 'overall 不正确'
        Assert-Equal 'FAIL' (Get-Check $summary 'environment.adb').status 'ADB 检查状态不正确'
        Assert-Equal 'SKIP' (Get-Check $summary 'device.authorized').status '设备检查应跳过'
    }
    finally {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try { Invoke-MissingAdbCase; Write-Host 'PASS missing-adb' }
catch { $failures.Add("missing-adb: $($_.Exception.Message)"); Write-Host 'FAIL missing-adb' }

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
exit 0
```

- [ ] **Step 3: 运行测试，确认 RED**

Run:

```powershell
Set-Location D:\focus-autodebug
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File .\tests\debug-focus.Tests.ps1
```

Expected: 退出码为 `1`，失败原因是 `debug-focus.ps1` 不存在或没有生成 `summary.json`。

- [ ] **Step 4: 实现摘要骨架和 ADB 解析入口**

在 `debug-focus.ps1` 写入参数与严格模式：

```powershell
[CmdletBinding()]
param(
    [string]$AdbPath,
    [string]$Serial,
    [string]$PackageName = 'com.example.focus_app',
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'debug-results\latest'),
    [ValidateRange(1, 60)]
    [int]$LogWindowMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RequiredChecks = @('environment.adb', 'device.authorized', 'device.info', 'app.installed')
```

`New-DebugSummary` 必须一次性建立所有字段和检查项，避免异常路径缺字段：

```powershell
function New-DebugSummary {
    param([string]$PackageName, [DateTimeOffset]$StartedAt)
    $ids = @(
        'environment.adb', 'device.authorized', 'device.info', 'app.installed',
        'app.provenance', 'app.process', 'permission.accessibility',
        'logs.focus', 'logs.crash'
    )
    [ordered]@{
        schemaVersion = 1
        runId = $StartedAt.ToString('yyyyMMdd-HHmmss')
        mode = 'collect-only'
        overall = 'FAIL'
        startedAt = $StartedAt.ToString('o')
        completedAt = $null
        adbPath = $null
        device = [ordered]@{
            authorized = $false; serialHint = $null; manufacturer = $null
            model = $null; android = $null; sdk = $null
        }
        app = [ordered]@{
            packageName = $PackageName; installed = $null; versionName = $null
            versionCode = $null; lastUpdateTime = $null; processAlive = $null
            accessibilityEnabled = $null
        }
        checks = @($ids | ForEach-Object {
            [ordered]@{ id = $_; status = 'SKIP'; message = '上游前提尚未满足' }
        })
        artifacts = [ordered]@{
            deviceInfo = $null; focusState = $null
            focusLogcat = $null; crashLog = $null
        }
    }
}
```

`Set-DebugCheck` 必须校验状态值，并原地更新唯一检查项：

```powershell
function Set-DebugCheck {
    param($Summary, [string]$Id, [ValidateSet('PASS','FAIL','SKIP')][string]$Status, $Message)
    $matches = @($Summary.checks | Where-Object { $_.id -eq $Id })
    if ($matches.Count -ne 1) { throw "检查项不存在或不唯一: $Id" }
    $matches[0].status = $Status
    $matches[0].message = $Message
}
```

`Write-DebugSummary` 负责创建输出目录、填写完成时间、计算必需检查结果并以 UTF-8 写入：

```powershell
function Write-DebugSummary {
    param($Summary, [string]$OutputRoot, [bool]$FocusCrashDetected = $false)
    $requiredFailed = @($Summary.checks | Where-Object {
        $_.id -in $script:RequiredChecks -and $_.status -eq 'FAIL'
    }).Count -gt 0
    $Summary.overall = if ($requiredFailed -or $FocusCrashDetected) { 'FAIL' } else { 'PASS' }
    $Summary.completedAt = [DateTimeOffset]::Now.ToString('o')
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $json = $Summary | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'summary.json'), $json, [Text.UTF8Encoding]::new($false))
}
```

`Resolve-AdbExecutable` 在本任务只需完成显式路径、PATH 和 SDK 环境变量分支；常见用户 SDK 路径也列入候选：

```powershell
function Resolve-AdbExecutable {
    param([string]$ExplicitPath)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return [IO.Path]::GetFullPath($ExplicitPath)
        }
        return $null
    }
    $command = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    foreach ($root in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($root) { $candidates.Add((Join-Path $root 'platform-tools\adb.exe')) }
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}
```

`Invoke-ExternalCommand` 使用 `ProcessStartInfo.ArgumentList`，不得拼接整条命令字符串。显式 `.ps1` 只用于测试注入：

```powershell
function Invoke-ExternalCommand {
    param([string]$FilePath, [string[]]$Arguments)
    $actualFile = $FilePath
    $actualArguments = @($Arguments)
    if ([IO.Path]::GetExtension($FilePath) -ieq '.ps1') {
        $actualFile = Join-Path $PSHOME 'pwsh.exe'
        $actualArguments = @('-NoProfile', '-File', $FilePath) + $Arguments
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $actualFile
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $actualArguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout.GetAwaiter().GetResult().TrimEnd()
        StdErr = $stderr.GetAwaiter().GetResult().TrimEnd()
    }
}

function Invoke-Adb {
    param([string]$AdbPath, [string[]]$Arguments)
    Invoke-ExternalCommand -FilePath $AdbPath -Arguments $Arguments
}
```

`Invoke-FocusDebugCollection` 在 ADB 缺失时设置失败检查并进入统一报告写入路径；退出码约定为 `0=采集完成`、`10=ADB/设备前提失败`、`20=报告写入失败`、`30=未预期采集异常`。本任务的完整初始编排如下，Task 2 再把“ADB 已就绪”后的设备分支替换为真实设备选择：

```powershell
function Invoke-FocusDebugCollection {
    $summary = New-DebugSummary -PackageName $PackageName -StartedAt ([DateTimeOffset]::Now)
    $exitCode = 30
    $focusCrashDetected = $false
    try {
        $resolvedAdb = Resolve-AdbExecutable -ExplicitPath $AdbPath
        if (-not $resolvedAdb) {
            Set-DebugCheck -Summary $summary -Id 'environment.adb' -Status 'FAIL' -Message '未找到可用的 ADB，请使用 -AdbPath 指定 adb.exe'
            $exitCode = 10
        }
        else {
            $version = Invoke-Adb -AdbPath $resolvedAdb -Arguments @('version')
            if ($version.ExitCode -ne 0) {
                Set-DebugCheck -Summary $summary -Id 'environment.adb' -Status 'FAIL' -Message 'ADB 版本检查失败'
                $exitCode = 10
            }
            else {
                $summary.adbPath = $resolvedAdb
                Set-DebugCheck -Summary $summary -Id 'environment.adb' -Status 'PASS' -Message $null
                Set-DebugCheck -Summary $summary -Id 'device.authorized' -Status 'SKIP' -Message '设备选择由下一任务加入'
                $exitCode = 10
            }
        }
    }
    catch {
        Set-DebugCheck -Summary $summary -Id 'environment.adb' -Status 'FAIL' -Message $_.Exception.Message
        $exitCode = 30
    }
    try {
        Write-DebugSummary -Summary $summary -OutputRoot $OutputRoot -FocusCrashDetected $focusCrashDetected
    }
    catch {
        Write-Error "无法写入调试摘要: $($_.Exception.Message)"
        return 20
    }
    Write-Host '模式: collect-only'
    Write-Host "结果: $($summary.overall)"
    Write-Host "摘要: $(Join-Path ([IO.Path]::GetFullPath($OutputRoot)) 'summary.json')"
    return $exitCode
}

$exitCode = Invoke-FocusDebugCollection
exit $exitCode
```

- [ ] **Step 5: 运行测试，确认 GREEN**

Run:

```powershell
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
```

Expected: `PASS missing-adb`，进程退出码为 `0`。这里的 `0` 是测试运行器通过；被测脚本在该场景中的退出码仍为 `10`。

- [ ] **Step 6: 提交 Task 1**

```powershell
git add .gitignore debug-focus.ps1 tests/debug-focus.Tests.ps1
git commit -m "feat: add collect-only summary skeleton"
```

---

### Task 2: 安全解析设备列表并拒绝未授权或不明确设备

**Files:**
- Create: `tests/fixtures/fake-adb.ps1`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1`

**Interfaces:**
- Consumes: `Invoke-Adb`、摘要和检查项接口。
- Produces: `Get-AdbDevices` 和 `Select-AdbDevice`；后续任务只接收已明确选中的序列号。

- [ ] **Step 1: 创建确定性的假 ADB**

`tests/fixtures/fake-adb.ps1` 必须接受剩余参数、记录调用，并对场景返回固定输出：

```powershell
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AdbArgs)
Set-StrictMode -Version Latest
$scenario = if ($env:FOCUS_FAKE_ADB_SCENARIO) { $env:FOCUS_FAKE_ADB_SCENARIO } else { 'healthy' }
if ($env:FOCUS_FAKE_ADB_CALLS) {
    [IO.File]::AppendAllText($env:FOCUS_FAKE_ADB_CALLS, (($AdbArgs -join "`t") + "`n"))
}
if ($AdbArgs.Count -eq 1 -and $AdbArgs[0] -eq 'version') {
    'Android Debug Bridge version 1.0.41'; exit 0
}
if ($AdbArgs.Count -ge 2 -and $AdbArgs[0] -eq 'devices' -and $AdbArgs[1] -eq '-l') {
    'List of devices attached'
    switch ($scenario) {
        'unauthorized' { 'TEST123 unauthorized usb:1-1 transport_id:1' }
        'multiple' {
            'TEST123 device product:test model:Phone_A transport_id:1'
            'TEST456 device product:test model:Phone_B transport_id:2'
        }
        default { 'TEST123 device product:test model:RMX3350 transport_id:1' }
    }
    exit 0
}
Write-Error "fake-adb 尚未定义该调用: $($AdbArgs -join ' ')"
exit 9
```

- [ ] **Step 2: 加入三个设备选择失败测试**

在测试运行器中新增通用 `Invoke-DebugCase`，设置 `FOCUS_FAKE_ADB_SCENARIO`、`FOCUS_FAKE_ADB_CALLS`，以子进程执行被测脚本并返回 `{ExitCode,Summary,Calls,Console,OutputRoot}`：

```powershell
function Invoke-DebugCase {
    param(
        [string]$Scenario,
        [string[]]$ExtraArguments = @()
    )
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-" + [guid]::NewGuid())
    $callsPath = Join-Path $outputRoot 'adb-calls.txt'
    $fakeAdb = Join-Path $PSScriptRoot 'fixtures\fake-adb.ps1'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $previousScenario = $env:FOCUS_FAKE_ADB_SCENARIO
    $previousCalls = $env:FOCUS_FAKE_ADB_CALLS
    try {
        $env:FOCUS_FAKE_ADB_SCENARIO = $Scenario
        $env:FOCUS_FAKE_ADB_CALLS = $callsPath
        $arguments = @(
            '-NoProfile', '-File', $scriptUnderTest,
            '-AdbPath', $fakeAdb,
            '-OutputRoot', $outputRoot
        ) + $ExtraArguments
        $console = & (Join-Path $PSHOME 'pwsh.exe') @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $summary = Get-Content -LiteralPath (Join-Path $outputRoot 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $calls = if (Test-Path -LiteralPath $callsPath) {
            Get-Content -LiteralPath $callsPath -Raw -Encoding UTF8
        } else { '' }
        [pscustomobject]@{
            ExitCode = $exitCode
            Summary = $summary
            Calls = $calls
            Console = $console
            OutputRoot = $outputRoot
        }
    }
    finally {
        $env:FOCUS_FAKE_ADB_SCENARIO = $previousScenario
        $env:FOCUS_FAKE_ADB_CALLS = $previousCalls
    }
}
```

每个测试完成后都在自身 `finally` 中删除 `OutputRoot`；需要检查附件的测试必须在删除前完成读取。分别断言：

```powershell
$unauthorized = Invoke-DebugCase -Scenario 'unauthorized'
Assert-Equal 10 $unauthorized.ExitCode '未授权设备退出码不正确'
Assert-Equal 'FAIL' (Get-Check $unauthorized.Summary 'device.authorized').status '未授权状态不正确'
if ($unauthorized.Calls -match '(?m)^-s\t') { throw '未授权场景不应执行设备 shell 命令' }

$multiple = Invoke-DebugCase -Scenario 'multiple'
Assert-Equal 10 $multiple.ExitCode '多设备退出码不正确'
if ((Get-Check $multiple.Summary 'device.authorized').message -notmatch '-Serial') {
    throw '多设备错误消息必须提示 -Serial'
}
if ($multiple.Calls -match '(?m)^-s\t') { throw '未明确选中设备时不应执行设备命令' }

$selected = Invoke-DebugCase -Scenario 'multiple' -ExtraArguments @('-Serial','TEST456')
Assert-Equal 'PASS' (Get-Check $selected.Summary 'device.authorized').status '没有接受明确指定的授权设备'
Assert-Equal 'T456' $selected.Summary.device.serialHint '设备提示没有使用已选设备末四位'
if (($selected.Summary | ConvertTo-Json -Depth 8) -match 'TEST123') { throw '摘要错误包含未选择设备的完整序列号' }
```

- [ ] **Step 3: 运行新增测试，确认 RED**

Run: `& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1`

Expected: `missing-adb` 仍通过；`unauthorized`、`multiple` 或 `selected-serial` 至少一个失败，因为设备解析尚未实现。

- [ ] **Step 4: 实现设备列表解析**

```powershell
function Get-AdbDevices {
    param([string]$DevicesOutput)
    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($DevicesOutput -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -like 'List of devices attached*') { continue }
        if ($trimmed -match '^(\S+)\s+(\S+)(?:\s+(.*))?$') {
            $devices.Add([pscustomobject]@{
                Serial = $matches[1]; State = $matches[2]; Details = $matches[3]
            })
        }
    }
    return @($devices)
}
```

- [ ] **Step 5: 实现安全设备选择**

```powershell
function Select-AdbDevice {
    param([object[]]$Devices, [string]$RequestedSerial)
    if ($RequestedSerial) {
        $match = @($Devices | Where-Object Serial -CEQ $RequestedSerial)
        if ($match.Count -ne 1 -or $match[0].State -ne 'device') {
            return [pscustomobject]@{ Selected = $null; Message = "指定设备不可用或未授权: $RequestedSerial"; UnauthorizedHint = $null }
        }
        return [pscustomobject]@{ Selected = $match[0]; Message = $null; UnauthorizedHint = $null }
    }
    $authorized = @($Devices | Where-Object State -EQ 'device')
    if ($authorized.Count -eq 1) {
        return [pscustomobject]@{ Selected = $authorized[0]; Message = $null; UnauthorizedHint = $null }
    }
    if ($authorized.Count -gt 1) {
        return [pscustomobject]@{ Selected = $null; Message = '检测到多个已授权设备，请使用 -Serial 明确指定'; UnauthorizedHint = $null }
    }
    $unauthorized = @($Devices | Where-Object State -EQ 'unauthorized')
    $hint = if ($unauthorized.Count -eq 1) {
        $value = $unauthorized[0].Serial
        $value.Substring([Math]::Max(0, $value.Length - 4))
    } else { $null }
    $message = if ($unauthorized.Count -gt 0) { '设备已连接，但尚未授权 USB 调试' } else { '未发现已授权的 ADB 设备' }
    [pscustomobject]@{ Selected = $null; Message = $message; UnauthorizedHint = $hint }
}
```

编排层只能在 `Select-AdbDevice.Selected` 非空后设置 `device.authorized = true`，并确保后续所有调用使用 `@('-s', $serial, ...)`。

- [ ] **Step 6: 运行测试，确认 GREEN**

Expected: 四个场景全部通过；调用日志证明未授权和多设备未指定时没有任何以 `-s` 开头的调用，明确指定场景只在摘要中保留已选设备末四位。

- [ ] **Step 7: 提交 Task 2**

```powershell
git add debug-focus.ps1 tests/debug-focus.Tests.ps1 tests/fixtures/fake-adb.ps1
git commit -m "feat: select authorized adb device safely"
```

---

### Task 3: 采集设备与 Focus 应用状态并保持 null 语义

**Files:**
- Modify: `tests/fixtures/fake-adb.ps1`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1`

**Interfaces:**
- Consumes: 明确选中的 `Serial` 和 `Invoke-Adb`。
- Produces: `Get-DeviceSnapshot`、`Get-AppSnapshot`、`device-info.txt`、`focus-state.txt` 及摘要中的设备/应用字段。

- [ ] **Step 1: 扩充假 ADB 的健康、未安装和未运行输出**

在 `fake-adb.ps1` 的未定义调用前加入精确分支：

```powershell
$tail = if ($AdbArgs.Count -ge 3 -and $AdbArgs[0] -eq '-s') { @($AdbArgs[2..($AdbArgs.Count - 1)]) } else { @() }
if ($tail -join ' ' -eq 'shell getprop ro.product.manufacturer') { 'realme'; exit 0 }
if ($tail -join ' ' -eq 'shell getprop ro.product.model') { 'RMX3350'; exit 0 }
if ($tail -join ' ' -eq 'shell getprop ro.build.version.release') { '11'; exit 0 }
if ($tail -join ' ' -eq 'shell getprop ro.build.version.sdk') { '30'; exit 0 }
if ($tail -join ' ' -eq 'shell pm path com.example.focus_app') {
    if ($scenario -eq 'not-installed') { exit 0 }
    'package:/data/app/com.example.focus_app/base.apk'; exit 0
}
if ($tail -join ' ' -eq 'shell dumpsys package com.example.focus_app') {
    if ($scenario -eq 'not-installed') { 'Unable to find package: com.example.focus_app'; exit 0 }
    @'
Packages:
  Package [com.example.focus_app]
    versionCode=42 minSdk=26 targetSdk=35
    versionName=1.2.3
    lastUpdateTime=2026-09-02 12:34:56
'@; exit 0
}
if ($tail -join ' ' -eq 'shell pidof com.example.focus_app') {
    if ($scenario -ne 'stopped') { '2468' }
    exit 0
}
if ($tail -join ' ' -eq 'shell settings get secure enabled_accessibility_services') {
    'com.example.focus_app/.service.FocusAccessibilityService'; exit 0
}
```

- [ ] **Step 2: 加入健康、未安装、未运行测试**

健康场景断言：

```powershell
Assert-Equal 'realme' $healthy.Summary.device.manufacturer '厂商解析错误'
Assert-Equal 'RMX3350' $healthy.Summary.device.model '型号解析错误'
Assert-Equal '11' $healthy.Summary.device.android 'Android 版本解析错误'
Assert-Equal '30' $healthy.Summary.device.sdk 'SDK 解析错误'
Assert-Equal $true $healthy.Summary.app.installed '安装状态错误'
Assert-Equal '1.2.3' $healthy.Summary.app.versionName '版本名解析错误'
Assert-Equal '42' $healthy.Summary.app.versionCode '版本号解析错误'
Assert-Equal '2026-09-02 12:34:56' $healthy.Summary.app.lastUpdateTime '更新时间解析错误'
Assert-Equal $true $healthy.Summary.app.processAlive '进程状态错误'
Assert-Equal $true $healthy.Summary.app.accessibilityEnabled '无障碍状态错误'
```

未安装场景必须断言 `installed=false`、`app.installed=FAIL`，而 `processAlive` 与 `accessibilityEnabled` 保持 `null`，相关检查为 `SKIP`。未运行场景必须断言 `app.process=PASS` 且 `processAlive=false`。

- [ ] **Step 3: 运行新增测试，确认 RED**

Expected: 新增的设备和应用字段断言失败，且旧设备选择测试保持通过。

- [ ] **Step 4: 实现通用只读字段读取与设备快照**

`Get-DeviceSnapshot` 对四个 `getprop` 分别调用，任何字段读取失败都加入 `Errors`；只有四项都有非空值时 `device.info=PASS`。写入 `device-info.txt` 的内容固定为：

```text
manufacturer=<value>
model=<value>
android=<value>
sdk=<value>
```

文件不写完整序列号。编排层通过 `[IO.File]::WriteAllLines(..., [Text.UTF8Encoding]::new($false))` 写附件，并把 `artifacts.deviceInfo` 设置为 `device-info.txt`。

- [ ] **Step 5: 实现应用快照**

`Get-AppSnapshot` 按以下顺序执行：

1. `adb -s <serial> shell pm path <package>`；输出中至少一行以 `package:` 开头才视为已安装。
2. 已安装后执行 `dumpsys package <package>`，用逐行正则解析：

```powershell
if ($line -match '^\s*versionCode=(\d+)\b') { $versionCode = $matches[1] }
if ($line -match '^\s*versionName=(.*)$') { $versionName = $matches[1].Trim() }
if ($line -match '^\s*lastUpdateTime=(.*)$') { $lastUpdateTime = $matches[1].Trim() }
```

3. 已安装后执行 `pidof <package>`；命令成功且输出为空表示 `processAlive=false`，命令失败表示 `processAlive=null`。
4. 已安装后执行 `settings get secure enabled_accessibility_services`；命令成功时用冒号拆分服务列表，只要某项以 `<package>/` 开头即为 `true`，否则为 `false`；命令失败为 `null`。

`focus-state.txt` 只写包名、安装、版本、更新时间、进程和无障碍布尔状态，不写无障碍列表中其他应用的服务名。

- [ ] **Step 6: 明确检查状态**

- `pm path` 成功且无目标路径：`app.installed=FAIL`，`installed=false`。
- `pm path` 命令失败：`app.installed=FAIL`，`installed=null`。
- 包已安装且 provenance 三字段齐全：`app.provenance=PASS`；缺字段为 `FAIL`。
- `pidof` 成功：`app.process=PASS`，业务值可为 `true` 或 `false`。
- 无障碍列表读取成功：`permission.accessibility=PASS`，业务值可为 `true` 或 `false`。
- 包未安装：上述三个依赖检查保持 `SKIP`。

- [ ] **Step 7: 运行测试，确认 GREEN**

Expected: 健康、未安装、未运行和此前设备场景全部通过；`summary.json` 能被 `ConvertFrom-Json` 读取。

- [ ] **Step 8: 记录检查点**

建议提交信息：`feat: collect device and focus app state`。提交到当前非 `main` 功能分支。

---

### Task 4: 有界读取并过滤 Focus 日志与崩溃上下文

**Files:**
- Modify: `tests/fixtures/fake-adb.ps1`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1`

**Interfaces:**
- Consumes: `PackageName`、可空 `ProcessId`、`LogWindowMinutes` 和明确设备序列号。
- Produces: `Get-FocusLogSnapshot`、`logcat-focus.txt`、可选 `crash-focus.txt`、`logs.focus` 与 `logs.crash` 检查。

- [ ] **Step 1: 为假 ADB 增加三组日志**

当参数尾部以 `logcat -d -T` 开头时：

- `healthy` 输出两行含 PID `2468` 或包名 `com.example.focus_app` 的普通日志。
- `foreign-crash` 输出 `Process: com.other.app` 和其 `FATAL EXCEPTION`，另输出一行普通 Focus 日志，两组之间至少间隔 25 行。
- `focus-crash` 输出 `FATAL EXCEPTION`、`Process: com.example.focus_app, PID: 2468` 和异常栈。

所有场景退出码为 `0`。测试调用日志必须保留传入的 `-T` 时间参数，供后续断言窗口存在。

- [ ] **Step 2: 写日志隔离失败测试**

```powershell
$foreign = Invoke-DebugCase -Scenario 'foreign-crash'
$foreignCrashPath = Join-Path $foreign.OutputRoot 'crash-focus.txt'
if (Test-Path -LiteralPath $foreignCrashPath) { throw '其他应用崩溃不应生成 Focus 崩溃附件' }
Assert-Equal 'PASS' (Get-Check $foreign.Summary 'logs.crash').status '其他应用崩溃被误报'

$focusCrash = Invoke-DebugCase -Scenario 'focus-crash'
Assert-Equal 'FAIL' (Get-Check $focusCrash.Summary 'logs.crash').status 'Focus 崩溃未识别'
Assert-Equal 'FAIL' $focusCrash.Summary.overall '明确的 Focus 崩溃必须使 overall 失败'
$crashText = Get-Content -LiteralPath (Join-Path $focusCrash.OutputRoot 'crash-focus.txt') -Raw
if ($crashText -notmatch 'com\.example\.focus_app') { throw '崩溃附件缺少 Focus 进程证据' }
```

另断言 ADB 调用记录包含 `logcat`、`-d` 和 `-T`，且不包含 `-c`。

- [ ] **Step 3: 运行新增测试，确认 RED**

Expected: 日志相关断言失败；此前环境、设备和应用测试保持通过。

- [ ] **Step 4: 实现日志时间窗口和 Focus 行筛选**

`Get-FocusLogSnapshot` 使用：

```powershell
$timestamp = $Since.LocalDateTime.ToString('MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
$result = Invoke-Adb -AdbPath $AdbPath -Arguments @(
    '-s', $Serial, 'logcat', '-d', '-T', $timestamp, '-v', 'threadtime'
)
```

不得加入 `-c`。读取失败时返回 `Error`，不创建空附件。

筛选算法保持简单且确定：

1. 将原始日志按行拆分。
2. 主匹配为包名文字匹配；若进程 ID 非空，再增加 threadtime 行中独立 PID 匹配。
3. 对每个主匹配索引收集前 6 行、当前行和后 12 行。
4. 去重并保持原始顺序，形成 `FocusLines`。
5. 只有同一个已收集窗口同时包含 Focus 包名和 `FATAL EXCEPTION|ANR in|tombstone` 时，才把该窗口加入 `CrashLines`。

包名和 PID 必须经 `[regex]::Escape()`。上下文窗口是第一版已知上限；若真实设备证据显示堆栈经常超过 12 行，再基于失败样本调整，不提前实现完整 logcat 事件解析器。

- [ ] **Step 5: 写附件并计算结果**

- `FocusLines` 非空：写 `logcat-focus.txt`，`logs.focus=PASS`。
- 命令成功但无匹配：不创建附件，`logs.focus=PASS`，消息为“时间窗口内没有 Focus 相关日志”。
- 日志命令失败：`logs.focus=FAIL`，`logs.crash=SKIP`；因为两者是诊断项，不单独改变 `overall`。
- `CrashLines` 非空：写 `crash-focus.txt`，`logs.crash=FAIL`，并把内部 `$focusCrashDetected=true` 交给摘要计算，使 `overall=FAIL`。
- `CrashLines` 为空：不创建崩溃附件，`logs.crash=PASS`。

调用已在 Task 1 固定签名的 `Write-DebugSummary -FocusCrashDetected $focusCrashDetected`；`overall=FAIL` 的条件为“任一必需检查失败，或明确检测到 Focus 崩溃”。

- [ ] **Step 6: 运行测试，确认 GREEN**

Expected: 其他应用崩溃不误报，Focus 崩溃生成附件并使总体失败；调用记录中不存在 `logcat -c`。

- [ ] **Step 7: 记录检查点**

建议提交信息：`feat: collect bounded focus-only logs`。提交到当前非 `main` 功能分支。

---

### Task 5: 固化控制台行为、帮助文档与隐私护栏

**Files:**
- Create: `README.md`
- Modify: `tests/debug-focus.Tests.ps1`
- Modify: `debug-focus.ps1`

**Interfaces:**
- Consumes: 完整 CLI 和报告结构。
- Produces: 用户可运行的帮助说明、稳定退出码、静态危险命令保护测试。

- [ ] **Step 1: 写危险操作静态保护测试**

读取 `debug-focus.ps1` 原文并断言不存在以下执行片段：

```powershell
$source = Get-Content -LiteralPath $scriptUnderTest -Raw -Encoding UTF8
$forbidden = @(
    '(?i)\binstall\b', '(?i)\buninstall\b', '(?i)\bpm\s+clear\b',
    '(?i)\bpm\s+grant\b', '(?i)\bappops\s+set\b', '(?i)\blogcat\s+-c\b',
    '(?i)\binput\s+(tap|swipe|keyevent|text)\b', '(?i)\bam\s+start\b'
)
foreach ($pattern in $forbidden) {
    if ($source -match $pattern) { throw "生产脚本包含第一版禁止操作: $pattern" }
}
```

为避免帮助文字中的“禁止 install”触发静态测试，生产脚本帮助只使用中文描述；完整命令黑名单写在 README 和设计文档中。

- [ ] **Step 2: 写控制台与参数测试**

断言：

- `-LogWindowMinutes 0` 由参数验证拒绝。
- 成功运行只输出模式、设备提示、总体状态、摘要路径和分享前检查隐私提示。
- 控制台不输出完整设备序列号、完整 logcat 或其他无障碍服务列表。
- `summary.json` 中 `serialHint` 最多 4 个字符。

- [ ] **Step 3: 运行新增测试，确认 RED**

Expected: 至少帮助/控制台或静态保护测试失败，因为最终输出尚未固定。

- [ ] **Step 4: 固化生产脚本帮助与控制台输出**

在参数块上加入 comment-based help，明确：

- `.SYNOPSIS`：只读采集 Focus 调试状态。
- `.DESCRIPTION`：不会安装、清数据、改权限、启动应用、点击屏幕或清空日志。
- `.PARAMETER AdbPath`、`.PARAMETER Serial`、`.PARAMETER PackageName`、`.PARAMETER OutputRoot`、`.PARAMETER LogWindowMinutes`。
- `.EXAMPLE .\debug-focus.ps1`
- `.EXAMPLE .\debug-focus.ps1 -Serial IJCES4XO8XA6SGK7`

成功或失败时控制台只输出：

```text
模式: collect-only
设备: ****SGK7
结果: PASS|FAIL
摘要: <absolute path to summary.json>
隐私: 分享报告前请人工检查日志附件。
```

未选择设备时设备行写 `设备: 未选择`。完整序列号只存在于进程内，不写入报告或控制台。

- [ ] **Step 5: 编写 README**

`README.md` 必须包含：

1. 工具用途和严格只读边界。
2. 环境要求：Windows、PowerShell 7、Android Platform Tools、手机开启 USB 调试。
3. 首次授权：解锁手机、接受 RSA 指纹弹窗、用 `adb devices -l` 确认状态为 `device`。
4. 基本命令和多设备 `-Serial` 命令。
5. 五个输出文件的含义。
6. 退出码 `0/10/20/30`。
7. `PASS/FAIL/SKIP` 与布尔业务值的区别。
8. 报告只保存在本地、日志可能含业务文本、分享前人工检查。
9. 第一版明确不包含构建、安装、权限自动化、ColorOS 自动操作和 UI 自动化。
10. 运行离线测试的精确命令。

- [ ] **Step 6: 运行测试，确认 GREEN**

Run:

```powershell
& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
```

Expected: 所有测试通过；生产脚本源码不存在禁止命令片段。

- [ ] **Step 7: 记录检查点**

建议提交信息：`docs: document collect-only debugger usage`。提交到当前非 `main` 功能分支。

---

### Task 6: 完整离线验证与首次真机只读采集

**Files:**
- Modify: `tests/debug-focus.Tests.ps1`
- Runtime output: `debug-results/latest/summary.json`
- Runtime output: `debug-results/latest/device-info.txt`
- Runtime output: `debug-results/latest/focus-state.txt`
- Runtime output: `debug-results/latest/logcat-focus.txt`（仅有匹配时）
- Runtime output: `debug-results/latest/crash-focus.txt`（仅检测到明确 Focus 崩溃时）

**Interfaces:**
- Consumes: 完整第一版工具。
- Produces: 离线测试证据和一次明确标注为“真机只读”的运行结果。

- [ ] **Step 1: 增加最终结构断言**

对健康场景检查：

- `schemaVersion=1`、`mode=collect-only`。
- 九个检查 ID 各出现且只出现一次。
- `startedAt` 和 `completedAt` 可被 `[DateTimeOffset]::Parse()` 解析。
- 所有非空附件路径都是简单相对文件名，不包含 `..`，且对应文件位于该场景 `OutputRoot` 内。
- 健康场景总体为 `PASS`。
- JSON 原文不包含 `TEST123` 完整序列号。

- [ ] **Step 2: 运行完整离线测试两次**

Run:

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
```

Expected: 两次均退出 `0`；重复运行不依赖残留文件，不连接真实设备。

- [ ] **Step 3: 静态确认只读 ADB 命令集合**

执行：

```powershell
Select-String -LiteralPath .\debug-focus.ps1 -Pattern "Invoke-Adb"
```

人工逐项确认参数只落入：`version`、`devices -l`、`getprop`、`pm path`、`dumpsys package`、`pidof`、`settings get secure enabled_accessibility_services`、`logcat -d -T ... -v threadtime`。

- [ ] **Step 4: 真机前只检查授权状态**

使用已解析到的真实 ADB 路径运行：

```powershell
& 'D:\Program\Android\SDK\platform-tools\adb.exe' devices -l
```

Expected: 目标行状态为 `device`。若仍为 `unauthorized`，停止，不运行采集脚本，并提示用户在已解锁手机上接受 USB 调试 RSA 弹窗。若出现多个 `device`，记录目标序列号并在下一步显式传入 `-Serial`。

- [ ] **Step 5: 执行一次真机只读采集**

单个授权设备：

```powershell
Set-Location D:\focus-autodebug
.\debug-focus.ps1 -AdbPath 'D:\Program\Android\SDK\platform-tools\adb.exe'
```

多个授权设备：

```powershell
.\debug-focus.ps1 -AdbPath 'D:\Program\Android\SDK\platform-tools\adb.exe' -Serial '<adb devices -l 中由用户确认的目标序列号>'
```

Expected: 不启动或切换手机界面；生成 `debug-results\latest\summary.json`。终端返回 `0` 表示采集流程完成且必需检查通过，非零时先读取摘要，不立即修改手机或 Focus。

- [ ] **Step 6: 审阅真机摘要和附件隐私**

先执行：

```powershell
Get-Content -LiteralPath .\debug-results\latest\summary.json -Raw -Encoding UTF8 | ConvertFrom-Json | Format-List
```

只有摘要指向某个附件时才读取该附件。确认：

- 设备应识别为用户实际连接的 realme/ColorOS 设备；若型号不同，以真机输出为准。
- 完整序列号未写入任何报告。
- `focus-state.txt` 未写其他应用的无障碍服务。
- 日志附件没有明显无关应用内容；如有，记录为过滤器缺陷并回到 Task 4 增加失败样本测试。
- 没有因运行脚本导致 Focus 被启动、停止、清数据或权限变化。

- [ ] **Step 7: 记录验证结论**

最终交付说明必须分别列出：

```text
离线测试：PASS/FAIL，运行命令，测试场景数
真机采集：PASS/FAIL/BLOCKED，设备型号，摘要路径
未验证范围：构建、安装、UI 自动化、提醒触发、ColorOS 权限自动化
```

建议提交信息：`test: verify collect-only debugger end to end`。提交到当前非 `main` 功能分支。

---

## Plan Self-Review Record

- Spec coverage: 设计规范第 1～14 节均映射到 Task 1～6；第 15 节明确属于第一版之后，不进入本计划。
- File responsibility: 生产逻辑、测试运行器、假 ADB、使用文档和忽略规则各自只有一个职责；没有提前拆分 PowerShell 模块。
- Type consistency: 所有任务使用相同的函数名、摘要字段、九个检查 ID、四个退出码和 `PASS/FAIL/SKIP` 状态。
- Privacy coverage: 完整序列号、其他无障碍服务、默认截图/UI dump、全量日志和网络上传均被排除。
- State-change coverage: 测试和静态检查同时约束安装、卸载、清数据、授权、UI 输入、Activity 启动和 logcat 清空。
- Placeholder scan: 本计划没有待补写标记或未定义的“照前一步处理”式实现指令。
- YAGNI decision: 第一版保持 1 个生产脚本、1 个测试脚本和 1 个假 ADB；不引入 Pester、模块拆分、配置文件、数据库、归档系统或 Git 初始化。
