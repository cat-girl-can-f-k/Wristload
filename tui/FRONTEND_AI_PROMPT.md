# WearableInstall macOS TUI 前端实施提示词

使用方法：把下方 BEGIN PROMPT 到 END PROMPT 之间的内容完整交给负责前端的 AI。不要只截取页面要求；接口边界、安全语义、测试和交付约束同样属于任务。

~~~~text
BEGIN PROMPT

你负责为 WearableInstall 的独立 TUI 工程实现前端。你的工作目标是交付一个紧凑、可靠、可完全用键盘操作的中文终端界面，并通过唯一的 facade 接入现有 macOS 安装后端。

这不是概念设计、网页、Flutter 页面或营销首页任务。请在读取仓库后直接实现前端、测试和必要的前端说明，但不得越过下面规定的边界补写蓝牙或安装协议。

一、必须先理解的项目事实

1. 工作区中的 TUI 工程位于 tui/，根目录是现有 Flutter GUI。TUI 是独立的纯 Dart 工程，不启动 Flutter engine，也不复用 Flutter presentation。
2. TUI 只面向 macOS。Windows、Linux、Android、iOS 以及跨平台兼容均不在范围内。
3. 设备连接使用 macOS IOBluetooth.framework 提供的经典蓝牙、SDP 和 RFCOMM，不是 CoreBluetooth BLE GATT。
4. 原生 helper 位于 tui/macos_bridge/，通过 JSON Lines 与 Dart 传输层通信。前端不拥有 helper 生命周期，也不理解 JSONL。
5. 安装后端保留 authkey、f=26/f=27 鉴权、AES 会话、SPP、Mass、累计 ACK、发送窗口、重试、检查点、文件 MD5/SHA-256 复核，以及表盘和 RPK 的设备业务完成事件验证。
6. 当前允许安装的设备必须明确识别为 ProtocolGeneration.v2Vela。旧 Vela、Huami/Zepp、未知代际和仅凭猜测得到的型号不能进入安装链路。
7. macOS 系统蓝牙配对与小米 authkey 会话鉴权是两件不同的事。界面必须分别显示，不能把“已配对”写成“已鉴权”。
8. 文件全部写入 RFCOMM、收到全部 Mass ACK 或进度达到 100%，都不代表安装成功。只有 facade 给出的匹配设备业务成功终态才能显示“安装成功”。
9. 断链、超时、畸形响应、取消或业务结果无法验证时，必须保留“设备状态未知”语义，不能自动降格成普通失败，更不能显示成功。
10. authkey 当前只允许保存在进程内存中。不要声称它已写入 Keychain，也不要自行把它保存到 JSON、配置文件、历史记录、日志或检查点。

开始前完整阅读：

- tui/README.md
- tui/UPSTREAM_SOURCES.md
- tui/macos_bridge/README.md
- tui/pubspec.yaml
- tui/lib/wristload_tui.dart
- tui/lib/src/facade/ 下实际存在的所有公开接口（若该目录已经存在）

仓库可能有用户未提交的改动。保留所有非本任务改动，不要重置、清理、覆盖或格式化根 Flutter 工程。

二、硬性所有权边界

前端只负责：

- 终端初始化和恢复
- 键盘输入、粘贴、焦点、导航和快捷键
- 布局、Unicode 宽度、颜色和状态渲染
- 前端弹层与高风险动作确认
- 调用 facade 的公开动作
- 订阅 facade 的不可变快照
- 前端本地视图状态
- fake facade、状态 fixture、渲染测试和键盘测试

前端绝对不能：

- import 或实例化 WristloadBackend
- import 或实例化 MacBluetoothTransport 或 JsonLineMacBluetoothTransport
- 启动、停止、kill、重启或直接监管 wearable_macos_bridge
- 读写 helper 的 stdin/stdout/stderr 或解析 JSONL
- import IOBluetooth、CoreBluetooth、dart:ffi，或为蓝牙调用 Process
- import 或调用 SppProtocol、Zau、SessionCipher、MassTransfer、VerificationGate、检查点 store 或任何 protocol 文件
- 构造或发送 RFCOMM 字节、L1/L2 帧、f=26/f=27、ACK、Mass 分片或业务 protobuf
- 自行解析安装包、计算安装元数据、修改 InstallRequest 或写检查点
- 根据字符串、RSSI、UUID 尾部或设备名猜测经典蓝牙地址
- 绕过 authkey、型号门控、文件校验、确认项、VerificationGate 或设备业务终态
- 增加“跳过校验”“强制发送”“忽略设备结果”“假定成功”“从头强刷”等入口
- 为了让代码编译而扩大 wristload_tui.dart 的公共导出或访问 lib/src 内部后端

前端可保存的本地状态仅限当前页面、焦点、滚动位置、选中项 ID、弹层是否打开、输入框的短生命周期内容、颜色模式和帮助开关。连接、扫描、鉴权、设备、队列、任务、检查点、设置和日志的事实状态都以 facade 快照为唯一真相。

三、当前 facade 缺失时的处理规则

本提示词生成时，仓库中可能还没有 TuiFacade 和聚合 TuiSnapshot。你必须先检查实际源码，不能假装接口已经存在。

如果 facade 已存在：

1. 只使用 tui/lib/wristload_tui.dart 正式导出的 facade 和 UI DTO。
2. 以实际接口为准，并检查它是否满足本文的语义契约。
3. 任何缺口写入 tui/FACADE_GAP.md，说明所需字段、动作、原因和受影响页面。
4. 不得用访问 backend、transport 或 protocol 的方式填补缺口。

如果 facade 尚不存在：

1. 仍然完成全部前端布局、交互、状态映射和测试。
2. 在 tui/lib/src/frontend/ 内定义一个仅供前端使用的 TuiFrontendPort 抽象和不可变 UI view model；语义必须匹配下一节的契约。
3. 提供 FakeTuiFrontendPort 和完整 fixture，使所有页面无需真机即可运行和测试。
4. 不要在 tui/lib/src/facade/ 中替后端作者创建生产 facade，不要实现 transport/bridge 适配器。
5. 不要把 fake 接到正式生产入口，也不要打印会误导用户的“后端已连接”信息。
6. 创建 tui/FACADE_GAP.md，明确说明正式入口仍缺少哪一个生产适配器。
7. 可以提供仅用于开发的 fixture preview，但名称和启动输出必须明确标注 FAKE / PREVIEW，不能冒充真实设备。

前端 port 的存在只是解耦开发手段。正式 facade 交付后，生产适配器必须是无业务判断的薄映射层；所有动作许可、地址解析、型号判定、文件确认和安装语义仍由 facade 决定。

四、最终 facade 必须满足的语义契约

不要要求前端从多个 stream 拼接状态。生产 facade 必须向前端提供一个原子的、不可变的 TuiSnapshot，并提供一个会向每个新订阅者先发当前值的状态流。

前端 port 可按以下形状建模。名称可以适配实际公开类型，但语义和数据所有权不能改变：

    abstract interface class TuiFrontendPort {
      TuiSnapshot get snapshot;
      Stream<TuiSnapshot> get snapshots;

      Future<TuiActionResult> initialize();
      Future<TuiActionResult> refreshPairedDevices();
      Future<TuiActionResult> startScan({Duration duration});
      Future<TuiActionResult> stopScan();
      Future<TuiActionResult> addManualDevice({
        required String address,
        required String modelId,
        String? displayName,
      });
      Future<TuiActionResult> connectDevice(String deviceId);
      Future<TuiActionResult> disconnect();
      Future<TuiActionResult> submitAuthKey(String value);
      Future<TuiActionResult> clearAuthKey();

      Future<TuiActionResult> importFiles(List<String> literalPaths);
      Future<TuiActionResult> resolveDecision(
        String decisionId, {
        required bool accepted,
        Map<String, String> values,
      });
      Future<TuiActionResult> removeQueueItem(String itemId);
      Future<TuiActionResult> moveQueueItem(String itemId, int newIndex);
      Future<TuiActionResult> clearCompletedQueue();
      Future<TuiActionResult> startQueue();
      Future<TuiActionResult> retryQueueItem(String itemId);
      Future<TuiActionResult> cancelActiveInstall();

      Future<TuiActionResult> inspectRecovery();
      Future<TuiActionResult> resumeRecovery();
      Future<TuiActionResult> discardRecovery();
      Future<TuiActionResult> updateTransferSettings({
        required int segmentIntervalMs,
        required int massWindowSize,
      });
      Future<TuiActionResult> exportSafeLogs(String literalDestinationPath);
      Future<void> dispose();
    }

这是语义接口，不授权你在生产层实现缺失的后端功能。实际 facade 若把少量动作合并或改名，写一个薄前端适配器即可，不要复制业务规则。

TuiActionResult 至少要表达：

- accepted：动作是否被接受
- code：稳定的机器可读 reason code；前端不能解析异常字符串来判断类型
- message：已经适合展示且不含敏感信息的中文说明
- operationId：可选，用于关联异步操作和避免重复提交

正常的用户输入错误、动作被门控、蓝牙常见错误和文件导入失败应返回 typed result 或进入 snapshot，而不是让 stream 崩溃。前端仍须捕获意外异常，恢复终端并显示不含堆栈和秘密的兜底信息。

TuiSnapshot 至少聚合以下内容：

1. revision：单调递增版本号，便于识别迟到动作和测试。
2. platform：明确 macOS-only 和当前平台是否受支持。
3. helper：stopped、starting、ready、failed、disposed；包含安全的 code/message、协议版本和可执行文件状态，但不暴露 Process。
4. scan：idle、starting、running、stopping、failed；包含截止时间或剩余时间等展示信息。
5. supportedModels：由后端提供的可安装 V2 型号 ID、名称、代际和支持状态，供手动地址选择；前端不能自己维护型号白名单。
6. devices：已配对、扫描和手动来源按经典地址 key 去重后的不可变列表。
7. connection：disconnected、connecting、awaitingAuthKey、authenticating、reconnecting、ready、disconnecting、failed 等 UI 状态，以及当前目标。
8. authKeyLoaded：只允许 bool；快照不得包含 authkey、nonce、会话密钥或 HMAC。
9. pendingDecisions：后端生成的待确认项，使用稳定 decisionId。
10. queue：使用稳定 itemId 的不可变队列视图。
11. activeTask：当前任务、阶段、进度和时间统计；无任务时为 null。
12. recovery：unchecked、checking、none、available、invalid、failed 等状态，以及不敏感的文件摘要。
13. transferSettings：当前已生效的 segmentIntervalMs 和 massWindowSize 及范围。
14. logs：结构化且已脱敏的日志条目。
15. notice：一次性或可覆盖的安全提示、错误和状态消息。
16. allowedActions 与 blockedReasons：所有全局动作的许可和禁止原因。
17. busyOperations：正在执行的初始化、扫描、连接、鉴权、导入、设置、导出或清理动作。

每个设备视图至少包含：

- deviceId：稳定、不可由列表下标替代的 ID
- address：统一的 macOS 连字符显示格式
- addressKey：大写、无分隔的 12 位地址 key；仅用于身份和去重
- name：可能为空，界面要有“未知名称”占位
- rssi：可能为空，不能显示伪造的 0
- paired：macOS 配对状态
- sources：paired、inquiry、manual 的集合
- matchedModelId 和 matchedModelName：可能为空
- protocolGeneration 和 supportState
- blockedReason
- allowedActions

每个队列视图至少包含：

- itemId：稳定 ID；删除、排序、重试只能传 ID，不能依赖对象引用或下标
- kind：watchface 或 quickApp
- fileName、literalPath、fileSize
- md5Hex、sha256Hex
- 表盘可用的 faceId、解析到的分辨率、containsLua
- RPK 可用的 packageName、versionCode
- waiting、installing、done、failed、cancelled、stateUnknown 阶段
- message、failureAttempts、canRetry
- 该条目的 allowedActions 和 blockedReasons

activeTask 至少包含：

- kind、fileName、stage、message、targetDeviceName
- currentSegment、totalSegments
- confirmedBytes、queuedBytes、totalBytes
- queuedSegment
- bytesPerSecond、elapsed、transferElapsed、averageBytesPerSecond
- successVerifiedByDeviceBusinessEvent

不要把不存在的“预安装”枚举硬编码成后端状态。UI 可用友好文案描述过程，但判断必须以 facade 提供的阶段为准。

pendingDecision 必须是通用、可渲染的不可变描述，至少包含：

- decisionId 和 kind
- severity、title、message 和事实列表
- confirmLabel、cancelLabel，且默认选择取消
- 可选输入字段定义：fieldId、label、格式、是否必填、公开的范围
- 单次 token 或 revision 约束，防止确认应用到已经变化的文件或设备

至少要能表达以下后端决策：

- 表盘分辨率与当前设备不匹配的明确确认
- REDMI Watch 5 Lua 表盘不受支持的明确确认
- 缺失或需要复核的数值 faceId
- 缺失或无效的 RPK versionCode，合法范围 1 到 2147483647
- 恢复检查点文件已变化、不可访问或摘要不匹配

前端只能把 decisionId、accepted 和字段值交回 facade。不能自行构造或修改 InstallRequest，也不能允许用户手工填写 RPK packageName。

五、动作许可和并发规则

1. 所有控件是否可用都读取 allowedActions；blockedReason 直接用于状态栏或详情。不要仅通过 connection == ready 等字段自行推断业务许可。
2. 每次按键最多触发一次 facade 动作。动作 Future 未完成时，对应控件进入 busy，忽略重复 Enter 和按键连发。
3. 列表选中项用稳定 ID 保存。快照刷新后若 ID 仍存在则保持选择；不存在时选择相邻合理项，而不是连接另一个下标相同的设备。
4. 不缓存或修改 snapshot 内的对象。渲染前捕获同一 revision 的局部引用，避免一帧混用两个快照。
5. 操作结果与更新快照可能异步到达。以最新 revision 和稳定 operationId 为准，迟到结果只能形成提示，不能回滚状态。
6. facade 负责串行化有副作用动作；前端也要避免并发提交连接、鉴权、安装、重试、设置和退出。
7. 扫描时可以浏览已有设备；连接动作是否允许由 facade 决定。不要为了刷新列表重启 helper。
8. f=27 后可能出现后端管理的短暂 RFCOMM 重建。前端只显示 reconnecting，不自行重连、不再次提交 authkey，除非 facade 明确回到 awaitingAuthKey。
9. 显式断开会清除当前目标。断开后重试不得暗中连接旧设备，用户必须重新选择，除非 facade 明确给出可恢复动作。
10. 队列遇到 failed、cancelled 或 stateUnknown 后会暂停，必须等待用户明确处理或重试；不能自动跳到下一包。

六、经典蓝牙地址和设备规则

1. 真正的经典蓝牙地址只能来自 IOBluetoothDevice.addressString（经 facade 返回）或用户明确输入。
2. 手动输入只接受以下三种形式：

   - AA-BB-CC-DD-EE-FF
   - AA:BB:CC:DD:EE:FF
   - AABBCCDDEEFF

3. 不要在前端自行删除任意字符“修复”地址。把原始输入交给 facade 严格解析；只显示 facade 返回的规范地址。
4. 向用户始终显示 AA-BB-CC-DD-EE-FF。冒号只是一种允许的输入，不是 macOS 展示格式。
5. 拒绝 CoreBluetooth UUID、任意 UUID、超长十六进制和从 UUID 后 6 字节截取的伪 MAC。
6. 已配对列表和 inquiry 结果可能重复。只按 facade 的 deviceId/addressKey 呈现去重后的设备，合并 paired、RSSI、name 和 source。
7. 名称可能为空、变化或不足以识别型号。手动地址必须要求用户从 facade 的 supportedModels 选择明确 V2 型号；不能让用户输入任意字符串伪造型号。
8. 未识别、旧 Vela、Huami/Zepp 或未知协议设备必须显示拒绝原因。不要提供“仍然连接”或“强制安装”。
9. RSSI 只作显示和排序提示，不是身份信息、配对状态或协议支持依据。

七、安装和恢复必须如实呈现

文件导入：

- 仅接收用户输入的字面路径，支持 .bin、.face 和 .rpk。
- 路径可能包含空格、中文、引号字符或连字符。不要交给 shell，不做命令替换，不执行通配符，不拼接 shell 命令。
- 允许一次粘贴多行路径；逐行作为字面路径提交，清楚展示空行、重复、不支持扩展名和逐文件失败。
- 不在前端读取、解压、解析或 hash 文件。facade 返回已验证元数据后再展示。
- 导入过程必须有 busy 状态；大文件解析不能冻结渲染。
- 显示 added、duplicate、unsupported 和 failures 的分项结果，不用一句“导入失败”吞掉细节。

安装前确认：

- 展示目标设备名称、规范 MAC、识别型号、文件名、类型、大小和关键元数据。
- 所有后端 pendingDecision 必须先解决。
- 开始队列属于高风险动作，默认焦点为取消。
- 不允许用户直接改 packageName、哈希、文件大小或协议参数。

进度：

- 主进度按 confirmedBytes / totalBytes 计算，不按 queuedBytes，也不按本地 write 完成。
- queuedBytes 可以作为“已提交，等待累计 ACK”的次级信息。
- totalBytes 为 0 或未知时使用不定进度，不除以 0。
- 百分比限制在 0 到 100，布局宽度稳定，不因位数变化跳动。
- 速度和耗时直接显示 facade 数值，不在前端基于刷新频率重新计算。
- 100% 且 awaitingDevice 时明确显示“文件已确认发送，等待设备安装结果”，不能使用完成颜色或成功图标。

终态：

- succeeded：仅当 successVerifiedByDeviceBusinessEvent 为 true 且 facade 阶段为成功，显示“安装成功”。
- failed：设备明确拒绝或本地校验等已知失败，显示原因。
- cancelled：本地发送已取消；说明设备可能保留部分数据。
- stateUnknown：独立的最高关注状态，说明设备结果无法验证；不能写成普通失败或成功。
- 断链、超时和响应解析失败后保留最后确认进度，便于诊断，不归零伪装成未开始。

重试与检查点：

- 重试同一包不是“从头强刷”。本地检查点只证明文件一致性，实际续传偏移由设备 MassPrepare 协商。
- 未验证源文件 MD5/SHA-256、文件缺失或路径不可访问时禁止恢复。
- 恢复页必须显示检查状态、文件、摘要、最后确认片和 phase，但不能显示密钥或文件内容。
- 只有 resumeRecovery 被 allowedActions 允许时才显示可执行的继续动作。
- discardRecovery 是破坏性操作，必须二次确认并说明删除的是本地检查点，不会撤销设备端可能已有的数据。

八、页面与信息架构

使用工作型应用布局，不做 landing page，不堆叠装饰卡片。建议固定顶部状态条、中央工作区和底部上下文快捷键栏。

必须实现以下视图：

1. 设备 / 连接

- 顶部显示 macOS-only、helper、扫描、连接、鉴权和当前任务摘要。
- 显示已配对设备与扫描设备的合并列表：名称、完整 MAC、paired、source、RSSI、识别型号、协议支持。
- 支持刷新已配对设备、开始/停止扫描、手动地址、连接和断开。
- 扫描刷新不能丢失仍存在的选中 ID。
- 空列表、helper 启动中、扫描中、权限错误、蓝牙不可用、SDP 无 SPP、连接中、断开和失败都有明确状态及下一步。

2. authkey 弹层或连接侧栏

- 仅 facade 允许时可提交。
- 输入必须默认掩码，支持安全粘贴、清空和显式显示/隐藏。
- 明确只接受 32 位十六进制，但最终校验由 facade 执行。
- 提交前显示目标设备名称和 MAC；鉴权中禁止重复提交。
- 调用返回后立即清空输入 controller，释放对原始字符串的引用。
- clearAuthKey 必须说明会清除内存 authkey 和会话材料，并可能要求重新鉴权。
- 任何日志、状态、崩溃文本、fixture、测试快照和屏幕截图都不能包含完整 authkey。

3. 安装队列

- 支持输入或粘贴一个或多个文件路径。
- 每项显示稳定序号、类型、文件名、大小、阶段和简短原因；详情区显示路径、MD5、SHA-256、faceId/分辨率/Lua 或 packageName/versionCode。
- 支持按 ID 删除、移动、清理已完成、开始队列和失败项重试。
- 安装中的条目不能删除或重排，除非 facade 明确允许。
- 队列暂停原因必须醒目，不能把后续 waiting 项误画成正在继续。

4. 当前任务 / 传输

- 显示真实阶段、目标、文件、确认进度、已排队进度、片段、瞬时速度、平均速度、总耗时和传输耗时。
- 使用固定尺寸进度条；在窄终端退化为一行百分比和字节数。
- awaitingDevice、succeeded、failed、cancelled 和 stateUnknown 必须有明显不同的文字，不只靠颜色。
- cancel 动作必须二次确认，文案说明不会发送未经验证的设备取消帧，设备可能保留部分数据。

5. 恢复

- 可作为任务页区块或独立弹层。
- 展示 facade 的 recovery 状态和允许动作。
- 支持检查、继续和放弃；缺少 facade 动作时只读显示并记录接口缺口。

6. 设置

- 只显示 facade 实际支持的安装传输参数。
- segmentIntervalMs 范围 1 到 20，massWindowSize 范围 1 到 50。
- 使用输入框或步进器，不使用 GUI 滑块思维；越界值不提交。
- 显示已保存值、正在保存和失败回滚状态，以最新 snapshot 为准。
- 不添加跳过校验、强制发送、忽略错误、强制窗口、自动重试等选项。
- 当前 TUI 后端未公开时间同步，前端不要从根 GUI 移植 autoTimeSync。

7. 日志 / 诊断

- 只显示 facade 提供的结构化安全日志，按时间和级别渲染。
- 支持滚动、跟随尾部、暂停跟随、级别筛选和复制可见安全文本。
- 只有 exportSafeLogs 被允许时才提供导出；目标路径按字面值传给 facade，不自行拼 shell 命令。
- 不显示原始私有帧、完整 payload、nonce、HMAC、会话密钥、authkey 或未脱敏堆栈。
- 不要把所有 32 位十六进制一律隐藏，因为 MD5 是合法展示字段；安全脱敏应由 facade 结合字段语义完成。前端的责任是绝不记录 authkey 输入。

8. 帮助 / 关于 / 退出

- ? 或 F1 打开上下文快捷键帮助。
- 说明只支持 macOS classic Bluetooth，不提供 Windows/BLE 建议。
- q 只在非文本输入状态触发退出。
- 扫描、连接、鉴权、导入、安装或日志导出活跃时，退出必须二次确认。
- 退出只调用 facade.dispose 和正常终端恢复，不直接 kill helper。

明确不移植根 GUI 中的这些功能，除非未来 facade 正式公开：

- Flutter 页面、Material 组件和悬浮安装窗口
- desktop_drop 和 GUI 文件选择器
- Windows/Android BLE 兼容和平台通道
- HCI 抓包解码器
- 从小米运动健康 ZIP 提取 authkey 的工具
- 设备健康信息、通知、截图、时间同步等非安装核心工具
- authkey 复制、持久化或自动填充

九、键盘与焦点规范

建议快捷键，可按所选库调整，但必须在底栏和帮助中可发现：

- Tab / Shift+Tab：切换焦点区
- 左右方向键或 1-5：切换主视图
- j/k 或上下方向键：移动列表
- g/G：列表顶部/底部
- Enter：打开详情或确认当前非危险动作
- r：刷新已配对设备或开始扫描
- c：连接；已连接时打开断开确认
- a：打开 authkey 输入
- i：添加安装文件路径
- s：打开开始队列确认
- x：打开取消任务确认
- R：重试当前失败条目
- d：删除当前非活动队列项并确认
- l：日志跟随开关
- ? 或 F1：帮助
- Esc：关闭弹层、取消输入或返回
- q：退出

要求：

1. 文本输入获得焦点时，字母键必须输入文本，不能触发全局快捷键。
2. 支持 bracketed paste 或等效安全粘贴；粘贴内容不能被逐字符解释为快捷键。
3. 所有危险确认框默认选中“取消/返回”。Enter 只有在焦点明确位于确认按钮时才执行。
4. 不要求鼠标；若库天然支持鼠标，也只能作为可选增强。
5. 焦点必须始终可见。弹层打开时焦点被圈定，关闭后回到原控件。
6. 长操作不得阻塞事件循环或冻结重绘。界面持续响应 resize、取消和退出请求。
7. 快速重复按键、键盘自动重复和迟到 Future 不得造成双连接、双安装或列表选择漂移。

十、终端生命周期与响应式布局

终端生命周期：

- 使用 alternate screen 时必须在 try/finally 中恢复。
- 无论正常退出、Ctrl+C、SIGTERM、异常还是初始化失败，都要恢复 canonical mode、echo、光标、颜色和 alternate screen。
- 监听终端 resize 并重新布局，不保留超出新尺寸的旧绘制内容。
- 不向 stdout 混写调试日志，以免破坏 UI；安全诊断走 facade 日志区或退出后的 stderr 摘要。
- 对不支持的终端能力提供简洁降级；遵守 NO_COLOR。
- macOS 之外不要启动 helper。显示“不支持的平台”并安全退出。

布局断点：

- 小于 60x20：只显示“终端尺寸不足”、当前关键状态和退出/帮助；不得尝试挤压完整 UI。
- 60-79 列：单栏，只渲染当前主视图，详情通过切换或弹层打开。
- 80-99 列：两栏，左侧列表/导航，右侧详情；日志可折叠。
- 100 列及以上：2+1 或三栏，左侧导航、中间工作区、右侧连接/任务摘要。
- 高度不足时，顶部状态条和底部快捷键保持固定，列表与日志滚动。

Unicode 与尺寸：

- 中文通常占两个终端 cell。严禁用 String.length 做对齐、裁剪、表格列宽或光标定位。
- 使用库提供的 grapheme 和 cell-width API；若库没有，加入经过测试的 Unicode 宽度依赖或集中实现一个唯一的宽度适配器。
- 设备名、中文路径、全角标点、组合字符和 emoji 都不能导致覆盖或错位。
- MAC 地址不可截断。文件名和错误信息可按 cell 宽度省略，详情区显示完整内容。
- 进度条、百分比、按钮和状态列使用稳定宽度，动态内容不能推动相邻区域跳动。
- 颜色只作增强。每个状态必须同时有文字或 ASCII/Unicode 符号；不能只靠红绿区分。
- 避免依赖 emoji 字形，因为不同终端宽度不一致；不要用 emoji 作为唯一图标。

十一、视觉与文案

- 界面应克制、信息密度适中、面向重复操作，不使用巨型标题、营销文案、装饰渐变或 GUI 卡片堆叠。
- 用列表、表格、分隔线、状态条、标签和模态框组织信息；不要做卡片套卡片。
- 顶部始终可见：macOS-only、helper、扫描、连接设备与 MAC、鉴权、当前任务。
- 底部只显示当前上下文可执行快捷键；被禁止的动作可以显示禁用及简短原因。
- 错误文案优先使用 facade 的 code 和安全中文 message，不解析英文异常字符串。
- 对常见分类提供准确下一步：helper 缺失/不可执行/协议不匹配、蓝牙权限、扫描失败、SPP 服务缺失、连接 busy/timeout、远端断开、authkey 无效、设备不支持、文件无效、哈希变化、设备拒绝和状态未知。
- 不推荐 Windows 设置、冒号 MAC 修复、BLE GATT 扫描或从 UUID 推导地址。
- 空状态必须有实际下一步，不写产品宣传或操作教程长文。

十二、安全要求

1. authkey 输入默认掩码，显示/隐藏是显式动作；离开弹层、提交、失败或取消时清空。
2. 不把 authkey 放入状态管理、队列、日志、异常、测试 fixture、golden、截图、剪贴板、命令行参数或环境变量。
3. 不记录用户粘贴的原始内容。错误只写“格式无效”，不回显输入。
4. 不引入网络、遥测、崩溃上传或云服务。
5. 不执行用户输入的路径，不调用 shell 展开，不使用 eval，不拼接命令。
6. facade 快照不应含秘密；若发现秘密字段，停止使用并记录安全缺口，而不是在 UI 中“隐藏后继续传播”。
7. 日志导出必须来自 facade 的安全导出接口。不要直接转存 stdout、raw JSONL 或内部异常。
8. 不宣称 Keychain 支持。未来若后端加入 Keychain，也必须通过新 facade 能力和明确用户授权接入。
9. 不实现任何降低 VerificationGate 的开发模式、隐藏快捷键或环境变量后门。

十三、建议的前端代码结构

在不违背仓库实际结构的情况下，优先使用以下职责划分：

    tui/lib/src/frontend/
      app/                 应用循环、终端生命周期、路由
      port/                facade 适配接口；facade 缺失时的唯一隔离层
      state/               只含前端局部状态，不复制业务状态
      views/               devices、queue、task、recovery、settings、logs
      widgets/             表格、进度条、状态条、确认框、输入框
      input/               键位映射、焦点、粘贴和命令分发
      terminal/            cell width、resize、颜色能力和安全恢复
      fixtures/            fake snapshot 场景，仅开发和测试使用

要求：

- 渲染组件接收不可变 view model，不直接调用后端。
- 用户意图先变成前端 command，再由一个 action dispatcher 调 facade。
- 只有 dispatcher 处理 busy、防重复、ActionResult 和意外异常。
- 不创建一个复制全部 facade 状态的第二业务 store；保存最新 snapshot 引用即可。
- 不让页面知道 JSONL、Process、SPP、Mass 或检查点文件格式。
- 对所选 TUI 库写一层很薄的终端/事件适配，避免业务视图散落 ANSI 控制码。

依赖规则：

- 优先使用仓库已经选定的 Dart TUI 库。
- 若尚未选库，选择维护活跃、支持 raw keyboard、resize、alternate screen 和 Unicode cell width 的成熟库。
- 为实现前端允许只修改 tui/pubspec.yaml 的前端依赖部分，但必须在说明中写清选择理由、版本和许可证；不要更换现有 archive、crypto、pointycastle 或 test 版本。
- 不为一个简单控件引入庞大框架，不引入 Flutter。
- 若网络或依赖安装不可用，不要伪造测试通过；报告限制并保持代码可审查。

十四、fake 与测试矩阵

必须提供可编程 FakeTuiFrontendPort。它记录收到的动作，以离散 fixture 推送完整快照，不包含协议模拟、真实定时重试或蓝牙字节。

至少覆盖这些 fixture：

1. 初始启动、helper starting、ready、missing、protocol mismatch、unexpected exit。
2. 无设备、扫描中、扫描结束、扫描失败。
3. paired 与 inquiry 使用三种地址形式出现但归并为同一 deviceId。
4. 手动合法地址、无效地址、CoreBluetooth UUID 被拒绝。
5. V2 支持型号、旧 Vela、Huami/Zepp、未知型号。
6. connecting、awaitingAuthKey、authenticating、reconnecting、ready、remote closed。
7. authkey 空、长度错误、非 hex、正确提交、清除；任何输出都不出现测试 secret。
8. 文件添加成功、重复、不支持扩展、逐文件解析失败、长中文路径。
9. faceId、versionCode、分辨率和 Lua 四类 pendingDecision。
10. 空队列、多条等待、排序、删除、清理完成、队列运行。
11. validating、waitingForProtocol、transferring、awaitingDevice、succeeded、failed、cancelled、stateUnknown。
12. confirmedBytes 小于 queuedBytes，以及 confirmedBytes 等于 totalBytes 但仍 awaitingDevice。
13. 队列失败暂停、显式重试、无当前目标时重试被拒绝。
14. recovery checking、available、invalid、discard 和 resume 被门控。
15. 设置边界 1/20 ms、1/50 片，越界输入和保存失败回滚。
16. 日志为空、500 行滚动、安全筛选和导出失败。
17. 动作 Future 很慢、快速重复按键、迟到结果、快照删除当前选中 ID。
18. Ctrl+C、异常和 dispose 失败时终端仍恢复。

渲染与交互测试至少使用：

- 60x20
- 80x24
- 100x30
- 120x40
- 59x19 的尺寸不足降级

每个尺寸检查：无重叠、无越界、MAC 完整、关键动作可达、底栏不覆盖内容、焦点可见。加入长中文设备名、长文件名、组合字符和包含 emoji 的名称验证 cell width。

必须测试：

- 所有主要快捷键及文本输入时的快捷键隔离
- 危险确认默认取消
- snapshot 刷新后按 ID 保持选择
- 进度按 confirmedBytes 而非 queuedBytes
- 100% awaitingDevice 不渲染成功
- stateUnknown 不渲染为 failed 或 succeeded
- authkey 不出现在渲染 buffer、日志、异常和 fixture snapshot
- dispose 恰好调用一次
- 终端状态在正常退出、异常和信号路径均恢复

十五、允许修改和禁止修改的文件

允许：

- tui/lib/src/frontend/**
- tui/test/frontend/** 或等价的前端测试目录
- facade 已存在时，为正式接入所需的薄前端 adapter
- facade 已存在且契约满足时，tui/bin/wristload_tui.dart 的前端启动接线
- tui/pubspec.yaml 中最小必要的前端依赖
- tui/FACADE_GAP.md
- tui/FRONTEND_IMPLEMENTATION_NOTES.md
- 明确标注为 fake 的开发 preview

禁止：

- 根目录 lib/**、macos/**、plugins/**、根 pubspec.yaml 和根测试
- tui/lib/src/backend/**
- tui/lib/src/domain/** 和 tui/lib/src/domain/protocol/**
- tui/lib/src/transport/**
- tui/macos_bridge/**
- tui/lib/src/facade/** 的生产实现
- 为规避缺失接口而扩展 public exports
- 删除或改写本提示词、README 或上游来源记录

如果实际 facade 文件与前端改动存在冲突，停止修改该文件并记录缺口，不要覆盖后端作者的工作。

十六、实现顺序

1. 阅读指定文档和实际 public API，确认工作树状态。
2. 列出 facade 已具备和缺失的契约；必要时创建 FACADE_GAP.md。
3. 选择或确认 TUI 库，说明 Unicode/resize/终端恢复能力。
4. 建立 TuiFrontendPort、fake 和 fixture（若正式 facade 已存在，可由薄 adapter 实现 port）。
5. 先完成终端生命周期、输入分发、焦点和 cell-width 基础。
6. 按设备、队列、任务/恢复、设置、日志顺序实现页面。
7. 加入所有危险确认、authkey 安全处理和 allowedActions 门控。
8. 完成 fixture 驱动的键盘、渲染、并发和终端恢复测试。
9. facade 已存在时接正式入口；不存在时只提供明确标注的 fake preview。
10. 运行格式化、静态分析和测试，逐项修复。

建议验证命令：

    cd tui
    dart pub get
    dart format --output=none --set-exit-if-changed lib bin test
    dart analyze
    dart test

如果当前环境无法运行 Dart，明确报告具体命令、错误和未验证范围；不要写“应该通过”。不需要也不得伪造真机结果。

十七、交付与最终报告

最终交付必须包括：

- 完整前端源码和测试
- facade 存在时的正式接线，或 facade 缺失时可运行的 fake preview
- FACADE_GAP.md（只在有真实缺口时）
- FRONTEND_IMPLEMENTATION_NOTES.md，包含依赖选择、目录、快捷键、运行方式、fixture 和已知限制
- 格式化、analyze、test 的真实结果
- 60x20、80x24、100x30、120x40 的验证结果
- 明确列出未做的真机验证

最终报告先说明结果，再说明修改文件、测试结果和仍需后端提供的接口。不要提交、push、创建 PR，也不要修改本任务范围外的文件。

完成标准不是“画出了几个页面”，而是：所有页面都可由键盘访问；所有状态都来自 facade/fake 的原子快照；每个动作都受 allowedActions 门控；authkey 不泄露；100% ACK 不冒充成功；状态未知得到保留；终端在所有退出路径恢复；窄终端和中文宽度经过测试；生产前端没有访问任何 backend、transport、bridge 或 protocol 内部。

END PROMPT
~~~~
