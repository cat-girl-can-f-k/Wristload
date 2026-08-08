/// Supported device families. Runtime BLE data remains authoritative: a family
/// match alone never enables file installation.
///
/// 协议代数（逆向确认，2026-08-07）：
/// - [ProtocolGeneration.v2Vela]：手环 9（N66）及以后的新 Vela —— 单通道
///   fe95 + L1(0xA525)/L2 + Mass 通道（`BleTaskQueueV2`）。本项目已实现。
/// - [ProtocolGeneration.v1Vela]：M66/M67（手环 8/8 Pro）等旧 Vela —— 多通道
///   直写 + 老 Mili 帧（`BleTaskQueueV1`）。暂不支持，需另行实现。
enum DeviceFamily {
  band9,
  band9Pro,
  band10,
  band10Pro,
  watchS4,
  redmiWatch5,
  redmiWatch6,
  unknown,
}

enum ProtocolGeneration { v2Vela, v1Vela, unknown }

class DeviceProfile {
  const DeviceProfile({
    required this.family,
    required this.displayName,
    required this.modelHints,
    this.adNameHints = const [],
    this.capabilities = const DeviceCapabilities(),
  });

  final DeviceFamily family;
  final String displayName;

  /// model 前缀（如固件包名 `miwear.watch.n66*`），供连接后读取型号匹配。
  final Set<String> modelHints;

  /// BLE 广播名关键词（启发式，供扫描列表标注；真机确认前不作为门控依据）。
  final List<String> adNameHints;

  final DeviceCapabilities capabilities;

  /// 协议代数。N66 及以后 = [ProtocolGeneration.v2Vela]。
  ProtocolGeneration get generation => switch (family) {
        DeviceFamily.band9 ||
        DeviceFamily.band9Pro ||
        DeviceFamily.band10 ||
        DeviceFamily.band10Pro ||
        DeviceFamily.watchS4 ||
        DeviceFamily.redmiWatch5 ||
        DeviceFamily.redmiWatch6 =>
          ProtocolGeneration.v2Vela,
        _ => ProtocolGeneration.unknown,
      };

  /// 用广播名做启发式识别（大小写不敏感、包含匹配）。
  static DeviceProfile? matchAdvertisementName(String name) {
    if (name.isEmpty) return null;
    final lower = name.toLowerCase();
    for (final profile in supported) {
      if (profile.adNameHints.any(lower.contains)) return profile;
    }
    return null;
  }

  /// Hints 依据：用户提供的型号汇总表 + 固件包名（`upd_miwear.watch.*`）。
  /// 更完整的 model ↔ 产品映射需真机身份抓取后补充。
  static const supported = <DeviceProfile>[
    DeviceProfile(
      family: DeviceFamily.band9,
      displayName: '小米手环 9 系列',
      modelHints: {'miwear.watch.n66', 'miwear.watch.n66cn'},
      adNameHints: ['smart band 9', 'band 9'],
    ),
    DeviceProfile(
      family: DeviceFamily.band9Pro,
      displayName: '小米手环 9 Pro',
      modelHints: {'miwear.watch.n67', 'miwear.watch.n67cn'},
      adNameHints: ['smart band 9 pro', 'band 9 pro'],
    ),
    DeviceProfile(
      family: DeviceFamily.band10,
      displayName: '小米手环 10',
      modelHints: {'miwear.watch.o66', 'miwear.watch.o66cn'},
      adNameHints: ['smart band 10', 'band 10'],
    ),
    DeviceProfile(
      family: DeviceFamily.band10Pro,
      displayName: '小米手环 10 Pro',
      modelHints: {'miwear.watch.p67cn'},
      adNameHints: ['smart band 10 pro', 'band 10 pro'],
    ),
    DeviceProfile(
      family: DeviceFamily.watchS4,
      displayName: '小米 Watch S4 系列',
      modelHints: {'miwear.watch.o63', 'miwear.watch.o62'},
      adNameHints: ['watch s4'],
    ),
    DeviceProfile(
      family: DeviceFamily.redmiWatch5,
      displayName: 'REDMI Watch 5',
      modelHints: {'miwear.watch.o65'},
      adNameHints: ['redmi watch 5'],
    ),
    DeviceProfile(
      family: DeviceFamily.redmiWatch6,
      displayName: 'REDMI Watch 6',
      modelHints: {'miwear.watch.p65'},
      adNameHints: ['redmi watch 6'],
    ),
  ];
}

class DeviceCapabilities {
  const DeviceCapabilities({
    this.watchface = false,
    this.thirdPartyApp = false,
  });

  final bool watchface;
  final bool thirdPartyApp;
}
