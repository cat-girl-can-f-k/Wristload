/// 私有协议核心接口：能力查询、表盘安装、RPK 安装。
///
/// 实现分层（见 `lib/domain/protocol/`）：
/// - [Zau]、[A9u]、[V8s]、[O1h]：protobuf 命令载荷
/// - [L1Frame]/[L2Frame]：SAR 传输帧
/// - [splitMassFile]：Mass 文件分片
///
/// ⚠️ 连接鉴权（authkey）前置：GATT 连接 + L1START 握手后，设备要求先完成
/// authkey 校验才能进入可用会话（否则 `AUTH_FAILED`/「device not bound」）。
/// 反编译确认（见 analysis/连接鉴权_authkey校验_小米运动健康_9.23.35.md）：
/// - 旧固件 WearAuthV1：`abu{e=1,f=5}` 携带 userId，设备比对绑定关系；
/// - 新固件 WearAuthV2：`f=26`(sendAppVerify) → HKDF-SHA256(authKey,
///   randomApp‖randomDevice, info="miwear-auth") 派生 DeviceKey/AppKey/IV，
///   HMAC-SHA256 双向签名 → `f=27`(sendAppConfirm) → 会话密钥生效；
/// - auth 报文走 L2{channel=1, opCode=1} **明文**；业务 protobuf 才走
///   opCode=2(WRITE_ENC) + AES-CTR。
/// authKey 即绑定 token：App 绑定流程生成（`"token.%d.%f"` → MD5 中间 12B →
/// hex 24 字符），经服务器签名后 `zau{e=1,f=2}` 下发给设备保存；本地绑定则
/// 由设备返回随机 token。解绑后 token 失效。
/// 实现本协议前必须先实现并真机验证该鉴权握手。
///
/// ⚠️ 验证门控：在真机 HCI 验证完成前，真实发送被 [VerificationGate]
/// 阻断；任何安装调用只会产出「等待协议验证」任务，绝不向设备发送未知帧。
library;

import 'device_profile.dart';
import 'install_task.dart';
import 'protocol/zau.dart';

/// 已由 n67cn 官方连接日志验证的范围：RFCOMM、SPP 版本读取、L1START、
/// 以及 `sendAppVerify → sendAppConfirm` 的会话顺序。它只解锁“连接认证”按钮，
/// 不解锁表盘、RPK 或其他业务命令。
const bool kSppAuthProtocolVerified = true;

/// 安装协议开关。文件传输/安装确认尚未完成真机验证，必须保持 false。
const bool kProtocolVerified = false;

/// 协议验证门控。集中管理「能否真正发送」。
class VerificationGate {
  const VerificationGate();

  /// 未验证时抛错，由上层转成等待任务。
  void ensureCanSend() {
    if (!kProtocolVerified) {
      throw StateError('协议尚未通过真机 HCI 验证，禁止发送私有帧');
    }
  }
}

/// 边界：私有协议接口。实现仅在帧级验证后启用。
abstract interface class WearProtocol {
  Future<DeviceCapabilities> queryCapabilities();
  Stream<InstallTask> installWatchface(String path);
  Stream<InstallTask> installQuickApp(String path);
}

/// 安全占位实现：在协议验证前使用，绝不发送数据。
/// 构造时可传入 [deviceProfile]，用于能力门控与日志。
class UnverifiedWearProtocol implements WearProtocol {
  UnverifiedWearProtocol({this.deviceProfile, this.gate = const VerificationGate()});

  final DeviceProfile? deviceProfile;
  final VerificationGate gate;

  @override
  Future<DeviceCapabilities> queryCapabilities() async {
    // 已确认：能力在连接后由设备上报（model/pd_id/firmware/capability）。
    return deviceProfile?.capabilities ?? const DeviceCapabilities();
  }

  @override
  Stream<InstallTask> installWatchface(String path) async* {
    yield _blockedTask(InstallKind.watchface, path,
        '表盘链路：预装 zau(4,4,a9u) → Mass(type=1) → 结果 zau(4,5) → setFace(4,1)');
  }

  @override
  Stream<InstallTask> installQuickApp(String path) async* {
    yield _blockedTask(InstallKind.quickApp, path,
        'RPK 链路：预装 zau(20,1,v8s) → Mass(type=4) → AppStatus 11');
  }

  InstallTask _blockedTask(InstallKind kind, String path, String chain) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final capabilityOk = switch (kind) {
      InstallKind.watchface => deviceProfile?.capabilities.watchface ?? false,
      InstallKind.quickApp => deviceProfile?.capabilities.thirdPartyApp ?? false,
    };
    return InstallTask(
      kind: kind,
      fileName: name,
      stage: InstallStage.waitingForProtocol,
      message: capabilityOk
          ? '设备已声明能力，但私有协议尚未通过 HCI 验证，未发送任何数据。'
              '（$chain）'
          : '设备未声明该能力或协议未验证，未发送任何数据。',
    );
  }
}
