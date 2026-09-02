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

function Set-DebugCheck {
    param($Summary, [string]$Id, [ValidateSet('PASS','FAIL','SKIP')][string]$Status, $Message)
    $matches = @($Summary.checks | Where-Object { $_.id -eq $Id })
    if ($matches.Count -ne 1) { throw "检查项不存在或不唯一: $Id" }
    $matches[0].status = $Status
    $matches[0].message = $Message
}

function Write-DebugSummary {
    param($Summary, [string]$OutputRoot, [bool]$FocusCrashDetected = $false)
    $requiredNotPassed = @($Summary.checks | Where-Object {
        $_.id -in $script:RequiredChecks -and $_.status -ne 'PASS'
    }).Count -gt 0
    $Summary.overall = if ($requiredNotPassed -or $FocusCrashDetected) { 'FAIL' } else { 'PASS' }
    $Summary.completedAt = [DateTimeOffset]::Now.ToString('o')
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $json = $Summary | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'summary.json'), $json, [Text.UTF8Encoding]::new($false))
}

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

function Get-AdbDevices {
    param([string]$DevicesOutput)
    $devices = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in ($DevicesOutput -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -like 'List of devices attached*') { continue }
        if ($trimmed -match '^(\S+)\s+(\S+)(?:\s+(.*))?$') {
            $devices.Add([pscustomobject]@{
                Serial = $matches[1]; State = $matches[2]; Details = $matches[3]
            })
            continue
        }
        throw "无法解析 ADB 设备列表中的非空行（第 $lineNumber 行）"
    }
    return @($devices)
}

function Get-SafeSerialHint {
    param([string]$Serial)
    if (-not $Serial -or $Serial.Length -le 4) { return '****' }
    return $Serial.Substring($Serial.Length - 4)
}

function Select-AdbDevice {
    param([object[]]$Devices, [string]$RequestedSerial)
    if ($RequestedSerial) {
        $match = @($Devices | Where-Object Serial -CEQ $RequestedSerial)
        if ($match.Count -ne 1 -or $match[0].State -CNE 'device') {
            $requestedHint = Get-SafeSerialHint -Serial $RequestedSerial
            return [pscustomobject]@{ Selected = $null; Message = "指定设备不可用或未授权: $requestedHint"; UnauthorizedHint = $null }
        }
        return [pscustomobject]@{ Selected = $match[0]; Message = $null; UnauthorizedHint = $null }
    }
    $authorized = @($Devices | Where-Object State -CEQ 'device')
    if ($authorized.Count -eq 1) {
        return [pscustomobject]@{ Selected = $authorized[0]; Message = $null; UnauthorizedHint = $null }
    }
    if ($authorized.Count -gt 1) {
        return [pscustomobject]@{ Selected = $null; Message = '检测到多个已授权设备，请使用 -Serial 明确指定'; UnauthorizedHint = $null }
    }
    $unauthorized = @($Devices | Where-Object State -CEQ 'unauthorized')
    $hint = if ($unauthorized.Count -eq 1) {
        Get-SafeSerialHint -Serial $unauthorized[0].Serial
    } else { $null }
    $message = if ($unauthorized.Count -gt 0) { '设备已连接，但尚未授权 USB 调试' } else { '未发现已授权的 ADB 设备' }
    [pscustomobject]@{ Selected = $null; Message = $message; UnauthorizedHint = $hint }
}

function Invoke-FocusDebugCollection {
    $summary = New-DebugSummary -PackageName $PackageName -StartedAt ([DateTimeOffset]::Now)
    $exitCode = 30
    $focusCrashDetected = $false
    $resolvedAdb = $null
    $adbReady = $false
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
                $adbReady = $true
            }
        }
    }
    catch {
        Set-DebugCheck -Summary $summary -Id 'environment.adb' -Status 'FAIL' -Message $_.Exception.Message
        $exitCode = if ($resolvedAdb) { 10 } else { 30 }
    }
    if ($adbReady) {
        try {
            $devicesResult = Invoke-Adb -AdbPath $resolvedAdb -Arguments @('devices', '-l')
            if ($devicesResult.ExitCode -ne 0) {
                Set-DebugCheck -Summary $summary -Id 'device.authorized' -Status 'FAIL' -Message '设备列表读取失败，请检查 ADB 输出或连接状态'
                $exitCode = 10
            }
            else {
                $devices = Get-AdbDevices -DevicesOutput $devicesResult.StdOut
                $selection = Select-AdbDevice -Devices $devices -RequestedSerial $Serial
                $summary.device.serialHint = $selection.UnauthorizedHint
                if ($selection.Selected) {
                    $selectedSerial = $selection.Selected.Serial
                    $summary.device.authorized = $true
                    $summary.device.serialHint = Get-SafeSerialHint -Serial $selectedSerial
                    Set-DebugCheck -Summary $summary -Id 'device.authorized' -Status 'PASS' -Message $null
                }
                else {
                    Set-DebugCheck -Summary $summary -Id 'device.authorized' -Status 'FAIL' -Message $selection.Message
                }
                $exitCode = 10
            }
        }
        catch {
            Set-DebugCheck -Summary $summary -Id 'device.authorized' -Status 'FAIL' -Message "设备列表读取失败：$($_.Exception.Message)"
            $exitCode = 30
        }
    }
    try {
        Write-DebugSummary -Summary $summary -OutputRoot $OutputRoot -FocusCrashDetected $focusCrashDetected
    }
    catch {
        $summaryPath = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) 'summary.json'
        Write-Error "无法写入调试摘要 [目标: $summaryPath]: $($_.Exception.Message)" -ErrorAction Continue
        return 20
    }
    Write-Host '模式: collect-only'
    if ($summary.device.serialHint) {
        Write-Host "设备: ****$($summary.device.serialHint)"
    }
    else {
        Write-Host '设备: 未选择'
    }
    Write-Host "结果: $($summary.overall)"
    Write-Host "摘要: $(Join-Path ([IO.Path]::GetFullPath($OutputRoot)) 'summary.json')"
    Write-Host '隐私: 分享报告前请人工检查日志附件。'
    return $exitCode
}

$exitCode = Invoke-FocusDebugCollection
exit $exitCode
