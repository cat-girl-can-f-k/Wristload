# Flutter 应用：第一版

此目录是全新实现的 Flutter Material 3 应用，不包含、也不引用任何反编译 APK 的代码、资源、布局或服务端接口。

## 第一版边界

- 实际扫描 Android/Windows/Linux 支持的 BLE 设备；
- 实际建立 BLE GATT 连接并读取服务 UUID；
- 导入本地 `.bin` 表盘或 `.rpk` 快应用文件；
- 在设备身份、能力和私有协议均未验证前，只创建明确标记为“等待协议验证”的尝试任务，**不会发送不明安装帧**；
- 保留 `WearProtocol` 接口，让后续基于自有设备 HCI 日志实现经过验证的协商与传输。

## 环境

需要 Flutter 3.22+、Dart 3.3+ 和各平台开发工具。安装 SDK 后，在本目录运行：

```powershell
flutter pub get
flutter run -d windows
```

Android 原生工程已生成，最低 SDK 需保持为 21+，并已声明附近设备/蓝牙扫描/连接权限。不要让 Flutter 模板重新生成时覆盖 `lib/` 或 `pubspec.yaml`。

当前工作站验证状态（2026-08-08）：

- Flutter 3.44.8 / Dart 3.12.2 已找到并可用；
- Dart 静态分析与单元测试已通过（含协议核心编码测试）；
- `flutter build windows --debug` 已成功，产物在 `build\windows\x64\runner\Debug\miwearable_install_tool.exe`，冒烟运行通过；
- n67cn（小米手环 9 Pro）官方日志已确认 RFCOMM → SPP 版本 2.1.2 → L1START →
  `sendAppVerify` → `sendAppConfirm` → `device ready` 的认证顺序；应用提供
  「通过 SPP 验证 authkey」入口。该入口不开放任何安装业务；
- Android SDK 尚未在 C:、D: 找到，因此不能构建 APK；安装 Android SDK 后设置 `ANDROID_HOME` 即可；
- 逆向工具链（便携 JDK 21 + JADX 1.4.7）与反编译产物在 `项目目录/tools/`，不纳入仓库。


## 分层

- `lib/platform/`：基于 `bluetooth_low_energy` 的真实 BLE 传输（Windows 优先）；
- `lib/domain/`：设备档案、安装任务和协议边界；
- `lib/domain/protocol/`：私有协议核心（逆向确认的帧与命令，独立实现）；
- `lib/application/`：状态控制器；
- `lib/presentation/`：Material 3 界面。

协议帧只能写入 `WearProtocol` 的实现，禁止由 UI 直接写 GATT Characteristic。

## 协议核心（`lib/domain/protocol/`）

基于 `analysis/协议方法体级分析_小米运动健康_9.23.35.md` 的逆向结论实现，**全部独立编写，仅复用必须互通的协议常量**（UUID、帧布局、命令号、protobuf 字段号）。

| 文件 | 内容 |
|---|---|
| `proto_wire.dart` | 最小 protobuf wire 编码/解码（varint、zigzag、length-delimited） |
| `zau.dart` | zau 命令 + 表盘(a9u/y8u/x8u)/RPK(v8s/j8s/k8s)/Mass(o1h/s1h/u1h/q1h) 载荷 |
| `l1_l2_frame.dart` | SAR 帧：L1（magic/type·frx/seq/len/crc）、L2（channel/opCode）、GATT UUID 常量 |
| `mass_transfer.dart` | Mass 文件分片（22B 首片头、CRC32 尾、10MB 大块、设备协商数据段长） |

已确认常量（逆向来源见分析文档 §3/§4）：

- GATT：Service `0000fe95-…`、Write `0000005f-…`、Notify `0000005e-…`
- zau：f1=命令号、f2=子命令；oneof f6=表盘、f22=RPK、f24=Mass
- 表盘：预装 `(4,4)` → Mass type=1 → 结果 `(4,5)` code∈{2,3} → setFace `(4,1)`
- RPK：预装 `(20,1)` → Mass type=4 → AppStatus 11 成功
- Mass dataType：表盘 `0x10`、RPK `0x40`

⚠️ **发送门控**：`wear_protocol.dart` 的 `kProtocolVerified` 默认保持 `false`。
CRC16 算法、`p0` int 编码（varint/zigzag）、段长语义、绑定鉴权仍待真机 HCI 验证，
验证前任何安装调用都只会返回「等待协议验证」任务。

## SPP/authkey 认证（n67cn 已实现，待真机确认）

`auth_handshake.dart` 使用官方 App 的 `abu/bc0/hc0/ec0` protobuf 结构，认证
路径与 `analysis/重新绑定日志_SPP鉴权链路_2026-08-08.md` 对照：

1. 连接后点击「通过 SPP 验证 authkey」；
2. 读取 SPP 版本，发送已由日志核对的 L1START；
3. 发送 f=26，校验设备签名，发送 f=27；
4. 仅收到 confirm success 时记录 `device ready`。

这是面向用户已授权设备的连接兼容性实现，不实现账户绑定、token 生成或服务器
绑定材料。不要把 `kSppAuthProtocolVerified` 误解为安装协议已验证。

## 构建备注（2026-08-07）

- `bluetooth_low_energy_windows` 6.2.1 依赖 `<experimental/coroutine>`，在 VS 18 BuildTools（MSVC 14.51）下触发 STL1011 编译错误；已在 `windows/CMakeLists.txt` 为 MSVC 定义 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` 修复。
- `flutter analyze` 在含中文的工程路径下偶发 analysis server LSP JSON 崩溃，可改用 `dart analyze`。
