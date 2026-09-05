# Focus Auto Debug 新会话交接（2026-09-05）

把本文完整复制到新的 Codex 会话即可继续工作。本文以当前 Git 仓库为准；`2026-09-03-bounded-logs-task1-paused-handoff.md` 仅保留为历史记录，其中“Task 2～4 尚未开始”等状态已经过时。

## 新会话任务说明

请继续开发 Focus 真机自动调试工具。

### 仓库

- 本地仓库：`D:\focus-autodebug`
- GitHub：`https://github.com/BruceHuang-CN/focus-autodebugge.git`
- 当前分支：`codex/collect-only-small-tests`
- 本交接文档创建前的代码基线：`f4a43813bef5a87fa29f033285bd32495b1dc0c2`
- 不要直接修改 `main`，不要重新创建仓库或切换到其他 Focus-App checkout。
- 开始前执行：

```powershell
Set-Location D:\focus-autodebug
git status --short
git branch -vv --no-abbrev
git remote -v
git log -5 --oneline
```

如果工作树不干净，先识别并保留现有修改，不要覆盖、重置或删除。

### 当前已经完成

当前工具是单文件 PowerShell `collect-only` 诊断入口：

```powershell
.\debug-focus.ps1
```

已经实现：

1. 查找或接受显式 `adb` 路径并验证 ADB 可执行。
2. 解析授权设备；多设备时要求显式 `-Serial`；报告不保存完整设备序列号。
3. 采集手机厂商、型号、Android 版本和 SDK。
4. 检查 Focus 是否安装，并读取版本名、版本号、更新时间和安装来源。
5. 检查 Focus 进程和无障碍服务状态，保留 `true/false/null` 语义。
6. 使用 `logcat -d -T <时间> -v threadtime` 有界、只读地读取日志，不执行 `logcat -c`。
7. 只把已确认属于 Focus PID 的日志写入 `logcat-focus.txt`；其他应用日志和崩溃不得进入 Focus 附件。
8. 识别 Focus 的 `FATAL EXCEPTION`、ANR、`Process:` PID 来源和 tombstone PID 来源，并按需生成 `crash-focus.txt`。
9. 对常见 API Key、token、Bearer 值和完整序列号做基础脱敏。
10. 生成 `summary.json`、`device-info.txt`、`focus-state.txt` 以及按需存在的日志附件。
11. 固化退出码和 `PASS/FAIL/SKIP` 语义，处理报告或附件写入失败。
12. fake ADB 离线测试已覆盖设备、应用、日志、隐私、失败语义和危险命令白名单。
13. 新增快速小护栏入口：

```powershell
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1 -OnlySmallGuardrails
```

该入口覆盖：健康摘要恰好九项检查、无日志时物理附件不存在、可选 logcat 失败摘要不变量、崩溃附件写入冲突，以及 `Process:`/tombstone 两种 PID 来源。

### 当前验证边界

- 2026-09-05 推送前重新运行小护栏定向测试：`PASS small-guardrails`，耗时 50.6 秒。
- 约 50 秒的耗时主要来自六个模拟场景反复启动 PowerShell 和 fake ADB 子进程，不代表真实单次 `collect-only` 采集会用这么久。
- 增加最后四个小护栏后，完整离线套件尚未重新运行；不要声称完整套件当前已通过。
- 尚未进行首次真机 `collect-only` 验证。
- 尚未执行 Gradle、构建 APK、安装 APK、instrumentation 或 UI Automator。
- 不需要 Root，也不要建议 Root。

### 必须保持的安全边界

1. 默认模式始终是只读 `collect-only`。
2. 未经本次会话用户明确授权，不安装 APK、不点击手机 UI、不修改权限或系统设置。
3. 不运行 `connectedDebugAndroidTest`。该路径过去在 realme/ColorOS 真机上发生过清理应用数据的问题。
4. 禁止 `adb uninstall`、`pm clear`、自动降级、自动恢复旧 APK、恢复出厂设置或删除 Focus 数据库。
5. 后续安装主 APK 只能在安全门禁通过后显式使用 `adb install -r`。
6. AndroidTest 采用手动安装 APK 后按 allowlist 运行指定 `am instrument` class/method，不默认运行整个测试包。
7. 不记录微信聊天、联系人、通知正文、API Key 或其他应用的完整无障碍文本。
8. 未知 OEM 状态、跨用户/双开可见性或安全窗口应报告 `UNKNOWN/BLOCKED`，不能猜测为 `false`。
9. Android Studio 可以用于人工 Run/Debug；自动化构建应调用 Focus-App 自带的 Gradle Wrapper。两者共享 Gradle daemon 与缓存，不要通过 UI 自动点击 Android Studio。

## 剩余开发内容和顺序

### 阶段 B：扩展只读 preflight（下一项，尚未实现）

先把工作限制为一个小批次：

1. 检查指定设备是否唯一、仍为 `device`，阶段间身份发生变化立即停止。
2. 检查屏幕是否点亮、keyguard 是否解锁。
3. 读取当前前台 package/activity/window，遇到未知系统弹窗时停止并报告。
4. 把结果加入 `summary.json`，先用 fake ADB 写定向测试。

随后再分别加入通知、悬浮窗、Usage Access、电池优化、DND、自动旋转、网络和目标 App/双开包存在性检查。首版只检测，不自动开启权限。

### 阶段 C：build-only（尚未实现）

1. 通过显式 `-FocusSourceRoot` 接收 Focus-App 源码路径。
2. 确认目录、Git 仓库、分支、SHA 和工作树状态，不丢弃用户修改。
3. 调用仓库内 `gradlew.bat` 执行指定 JVM 测试和增量构建。
4. 构建 Debug APK 与 AndroidTest APK，但不运行 connected test。
5. 记录 APK 路径、SHA-256、包名、版本和签名证书摘要。
6. Android Studio 可继续由用户人工使用；脚本不控制 Android Studio UI。

### 阶段 D：Focus debug 诊断快照（尚未实现）

需要在 Focus-App 中增加受控的测试/诊断接口，返回最小状态：数据库 schema、任务和应用组数量、关键开关、待处理提醒数量、API 是否配置以及归一化配置哈希。不得返回正文或密钥。

### 阶段 E：install-safe（尚未实现）

1. 先实现 dry-run，只报告允许/禁止安装及理由。
2. 比较新旧 APK 签名、版本和最小数据指纹。
3. 得到用户明确授权后才开放单次 `adb install -r`。
4. 安装后重新校验 `pm path`、版本、签名、instrumentation 和 ColorOS 确认状态。

### 阶段 F：UI Automator 冒烟测试（尚未实现）

先只做：启动 Focus → 用稳定 testTag 找到一个 Focus 元素 → 截图 → 退出。Focus Compose 根节点需要启用 `testTagsAsResourceId`。禁止固定坐标和通用“允许/确定”点击器。

### 阶段 G：逐项完整验收（尚未实现）

按顺序加入：

1. 提醒全屏。
2. “有目的使用”和“休息一下”菜单居中。
3. 1 分钟快速倒计时通知和至少一次 5 分钟可靠性用例。
4. 设置保存确认，并在 `finally` 中恢复原值。
5. 强制提醒重新出现、计数和待处理提醒清除。
6. 最后才增加 ColorOS 权限操作、OEM profile 和长时间可靠性循环。

## 下一会话建议的唯一首要任务

只实现“阶段 B 的第一小批次”：唯一目标设备、屏幕点亮、设备解锁和前台窗口/未知弹窗门禁。不要同时开始构建、安装或 UI Automator。

开始编码前先阅读：

- `README.md`
- `docs/specs/2026-09-02-focus-autodebug-collect-only-design.md`
- `docs/specs/2026-09-02-focus-autodebug-safe-automation-roadmap-design.md`
- `debug-focus.ps1`
- `tests/debug-focus.Tests.ps1`
- `tests/fixtures/fake-adb.ps1`

先写一个短设计并让我确认；确认后按 TDD 增加 fake ADB 失败场景和最小生产实现。完成小批次后只运行相关定向测试和 PowerShell 语法检查；完整离线测试等这一部分稳定后再运行。不得通过删除测试、放宽断言、跳过功能或 hardcode PASS 让测试通过。

## 常用命令

快速小护栏：

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1 -OnlySmallGuardrails
```

完整离线测试（用户明确同意后再运行）：

```powershell
Set-Location D:\focus-autodebug
& $PSHOME\pwsh.exe -NoProfile -File .\tests\debug-focus.Tests.ps1
```

当前只读真机入口（用户明确同意且手机已连接、解锁、授权 USB 调试后）：

```powershell
Set-Location D:\focus-autodebug
$adbPath = 'D:\Program\Android\SDK\platform-tools\adb.exe'
$outputPath = 'D:\focus-autodebug\debug-results\latest'

& $PSHOME\pwsh.exe -NoProfile -File .\debug-focus.ps1 `
    -AdbPath $adbPath `
    -Serial '<设备序列号>' `
    -PackageName 'com.example.focus_app' `
    -OutputRoot $outputPath `
    -LogWindowMinutes 10
```

运行后首先只读 `summary.json`；只有失败时才按附件指针读取相关日志。分享任何报告前必须人工检查隐私内容。
