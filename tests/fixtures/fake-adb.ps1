param(
    [Alias('d')][switch]$DebugFlag,
    [Alias('v')][switch]$VerboseFlag,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$AdbArgs
)
Set-StrictMode -Version Latest
$scenario = if ($env:FOCUS_FAKE_ADB_SCENARIO) { $env:FOCUS_FAKE_ADB_SCENARIO } else { 'healthy' }
$rawCommandLine = [Environment]::CommandLine
$hasExactDebugFlag = $DebugFlag -and $rawCommandLine -cmatch '(?<!\S)-d(?=\s|$)'
$hasExactVerboseFlag = $VerboseFlag -and $rawCommandLine -cmatch '(?<!\S)-v(?=\s|$)'
if (($hasExactDebugFlag -or $hasExactVerboseFlag) -and $AdbArgs -contains 'logcat') {
    $rebuiltArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $AdbArgs) {
        if ($hasExactDebugFlag -and $argument -ceq 'logcat') {
            [void]$rebuiltArgs.Add($argument)
            [void]$rebuiltArgs.Add('-d')
            continue
        }
        if ($hasExactVerboseFlag -and $argument -ceq 'threadtime') {
            [void]$rebuiltArgs.Add('-v')
        }
        [void]$rebuiltArgs.Add($argument)
    }
    $AdbArgs = $rebuiltArgs.ToArray()
}
if ($env:FOCUS_FAKE_ADB_CALLS) {
    [IO.File]::AppendAllText($env:FOCUS_FAKE_ADB_CALLS, (($AdbArgs -join "`t") + "`n"))
}
if ($AdbArgs.Count -eq 1 -and $AdbArgs[0] -ceq 'version') {
    'Android Debug Bridge version 1.0.41'; exit 0
}
if ($AdbArgs.Count -eq 2 -and $AdbArgs[0] -ceq 'devices' -and $AdbArgs[1] -ceq '-l') {
    'List of devices attached'
    switch ($scenario) {
        'unauthorized' { 'TEST123 unauthorized usb:1-1 transport_id:1' }
        'malformed' { 'MALFORMED_DEVICE_LINE' }
        'multiple' {
            'TEST123 device product:test model:Phone_A transport_id:1'
            'TEST456 device product:test model:Phone_B transport_id:2'
        }
        default { 'TEST123 device product:test model:RMX3350 transport_id:1' }
    }
    exit 0
}
$fixturePackage = if ($env:FOCUS_FAKE_ADB_PACKAGE) { $env:FOCUS_FAKE_ADB_PACKAGE } else { 'com.example.focus_app' }
$tail = if ($AdbArgs.Count -ge 3 -and $AdbArgs[0] -ceq '-s') {
    @($AdbArgs[2..($AdbArgs.Count - 1)])
} else {
    @()
}
$tailText = $tail -join ' '
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
if ($tailText -ceq 'shell getprop ro.product.manufacturer') { 'realme'; exit 0 }
if ($tailText -ceq 'shell getprop ro.product.model') { 'RMX3350'; exit 0 }
if ($tailText -ceq 'shell getprop ro.build.version.release') { '11'; exit 0 }
if ($tailText -ceq 'shell getprop ro.build.version.sdk') { '30'; exit 0 }
if ($tailText -ceq "shell pm path $fixturePackage") {
    if ($scenario -eq 'not-installed') { exit 0 }
    if ($scenario -eq 'pm-path-failed') {
        [Console]::Error.WriteLine('模拟 pm path 失败')
        exit 7
    }
    "package:/data/app/$fixturePackage/base.apk"; exit 0
}
if ($tailText -ceq "shell dumpsys package $fixturePackage") {
    if ($scenario -eq 'not-installed') { "Unable to find package: $fixturePackage"; exit 0 }
    if ($scenario -eq 'dumpsys-failed') {
        [Console]::Error.WriteLine('模拟 dumpsys 失败')
        exit 5
    }
    if ($scenario -eq 'provenance-missing') {
        @"
Packages:
  Package [$fixturePackage]
    versionName=1.2.3
"@; exit 0
    }
    @"
Packages:
  Package [$fixturePackage]
    versionCode=42 minSdk=26 targetSdk=35
    versionName=1.2.3
    lastUpdateTime=2026-09-02 12:34:56
"@; exit 0
}
if ($tailText -ceq "shell pidof $fixturePackage") {
    if ($scenario -eq 'stopped') { exit 1 }
    if ($scenario -eq 'pidof-empty') { exit 0 }
    if ($scenario -eq 'pidof-failed') {
        [Console]::Error.WriteLine('模拟 pidof 失败')
        exit 7
    }
    '2468'; exit 0
}
if ($tailText -ceq 'shell settings get secure enabled_accessibility_services') {
    if ($scenario -eq 'accessibility-failed') {
        [Console]::Error.WriteLine('模拟无障碍读取失败')
        exit 5
    }
    if ($scenario -eq 'accessibility-disabled') {
        'com.other.app/.service.OtherAccessibilityService'; exit 0
    }
    'com.other.app/.service.OtherAccessibilityService:' + "$fixturePackage/.service.FocusAccessibilityService"; exit 0
}
Write-Error "fake-adb 尚未定义该调用: $($AdbArgs -join ' ')"
exit 9
