# Focus Auto Debug

`debug-focus.ps1` 是一个 Android Focus 应用的只读诊断工具。它以 `collect-only` 模式读取 ADB、设备、应用和有限时间窗口内的日志，写出本地摘要与附件；它不尝试修复设备或应用状态。

## 运行要求

- Windows。
- PowerShell 7（`pwsh`）。
- 已安装 Android Platform Tools，并能定位到 `adb.exe`。
- 已在目标设备上启用 USB 调试，并在设备端完成 USB 调试授权。

若连接了多台已授权设备，必须提供 `-Serial`。工具只会选择状态为 `device` 的目标。

## 用法

在仓库根目录运行。下面的命令同时展示所有可配置参数：

```powershell
$adb = 'D:\Program\Android\SDK\platform-tools\adb.exe'
$out = 'D:\focus-autodebug\debug-results\latest'

& $PSHOME\pwsh.exe -NoProfile -File .\debug-focus.ps1 `
    -AdbPath $adb `
    -Serial '<设备序列号>' `
    -PackageName 'com.example.focus_app' `
    -OutputRoot $out `
    -LogWindowMinutes 10
```

- `-AdbPath`：可选的 `adb.exe` 或测试用 fake ADB 路径；省略时会尝试在常见 SDK 位置查找。
- `-Serial`：目标设备序列号；仅有一台已授权设备时可以省略。
- `-PackageName`：要诊断的应用包名，默认 `com.example.focus_app`。
- `-OutputRoot`：本次报告目录，默认 `debug-results\latest`。
- `-LogWindowMinutes`：回读日志的分钟数，范围为 1 到 60，默认 10。

## 输出文件

`-OutputRoot` 下会写入 `summary.json`，以及按采集结果存在的附件：

| 文件 | 含义 |
| --- | --- |
| `summary.json` | schema、检查项、总体结果、脱敏后的设备提示和附件文件名。 |
| `device-info.txt` | 厂商、型号、Android 版本和 SDK 版本。 |
| `focus-state.txt` | 包名、安装、版本来源、进程和无障碍状态的业务值。 |
| `logcat-focus.txt` | 仅保留可归属到 Focus 的有限窗口日志；没有匹配日志时不会创建空文件。 |
| `crash-focus.txt` | 明确属于 Focus 的崩溃或 ANR 证据；只在检测到此类事件时写入。 |

## 退出码与检查状态

| 退出码 | 含义 |
| --- | --- |
| `0` | 正常完成，且未检测到明确属于 Focus 的崩溃。 |
| `10` | 必需前提失败，例如 ADB 不可用、设备未授权或目标应用未安装。 |
| `20` | 无法写入 `summary.json`。 |
| `30` | 摘要标记为采集或附件失败，或检测到明确属于 Focus 的崩溃。 |

日志读取属于可选检查：单独的日志读取失败会在摘要中把相应检查标为 `FAIL`，但不会覆盖已通过的必需前提退出码语义。

检查项的 `PASS`、`FAIL`、`SKIP` 表示诊断检查是否完成、失败或因上游前提未满足而跳过；它们不等同于业务字段本身的 `true`、`false`、`null`。例如 `app.process` 为 `PASS` 且 `processAlive=false` 表示已成功确认应用未运行；`null` 表示无法确认，不应被当作 `false`。

## 日志与隐私边界

- 日志调用只读取窗口内容，不清空设备 logcat；不会使用 `logcat -c`。
- 全量原始 logcat 不会落盘。其他应用的崩溃不会计入 Focus 崩溃，也不会写入 Focus 崩溃附件。
- 常见 token、API Key、Bearer 值和完整序列号会做基础脱敏，但这不是完整隐私保证。报告目录仍属于私密数据，分享前请人工检查全部附件。
- 工具明确不包含构建、安装、卸载、清数据、权限修改、UI 操作或网络上传。

## 离线验收

离线测试只使用仓库内的 fake ADB，不需要真机、网络、Gradle 或安装步骤。连续运行两次以确认第二次不依赖第一次的临时文件：

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
if ($LASTEXITCODE -ne 0) { exit 1 }
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
if ($LASTEXITCODE -ne 0) { exit 1 }
```
