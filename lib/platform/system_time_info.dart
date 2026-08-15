import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../application/diagnostic_log_service.dart';

class SystemTimeInfo {
  const SystemTimeInfo({
    required this.localTime,
    required this.standardOffsetMinutes,
    required this.daylightOffsetMinutes,
    required this.timezoneId,
    required this.use24Hour,
  });

  final DateTime localTime;
  final int standardOffsetMinutes;
  final int daylightOffsetMinutes;
  final String timezoneId;
  final bool use24Hour;
}

class SystemTimeInfoSource {
  const SystemTimeInfoSource();

  static const _channel = MethodChannel('wristload/system_time');

  Future<SystemTimeInfo> read() async {
    appLogger.trace('系统时间信息读取开始', category: DiagnosticLogCategory.runtime);
    final now = DateTime.now();
    final nativePlatform = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (!nativePlatform) {
      final info = SystemTimeInfo(
        localTime: now,
        standardOffsetMinutes: now.timeZoneOffset.inMinutes,
        daylightOffsetMinutes: 0,
        timezoneId: now.timeZoneName,
        use24Hour: true,
      );
      appLogger.debug('系统时间信息读取完成', category: DiagnosticLogCategory.runtime, fields: <String, Object?>{'timezoneId': info.timezoneId, 'offsetMinutes': info.localTime.timeZoneOffset.inMinutes, 'native': false});
      return info;
    }
    final values = await _channel.invokeMapMethod<String, Object?>('read');
    if (values == null) {
      throw PlatformException(
        code: 'system_time',
        message: 'Native system time information is unavailable',
      );
    }
    final standardOffset = values['standardOffsetMinutes'];
    final daylightOffset = values['daylightOffsetMinutes'];
    final timezoneId = values['timezoneId'];
    final use24Hour = values['use24Hour'];
    if (standardOffset is! int ||
        daylightOffset is! int ||
        timezoneId is! String ||
        timezoneId.isEmpty ||
        use24Hour is! bool) {
      throw const FormatException(
          'The platform returned invalid system time information');
    }
    final info = SystemTimeInfo(
      localTime: now,
      standardOffsetMinutes: standardOffset,
      daylightOffsetMinutes: daylightOffset,
      timezoneId: timezoneId,
      use24Hour: use24Hour,
    );
    appLogger.debug('系统时间信息读取完成', category: DiagnosticLogCategory.runtime, fields: <String, Object?>{'timezoneId': info.timezoneId, 'standardOffsetMinutes': standardOffset, 'daylightOffsetMinutes': daylightOffset, 'use24Hour': use24Hour, 'native': true});
    return info;
  }
}
