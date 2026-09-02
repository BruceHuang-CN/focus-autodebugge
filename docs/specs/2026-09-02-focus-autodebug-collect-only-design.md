# Focus Auto Debug 第一阶段设计规范：只读采集

- 日期：2026-09-02
- 状态：已确认，进入实施计划编写
- 工具根目录：`D:\focus-autodebug`
- 目标应用包名：`com.example.focus_app`
- 当前阶段：阶段 1～2 的最小安全子集

## 1. 背景与目标

本工具用于在 Windows 电脑上通过 USB 和 ADB 收集 Focus 应用及 Android 设备的调试证据，并把结果整理成一个机器可读的 `summary.json` 和少量文本附件。

第一版的目标不是自动修复、自动授权或自动点击，而是建立一个稳定、可重复、可审计的诊断入口。Codex 或开发者先读取摘要，只有某项失败时再查看相关附件，从而避免每次分析整份设备日志。

第一版完成后，应能回答以下问题：

1. ADB 是否可用。
2. 当前是否存在且只存在一个可安全选择的已授权设备。
3. 设备厂商、型号、Android 版本和 SDK 版本是什么。
4. Focus 是否已安装，安装版本和最近更新时间是什么。
5. Focus 进程当前是否存活。
6. Focus 的无障碍服务是否处于系统已启用列表中。
7. Focus 相关的有限日志中是否出现崩溃或明显异常。

## 2. 安全原则

第一版采用“只读采集”模式，默认不得改变应用数据、权限、系统设置或手机 UI 状态。

允许的操作：

- 查询 ADB 版本和设备列表。
- 读取 `getprop`、`dumpsys package`、`pidof`、无障碍启用状态等系统信息。
- 读取当前已有的 logcat 缓冲区，并在电脑端过滤 Focus 相关内容。
- 在电脑本地创建本次调试报告。

禁止的操作：

- 不编译、不安装、不卸载 APK。
- 不执行 `pm clear`、`pm grant`、`appops set`。
- 不修改系统设置，不自动开启无障碍、通知、悬浮窗或后台权限。
- 不清空 logcat，不执行 `adb logcat -c`。
- 不发送点击、滑动、按键或 Activity 启动命令。
- 不自动操作 ColorOS 设置页。
- 不默认截图或导出 UI 层级。
- 不读取或输出 API Key、任务正文等用户内容。
- 不把报告上传到网络。

这些边界必须在脚本帮助信息和摘要中明确标注。以后新增有状态操作时，应使用单独的显式模式和二次确认，不得悄悄扩大默认行为。

## 3. 范围与非目标

### 3.1 第一版范围

- 一个统一 PowerShell 入口。
- ADB 动态发现与环境检查。
- 安全的设备选择规则。
- 设备、应用、进程、无障碍状态采集。
- Focus 相关的有限 logcat 与崩溃线索采集。
- 无论成功还是失败，尽量生成有效的 `summary.json`。
- 使用假 ADB 输出进行离线测试。

### 3.2 第一版不做

- Gradle 构建、APK 安装与 instrumentation 测试。
- Compose UI 自动化和 UiAutomator。
- 权限自动开启。
- ColorOS 后台保护自动配置。
- Focus 内部应用组、强制提醒、API 和重置文案配置。
- 打开受监控应用并验证提醒出现。
- Codex 自动修改生产代码并循环重测。
- 多设备并行采集。

## 4. 独立目录与文件结构

第一版采用最少文件结构，暂不提前拆分多个 PowerShell 模块：

```text
D:\focus-autodebug\
├─ debug-focus.ps1
├─ tests\
│  ├─ debug-focus.Tests.ps1
│  └─ fixtures\
├─ docs\
│  └─ specs\
│     └─ 2026-09-02-focus-autodebug-collect-only-design.md
├─ debug-results\
│  └─ latest\
│     ├─ summary.json
│     ├─ device-info.txt
│     ├─ focus-state.txt
│     ├─ logcat-focus.txt
│     └─ crash-focus.txt
└─ .gitignore
```

暂时将少量私有辅助函数放在 `debug-focus.ps1` 内。当脚本出现清晰的第二个调用方，或单文件确实难以测试和维护时，再拆成 `adb-utils.ps1`、`log-utils.ps1` 和 `result-utils.ps1`。

该工具与 Focus-App 源码仓库相互独立。第一版不需要源码路径，也不修改 Focus-App 仓库。后续需要构建时，再通过显式参数传入项目路径。

## 5. 统一入口接口

预期使用方式：

```powershell
.\debug-focus.ps1
```

第一版参数：

```powershell
param(
    [string]$AdbPath,
    [string]$Serial,
    [string]$PackageName = "com.example.focus_app",
    [string]$OutputRoot = "$PSScriptRoot\debug-results\latest",
    [ValidateRange(1, 60)]
    [int]$LogWindowMinutes = 10
)
```

参数规则：

- `AdbPath`：可选。未提供时先查找 PATH 中的 `adb`，再查找已知 Android SDK 环境变量和常见 SDK 位置。报告中记录最终使用的绝对路径。
- `Serial`：可选。只有一个已授权设备时可省略；存在多个已授权设备时必须显式指定。
- `PackageName`：默认 Focus 正式调试目标包名，但允许未来测试其他构建变体。
- `OutputRoot`：默认覆盖 `latest` 目录中的同名报告；后续可增加按 runId 归档，但第一版不提前实现。
- `LogWindowMinutes`：限制日志时间窗口，默认只分析最近 10 分钟。

正常完成返回退出码 `0`。环境、授权或采集检查失败返回非零退出码，但仍应尽力写出有效摘要。

## 6. ADB 发现与设备选择

### 6.1 ADB 发现顺序

1. 使用显式 `-AdbPath`。
2. 使用 PATH 中可执行的 `adb`。
3. 检查 `ANDROID_SDK_ROOT` 或 `ANDROID_HOME` 下的 `platform-tools\adb.exe`。
4. 检查 Windows 常见用户 SDK 目录。
5. 若仍找不到，记录 `environment.adb = FAIL` 并停止设备采集。

发现文件后必须实际执行 `adb version` 验证，不能仅凭文件存在判定可用。

### 6.2 设备状态解析

使用 `adb devices -l`，将设备区分为：

- `device`：已授权且可读取。
- `unauthorized`：已连接但手机尚未授权。
- `offline`：ADB 可见但不可用。
- 其他状态：保留原始状态并按不可用处理。

### 6.3 安全选择规则

- 没有已授权设备：失败，下游设备和应用检查记为 `SKIP`。
- 恰好一个已授权设备：自动选择。
- 多个已授权设备且未提供 `-Serial`：失败，不随机选择。
- 提供 `-Serial`：只使用完全匹配且状态为 `device` 的目标。
- 所有后续设备命令都必须带 `-s <serial>`，避免设备列表变化后误操作其他设备。

完整设备序列号不写入 `summary.json`。如需关联一次运行，只记录掩码形式，例如末四位。

## 7. 数据采集流程

```text
初始化输出目录和运行上下文
    ↓
验证 ADB
    ↓
读取并安全选择已授权设备
    ↓
采集设备基础信息
    ↓
检查 Focus 安装与版本来源
    ↓
检查 Focus 进程和无障碍启用状态
    ↓
读取有限时间窗口的日志并在电脑端过滤
    ↓
写入附件和 summary.json
    ↓
根据检查结果返回退出码
```

每一步只依赖前一步必要的输出。设备未授权时，不尝试运行任何针对该设备的 shell 命令；应用未安装时，进程和应用服务检查记为 `SKIP`，而不是伪造为 `FAIL` 或 `false`。

## 8. 检查项与状态语义

所有检查统一使用三种状态：

- `PASS`：检查已执行，并获得明确符合预期的结果。
- `FAIL`：检查已执行，获得明确失败结果，或该项是继续运行的必要前提但不可用。
- `SKIP`：因为上游前提不成立而未执行，不能推断真实状态。

初始检查项：

| ID | 含义 | 必要性 |
|---|---|---|
| `environment.adb` | ADB 可执行且版本查询成功 | 必需 |
| `device.authorized` | 已安全选中一个授权设备 | 必需 |
| `device.info` | 厂商、型号、Android 和 SDK 信息可读取 | 必需 |
| `app.installed` | 目标包已安装 | 必需 |
| `app.provenance` | 版本名、版本号和更新时间可读取 | 诊断项 |
| `app.process` | 进程状态已成功读取 | 诊断项 |
| `permission.accessibility` | 系统启用列表中能明确判断 Focus 服务状态 | 诊断项 |
| `logs.focus` | Focus 相关日志读取和过滤成功 | 诊断项 |
| `logs.crash` | 崩溃线索扫描完成 | 诊断项 |

`app.process` 的检查状态与业务值分开：命令成功但进程未运行时，检查可以是 `PASS`，同时 `processAlive = false`。这表示“成功确认应用当前未运行”，不是采集失败。

`permission.accessibility` 同理：成功读取系统状态时检查为 `PASS`，业务字段 `enabled` 可以为 `true` 或 `false`；无法可靠读取时才为 `FAIL` 或 `SKIP`。

## 9. summary.json 设计

示例：

```json
{
  "schemaVersion": 1,
  "runId": "20260902-163000",
  "mode": "collect-only",
  "overall": "FAIL",
  "startedAt": "2026-09-02T16:30:00+08:00",
  "completedAt": "2026-09-02T16:30:03+08:00",
  "device": {
    "authorized": false,
    "serialHint": "SGK7",
    "manufacturer": null,
    "model": null,
    "android": null,
    "sdk": null
  },
  "app": {
    "packageName": "com.example.focus_app",
    "installed": null,
    "versionName": null,
    "versionCode": null,
    "lastUpdateTime": null,
    "processAlive": null,
    "accessibilityEnabled": null
  },
  "checks": [
    {
      "id": "environment.adb",
      "status": "PASS",
      "message": null
    },
    {
      "id": "device.authorized",
      "status": "FAIL",
      "message": "设备已连接，但尚未在手机上授权 USB 调试"
    },
    {
      "id": "app.installed",
      "status": "SKIP",
      "message": "未选择已授权设备"
    }
  ],
  "artifacts": {
    "deviceInfo": null,
    "focusState": null,
    "focusLogcat": null,
    "crashLog": null
  }
}
```

`overall` 计算规则：

- 任一必需检查为 `FAIL`，则为 `FAIL`。
- 必需检查全部通过且未发现明确崩溃线索，则为 `PASS`。
- 第一版不引入 `WARN`，避免状态语义过早复杂化；非致命诊断缺失通过具体检查项表达。

JSON 写入要求：

- UTF-8 编码。
- 即使中途异常，也通过统一的 `finally` 路径尽力生成结构有效的摘要。
- 未知值使用 `null`，不得用 `false` 代替未知。
- 附件路径使用相对于 `OutputRoot` 的路径。
- 错误消息面向用户，原始命令错误放入相关文本附件或内部诊断字段，避免摘要过长。

## 10. 日志采集与隐私

日志策略：

1. 不清空手机日志缓冲区。
2. 读取最近 `LogWindowMinutes` 分钟的日志。
3. 优先根据 Focus 当前 PID 过滤；没有 PID 时根据包名、进程名和 Android 崩溃标记做有限匹配。
4. 在电脑端执行过滤，不改变手机日志状态。
5. `logcat-focus.txt` 保存 Focus 相关上下文。
6. `crash-focus.txt` 保存与 Focus 明确相关的 FATAL EXCEPTION、ANR 或 tombstone 线索。

第一版不能承诺 logcat 完全不包含业务文本，因此报告目录默认视为私密本地数据，并加入 `.gitignore`。脚本结束时提示用户在分享前人工检查附件。

默认不采集截图和 UI dump，因为它们更容易包含通知、联系人、任务内容和其他应用信息。只有未来用户显式选择某个失败步骤时才考虑加入。

## 11. 异常与失败处理

- 每个外部命令都记录退出码、标准输出和标准错误，不能仅通过是否有文本判断成功。
- 单个非必要采集项失败不应阻止其他安全项目继续采集。
- ADB 缺失、设备未授权或设备选择不明确时立即停止设备侧采集。
- 写报告失败时返回不同的非零退出码，并在控制台明确输出目标路径和错误原因。
- 终止时不杀死 ADB server，不重启设备，不停止 Focus 进程。
- 控制台只显示简短结论和摘要路径，详细证据写入附件。

## 12. 测试驱动策略

正式实现前，先使用假 ADB 可执行文件或可注入的命令执行器编写以下失败测试：

1. **ADB 缺失**
   - 返回非零退出码。
   - 仍生成合法 JSON。
   - `environment.adb = FAIL`。
   - 下游检查为 `SKIP`。

2. **设备未授权**
   - 能识别 `unauthorized`。
   - `device.authorized = FAIL`。
   - 不调用任何 `adb -s <serial> shell ...` 命令。
   - 不伪造设备或应用元数据。

3. **多个已授权设备但未指定序列号**
   - 返回非零退出码。
   - 不随机选择设备。
   - 错误消息要求使用 `-Serial`。

4. **单个已授权设备且 Focus 已安装**
   - 所有设备命令都带显式序列号。
   - 生成合法摘要和预期附件。
   - 正确解析厂商、型号、Android、SDK、版本名、版本号和更新时间。

5. **Focus 未安装**
   - `app.installed = FAIL`。
   - 依赖安装状态的检查为 `SKIP`。
   - 不把“未安装”误报为“进程未运行”。

6. **Focus 已安装但未运行**
   - `app.process = PASS`。
   - `processAlive = false`。

7. **日志包含其他应用的崩溃**
   - 不写入 Focus 崩溃附件。
   - 不把其他应用崩溃计入 Focus 总体结果。

测试工具优先使用 PowerShell 自包含断言或与 PowerShell 7 兼容的方式，不依赖机器上较旧的 Pester 版本。测试不得连接真实手机。

## 13. 第一版验收标准

只有同时满足以下条件，才可称为第一版完成：

- 离线测试覆盖上述关键分支并全部通过。
- 缺少 ADB 时能生成有效失败摘要。
- 未授权设备场景能生成有效失败摘要，且没有设备侧 shell 调用。
- 多设备场景不会误选设备。
- 手机授权后，能识别真实设备基础信息。
- 能读取 Focus 的安装版本和更新时间。
- 能区分“应用未运行”和“状态无法读取”。
- 报告只保存在 `D:\focus-autodebug\debug-results`。
- 默认流程没有构建、安装、清数据、改权限、改系统设置、点击或清空日志行为。
- 真机验证结果与离线测试结果分别报告，不把脚本测试等同于手机功能验证。

## 14. 当前已知前提

此前电脑上的 ADB 已能发现一台 USB 设备，但当时设备状态为 `unauthorized`。用户现已重新解锁手机；是否已经在手机弹窗中允许这台电脑进行 USB 调试，留到首次真机只读验证时通过 `adb devices -l` 确认。文档和离线测试阶段不据此声称真实设备采集已经通过。

## 15. 后续扩展边界

第一版稳定后，再按以下顺序逐步扩展，每个阶段都应有独立设计、测试和显式授权边界：

1. 归档多个 runId 和更细的日志关联。
2. 可选截图与 UI dump，仅在明确失败步骤并由用户启用。
3. Gradle 构建与 APK 安装，和只读模式完全分离。
4. Focus 内部 Compose/UiAutomator 测试。
5. 权限检测与人工引导。
6. 显式授权后的权限自动化和 ColorOS 专用设置。
7. 应用组、API 与提醒触发验证。
8. Codex 根据摘要定位代码、修改和重测的闭环。

任何扩展都不得通过删除测试、放宽断言、硬编码 PASS 或跳过功能来制造通过结果。

## 16. 审阅决策

进入实现计划前，需要用户确认以下设计决策：

1. 第一版保持严格只读，不自动启动 Focus。
2. 多设备时要求显式 `-Serial`，不自动猜测。
3. 默认日志窗口为最近 10 分钟。
4. 默认不采集截图和 UI dump。
5. 第一版采用单入口脚本，达到明确拆分条件后再模块化。
