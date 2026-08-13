# WearableInstall macOS TUI

这是 Wristload 的独立、纯 Dart、仅面向 macOS 的终端界面（TUI）工作区。它不复用 Flutter GUI，也不启动隐藏 Flutter engine；安装协议、文件校验和恢复语义由 Dart 后端保留，经典蓝牙由一个小型原生 JSON Lines 子进程桥接。

当前目录包含独立的 TUI 前端、生产 facade、安装状态机和 macOS 原生蓝牙 helper。根目录 Flutter GUI 不受影响，也不是此 TUI 的运行依赖。前端仍可通过 fixture 预览模式脱离真实设备开发；生产模式则只通过 `TuiFacade` 访问后端。

## 范围

- 平台：只支持 macOS。Windows、Linux 和 Android 都不在此 TUI 的兼容范围内。
- 蓝牙：只使用 macOS `IOBluetooth.framework` 的经典蓝牙 / SDP / RFCOMM，不把它当作 BLE GATT 客户端。
- 支持的安装链路：只允许当前已验证的 Vela V2 协议进入安装状态机。旧 Vela、Huami/Zepp 和协议未知设备保持只读或拒绝安装。
- 安全边界：authkey 鉴权、`VerificationGate`、文件类型和元数据校验、MD5/SHA-256 源文件一致性检查、Mass ACK、业务完成事件、检查点恢复和“设备状态未知”语义必须完整保留。

不允许为了简化 TUI 而直接向 RFCOMM 写私有帧，也不允许以“写入完成”或“Mass ACK 完成”冒充设备安装成功。

## 架构

```text
TUI 前端（键盘、布局、展示）
  -> TuiFacade（唯一可调用业务 API）
  -> Dart 应用/安装状态机
  -> JSONL Bluetooth facade（长驻子进程）
  -> tui/macos_bridge/wearable_macos_bridge
  -> IOBluetooth: classic inquiry -> SDP -> RFCOMM
```

TUI 前端只能订阅 `TuiFacade` 的状态流并调用其公开动作。它不能 import 协议编码、`VerificationGate`、检查点存储、`Process`、bridge 的 stdin/stdout，不能把文件字节、authkey 或私有帧直接写给 bridge。bridge 只负责发现、SDP 服务解析、RFCOMM 字节收发；它不理解安装协议。

### 地址规则

经典蓝牙地址必须来自 `IOBluetoothDevice.addressString` 或用户明确输入的经典蓝牙地址。绝不从 CoreBluetooth 的 UUID、BLE 广播 ID，或 UUID 末尾 6 字节伪造 MAC。

输入接受下列三种等价形式：

- `AA-BB-CC-DD-EE-FF`
- `AA:BB:CC:DD:EE:FF`
- `AABBCCDDEEFF`

输入层必须先删除分隔符并严格验证为 12 个十六进制字符；内部用无分隔大写 12 hex 作为比较键，向用户与 macOS bridge 展示时统一为 `AA-BB-CC-DD-EE-FF`。不要把横杠改成 Windows 风格的冒号展示。

### JSON Lines bridge

bridge 的源码在 [`macos_bridge/main.mm`](macos_bridge/main.mm)，协议说明在 [`macos_bridge/README.md`](macos_bridge/README.md)。正常运行时必须保持同一个子进程存活；关闭 stdin 等于主动退出 bridge。若旧 SDP 终端回调长期不返回，bridge 会返回 `sdp_drain_required` 并阻止同一设备重连；当前 Dart transport 不会自动重启 helper，此时只能在没有活跃连接时重启 helper/TUI。

命令为一行一个 JSON 对象；每个命令都必须带非空 `requestId`：

```json
{"command":"scan.start","requestId":"r-1","scanId":"scan-1","duration":10}
{"command":"connect","requestId":"r-2","connectionId":"conn-1","address":"AA-BB-CC-DD-EE-FF","serviceUuid":"1101"}
{"command":"write","requestId":"r-3","connectionId":"conn-1","base64":"AQID"}
{"command":"disconnect","requestId":"r-4","connectionId":"conn-1"}
```

事件也为一行一个 JSON 对象：`device`、`connect.done`、`data`、`closed`、`error`。连接时 bridge 会先做 SDP 查询，从请求的服务记录取得实际 RFCOMM channel 后再打开连接；不要硬编码 SPP 的 channel number。默认服务 UUID 是 SPP `00001101-0000-1000-8000-00805F9B34FB`（bridge 接受短写 `1101`）。

bridge 目前以 `writeSync` 按 RFCOMM MTU 分片写入。Dart facade 仍须维护单写 FIFO、连接代次和断线传播：旧连接晚到的 `data` 或 `closed` 不能污染重连后的会话。

### SPP ACK 与序号代际

SPP ACK 帧只携带 8 位 `sequence`，不携带连接代际、`connectionId` 或 session epoch。本地 `_sessionEpoch` 只能隔离 Dart Future，不能消除同一物理 RFCOMM 字节流中序号回绕后的迟到 ACK 歧义。因此当前实现对每个物理 RFCOMM 连接采用一次性序号空间：序号一旦发送，无论 ACK 成功、超时、取消、写失败或可选 ACK 退役，都永久从该连接代际中退役；quarantine 只用于诊断，不能恢复复用。

单个物理连接最多发送 256 个需要 SPP 序号的出站数据帧。Mass 窗口会在写入前原子预留完整序号集合；空间不足时不发送半个窗口，而是 fail-closed、断开链路并返回稳定错误码 `rfcomm_rebuild_required`，提示重建 RFCOMM 后重试。只有 transport 完成新 `connect.done`、确认新的物理 channel 建立后，backend 才创建新的序号空间。

## 构建和运行

先准备 macOS 的 Xcode Command Line Tools、CMake、Flutter/Dart SDK。bridge 不需要 Flutter。

```sh
cd tui/macos_bridge
cmake -S . -B build
cmake --build build

cd ..
dart pub get
dart run bin/wristload_tui.dart
```

默认生产入口使用 `macos_bridge/build/wearable_macos_bridge`。可用 `--helper <绝对或相对路径>` 指定其他构建产物，用 `--probe` 只启动 helper 并刷新已配对设备，不启动 TUI，也不连接、鉴权或安装。界面开发可用 `--fixture <name>` 启动纯 fake 预览；该模式不会连接蓝牙或安装文件。

当前实现已具备可审查的生产 facade、安装状态机和 TUI 工作台，但尚未完成 macOS 真机端到端验收。当前已确认 `git diff --check -- tui` 和 native bridge 构建；Dart VM 在本机启动阶段崩溃，因此不能把 format、analyze 或 test 宣称为通过。请先在可用 Dart SDK 下完成验证，再连接真实设备。

```sh
dart run bin/wristload_tui.dart --help
dart run bin/wristload_tui.dart --probe
dart run bin/wristload_tui.dart --fixture queueWaiting
```

## macOS 权限和发布

- 首次蓝牙访问可能由 macOS 弹出授权提示；用户需要在“系统设置 -> 隐私与安全性 -> 蓝牙”允许应用或终端。
- 真机连接前，设备必须可发现或已在 macOS 中配对，并且其 SDP 服务实际暴露 RFCOMM。配对是系统级操作，不等同于本项目的 authkey 鉴权。
- 若把 TUI 包成带签名的 app / helper，应在目标 macOS 版本上验证 Sandbox、Bluetooth entitlement 与 `Info.plist` 的蓝牙使用说明；发布配置必须以 Apple 当前签名/公证要求为准。先在非沙盒开发环境验证经典 RFCOMM，再引入沙盒。
- 不申请或模拟 Windows 权限，也不为跨平台兼容把地址格式降级成 Windows 规则。

## 当前真机限制

根仓库已在 n67cn（小米手环 9 Pro）上验证 Windows RFCOMM -> L1START -> f=26/f=27 -> Mass 表盘传输；这证明 Dart 协议层的互操作结论，不等于 macOS bridge 已完成同设备端到端验收。TUI 的 `kProtocolVerified=true` 仅表示其后端允许进入已验证的协议状态机，绝不构成 macOS 真机安装成功声明。

macOS 版本仍必须逐台实测：经典发现、已配对地址、SDP 服务 UUID、动态 RFCOMM channel、配对后的链路加密、L1START、authkey 鉴权、断链恢复、表盘安装和 RPK 安装。文件达到 100%、RFCOMM `write` 完成或 Mass ACK 完成，都只代表传输状态；只有设备业务完成事件才可显示安装成功。未验收的型号或任何模糊终态必须显示为失败/设备状态未知，不能显示成功。

## 同步根仓库代码

复制来源、commit 和同步原则见 [`UPSTREAM_SOURCES.md`](UPSTREAM_SOURCES.md)。同步时只带入可复用的领域/协议代码并保留其测试；不要从根 GUI 复制 `presentation/`，不要把 Windows BLE transport 移植进 TUI。
