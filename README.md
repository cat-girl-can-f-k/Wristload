# Wristload

此目录是全新实现的 Flutter Material 3 应用，不包含、也不引用任何反编译 APK 的代码、资源、布局或服务端接口。

## 当前能力

- Windows 和 macOS 扫描目标设备后建立 RFCOMM、完成 L1START 与 authkey 会话；
- 导入 `.bin` 表盘和 `.rpk` 快应用，发送前校验元数据、文件大小与 MD5；
- 表盘执行预安装、Mass 传输、安装结果与 `setFace(faceId)`；
- 快应用执行 `20/1` 预安装、Mass `0x40` 传输，并等待匹配包名的 `20/2` 最终结果；
- 设备 ACK 驱动双层进度条、KB 进度和 KB/s 实际确认速度；
- 支持本地取消、超时停止、检查点和重连后的源文件一致性检查；
- Android 已接入 RFCOMM 与安全存储，仍需目标设备真机验收；macOS 已接入
  CoreBluetooth 扫描、IOBluetooth SPP、Keychain 和沙盒文件授权，仍需目标设备真机安装验收；
  Linux 仅保留明确的不支持提示。

## 自行编译和运行

本仓库有两个独立入口：根目录是 Flutter GUI，`tui/` 是只支持 macOS 的终端程序。两者不能互相替代；TUI 不会启动 Flutter，也不依赖 GUI 运行时。

### Flutter GUI

准备 Flutter stable（内置 Dart 3.9.2+；当前已验证 Flutter 3.44.8 / Dart 3.12.2）以及目标平台的开发环境。在仓库根目录执行：

```sh
flutter pub get
flutter run -d macos

# 或在 Windows 上运行
flutter run -d windows
```

仅构建而不启动时，分别使用：

```sh
flutter build macos --debug
flutter build windows --debug
```

Windows 也提供会先更新页面注册表的构建脚本。PowerShell 中执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool\build_windows_only.ps1
```

脚本默认从 `C:\src\flutter` 寻找 Flutter；使用其他位置时传入 `-FlutterRoot`。发布 GUI 可使用 `flutter build macos --release`。

### macOS TUI

TUI 需要 macOS、Xcode Command Line Tools、CMake 和 Dart SDK；原生 Bluetooth helper 不需要 Flutter。下面的命令从仓库根目录开始，先构建并 ad-hoc 签名 helper，再启动交互式 TUI：

```sh
cd tui
dart pub get
cd macos_bridge
./scripts/package_bundle.sh --ad-hoc
cd ..
dart run bin/wristload_tui.dart
```

需要较完整的本地编译检查时，在 `tui/` 执行：

```sh
dart analyze lib test bin tool
dart test
```

`package_bundle.sh --ad-hoc` 会运行 CMake 构建与不依赖硬件的 CTest，并把已签名 helper 放到 TUI 默认读取的位置。可用 `dart run bin/wristload_tui.dart --probe` 只检查 TUI 到 helper 的启动与 JSONL 握手；`--fixture ready` 可预览纯内存界面，两者都不连接设备。更多 TUI 操作说明见 [`tui/README.md`](tui/README.md)。

Android 原生工程已生成，最低 SDK 需保持为 21+，并已声明附近设备/蓝牙扫描/连接权限。不要让 Flutter 模板重新生成时覆盖 `lib/` 或 `pubspec.yaml`。
macOS 最低版本为 10.15。首次连接前需在系统蓝牙设置中完成配对；应用会通过设备广播名将
CoreBluetooth 标识映射到已配对的经典蓝牙设备。广播名不唯一时会拒绝猜测，避免连接到错误设备。

当前工作站验证状态（2026-08-10）：

- Flutter 3.44.8 / Dart 3.12.2 已找到并可用；
- Dart 静态分析保持无错误；45 项自动化测试覆盖 RPK 最终结果解析、多清单冲突、畸形 PB、压缩包安全边界和安装进度 UI；
- `flutter build windows --debug` 已成功，产物在 `build\windows\x64\runner\Debug\wristload.exe`，冒烟运行通过；
- n67cn（小米手环 9 Pro）已真机确认 RFCOMM → L1START → `sendAppVerify` →
  `sendAppConfirm` → `device ready`，以及表盘 Mass 传输；
- 快应用控制命令、Mass `0x40` 和最终 `20/2` 数据结构已实现，等待本版真机安装验收；
- macOS Runner、蓝牙/文件沙盒权限、Keychain、系统时间、SPP/RFCOMM 与
  security-scoped bookmark 恢复链路已实现；尚未在 Mac + 目标手环上完成端到端安装验收；
- 小米手环 7 Pro 已确认属于 Huami/Zepp 独立协议，小米手环 8 Pro 属于旧 Vela V1；二者均与当前 V2 安装链路隔离，详见 [`文档/经典设备协议差异.md`](文档/经典设备协议差异.md)；
- 逆向工具链（便携 JDK 21 + JADX 1.4.7）与反编译产物在 `项目目录/tools/`，不纳入仓库。


## 分层

- `lib/platform/`：基于 `bluetooth_low_energy` 的 BLE 传输，以及各平台 RFCOMM、
  安全存储、系统时间和沙盒文件桥接；
- `lib/domain/`：设备档案、安装任务和协议边界；
- `lib/domain/protocol/`：私有协议核心（逆向确认的帧与命令，独立实现）；
- `lib/application/`：状态控制器；
- `lib/presentation/`：Material 3 安装任务、进度与离线 HCI 页面；
- `lib/main.dart`：应用入口、首页布局与文件选择交互。

协议帧只能由应用层控制器通过平台 transport 写入，禁止由 UI 直接写 GATT
Characteristic 或 RFCOMM；所有安装写入还必须通过 `VerificationGate`。

## 协议核心（`lib/domain/protocol/`）

基于 `analysis/协议方法体级分析_小米运动健康_9.23.35.md` 的逆向结论实现，**全部独立编写，仅复用必须互通的协议常量**（UUID、帧布局、命令号、protobuf 字段号）。

| 文件 | 内容 |
|---|---|
| `proto_wire.dart` | 最小 protobuf wire 编码/解码（varint、zigzag、length-delimited） |
| `zau.dart` | zau 命令 + 表盘(a9u/y8u/x8u)/RPK(v8s/j8s/k8s)/Mass(o1h/s1h/u1h/q1h) 载荷 |
| `spp_protocol.dart` | 已验证的 RFCOMM L1/L2 帧、累计 ACK 与版本查询 |
| `transport_constants.dart` | GATT UUID 与 CRC-16 公共常量，不包含第二套帧实现 |
| `mass_transfer.dart` | Mass 文件分片（22B 首片头、CRC32 尾、10MB 大块、设备协商数据段长） |

已确认常量（逆向来源见分析文档 §3/§4）：

- GATT：Service `0000fe95-…`、Write `0000005f-…`、Notify `0000005e-…`
- zau：f1=命令号、f2=子命令；oneof f6=表盘、f22=RPK、f24=Mass
- 表盘：预装 `(4,4)` → Mass dataType=`0x10` → 结果 `(4,5)` code∈{2,3} → setFace `(4,1)`
- RPK：预装 `(20,1)` → Mass dataType=`0x40` → 结果 `(20,2)`，状态 0 且包名匹配才成功
- Mass dataType：表盘 `0x10`、RPK `0x40`

发送只允许发生在已完成 authkey 的 RFCOMM 会话。GATT 成功、文件写入完成或
Mass ACK 完成均不等于安装成功；必须收到对应业务完成事件。

## SPP/authkey 认证

`auth_handshake.dart` 使用官方 App 的 `abu/bc0/hc0/ec0` protobuf 结构，认证
路径与 `analysis/重新绑定日志_SPP鉴权链路_2026-08-08.md` 对照：

1. 选择设备后自动建立 RFCOMM；
2. 对已识别 V2 目标直接发送已验证的 L1START；
3. 发送 f=26，校验设备签名，发送 f=27；
4. 仅收到 confirm success 时记录 `device ready`。

这是面向用户已授权设备的连接兼容性实现，不实现账户绑定、token 生成或服务器
绑定材料。不要把 `kSppAuthProtocolVerified` 误解为安装协议已验证。

## 构建备注（2026-08-07）

- `bluetooth_low_energy_windows` 6.2.1 依赖 `<experimental/coroutine>`，在 VS 18 BuildTools（MSVC 14.51）下触发 STL1011 编译错误；已在 `windows/CMakeLists.txt` 为 MSVC 定义 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` 修复。
- `flutter analyze` 在含中文的工程路径下偶发 analysis server LSP JSON 崩溃，可改用 `dart analyze`。
