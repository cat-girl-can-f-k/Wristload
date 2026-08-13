# TUI 前端实现说明

本文档说明 WearableInstall TUI 前端的依赖选择、目录结构、快捷键、运行方式、fixture 用法和已知限制。

## 依赖选择

| 包 | 版本 | 用途 | 许可证 |
|---|---|---|---|
| `console` | `^4.1.0` | ANSI 控制、光标移动、清屏、alternate screen、终端 resize 事件 | MIT |
| `wcwidth` | `^0.0.4` | Unicode 字符 cell 宽度计算 | BSD-2-Clause |
| `archive` | `^3.6.1` | 后端 ZIP 解析（前端不直接使用） | Apache-2.0 |
| `crypto` | `^3.0.3` | 后端哈希（前端不直接使用） | BSD-3-Clause |
| `pointycastle` | `^3.9.1` | 后端加密（前端不直接使用） | MPL-2.0 / MIT |
| `test` | `^1.25.0` | 单元与交互测试 | BSD-3-Clause |

选择 `console` 的原因：它提供跨平台 ANSI 转义和 stdin/stdout 包装，支持 raw mode、alternate buffer、光标控制和 resize 事件，且本仓库已在其依赖解析中。`wcwidth` 用于处理中文、全角标点和组合字符的终端 cell 宽度，避免用 `String.length` 做对齐。

前端没有引入 Flutter、Material、desktop_drop、BLE 库或任何 GUI 框架。

## 目录结构

```text
tui/lib/src/frontend/
  app/           # 应用循环、终端生命周期、路由
    tui_app.dart
  port/          # facade 适配接口；生产 facade 与前端之间的唯一隔离层
    tui_frontend_port.dart
    tui_action_result.dart
    tui_snapshot.dart
    fake_tui_frontend_port.dart
  state/         # 只含前端局部状态（当前视图、焦点、选中项、弹层）
    app_state.dart
  terminal/      # cell width、终端抽象、真实/伪终端实现
    terminal.dart
    console_terminal.dart
    fake_terminal.dart
    cell_width.dart
  input/         # 键位映射、焦点、粘贴安全解码和命令分发
    key_event.dart
    key_decoder.dart
    mapper.dart
    command.dart
    dispatcher.dart
  views/         # 设备、队列、任务/恢复、设置、日志、帮助
    devices_view.dart
    queue_view.dart
    task_view.dart
    settings_view.dart
    logs_view.dart
    help_view.dart
  widgets/       # 表格、进度条、状态条、确认框、输入框、框架
    frame.dart
    table.dart
    progress.dart
    status_bar.dart
    shortcuts_bar.dart
    dialog.dart
    input.dart
  fixtures/      # fake snapshot 场景，仅开发和测试使用
    tui_fixtures.dart
```

所有视图组件只接收不可变的 view model，不直接调用后端。用户意图先变成前端 `Command`，再由 `ActionDispatcher` 统一调 facade，并处理 busy、防重复和结果提示。

## 运行方式

```sh
cd tui

# 生产模式（macOS 真机）
dart run bin/wristload_tui.dart

# 仅启动 helper 并检查握手（可在管道/非交互环境运行）
dart run bin/wristload_tui.dart --probe

# 指定 helper 路径
dart run bin/wristload_tui.dart --helper /path/to/wearable_macos_bridge

# fixture 预览（明确标注 FAKE PREVIEW）
dart run bin/wristload_tui.dart --fixture base
dart run bin/wristload_tui.dart --fixture queueWaiting
dart run bin/wristload_tui.dart --fixture pendingDecisions
```

生产模式和 fixture 模式都需要交互式终端。在管道或非 TTY 环境中启动会输出中文错误并退出，不会修改终端状态。`--probe` 可以在非交互环境中运行。

## 快捷键

| 键 | 全局/上下文 | 动作 |
|---|---|---|
| `Tab` / `Shift+Tab` | 全局 | 切换焦点区 |
| `1`-`5` | 全局 | 切换主视图（设备/队列/任务/设置/日志） |
| `←` / `→` | 全局 | 切换主视图 |
| `j` / `k` 或 `↑` / `↓` | 列表 | 移动选择 |
| `g` / `G` | 列表 | 顶部/底部 |
| `Enter` | 详情/确认 | 打开详情或确认非危险动作 |
| `r` | 设备页 | 刷新已配对设备 / 开始扫描 |
| `c` | 设备页 | 连接；已连接时打开断开确认 |
| `a` | 设备页/连接 | 打开 authkey 输入 |
| `i` | 队列页 | 添加安装文件路径 |
| `s` | 队列页 | 打开开始队列确认 |
| `x` | 任务页 | 打开取消任务确认 |
| `R` | 队列页 | 重试当前失败条目 |
| `d` | 队列页 | 删除当前非活动队列项并确认 |
| `l` | 日志页 | 日志跟随开关 |
| `?` / `F1` | 全局 | 打开上下文帮助 |
| `Esc` | 全局 | 关闭弹层、取消输入或返回 |
| `q` | 全局（非文本输入状态） | 退出；活跃操作时二次确认 |
| `Ctrl+C` | 全局 | 安全退出并恢复终端 |

文本输入框获得焦点时，字母键输入文本，不会触发全局快捷键。粘贴通过 bracketed paste 或原始字节批量处理，不会被逐字符解释为快捷键。

## Fixture 列表

`--fixture <name>` 可用的预览场景：

- `base`：初始状态，helper 就绪，无设备，队列为空。
- `scanFinished`：扫描结束，显示已配对和 inquiry 合并后的设备列表。
- `queueWaiting`：队列含多条等待条目，含 faceId/versionCode 待确认。
- `awaitingAuthKey`：设备已连接，等待 authkey 输入。
- `rfcommRebuildRequired`：SPP 序号空间耗尽，必须建立新的物理 RFCOMM 连接。
- `ready`：已鉴权，准备安装。
- `queueRunningTransfer`：正在传输文件。
- `awaitingDevice100`：文件 100% 已确认发送，等待设备业务结果（不显示成功）。
- `installSucceeded`：设备业务事件确认安装成功。
- `installFailed`：设备明确拒绝或本地校验失败。
- `installStateUnknown`：断链/超时/结果无法验证，保留状态未知。
- `recoveryAvailable`：有可恢复的检查点。
- `pendingDecisions`：表盘分辨率、Lua、faceId、versionCode 等确认项。
- `logs`：日志页，含多级别日志。

## 布局断点

- `< 60×20`：只显示“终端尺寸不足”、当前关键状态和退出/帮助。
- `60-115` 列：单栏，只渲染当前主视图；日志页可独立访问。
- `≥116` 列：左侧业务工作区 + 右侧常驻 `LIVE LOG / EVENTS` 诊断栏；右栏按日志级别、类别和跟随尾部状态渲染。

高度不足时，顶部状态条和底部快捷键保持固定，列表与日志滚动；宽屏诊断栏的日志视口约为 `rows - 9`，窄屏日志页约为 `rows - 11`。

## 安全与状态语义

- authkey 输入默认掩码，支持 `v` 切换显示/隐藏；离开弹层、提交或取消后清空输入 controller。
- 不将 authkey 写入状态、日志、fixture、测试或剪贴板。测试中的 `submitAuthKey` 只记录长度。
- 安装成功只在前端看到 `TuiTaskStage.succeeded` 且 `successVerifiedByDeviceBusinessEvent` 为 `true` 时显示。
- `awaitingDevice` 即使 `confirmedBytes == totalBytes` 也显示“等待设备安装结果”，不使用完成颜色。
- `stateUnknown` 独立显示，不降级为 failed 或 succeeded。
- 所有危险确认框默认选中“取消”；Enter 仅在焦点位于确认按钮时执行。

## 已知限制

1. **macOS 专用**：TUI 在非 macOS 平台启动时，`TuiFacade.initialize()` 会返回 `unsupported_platform`，界面显示“仅支持 macOS”。
2. **需要交互式终端**：管道、文件重定向或非 TTY 环境无法启动 TUI；`--probe` 可用于此类环境做 helper 自检。
3. **生产 facade 契约缺口**：生产 `TuiFacade` 已存在并被 TUI 使用，但仍有 `reconnecting` 状态、busy 粒度和恢复门控原因等契约缺口，详见 `FACADE_GAP.md`。当前前端视图按完整目标契约实现，缺口收敛后无需绕过 facade 修改 UI。
4. **未做真机验证**：UI 测试主要使用 fake port 和 fixture；transport 合同测试使用可控的 `/usr/bin/python3` JSONL helper。macOS 经典蓝牙、SDP、RFCOMM、authkey、表盘/RPK 安装均需真机逐项验收。
5. **未实现从 ZIP 提取 authkey**：该工具属于根 GUI，不在 TUI 范围内。
6. **未实现时间同步、设备健康、通知、截图**：这些非安装核心工具不在当前 TUI 范围内。

## 当前验证状态

已完成的静态验证：

- `git diff --check -- tui`：通过。
- `cmake --build tui/macos_bridge/build --parallel 2`：通过，生成 `wearable_macos_bridge`。

Dart 的 `format`、`analyze` 和 `test` 已尝试运行，但当前机器上的 Dart 3.12.2 `macos_x64` VM 在启动阶段于 `runtime/vm/cpuinfo_macos.cc:42` 崩溃（`unreachable code`）。因此本次不能声称格式化、静态分析或测试通过，也不能确认测试数量。此前其他模型过程中的“57 tests passed”属于历史声明，当前环境未能独立复验。

测试代码已补充宽屏 `120` 列常驻日志栏、`60/80` 列单栏降级、ANSI 开关、日志筛选和首次 authkey 弹窗回归；需在可用 Dart SDK 下执行后再确认结果。macOS 经典蓝牙、SDP/RFCOMM、authkey、断链恢复及表盘/RPK 真机安装仍未验收。
