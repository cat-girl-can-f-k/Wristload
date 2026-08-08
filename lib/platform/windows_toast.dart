import 'package:flutter/services.dart';

/// Windows 系统 toast 通知（配对提示等）。
///
/// 直接走插件 Pigeon 通道调用 C++ 原生实现（winrt
/// `ToastNotificationManager`，无 AUMID 时以 exe 名临时标识，Win10 1803+
/// 可正常显示）。失败静默——UI 内日志仍会给出提示。
class WindowsToast {
  WindowsToast._();

  static final WindowsToast instance = WindowsToast._();

  /// 弹出 Windows toast。失败静默。
  Future<void> show(String title, String body) async {
    try {
      const channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.showToast',
        StandardMessageCodec(),
      );
      await channel.send(<Object?>[title, body]);
    } catch (_) {
      // 静默降级。
    }
  }
}
