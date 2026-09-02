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

function Invoke-DebugScriptProcess {
    param([string[]]$Arguments)
    $capturedOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $scriptUnderTest @Arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $capturedOutput
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
if ($Arguments.Count -ne 1 -or $Arguments[0] -ne 'version') { exit 2 }
exit 0
'@ | Set-Content -LiteralPath $fakeAdb -Encoding UTF8
    try {
        $result = Invoke-DebugScriptProcess -Arguments @('-AdbPath', $fakeAdb, '-OutputRoot', $outputRoot)
        $summaryPath = Join-Path $outputRoot 'summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath)) { throw '未生成 summary.json' }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 10 $result.ExitCode '设备前提未满足退出码不正确'
        Assert-Equal 'FAIL' $summary.overall '必需检查 SKIP 时 overall 应为 FAIL'
        Assert-Equal 'PASS' (Get-Check $summary 'environment.adb').status '假 ADB 版本检查状态不正确'
        Assert-Equal 'SKIP' (Get-Check $summary 'device.authorized').status '设备检查状态不正确'
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

function Invoke-RequestedSerialPrivacyCase {
    param(
        [string]$Scenario,
        [string]$RequestedSerial
    )
    $result = Invoke-DebugCase -Scenario $Scenario -ExtraArguments @('-Serial', $RequestedSerial)
    try {
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
        if (($selected.Summary | ConvertTo-Json -Depth 8) -match 'TEST123') { throw '摘要错误包含未选择设备的完整序列号' }
    }
    finally {
        Remove-Item -LiteralPath $selected.OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'PASS selected-serial'
}
catch { $failures.Add("selected-serial: $($_.Exception.Message)"); Write-Host 'FAIL selected-serial' }

try {
    $single = Invoke-DebugCase -Scenario 'healthy'
    try {
        Assert-Equal 'PASS' (Get-Check $single.Summary 'device.authorized').status '单个授权设备未自动选择'
        Assert-Equal 'T123' $single.Summary.device.serialHint '自动选择设备提示不正确'
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

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
exit 0
