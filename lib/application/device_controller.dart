import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/device_profile.dart';
import '../domain/install_models.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_task.dart';
import '../domain/mass_ack_idle_timeout.dart';
import '../domain/transfer_settings_store.dart';
import '../domain/protocol/auth_handshake.dart';
import '../domain/protocol/session_cipher.dart';
import '../domain/protocol/spp_protocol.dart';
import '../domain/protocol/mass_transfer.dart';
import '../domain/protocol/zau.dart';
import '../domain/protocol/transport_constants.dart';
import '../domain/verification_gate.dart';
import '../platform/ble_transport.dart';
import '../platform/auth_key_store.dart';
import '../platform/system_time_info.dart';

typedef QueueInstallPreparer = Future<InstallRequest?> Function(
  InstallRequest request,
);

class DeviceController extends ChangeNotifier {
  DeviceController({BleTransport? transport})
      : _transport = transport ?? BleTransport() {
    unawaited(_restoreAuthKey());
    _transferSettingsReady = _restoreTransferSettings();
  }

  final BleTransport _transport;
  late final Future<void> _transferSettingsReady;
  bool _disposed = false;
  StreamSubscription<DiscoveredEventArgs>? _scanSubscription;
  bool _isScanning = false;
  Timer? _scanResultsFlushTimer;
  final Map<String, DiscoveredEventArgs> _pendingScanResults = {};

  List<DiscoveredEventArgs> scanResults = const [];
  Peripheral? connectedDevice;
  String? connectedDeviceName;
  DeviceProfile? connectedProfile;
  Peripheral? _lastPeripheral;
  List<GATTService> services = const [];
  InstallTask? latestTask;

  /// 固件版本（从版本特征读取，如 2.1.2）。
  String? connectedFirmwareVersion;

  /// 设备电量（%），连接后随状态查询获取；null 表示未取到（UI 不渲染）。
  int? batteryPercent;

  /// 设备存储（字节），null 表示未取到。
  int? storageUsedBytes;
  int? storageTotalBytes;
  int _sessionEpoch = 0;
  int? _statusRefreshEpoch;

  bool get statusRefreshInProgress => _statusRefreshEpoch != null;

  void _advanceSessionEpoch() {
    _sessionEpoch++;
    _statusRefreshEpoch = null;
  }

  /// 安装队列（串行执行）。
  final List<QueueEntry> installQueue = [];
  bool _queueRunning = false;
  static const queueSuccessDisplayDuration = Duration(milliseconds: 2400);
  QueueInstallPreparer? queueInstallPreparer;

  bool get queueRunning => _queueRunning;

  int get pendingCount =>
      installQueue.where((e) => e.stage == QueueStage.waiting).length;
  int get installingCount =>
      installQueue.where((e) => e.stage == QueueStage.installing).length;

  /// 把安装请求加入队列，等待用户从队列页开始串行安装。
  void enqueue(InstallRequest request) {
    installQueue.add(QueueEntry(request: request));
    _log('已加入安装队列（当前待安装 $pendingCount 项）');
    notifyListeners();
  }

  /// 将失败、取消或状态未知的条目重新放回串行队列。
  ///
  /// 重试会重新发送同一安装包。MassPrepare 由设备返回可信的已发送
  /// 偏移，因此不会因为本地界面重试而强制从零开始。
  bool retryQueueEntry(QueueEntry entry) {
    if (!installQueue.contains(entry) ||
        entry.stage == QueueStage.installing ||
        !entry.canRetry) {
      return false;
    }
    unawaited(_retryQueueEntry(entry));
    return true;
  }

  Future<void> _retryQueueEntry(QueueEntry entry) async {
    entry
      ..stage = QueueStage.waiting
      ..message = null;
    notifyListeners();
    if (!await _restoreInstallSessionForRetry()) {
      if (installQueue.contains(entry) && entry.stage == QueueStage.waiting) {
        entry
          ..stage = QueueStage.stateUnknown
          ..message = '未能恢复鉴权会话；请重新连接设备后再次尝试安装。';
        notifyListeners();
      }
      return;
    }
    if (installQueue.contains(entry) && entry.stage == QueueStage.waiting) {
      await runQueue(preferredEntry: entry);
    }
  }

  /// 从队列移除（安装中禁止）。
  void removeQueueEntry(int index) {
    if (index < 0 || index >= installQueue.length) return;
    if (installQueue[index].stage == QueueStage.installing) return;
    installQueue.removeAt(index);
    notifyListeners();
  }

  /// 拖拽排序（安装中禁止）。
  void reorderQueue(int oldIndex, int newIndex) {
    if (installQueue.any((e) => e.stage == QueueStage.installing)) return;
    if (oldIndex < 0 || oldIndex >= installQueue.length) return;
    if (newIndex > installQueue.length) newIndex = installQueue.length;
    if (oldIndex < newIndex) newIndex--;
    final entry = installQueue.removeAt(oldIndex);
    installQueue.insert(newIndex, entry);
    notifyListeners();
  }

  /// 只清空已成功完成的条目，失败或取消项保留以便重试。
  void clearCompletedQueue() {
    installQueue.removeWhere((entry) => entry.stage == QueueStage.done);
    notifyListeners();
  }

  /// Dismisses the current installation summary without changing queue history.
  void clearLatestTask() {
    latestTask = null;
    notifyListeners();
  }

  /// 串行执行队列。
  Future<void> runQueue({QueueEntry? preferredEntry}) async {
    if (_queueRunning) return;
    _queueRunning = true;
    try {
      while (true) {
        // Normal queue execution pauses at any failed item. An explicit retry
        // may target that exact item even when older failure history remains.
        final preferred = preferredEntry != null &&
                installQueue.contains(preferredEntry) &&
                preferredEntry.stage == QueueStage.waiting
            ? preferredEntry
            : null;
        if (preferred == null && installQueue.any((entry) => entry.canRetry)) {
          break;
        }
        final next = preferred ??
            installQueue
                .where((e) => e.stage == QueueStage.waiting)
                .firstOrNull;
        if (next == null) break;
        preferredEntry = null;
        final preparer = queueInstallPreparer;
        if (preparer != null) {
          try {
            final prepared = await preparer(next.request);
            if (!installQueue.contains(next) ||
                next.stage != QueueStage.waiting) {
              break;
            }
            if (prepared == null) {
              // The user declined a required preflight confirmation. This is
              // an abandoned add-to-queue action, not a waiting installation.
              installQueue.remove(next);
              notifyListeners();
              continue;
            }
            next.request = prepared;
          } on Object catch (exception) {
            next.message = '安装前检查失败：$exception';
            _log(next.message!);
            notifyListeners();
            break;
          }
        }
        final taskBeforeInstall = latestTask;
        next.stage = QueueStage.installing;
        next.message = null;
        notifyListeners();
        await startInstall(next.request);
        final task = latestTask;
        final producedTask = task != null &&
            !identical(task, taskBeforeInstall) &&
            task.kind == next.request.kind &&
            task.fileName == next.request.metadata.fileName &&
            task.md5Hex == next.request.metadata.md5Hex;
        if (!producedTask) {
          next
            ..stage = QueueStage.waiting
            ..message = task?.message;
          notifyListeners();
          break;
        }
        if (task.stage == InstallStage.waitingForProtocol ||
            task.stage == InstallStage.idle ||
            task.stage == InstallStage.validating ||
            task.stage == InstallStage.transferring ||
            task.stage == InstallStage.awaitingDevice) {
          next
            ..stage = QueueStage.waiting
            ..message = task.message;
          notifyListeners();
          break;
        }
        next.stage = switch (task.stage) {
          InstallStage.succeeded => QueueStage.done,
          InstallStage.cancelled => QueueStage.cancelled,
          InstallStage.failed => QueueStage.failed,
          InstallStage.stateUnknown => QueueStage.stateUnknown,
          _ => QueueStage.failed,
        };
        next.message = task.message;
        if (next.isFailure) next.failureAttempts++;
        notifyListeners();

        if (next.stage == QueueStage.done) {
          await Future<void>.delayed(queueSuccessDisplayDuration);
          if (_disposed) break;
        }

        // A failed item is a deliberate pause point. Keep it in the queue and
        // let the user retry the same package as many times as necessary.
        if (next.isFailure) break;
      }
    } finally {
      _queueRunning = false;
      notifyListeners();
    }
  }

  String? error;
  bool sessionReady = false;
  bool sppConnecting = false;
  ConnectionMode connectionMode = ConnectionMode.modern;

  /// authkey（绑定 token，32 位 hex = 16 字节）。连接前由 UI 弹窗输入。
  /// 校验规则：32 位十六进制字符。协议验证通过前只保存、不发送鉴权帧。
  String? authKey;

  /// 运行日志（时间戳 + 消息），供真机验证时观察 BLE/协议行为。
  List<String> logs = const [];

  static final RegExp _authKeyPattern = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _secureStorage = AuthKeyStore();
  static final _transferSettings = TransferSettingsStore();

  /// Delay between consecutive Mass writes. The negotiated L1 receive window
  /// still limits outstanding packets, so a small value does not bypass flow
  /// control or ACK validation.
  int segmentIntervalMs = 5;
  int massWindowSize = 3;
  bool autoTimeSync = false;
  bool _autoTimeSyncChangedByUser = false;

  void _persistTransferSettings() {
    unawaited(_transferSettings.write(
      segmentIntervalMs: segmentIntervalMs,
      massWindowSize: massWindowSize,
      autoTimeSync: autoTimeSync,
    ));
  }

  void setAutoTimeSync(bool value) {
    if (autoTimeSync == value) return;
    _autoTimeSyncChangedByUser = true;
    autoTimeSync = value;
    _persistTransferSettings();
    _log('自动同步时间与时区已${value ? '开启' : '关闭'}。');
    notifyListeners();
    if (value && sessionReady && !installInProgress && !timeSyncInProgress) {
      unawaited(syncSystemTime(automatic: true));
    }
  }

  void setSegmentIntervalMs(int value) {
    final clamped = value.clamp(1, 20);
    if (segmentIntervalMs == clamped) return;
    segmentIntervalMs = clamped;
    _persistTransferSettings();
    _log('传输窗口间隔已设为 $clamped ms，下一个发送窗口起生效。');
    notifyListeners();
  }

  void setMassWindowSize(int value) {
    final clamped = value.clamp(1, 50);
    if (massWindowSize == clamped) return;
    massWindowSize = clamped;
    _persistTransferSettings();
    _log(clamped <= 3
        ? '每窗口分片数已设为 $clamped（设备协商范围内）。'
        : '每窗口分片数已设为 $clamped（实验模式，超过设备协商值 3）。');
    notifyListeners();
  }

  Future<void> _restoreTransferSettings() async {
    final saved = await _transferSettings.read();
    final interval = saved.segmentIntervalMs;
    final window = saved.massWindowSize;
    if (!_autoTimeSyncChangedByUser) {
      autoTimeSync = saved.autoTimeSync ?? false;
    }
    if (interval != null && interval >= 1 && interval <= 20) {
      segmentIntervalMs = interval;
    }
    if (window != null && window >= 1 && window <= 50) {
      massWindowSize = window;
    }
    notifyListeners();
  }

  bool get isConnected => connectedDevice != null;

  bool get isScanning => _isScanning;

  bool get hasAuthKey => authKey != null;

  bool get installInProgress => _installInProgress;

  bool get timeSyncInProgress => _timeSyncInProgress;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void setConnectionMode(ConnectionMode mode) {
    if (isConnected || connectionMode == mode) return;
    connectionMode = mode;
    _log(mode == ConnectionMode.modern
        ? '已切换到现代设备模式（V2 RFCOMM 安装）。'
        : '已切换到经典设备实验模式；只开放安全连接与协议取证，不开放安装。');
    notifyListeners();
  }

  void reportError(String message) {
    error = message;
    _log(message);
  }

  void _log(String message) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final next = [...logs, '[$ts] $message'];
    // Keep diagnostics useful without retaining an unbounded session history.
    logs = next.length <= 500 ? next : next.sublist(next.length - 500);
    notifyListeners();
  }

  void clearLogs() {
    logs = const [];
    notifyListeners();
  }

  /// 校验并保存 authkey。返回是否成功；失败时设置 [error] 并记录日志。
  Future<bool> setAuthKey(String key) async {
    final trimmed = key.trim();
    if (!_authKeyPattern.hasMatch(trimmed)) {
      error = 'authkey 必须是 32 位十六进制字符（收到 ${trimmed.length} 个字符）';
      _log('authkey 输入无效：${trimmed.length} 个字符');
      notifyListeners();
      return false;
    }
    authKey = trimmed.toLowerCase();
    error = null;
    try {
      await _secureStorage.write(authKey!);
      _log('authkey 已保存：${trimmed.substring(0, 4)}…${trimmed.substring(28)} '
          '（32 hex，16 字节）');
    } on Object {
      _log('安全存储写入失败；authkey 仅在本次运行中可用，下次需要重新输入。');
    }
    return true;
  }

  /// 从系统安全存储恢复 authkey。仅恢复到内存，不会输出完整内容。
  Future<void> _restoreAuthKey() async {
    try {
      final saved = await _secureStorage.read();
      if (saved == null || !_authKeyPattern.hasMatch(saved)) return;
      authKey = saved.toLowerCase();
      _log('已从系统安全存储恢复 authkey；无需重新输入。');
    } on Object {
      // 凭据库不可用时保持手动输入能力，且不把安全存储错误暴露为密钥内容。
      _log('无法读取系统安全存储；可手动输入 authkey。');
    }
  }

  Future<void> forgetAuthKey() async {
    authKey = null;
    await _secureStorage.delete();
    _log('已从系统安全存储移除 authkey。');
  }

  Future<void> beginScan() async {
    if (_isScanning) {
      _log('BLE 扫描已在进行，忽略重复请求。');
      return;
    }
    error = null;
    scanResults = const [];
    _pendingScanResults.clear();
    _scanResultsFlushTimer?.cancel();
    _scanResultsFlushTimer = null;
    _isScanning = true;
    _log('开始 BLE 扫描…');
    await _scanSubscription?.cancel();
    _scanSubscription = _transport.discoveries.listen((result) {
      if (!_isScanning) return;
      final name = (result.advertisement.name ?? '').trim();
      if (name.isEmpty) return;
      final id = result.peripheral.uuid.toString();
      final pending = _pendingScanResults[id];
      DiscoveredEventArgs? published;
      for (final item in scanResults) {
        if (item.peripheral.uuid.toString() == id) {
          published = item;
          break;
        }
      }
      final previous = pending ?? published;
      final previousName = (previous?.advertisement.name ?? '').trim();
      // RSSI changes arrive many times per second. Only rebuild when a device
      // is new or a later scan response provides a different/better name.
      if (previous != null && previousName == name) return;
      _pendingScanResults[id] = result;
      _scanResultsFlushTimer ??= Timer(
        const Duration(milliseconds: 250),
        _flushScanResults,
      );
    }, onError: (Object value) {
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      error = '扫描失败：$value';
      _log('扫描失败：$value');
      notifyListeners();
    });
    try {
      await _transport.startScan();
      if (!_isScanning) {
        await _transport.stopScan();
        return;
      }
      _log(defaultTargetPlatform == TargetPlatform.windows
          ? '扫描已启动（已识别的 V2 设备将直接使用 RFCOMM，不经过 GATT）。'
          : '扫描已启动（点击连接将先读取 GATT 版本）。');
    } catch (exception) {
      _isScanning = false;
      error = '启动扫描失败：$exception';
      _log(error!);
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    _isScanning = false;
    _flushScanResults();
    notifyListeners();
    try {
      await _transport.stopScan();
      _log('BLE 扫描已停止。');
    } catch (exception) {
      error = '停止扫描失败：$exception';
      _log(error!);
    }
  }

  void _flushScanResults() {
    _scanResultsFlushTimer = null;
    if (_disposed || _pendingScanResults.isEmpty) return;
    final updates = Map<String, DiscoveredEventArgs>.fromEntries(
      scanResults.map(
        (item) => MapEntry(item.peripheral.uuid.toString(), item),
      ),
    );
    updates.addAll(_pendingScanResults);
    _pendingScanResults.clear();
    final indexed =
        updates.values.toList(growable: false).asMap().entries.toList();
    indexed.sort((left, right) {
      final leftKnown = DeviceProfile.matchAdvertisementName(
            left.value.advertisement.name ?? '',
          ) !=
          null;
      final rightKnown = DeviceProfile.matchAdvertisementName(
            right.value.advertisement.name ?? '',
          ) !=
          null;
      if (leftKnown != rightKnown) return leftKnown ? -1 : 1;
      return left.key.compareTo(right.key);
    });
    scanResults =
        indexed.map((entry) => entry.value).take(20).toList(growable: false);
    notifyListeners();
  }

  Future<void> connect(DiscoveredEventArgs result) async {
    final advertisedName = (result.advertisement.name ?? '').trim();
    final profile = DeviceProfile.matchAdvertisementName(advertisedName);
    if (profile == null) {
      error = advertisedName.isEmpty
          ? '连接被拒绝：设备没有可用于型号校验的名称。'
          : '连接被拒绝：无法从设备名称识别受支持型号（$advertisedName）。';
      _log(error!);
      notifyListeners();
      return;
    }
    final needsExperimentalMode =
        profile.generation != ProtocolGeneration.v2Vela;
    if (needsExperimentalMode &&
        connectionMode != ConnectionMode.classicExperimental) {
      error = '该设备使用旧版传输；请切换“经典设备（实验）”模式后连接。';
      _log(error!);
      notifyListeners();
      return;
    }
    if (!needsExperimentalMode &&
        connectionMode == ConnectionMode.classicExperimental) {
      error = '该设备属于现代 V2 型号；请切换“现代设备”模式后连接。';
      _log(error!);
      notifyListeners();
      return;
    }
    if (!hasAuthKey) {
      error = '连接被拒绝：请输入 32 位 authkey 以进行设备身份校验。';
      _log(error!);
      notifyListeners();
      return;
    }
    connectedDeviceName = advertisedName;
    connectedProfile = profile;
    _log('设备名称校验通过：$advertisedName → ${profile.displayName}。');
    if (defaultTargetPlatform == TargetPlatform.windows &&
        profile.generation == ProtocolGeneration.v2Vela) {
      await _connectWindowsV2(result.peripheral, profile);
      return;
    }
    await _connectPeripheral(result.peripheral);
  }

  /// Known Windows targets are V2 devices. RFCOMM carries the real pairing,
  /// authentication and install protocol, while GATT only repeats a version
  /// probe and is prone to stale Windows "connected" state failures.
  Future<void> _connectWindowsV2(
      Peripheral peripheral, DeviceProfile profile) async {
    _advanceSessionEpoch();
    error = null;
    sessionReady = false;
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    // Some V2 devices close the first RFCOMM socket immediately after f=27.
    // Allow one transport-only reconnect while retaining the confirmed keys.
    _postAuthReconnectAttempts = 0;
    _authenticatedAt = null;
    _log('已识别 ${profile.displayName}（V2），Windows 使用无 GATT 快速连接。');
    try {
      await _transport.stopScan();
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      connectedDevice = peripheral;
      _lastPeripheral = peripheral;
      services = const [];
      _log('直接检查系统配对并建立 RFCOMM；不创建临时 GATT 链路。');
      await connectSpp();
    } on Object catch (exception) {
      sessionReady = false;
      error = 'Windows V2 快速连接失败：$exception';
      _log(error!);
    }
    notifyListeners();
  }

  /// 先建立 GATT 链路，再进入经验证的应用层 authkey 鉴权。
  Future<void> _connectPeripheral(
    Peripheral peripheral, {
    bool resetWindowsPairing = false,
  }) async {
    _advanceSessionEpoch();
    error = null;
    sessionReady = false;
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    _postAuthReconnectAttempts = 0;
    _authenticatedAt = null;
    _log('正在连接 ${peripheral.uuid}（authkey 已就绪，等待应用层身份校验）…');
    try {
      await _transport.stopScan();
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      if (resetWindowsPairing) {
        final removedOldPairing =
            await _transport.unpairIfPaired(peripheral.uuid);
        if (removedOldPairing) {
          _log('检测到 Windows 旧配对，已在连接前删除设备记录。');
          _log('等待系统释放旧蓝牙链路后重新连接…');
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      services = await _transport.connectAndDiscover(peripheral);
      connectedDevice = peripheral;
      _lastPeripheral = peripheral;
      _log('GATT 已连接，发现 ${services.length} 个服务：');
      for (final service in services) {
        _log('  服务 ${service.uuid}');
      }
      await _inspectMiWearService();
      await _readStandardBatteryLevel();
      if (connectedProfile?.generation != ProtocolGeneration.v2Vela) {
        final transport = switch (connectedProfile?.generation) {
          ProtocolGeneration.v1Vela => '旧 Vela V1',
          ProtocolGeneration.huamiZepp => 'Huami/Zepp',
          _ => '尚未确认',
        };
        _log('旧设备实验连接完成：已保留 GATT 链路用于服务枚举与取证（$transport）。');
        _log('该型号的独立鉴权与安装协议尚未完成真机验证，不会发送猜测性私有帧。');
        return;
      }
      _log('GATT 链路已建立。应用层 authkey 身份校验尚待真机帧验证，'
          '私有帧仍受安全门控保护，当前未宣称“设备已就绪”。');
      if (defaultTargetPlatform == TargetPlatform.windows) {
        _log('正在检查 Windows 系统配对状态…');
        // Native pairDevice is intentionally idempotent: an existing pairing
        // is reused, while an unpaired but connected LE device enters the one
        // real system pairing flow before any RFCOMM/auth traffic is sent.
        await _transport.pairDevice(peripheral.uuid);
        _log('系统配对状态已确认；后续直接复用，不删除设备记录。');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // 官方 SPP 连接是独立的经典蓝牙主通道。版本读取完成后释放并行 GATT
      // 连接，避免 Windows 同时维持 LE 与 RFCOMM 时回收串口 socket。
      await _transport.disconnect(peripheral);
      _log('版本读取完成，已释放临时 GATT 链路；后续保持独立 SPP 长连接。');
      _log('开始自动建立 SPP 与 authkey 会话，无需再次点击。');
      await connectSpp();
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

  /// Reads the standard Bluetooth Battery Service when the temporary GATT
  /// link is available. V2 Windows fast-connect intentionally has no GATT
  /// link, so its battery value remains unknown instead of using a guessed
  /// private RFCOMM command.
  Future<void> _readStandardBatteryLevel() async {
    final device = connectedDevice;
    if (device == null) return;

    GATTCharacteristic? levelCharacteristic;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != BatteryGatt.serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() ==
            BatteryGatt.levelUuid) {
          levelCharacteristic = characteristic;
          break;
        }
      }
      break;
    }

    if (levelCharacteristic == null) {
      _log(
          'Standard Battery Service (180F/2A19) not available; battery unknown.');
      return;
    }
    try {
      final data =
          await _transport.readCharacteristic(device, levelCharacteristic);
      final level = parseBatteryLevel(data);
      if (level == null) {
        _log(
            'Battery Level characteristic returned an invalid value; battery unknown.');
        return;
      }
      batteryPercent = level;
      _log('Battery Level (2A19) = $level%');
    } catch (exception) {
      _log(
          'Battery Level characteristic read failed; battery unknown: $exception');
    }
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
        connectedFirmwareVersion = version;
        final generation = data[0] == 0 ? 'V1（旧传输）' : 'V2（新传输）';
        _log('版本特征 $versionUuid = $hex → 固件 $version → $generation');
      } else {
        _log('版本特征 $versionUuid = $hex（不足 3 字节）');
      }
    } catch (exception) {
      _log('版本特征读取失败：$exception');
    }
  }

  /// SPP（经典蓝牙 RFCOMM）连接 + 鉴权握手——手环 9 系主通道。
  ///
  /// 流程（与 App/Gadgetbridge 一致）：
  /// RFCOMM 连接 → SessionConfig(START_SESSION) → 设备回 SessionConfig →
  /// 发 f=26（DATA 明文帧）→ 设备回 watchNonce → 完成 step1。
  Future<void> connectSpp({bool resumeSession = false}) async {
    if (sppConnecting) {
      _log('SPP 连接已在进行，忽略重复请求。');
      return;
    }
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
    sessionReady = false;
    sppConnecting = true;
    _authenticatedAt = null;
    _resumeAuthenticatedSession = resumeSession && _sessionCipher != null;
    notifyListeners();
    _log(_resumeAuthenticatedSession
        ? 'SPP（RFCOMM 串口）重连：${device.uuid}（复用已确认会话）…'
        : 'SPP（RFCOMM 串口）连接：${device.uuid}…');
    _sppAcc = Accumulator();
    _sppSeq = 0;
    _sppAwaitingAuthConfirm = false;
    if (!_resumeAuthenticatedSession) {
      _pendingSessionKeys = null;
      _sessionCipher = null;
    }
    try {
      _transport.listenRfcommData();
      _sppSub ??= _transport.rfcommData.listen(
        _handleSppData,
        onError: (Object exception, StackTrace stackTrace) {
          _log('RFCOMM 数据流错误：$exception');
          _handleRfcommEof();
        },
        onDone: _handleRfcommEof,
      );
      _log('正在建立经典蓝牙 RFCOMM 链路，并独立检查 SPP 配对状态…');
      _log('  Windows 的 BLE 配对不等于经典蓝牙 SPP 配对；若手环弹出请求，请在手环上确认。');
      await _transport.connectRfcomm(device.uuid);
      // These V2 targets expose their transport generation through the GATT
      // version characteristic. Repeated device tests show that they do not
      // answer the legacy BA-DC-FE SPP version query, while L1START succeeds
      // immediately. Skipping that fixed 8-second wait matches the effective
      // fallback path without changing the authenticated protocol.
      _sppAwaitingVersion = false;
      _log('RFCOMM 已连接；目标型号已识别为 V2，直接发送 L1START…');
      await _sppSendL1Start();
    } catch (exception) {
      sppConnecting = false;
      if (_resumeAuthenticatedSession) {
        _resumeAuthenticatedSession = false;
        _sessionCipher = null;
        _log('会话恢复失败；已丢弃旧会话密钥，下次连接将重新鉴权。');
      }
      _log('SPP 连接失败：$exception');
      notifyListeners();
    }
  }

  StreamSubscription<Uint8List>? _sppSub;
  Accumulator _sppAcc = Accumulator();
  int _sppSeq = 0;
  bool _sppAwaitingVersion = false;
  bool _sppAwaitingAuthConfirm = false;
  Timer? _sppWatchdog;
  DateTime? _authenticatedAt;
  int _postAuthReconnectAttempts = 0;
  bool _recoveringPostAuthClose = false;
  bool _resumeAuthenticatedSession = false;
  SessionKeys? _pendingSessionKeys;
  SessionCipher? _sessionCipher;
  final Map<int, Completer<void>> _pendingAcks = {};
  final Set<int> _pendingMassAcks = {};
  final List<int> _pendingMassAckOrder = [];
  final Map<int, _MassProgressMarker> _pendingMassProgress = {};
  final StreamController<Zau> _businessResponses =
      StreamController<Zau>.broadcast();
  final Set<_BusinessWaiter> _completionWaiters = {};
  final InstallCheckpointStore _checkpointStore = InstallCheckpointStore();
  bool _installCancelled = false;
  bool _installInProgress = false;
  bool _timeSyncInProgress = false;
  String? lastTimeSyncSummary;
  Completer<void>? _installCancellation;
  Completer<Object>? _installTransportFailure;
  InstallRequest? _lastInstallRequest;
  DateTime? _lastSpeedSampleAt;
  int _lastSpeedSampleBytes = 0;
  double? _confirmedBytesPerSecond;
  Stopwatch? _installStopwatch;
  Stopwatch? _transferStopwatch;
  Duration? _completedTransferElapsed;
  int _transferStartConfirmedBytes = 0;

  /// 处理 RFCOMM 收到的字节：先试 SppPacket（版本回包），再增量解析 L1 帧。
  void _handleSppData(Uint8List data) {
    if (data.isEmpty) {
      _handleRfcommEof();
      return;
    }
    _log('RFCOMM 收到 ${data.length}B：${_hex(data)}');
    if (_sppAwaitingVersion) {
      final packet = SppProtocol.parseSppPacket(data);
      if (packet != null) {
        _sppAwaitingVersion = false;
        final (type, payload) = packet;
        _log('SppPacket 回包：type=$type payload=${_hex(payload)}');
        if (type == 106) {
          connectedFirmwareVersion = payload
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join('.');
          _log('  ★ 设备版本：$connectedFirmwareVersion');
          _log('版本确认。发送 L1START_REQ（L1 CMD 帧）…');
          unawaited(_sppSendL1Start());
        } else {
          _log('  非版本回包（type=$type），仍尝试 L1START…');
          unawaited(_sppSendL1Start());
        }
        return;
      }
    }
    _sppAcc.buffer = [..._sppAcc.buffer, ...data];
    final packets = SppProtocol.parse(_sppAcc);
    for (final packet in packets) {
      _handleSppPacket(packet);
    }
  }

  void _handleRfcommEof() {
    sppConnecting = false;
    if (!sessionReady && _sessionCipher == null) {
      _log('RFCOMM 已关闭（EOF）。');
      notifyListeners();
      return;
    }
    final authenticatedAt = _authenticatedAt;
    final isTransportTransition = authenticatedAt != null &&
        DateTime.now().difference(authenticatedAt) <
            const Duration(seconds: 2) &&
        _postAuthReconnectAttempts == 0 &&
        !_recoveringPostAuthClose &&
        !_installInProgress;
    _advanceSessionEpoch();
    sessionReady = false;
    _authenticatedAt = null;
    if (!isTransportTransition) {
      _sessionCipher = null;
      _resumeAuthenticatedSession = false;
    }
    final exception = StateError('RFCOMM 远端已关闭');
    final installFailure = _installTransportFailure;
    if (_installInProgress &&
        installFailure != null &&
        !installFailure.isCompleted) {
      installFailure.complete(exception);
    }
    for (final waiter in _pendingAcks.values) {
      if (!waiter.isCompleted) waiter.completeError(exception);
    }
    _pendingAcks.clear();
    _pendingMassAcks.clear();
    _pendingMassAckOrder.clear();
    _pendingMassProgress.clear();
    if (isTransportTransition) {
      _postAuthReconnectAttempts++;
      _log('检测到 f=27 后的 RFCOMM 传输切换；保留已确认会话密钥并自动重建链路。');
      unawaited(_recoverPostAuthRfcomm());
    } else {
      _log('RFCOMM 长连接已被远端关闭；当前鉴权会话失效。');
    }
    notifyListeners();
  }

  Future<void> _recoverPostAuthRfcomm() async {
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null || _recoveringPostAuthClose) return;
    _recoveringPostAuthClose = true;
    try {
      try {
        await _transport.disconnectRfcomm(device.uuid);
      } on Object {
        // 设备已经关闭旧 socket 时，本地清理仍可能返回错误。
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _log('正在重建持久 SPP 传输；不会重复系统配对或 f=26/f=27。');
      await connectSpp(resumeSession: true);
    } on Object catch (exception) {
      _resumeAuthenticatedSession = false;
      _sessionCipher = null;
      _log('持久 SPP 会话重建失败：$exception');
    } finally {
      _recoveringPostAuthClose = false;
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
          if (_resumeAuthenticatedSession && _sessionCipher != null) {
            _resumeAuthenticatedSession = false;
            sessionReady = true;
            sppConnecting = false;
            _sppWatchdog?.cancel();
            _sppWatchdog = null;
            _log('L1START_RSP 收到——传输层已恢复；复用已确认的会话密钥，不重复 f=26/f=27。');
            unawaited(_refreshAuthenticatedDeviceStatus());
            notifyListeners();
          } else {
            _log('L1START_RSP 收到——L1 会话建立！发送官方鉴权 f=26（DATA 明文帧）…');
            unawaited(_sppSendAuthStep1());
          }
        }
        break;
      case SppProtocol.typeData:
        _log('SPP DATA 帧（seq=${packet.seq}）：payload=${_hex(packet.payload)}');
        // 回 ACK
        unawaited(_sppSendAck(packet.seq));
        _handleSppDataPacket(packet);
        break;
      case SppProtocol.typeAck:
        final massIndex = _pendingMassAckOrder.indexOf(packet.seq);
        if (massIndex >= 0) {
          // L1 uses cumulative ACKs for a receive window. ACK N confirms every
          // queued Mass frame through N, not only the frame whose seq equals N.
          final confirmed =
              _pendingMassAckOrder.sublist(0, massIndex + 1).toList();
          _pendingMassAckOrder.removeRange(0, massIndex + 1);
          _MassProgressMarker? latestProgress;
          for (final sequence in confirmed) {
            _pendingMassAcks.remove(sequence);
            latestProgress =
                _pendingMassProgress.remove(sequence) ?? latestProgress;
            final waiter = _pendingAcks.remove(sequence);
            if (waiter != null && !waiter.isCompleted) waiter.complete();
          }
          _log('Mass 累计 ACK（seq=${packet.seq}，确认 ${confirmed.length} 片）');
          if (latestProgress != null) {
            _updateTransferSpeed(latestProgress.confirmedBytes);
            _publishTask(
              latestProgress.request,
              InstallStage.transferring,
              '设备已确认第 ${latestProgress.segmentIndex}/'
              '${latestProgress.totalSegments} 片。',
              currentSegment: latestProgress.segmentIndex,
              totalSegments: latestProgress.totalSegments,
              confirmedBytes: latestProgress.confirmedBytes,
              queuedSegment: latestProgress.queuedSegment,
              queuedBytes: latestProgress.queuedBytes,
              totalBytes: latestProgress.totalBytes,
              bytesPerSecond: _confirmedBytesPerSecond,
            );
          }
        } else {
          final waiter = _pendingAcks.remove(packet.seq);
          if (waiter != null && !waiter.isCompleted) waiter.complete();
          _log('SPP ACK（seq=${packet.seq}）');
        }
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
    if (channel == SppProtocol.channelPb &&
        opCode == SppProtocol.opCodeWriteEnc) {
      _inspectEncryptedBusinessFrame(data);
      return;
    }
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
        _sppAwaitingAuthConfirm = false;
        final confirmed = parsed.authStatus == 1;
        sppConnecting = false;
        if (confirmed) {
          sessionReady = true;
          _authenticatedAt = DateTime.now();
          final keys = _pendingSessionKeys;
          if (keys != null) {
            _sessionCipher = SessionCipher(keys);
            _pendingSessionKeys = null;
            _log('  已启用 WRITE_ENC 业务通道与只读解密诊断。');
          }
          _sppWatchdog?.cancel();
          _sppWatchdog = null;
          // f=27 confirms the authenticated session. Do not send a speculative
          // encrypted "keepalive" here: the reference installer proceeds with
          // the requested business command, and this device does not ACK the
          // previously tested 4/0 probe. A missing response to an optional
          // probe must never invalidate an otherwise healthy RFCOMM session.
        }
        _log('  f=27 设备响应（confirmed=$confirmed，status=${parsed.status}）');
        _log(confirmed
            ? '  ★ 鉴权完成（device ready）——会话密钥已建立；可使用已验证的安装流程'
            : '  ✕ 设备未确认鉴权，未将连接标记为就绪');
        if (confirmed && _sessionCipher != null) {
          unawaited(_refreshAuthenticatedDeviceStatus());
        }
      }
    } else {
      _log('  无法按 Xiaomi Command 解析');
    }
  }

  /// 只分析设备入站加密帧，不会向设备发送任何探测数据。
  void _inspectEncryptedBusinessFrame(List<int> ciphertext) {
    final cipher = _sessionCipher;
    if (cipher == null) {
      _log('  WRITE_ENC 已收到，但本次会话尚无可用密钥（只记录）。');
      return;
    }
    final plaintext = cipher.decryptInbound(ciphertext);
    final business = Zau.tryParse(plaintext);
    if (business != null && business.command != XiaomiAuth.commandType) {
      _log('  WRITE_ENC 业务响应：command=${business.command}/${business.sub}');
      _businessResponses.add(business);
      return;
    }
    final parsed = XiaomiAuth.parse(plaintext);
    if (parsed?.type != null && parsed?.subtype != null) {
      _log('  WRITE_ENC 解密命中：type=${parsed!.type} '
          'subtype=${parsed.subtype} plain=${_hex(plaintext)}');
      return;
    }
    _log('  WRITE_ENC 未解析为已知 Command；不改变会话或发送状态。');
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
      phoneModel: _companionDeviceName(),
    );
    if (cmd == null) {
      _log('  ✗ 设备签名校验失败（HMAC 不匹配——authkey 与设备不匹配？）');
      return;
    }
    _pendingSessionKeys = SessionKeys.fromHkdf(
      XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce),
    );
    final frame = SppProtocol.buildDataFrame(_sppSeq++, cmd);
    _log('发送 f=27（seq=${_sppSeq - 1}，${frame.length}B）：${_hex(frame)}');
    try {
      // 设备可能在 Windows 写入 Future 完成前回包，先置状态以避免随后误挂超时。
      _sppAwaitingAuthConfirm = true;
      await _transport.rfcommWrite(device.uuid, frame);
      if (!_sppAwaitingAuthConfirm) {
        _log('f=27 已在写入完成前收到设备确认。');
        return;
      }
      _log('f=27 已写入，等待设备确认（device ready）…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        if (_sppAwaitingAuthConfirm) {
          _sppAwaitingAuthConfirm = false;
          _log('SPP 超时：15 秒内无 f=27 响应');
        }
      });
    } catch (exception) {
      _sppAwaitingAuthConfirm = false;
      _log('f=27 发送失败：$exception');
    }
  }

  String _companionDeviceName() {
    try {
      final hostname = Platform.localHostname.trim();
      if (hostname.isNotEmpty) {
        return hostname.length <= 64 ? hostname : hostname.substring(0, 64);
      }
    } on Object {
      // 主机名不可用时使用不含用户信息的通用平台名。
    }
    return 'Windows';
  }

  Future<void> _sppSendAuthStep1() async {
    final device = connectedDevice;
    if (device == null) return;
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    _pendingPhoneNonce = nonce;
    final command = XiaomiAuth.buildNonceCommand(nonce);
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
      _log('  ACK 已发送（seq=$seq）');
    } catch (exception) {
      _log('ACK 发送失败：$exception');
    }
  }

  List<int>? _pendingPhoneNonce;
  final _random = Random();

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  Future<void> disconnect() async {
    _advanceSessionEpoch();
    if (_installInProgress) {
      await cancelInstall();
      _log('RFCOMM/GATT 正在断开：安装已停止，设备可能保留部分数据。');
    }
    final device = connectedDevice;
    if (device != null) {
      try {
        await _transport.disconnectRfcomm(device.uuid);
      } on Object {
        // RFCOMM 可能已经由设备关闭；仍继续清理 GATT/界面状态。
      }
      try {
        await _transport.disconnect(device);
      } on Object {
        // Windows V2 快速路径不创建 GATT 连接，断开失败不影响 RFCOMM 清理。
      }
      _log('已断开 ${connectedDeviceName ?? device.uuid.toString()}');
    }
    connectedDevice = null;
    connectedDeviceName = null;
    connectedProfile = null;
    sessionReady = false;
    sppConnecting = false;
    _sppWatchdog?.cancel();
    _sppWatchdog = null;
    _scanResultsFlushTimer?.cancel();
    _scanResultsFlushTimer = null;
    _authenticatedAt = null;
    _recoveringPostAuthClose = false;
    _resumeAuthenticatedSession = false;
    _sppAwaitingAuthConfirm = false;
    _pendingSessionKeys = null;
    _sessionCipher = null;
    _isScanning = false;
    services = const [];
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    notifyListeners();
  }

  Future<void> startInstall(InstallRequest request) async {
    if (_timeSyncInProgress) {
      _log('安装被拒绝：系统时间同步正在进行，请等待同步完成。');
      return;
    }
    if (statusRefreshInProgress) {
      _log('安装被拒绝：正在读取设备状态，请等待完成。');
      return;
    }
    if (_installInProgress) {
      _log('安装被拒绝：已有任务正在运行。');
      return;
    }
    error = null;
    try {
      const VerificationGate().ensureCanSend();
    } on StateError catch (exception) {
      _publishTask(request, InstallStage.waitingForProtocol, exception.message);
      return;
    }
    if (!sessionReady ||
        _sessionCipher == null ||
        (connectedDevice ?? _lastPeripheral) == null) {
      error = '安装被拒绝：请先完成 authkey 会话认证。';
      _log(error!);
      notifyListeners();
      return;
    }
    _installInProgress = true;
    _lastInstallRequest = request;
    _installCancelled = false;
    _installStopwatch = Stopwatch()..start();
    _transferStopwatch = null;
    _completedTransferElapsed = null;
    _transferStartConfirmedBytes = 0;
    _installCancellation = Completer<void>();
    _installTransportFailure = Completer<Object>();
    try {
      await _runInstall(request);
    } on _InstallCancelled {
      _publishTask(request, InstallStage.cancelled, '已取消，设备可能保留部分数据。');
    } on FormatException catch (exception) {
      _publishTask(request, InstallStage.failed, exception.message);
    } on _DeviceInstallFailed catch (exception) {
      await _clearCheckpointBestEffort();
      _publishTask(request, InstallStage.failed, exception.message);
    } on TimeoutException catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _publishTask(request, InstallStage.stateUnknown,
          '设备未在规定时间响应；已停止发送，设备状态未知。${exception.message ?? ''}');
    } on _InvalidDeviceResponse catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _publishTask(request, InstallStage.stateUnknown,
          '设备响应无法验证；已停止发送，设备状态未知：${exception.message}');
    } on Object catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _publishTask(
          request, InstallStage.stateUnknown, '传输已停止，设备状态未知：$exception');
    } finally {
      for (final waiter in _completionWaiters.toList()) {
        await waiter.cancel();
      }
      _completionWaiters.clear();
      _pendingAcks.clear();
      _pendingMassAcks.clear();
      _pendingMassAckOrder.clear();
      _pendingMassProgress.clear();
      _resetTransferSpeed();
      _installStopwatch?.stop();
      _transferStopwatch?.stop();
      _installStopwatch = null;
      _transferStopwatch = null;
      _completedTransferElapsed = null;
      _transferStartConfirmedBytes = 0;
      _installCancellation = null;
      _installTransportFailure = null;
      _installInProgress = false;
      notifyListeners();
    }
  }

  Future<void> cancelInstall() async {
    if (!_installInProgress) return;
    _installCancelled = true;
    for (final waiter in _pendingAcks.values) {
      if (!waiter.isCompleted) waiter.completeError(const _InstallCancelled());
    }
    _pendingAcks.clear();
    _pendingMassAcks.clear();
    _pendingMassAckOrder.clear();
    _pendingMassProgress.clear();
    final cancellation = _installCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _log('已停止本地安装队列；未发送未验证的设备取消命令。');
  }

  /// 只校验本地检查点和源文件；没有设备侧状态查询证据时绝不自行续传。
  Future<void> reconnectAndCheckInstall() async {
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null) {
      _log('没有待恢复的安装检查点。');
      return;
    }
    final file = File(checkpoint.path);
    if (!await file.exists()) {
      _log('恢复检查失败：源文件已不存在，设备状态未知。');
      return;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != checkpoint.fileSize ||
        md5.convert(bytes).toString() != checkpoint.md5Hex ||
        sha256.convert(bytes).toString() != checkpoint.sha256Hex) {
      _log('恢复检查失败：源文件已变更，不能使用此检查点续传。');
      return;
    }
    _log('检查点有效：已确认片 ${checkpoint.lastAcknowledgedSegment}，'
        '重新认证后将重新 MassPrepare，由设备决定是否给出可信断点。');
  }

  /// Retries the same package without discarding the device's Mass checkpoint.
  ///
  /// The local checkpoint is only an integrity record. The actual resume offset
  /// is always negotiated again through MassPrepare, so a device that retained
  /// part of the package continues from that point and one that did not safely
  /// asks for the whole package again.
  Future<void> retryInstall() async {
    final request = _lastInstallRequest;
    if (request == null) {
      _log('没有可继续传输的安装任务。');
      return;
    }
    final queuedEntry = installQueue.reversed
        .where((entry) =>
            entry.canRetry &&
            entry.request.kind == request.kind &&
            entry.request.path == request.path &&
            entry.request.metadata.md5Hex == request.metadata.md5Hex)
        .firstOrNull;
    if (queuedEntry != null) {
      await _retryQueueEntry(queuedEntry);
      return;
    }
    final checkpoint = await _checkpointStore.load();
    final checkpointMatches = checkpoint != null &&
        checkpoint.kind == request.kind &&
        checkpoint.path == request.path &&
        checkpoint.fileSize == request.metadata.fileSize &&
        checkpoint.md5Hex == request.metadata.md5Hex &&
        checkpoint.sha256Hex == request.metadata.sha256Hex;
    if (checkpointMatches) {
      _log('继续传输同一文件：本地已确认片 '
          '${checkpoint.lastAcknowledgedSegment}；将由设备 MassPrepare 决定续传偏移。');
    } else {
      _log('重新发送同一文件：没有可用本地检查点；将由设备 MassPrepare 决定续传偏移。');
    }
    if (!await _restoreInstallSessionForRetry()) return;
    await startInstall(request);
  }

  Future<bool> _restoreInstallSessionForRetry() async {
    if (sessionReady && _sessionCipher != null && connectedDevice != null) {
      return true;
    }
    // An explicit disconnect clears the current target. Do not silently revive
    // a stale peripheral; the user must select the intended device again.
    if (connectedDevice == null) {
      _log('无法继续传输：当前没有已连接的目标设备，请重新连接后再次尝试。');
      return false;
    }
    _log('继续传输前正在重建 SPP 鉴权会话…');
    if (!sppConnecting) await connectSpp();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!sessionReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!sessionReady || _sessionCipher == null) {
      _log('SPP 鉴权会话尚未恢复，未发送安装包。');
      return false;
    }
    return true;
  }

  /// Backward-compatible API name retained for integrations compiled against
  /// older versions. Its behavior intentionally no longer clears a checkpoint.
  @Deprecated('Use retryInstall() to continue the same package.')
  Future<void> retryInstallFromStart() => retryInstall();

  Future<void> _runInstall(InstallRequest request) async {
    final metadata = request.metadata;
    _validateInstallRequest(request);
    final file = File(request.path);
    if (!await file.exists()) throw StateError('源文件已不存在');
    final bytes = await file.readAsBytes();
    if (bytes.length != metadata.fileSize ||
        md5.convert(bytes).toString() != metadata.md5Hex ||
        sha256.convert(bytes).toString() != metadata.sha256Hex) {
      throw StateError('源文件已变化，拒绝使用旧元数据发送');
    }
    final dataType = request.kind == InstallKind.watchface
        ? MassDataType.watchface
        : MassDataType.quickAppRpk;
    _publishTask(request, InstallStage.validating, '元数据与文件哈希已校验。');
    // Subscribe before sending the file so an immediate completion event is
    // not lost on the broadcast stream. The result timeout starts only after
    // all Mass data is acknowledged; otherwise a large file can time out while
    // it is still being transferred.
    final watchCompletion = request.kind == InstallKind.watchface
        ? _listenBusiness(ZauCommand.setFace, 5)
        : null;
    final appCompletion = request.kind == InstallKind.quickApp
        ? _listenQuickAppInstallResult(metadata.packageName!)
        : null;
    var preinstallSliceLength = 0;
    if (request.kind == InstallKind.watchface) {
      final preinstall = await _requestBusiness(
        Zau(
            command: ZauCommand.setFace,
            sub: 4,
            payload: A9u.withFileInfo(
                faceId: metadata.faceId!, fileSize: bytes.length)),
        ZauCommand.setFace,
        4,
      );
      final payload = preinstall.payload;
      if (payload == null) throw StateError('表盘预安装响应缺少载荷');
      final result = A9u.parse(payload.$2);
      if (result.code != 0) {
        throw _DeviceInstallFailed('设备拒绝表盘预安装，状态=${result.code}');
      }
      _log('表盘预安装通过：faceId=${metadata.faceId}');
    } else {
      final preinstall = await _requestBusiness(
        Zau(
            command: ZauCommand.prepareInstallApp,
            sub: 1,
            payload: V8s.prepareRequest(
                packageName: metadata.packageName!,
                versionCode: metadata.versionCode!,
                packageSize: bytes.length)),
        ZauCommand.prepareInstallApp,
        1,
      );
      final payload = preinstall.payload;
      if (payload == null) throw StateError('RPK 预安装响应缺少载荷');
      final result = V8s.parsePrepareResponse(payload.$2);
      if (result.status != 0) {
        throw _DeviceInstallFailed('设备拒绝 RPK 预安装，状态=${result.status}');
      }
      preinstallSliceLength = result.expectedSliceLength;
      _log('RPK 预安装通过：设备建议片长=$preinstallSliceLength B');
    }
    _checkCancelled();
    final prepared = await _requestBusiness(
      Zau(
          command: ZauCommand.massTransfer,
          payload: O1h.prepareRequest(
              dataType: dataType,
              fileMd5: _hexToBytes(metadata.md5Hex),
              fileLength: bytes.length)),
      ZauCommand.massTransfer,
      0,
    );
    final response = prepared.payload;
    if (response == null) throw StateError('MassPrepare 响应缺少载荷');
    final massInfo = O1h.parsePrepareResponse(response.$2);
    if (massInfo.prepareStatus != 0) {
      throw _DeviceInstallFailed(
          'MassPrepare 被设备拒绝，状态=${massInfo.prepareStatus}');
    }
    // The APK names this value remainLength, but passes it directly as the
    // already-sent file offset to MassDataDispatcher. A fresh transfer returns
    // zero. Treating zero as "all bytes remaining" and subtracting it from the
    // file size incorrectly skipped the entire transfer.
    final sentLength = massInfo.remainLength;
    if (sentLength < 0 || sentLength > bytes.length) {
      throw StateError('MassPrepare 给出无效断点：已发送 $sentLength B');
    }
    final segmentLength = massInfo.expectedSliceLength > 4
        ? massInfo.expectedSliceLength
        : preinstallSliceLength > 4
            ? preinstallSliceLength
            : defaultMassSegmentLength;
    _log('MassPrepare 通过：续传偏移=$sentLength B，片长=$segmentLength B');
    final transferPlan = sentLength == bytes.length
        ? null
        : planMassFile(
            fileBytes: bytes,
            dataType: dataType,
            fileMd5: _hexToBytes(metadata.md5Hex),
            segmentLength: segmentLength,
            sentLength: sentLength,
          );
    final totalSegments = transferPlan?.totalSegments ?? 0;
    await _checkpointStore.save(InstallCheckpoint(
      kind: request.kind,
      path: request.path,
      fileSize: metadata.fileSize,
      md5Hex: metadata.md5Hex,
      sha256Hex: metadata.sha256Hex,
      dataType: dataType,
      lastAcknowledgedSegment: 0,
      phase: 'transferring',
      faceId: metadata.faceId,
      packageName: metadata.packageName,
      versionCode: metadata.versionCode,
    ));
    // The device negotiated a three-packet L1 receive window. The UI can raise
    // this experimental window for throughput testing. Complete L1 frames are
    // concatenated into one RFCOMM stream write; frame boundaries, sequence
    // numbers, cumulative ACK handling, and timeout behavior stay unchanged.
    final massAckWindow = massWindowSize;
    var confirmedFileBytes = sentLength;
    _beginTransferTiming(confirmedBytes: sentLength);
    _publishTask(
      request,
      InstallStage.transferring,
      '文件已进入发送队列，等待设备累计 ACK…',
      currentSegment: 0,
      totalSegments: totalSegments,
      confirmedBytes: sentLength,
      totalBytes: bytes.length,
      bytesPerSecond: _confirmedBytesPerSecond,
    );
    final iterator = transferPlan?.segments.iterator;
    while (iterator != null) {
      final batch = <MassSegment>[];
      final confirmedBytesBySegment = <int, int>{};
      var queuedFileBytes = confirmedFileBytes;
      while (batch.length < massAckWindow && iterator.moveNext()) {
        final segment = iterator.current;
        batch.add(segment);
        queuedFileBytes =
            min(bytes.length, queuedFileBytes + segment.fileByteCount);
        confirmedBytesBySegment[segment.index] = queuedFileBytes;
      }
      if (batch.isEmpty) break;
      _checkCancelled();
      final queuedThrough = batch.last;
      _publishTask(
        request,
        InstallStage.transferring,
        '已提交第 ${batch.first.index}–${queuedThrough.index}/'
        '${queuedThrough.total} 片，等待设备累计 ACK…',
        currentSegment: batch.first.index - 1,
        totalSegments: queuedThrough.total,
        confirmedBytes: confirmedFileBytes,
        queuedSegment: queuedThrough.index,
        queuedBytes: queuedFileBytes,
        totalBytes: bytes.length,
        bytesPerSecond: _confirmedBytesPerSecond,
      );
      await _queueMassWindow(
        batch,
        request: request,
        confirmedBytesBySegment: confirmedBytesBySegment,
        totalBytes: bytes.length,
        idleTimeout: const Duration(seconds: 12),
      );
      final confirmed = batch.last;
      confirmedFileBytes = queuedFileBytes;
      await _checkpointStore.save(InstallCheckpoint(
        kind: request.kind,
        path: request.path,
        fileSize: metadata.fileSize,
        md5Hex: metadata.md5Hex,
        sha256Hex: metadata.sha256Hex,
        dataType: dataType,
        lastAcknowledgedSegment: confirmed.index,
        phase: 'transferring',
        faceId: metadata.faceId,
        packageName: metadata.packageName,
        versionCode: metadata.versionCode,
      ));
      if (confirmed.index < totalSegments) {
        await Future<void>.delayed(Duration(milliseconds: segmentIntervalMs));
      }
    }
    _finishTransferTiming();
    _publishTask(request, InstallStage.awaitingDevice, '文件已确认发送，正在等待设备安装结果。',
        currentSegment: totalSegments,
        totalSegments: totalSegments,
        confirmedBytes: bytes.length,
        queuedSegment: totalSegments,
        queuedBytes: bytes.length,
        totalBytes: bytes.length,
        bytesPerSecond: _confirmedBytesPerSecond);
    await _checkpointStore.save(InstallCheckpoint(
      kind: request.kind,
      path: request.path,
      fileSize: metadata.fileSize,
      md5Hex: metadata.md5Hex,
      sha256Hex: metadata.sha256Hex,
      dataType: dataType,
      lastAcknowledgedSegment: totalSegments,
      phase: 'awaitingDevice',
      faceId: metadata.faceId,
      packageName: metadata.packageName,
      versionCode: metadata.versionCode,
    ));
    if (watchCompletion != null) {
      final result = await _withInstallCancellation(
          watchCompletion.future.timeout(const Duration(minutes: 5)));
      final payload = result.payload;
      if (payload == null) throw StateError('表盘完成事件缺少载荷');
      final parsed = A9u.parse(payload.$2);
      if (parsed.kind != 'installResult' ||
          (parsed.code != 2 && parsed.code != 3)) {
        throw _DeviceInstallFailed('设备拒绝表盘安装，状态=${parsed.code}');
      }
      await _requestBusiness(
          Zau(
              command: ZauCommand.setFace,
              sub: 1,
              payload: A9u.withFaceId(metadata.faceId!)),
          ZauCommand.setFace,
          1);
      await _clearCheckpointBestEffort();
      _publishTask(request, InstallStage.succeeded,
          '表盘已安装并已请求切换 faceId=${metadata.faceId}');
      return;
    }
    late final Zau appResultMessage;
    late final ({int code, String packageName}) appResult;
    try {
      appResultMessage = await _withInstallCancellation(
          appCompletion!.future.timeout(const Duration(seconds: 120)));
      final appPayload = appResultMessage.payload;
      if (appPayload == null) {
        throw const FormatException('快应用安装结果缺少载荷');
      }
      appResult = V8s.parseInstallResult(appPayload.$2);
    } on FormatException catch (exception) {
      throw _InvalidDeviceResponse(exception.message);
    }
    if (appResult.code != 0) {
      throw _DeviceInstallFailed(
          '设备报告快应用安装失败：包名=${appResult.packageName}，状态=${appResult.code}');
    }
    await _clearCheckpointBestEffort();
    _publishTask(
        request, InstallStage.succeeded, '快应用已安装：${appResult.packageName}');
  }

  void _validateInstallRequest(InstallRequest request) {
    final metadata = request.metadata;
    if (request.kind == InstallKind.watchface &&
        !RegExp(r'^\d+$').hasMatch(metadata.faceId ?? '')) {
      throw const FormatException('faceId 必须为非空数值');
    }
    if (request.kind == InstallKind.watchface) {
      final compatibilityError = watchfaceCompatibilityError(metadata);
      if (compatibilityError != null && !request.watchfaceResolutionConfirmed) {
        throw FormatException(compatibilityError);
      }
      if (requiresUnsupportedLuaConfirmation(metadata) &&
          !request.unsupportedLuaConfirmed) {
        throw const FormatException('REDMI Watch 5 的 Lua 表盘安装尚未由用户确认');
      }
    }
    if (request.kind == InstallKind.quickApp &&
        (metadata.packageName == null ||
            metadata.versionCode == null ||
            metadata.versionCode! <= 0 ||
            metadata.versionCode! > maxRpkVersionCode)) {
      throw const FormatException('RPK 必须具有从清单读取的包名和有效 32 位正整数版本号');
    }
  }

  String? watchfaceCompatibilityError(InstallMetadata metadata) {
    final profile = connectedProfile;
    final expected = profile?.watchfaceResolution;
    final detected = metadata.watchfaceResolutions;
    if (profile == null || expected == null || detected.isEmpty) return null;
    if (detected.contains(expected)) return null;
    return '表盘分辨率 ${detected.join('、')} 与 ${profile.displayName} '
        '所需的 $expected 不匹配';
  }

  bool requiresUnsupportedLuaConfirmation(InstallMetadata metadata) =>
      connectedProfile?.family == DeviceFamily.redmiWatch5 &&
      metadata.containsLua;

  Future<Zau> _requestBusiness(
    Zau message,
    int command,
    int sub, {
    int? responseCommand,
    int? responseSub,
  }) async {
    final expectedCommand = responseCommand ?? command;
    final expectedSub = responseSub ?? sub;
    final waiter = _BusinessWaiter(_businessResponses.stream,
        (item) => item.command == expectedCommand && item.sub == expectedSub);
    final plaintext = message.encode();
    final encrypted = _sessionCipher!.encryptOutbound(plaintext);
    _log('发送业务命令 $command/$sub：PB=${_hex(plaintext)}');
    try {
      await _writeL2(
          channel: SppProtocol.channelPb,
          opCode: SppProtocol.opCodeWriteEnc,
          payload: encrypted,
          timeout: const Duration(seconds: 12));
      return await _withInstallCancellation(
          waiter.future.timeout(const Duration(seconds: 12)));
    } finally {
      await waiter.cancel();
    }
  }

  Future<bool> syncSystemTime({bool automatic = false}) async {
    if (_timeSyncInProgress) return false;
    if (_installInProgress) {
      _log('时间同步被拒绝：安装任务正在运行。');
      return false;
    }
    final cipher = _sessionCipher;
    if (!sessionReady ||
        cipher == null ||
        (connectedDevice ?? _lastPeripheral) == null) {
      if (!automatic) {
        error = '时间同步被拒绝：请先完成 authkey 会话认证。';
        _log(error!);
      }
      return false;
    }

    _timeSyncInProgress = true;
    _installCancelled = false;
    if (!automatic) error = null;
    notifyListeners();
    try {
      final info = await const SystemTimeInfoSource().read();
      final payload = TimeSyncPayload.encode(
        localTime: info.localTime,
        standardOffsetMinutes: info.standardOffsetMinutes,
        daylightOffsetMinutes: info.daylightOffsetMinutes,
        timezoneId: info.timezoneId,
        use24Hour: info.use24Hour,
      );
      final message = Zau(
        command: ZauCommand.setSystemTime,
        sub: 3,
        payload: payload,
      );
      await _sendBusinessNoResponse(message);
      final totalOffset =
          info.standardOffsetMinutes + info.daylightOffsetMinutes;
      final offsetSign = totalOffset < 0 ? '-' : '+';
      final offsetAbsolute = totalOffset.abs();
      final offset =
          '$offsetSign${(offsetAbsolute ~/ 60).toString().padLeft(2, '0')}:'
          '${(offsetAbsolute % 60).toString().padLeft(2, '0')}';
      final local = info.localTime;
      String two(int value) => value.toString().padLeft(2, '0');
      lastTimeSyncSummary =
          '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}:${two(local.second)} · '
          '${info.timezoneId} (UTC$offset) · ${info.use24Hour ? '24 小时制' : '12 小时制'}';
      _log('${automatic ? '自动' : '手动'}时间同步已发送：$lastTimeSyncSummary');
      return true;
    } on Object catch (exception) {
      final message = '时间同步失败：$exception';
      _log(message);
      if (!automatic) error = message;
      return false;
    } finally {
      _timeSyncInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _refreshAuthenticatedDeviceStatus() async {
    final session = _sessionCipher;
    final refreshEpoch = _sessionEpoch;
    if (_statusRefreshEpoch != null || !sessionReady || session == null) {
      return;
    }
    _statusRefreshEpoch = refreshEpoch;
    notifyListeners();
    try {
      await _transferSettingsReady;
      if (refreshEpoch != _sessionEpoch ||
          !sessionReady ||
          !identical(_sessionCipher, session)) {
        return;
      }
      if (autoTimeSync) {
        final synced = await syncSystemTime(automatic: true);
        if (!synced) return;
      }
      if (refreshEpoch != _sessionEpoch ||
          !sessionReady ||
          !identical(_sessionCipher, session)) {
        return;
      }
      // StorageManager uses the official Profile Channel API (module 62,
      // request command 3 / response command 4), not a ZAU 2/62 message.
      // RFCOMM currently implements PB WRITE_ENC and Mass only, so leave the
      // values unknown instead of sending an invalid request that blocks for
      // twelve seconds or interpreting unrelated business notifications.
      storageUsedBytes = null;
      storageTotalBytes = null;
      _log(
          '设备存储暂不可用：StorageManager module=62、cmd=3/4 使用独立 Profile Channel，当前 RFCOMM 尚未实现该封装');
    } on Object catch (exception) {
      _log('设备状态刷新失败：$exception');
    } finally {
      if (_statusRefreshEpoch == refreshEpoch) {
        _statusRefreshEpoch = null;
        notifyListeners();
      }
    }
  }

  Future<void> _sendBusinessNoResponse(Zau message) async {
    final cipher = _sessionCipher;
    if (cipher == null) throw StateError('认证会话已失效');
    final plaintext = message.encode();
    final encrypted = cipher.encryptOutbound(plaintext);
    _log('发送单向业务命令 ${message.command}/${message.sub}：PB=${_hex(plaintext)}');
    await _writeL2(
      channel: SppProtocol.channelPb,
      opCode: SppProtocol.opCodeWriteEnc,
      payload: encrypted,
      timeout: const Duration(seconds: 12),
    );
  }

  _BusinessWaiter _listenBusiness(int command, int sub) =>
      _registerCompletionWaiter(
          (item) => item.command == command && item.sub == sub);

  /// 官方客户端等待 command=20/sub=2 的设备安装结果，并以包名关联任务。
  /// 结果可能来自其他应用，因此不能只按命令号取第一条消息。
  _BusinessWaiter _listenQuickAppInstallResult(String packageName) =>
      _registerCompletionWaiter((item) {
        if (item.command != ZauCommand.prepareInstallApp || item.sub != 2) {
          return false;
        }
        final payload = item.payload;
        if (payload == null) return false;
        final result = V8s.parseInstallResult(payload.$2);
        if (result.packageName != packageName) {
          _log('忽略其他快应用的安装结果：${result.packageName}');
          return false;
        }
        _log('收到快应用安装结果：包名=${result.packageName}，状态=${result.code}');
        return true;
      });

  _BusinessWaiter _registerCompletionWaiter(bool Function(Zau) predicate) {
    final waiter = _BusinessWaiter(_businessResponses.stream, predicate);
    _completionWaiters.add(waiter);
    return waiter;
  }

  Future<T> _withInstallCancellation<T>(Future<T> operation) {
    final cancellation = _installCancellation;
    final transportFailure = _installTransportFailure;
    if (cancellation == null || transportFailure == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.future.then<T>((_) => throw const _InstallCancelled()),
      transportFailure.future.then<T>((error) => throw error),
    ]);
  }

  Future<void> _clearCheckpointBestEffort() async {
    try {
      await _checkpointStore.clear();
    } on Object catch (exception) {
      // 安装结果由设备事件决定；本地清理失败不能把成功误报为状态未知。
      _log('检查点清理失败，可在下次启动时安全覆盖：$exception');
    }
  }

  Future<void> _writeL2(
      {required int channel,
      required int opCode,
      required List<int> payload,
      required Duration timeout}) async {
    final queued = await _queueL2(
        channel: channel, opCode: opCode, payload: payload, timeout: timeout);
    await queued.acknowledged;
  }

  Future<_QueuedL2Write> _queueL2(
      {required int channel,
      required int opCode,
      required List<int> payload,
      required Duration timeout}) async {
    _checkCancelled();
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null || !sessionReady) throw StateError('认证会话已失效');
    final sequence = _sppSeq++ & 0xff;
    final ack = Completer<void>();
    _pendingAcks[sequence] = ack;
    if (channel == SppProtocol.channelMass) {
      _pendingMassAcks.add(sequence);
      _pendingMassAckOrder.add(sequence);
    }
    try {
      final frame = SppProtocol.buildDataFrame(sequence, payload,
          channel: channel, opCode: opCode);
      if (channel == SppProtocol.channelMass) {
        final total = payload.length >= 2 ? payload[0] | (payload[1] << 8) : 0;
        final index = payload.length >= 4 ? payload[2] | (payload[3] << 8) : 0;
        if (index == 1 || index == total || index % 25 == 0) {
          _log('  Mass TX seq=$sequence 片=$index/$total，${payload.length}B');
        }
      } else {
        _log('  RFCOMM TX seq=$sequence channel=$channel opCode=$opCode '
            'frame=${_hex(frame)}');
      }
      await _transport.rfcommWrite(device.uuid, frame);
      final acknowledged = ack.future.timeout(timeout).whenComplete(() {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
      });
      return _QueuedL2Write(acknowledged);
    } on Object {
      _pendingAcks.remove(sequence);
      _pendingMassAcks.remove(sequence);
      _pendingMassAckOrder.remove(sequence);
      rethrow;
    }
  }

  /// Queues one Mass receive window as a single stream write. RFCOMM is a byte
  /// stream, so concatenating complete L1 frames is protocol-equivalent to
  /// adjacent writes while avoiding repeated WinRT StoreAsync round trips.
  Future<void> _queueMassWindow(
    List<MassSegment> segments, {
    required InstallRequest request,
    required Map<int, int> confirmedBytesBySegment,
    required int totalBytes,
    required Duration idleTimeout,
  }) async {
    _checkCancelled();
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null || !sessionReady) throw StateError('认证会话已失效');
    if (segments.isEmpty || segments.length > 50) {
      throw ArgumentError.value(segments.length, 'segments', '窗口必须包含 1–50 片');
    }

    final frames = <int>[];
    final queued = <(int, Completer<void>)>[];
    for (final segment in segments) {
      final sequence = _sppSeq++ & 0xff;
      final ack = Completer<void>();
      _pendingAcks[sequence] = ack;
      _pendingMassAcks.add(sequence);
      _pendingMassAckOrder.add(sequence);
      _pendingMassProgress[sequence] = _MassProgressMarker(
        request: request,
        segmentIndex: segment.index,
        totalSegments: segment.total,
        confirmedBytes: confirmedBytesBySegment[segment.index] ?? 0,
        queuedSegment: segments.last.index,
        queuedBytes: confirmedBytesBySegment[segments.last.index] ?? 0,
        totalBytes: totalBytes,
      );
      queued.add((sequence, ack));
      frames.addAll(SppProtocol.buildDataFrame(
        sequence,
        segment.data,
        channel: SppProtocol.channelMass,
        opCode: SppProtocol.opCodeWrite,
      ));
    }

    final first = segments.first;
    final last = segments.last;
    if (first.index == 1 ||
        last.index == last.total ||
        segments.any((segment) => segment.index % 25 == 0)) {
      _log('  Mass TX 窗口 ${first.index}–${last.index}/${last.total}，'
          '${frames.length}B（单次 RFCOMM 写入）');
    }

    try {
      await _transport.rfcommWrite(device.uuid, frames);
    } on Object {
      for (final (sequence, _) in queued) {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
        _pendingMassProgress.remove(sequence);
      }
      rethrow;
    }

    try {
      await waitForMassAcknowledgements(
        [for (final (_, ack) in queued) ack.future],
        idleTimeout: idleTimeout,
        timeoutMessage: (acknowledged, total) =>
            'Mass ACK 空闲超时：连续 ${idleTimeout.inSeconds} 秒没有新的累计 ACK；'
            '窗口 ${first.index}–${last.index}/${last.total} 已确认 '
            '$acknowledged/$total 片，仍有 ${total - acknowledged} 片待确认。',
      );
    } finally {
      for (final (sequence, _) in queued) {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
        _pendingMassProgress.remove(sequence);
      }
    }
  }

  void _checkCancelled() {
    if (_installCancelled) throw const _InstallCancelled();
  }

  void _resetTransferSpeed({int confirmedBytes = 0}) {
    _lastSpeedSampleAt = DateTime.now();
    _lastSpeedSampleBytes = confirmedBytes;
    _confirmedBytesPerSecond = null;
  }

  void _beginTransferTiming({required int confirmedBytes}) {
    _transferStartConfirmedBytes = confirmedBytes;
    _completedTransferElapsed = null;
    _transferStopwatch = Stopwatch()..start();
    _resetTransferSpeed(confirmedBytes: confirmedBytes);
  }

  void _finishTransferTiming() {
    final stopwatch = _transferStopwatch;
    if (stopwatch == null) return;
    stopwatch.stop();
    _completedTransferElapsed = stopwatch.elapsed;
  }

  Duration? get _currentTransferElapsed =>
      _completedTransferElapsed ?? _transferStopwatch?.elapsed;

  void _updateTransferSpeed(int confirmedBytes) {
    final now = DateTime.now();
    final previousAt = _lastSpeedSampleAt;
    final elapsedMicros =
        previousAt == null ? 0 : now.difference(previousAt).inMicroseconds;
    final byteDelta = confirmedBytes - _lastSpeedSampleBytes;
    if (elapsedMicros > 0 && byteDelta > 0) {
      final instant =
          byteDelta * Duration.microsecondsPerSecond / elapsedMicros;
      final previous = _confirmedBytesPerSecond;
      _confirmedBytesPerSecond =
          previous == null ? instant : previous * 0.65 + instant * 0.35;
    }
    _lastSpeedSampleAt = now;
    _lastSpeedSampleBytes = confirmedBytes;
  }

  void _publishTask(InstallRequest request, InstallStage stage, String message,
      {int? currentSegment,
      int? totalSegments,
      int? confirmedBytes,
      int? queuedSegment,
      int? queuedBytes,
      int? totalBytes,
      double? bytesPerSecond}) {
    final previous = latestTask;
    final sameTask = previous != null &&
        previous.kind == request.kind &&
        previous.fileName == request.metadata.fileName &&
        previous.md5Hex == request.metadata.md5Hex;
    final keepProgress = sameTask &&
        stage != InstallStage.validating &&
        stage != InstallStage.waitingForProtocol;
    final resolvedCurrentSegment =
        currentSegment ?? (keepProgress ? previous.currentSegment : null);
    final resolvedTotalSegments =
        totalSegments ?? (keepProgress ? previous.totalSegments : null);
    final resolvedConfirmedBytes =
        confirmedBytes ?? (keepProgress ? previous.confirmedBytes : null);
    final resolvedQueuedSegment =
        queuedSegment ?? (keepProgress ? previous.queuedSegment : null);
    final resolvedQueuedBytes =
        queuedBytes ?? (keepProgress ? previous.queuedBytes : null);
    final resolvedTotalBytes =
        totalBytes ?? (keepProgress ? previous.totalBytes : null);
    final resolvedSpeed =
        bytesPerSecond ?? (keepProgress ? previous.bytesPerSecond : null);
    final transferElapsed = _currentTransferElapsed;
    final transferredBytes =
        (resolvedConfirmedBytes ?? 0) - _transferStartConfirmedBytes;
    final averageBytesPerSecond = transferElapsed != null &&
            transferElapsed.inMicroseconds > 0 &&
            transferredBytes > 0
        ? transferredBytes *
            Duration.microsecondsPerSecond /
            transferElapsed.inMicroseconds
        : null;
    latestTask = InstallTask(
        kind: request.kind,
        fileName: request.metadata.fileName,
        stage: stage,
        message: message,
        targetDeviceName: connectedDeviceName ?? connectedProfile?.displayName,
        md5Hex: request.metadata.md5Hex,
        faceId: request.metadata.faceId,
        packageName: request.metadata.packageName,
        versionCode: request.metadata.versionCode,
        currentSegment: resolvedCurrentSegment,
        totalSegments: resolvedTotalSegments,
        confirmedBytes: resolvedConfirmedBytes,
        queuedSegment: resolvedQueuedSegment,
        queuedBytes: resolvedQueuedBytes,
        totalBytes: resolvedTotalBytes,
        bytesPerSecond: resolvedSpeed,
        elapsed: _installStopwatch?.elapsed,
        transferElapsed: transferElapsed,
        averageBytesPerSecond: averageBytesPerSecond);
    final shouldLog = stage != InstallStage.transferring ||
        currentSegment == 1 ||
        currentSegment == totalSegments ||
        (currentSegment != null && currentSegment % 25 == 0);
    if (shouldLog) {
      _log('安装任务：${stage.name} — $message');
    } else {
      notifyListeners();
    }
  }

  List<int> _hexToBytes(String hex) => [
        for (var index = 0; index < hex.length; index += 2)
          int.parse(hex.substring(index, index + 2), radix: 16),
      ];

  @override
  void dispose() {
    _disposed = true;
    _sppWatchdog?.cancel();
    _sppWatchdog = null;
    unawaited(_scanSubscription?.cancel());
    unawaited(_sppSub?.cancel());
    _sppSub = null;
    for (final waiter in _completionWaiters) {
      unawaited(waiter.cancel());
    }
    _completionWaiters.clear();
    unawaited(_businessResponses.close());
    final device = connectedDevice ?? _lastPeripheral;
    if (device != null) {
      unawaited(_transport.disconnectRfcomm(device.uuid).catchError((_) {}));
    }
    unawaited(_transport.disposeRfcommStream());
    super.dispose();
  }
}

class _InstallCancelled implements Exception {
  const _InstallCancelled();
}

class _DeviceInstallFailed implements Exception {
  const _DeviceInstallFailed(this.message);

  final String message;
}

class _InvalidDeviceResponse implements Exception {
  const _InvalidDeviceResponse(this.message);

  final String message;
}

class _QueuedL2Write {
  const _QueuedL2Write(this.acknowledged);

  final Future<void> acknowledged;
}

/// Cancellable buffered wait for an asynchronous business event.
///
/// The listener is installed before Mass transfer begins, but no timer is
/// started here. This prevents both missing an early result and incorrectly
/// charging file-transfer time against the device-install timeout.
class _BusinessWaiter {
  _BusinessWaiter(Stream<Zau> stream, bool Function(Zau) predicate) {
    _subscription = stream.listen((item) {
      if (_completer.isCompleted) return;
      try {
        if (!predicate(item)) return;
        _completer.complete(item);
        unawaited(_subscription.cancel());
      } on Object catch (error, stackTrace) {
        _completer.completeError(error, stackTrace);
        unawaited(_subscription.cancel());
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!_completer.isCompleted) {
        _completer.completeError(error, stackTrace);
      }
    });
  }

  final Completer<Zau> _completer = Completer<Zau>();
  late final StreamSubscription<Zau> _subscription;

  Future<Zau> get future => _completer.future;

  Future<void> cancel() => _subscription.cancel();
}

/// Maps an L1 Mass sequence number back to exact source-file progress.
/// ACK handling publishes only the newest marker in one cumulative ACK, so a
/// large RFCOMM write remains fast without rebuilding the Flutter UI per frame.
class _MassProgressMarker {
  const _MassProgressMarker({
    required this.request,
    required this.segmentIndex,
    required this.totalSegments,
    required this.confirmedBytes,
    required this.queuedSegment,
    required this.queuedBytes,
    required this.totalBytes,
  });

  final InstallRequest request;
  final int segmentIndex;
  final int totalSegments;
  final int confirmedBytes;
  final int queuedSegment;
  final int queuedBytes;
  final int totalBytes;
}
