# Wristload macOS TUI

`tui/` 是 Wristload 的独立、纯 Dart、仅面向 macOS 的终端应用。它不启动 Flutter engine，不依赖 Flutter GUI 的 widget、controller、presentation 或运行时。经典蓝牙由一个小型 JSON Lines 原生 helper 承担；安装状态机和 Xiaomi 协议实现位于 TUI 工作区自己的纯 Dart 层。

## 生产架构

```text
UiNextShell + UiConsoleTerminal
  -> UiNextPort
  -> TuiApplicationUiPortAdapter
  -> TuiApplication
  -> TuiBackendPort
  -> MacOsTuiBackendAdapter
  -> JsonLineMacBluetoothTransport
  -> macos_bridge/wearable_macos_bridge
  -> IOBluetooth: classic inquiry -> SDP -> RFCOMM
```

这条边界的职责是明确的：

- `ui_next/` 只处理 terminal 输入、鼠标、渲染、主题和稳定设备选择。render 不会启动扫描、连接、写入 authkey 或安装资源。
- `application/` 合并已保存设备与实时发现结果，以规范化经典蓝牙 MAC 作为唯一身份；它管理自动连接、连接代次、保存设备、Keychain authkey 和安装状态。
- `backend_next/` 是 TUI 自己拥有的 macOS backend 边界。它组合 TUI 内的纯 Dart 协议状态机和 JSONL helper，不调用 Flutter GUI controller 或生命周期。
- `macos_bridge/` 只负责 classic discovery、SDP、RFCOMM open/close 和原始字节；它不理解 authkey、安装协议或业务成功语义。

`--fixture` 也使用新界面：

```text
FakeUiNextPort -> UiNextShell -> UiConsoleTerminal
```

fixture 不会启动 helper、访问蓝牙、写 Keychain、持久化设备或安装资源。legacy `frontend/` 仍保留为历史参考，但不在生产入口或 fixture 入口上执行。

## UI 行为

默认主题为 `black-blue`，并可在运行时切换 `black-cyan`、`black-green`。所有颜色通过 `UiTheme` 集中定义。

设备的主行语义始终是：

```text
设备名称 -- MAC地址 -- 可否支持 -- authkey
```

authkey 已保存时显示完整值；未保存时显示 `-`。设备名称以 Unicode grapheme 和 terminal cell width 渲染，处理 CJK、emoji 与 ANSI/控制字符。宽终端使用单行多列，中等宽度自动换行，窄终端使用堆叠信息；选中后按 `Enter` 可进入可滚动详情页查看完整名称。

键盘与鼠标共用同一条规范化 MAC 选择状态：方向键或 `j`/`k` 选择、`Enter` 详情、滚轮滚动、鼠标点击选择或操作。终端 resize 会重新计算布局和 hitbox。退出时恢复 raw mode、鼠标捕获、备用屏幕和 cursor。

常用操作：

```text
r 扫描/停止扫描     c 连接     x 断开
s 保存/取消保存     a 输入 authkey     i 安装资源
z 取消安装          t 自动连接开关       m 切换主题
q 或 Ctrl-C 退出
```

安装和 Bluetooth I/O 均在渲染循环之外执行。取消安装可以越过正在等待的安装 action；底层 RFCOMM 写入仍由 transport FIFO 串行化。只有设备业务完成事件才能标记安装成功，RFCOMM `write.done` 或 Mass ACK 不是安装成功。

## 保存和自动连接

- 保存记录使用经典蓝牙 MAC、显示名称、支持 profile 和最后成功连接时间。扫描刷新与保存记录按 MAC 合并，保存名称/profile 优先保护。
- authkey 每台设备独立存在 macOS Keychain service `com.anemo.wristload.tui.authkey` 中；JSON 保存文件不含密钥。
- 仅当对应连接真正进入 `ready` 后，用户提交的 authkey 才会持久化。取消保存会删除记录和该 MAC 的 Keychain key。
- 启动自动连接会按最近 `lastConnectedAt` 的已保存设备直接以 MAC 连接，不先扫描。没有 authkey 时进入 `awaitingAuthKey`，不会伪装为 ready。
- 用户主动断开后，本进程会抑制自动重连。连接 generation 防止旧回调覆盖新连接状态。

## 地址和 transport 规则

经典蓝牙地址只能来自 `IOBluetoothDevice.addressString` 或用户明确输入的 classic 地址，不能从 CoreBluetooth UUID 或 BLE 广播 ID 推导。输入支持：

```text
AA-BB-CC-DD-EE-FF
AA:BB:CC:DD:EE:FF
AABBCCDDEEFF
```

内部 identity 是无分隔大写 12 hex；对用户与 helper 展示为 `AA-BB-CC-DD-EE-FF`。

helper 在连接时使用 SDP 查找服务记录并动态取得 RFCOMM channel，绝不硬编码 channel。Xiaomi Mi Fitness APK 的已有反编译结果显示其 SPP client 使用标准 UUID `00001101-0000-1000-8000-00805F9B34FB`；TUI 使用这个 UUID 是基于该行为证据，而不是复制 APK 代码。`connect.done` 才表示 native RFCOMM channel 已打开；之后才允许后端发送 L1START。

SPP 8-bit sequence 只在一个物理 RFCOMM generation 内有效。TUI 对每个物理连接一次性分配 sequence，耗尽时 fail-closed 并要求重建 RFCOMM，避免迟到 ACK 误匹配。

## 构建和运行

要求：macOS、Xcode Command Line Tools、CMake 和 Dart SDK。bridge 不需要 Flutter。

```sh
cd tui/macos_bridge
cmake -S . -B build
cmake --build build

cd ..
dart pub get
dart run bin/wristload_tui.dart
```

```sh
# 只验证 helper 启动、JSONL handshake 和已配对设备读取。
dart run bin/wristload_tui.dart --probe

# 新 UI 的纯内存预览。
dart run bin/wristload_tui.dart --fixture ready
dart run bin/wristload_tui.dart --fixture queueRunningTransfer
```

可用 `--helper <path>` 覆盖 helper 路径，`--help` 列出完整 fixture 名称。

## 已验证与当前真实设备边界

本次重构已实际验证：

- `dart analyze` 无问题，完整 `dart test` 通过。
- `cmake -S macos_bridge -B macos_bridge/build && cmake --build macos_bridge/build` 成功。
- `dart run bin/wristload_tui.dart --probe` 成功：Dart -> JSONL helper 的启动、`hello` handshake 与已配对设备读取可用。
- 新 UI 覆盖了 60/80/120 列响应式布局、Unicode/CJK/emoji cell width、控制字符净化、详情滚动、键盘/鼠标统一选择、滚轮、resize、主题、取消安装、fixture 和 terminal cleanup。

已在此 Mac 上对已配对的 Xiaomi Smart Band 10（`04-34-C3-3F-9D-63`）做过一次受控 native 实验：helper 接受 `connect`，使用标准 SPP UUID `1101` 发起 SDP；35 秒内没有收到 `sdpQueryComplete` 导致的 `connect.done`、`error` 或任何 raw RX。随后发送本地 `disconnect`，helper 正确返回 `closed(local)` 与 `disconnect.done`。

因此当前首个未通过的真实层是：

```text
IOBluetooth performSDPQuery accepted
  -> SDP terminal callback / service resolution: UNKNOWN / no callback observed
  -> RFCOMM open: not reached
  -> raw TX: not reached
  -> raw RX: not reached
```

这不是 authkey、L1START、安装协议或资源传输失败的证据。TUI transport 会在 RFCOMM 建链等待 30 秒后报告超时、尝试受控 native cleanup，并拒绝在不确定会话上继续写入。没有明确 `connect.done`、原始 TX 和原始 RX 前，Band 9、9 Pro、10、10 Pro 的 macOS 端到端兼容性均保持 `UNKNOWN`。

## macOS 权限

首次使用可能需要在“系统设置 -> 隐私与安全性 -> 蓝牙”允许实际启动 TUI/helper 的进程。配对是系统级状态，不等同于 authkey 鉴权，也不证明 RFCOMM/SDP 可用。发布为签名 app 或 helper 时，需要重新核验 bundle identity、Info.plist、entitlements、Sandbox 和 TCC；不能仅以开发终端的授权状态推断发布产物可用。
