# Focus Auto Debug 第二阶段设计草案：无 Root 安全自动化路线图

- 日期：2026-09-02
- 状态：用户已批准八项安全决策；按 A → B → C 分阶段编写实施计划
- 工具根目录：`D:\focus-autodebug`
- 前置规范：`docs/specs/2026-09-02-focus-autodebug-collect-only-design.md`
- 当前已实现：ADB 环境与设备选择、设备信息、Focus 安装/版本/进程/无障碍状态、结构化报告
- 当前未实现：日志、构建、安装、instrumentation、UI Automator、权限修复和完整验收流程

## 1. 结论

这套自动调试方案总体可行，而且**不需要 Root 手机**。推荐把它建设成一个无 Root、分模式、失败即停的测试系统，而不是一个拿到 ADB 后可以任意点击和修改系统的脚本。

按当前需求估计：

| 范围 | 可行性 | 主要限制 |
|---|---:|---|
| ADB、设备、应用、权限和系统状态检查 | 高，约 90% | 部分 ColorOS 状态没有稳定的公开 shell 接口 |
| JVM 测试、APK 构建、哈希和签名检查 | 高，约 90% | 需要明确 Focus 源码 checkout 和 Android SDK |
| 覆盖安装并保留数据 | 中，约 70% | 签名必须兼容；升级迁移仍可能修改数据；ColorOS 可能弹出安装确认 |
| 普通 App 与 Focus 的跨应用 UI 自动化 | 中高，约 70%～85% | 依赖可访问节点、稳定 testTag、已解锁屏幕和无意外系统弹窗 |
| ColorOS 权限页自动化 | 中，约 50%～70% | OEM 页面、文字和层级可能随系统版本变化 |
| 微信/小红书/抖音及双开应用检测 | 主包高，双开中低 | 同包名但不同 Android 用户/工作资料的副本不能承诺普遍可见 |
| Focus 私有数据库和配置检查 | 调试版高，正式版低 | Android 沙箱阻止普通 ADB 直接读取其他应用的内部私有文件 |
| 100% 无人值守的个人真机测试 | 不建议承诺 | 锁屏认证、安装增强保护、系统弹窗和隐私内容需要失败即停或人工确认 |

推荐目标不是“所有情况下都无人值守”，而是：

1. 可验证时自动执行。
2. 无法可靠验证时输出 `BLOCKED`，不猜测、不盲点。
3. 任何有状态操作都必须经过单独模式和前置门禁。
4. 私人手机上遇到锁屏、未知弹窗、签名不一致或数据指纹不可读时立即停止。

## 2. Root 决策

### 2.1 默认策略

本项目明确采用：

```text
RootRequired = false
RootSupported = false
BootloaderUnlockRequired = false
```

不建议为了自动测试而 Root 或解锁 bootloader。Root 会扩大脚本误操作范围；许多设备在解锁 bootloader 时还可能清除用户数据。当前需求没有哪一项必须依靠 Root 才能完成。

### 2.2 唯一明显受沙箱限制的项目

普通 ADB shell 不能直接读取 `/data/user/0/<package>` 下的 Focus 私有数据库、SharedPreferences 和内部文件。Android 官方也明确说明应用内部存储默认只允许应用自身访问。

无 Root 的替代方案按优先级排列：

1. **Focus debug 构建中的内部诊断接口**：在 `src/debug` 中提供只读 `DiagnosticSnapshot`，只返回计数、布尔状态、Schema 版本和哈希，不返回任务正文、API Key 或数据库原文。
2. **instrumentation 内部查询**：通过 AndroidTest 在目标应用测试上下文中读取 Room/配置的最小状态，并通过 instrumentation result 返回。
3. **`run-as <package>`**：仅在当前安装包为 `debuggable` 且设备允许时使用；只计算存在性、文件大小或哈希，不默认复制完整数据库。
4. 正式版不具备上述入口时，将 `focus.data_preserved` 记为 `BLOCKED`，而不是要求 Root 或伪造 PASS。

诊断接口不得是 release 构建中的可导出 Provider、Receiver 或网络端口，也不得让其他应用访问 Focus 私有数据。

## 3. 对 session 建议的可行性修订

### 3.1 可以直接保留的建议

- 测试前必须有环境门禁，任何必要条件失败都停止。
- 不使用固定坐标，优先资源 ID、Compose testTag、内容描述和受控文字。
- 不执行卸载、`pm clear`、恢复出厂设置或数据库删除。
- 不再把 `connectedDebugAndroidTest` 作为个人真机的默认执行路径。
- 构建主 APK 和 AndroidTest APK 后，手动安装，再用 `adb shell am instrument` 运行指定测试。
- 每次运行生成独立证据目录和结构化摘要。
- 日志、截图和 UI 层级采用最少采集原则。

### 3.2 必须改写或增加门禁的建议

#### `adb install -r` 不是数据库绝对安全保证

Android 官方将 `-r` 定义为重新安装并保留现有数据，但它只描述包管理器行为。新 APK 第一次启动时仍可能执行 Room migration、SharedPreferences 迁移或业务初始化，因此不能把 `install -r` 等同于“数据一定不变”。

安全安装前必须同时满足：

- 新旧包名一致。
- 新 APK 签名与已安装应用的当前签名或签名历史兼容。
- 新 `versionCode` 不低于已安装版本；第一版不支持自动降级，也不使用 `-d`。
- 安装前能读取 Focus 数据指纹，或用户显式接受无法验证数据指纹的风险。
- 手机已解锁且没有安装增强保护弹窗。
- 已保存已安装版本、数据指纹和权限状态。

安装后必须重新检查 `pm path`、版本、签名、`pm list instrumentation`、`dumpsys package` 和数据指纹。任一不一致立即停止，不继续 UI 测试。

#### 手动 `am instrument` 避开的是 Gradle 清理流程，不是所有测试风险

Android 官方支持先构建并安装主 APK/test APK，再使用：

```text
adb shell am instrument -w <testPackage>/<runner>
```

这种方式不会因为 `am instrument` 命令本身自动卸载应用，但测试代码仍可能主动调用 `clearAppData()`、删除数据库、修改权限或清理配置。因此还必须静态禁止和运行时拦截测试代码中的数据清理操作。

#### “手机已解锁”只能检测，不能绕过安全认证

脚本可以读取屏幕点亮、交互状态和 keyguard 状态，但不得保存或输入 PIN、图案或生物认证。锁屏未解除时结果应为 `BLOCKED`，提示用户手动解锁。

#### “当前不存在系统弹窗”不能只靠一次 UI dump 证明

建议组合判断：

- 当前前台 window/package。
- keyguard、权限控制器、系统安装器和已知 ColorOS 安装保护窗口。
- UI Automator watcher 只处理当前用例明确允许的弹窗。

任何未知系统窗口都停止测试。不得编写“看到确定按钮就点”的通用 watcher。

#### 通知横幅不适合作为唯一硬断言

横幅是否出现会受通知频道历史状态、免打扰、系统速率限制、当前前台状态和 OEM 行为影响。可靠硬断言应是：

- Focus 通知记录存在。
- 频道 ID、importance、ongoing、chronometer 和取消状态符合约定。
- 到期后 ReminderActivity 出现。

顶部横幅截图保留为条件性证据；环境不支持 heads-up 时不应单独导致核心用例失败。

#### 频道 ID 不应在自动化工具中永久硬编码为 v3

现有历史调试证据曾使用 `focus_follow_up_countdown_v2`，本次 session 建议写的是 `focus_follow_up_countdown_v3`。两者存在版本冲突。实现前必须从当前 Focus 源码、构建产物或 debug 诊断契约读取期望频道 ID；自动化仓库不得自行决定版本号。

#### 双开应用不能只按包名列表理解

首版支持：

- 当前用户下的微信、小红书、抖音主包。
- 当前用户下已知的不同包名 clone/manual alias。

同一个包名位于另一个 Android user、工作资料或 OEM 私有双开空间时，普通应用和普通 UI Automator 流程不一定可见。此类结果必须是 `UNKNOWN/BLOCKED`，不能声称“手机没有双开”。

## 4. 模式分层

统一入口仍是：

```powershell
.\debug-focus.ps1 -Mode <mode>
```

建议引入以下相互隔离的模式：

| 模式 | 是否改变手机状态 | 作用 |
|---|---:|---|
| `collect-only` | 否 | 当前已实现的设备和 Focus 只读采集；后续增加有界日志 |
| `preflight` | 否 | 完整测试环境门禁，不启动 App、不点击 UI |
| `build-only` | 否，只有电脑文件变化 | JVM 测试、APK 构建、哈希和新 APK 签名检查 |
| `install-safe` | 是 | 通过签名与数据门禁后执行一次受控覆盖安装 |
| `ui-test` | 是 | 安装和 preflight 全部通过后运行指定 instrumentation 用例 |
| `full` | 是 | 按顺序编排前述阶段；第一版不默认开放 |

默认模式始终是 `collect-only`。`install-safe`、`ui-test` 和 `full` 必须显式指定，并要求：

- 明确的 `-Serial`。
- 明确的 `-FocusSourceRoot`。
- 明确的 `-Test` 或测试 allowlist。
- 单独的 `-AllowInstall` 或 `-AllowUiActions` 开关。
- 将即将运行的状态修改命令写入摘要。

## 5. 总体状态机

```text
START
  ↓
collect-only
  ↓ PASS
preflight
  ├─ FAIL/BLOCKED → 写报告并停止
  ↓ PASS
build-only
  ├─ FAIL → 写构建证据并停止
  ↓ PASS
签名 + 版本 + 数据指纹门禁
  ├─ FAIL/BLOCKED → 禁止安装
  ↓ PASS
install-safe
  ├─ FAIL/BLOCKED → 保存安装日志并停止
  ↓ PASS
安装后来源 + 数据指纹复核
  ├─ FAIL → 禁止运行 UI 测试
  ↓ PASS
ui-test（只运行 allowlist 中的测试）
  ↓
证据脱敏 + summary.json
```

新增总体结果：

- `PASS`：所有必要门禁和已请求用例通过。
- `FAIL`：已执行检查或用例并获得明确失败。
- `BLOCKED`：无法安全继续，例如锁屏、签名未知、数据指纹不可读或未知系统弹窗。

业务值仍使用 `true/false/null`；未知不得伪装成 `false`。

## 6. Preflight 环境门禁

### 6.1 设备身份与交互状态

| 检查 ID | 检查内容 | 失败行为 |
|---|---|---|
| `device.single_target` | 只选中一个指定序列号且状态为 `device` | 停止 |
| `device.identity` | 厂商、型号、Android、SDK 与配置允许值匹配 | 停止或由显式兼容矩阵决定 |
| `device.screen_on` | 屏幕处于点亮/交互状态 | 停止 |
| `device.unlocked` | keyguard 未锁定 | `BLOCKED`，等待人工解锁 |
| `device.foreground_clean` | 当前前台不存在未知系统弹窗 | `BLOCKED` |

“型号符合预期”不应永久写死 RMX3350。配置应允许多个设备 profile；当前 profile 可要求 `manufacturer=realme`、`model=RMX3350`、`android=13`、`sdk=33`，以这次真机采集为准。

设备数量规则按模式区分：`collect-only` 可以在多个已授权设备中通过显式 `-Serial` 做只读采集；`install-safe`、`ui-test` 和 `full` 要求 ADB 列表中恰好只有一台状态为 `device` 的目标，而且它必须与 `-Serial` 完全一致。设备数量或状态在阶段间发生变化时立即停止，不能沿用旧选择继续操作。

### 6.2 Focus 安装、来源与数据

| 检查 ID | 检查内容 |
|---|---|
| `focus.installed` | `pm path` 能确认主包存在 |
| `focus.provenance` | 版本名、版本号、更新时间和安装路径可读 |
| `focus.installed_signature` | 已安装包签名证书摘要可验证 |
| `focus.data_snapshot` | 读取最小数据指纹；不得导出正文或密钥 |
| `focus.instrumentation` | 需要 UI 测试时，runner 已注册且目标包正确 |

最小数据指纹建议包括：

- 数据库 schema 版本。
- 任务数量。
- 应用组数量和组内包名数量。
- 引导完成状态。
- 强制提醒开关。
- 待处理提醒数量。
- API 配置是否存在，但不返回 API Key。
- 关键配置归一化后的 SHA-256。

### 6.3 权限和系统状态

| 检查 ID | 状态读取 | 首版行为 |
|---|---|---|
| `permission.notification` | 通知运行时权限/通知启用状态 | 只检测；缺失则停止需要通知的用例 |
| `permission.overlay` | 悬浮窗特殊访问状态 | 只检测；是否必需由 Focus 功能契约决定 |
| `permission.accessibility` | 启用服务列表中是否存在 Focus | 只检测 |
| `permission.usage_access` | Usage Access/AppOps | 只检测 |
| `permission.battery_optimization` | 是否忽略电池优化 | 只检测；OEM 后台保护另列 |
| `system.dnd` | 当前免打扰和通知策略访问状态 | 记录；通知用例按预期决定是否阻塞 |
| `system.auto_rotate` | 自动旋转开关和当前方向 | 记录；需要固定方向的用例先显式设置并恢复 |
| `system.network` | 网络连接类型和已验证网络 | 记录；不把“连上 Wi-Fi”当成 API 可达 |
| `system.coloros_background` | ColorOS 自启动/后台保护可验证部分 | 无稳定读取结果时为 `UNKNOWN`，不猜测 |

自动开启权限和 ColorOS 设置属于更后的独立阶段。首版 preflight 只检测并给出人工修复路径。

### 6.4 目标应用和双开

目标应用身份不能只保存一个包名，应建模为：

```text
TargetAppIdentity {
  logicalName
  packageName
  userId?       // 无法确定时为 null
  variant       // primary / known-alias / work-profile / unknown
}
```

微信、小红书、抖音的具体包名必须来自配置或当前 Focus 应用组，不能由脚本在生产代码中散落硬编码。检测到同包名跨用户但无法访问时，报告限制，不自动 Root 或切换用户。

## 7. 构建与安全安装事务

### 7.1 Build-only

按顺序执行：

1. 验证 `-FocusSourceRoot` 是预期 Git 仓库、分支和提交。
2. 记录 Git SHA 和工作树是否干净；不自动丢弃用户修改。
3. 执行指定的 JVM 测试。
4. 构建 Debug APK 和 AndroidTest APK，但不运行 connected test。
5. 记录两个 APK 的路径、SHA-256、包名、versionCode、versionName 和签名证书摘要。
6. 扫描 AndroidTest 源码和 runner 参数，拒绝清数据、卸载和非 allowlist shell 命令。

### 7.2 签名比较

新 APK 使用 Android SDK `apksigner verify --print-certs`。已安装包优先由 debug 诊断/instrumentation 通过 `PackageManager` 的 signing 信息返回证书 SHA-256；如设备允许拉取已安装 APK，也可在电脑端用同一 `apksigner` 验证。

签名比较必须考虑签名轮换历史，不能只比较一段未经定义的 `dumpsys` 文本。签名未知或不兼容时禁止安装。

### 7.3 Install-safe

主 APK 只允许：

```text
adb -s <serial> install -r <main.apk>
```

AndroidTest APK 在确认为 test-only 时可使用受控的 `-t`，但不使用 `-g` 自动授予所有运行时权限。第一版不支持：

- `uninstall`
- `pm clear`
- `install -d`
- 自动卸载旧 test APK
- 自动降级主 APK
- 自动恢复旧 APK

这里没有可靠的通用“自动回滚”：数据库迁移可能不可逆。安装后验证失败时，正确行为是停止并保存证据，而不是自动降级或清数据。

### 7.4 ColorOS 安装确认

ColorOS 可能在 ADB 返回后仍显示“安装增强保护”或电脑端未知来源确认。脚本必须在安装返回后重新读取：

- 目标包 `pm path`。
- versionCode/versionName/lastUpdateTime。
- 签名证书摘要。
- `pm list instrumentation`。
- 目标 runner 的 `dumpsys package` 信息。

只有这些结果全部一致，才把安装记为 PASS。

## 8. UI Automator 与 Focus 测试接口

Android 官方 UI Automator 可以与用户应用和系统应用交互，适合跨应用验收；现代 API 还提供谓词查找、等待、稳定性检查、截图和结果报告。但系统只暴露可访问节点，不能保证所有 OEM 页面或安全窗口都可操作。

### 8.1 定位优先级

1. Focus 稳定 Compose `testTag`，并在根节点启用 `testTagsAsResourceId`。
2. Android resource ID。
3. content description。
4. Focus 自己的稳定文字。
5. 系统/OEM 文字，只作为带系统 profile 的最后手段。
6. 固定坐标禁止进入常规流程。

Compose 官方互操作文档要求：只有在父级启用 `testTagsAsResourceId` 后，UI Automator 才能通过 `By.res(tag)` 访问 `Modifier.testTag`。

建议 Focus 首批稳定 tag：

```text
focus_root
bottom_nav_tasks
bottom_nav_settings
force_reminder_switch
app_group_add_button
api_settings_button
api_status
reset_prompt_button
reminder_root
reminder_intentional_use
reminder_take_break
reminder_back_to_task
reminder_duration_menu
save_settings_dialog
save_and_switch_button
continue_editing_button
```

### 8.2 Watcher 安全规则

- watcher 必须绑定明确包名、资源 ID 和当前测试步骤。
- watcher 只处理本用例预期的权限弹窗或 Focus 对话框。
- 未知弹窗只截图/记录窗口元数据并终止。
- 不实现通用“允许”“确定”“继续”点击器。
- 不自动输入 PIN、密码、验证码、API Key 或聊天内容。

### 8.3 测试执行方式

手动验证安装和 runner 注册后，使用指定 class/method：

```text
adb -s <serial> shell am instrument -w \
  -e class <fully.qualified.TestClass#method> \
  <testPackage>/androidx.test.runner.AndroidJUnitRunner
```

禁止默认运行整个 AndroidTest 包；只运行控制器 allowlist 中的测试，减少未知清理代码被执行的风险。

## 9. 完整验收用例的调整版

### 9.1 提醒全屏

可自动化：

1. 启动配置中的目标应用。
2. 等待 Focus reminder 根节点。
3. 读取前台 Activity/window/package。
4. 截取 Focus reminder 窗口。
5. 比较 `reminder_root` bounds 与可用窗口 bounds。
6. 确认 UI 层级中没有目标应用的可见节点。

限制：截图若受 `FLAG_SECURE` 或 OEM 合成层影响，应输出 `BLOCKED/UNAVAILABLE`，不能伪造失败原因。

### 9.2 菜单居中

可自动化，前提是按钮和菜单有稳定 tag：

1. 获取按钮 bounds 和菜单 bounds。
2. 计算两者中心点 X 的像素差。
3. 用设备 density 转换为 dp。
4. 默认允许误差 `<= 8dp`，阈值写入测试配置。
5. 分别测试“有目的使用”和“休息一下”。

测试报告同时保存像素差、dp 差、屏幕 density 和截图，避免只输出 PASS/FAIL。

### 9.3 倒计时通知

硬断言：

- 期望频道 ID 来自 Focus 测试契约。
- importance、ongoing、chronometer、sound/vibration 策略符合契约。
- 记录倒计时开始、期望到期和实际 reminder 出现时间。
- 到期后旧倒计时通知取消。

条件性证据：

- 顶部 heads-up 横幅截图。
- 下拉通知栏中的 Focus 通知元素截图。

快速回归使用 1 分钟；可靠性测试至少保留 5 分钟用例。允许时间误差必须在设计测试时明确，例如前台环境和 ColorOS 后台环境分别设阈值。

### 9.4 设置保存确认

可自动化，但必须先读取原值并在 `finally` 中恢复：

1. 修改一个明确标记为可恢复的设置。
2. 分别验证底部任务、顶部返回、系统返回和 `ACTION_OPEN_TASKS`。
3. 验证“继续修改”和“保存并切换”。
4. 恢复原设置。
5. 再次读取诊断快照确认恢复成功。

恢复失败必须使本次运行 FAIL，并把设备标记为“需要人工恢复”，不能继续其他用例。

### 9.5 强制提醒重新出现

UI 步骤本身可由 UI Automator 完成；“展示次数”和“旧待处理提醒已清除”必须通过 Focus debug 诊断接口验证，不能依靠直接读取私有数据库。

推荐断言：

- ReminderActivity 首帧确认后展示计数只增加一次。
- Home 后未选择操作，再进入同一目标应用会重新出现提醒。
- 重建 Activity、重复 wakeup 或仅通知送达不重复计数。
- 超过普通窗口额度后，强制提醒策略继续生效。
- 点击“回到任务”后待处理 reminder ID 清除。

## 10. 证据和隐私

每次测试生成：

```text
debug-results/
└─ runs/
   └─ <runId>/
      ├─ summary.json
      ├─ environment.json
      ├─ build.json
      ├─ install.json
      ├─ device-info.txt
      ├─ focus-state.txt
      ├─ instrumentation.txt
      ├─ logcat-focus.txt
      ├─ activity-focus.txt
      ├─ notification-focus.txt
      ├─ ui/
      └─ screenshots/
```

`latest` 只作为最近一次运行入口，不是唯一历史目录。

### 10.1 允许保存

- 时间、设备型号和系统版本。
- Focus 版本、Git SHA、APK SHA-256 和证书 SHA-256。
- Focus 包名、Activity、进程和服务状态。
- 测试用例结果、计时和几何坐标。
- 仅与 Focus 明确相关的日志窗口。
- Focus 自己的 UI 元素和截图。

### 10.2 默认禁止保存

- 完整设备序列号。
- 微信聊天、联系人、通知正文和其他应用 UI 文本。
- API Key、任务正文和用户输入内容。
- 全量 `dumpsys notification`。
- 全量无过滤 logcat。
- 通知栏的完整 UI dump。
- 其他应用的完整无障碍层级。
- Focus 原始数据库文件。

`dumpsys notification` 和 `dumpsys activity` 只在电脑端过滤 Focus 包名和结构字段，再写入附件；不得先保存全量原文。通知栏证据优先截取 Focus 通知元素，而不是整屏通知列表。

### 10.3 失败上下文

每个失败项至少包含：

```json
{
  "id": "reminder.trigger",
  "status": "FAIL",
  "message": "ReminderActivity 未在允许时间内出现",
  "context": {
    "targetLogicalApp": "xiaohongshu",
    "targetPackage": "<masked-or-allowlisted-package>",
    "focusProcessAlive": true,
    "accessibilityEnabled": true,
    "foregroundPackage": "<package-only>",
    "elapsedMs": 61234
  },
  "artifacts": [
    "screenshots/reminder-trigger-fail.png",
    "ui/reminder-trigger-fail.xml"
  ]
}
```

UI dump 写盘前必须做包名 allowlist 和文本字段脱敏。

## 11. 代码边界

当功能扩展到构建、安装和 UI 后，单个 `debug-focus.ps1` 已达到合理拆分条件。建议结构：

```text
focus-autodebug/
├─ debug-focus.ps1
├─ tools/
│  └─ auto-debug/
│     ├─ config.ps1
│     ├─ adb-utils.ps1
│     ├─ preflight-utils.ps1
│     ├─ build-utils.ps1
│     ├─ install-utils.ps1
│     ├─ test-utils.ps1
│     └─ result-utils.ps1
├─ tests/
│  ├─ debug-focus.Tests.ps1
│  └─ fixtures/fake-adb.ps1
└─ docs/specs/
```

Focus-App 源码仓库负责：

```text
app/src/androidTest/java/.../
├─ FocusAutoDebugTest.kt
├─ DeviceSetup.kt
├─ FocusSetup.kt
├─ PermissionHelper.kt
├─ SystemUiHelper.kt
├─ TestResultReporter.kt
└─ diagnostics/
   └─ DebugStateReporter.kt
```

PowerShell 负责环境、构建、安装、ADB 编排和电脑端报告；Kotlin instrumentation 负责设备内 UI、Focus 内部状态和步骤级证据。双方只通过 instrumentation stdout/result bundle 和本次运行目录交换数据。

## 12. 分阶段实施顺序

为衔接现有 collect-only 计划，推荐顺序如下：

1. **完成现有 Task 4：有界 Focus 日志与崩溃采集**
   - 只读。
   - 不清 logcat。
   - 先用 fake ADB 验证其他应用崩溃不会误报。
2. **扩展 preflight**
   - 屏幕、锁屏、前台窗口、通知、悬浮窗、Usage Access、电池优化、DND、旋转、网络和目标 App 状态。
   - 全部只读，失败即停。
3. **实现 build-only**
   - Source root、Git SHA、JVM 测试、两个 APK、哈希和签名。
   - 不连接或安装手机。
4. **实现 Focus debug 诊断快照**
   - 先解决数据是否保留、展示次数和配置恢复的可验证性。
5. **实现 install-safe dry-run**
   - 第一版只输出“允许/禁止安装”和理由，不执行安装。
6. **开放单次 install-safe**
   - 仅签名、版本、数据和 ColorOS 门禁全部通过时执行。
7. **建立一个 UI Automator 冒烟用例**
   - 只做“启动 Focus → 找到稳定 tag → 截取 Focus 元素 → 退出”。
8. **逐个加入验收用例**
   - 提醒全屏。
   - 菜单居中。
   - 倒计时通知。
   - 设置保存确认。
   - 强制提醒重显。
9. **最后增加 ColorOS 权限自动化和可靠性循环**
   - 与通用 Android 流程隔离。
   - 每个系统版本单独维护 profile。

不建议现在同时实现所有权限、所有 OEM 页面和全部验收用例。

## 13. 第一轮后续实施的建议范围

用户已批准按 A → B → C 顺序实施。每个方案仍使用独立计划、独立测试和独立审查门：

### 方案 A：先完成只读日志（推荐）

- 延续现有 Task 4。
- 风险最低。
- 能让后续 UI 失败有 Focus 日志和崩溃证据。

### 方案 B：先扩展完整 preflight

- 直接覆盖用户本次列出的测试环境检查。
- 仍保持只读。
- 工作量高于方案 A，但不会安装或点击手机。

### 方案 C：直接做 build-only

- 先接入 Focus 源码和 JVM/APK 构建。
- 暂不安装手机。
- 需要用户明确当前 Focus 源码 checkout。

推荐 A → B → C；完成三者后再设计 install-safe 的实现计划。

## 14. 已确认的用户决策

2026-09-02，用户确认以下八项全部同意：

1. 是否同意永久采用“无 Root、无 bootloader 解锁”的架构。
2. 是否同意安装前数据指纹不可读时默认 `BLOCKED`，不自动覆盖安装。
3. 是否同意第一版不支持降级、不自动回滚、不卸载旧测试包。
4. 是否同意锁屏和未知系统弹窗必须人工处理，脚本不尝试绕过。
5. 是否同意通知横幅只作为条件性证据，核心断言以通知记录和 ReminderActivity 为准。
6. 是否同意当前用户下已知不同包名双开优先；同包名跨 user/profile 先报告限制。
7. 是否同意从 Focus 当前源码/诊断契约读取通知频道 ID，不在自动化仓库硬编码 v2 或 v3。
8. 实施顺序选择 A → B → C；当前先执行方案 A“有界 Focus 日志与崩溃采集”。

## 15. 官方依据

- [Android UI Automator：跨用户应用和系统应用的 UI 测试](https://developer.android.com/training/testing/other-components/ui-automator)
- [Android 命令行测试与 `adb shell am instrument`](https://developer.android.com/studio/test/command-line)
- [ADB 安装参数，包括 `-r` 保留现有数据](https://developer.android.com/tools/adb)
- [apksigner 验证 APK 与输出签名证书](https://developer.android.com/tools/apksigner)
- [Compose `testTagsAsResourceId` 与 UI Automator 互操作](https://developer.android.com/develop/ui/compose/testing/interoperability)
- [Android 应用专属内部存储的访问边界](https://developer.android.com/training/data-storage/app-specific)
- [PackageManager signing certificate API](https://developer.android.com/reference/android/content/pm/PackageManager)
- [Doze、电池优化与豁免状态](https://developer.android.com/training/monitoring-device-state/doze-standby)
