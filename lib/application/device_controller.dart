import 'dart:async';
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../domain/device_profile.dart';
import '../domain/install_task.dart';
import '../domain/protocol/auth_handshake.dart';
import '../domain/protocol/l1_l2_frame.dart';
import '../domain/protocol/spp_protocol.dart';
import '../domain/wear_protocol.dart';
import '../platform/ble_transport.dart';
import '../platform/windows_toast.dart';

class DeviceController extends ChangeNotifier {
  DeviceController({BleTransport? transport, WearProtocol? protocol})
      : _transport = transport ?? BleTransport(),
        _protocol = protocol ?? UnverifiedWearProtocol();

  final BleTransport _transport;
  WearProtocol _protocol;
  StreamSubscription<DiscoveredEventArgs>? _scanSubscription;
  bool _isScanning = false;

  List<DiscoveredEventArgs> scanResults = const [];
  Peripheral? connectedDevice;
  Peripheral? _lastPeripheral;
  List<GATTService> services = const [];
  DeviceCapabilities capabilities = const DeviceCapabilities();
  InstallTask? latestTask;
  String? error;
  bool sessionReady = false;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _lastNotifyListener;
  Timer? _notifyWatchdog;

  /// L1START 试错变体（0=标准 1=seq1 2=最小 3=写5e 4=小MPS 5=空DATA）。
  int l1StartVariant = 0;

  void setL1StartVariant(int variant) {
    l1StartVariant = variant;
    _log('L1START 变体切换为：${variantName(variant)}');
    notifyListeners();
  }

  static String variantName(int variant) => switch (variant) {
        0 => '标准（官方载荷）',
        1 => 'seq=1',
        2 => '最小载荷（VERSION+MPS）',
        3 => '写 5e 特征',
        4 => '小 MPS=247',
        5 => '空 DATA 帧探测',
        _ => '变体 $variant',
      };

  /// authkey（绑定 token，32 位 hex = 16 字节）。连接前由 UI 弹窗输入。
  /// 校验规则：32 位十六进制字符。协议验证通过前只保存、不发送鉴权帧。
  String? authKey;

  /// 运行日志（时间戳 + 消息），供真机验证时观察 BLE/协议行为。
  List<String> logs = const [];

  static final RegExp _authKeyPattern = RegExp(r'^[0-9a-fA-F]{32}$');

  bool get isConnected => connectedDevice != null;

  bool get hasAuthKey => authKey != null;

  /// n67cn 官方日志已确认的 SPP + authkey 会话入口；安装能力不包含在内。
  /// SPP 鉴权只依赖用户提供的 authkey，不要求小米账号登录。
  bool get canStartSppAuth =>
      isConnected && hasAuthKey && kSppAuthProtocolVerified;

  void _log(String message) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    logs = [...logs, '[$ts] $message'];
    notifyListeners();
  }

  void clearLogs() {
    logs = const [];
    notifyListeners();
  }

  /// 校验并保存 authkey。返回是否成功；失败时设置 [error] 并记录日志。
  bool setAuthKey(String key) {
    final trimmed = key.trim();
    if (!_authKeyPattern.hasMatch(trimmed)) {
      error = 'authkey 必须是 32 位十六进制字符（收到 ${trimmed.length} 个字符）';
      _log('authkey 输入无效：${trimmed.length} 个字符');
      notifyListeners();
      return false;
    }
    authKey = trimmed.toLowerCase();
    _log('authkey 已保存：${trimmed.substring(0, 4)}…${trimmed.substring(28)} '
        '（32 hex，16 字节）');
    return true;
  }

  Future<void> beginScan() async {
    if (_isScanning) {
      _log('BLE 扫描已在进行，忽略重复请求。');
      return;
    }
    error = null;
    scanResults = const [];
    _log('开始 BLE 扫描…');
    await _scanSubscription?.cancel();
    _scanSubscription = _transport.discoveries.listen((result) {
      final index = scanResults
          .indexWhere((item) => item.peripheral == result.peripheral);
      final mutable = [...scanResults];
      if (index < 0) {
        mutable.add(result);
      } else {
        mutable[index] = result;
      }
      scanResults = mutable;
      notifyListeners();
    }, onError: (Object value) {
      _isScanning = false;
      error = '扫描失败：$value';
      _log('扫描失败：$value');
      notifyListeners();
    });
    try {
      await _transport.startScan();
      _isScanning = true;
      _log('扫描已启动（点击连接仅进行安全的 GATT 服务枚举）。');
    } catch (exception) {
      _isScanning = false;
      error = '启动扫描失败：$exception';
      _log(error!);
      notifyListeners();
    }
  }

  Future<void> connect(DiscoveredEventArgs result) async {
    if (!hasAuthKey) {
      error = '连接被拒绝：请输入 32 位 authkey 以进行设备身份校验。';
      _log(error!);
      notifyListeners();
      return;
    }
    await _connectPeripheral(result.peripheral);
  }

  /// 先建立 GATT 链路，再进入经验证的应用层 authkey 鉴权。
  Future<void> _connectPeripheral(Peripheral peripheral) async {
    error = null;
    sessionReady = false;
    _log('正在连接 ${peripheral.uuid}（authkey 已就绪，等待应用层身份校验）…');
    try {
      await _transport.stopScan();
      _isScanning = false;
      services = await _transport.connectAndDiscover(peripheral);
      connectedDevice = peripheral;
      _lastPeripheral = peripheral;
      _log('GATT 已连接，发现 ${services.length} 个服务：');
      for (final service in services) {
        _log('  服务 ${service.uuid}');
      }
      await _inspectMiWearService();
      capabilities = await _protocol.queryCapabilities();
      _log('能力查询（占位实现）完成：watchface=${capabilities.watchface}，'
          'thirdPartyApp=${capabilities.thirdPartyApp}');
      _log('GATT 链路已建立。应用层 authkey 身份校验尚待真机帧验证，'
          '私有帧仍受安全门控保护，当前未宣称“设备已就绪”。');
    } catch (exception) {
      error = '连接或发现服务失败：$exception';
      _log('连接失败：$exception');
      _log('提示：GattCommunicationStatus=1 表示设备不可达（Unreachable）——'
          '常见于 Windows 蓝牙缓存/bonding 损坏。建议：手环亮屏并靠近电脑，'
          'Windows「设置→蓝牙」删除该设备记录后重新扫描连接，或重启 Windows 蓝牙。');
      _log('不会在 GATT 失败后回退发送 RFCOMM 协议帧；请先完成 HCI 验证。');
    }
    notifyListeners();
  }

  /// 检查 MI Wear 服务（0000fe95）的特征明细，并尝试读取版本特征
  /// 00000050（只读，不发送任何私有帧），用于对照逆向结论并判定 V1/V2。
  Future<void> _inspectMiWearService() async {
    const fe95 = '0000fe95-0000-1000-8000-00805f9b34fb';
    const versionUuid = '00000050-0000-1000-8000-00805f9b34fb';
    const notifyUuid = '0000005e-0000-1000-8000-00805f9b34fb';
    const writeUuid = '0000005f-0000-1000-8000-00805f9b34fb';
    GATTService? miService;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == fe95) {
        miService = service;
        break;
      }
    }
    if (miService == null) {
      _log('警告：未发现 MI Wear 服务 $fe95');
      return;
    }
    final chars = miService.characteristics;
    _log('MI Wear 服务 fe95 特征（${chars.length}）：');
    for (final characteristic in chars) {
      final uuid = characteristic.uuid.toString().toLowerCase();
      final role = switch (uuid) {
        versionUuid => ' ← 版本特征',
        notifyUuid => ' ← 通知特征',
        writeUuid => ' ← 写入特征',
        _ => '',
      };
      final properties =
          characteristic.properties.map((property) => property.name).join('|');
      _log('    特征 $uuid$role  属性: $properties');
    }
    GATTCharacteristic? versionChar;
    for (final characteristic in chars) {
      if (characteristic.uuid.toString().toLowerCase() == versionUuid) {
        versionChar = characteristic;
        break;
      }
    }
    final device = connectedDevice;
    if (versionChar == null || device == null) {
      _log('未找到版本特征 $versionUuid（不发送任何帧）');
      return;
    }
    try {
      final data = await _transport.readCharacteristic(device, versionChar);
      final hex =
          data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      if (data.length >= 3) {
        final version = '${data[0]}.${data[1]}.${data[2]}';
        final generation = data[0] == 0 ? 'V1（旧传输）' : 'V2（新传输）';
        _log('版本特征 $versionUuid = $hex → 固件 $version → $generation');
        // 将设备代际信息流转到协议层（能力门控使用）。
        const profile = DeviceProfile(
          family: DeviceFamily.unknown,
          displayName: 'Unknown Band',
          modelHints: {},
          capabilities: DeviceCapabilities(),
        );
        _protocol = UnverifiedWearProtocol(deviceProfile: profile);
      } else {
        _log('版本特征 $versionUuid = $hex（不足 3 字节）');
      }
    } catch (exception) {
      _log('版本特征读取失败：$exception');
    }
  }

  /// 发送鉴权 step1（`Command{type=1, subtype=26, auth{phoneNonce}}`）。
  /// [writeToNotifyChar] 为 true 时写入 5e（5e/5f 均可写，手环 9 命令通道未定）。
  /// 设备应回 `watchNonce`（5e 通知），收到后派生 step3 密钥并校验 HMAC。
  Future<void> sendAuthStep1({bool writeToNotifyChar = false}) async {
    if (!_ensurePrivateProtocolEnabled('鉴权 step1')) return;
    final device = connectedDevice;
    if (device == null) {
      _log('鉴权被拒绝：未连接设备');
      return;
    }
    GATTCharacteristic? writeChar;
    GATTCharacteristic? notifyChar;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != SarGatt.serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.toString().toLowerCase();
        if (uuid == SarGatt.writeUuid) writeChar = characteristic;
        if (uuid == SarGatt.notifyUuid) notifyChar = characteristic;
      }
    }
    if (writeChar == null || notifyChar == null) {
      _log('鉴权被拒绝：未找到写/通知特征（fe95）');
      return;
    }
    try {
      await _transport.setNotify(device, notifyChar, state: true);
      _log('已开启通知特征 $SarGatt.notifyUuid');
      _lastNotifyListener?.cancel();
      _lastNotifyListener = _transport.characteristicNotified.listen(
        (event) {
          if (event.peripheral != device) return;
          _handleAuthNotification(event.value);
        },
        onError: (Object value) => _log('通知流错误：$value'),
      );
      // 16B 随机 nonce
      final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
      final command = XiaomiAuth.buildNonceCommand(nonce);
      _pendingPhoneNonce = nonce;
      final target = writeToNotifyChar ? notifyChar : writeChar;
      final targetUuid =
          writeToNotifyChar ? SarGatt.notifyUuid : SarGatt.writeUuid;
      _log('发送鉴权 step1（f=26，phoneNonce=${_hex(nonce)}，'
          '${command.length}B protobuf，直写 $targetUuid）：${_hex(command)}');
      await _transport.write(device, target, command, withResponse: true);
      _log('已写入，等待设备 watchNonce 回包…');
      _notifyWatchdog?.cancel();
      _notifyWatchdog = Timer(const Duration(seconds: 12), () {
        _log('监听结束：12 秒内无设备回包（试写 5e 或 f=5）');
      });
    } catch (exception) {
      _log('鉴权 step1 发送失败：$exception');
    }
  }

  /// 发送明文鉴权（`Command{type=1, subtype=5, auth{userId}}`，WearAuthV1 风格）。
  Future<void> sendSendUserId({bool writeToNotifyChar = false}) async {
    if (!_ensurePrivateProtocolEnabled('明文鉴权')) return;
    final device = connectedDevice;
    if (device == null) {
      _log('鉴权被拒绝：未连接设备');
      return;
    }
    GATTCharacteristic? writeChar;
    GATTCharacteristic? notifyChar;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != SarGatt.serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.toString().toLowerCase();
        if (uuid == SarGatt.writeUuid) writeChar = characteristic;
        if (uuid == SarGatt.notifyUuid) notifyChar = characteristic;
      }
    }
    if (writeChar == null || notifyChar == null) {
      _log('鉴权被拒绝：未找到写/通知特征（fe95）');
      return;
    }
    try {
      await _transport.setNotify(device, notifyChar, state: true);
      _lastNotifyListener?.cancel();
      _lastNotifyListener = _transport.characteristicNotified.listen(
        (event) {
          if (event.peripheral != device) return;
          _handleAuthNotification(event.value);
        },
        onError: (Object value) => _log('通知流错误：$value'),
      );
      final userId = authKey ?? '';
      final command = XiaomiAuth.buildSendUserIdCommand(userId);
      final target = writeToNotifyChar ? notifyChar : writeChar;
      final targetUuid =
          writeToNotifyChar ? SarGatt.notifyUuid : SarGatt.writeUuid;
      _log(
          '发送明文鉴权（f=5，userId=${_redact(userId)}，直写 $targetUuid）：${_hex(command)}');
      await _transport.write(device, target, command, withResponse: true);
      _log('已写入，等待设备响应…');
      _notifyWatchdog?.cancel();
      _notifyWatchdog = Timer(const Duration(seconds: 12), () {
        _log('监听结束：12 秒内无设备回包');
      });
    } catch (exception) {
      _log('明文鉴权发送失败：$exception');
    }
  }

  /// 触发 Windows 系统配对（bonding）。手环 9 写入特征要求加密连接：
  /// 未配对时写入被设备静默丢弃（read 成功、write 无回包）。配对后
  /// 连接将加密，写入才会被接受。等价 Android 端首次"绑定"确认。
  Future<void> pairDevice() async {
    final device = connectedDevice;
    if (device == null) {
      _log('配对被拒绝：未连接设备');
      return;
    }
    _log('触发 Windows 系统配对（bonding）：${device.uuid}…');
    _log('  （请留意 Windows 弹出的配对/确认窗口，可能需要输入 0000）');
    unawaited(WindowsToast.instance
        .show('正在请求配对', '请在 Windows 弹出的窗口中确认与手环配对（可能需要输入 PIN 0000）'));
    try {
      await _transport.pairDevice(device.uuid);
      _log('配对完成：设备已 bonding');
      unawaited(
          WindowsToast.instance.show('配对完成', '手环已与电脑 bonding，正在重连以启用加密链路'));
      // bonding 后当前 GATT 连接可能仍是非加密的——必须断开重连，
      // Windows 才会用加密链路重新连接（未加密写入被设备丢弃）。
      _log('配对完成。正在断开并重连（bonding 后写入才被设备接受）…');
      try {
        await _transport.disconnect(device);
      } catch (_) {
        // 忽略断开失败。
      }
      connectedDevice = null;
      await Future.delayed(const Duration(milliseconds: 800));
      if (_lastPeripheral != null) {
        await _connectPeripheral(_lastPeripheral!);
      }
    } catch (exception) {
      _log('配对失败：$exception');
      unawaited(WindowsToast.instance.show('配对失败', '请重试，或在 Windows 设置中手动添加设备'));
      _log('  提示：可尝试在 Windows「设置 → 蓝牙和其他设备 → 添加设备」手动配对');
    }
  }

  /// SPP（经典蓝牙 RFCOMM）连接 + 鉴权握手——手环 9 系主通道。
  ///
  /// 流程（与 App/Gadgetbridge 一致）：
  /// RFCOMM 连接 → SessionConfig(START_SESSION) → 设备回 SessionConfig →
  /// 发 f=26（DATA 明文帧）→ 设备回 watchNonce → 完成 step1。
  Future<void> connectSpp() async {
    if (!kSppAuthProtocolVerified) {
      _log('SPP 鉴权被阻止：尚未完成真机验证。');
      return;
    }
    // SPP 主通道独立于 GATT：GATT 成功时用 connectedDevice，
    // GATT 失败回退时用 _lastPeripheral（仅需 MAC）。
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null) {
      _log('SPP 连接被拒绝：未连接设备');
      return;
    }
    _log('SPP（RFCOMM 串口）连接：${device.uuid}…');
    _sppAcc = Accumulator();
    _sppSeq = 0;
    _sppL1FallbackStarted = false;
    try {
      _transport.listenRfcommData();
      _sppSub ??= _transport.rfcommData.listen(_handleSppData);
      _log('正在建立经典蓝牙 RFCOMM 链路（仅在 Windows 尚未配对时请求 pairing）…');
      _log('  若手环屏幕弹出配对请求，请在手环上确认；不会自动解绑已有配对。');
      await _transport.connectRfcomm(device.uuid);
      _log('RFCOMM 已连接。发送 SPP 版本查询（SppPacket，App SppVersionReader 前置）…');
      final versionQuery = SppProtocol.buildVersionQuery(_sppVersionSeq++);
      _log('  版本查询：${_hex(versionQuery)}');
      await _transport.rfcommWrite(device.uuid, versionQuery);
      _sppAwaitingVersion = true;
      _log('已发送版本查询，等待设备版本回包…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 8), () {
        _log('SPP 超时：8 秒内无版本回包');
        _sppAwaitingVersion = false;
        if (!_sppL1FallbackStarted) {
          _sppL1FallbackStarted = true;
          _log('版本探测未回包，回退发送一次 L1START 会话协商帧…');
          unawaited(_sppSendL1Start());
        }
      });
    } catch (exception) {
      _log('SPP 连接失败：$exception');
    }
  }

  StreamSubscription<Uint8List>? _sppSub;
  Accumulator _sppAcc = Accumulator();
  int _sppSeq = 0;
  // Official b1r.b() increments before returning, so a new process starts at 1.
  int _sppVersionSeq = 1;
  bool _sppAwaitingVersion = false;
  bool _sppL1FallbackStarted = false;
  Timer? _sppWatchdog;

  /// 处理 RFCOMM 收到的字节：先试 SppPacket（版本回包），再增量解析 L1 帧。
  void _handleSppData(Uint8List data) {
    _log('RFCOMM 收到 ${data.length}B：${_hex(data)}');
    if (_sppAwaitingVersion) {
      final packet = SppProtocol.parseSppPacket(data);
      if (packet != null) {
        _sppAwaitingVersion = false;
        final (type, payload) = packet;
        _log('SppPacket 回包：type=$type payload=${_hex(payload)}');
        if (type == 106) {
          _log('  ★ 设备版本：'
              '${payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join('.')}');
          _log('版本确认。发送 L1START_REQ（L1 CMD 帧）…');
          unawaited(_sppSendL1Start());
        } else {
          _log('  非版本回包（type=$type），仍尝试 L1START…');
          unawaited(_sppSendL1Start());
        }
        _sppL1FallbackStarted = true;
        return;
      }
    }
    _sppAcc.buffer = [..._sppAcc.buffer, ...data];
    final packets = SppProtocol.parse(_sppAcc);
    for (final packet in packets) {
      _handleSppPacket(packet);
    }
  }

  Future<void> _sppSendL1Start() async {
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null) return;
    final start = SppProtocol.buildL1StartRequest();
    _log('  L1START_REQ：${_hex(start)}');
    try {
      await _transport.rfcommWrite(device.uuid, start);
      _log('已发送 L1START_REQ，等待设备 L1START_RSP…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        _log('SPP 超时：15 秒内无 L1START_RSP');
      });
    } catch (exception) {
      _log('L1START 发送失败：$exception');
    }
  }

  void _handleSppPacket(SppPacket packet) {
    switch (packet.type) {
      case SppProtocol.typeCmd:
        final cmd = packet.payload.isEmpty ? -1 : packet.payload[0];
        _log('SPP CMD 帧：cmd=$cmd（1=L1START_REQ 2=L1START_RSP），'
            'payload=${_hex(packet.payload)}');
        if (cmd == SppProtocol.cmdL1StartRsp) {
          _log('L1START_RSP 收到——L1 会话建立！发送官方鉴权 f=26（DATA 明文帧）…');
          unawaited(_sppSendAuthStep1());
        }
        break;
      case SppProtocol.typeData:
        _log('SPP DATA 帧（seq=${packet.seq}）：payload=${_hex(packet.payload)}');
        // 回 ACK
        unawaited(_sppSendAck(packet.seq));
        _handleSppDataPacket(packet);
        break;
      case SppProtocol.typeAck:
        _log('SPP ACK（seq=${packet.seq}）');
        break;
      default:
        _log('SPP 未知帧 type=${packet.type}：${_hex(packet.payload)}');
    }
  }

  /// DATA 帧：channel + opCode + data。解析 Command protobuf。
  void _handleSppDataPacket(SppPacket packet) {
    if (packet.payload.length < 2) {
      _log('SPP DATA 帧过短');
      return;
    }
    final channel = packet.payload[0] & 0x0f;
    final opCode = packet.payload[1];
    final data = packet.payload.sublist(2);
    _log('  DATA channel=$channel opCode=$opCode data=${_hex(data)}');
    final parsed = XiaomiAuth.parse(data);
    if (parsed != null) {
      _log('  Command：type=${parsed.type} subtype=${parsed.subtype} '
          'watchNonce=${parsed.watchNonce != null}');
      if (parsed.watchNonce != null && _pendingPhoneNonce != null) {
        _log('  收到设备随机数与签名，开始本地验签后自动发送 f=27 sendAppConfirm…');
        unawaited(_sppSendAuthConfirm(
          phoneNonce: _pendingPhoneNonce!,
          watchNonce: parsed.watchNonce!,
          watchHmac: parsed.watchHmac ?? const [],
        ));
      } else if (parsed.subtype == 27) {
        // f=27 响应：设备确认（kc0{success, capability}）→ device ready。
        final confirmed = parsed.authStatus == 1;
        if (confirmed) {
          sessionReady = true;
          _sppWatchdog?.cancel();
          _sppWatchdog = null;
        }
        _log('  f=27 设备响应（confirmed=$confirmed，status=${parsed.status}）');
        _log(confirmed
            ? '  ★ 鉴权完成（device ready）——会话密钥已建立；安装功能仍未开放'
            : '  ✕ 设备未确认鉴权，未将连接标记为就绪');
      }
    } else {
      _log('  无法按 Xiaomi Command 解析');
    }
  }

  Future<void> _sppSendAuthConfirm({
    required List<int> phoneNonce,
    required List<int> watchNonce,
    required List<int> watchHmac,
  }) async {
    final device = connectedDevice;
    if (device == null) return;
    final secretKey = XiaomiAuth.secretKeyFromHex(authKey ?? '');
    if (secretKey == null) {
      _log('f=27 被拒绝：authkey 无效');
      return;
    }
    final cmd = XiaomiAuth.buildAuthStep3Command(
      secretKey: secretKey,
      phoneNonce: phoneNonce,
      watchNonce: watchNonce,
      watchHmac: watchHmac,
    );
    if (cmd == null) {
      _log('  ✗ 设备签名校验失败（HMAC 不匹配——authkey 与设备不匹配？）');
      return;
    }
    final frame = SppProtocol.buildDataFrame(_sppSeq++, cmd);
    _log('发送 f=27（seq=${_sppSeq - 1}，${frame.length}B）：${_hex(frame)}');
    try {
      await _transport.rfcommWrite(device.uuid, frame);
      _log('f=27 已写入，等待设备确认（device ready）…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        _log('SPP 超时：15 秒内无 f=27 响应');
      });
    } catch (exception) {
      _log('f=27 发送失败：$exception');
    }
  }

  Future<void> _sppSendAuthStep1() async {
    final device = connectedDevice;
    if (device == null) return;
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    _pendingPhoneNonce = nonce;
    final command =
        XiaomiAuth.buildNonceCommand(nonce);
    final frame = SppProtocol.buildDataFrame(_sppSeq++, command);
    _log('发送 f=26（seq=${_sppSeq - 1}，${frame.length}B）：${_hex(frame)}');
    try {
      await _transport.rfcommWrite(device.uuid, frame);
      _log('f=26 已写入，等待设备 watchNonce…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        _log('SPP 超时：15 秒内无 watchNonce');
      });
    } catch (exception) {
      _log('f=26 发送失败：$exception');
    }
  }

  Future<void> _sppSendAck(int seq) async {
    final device = connectedDevice;
    if (device == null) return;
    try {
      await _transport.rfcommWrite(device.uuid, SppProtocol.buildAck(seq));
    } catch (exception) {
      _log('ACK 发送失败：$exception');
    }
  }

  List<int>? _pendingPhoneNonce;
  final _random = Random();

  /// 处理设备通知：尝试按 Xiaomi Command 解析并完成 step3 密钥派生。
  void _handleAuthNotification(Uint8List data) {
    _log('设备通知（$SarGatt.notifyUuid）：${_hex(data)}');
    final parsed = XiaomiAuth.parse(data);
    if (parsed == null) {
      _log('  （无法按 Xiaomi Command 解析，可能是其它通知）');
      _describeL1Frame(data);
      return;
    }
    final sub = parsed.subtype;
    if (sub == XiaomiAuth.cmdNonce && parsed.watchNonce != null) {
      _log('  ← 设备回包 watchNonce（f=26 响应）');
      _log('    watchNonce=${_hex(parsed.watchNonce!)}');
      _log('    watchHmac =${_hex(parsed.watchHmac ?? const [])}');
      final phoneNonce = _pendingPhoneNonce;
      final authKeyHex = authKey;
      if (phoneNonce != null && authKeyHex != null) {
        final secretKey = XiaomiAuth.secretKeyFromHex(authKeyHex);
        if (secretKey == null) {
          _log('  authkey 无法解析为 16 字节（跳过 step3）');
          return;
        }
        final hkdf = XiaomiAuth.computeStep3Hmac(
            secretKey, phoneNonce, parsed.watchNonce!);
        _log('  step3 密钥派生（HKDF "miwear-auth"）：'
            'decKey=${_hex(hkdf.sublist(0, 16))} encKey=${_hex(hkdf.sublist(16, 32))} '
            'decNonce=${_hex(hkdf.sublist(32, 36))} encNonce=${_hex(hkdf.sublist(36, 40))}');
        final hmac = parsed.watchHmac;
        if (hmac != null && hmac.isNotEmpty) {
          final expected = XiaomiAuth.hmacSha256(
            hkdf.sublist(0, 16),
            [...parsed.watchNonce!, ...phoneNonce],
          );
          final ok = _bytesEqual(expected, hmac);
          _log(ok
              ? '  ✅ 设备 HMAC 校验通过 —— 手环 9 确认使用直写 protobuf 鉴权！'
              : '  ❌ HMAC 不匹配（expected=${_hex(expected)}）');
        }
      } else {
        _log('  未保存 phoneNonce 或 authkey，无法派生 step3（可点按钮重发）');
      }
    } else if (sub == XiaomiAuth.cmdSendUserId) {
      _log('  ← 设备回 userId 确认（f=5）');
    } else if (sub == XiaomiAuth.cmdAuth) {
      _log('  ← 设备回 AuthStep3 状态（f=27）：status=${parsed.authStatus}');
    } else {
      _log(
          '  ← Command type=${parsed.type} subtype=$sub status=${parsed.status}');
    }
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  String _redact(String value) {
    if (value.length <= 8) return '<已隐藏>';
    return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 发送 L1START 握手帧（实验性，仅验证 SAR 链路，不发业务数据）。
  /// [auto] 为 true 表示连接成功后自动触发；[variant] 选择试错变体
  /// （0=标准 1=seq1 2=最小载荷 3=写5e 4=小MPS 5=空DATA帧）。
  Future<void> sendL1Start({bool auto = false, int variant = 0}) async {
    if (!_ensurePrivateProtocolEnabled('L1START')) return;
    final device = connectedDevice;
    if (device == null) {
      _log('L1START 被拒绝：未连接设备');
      return;
    }
    GATTCharacteristic? writeChar;
    GATTCharacteristic? notifyChar;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != SarGatt.serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.toString().toLowerCase();
        if (uuid == SarGatt.writeUuid) writeChar = characteristic;
        if (uuid == SarGatt.notifyUuid) notifyChar = characteristic;
      }
    }
    if (writeChar == null || notifyChar == null) {
      _log('L1START 被拒绝：未找到写/通知特征（fe95）');
      return;
    }
    try {
      // 5e 与 5f 都声明了 notify 属性——设备回包可能走任意一个，双订阅。
      await _transport.setNotify(device, notifyChar, state: true);
      if (writeChar.uuid != notifyChar.uuid) {
        await _transport.setNotify(device, writeChar, state: true);
        _log('已开启通知特征 $SarGatt.notifyUuid 与写入特征（双订阅）');
      } else {
        _log('已开启通知特征 $SarGatt.notifyUuid');
      }
      _lastNotifyListener?.cancel();
      _lastNotifyListener = _transport.characteristicNotified.listen(
        (event) {
          if (event.peripheral != device) return;
          _log('设备通知（${event.characteristic.uuid}）：'
              '${event.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
          _describeL1Frame(event.value);
        },
        onError: (Object value) => _log('通知流错误：$value'),
      );
      final frame = L1StartRequest.buildVariant(variant);
      final bytes = frame.encode();
      // variant 3：写到 5e（通知特征同时可写）
      final targetChar = variant == 3 ? notifyChar : writeChar;
      final targetName = variant == 3 ? SarGatt.notifyUuid : SarGatt.writeUuid;
      _log('${auto ? '（自动）' : ''}[变体$variant→$targetName] 发送 '
          '${frame.type == L1Type.data ? 'DATA' : 'L1START'}（${bytes.length}B）：'
          '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      await _transport.write(device, targetChar, bytes, withResponse: true);
      _log('已写入，持续监听设备通知（15 秒）…');
      _notifyWatchdog?.cancel();
      _notifyWatchdog = Timer(const Duration(seconds: 15), () {
        _log('监听结束：15 秒内无设备通知（设备未响应，试其它变体）');
      });
    } catch (exception) {
      _log('L1START 发送失败：$exception');
    }
  }

  /// 解析并描述设备回包中的 L1 帧（cmd/ack/data）。
  void _describeL1Frame(Uint8List data) {
    final frame = L1Frame.parse(data);
    if (frame == null) {
      _log('  （无法按 L1 帧解析，可能是分片或非 L1 数据）');
      return;
    }
    final typeName = switch (frame.type) {
      L1Type.ack => 'ACK',
      L1Type.nak => 'NAK',
      L1Type.cmd => 'CMD',
      L1Type.data => 'DATA',
      _ => 'type=${frame.type}',
    };
    final details = StringBuffer(
        '  L1 $typeName frx=${frame.frx} seq=${frame.seqNum} '
        'len=${frame.payload.length} crc=${frame.crc.toRadixString(16).padLeft(4, '0')}');
    if (frame.payload.isNotEmpty) {
      details.write(' payload='
          '${frame.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      if (frame.type == L1Type.cmd) {
        final cmd = frame.payload.first;
        final cmdName = switch (cmd) {
          L1Cmd.startReq => 'L1START_REQ',
          L1Cmd.startRsp => 'L1START_RSP',
          L1Cmd.stopReq => 'L1STOP_REQ',
          L1Cmd.stopRsp => 'L1STOP_RSP',
          _ => 'cmd=$cmd',
        };
        details.write(' ← $cmdName');
      }
    }
    _log(details.toString());
  }

  Future<void> disconnect() async {
    final device = connectedDevice;
    if (device != null) {
      await _transport.disconnect(device);
      _log('已断开 ${device.uuid}');
    }
    connectedDevice = null;
    sessionReady = false;
    _isScanning = false;
    services = const [];
    capabilities = const DeviceCapabilities();
    notifyListeners();
  }

  Future<void> startInstall(InstallKind kind, String path) async {
    if (!isConnected) {
      error = '请先连接设备。';
      _log('安装被拒绝：未连接设备');
      notifyListeners();
      return;
    }
    final kindName = kind == InstallKind.watchface ? '表盘 .bin' : '快应用 .rpk';
    _log('选择 $kindName：$path');
    final stream = kind == InstallKind.watchface
        ? _protocol.installWatchface(path)
        : _protocol.installQuickApp(path);
    await for (final task in stream) {
      latestTask = task;
      _log('安装任务：${task.stage.name} — ${task.message}');
      notifyListeners();
    }
  }

  /// Private Xiaomi frames must never become reachable by accident. BLE device
  /// discovery is safe, but protocol traffic requires real-device validation.
  bool _ensurePrivateProtocolEnabled(String action) {
    if (kProtocolVerified) return true;
    error = '$action 被安全门控阻止：尚未完成真机 HCI 验证。';
    _log(error!);
    notifyListeners();
    return false;
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _lastNotifyListener?.cancel();
    _notifyWatchdog?.cancel();
    super.dispose();
  }
}
