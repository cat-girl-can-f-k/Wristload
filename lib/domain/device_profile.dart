/// Supported device families. Runtime BLE data remains authoritative: a family
/// match alone never enables file installation.
///
/// 协议代数（逆向确认，2026-08-07）：
/// - [ProtocolGeneration.v2Vela]：手环 9（N66）及以后的新 Vela —— 单通道
///   fe95 + L1(`A5 A5`)/L2 + Mass 通道（`BleTaskQueueV2`）。本项目已实现。
/// - [ProtocolGeneration.v1Vela]：M66/M67（手环 8/8 Pro）等旧 Vela —— 多通道
///   直写 + 老 Mili 帧（`BleTaskQueueV1`）。暂不支持，需另行实现。
/// - [ProtocolGeneration.huamiZepp]：手环 7 Pro 等华米设备，使用另一套
///   Zepp/Huami 协议栈，不能复用 Vela V1。
enum DeviceFamily {
  band7Pro,
  band8Pro,
  band9,
  band9Pro,
  band10,
  band10Pro,
  watchS4,
  watchS5,
  redmiWatch4,
  redmiWatch5,
  redmiWatch6,
  unknown,
}

enum ProtocolGeneration { v2Vela, v1Vela, huamiZepp, unknown }

/// 现代模式只进入已验证的 V2 安装链路；经典模式只做旧设备的安全
/// GATT 枚举与协议取证，在旧传输协议验证完成前不会开放安装按钮。
enum ConnectionMode { modern, classicExperimental }

class DeviceProfile {
  const DeviceProfile({
    required this.family,
    required this.displayName,
    required this.modelHints,
    this.adNameHints = const [],
  });

  final DeviceFamily family;
  final String displayName;

  /// model 前缀（如固件包名 `miwear.watch.n66*`），供连接后读取型号匹配。
  final Set<String> modelHints;

  /// BLE 广播名关键词（启发式，供扫描列表标注；真机确认前不作为门控依据）。
  final List<String> adNameHints;

  WatchfaceResolution? get watchfaceResolution => switch (family) {
        DeviceFamily.band9Pro || DeviceFamily.band10Pro =>
          const WatchfaceResolution(336, 480),
        DeviceFamily.redmiWatch5 || DeviceFamily.redmiWatch6 =>
          const WatchfaceResolution(432, 514),
        DeviceFamily.watchS4 || DeviceFamily.watchS5 =>
          const WatchfaceResolution(464, 464),
        _ => null,
      };

  /// 协议代数。N66 及以后 = [ProtocolGeneration.v2Vela]。
  ProtocolGeneration get generation => switch (family) {
        DeviceFamily.band9 ||
        DeviceFamily.band9Pro ||
        DeviceFamily.band10 ||
        DeviceFamily.band10Pro ||
        DeviceFamily.watchS4 ||
        DeviceFamily.watchS5 ||
        DeviceFamily.redmiWatch5 ||
        DeviceFamily.redmiWatch6 =>
          ProtocolGeneration.v2Vela,
        DeviceFamily.band8Pro =>
          ProtocolGeneration.v1Vela,
        DeviceFamily.band7Pro => ProtocolGeneration.huamiZepp,
        // REDMI Watch 4 的工具侧入口虽为经典蓝牙，但运动健康的实际
        // 队列/鉴权分支仍需真机帧确认，暂不把它冒充 Vela V1。
        DeviceFamily.redmiWatch4 => ProtocolGeneration.unknown,
        _ => ProtocolGeneration.unknown,
      };

  /// 用广播名做启发式识别（大小写不敏感、包含匹配）。
  static DeviceProfile? matchAdvertisementName(String name) {
    if (name.isEmpty) return null;
    final lower = name.toLowerCase();
    final compact = lower.replaceAll(RegExp(r'[\s_-]+'), '');

    if (lower.contains('redmi') && lower.contains('watch')) {
      if (RegExp(r'watch\s*6').hasMatch(lower)) return redmiWatch6;
      if (RegExp(r'watch\s*5').hasMatch(lower)) return redmiWatch5;
      if (RegExp(r'watch\s*4').hasMatch(lower)) return redmiWatch4;
    }
    if (lower.contains('band')) {
      if (compact.contains('band10pro')) return band10Pro;
      if (compact.contains('band10')) return band10;
      if (compact.contains('band9pro')) return band9Pro;
      if (compact.contains('band9')) return band9;
      if (compact.contains('band8pro')) return band8Pro;
      if (compact.contains('band7pro')) return band7Pro;
    }
    if (lower.contains('watch')) {
      if (RegExp(r'watch\s*s5').hasMatch(lower)) return watchS5;
      if (RegExp(r'watch\s*s4').hasMatch(lower)) return watchS4;
    }
    return null;
  }

  /// Hints 依据：用户提供的型号汇总表 + 固件包名（`upd_miwear.watch.*`）。
  /// 更完整的 model ↔ 产品映射需真机身份抓取后补充。
  static const band7Pro = DeviceProfile(
    family: DeviceFamily.band7Pro,
    displayName: '小米手环 7 Pro（经典实验）',
    modelHints: {'hqbd3.watch.l67', 'hqbd3.watch.l67in'},
    adNameHints: ['smart band 7 pro', 'band 7 pro'],
  );
  static const band8Pro = DeviceProfile(
    family: DeviceFamily.band8Pro,
    displayName: '小米手环 8 Pro（经典实验）',
    modelHints: {'lchz.watch.m67', 'lchz.watch.m67gl'},
    adNameHints: ['smart band 8 pro', 'band 8 pro'],
  );
  static const band9 = DeviceProfile(
      family: DeviceFamily.band9,
      displayName: '小米手环 9 系列',
      modelHints: {'miwear.watch.n66', 'miwear.watch.n66cn'},
      adNameHints: ['smart band 9', 'band 9'],
    );
  static const band9Pro = DeviceProfile(
      family: DeviceFamily.band9Pro,
      displayName: '小米手环 9 Pro',
      modelHints: {'miwear.watch.n67', 'miwear.watch.n67cn'},
      adNameHints: ['smart band 9 pro', 'band 9 pro'],
    );
  static const band10 = DeviceProfile(
      family: DeviceFamily.band10,
      displayName: '小米手环 10',
      modelHints: {'miwear.watch.o66', 'miwear.watch.o66cn'},
      adNameHints: ['smart band 10', 'band 10'],
    );
  static const band10Pro = DeviceProfile(
      family: DeviceFamily.band10Pro,
      displayName: '小米手环 10 Pro',
      modelHints: {'miwear.watch.p67cn'},
      adNameHints: ['smart band 10 pro', 'band 10 pro'],
    );
  static const watchS4 = DeviceProfile(
      family: DeviceFamily.watchS4,
      displayName: '小米 Watch S4 系列',
      modelHints: {'miwear.watch.o63', 'miwear.watch.o62'},
      adNameHints: ['watch s4'],
    );
  static const watchS5 = DeviceProfile(
      family: DeviceFamily.watchS5,
      displayName: '小米 Watch S5 系列',
      modelHints: {'miwear.watch.s5'},
      adNameHints: ['watch s5'],
    );
  static const redmiWatch5 = DeviceProfile(
      family: DeviceFamily.redmiWatch5,
      displayName: 'REDMI Watch 5',
      modelHints: {'miwear.watch.o65'},
      adNameHints: ['redmi watch 5'],
    );
  static const redmiWatch4 = DeviceProfile(
    family: DeviceFamily.redmiWatch4,
    displayName: 'REDMI Watch 4（经典实验）',
    modelHints: {'lchz.watch.n65', 'lchz.watch.n65gl'},
    adNameHints: ['redmi watch 4'],
  );
  static const redmiWatch6 = DeviceProfile(
      family: DeviceFamily.redmiWatch6,
      displayName: 'REDMI Watch 6',
      modelHints: {'miwear.watch.p65'},
      adNameHints: ['redmi watch 6'],
    );

  /// 可从广播名识别的型号；其中仅 V2 型号代表已支持安装。
  static const recognized = <DeviceProfile>[
    band7Pro,
    band8Pro,
    redmiWatch4,
    band9Pro,
    band10Pro,
    band9,
    band10,
    watchS4,
    watchS5,
    redmiWatch5,
    redmiWatch6,
  ];
}

class WatchfaceResolution {
  const WatchfaceResolution(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is WatchfaceResolution &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '$width×$height';
}
