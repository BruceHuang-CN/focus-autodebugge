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
$tail = if ($AdbArgs.Count -ge 3 -and $AdbArgs[0] -eq '-s') {
    @($AdbArgs[2..($AdbArgs.Count - 1)])
} else {
    @()
}
$tailText = $tail -join ' '
if ($tailText -eq 'shell getprop ro.product.manufacturer') { 'realme'; exit 0 }
if ($tailText -eq 'shell getprop ro.product.model') { 'RMX3350'; exit 0 }
if ($tailText -eq 'shell getprop ro.build.version.release') { '11'; exit 0 }
if ($tailText -eq 'shell getprop ro.build.version.sdk') { '30'; exit 0 }
if ($tailText -eq "shell pm path $fixturePackage") {
    if ($scenario -eq 'not-installed') { exit 0 }
    if ($scenario -eq 'pm-path-failed') {
        [Console]::Error.WriteLine('模拟 pm path 失败')
        exit 7
    }
    "package:/data/app/$fixturePackage/base.apk"; exit 0
}
if ($tailText -eq "shell dumpsys package $fixturePackage") {
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
if ($tailText -eq "shell pidof $fixturePackage") {
    if ($scenario -eq 'stopped') { exit 1 }
    if ($scenario -eq 'pidof-failed') {
        [Console]::Error.WriteLine('模拟 pidof 失败')
        exit 7
    }
    '2468'; exit 0
}
if ($tailText -eq 'shell settings get secure enabled_accessibility_services') {
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
