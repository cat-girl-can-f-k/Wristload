# 上游复制来源与同步策略

本目录的初始上游基线是根仓库 commit `bb4d306`：

```text
bb4d306 fix: resume failed installs and render transfer progress
```

复制不表示与根 Flutter GUI 共用运行时。TUI 是独立纯 Dart 工程，根 GUI 保持原样；这里保留的是安装所必需、且不依赖 Flutter 展示层或 Windows BLE 平台实现的代码。

## 已复制的具体文件

从 `bb4d306` 复制到 `tui/lib/src/domain/`：

```text
lib/domain/device_profile.dart
lib/domain/install_checkpoint_store.dart
lib/domain/install_metadata_reader.dart
lib/domain/install_models.dart
lib/domain/install_task.dart
lib/domain/mass_ack_idle_timeout.dart
lib/domain/queue_file_importer.dart
lib/domain/transfer_settings_store.dart
lib/domain/verification_gate.dart
lib/domain/protocol/auth_handshake.dart
lib/domain/protocol/mass_transfer.dart
lib/domain/protocol/proto_wire.dart
lib/domain/protocol/session_cipher.dart
lib/domain/protocol/spp_protocol.dart
lib/domain/protocol/transport_constants.dart
lib/domain/protocol/zau.dart
```

这些文件覆盖：设备代际保护、authkey 鉴权、L1/L2 帧、AES-CCM/CTR、protobuf wire 编解码、Mass 文件分片、安装任务模型、文件元数据/ZIP 安全边界、恢复检查点、传输参数和发送门控。

## 明确不复制的根仓库文件

- `lib/main.dart` 与 `lib/presentation/**`：Flutter Material GUI，TUI 不使用。
- `lib/application/device_controller.dart`：包含 Flutter `ChangeNotifier`、BLE discovery 类型与 Windows/Android 分支；TUI 应重建一个不依赖 Flutter 的应用编排层，但必须保留同等的协议和失败语义。
- `lib/platform/ble_transport.dart`：Windows/Android BLE 与 Pigeon/MethodChannel 边界，不能用于 macOS classic RFCOMM。
- `plugins/bluetooth_low_energy_windows/**`、`windows/**`、`android/**`：都不属于 macOS TUI。
- `auth_key_store.dart`、`system_time_info.dart`：尚未复制。当前 TUI 的 authkey 只在进程内存中保存，退出或显式清除后不可恢复；尚未实现 macOS Keychain。任何后续持久化都必须使用 Keychain，不能把 authkey 明文写入 JSON、日志、检查点或终端回显。

## TUI 专有来源

以下文件不是从 `bb4d306` 复制，而是本 TUI 的 macOS 专有传输层：

```text
tui/macos_bridge/CMakeLists.txt
tui/macos_bridge/main.mm
tui/macos_bridge/README.md
```

`main.mm` 只链接公开的 `Foundation.framework` 和 `IOBluetooth.framework`，通过 JSON Lines 子进程接口提供经典设备发现、SDP 服务查询和 RFCOMM 字节流。它不包含安装协议或来自任何 APK 的实现。

## 同步原则

1. 同步前先记录根仓库 commit，并比较每个候选文件的 diff；不要按目录整体覆盖。
2. 只同步领域/协议层的功能修复和对应测试。涉及 Flutter UI、Windows/Android transport 的改动一律不能直接带入。
3. 对每个同步提交，在本文件追加根 commit、文件清单、冲突处理和 TUI 验证结果。
4. 当根仓库改变协议帧、加密、Mass、恢复或 `VerificationGate` 时，TUI 必须原子同步相关文件，复跑协议测试，并进行 macOS 真机验证；不能只挑一个常量或猜测性改写。
5. macOS bridge、Dart JSONL facade、TUI controller 和前端属于 TUI 所有。根 GUI 后续变更不得覆盖它们。
6. 根仓库与 TUI 的行为发生冲突时，以更保守的安全语义为准：未认证、未验证、断链、超时、畸形回包和不匹配业务结果都不宣称成功。

## 下一次同步记录

尚未进行 `bb4d306` 之后的同步。后续记录格式：

```text
日期：YYYY-MM-DD
上游 commit：<hash> <subject>
同步文件：<paths>
处理：<冲突/适配说明>
验证：dart test ...；macOS bridge build；真机状态
```
