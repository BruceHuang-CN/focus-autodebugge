param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AdbArgs)
Set-StrictMode -Version Latest
$scenario = if ($env:FOCUS_FAKE_ADB_SCENARIO) { $env:FOCUS_FAKE_ADB_SCENARIO } else { 'healthy' }
$fixtureSerial = if ($scenario -in @('focus-crash', 'focus-crash-required-failure')) { 'FOCUS.SERIAL+SENTINEL' } else { 'TEST123' }
$commandLineArgs = @([Environment]::GetCommandLineArgs())
$fileIndex = -1
for ($index = 0; $index -lt $commandLineArgs.Count; $index++) {
    if ($commandLineArgs[$index] -ceq '-File') {
        $fileIndex = $index
        break
    }
}
$firstScriptArgument = $fileIndex + 2
if ($fileIndex -ge 0 -and $firstScriptArgument -lt $commandLineArgs.Count) {
    $AdbArgs = @($commandLineArgs[$firstScriptArgument..($commandLineArgs.Count - 1)])
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
        default { "$fixtureSerial device product:test model:RMX3350 transport_id:1" }
    }
    exit 0
}
$fixturePackage = if ($env:FOCUS_FAKE_ADB_PACKAGE) { $env:FOCUS_FAKE_ADB_PACKAGE } else { 'com.example.focus_app' }
[string[]]$tail = [string[]]::new(0)
if ($AdbArgs.Count -ge 3 -and $AdbArgs[0] -ceq '-s') {
    $tail = @($AdbArgs[2..($AdbArgs.Count - 1)])
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
09-02 20:00:00.002  2468  2468 I FocusDebug: API Key: api-key-colon-sentinel
09-02 20:00:00.003  2468  2468 I FocusDebug: APIKEY=apikey-equals-sentinel
09-02 20:00:00.004  2468  2468 I FocusDebug: authorization=Bearer authorization-equals-bearer-sentinel
09-02 20:00:00.005  2468  2468 I FocusDebug: Authorization : bearer authorization-colon-bearer-sentinel
"@
        exit 0
    }
    if ($scenario -ceq 'foreign-crash') {
        @"
09-02 20:00:00.000  9000  9000 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  9000  9000 E AndroidRuntime: Process: com.other.app, PID: 9000
09-02 20:00:00.002  9000  9000 E AndroidRuntime: java.lang.IllegalStateException: FOREIGN_CRASH_SENTINEL
09-02 20:00:01.000  2468  2468 I FocusDebug: package=$fixturePackage healthy
"@
        exit 0
    }
    if ($scenario -in @('focus-crash', 'focus-crash-required-failure')) {
        @"
09-02 20:00:00.000  2468  2468 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  2468  2468 E AndroidRuntime: Process: $fixturePackage, PID: 2468
09-02 20:00:00.002  2468  2468 E AndroidRuntime: java.lang.IllegalStateException: FOCUS_CRASH_SENTINEL deviceSerial=$fixtureSerial
"@
        exit 0
    }
    if ($scenario -ceq 'focus-crash-process-source') {
        @"
09-02 20:00:00.000  3579  3579 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  3579  3579 E AndroidRuntime: Process: $fixturePackage, PID: 3579
09-02 20:00:00.002  3579  3579 E AndroidRuntime: java.lang.IllegalStateException: PROCESS_PID_SOURCE_SENTINEL
"@
        exit 0
    }
    if ($scenario -ceq 'focus-crash-tombstone-source') {
        @"
09-02 20:00:00.000  4680  4680 E AndroidRuntime: FATAL EXCEPTION: main
09-02 20:00:00.001  4680  4680 F DEBUG: pid: 4680, tid: 4680, name: focus  >>> $fixturePackage <<<
09-02 20:00:00.002  4680  4680 E AndroidRuntime: java.lang.IllegalStateException: TOMBSTONE_PID_SOURCE_SENTINEL
"@
        exit 0
    }
    @"
09-02 20:00:00.000  2468  2468 I FocusDebug: Focus startup complete
09-02 20:00:00.010  9000  9000 I OtherApp: OTHER_PRIVATE_SENTINEL
09-02 20:00:00.020  2468  2469 I FocusDebug: package=$fixturePackage ready
09-02 20:00:00.030  9000  9000 I OtherApp: OTHER_PACKAGE_SUFFIX_SENTINEL package=$fixturePackage.clone
09-02 20:00:00.040  9000  9000 I OtherApp: OTHER_PACKAGE_PREFIX_SENTINEL package=com.other.$fixturePackage
09-02 20:00:00.050  9000  9000 I OtherApp: OTHER_PACKAGE_EXACT_SENTINEL mention=$fixturePackage
"@
    exit 0
}
if ($tailText -ceq 'shell getprop ro.product.manufacturer') { 'realme'; exit 0 }
if ($tailText -ceq 'shell getprop ro.product.model') {
    if ($scenario -eq 'focus-crash-required-failure') {
        [Console]::Error.WriteLine('模拟设备型号读取失败')
        exit 7
    }
    'RMX3350'; exit 0
}
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
    if ($scenario -in @('pidof-empty', 'focus-crash-process-source', 'focus-crash-tombstone-source')) { exit 0 }
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
