import 'dart:async';

import 'port.dart';

/// Synthetic replacement-UI data used by the `--fixture` preview mode.
///
/// It deliberately models only [UiNextPort] state: it neither imports the
/// legacy frontend nor starts Bluetooth, persistence, or installation work.
final class UiNextFixtures {
  const UiNextFixtures._();

  static const names = <String>[
    'base',
    'scanFinished',
    'queueWaiting',
    'awaitingAuthKey',
    'rfcommRebuildRequired',
    'ready',
    'queueRunningTransfer',
    'awaitingDevice100',
    'installSucceeded',
    'installFailed',
    'installStateUnknown',
    'recoveryAvailable',
    'pendingDecisions',
    'logs',
  ];

  static UiSnapshot load(String name) => switch (name) {
        'scanFinished' => _base(
            revision: 2,
            devices: <UiDevice>[
              _supportedDevice(saved: true),
              _unknownDevice(),
            ],
            notice: '扫描完成：找到 2 台设备。',
          ),
        'queueWaiting' => _ready(
            revision: 3,
            notice: '预览：有 2 个资源等待安装。按 i 选择资源安装。',
          ),
        'awaitingAuthKey' => _base(
            revision: 4,
            devices: <UiDevice>[_supportedDevice(saved: true)],
            connectionPhase: UiConnectionPhase.awaitingAuthKey,
            connectedDeviceId: _primaryMac,
            notice: '已建立传输会话，等待输入 authkey。',
          ),
        'rfcommRebuildRequired' => _base(
            revision: 5,
            devices: <UiDevice>[_supportedDevice(saved: true)],
            error: 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。',
          ),
        'ready' => _ready(revision: 6),
        'queueRunningTransfer' => _ready(
            revision: 7,
            install: const UiInstallStatus(
              phase: UiInstallPhase.transferring,
              fileName: 'cat_face.bin',
              confirmedBytes: 14850,
              totalBytes: 158400,
              message: '正在发送资源，设备确认第 15 个分片。',
            ),
          ),
        'awaitingDevice100' => _ready(
            revision: 8,
            install: const UiInstallStatus(
              phase: UiInstallPhase.awaitingDevice,
              fileName: 'cat_face.bin',
              confirmedBytes: 158400,
              totalBytes: 158400,
              message: '字节已确认发送，等待设备业务完成事件。',
            ),
          ),
        'installSucceeded' => _ready(
            revision: 9,
            install: const UiInstallStatus(
              phase: UiInstallPhase.succeeded,
              fileName: 'cat_face.bin',
              confirmedBytes: 158400,
              totalBytes: 158400,
              message: '设备已确认资源安装成功。',
              successVerifiedByDeviceBusinessEvent: true,
            ),
          ),
        'installFailed' => _ready(
            revision: 10,
            install: const UiInstallStatus(
              phase: UiInstallPhase.failed,
              fileName: 'cat_face.bin',
              confirmedBytes: 158400,
              totalBytes: 158400,
              message: '设备拒绝资源安装，状态=3。',
            ),
            error: '安装失败：设备拒绝资源安装，状态=3。',
          ),
        'installStateUnknown' => _ready(
            revision: 11,
            install: const UiInstallStatus(
              phase: UiInstallPhase.unknown,
              fileName: 'cat_face.bin',
              confirmedBytes: 79200,
              totalBytes: 158400,
              message: '设备加密响应无法验证，安装状态未知。',
            ),
            error: '安装状态未知；请在设备上确认结果后再重试。',
          ),
        'recoveryAvailable' => _ready(
            revision: 12,
            notice: '预览：检测到可恢复的资源传输检查点。',
          ),
        'pendingDecisions' => _base(
            revision: 13,
            devices: <UiDevice>[_supportedDevice()],
            notice: '预览：资源元数据需要用户确认后才能继续。',
          ),
        'logs' => _base(
            revision: 14,
            devices: <UiDevice>[_supportedDevice(), _unknownDevice()],
            notice: '预览：新 TUI 不渲染日志面板；运行日志保持在后端诊断通道。',
          ),
        _ => _base(),
      };

  static const _primaryMac = 'AA:BB:CC:DD:EE:FF';

  static UiSnapshot _base({
    int revision = 1,
    List<UiDevice> devices = const <UiDevice>[],
    UiConnectionPhase connectionPhase = UiConnectionPhase.disconnected,
    String? connectedDeviceId,
    UiInstallStatus install = const UiInstallStatus(),
    String? notice,
    String? error,
  }) =>
      UiSnapshot(
        revision: revision,
        devices: devices,
        connectionPhase: connectionPhase,
        connectedDeviceId: connectedDeviceId,
        install: install,
        notice: notice,
        error: error,
      );

  static UiSnapshot _ready({
    required int revision,
    UiInstallStatus install = const UiInstallStatus(),
    String? notice,
    String? error,
  }) =>
      _base(
        revision: revision,
        devices: <UiDevice>[_supportedDevice(saved: true, connected: true)],
        connectionPhase: UiConnectionPhase.ready,
        connectedDeviceId: _primaryMac,
        install: install,
        notice: notice,
        error: error,
      );

  static UiDevice _supportedDevice({
    bool saved = false,
    bool connected = false,
  }) =>
      UiDevice(
        name: 'Xiaomi Smart Band 10 Pro 完整设备名称预览',
        macAddress: _primaryMac,
        support: UiDeviceSupport.supported,
        saved: saved,
        savedAuthKey: saved ? '00112233445566778899AABBCCDDEEFF' : null,
        connected: connected,
      );

  static UiDevice _unknownDevice() => UiDevice(
        name: 'Smart Band 9',
        macAddress: '11:22:33:44:55:66',
        support: UiDeviceSupport.unknown,
      );
}

/// In-memory [UiNextPort] for interactive fixture previews and frontend tests.
/// No action reaches a macOS helper or a persistence store.
final class FakeUiNextPort implements UiNextPort {
  FakeUiNextPort({required UiSnapshot initial}) : _snapshot = initial;

  UiSnapshot _snapshot;
  final StreamController<UiSnapshot> _snapshots =
      StreamController<UiSnapshot>.broadcast(sync: true);
  final List<String> recordedActions = <String>[];
  bool _disposed = false;

  @override
  UiSnapshot get snapshot => _snapshot;

  @override
  Stream<UiSnapshot> get snapshots => Stream<UiSnapshot>.multi((listener) {
        listener.add(_snapshot);
        final subscription = _snapshots.stream.listen(
          listener.add,
          onError: listener.addError,
          onDone: listener.close,
        );
        listener.onCancel = subscription.cancel;
      });

  @override
  Future<UiActionResult> initialize() => _accept('initialize');

  @override
  Future<UiActionResult> scan() {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      scanning: !_snapshot.scanning,
      notice: _snapshot.scanning ? '预览扫描已停止。' : '预览扫描已启动。',
      clearError: true,
    ));
    return _accept('scan');
  }

  @override
  Future<UiActionResult> connect(String macAddress) {
    final id = UiDevice.normalizeMac(macAddress);
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      connectionPhase: UiConnectionPhase.connecting,
      connectedDeviceId: id,
      notice: '预览连接请求已接受：$id',
      clearError: true,
    ));
    return _accept('connect');
  }

  @override
  Future<UiActionResult> connectDirectedExactAddress() async =>
      const UiActionResult.rejected('预览没有配置定向 Classic 设备。');

  @override
  Future<UiActionResult> disconnect() {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      connectionPhase: UiConnectionPhase.disconnected,
      clearConnectedDeviceId: true,
      devices: _snapshot.devices
          .map((device) => device.copyWith(connected: false))
          .toList(growable: false),
      notice: '预览连接已断开。',
      clearError: true,
    ));
    return _accept('disconnect');
  }

  @override
  Future<UiActionResult> saveDevice(String macAddress) => _updateDevice(
        'saveDevice',
        macAddress,
        (device) => device.copyWith(saved: true),
      );

  @override
  Future<UiActionResult> removeSavedDevice(String macAddress) => _updateDevice(
        'removeSavedDevice',
        macAddress,
        (device) => device.copyWith(saved: false, clearSavedAuthKey: true),
      );

  @override
  Future<UiActionResult> submitAuthKey(String macAddress, String authKey) =>
      _updateDevice(
        'submitAuthKey',
        macAddress,
        (device) => device.copyWith(saved: true, savedAuthKey: authKey),
      );

  @override
  Future<UiActionResult> installResource(String macAddress, String path) {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      install: UiInstallStatus(
        phase: UiInstallPhase.preparing,
        fileName: path.split('/').last,
        message: '预览安装任务已创建。',
      ),
      notice: '预览安装任务已创建。',
      clearError: true,
    ));
    return _accept('installResource');
  }

  @override
  Future<UiActionResult> cancelInstall() {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      install: _snapshot.install.copyWith(
        phase: UiInstallPhase.idle,
        message: '预览安装已取消。',
      ),
      notice: '预览安装已取消。',
    ));
    return _accept('cancelInstall');
  }

  @override
  Future<UiActionResult> setAutoConnect(bool enabled) {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      autoConnect: enabled,
      autoConnectState:
          enabled ? UiAutoConnectState.idle : UiAutoConnectState.disabled,
      notice: enabled ? '预览自动连接已开启。' : '预览自动连接已关闭。',
    ));
    return _accept('setAutoConnect');
  }

  @override
  Future<UiActionResult> setThemeId(String themeId) {
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      themeId: themeId,
      notice: '预览主题已切换为 $themeId。',
    ));
    return _accept('setThemeId');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _snapshots.close();
  }

  Future<UiActionResult> _updateDevice(
    String action,
    String macAddress,
    UiDevice Function(UiDevice device) update,
  ) {
    final id = UiDevice.normalizeMac(macAddress);
    _emit(_snapshot.copyWith(
      revision: _snapshot.revision + 1,
      devices: _snapshot.devices
          .map((device) => device.id == id ? update(device) : device)
          .toList(growable: false),
      notice: '预览操作已接受：$action。',
      clearError: true,
    ));
    return _accept(action);
  }

  Future<UiActionResult> _accept(String action) async {
    recordedActions.add(action);
    return UiActionResult.accepted('预览操作已接受：$action。');
  }

  void _emit(UiSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    _snapshots.add(next);
  }
}
