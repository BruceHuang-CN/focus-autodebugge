param(
    [switch]$OnlyShortSerial,
    [switch]$OnlyPidofEmpty
)

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

function Assert-FakeAdbReadOnlyCalls {
    param(
        [string]$Calls,
        [string]$SelectedSerial,
        [string]$PackageName = 'com.example.focus_app'
    )
    $lines = @($Calls -split "`r?`n" | Where-Object { $_ })
    $allowedShellTails = @(
        "shell getprop ro.product.manufacturer",
        "shell getprop ro.product.model",
        "shell getprop ro.build.version.release",
        "shell getprop ro.build.version.sdk",
        "shell pm path $PackageName",
        "shell dumpsys package $PackageName",
        "shell pidof $PackageName",
        'shell settings get secure enabled_accessibility_services'
    )
    foreach ($line in $lines) {
        $parts = @($line -split "`t")
        $allowed = ($parts.Count -eq 1 -and $parts[0] -ceq 'version') -or
            ($parts.Count -eq 2 -and $parts[0] -ceq 'devices' -and $parts[1] -ceq '-l')
        if (-not $allowed -and $SelectedSerial -and $parts.Count -ge 3 -and
            $parts[0] -ceq '-s' -and $parts[1] -ceq $SelectedSerial) {
            $tail = (@($parts | Select-Object -Skip 2) -join ' ')
            $allowed = $tail -in $allowedShellTails
        }
        if (-not $allowed) {
            throw "fake ADB 调用超出本批次白名单: $line"
        }
    }
}

function Get-Check {
    param($Summary, [string]$Id)
    return @($Summary.checks | Where-Object id -EQ $Id)[0]
}

function Assert-TextKeyValue {
    param([string]$Text, [string]$Key, [string]$ExpectedValue, [string]$Message)
    $Text = $Text -replace "`r`n", "`n"
    $pattern = "(?m)^$([regex]::Escape($Key))=$([regex]::Escape($ExpectedValue))$"
    if ($Text -notmatch $pattern) { throw $Message }
}

function Invoke-DebugScriptProcess {
    param([string[]]$Arguments)
    $capturedOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $scriptUnderTest @Arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $capturedOutput
    }
}

function Invoke-FakeAdbVector {
    param([string[]]$Arguments)
    $fakeAdb = Join-Path $PSScriptRoot 'fixtures\fake-adb.ps1'
    $capturedOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $fakeAdb @Arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $capturedOutput
    }
}

function Assert-FakeAdbRejectsVector {
    param([string[]]$Arguments, [string]$Label)
    $result = Invoke-FakeAdbVector -Arguments $Arguments
    if ($result.ExitCode -eq 0) {
        throw "$Label 必须返回非零退出码"
    }
    $output = $result.Output -join "`n"
    if ($output -match 'List of devices attached|TEST123 device|Android Debug Bridge version|(?m)^realme$|(?m)^RMX3350$') {
        throw "$Label 不得输出正常 fake ADB 结果"
    }
}

function Invoke-FakeAdbStrictWhitelistCase {
    Assert-FakeAdbRejectsVector -Arguments @('VERSION') -Label 'version 大小写变体'
    Assert-FakeAdbRejectsVector -Arguments @('version', 'EXTRA') -Label 'version 多余参数'
    Assert-FakeAdbRejectsVector -Arguments @('DEVICES', '-l') -Label 'devices 大小写变体'
    Assert-FakeAdbRejectsVector -Arguments @('devices', '-L') -Label 'devices -l 大小写变体'
    Assert-FakeAdbRejectsVector -Arguments @('devices', '-l', 'EXTRA') -Label 'devices -l 多余参数'
    Assert-FakeAdbRejectsVector -Arguments @('devices', '-l', '-s', 'TEST123') -Label 'devices -l 额外向量'

    $tailTexts = @(
        'shell getprop ro.product.manufacturer',
        'shell getprop ro.product.model',
        'shell getprop ro.build.version.release',
        'shell getprop ro.build.version.sdk',
        'shell pm path com.example.focus_app',
        'shell dumpsys package com.example.focus_app',
        'shell pidof com.example.focus_app',
        'shell settings get secure enabled_accessibility_services'
    )
    foreach ($tailText in $tailTexts) {
        $tail = @($tailText -split ' ')
        $caseVariant = @($tail)
        $caseVariant[0] = $caseVariant[0].ToUpperInvariant()
        Assert-FakeAdbRejectsVector -Arguments (@('-s', 'TEST123') + $caseVariant) -Label "$tailText 大小写变体"
        Assert-FakeAdbRejectsVector -Arguments (@('-s', 'TEST123') + @($tail + 'EXTRA')) -Label "$tailText 多余参数"
    }
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

function Invoke-ReportWriteFailureCase {
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-report-file-" + [guid]::NewGuid())
    $missingAdb = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-missing-" + [guid]::NewGuid() + '.exe')
    Set-Content -LiteralPath $outputRoot -Value 'not a directory' -Encoding UTF8
    try {
        $result = Invoke-DebugScriptProcess -Arguments @('-AdbPath', $missingAdb, '-OutputRoot', $outputRoot)
        Assert-Equal 20 $result.ExitCode '报告写入失败退出码不正确'
        $summaryPath = Join-Path $outputRoot 'summary.json'
        $consoleText = $result.Output -join "`n"
        if ($consoleText -notmatch '无法写入调试摘要 \[目标:') {
            throw '报告写入失败控制台必须标明目标 summary.json'
        }
        if ($consoleText -notmatch [regex]::Escape($summaryPath)) {
            throw '报告写入失败控制台缺少目标 summary.json 路径'
        }
        if ($consoleText -notmatch 'Exception calling|Could not find|Cannot') {
            throw '报告写入失败控制台必须包含异常原因'
        }
    }
    finally {
        Remove-Item -LiteralPath $outputRoot -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UnexecutableAdbCase {
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-unexecutable-" + [guid]::NewGuid())
    $adbText = Join-Path $outputRoot 'adb.txt'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    Set-Content -LiteralPath $adbText -Value 'this is not an executable' -Encoding UTF8
    try {
        $result = Invoke-DebugScriptProcess -Arguments @('-AdbPath', $adbText, '-OutputRoot', $outputRoot)
        $summaryPath = Join-Path $outputRoot 'summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath)) { throw '未生成 summary.json' }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 10 $result.ExitCode 'ADB 不可执行退出码不正确'
        Assert-Equal 'FAIL' (Get-Check $summary 'environment.adb').status 'ADB 不可执行检查状态不正确'
    }
    finally {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VersionOnlyAdbCase {
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-version-only-" + [guid]::NewGuid())
    $fakeAdb = Join-Path $outputRoot 'fake-adb.ps1'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
@'
param([string[]]$Arguments)
if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'version') { exit 0 }
if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'devices' -and $Arguments[1] -eq '-l') {
    [Console]::Error.WriteLine('模拟设备列表读取失败')
    exit 7
}
exit 2
'@ | Set-Content -LiteralPath $fakeAdb -Encoding UTF8
    try {
        $result = Invoke-DebugScriptProcess -Arguments @('-AdbPath', $fakeAdb, '-OutputRoot', $outputRoot)
        $summaryPath = Join-Path $outputRoot 'summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath)) { throw '未生成 summary.json' }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 10 $result.ExitCode '设备前提未满足退出码不正确'
        Assert-Equal 'FAIL' $summary.overall '必需检查 SKIP 时 overall 应为 FAIL'
        Assert-Equal 'PASS' (Get-Check $summary 'environment.adb').status '假 ADB 版本检查状态不正确'
        Assert-Equal 'FAIL' (Get-Check $summary 'device.authorized').status '设备列表读取失败时设备检查应为 FAIL'
        if ((Get-Check $summary 'device.authorized').message -notmatch '设备列表读取失败') {
            throw '设备列表读取失败消息不明确'
        }
    }
    finally {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
    $previousPackage = $env:FOCUS_FAKE_ADB_PACKAGE
    $packageName = 'com.example.focus_app'
    $requestedSerial = $null
    for ($index = 0; $index -lt $ExtraArguments.Count; $index++) {
        if ($ExtraArguments[$index] -eq '-PackageName' -and $index + 1 -lt $ExtraArguments.Count) {
            $packageName = $ExtraArguments[$index + 1]
        }
        if ($ExtraArguments[$index] -eq '-Serial' -and $index + 1 -lt $ExtraArguments.Count) {
            $requestedSerial = $ExtraArguments[$index + 1]
        }
    }
    $expectedSerial = $null
    if ($Scenario -in @('healthy', 'not-installed', 'stopped', 'pidof-failed', 'pidof-empty',
            'accessibility-failed', 'accessibility-disabled', 'provenance-missing',
            'dumpsys-failed', 'pm-path-failed')) {
        $expectedSerial = 'TEST123'
    }
    if ($Scenario -eq 'multiple' -and $requestedSerial -eq 'TEST456') {
        $expectedSerial = 'TEST456'
    }
    try {
        $env:FOCUS_FAKE_ADB_SCENARIO = $Scenario
        $env:FOCUS_FAKE_ADB_CALLS = $callsPath
        $env:FOCUS_FAKE_ADB_PACKAGE = $packageName
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
        Assert-FakeAdbReadOnlyCalls -Calls $calls -SelectedSerial $expectedSerial -PackageName $packageName
        [pscustomobject]@{
            ExitCode = $exitCode
            Summary = $summary
            Calls = $calls
            Console = $console
            OutputRoot = $outputRoot
            PackageName = $packageName
        }
    }
    finally {
        $env:FOCUS_FAKE_ADB_SCENARIO = $previousScenario
        $env:FOCUS_FAKE_ADB_CALLS = $previousCalls
        $env:FOCUS_FAKE_ADB_PACKAGE = $previousPackage
    }
}

function Invoke-FocusStateWriteFailureCase {
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("focus-autodebug-focus-state-dir-" + [guid]::NewGuid())
    $callsPath = Join-Path $outputRoot 'adb-calls.txt'
    $fakeAdb = Join-Path $PSScriptRoot 'fixtures\fake-adb.ps1'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $outputRoot 'focus-state.txt') -Force | Out-Null
    $previousScenario = $env:FOCUS_FAKE_ADB_SCENARIO
    $previousCalls = $env:FOCUS_FAKE_ADB_CALLS
    $previousPackage = $env:FOCUS_FAKE_ADB_PACKAGE
    try {
        $env:FOCUS_FAKE_ADB_SCENARIO = 'healthy'
        $env:FOCUS_FAKE_ADB_CALLS = $callsPath
        $env:FOCUS_FAKE_ADB_PACKAGE = 'com.example.focus_app'
        $console = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $scriptUnderTest `
            -AdbPath $fakeAdb -OutputRoot $outputRoot 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $summary = Get-Content -LiteralPath (Join-Path $outputRoot 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $calls = if (Test-Path -LiteralPath $callsPath) {
            Get-Content -LiteralPath $callsPath -Raw -Encoding UTF8
        } else { '' }
        Assert-FakeAdbReadOnlyCalls -Calls $calls -SelectedSerial 'TEST123'
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
        $env:FOCUS_FAKE_ADB_PACKAGE = $previousPackage
    }
}

function Invoke-RequestedSerialPrivacyCase {
    param(
        [string]$Scenario,
        [string]$RequestedSerial
    )
    $result = Invoke-DebugCase -Scenario $Scenario -ExtraArguments @('-Serial', $RequestedSerial)
    try {
        Assert-Equal 10 $result.ExitCode '显式设备失败退出码不正确'
        Assert-Equal 'FAIL' $result.Summary.overall '显式设备失败 overall 不正确'
        Assert-Equal 'FAIL' (Get-Check $result.Summary 'device.authorized').status '显式设备失败状态不正确'
        if (($result.Summary | ConvertTo-Json -Depth 8) -match [regex]::Escape($RequestedSerial)) {
            throw '摘要不应包含显式请求设备的完整序列号'
        }
        if ($result.Calls -match '(?m)^-s\t') { throw '显式设备失败时不应执行设备命令' }
    }
    finally {
        Remove-Item -LiteralPath $result.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ShortRequestedSerialCase {
    $result = Invoke-DebugCase -Scenario 'multiple' -ExtraArguments @('-Serial', 'ABC')
    try {
        $check = Get-Check $result.Summary 'device.authorized'
        Assert-Equal 'FAIL' $check.status '短显式设备失败状态不正确'
        Assert-Equal '指定设备不可用或未授权: ****' $check.message '短序列号安全提示不正确'
        if (($result.Summary | ConvertTo-Json -Depth 8) -match [regex]::Escape('ABC')) {
            throw '摘要不应包含长度不超过四位的原始序列号'
        }
        if ($result.Console -cmatch [regex]::Escape('ABC')) { throw '控制台不应包含长度不超过四位的原始序列号' }
        if ($result.Calls -match '(?m)^-s\t') { throw '短显式设备失败时不应执行设备命令' }
    }
    finally {
        Remove-Item -LiteralPath $result.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PidofEmptyCase {
    $result = Invoke-DebugCase -Scenario 'pidof-empty'
    try {
        Assert-Equal 0 $result.ExitCode 'pidof 退出码 0 且空输出时退出码不正确'
        Assert-Equal $false $result.Summary.app.processAlive 'pidof 退出码 0 且空输出时进程状态必须为 false'
        Assert-Equal 'PASS' (Get-Check $result.Summary 'app.process').status 'pidof 退出码 0 且空输出时进程检查应为 PASS'
    }
    finally {
        Remove-Item -LiteralPath $result.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($OnlyShortSerial) {
    try {
        Invoke-ShortRequestedSerialCase
        Write-Host 'PASS short-requested-serial-privacy'
    }
    catch { $failures.Add("short-requested-serial-privacy: $($_.Exception.Message)"); Write-Host 'FAIL short-requested-serial-privacy' }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Error $_ }
        exit 1
    }
    exit 0
}

if ($OnlyPidofEmpty) {
    try {
        Invoke-PidofEmptyCase
        Write-Host 'PASS pidof-empty'
    }
    catch {
        $failures.Add("pidof-empty: $($_.Exception.Message)")
        Write-Host 'FAIL pidof-empty'
    }
    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Error $_ }
        exit 1
    }
    exit 0
}

try {
    Invoke-FakeAdbStrictWhitelistCase
    Write-Host 'PASS fake-adb-strict-whitelist'
}
catch {
    $failures.Add("fake-adb-strict-whitelist: $($_.Exception.Message)")
    Write-Host 'FAIL fake-adb-strict-whitelist'
}

try {
    $unauthorized = Invoke-DebugCase -Scenario 'unauthorized'
    try {
        Assert-Equal 10 $unauthorized.ExitCode '未授权设备退出码不正确'
        Assert-Equal 'FAIL' (Get-Check $unauthorized.Summary 'device.authorized').status '未授权状态不正确'
        if ($unauthorized.Calls -match '(?m)^-s\t') { throw '未授权场景不应执行设备 shell 命令' }
    }
    finally {
        Remove-Item -LiteralPath $unauthorized.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS unauthorized-device'
}
catch { $failures.Add("unauthorized-device: $($_.Exception.Message)"); Write-Host 'FAIL unauthorized-device' }

try {
    $multiple = Invoke-DebugCase -Scenario 'multiple'
    try {
        Assert-Equal 10 $multiple.ExitCode '多设备退出码不正确'
        if ((Get-Check $multiple.Summary 'device.authorized').message -notmatch '-Serial') {
            throw '多设备错误消息必须提示 -Serial'
        }
        if ($multiple.Calls -match '(?m)^-s\t') { throw '未明确选中设备时不应执行设备命令' }
    }
    finally {
        Remove-Item -LiteralPath $multiple.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS multiple-devices'
}
catch { $failures.Add("multiple-devices: $($_.Exception.Message)"); Write-Host 'FAIL multiple-devices' }

try {
    $selected = Invoke-DebugCase -Scenario 'multiple' -ExtraArguments @('-Serial', 'TEST456')
    try {
        Assert-Equal 'PASS' (Get-Check $selected.Summary 'device.authorized').status '没有接受明确指定的授权设备'
        Assert-Equal 'T456' $selected.Summary.device.serialHint '设备提示没有使用已选设备末四位'
        $selectedJson = $selected.Summary | ConvertTo-Json -Depth 8
        if ($selectedJson -match 'TEST123|TEST456') { throw '摘要不应包含任何完整设备序列号' }
        if ($selected.Console -match 'TEST123|TEST456') { throw '控制台不应包含任何完整设备序列号' }
    }
    finally {
        Remove-Item -LiteralPath $selected.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS selected-serial'
}
catch { $failures.Add("selected-serial: $($_.Exception.Message)"); Write-Host 'FAIL selected-serial' }

try {
    $healthy = Invoke-DebugCase -Scenario 'healthy'
    try {
        Assert-Equal 0 $healthy.ExitCode '健康场景退出码不正确'
        Assert-Equal 'PASS' $healthy.Summary.overall '健康场景 overall 不正确'
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
        foreach ($checkId in @('device.info', 'app.installed', 'app.provenance', 'app.process', 'permission.accessibility')) {
            Assert-Equal 'PASS' (Get-Check $healthy.Summary $checkId).status "$checkId 检查状态错误"
        }
        Assert-Equal 'device-info.txt' $healthy.Summary.artifacts.deviceInfo '设备附件路径错误'
        Assert-Equal 'focus-state.txt' $healthy.Summary.artifacts.focusState 'Focus 附件路径错误'

        $deviceInfo = Get-Content -LiteralPath (Join-Path $healthy.OutputRoot 'device-info.txt') -Raw -Encoding UTF8
        $deviceInfo = ($deviceInfo -replace "`r`n", "`n").Trim()
        Assert-Equal "manufacturer=realme`nmodel=RMX3350`nandroid=11`nsdk=30" $deviceInfo '设备附件内容错误'
        if ($deviceInfo -match 'TEST123') { throw '设备附件不应包含完整设备序列号' }

        $focusState = Get-Content -LiteralPath (Join-Path $healthy.OutputRoot 'focus-state.txt') -Raw -Encoding UTF8
        Assert-TextKeyValue $focusState 'packageName' 'com.example.focus_app' 'Focus 附件缺少包名'
        Assert-TextKeyValue $focusState 'installed' 'true' 'Focus 附件安装状态错误'
        Assert-TextKeyValue $focusState 'versionName' '1.2.3' 'Focus 附件版本名错误'
        Assert-TextKeyValue $focusState 'versionCode' '42' 'Focus 附件版本号错误'
        Assert-TextKeyValue $focusState 'lastUpdateTime' '2026-09-02 12:34:56' 'Focus 附件更新时间错误'
        Assert-TextKeyValue $focusState 'processAlive' 'true' 'Focus 附件进程状态错误'
        Assert-TextKeyValue $focusState 'accessibilityEnabled' 'true' 'Focus 附件无障碍状态错误'
        if ($focusState -match 'com\.other\.app|OtherAccessibilityService|enabled_accessibility_services') {
            throw 'Focus 附件不应写入其他应用的无障碍服务列表'
        }
    }
    finally {
        Remove-Item -LiteralPath $healthy.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS healthy-device-and-app-state'
}
catch { $failures.Add("healthy-device-and-app-state: $($_.Exception.Message)"); Write-Host 'FAIL healthy-device-and-app-state' }

try {
    $customPackage = Invoke-DebugCase -Scenario 'healthy' -ExtraArguments @('-PackageName', 'com.example.focus_debug')
    try {
        Assert-Equal 'com.example.focus_debug' $customPackage.Summary.app.packageName '未使用 -PackageName 参数'
        Assert-Equal $true $customPackage.Summary.app.installed '自定义包安装状态错误'
        if ($customPackage.Calls -match 'com\.example\.focus_app') { throw '自定义包场景不应调用默认包名' }
    }
    finally {
        Remove-Item -LiteralPath $customPackage.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS custom-package-name'
}
catch { $failures.Add("custom-package-name: $($_.Exception.Message)"); Write-Host 'FAIL custom-package-name' }

try {
    $stateWriteFailure = Invoke-FocusStateWriteFailureCase
    try {
        Assert-Equal 30 $stateWriteFailure.ExitCode 'Focus 状态附件写入失败退出码不正确'
        Assert-Equal 'FAIL' $stateWriteFailure.Summary.overall 'Focus 状态附件写入失败时 overall 必须为 FAIL'
        Assert-Equal $null $stateWriteFailure.Summary.artifacts.focusState '附件写入失败时不应保留 focusState 指针'
        $collectionFailureProperty = @($stateWriteFailure.Summary.PSObject.Properties | Where-Object Name -EQ 'collectionFailed')
        if ($collectionFailureProperty.Count -ne 1) { throw '摘要必须包含统一 collectionFailed 失败信号' }
        Assert-Equal $true $stateWriteFailure.Summary.collectionFailed '摘要 collectionFailed 失败信号错误'
    }
    finally {
        Remove-Item -LiteralPath $stateWriteFailure.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS focus-state-write-failure'
}
catch { $failures.Add("focus-state-write-failure: $($_.Exception.Message)"); Write-Host 'FAIL focus-state-write-failure' }

try {
    $notInstalled = Invoke-DebugCase -Scenario 'not-installed'
    try {
        Assert-Equal 10 $notInstalled.ExitCode '未安装场景退出码不正确'
        Assert-Equal 'FAIL' $notInstalled.Summary.overall '未安装场景 overall 不正确'
        Assert-Equal $false $notInstalled.Summary.app.installed '未安装状态错误'
        Assert-Equal $null $notInstalled.Summary.app.processAlive '未安装时进程状态必须为 null'
        Assert-Equal $null $notInstalled.Summary.app.accessibilityEnabled '未安装时无障碍状态必须为 null'
        Assert-Equal 'FAIL' (Get-Check $notInstalled.Summary 'app.installed').status '未安装检查状态错误'
        foreach ($checkId in @('app.provenance', 'app.process', 'permission.accessibility')) {
            Assert-Equal 'SKIP' (Get-Check $notInstalled.Summary $checkId).status "$checkId 在未安装时应跳过"
        }
        if ($notInstalled.Calls -match 'dumpsys|pidof|enabled_accessibility_services') {
            throw '未安装时不应读取版本、进程或无障碍依赖状态'
        }
    }
    finally {
        Remove-Item -LiteralPath $notInstalled.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS focus-not-installed'
}
catch { $failures.Add("focus-not-installed: $($_.Exception.Message)"); Write-Host 'FAIL focus-not-installed' }

try {
    $stopped = Invoke-DebugCase -Scenario 'stopped'
    try {
        Assert-Equal 0 $stopped.ExitCode '未运行场景退出码不正确'
        Assert-Equal $false $stopped.Summary.app.processAlive '未运行状态错误'
        Assert-Equal 'PASS' (Get-Check $stopped.Summary 'app.process').status '未运行时进程检查应为 PASS'
    }
    finally {
        Remove-Item -LiteralPath $stopped.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS focus-not-running'
}
catch { $failures.Add("focus-not-running: $($_.Exception.Message)"); Write-Host 'FAIL focus-not-running' }

try {
    $pidofFailed = Invoke-DebugCase -Scenario 'pidof-failed'
    try {
        Assert-Equal $null $pidofFailed.Summary.app.processAlive 'pidof 未知失败时进程状态必须为 null'
        Assert-Equal 'FAIL' (Get-Check $pidofFailed.Summary 'app.process').status 'pidof 未知失败时进程检查应为 FAIL'
    }
    finally {
        Remove-Item -LiteralPath $pidofFailed.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS focus-process-unknown'
}
catch { $failures.Add("focus-process-unknown: $($_.Exception.Message)"); Write-Host 'FAIL focus-process-unknown' }

try {
    Invoke-PidofEmptyCase
    Write-Host 'PASS pidof-empty'
}
catch { $failures.Add("pidof-empty: $($_.Exception.Message)"); Write-Host 'FAIL pidof-empty' }

try {
    Invoke-ShortRequestedSerialCase
    Write-Host 'PASS short-requested-serial-privacy'
}
catch { $failures.Add("short-requested-serial-privacy: $($_.Exception.Message)"); Write-Host 'FAIL short-requested-serial-privacy' }

try {
    $single = Invoke-DebugCase -Scenario 'healthy'
    try {
        Assert-Equal 'PASS' (Get-Check $single.Summary 'device.authorized').status '单个授权设备未自动选择'
        Assert-Equal 'T123' $single.Summary.device.serialHint '自动选择设备提示不正确'
        $singleJson = $single.Summary | ConvertTo-Json -Depth 8
        if ($singleJson -match 'TEST123') { throw '摘要不应包含单设备完整序列号' }
        if ($single.Console -match 'TEST123') { throw '控制台不应包含单设备完整序列号' }
    }
    finally {
        Remove-Item -LiteralPath $single.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS single-authorized-device'
}
catch { $failures.Add("single-authorized-device: $($_.Exception.Message)"); Write-Host 'FAIL single-authorized-device' }

try {
    Invoke-RequestedSerialPrivacyCase -Scenario 'multiple' -RequestedSerial 'TEST999'
    Write-Host 'PASS requested-serial-missing-privacy'
}
catch { $failures.Add("requested-serial-missing-privacy: $($_.Exception.Message)"); Write-Host 'FAIL requested-serial-missing-privacy' }

try {
    Invoke-RequestedSerialPrivacyCase -Scenario 'unauthorized' -RequestedSerial 'TEST123'
    Write-Host 'PASS requested-serial-unauthorized-privacy'
}
catch { $failures.Add("requested-serial-unauthorized-privacy: $($_.Exception.Message)"); Write-Host 'FAIL requested-serial-unauthorized-privacy' }

try { Invoke-MissingAdbCase; Write-Host 'PASS missing-adb' }
catch { $failures.Add("missing-adb: $($_.Exception.Message)"); Write-Host 'FAIL missing-adb' }

try { Invoke-ReportWriteFailureCase; Write-Host 'PASS report-write-failure' }
catch { $failures.Add("report-write-failure: $($_.Exception.Message)"); Write-Host 'FAIL report-write-failure' }

try { Invoke-UnexecutableAdbCase; Write-Host 'PASS unexecutable-adb' }
catch { $failures.Add("unexecutable-adb: $($_.Exception.Message)"); Write-Host 'FAIL unexecutable-adb' }

try { Invoke-VersionOnlyAdbCase; Write-Host 'PASS version-only-adb' }
catch { $failures.Add("version-only-adb: $($_.Exception.Message)"); Write-Host 'FAIL version-only-adb' }

try {
    $malformed = Invoke-DebugCase -Scenario 'malformed'
    try {
        Assert-Equal 30 $malformed.ExitCode '设备输出解析异常退出码不正确'
        Assert-Equal 'PASS' (Get-Check $malformed.Summary 'environment.adb').status '设备输出解析异常不应污染 ADB 环境状态'
        Assert-Equal 'FAIL' (Get-Check $malformed.Summary 'device.authorized').status '设备输出解析异常状态不正确'
        Assert-Equal 'FAIL' $malformed.Summary.overall '设备输出解析异常 overall 不正确'
        if ((Get-Check $malformed.Summary 'device.authorized').message -notmatch '非空行') {
            throw '设备输出解析异常消息必须说明拒绝了无法解析的非空行'
        }
    }
    finally {
        Remove-Item -LiteralPath $malformed.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS malformed-devices-output'
}
catch { $failures.Add("malformed-devices-output: $($_.Exception.Message)"); Write-Host 'FAIL malformed-devices-output' }

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
exit 0
