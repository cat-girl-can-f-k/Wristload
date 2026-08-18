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
  -> signed macos_bridge/.../wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge
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

authkey 已保存时显示完整值；未保存时显示 `-`。设备名称以 Unicode grapheme 和 terminal cell width 渲染，处理 CJK、emoji 与 ANSI/控制字符。宽终端使用单行多列，中等宽度自动换行，窄终端使用堆叠信息；选中后按 `d` 或 `Tab` 可进入可滚动详情页查看完整名称。

初始化成功后，若没有进行的扫描、自动连接或连接活动，TUI 会自动开始扫描。

键盘与鼠标共用同一条规范化 MAC 选择与焦点状态。设备浏览器中可用 `↑`/`↓`（或 `j`/`k`）选择设备；在最后一行按 `↓` 会进入命令栏，列表为空时按 `↓` 也会进入命令栏。命令栏中用 `←`/`→` 切换已显示的命令，按 `↑` 返回设备浏览器，`Enter` 执行当前聚焦命令；终端高度不足时，命令栏显示 `<页码/总页数>`，在一页的首个或末个命令继续按 `←`/`→` 会翻页，鼠标也可点击 `<`/`>`。设备浏览器中的 `Enter`/`c` 或连接按钮只在未连接或失败时发起当前设备的连接；连接中、等待 authkey、鉴权中和就绪时不会重复连接或断开。断开请按 `x`，或在命令栏聚焦“断开”后按 `Enter`。`d`/`Tab` 打开详情，`L` 打开独立日志。滚轮和鼠标点击使用同一选择与焦点模型。终端 resize 会重新计算布局和 hitbox。退出时恢复 raw mode、鼠标捕获、备用屏幕和 cursor。

常用操作：

```text
r 扫描/停止扫描     Enter/c 连接（未连接/失败）    d/Tab 详情    x 断开
s 保存/取消保存     a 输入 authkey     i 安装资源
z 取消安装          t 自动连接开关       m 切换主题       L 独立日志
q 或 Ctrl-C 退出
```

对于当前扫描到的 Classic 设备行，`Enter`、`c` 和连接按钮会把该行的精确 Classic MAC、名称和 profile 作为一次性定向连接目标传给原生 backend，不会打开应用内设备选择器。输入 authkey 后，输入框会立即关闭并显示连接中；只有真正收到 `ready` 才会保存 authkey。系统自己的配对确认仍必须由用户同意。仅存在于保存历史、但当前不在扫描结果中的设备行，以及自动连接，仍使用严格身份校验。

安装和 Bluetooth I/O 均在渲染循环之外执行。取消安装可以越过正在等待的安装 action；底层 RFCOMM 写入仍由 transport FIFO 串行化。只有设备业务完成事件才能标记安装成功，RFCOMM `write.done` 或 Mass ACK 不是安装成功。

主界面的 `ACTIVITY` 仅保留紧凑的近期状态摘要，不承载完整诊断日志。按 `L` 打开独立日志查看器；打开或关闭该窗口不会断开设备、停止主界面、改变选中设备或影响自动连接和安装生命周期。

连接检查器会显示应用层已经报告的高层阶段（例如等待 authkey、鉴权中和 Session READY）。当前 UI 端口尚未暴露带连接代次的 Identity、Pairing、SDP、RFCOMM、L1、f=26、f=27 逐阶段 DTO，因此这些节点显示为 `未报告`；前端不会从诊断日志、notice 文本或宽泛的“连接中”状态推断传输/协议成功。

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

这项 APK/历史设备证据不是 Xiaomi Smart Band 10 Pro 5E29 的 transport 证明。对该设备，业务 transport、SDP service、RFCOMM channel、raw TX 和 raw RX 都必须以新的目标设备观察为准；在此之前均为 `UNKNOWN`。

SPP 8-bit sequence 只在一个物理 RFCOMM generation 内有效。TUI 对每个物理连接一次性分配 sequence，耗尽时 fail-closed 并要求重建 RFCOMM，避免迟到 ACK 误匹配。

## 定向 Classic 配对

配对不再打开 macOS 的设备选择器。TUI 会先通过 `identity.resolve` 将当前候选绑定到精确的 Classic MAC；随后 `pair.start` 只使用这个 MAC 调用 `IOBluetoothDevice deviceWithAddressString:` 和 `IOBluetoothDevicePair`。原生层会重新核对返回的 MAC 与候选名称；地址缺失、不一致或名称不匹配会失败，不会退回到按名称搜索或显示设备选择窗口。CoreBluetooth UUID 只属于 BLE 身份层，不能转换或拿来作为 Classic/RFCOMM 地址。

这会跳过“选择 Classic Bluetooth 设备”的窗口，但不会绕过 macOS 的配对安全流程。公开 API 不保证只显示由系统拥有的确认弹窗：PIN 或数值比较 delegate 仍可能要求 helper 取得用户确认并及时回复。Classic 配对完成后 identity 仍是 `provisional`；RFCOMM 连接、Xiaomi authentication 和资源安装是后续独立步骤。

### 一次性定向目标

当用户已经明确知道目标的 **Classic Bluetooth MAC**、名称和已识别 profile 时，可在启动时加入一个仅属于当前进程的临时设备行：

```sh
dart run bin/wristload_tui.dart \
  --directed-mac AA:BB:CC:DD:EE:FF \
  --directed-name "Example Classic Device" \
  --directed-profile band10Pro
```

三个 `--directed-*` 参数必须同时提供，且不能与 `--probe` 或 `--fixture` 混用。该临时设备行使用 `g`（或“定向连接”按钮）传递一次性的 exact-address 授权。普通扫描行的 `Enter`、`c` 和连接按钮也会使用其当前扫描到的精确 Classic MAC；保存历史中的非扫描行、保存后的重连和自动连接仍保留严格身份校验。

该目标不会自动写入已保存设备、Keychain 或自动重连状态；需要持久化时仍须由用户明确执行保存操作。这里只能填写 Classic MAC，不能填写或从 CoreBluetooth UUID/BLE 标识推导地址。

## 构建和运行

要求：macOS、Xcode Command Line Tools、CMake 和 Dart SDK。bridge 不需要 Flutter。

### 编译发布可执行文件

先构建并签名 TUI 专用 helper，再编译 AOT 可执行文件：

```sh
cd /Users/ikun_cxkpro/Projects/WearableInstall/tui
dart pub get
cd macos_bridge
./scripts/package_bundle.sh --ad-hoc
cd ..
dart compile exe bin/wristload_tui.dart -o build/wristload_tui
./build/wristload_tui
```

如果旧版 TUI 正在运行，请先退出它；若只想并行生成新文件而不覆盖当前进程，改用：

```sh
dart compile exe bin/wristload_tui.dart -o build/wristload_tui-next
```

### 快速编译检查

从仓库根目录执行以下命令。前四步只处理依赖、静态分析和测试；最后两步构建并以 ad-hoc 签名打包 TUI 专用 helper，然后启动 TUI。

```sh
cd tui
dart pub get
dart analyze lib test bin tool
dart test

cd macos_bridge
./scripts/package_bundle.sh --ad-hoc

cd ..
dart run bin/wristload_tui.dart
```

查看诊断日志时，源码运行与已编译程序使用不同但等价的入口。两者均可零参数启动并使用默认诊断文件：

```sh
# 源码运行
dart run bin/wristload_logs.dart

# 已编译可执行文件；不要在该命令后加 run 或 Dart 脚本路径
./build/wristload_tui logs
```

需要持续跟随新增日志时，可选加入 `--follow`：`dart run bin/wristload_logs.dart --follow` 或 `./build/wristload_tui logs --follow`。也可以指定日志文件：`./build/wristload_tui logs --file "$HOME/Library/Application Support/WristloadTui/diagnostics.jsonl"`。

`package_bundle.sh` 会执行 CMake 构建、native CTest、bundle 安装、ad-hoc 签名和签名检查。若只需单独验证 native bridge，可在 `tui/macos_bridge` 目录执行：

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

实际设备配对、连接、`--probe` 和协议调试不属于上述编译检查，应在已构建并签名的 helper 上单独手动进行。

```sh
# 只验证 helper 启动、JSONL handshake 和已配对设备读取。
dart run bin/wristload_tui.dart --probe

# 新 UI 的纯内存预览。
dart run bin/wristload_tui.dart --fixture ready
dart run bin/wristload_tui.dart --fixture queueRunningTransfer
```

生产入口只解析经 `codesign --verify --strict` 校验的 staged helper bundle：默认位置为
`macos_bridge/build-bundle/stage/wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge`。
若该 bundle 缺失、未签名或签名失效，TUI 会安全失败并提示运行
`./scripts/package_bundle.sh --ad-hoc`；它不会回退到未签名 plain helper，也不会自动签名。
可用 `--helper <path>` 显式覆盖 helper 路径（仅供受控开发/诊断使用），`--help` 列出完整 fixture 名称。

## 当前真实设备边界

编译与无硬件测试只能证明代码路径、JSONL 契约和状态机检查；它们不能证明某一手环的 transport 或认证已经成功。当前目标为 Xiaomi Smart Band 10 Pro 5E29，Classic 地址为 `2C-0D-CF-70-5E-29`。

本机对该目标已观察到：精确 Classic identity resolve 成功，随后 `IOBluetoothDevicePair.start` 被 macOS 接受；但约 90 秒内没有收到终止、PIN、数值比较或 passkey delegate，最终得到 `pairing_timeout`。因此目前首个真实失败层是：

```text
IOBluetoothDevicePair.start accepted
  -> pairing terminal delegate delivery / handling: no callback observed
  -> root cause: UNKNOWN
  -> Classic SDP / RFCOMM / raw TX / raw RX: not attempted for this target
```

这不是 authkey、f=26、L1START、安装协议或资源传输失败的证据。只有目标设备实际完成配对后，才可继续验证 SDP、RFCOMM、原始 TX/RX 和 Xiaomi 会话；在此之前 Band 10 Pro 的 macOS 端到端兼容性保持 `UNKNOWN`。

## macOS 权限

首次使用可能需要在“系统设置 -> 隐私与安全性 -> 蓝牙”允许实际启动 TUI/helper 的进程。配对是系统级状态，不等同于 authkey 鉴权，也不证明 RFCOMM/SDP 可用。发布为签名 app 或 helper 时，需要重新核验 bundle identity、Info.plist、entitlements、Sandbox 和 TCC；不能仅以开发终端的授权状态推断发布产物可用。
