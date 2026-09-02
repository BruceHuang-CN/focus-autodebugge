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
