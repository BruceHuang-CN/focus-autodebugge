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
