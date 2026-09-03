# Focus Auto Debug 有界日志 Task 1 暂停与完成交接

## 恢复后的最终状态

- 当前状态：`TASK 1 COMPLETE / REVIEWED / OFFLINE ONLY`
- 完成日期：2026-09-03（Asia/Shanghai）
- 实现提交：`fc435d715c26a80eca72acf9dfab5b0aaa9e7e0b`（`feat: collect bounded focus logs`）
- 修复提交：`7069eba9fdbcb9c5052122e7c18b80f75869bf6a`（`fix: harden bounded focus log guards`）
- 主代理 fresh verification：完整 fake-ADB 离线套件 `21/21 PASS`、退出码 `0`；`git diff --check` 退出码 `0`。
- 独立复审：初审发现 3 个 Important 和 1 个 Minor；fix round 1 后定向复审 `Approved`，全部 finding 已关闭。
- 本任务没有 push，没有使用真实 ADB 或真机，没有执行 Gradle、APK 构建/安装、instrumentation、权限修改或 UI 操作。

Task 1 最终实现以下能力：

1. 只读调用精确的 `adb -s <serial> logcat -d -T <timestamp> -v threadtime`，不清空日志、不全量落盘。
2. 从 `pidof` 与严格 `Process: <PackageName>, PID: <digits>` 行建立 Focus PID 集合。
3. 仅把已知 Focus PID 的 threadtime 行写入 `logcat-focus.txt`；其他 PID 即使提及完整、前缀或后缀包名也不会进入附件。
4. `ProcessIds` 只在进程内使用，不写入 `summary.json` 或 `focus-state.txt`。
5. fake ADB 按原始 argv 严格验证参数顺序、大小写和数量，拒绝 `-c`、`--clear`、乱序、重复、尾置和未定义开关。
6. 最终退出码保持：required 检查失败为 `10`，附件采集失败或 `focusCrashDetected` 为 `30`，否则为 `0`。
7. Task 1 仍按设计返回 `CrashLines=@()`、`FocusCrashDetected=false`；崩溃归属属于尚未开始的 Task 2。

后续状态：Task 2、Task 3、Task 4、整分支复审和只读真机采集全部保持延期，只有用户再次明确要求后才开始。以下“暂停时状态”保留为恢复审计记录，不再代表当前完成度。

## 暂停时状态（历史记录）

- 状态：`PAUSED / PARTIAL / NOT VERIFIED`
- 暂停时间：2026-09-03（Asia/Shanghai）
- 仓库：`D:\focus-autodebug`
- 分支：`codex/collect-only-small-tests`
- 当前 HEAD：`f1edeaaf45b32cefada2f1d535a8d38f953af2c5`
- 实现代理：`/root/bounded_logs_task1_impl`，已被主代理中断。
- 本次未提交、未推送、未连接真机、未运行真实 ADB、未执行 Gradle/APK/安装/instrumentation/UI 操作。

用户要求本次只推进 Task 1，随后又要求暂停。因此 Task 1 尚未完成验收；Task 2～4、整分支复审和真机采集均未启动。

## 暂停前已确认的基线

在 Task 1 修改开始前，主代理运行：

```powershell
& $PSHOME\pwsh.exe -NoProfile -File D:\focus-autodebug\tests\debug-focus.Tests.ps1
```

结果为既有离线套件 `20/20 PASS`、退出码 `0`；当时工作树没有跟踪文件改动，`git diff --check` 退出码为 `0`。

这只能证明基线健康，不能证明当前未提交改动通过测试。

## 当前未提交改动

中断时工作树包含：

| 文件 | 暂存状态 | 当前差异摘要 |
|---|---|---|
| `debug-focus.ps1` | 未暂存 | 新增 119 行 |
| `tests/debug-focus.Tests.ps1` | 未暂存 | 新增 31 行 |
| `tests/fixtures/fake-adb.ps1` | 未暂存 | 新增 37 行、删除 1 行 |

总计约 186 行新增、1 行删除。中断时的未提交 diff 指纹为：

```text
80b7dd289caef9e6f72dd666569996202bfe190e
```

该指纹在新增本交接文档前由 `git diff --binary | git hash-object --stdin` 得到，当时工作树只有上述三个代码/测试文件。恢复时应只对这三个文件计算：

```powershell
git diff --binary -- debug-focus.ps1 tests/debug-focus.Tests.ps1 tests/fixtures/fake-adb.ps1 | git hash-object --stdin
```

它只用于确认暂停期间的实现差异是否变化。

不要执行 `git reset --hard`、`git checkout --`、`git restore` 或清理工作树；这些改动属于尚未验收的在途工作。

## 已出现但尚未验收的实现

当前差异中已经出现以下内容：

1. `Get-AppSnapshot` 增加仅供进程内使用的 `ProcessIds`，从 `pidof` 数字输出建立 PID 列表。
2. 新增 `ConvertFrom-ThreadtimeLine`，解析 threadtime 格式的 PID、TID、优先级、tag 和 message。
3. 新增 `Protect-FocusLogLine`，尝试遮蔽 Authorization、Bearer、API key 和 token。
4. 新增 `Get-FocusLogSnapshot`，调用精确形状的只读命令：

   ```text
   adb -s <serial> logcat -d -T <timestamp> -v threadtime
   ```

5. 初步按当前 Focus PID 或包名筛选日志，形成 `FocusLines`；Task 1 暂时固定 `CrashLines=@()`、`FocusCrashDetected=false`。
6. 编排层初步写入 `logcat-focus.txt`，并更新 `logs.focus`、`logs.crash` 和 artifact。
7. fake ADB 初步加入精确 logcat 参数识别与健康日志输出；测试初步加入命令白名单、PID 不落盘、其他应用标记不泄露和 Focus 附件断言。

这些只是对当前差异的只读盘点，不代表代码正确或 Task 1 已完成。

## 未完成与必须复核的事项

1. 实现代理尚未生成 `task-1-report.md`，没有留下可审计的 TDD RED/GREEN 证据。
2. 当前未提交改动尚未由主代理运行聚焦测试、完整离线套件或独立验证。
3. 当前没有 Task 1 本地提交，也没有 review package 和独立复审结论。
4. fake ADB 为处理 PowerShell 参数绑定增加了 `d`/`v` 别名和参数重建逻辑；这段实现非直观，恢复后必须确认它没有放宽严格白名单，也不会改变其他命令参数。
5. 必须确认原始 logcat 始终只在内存中，附件中没有其他应用行、完整设备序列号、PID 状态字段或上下文窗口。
6. 必须确认无匹配 Focus 行时不创建空附件，并保持 Task 1 约定的检查状态与退出码。
7. Task 2 的崩溃归属尚未实现；当前空 `CrashLines` 和 `FocusCrashDetected=false` 仅是 Task 1 接口占位。
8. Task 3 的完整失败语义、脱敏场景和附件写入失败闭合尚未执行；不要把当前初步脱敏函数误记为 Task 3 已完成。

## 当时计划的恢复步骤（已执行）

以下步骤已在 2026-09-03 执行完毕：

1. 先读取本文件、批准计划和 SDD 台账：

   - `docs/superpowers/plans/2026-09-02-focus-autodebug-bounded-logs.md`
   - `.superpowers/sdd/2026-09-02-focus-autodebug-bounded-logs/progress.md`
   - `.superpowers/sdd/2026-09-02-focus-autodebug-bounded-logs/task-1-brief.md`

2. 只读确认分支、HEAD、工作树三文件和 diff 指纹；如与本文件不一致，先报告差异，不覆盖用户改动。
3. 优先恢复 `/root/bounded_logs_task1_impl`；若无法恢复，再分派新的 Luna Max 实现代理。代理必须先阅读 Task 1 简报和当前差异，再继续 TDD。
4. 实现代理补齐 RED/GREEN 证据、运行一次完整 fake-ADB 离线套件、执行 `git diff --check`、自审、写 `task-1-report.md`，然后创建本地提交；禁止 push。
5. 主代理独立检查提交和测试证据，生成从 Task 1 BASE 到 HEAD 的 review package。
6. 分派新的 Luna Max 复审代理，只评审 Task 1 的规格符合性与代码质量；重要问题回到原实现代理修复并定向复审。
7. Task 1 复审通过后更新本文件和台账，然后停止。不得顺带开始 Task 2、Task 3、Task 4、整分支复审或真机采集。

## 后续任务的真机与安全边界

Task 1 已仅使用 fake ADB 完成。以下事项仍必须等用户另行明确启动后才能进行：

- 真实 ADB 或真机日志采集；
- Task 2～4；
- Gradle、APK 构建、安装、instrumentation；
- 权限修改、系统设置、UI Automator 或坐标点击；
- 卸载、`pm clear`、数据库删除；
- Git push。

尤其不得运行 `connectedDebugAndroidTest`；既有 ColorOS 设备曾因该清理路径发生应用卸载和本地数据丢失。
