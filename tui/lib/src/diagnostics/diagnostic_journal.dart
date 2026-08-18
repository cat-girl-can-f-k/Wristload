import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum DiagnosticSeverity { trace, debug, info, warning, error, fatal }

enum DiagnosticCategory {
  scan,
  select,
  pairing,
  sdp,
  rfcomm,
  rawTx,
  rawRx,
  framing,
  auth,
  session,
  storage,
  autoConnect,
  install,
  system,
}

String _categoryName(DiagnosticCategory value) => switch (value) {
      DiagnosticCategory.rawTx => 'raw_tx',
      DiagnosticCategory.rawRx => 'raw_rx',
      DiagnosticCategory.autoConnect => 'auto_connect',
      _ => value.name,
    };

DiagnosticCategory _categoryFromName(String value) =>
    DiagnosticCategory.values.firstWhere(
      (item) => _categoryName(item) == value,
      orElse: () => DiagnosticCategory.system,
    );

/// One structured, redacted journal record. Authentication keys and session
/// secrets are deliberately absent from the typed schema.
class DiagnosticEvent {
  DiagnosticEvent({
    required this.timestamp,
    required this.severity,
    required this.category,
    required this.message,
    String? id,
    String? scope,
    String? component,
    String? event,
    this.deviceId,
    this.sessionId,
    String? connectionId,
    int? generation,
    String? transport,
    this.nativeDomain,
    this.nativeCode,
    this.disconnectReason,
    this.timeoutMs,
    this.retry,
    this.direction,
    this.byteCount,
    this.endpoint,
    String? serviceUuid,
    int? channel,
    String? stage,
    String? hex,
    String? writeResult,
    String? readResult,
    Map<String, Object?> fields = const {},
  })  : id = id ??
            '${timestamp.toUtc().microsecondsSinceEpoch}-${_categoryName(category)}',
        scope = scope ?? 'backend',
        component = component ?? 'wristload.TuiBackend',
        event = _redactString(event ?? message),
        connectionId = connectionId ?? _fieldString(fields, 'connectionId'),
        generation = generation ?? _fieldInt(fields, 'generation'),
        transport = transport ?? _fieldString(fields, 'transport'),
        serviceUuid = serviceUuid ?? _fieldString(fields, 'serviceUuid'),
        channel = channel ?? _fieldInt(fields, 'channel'),
        stage = stage ?? _fieldString(fields, 'stage'),
        hex = _redactSensitiveProtocolHex(
          category,
          hex ?? _fieldString(fields, 'hex'),
        ),
        writeResult = writeResult ?? _fieldString(fields, 'writeResult'),
        readResult = readResult ?? _fieldString(fields, 'readResult'),
        fields = Map.unmodifiable(_redactMap(fields, category: category));

  final DateTime timestamp;
  final DiagnosticSeverity severity;
  final DiagnosticCategory category;
  final String message;
  final String id;
  final String scope;
  final String component;
  final String event;
  final String? deviceId;
  final String? sessionId;
  final String? connectionId;
  final int? generation;
  final String? transport;
  final String? nativeDomain;
  final int? nativeCode;
  final String? disconnectReason;
  final int? timeoutMs;
  final int? retry;
  final String? direction;
  final int? byteCount;
  final String? endpoint;
  final String? serviceUuid;
  final int? channel;
  final String? stage;
  final String? hex;
  final String? writeResult;
  final String? readResult;
  final Map<String, Object?> fields;

  String get categoryName => _categoryName(category);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'severity': severity.name,
        // GUI journals use `level`; retain `severity` for TUI compatibility.
        'level': severity.name,
        'category': _categoryName(category),
        'scope': scope,
        'component': component,
        'event': event,
        'message': _redactString(message),
        if (deviceId != null) 'deviceId': _redactString(deviceId!),
        if (sessionId != null) 'sessionId': _redactString(sessionId!),
        if (connectionId != null) 'connectionId': _redactString(connectionId!),
        if (generation != null) 'generation': generation,
        if (transport != null) 'transport': _redactString(transport!),
        if (nativeDomain != null) 'nativeDomain': _redactString(nativeDomain!),
        if (nativeCode != null) 'nativeCode': nativeCode,
        if (disconnectReason != null)
          'disconnectReason': _redactString(disconnectReason!),
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
        if (retry != null) 'retry': retry,
        if (direction != null) 'direction': direction,
        if (byteCount != null) 'byteCount': byteCount,
        if (endpoint != null) 'endpoint': _redactString(endpoint!),
        if (serviceUuid != null) 'serviceUuid': _redactString(serviceUuid!),
        if (channel != null) 'channel': channel,
        if (stage != null) 'stage': _redactString(stage!),
        if (hex != null) 'hex': _redactString(hex!),
        if (writeResult != null) 'writeResult': _redactString(writeResult!),
        if (readResult != null) 'readResult': _redactString(readResult!),
        if (fields.isNotEmpty) 'fields': fields,
      };

  String toJsonLine() => jsonEncode(toJson());

  factory DiagnosticEvent.fromJson(Map<String, Object?> json) {
    final rawFields = json['fields'];
    return DiagnosticEvent(
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      severity: DiagnosticSeverity.values.firstWhere(
        (item) => item.name == (json['severity'] ?? json['level']),
        orElse: () => DiagnosticSeverity.info,
      ),
      category: _categoryFromName(json['category'] as String? ?? 'system'),
      message: json['message'] as String? ?? '',
      id: json['id'] as String?,
      scope: json['scope'] as String?,
      component: json['component'] as String?,
      event: json['event'] as String?,
      deviceId: json['deviceId'] as String?,
      sessionId: json['sessionId'] as String?,
      connectionId: json['connectionId'] as String?,
      generation: (json['generation'] as num?)?.toInt(),
      transport: json['transport'] as String?,
      nativeDomain: json['nativeDomain'] as String?,
      nativeCode: (json['nativeCode'] as num?)?.toInt(),
      disconnectReason: json['disconnectReason'] as String?,
      timeoutMs: (json['timeoutMs'] as num?)?.toInt(),
      retry: (json['retry'] as num?)?.toInt(),
      direction: json['direction'] as String?,
      byteCount: (json['byteCount'] as num?)?.toInt(),
      endpoint: json['endpoint'] as String?,
      serviceUuid: json['serviceUuid'] as String?,
      channel: (json['channel'] as num?)?.toInt(),
      stage: json['stage'] as String?,
      hex: json['hex'] as String?,
      writeResult: json['writeResult'] as String?,
      readResult: json['readResult'] as String?,
      fields:
          rawFields is Map ? Map<String, Object?>.from(rawFields) : const {},
    );
  }

  /// Compact terminal representation matching the GUI journal's structured
  /// single-line style while retaining transport evidence needed for triage.
  String get displayText {
    final details = <String>[
      if (deviceId != null) 'device=$deviceId',
      if (sessionId != null) 'session=$sessionId',
      if (connectionId != null) 'connection=$connectionId',
      if (generation != null) 'generation=$generation',
      if (transport != null) 'transport=$transport',
      if (endpoint != null) 'endpoint=$endpoint',
      if (serviceUuid != null) 'service=$serviceUuid',
      if (channel != null) 'channel=$channel',
      if (stage != null) 'stage=$stage',
      if (direction != null) 'direction=$direction',
      if (byteCount != null) 'length=$byteCount',
      if (hex != null) 'hex=$hex',
      if (writeResult != null) 'writeResult=$writeResult',
      if (readResult != null) 'readResult=$readResult',
      if (nativeDomain != null) 'nativeDomain=$nativeDomain',
      if (nativeCode != null) 'nativeCode=$nativeCode',
      if (disconnectReason != null) 'disconnect=$disconnectReason',
      if (timeoutMs != null) 'timeoutMs=$timeoutMs',
      if (retry != null) 'retry=$retry',
    ];
    final suffix = details.isEmpty ? '' : ' ' + details.join(' ');
    return '${timestamp.toUtc().toIso8601String()}  '
        '${severity.name.toUpperCase().padRight(7)} '
        '[$categoryName] $component  ${_redactString(message)}$suffix';
  }
}

String? _fieldString(Map<String, Object?> fields, String key) {
  final value = fields[key];
  return value is String && value.isNotEmpty ? value : null;
}

int? _fieldInt(Map<String, Object?> fields, String key) {
  final value = fields[key];
  return value is num ? value.toInt() : null;
}

const _secretFragments = <String>[
  'authkey',
  'auth_key',
  'appdeviceid',
  'app_device_id',
  'oob',
  'nonce',
  'sessionsecret',
  'session_secret',
  'sessionkey',
  'session_key',
  'secretkey',
  'secret_key',
  'devicekey',
  'device_key',
  'appkey',
  'app_key',
  'keymaterial',
  'key_material',
  'encryptionkey',
  'encryption_key',
  'decryptionkey',
  'decryption_key',
  'secret',
  'token',
  'password',
  'credential',
];

const _secretFieldNames = <String>{
  'key',
  'keys',
  'iv',
  'hmac',
  'signature',
};

String _redactString(String value) {
  var result = value;
  for (final fragment in _secretFragments) {
    final pattern = RegExp(
      '(' + fragment + r'\s*[:=]\s*)([^,; ]+)',
      caseSensitive: false,
    );
    result = result.replaceAllMapped(
      pattern,
      (match) => (match.group(1) ?? '') + '[REDACTED]',
    );
  }
  return result;
}

Map<String, Object?> _redactMap(
  Map<String, Object?> values, {
  DiagnosticCategory? category,
}) =>
    values.map(
      (key, value) => MapEntry(
        key,
        _redactValue(key, value, category: category),
      ),
    );

Object? _redactValue(
  String key,
  Object? value, {
  DiagnosticCategory? category,
}) {
  final lower = key.toLowerCase().replaceAll('-', '_');
  final compact = lower.replaceAll('_', '');
  if (_secretFragments.any((fragment) =>
          lower.contains(fragment) ||
          compact.contains(fragment.replaceAll('_', ''))) ||
      _secretFieldNames.contains(lower)) {
    return '[REDACTED]';
  }
  if (value is String && lower.contains('hex')) {
    return _redactSensitiveProtocolHex(category, value);
  }
  return _redactAny(value, category: category);
}

Object? _redactAny(Object? value, {DiagnosticCategory? category}) {
  if (value is String) return _redactString(value);
  if (value is Map) {
    return _redactMap(
      Map<String, Object?>.from(value),
      category: category,
    );
  }
  if (value is Iterable) {
    return value
        .map((item) => _redactAny(item, category: category))
        .toList(growable: false);
  }
  return value;
}

String? _redactSensitiveProtocolHex(
  DiagnosticCategory? category,
  String? value,
) {
  if (value == null ||
      (category != DiagnosticCategory.rawTx &&
          category != DiagnosticCategory.rawRx)) {
    return value;
  }
  final compact = value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (compact.length.isOdd || compact.isEmpty) return '[REDACTED]';
  final bytes = <int>[];
  try {
    for (var offset = 0; offset < compact.length; offset += 2) {
      bytes.add(int.parse(compact.substring(offset, offset + 2), radix: 16));
    }
  } on FormatException {
    return '[REDACTED]';
  }
  if (bytes.length == 3 &&
      bytes[0] == 0xba &&
      bytes[1] == 0xdc &&
      bytes[2] == 0xfe) {
    return value;
  }
  final isAck = bytes.length == 8 &&
      bytes[0] == 0xa5 &&
      bytes[1] == 0xa5 &&
      (bytes[2] & 0x0f) == 1 &&
      bytes[4] == 0 &&
      bytes[5] == 0;
  final isL1Command = bytes.length >= 9 &&
      bytes[0] == 0xa5 &&
      bytes[1] == 0xa5 &&
      (bytes[2] & 0x0f) == 2 &&
      (bytes[8] == 1 || bytes[8] == 2);
  return isAck || isL1Command ? value : '[REDACTED]';
}

/// Append-only JSONL journal. A sidecar exclusive-create lock serializes
/// writers across isolates and processes for one flushed append at a time.
class DiagnosticJournal {
  DiagnosticJournal(
    this.file, {
    this.pollInterval = const Duration(milliseconds: 100),
  });

  final File file;
  final Duration pollInterval;
  static final Map<String, Future<void>> _writeTails = {};

  Future<void> append(DiagnosticEvent event) async {
    final path = file.absolute.path;
    final previous = _writeTails[path] ?? Future<void>.value();
    final write = previous
        .catchError((Object _, StackTrace __) {})
        .then<void>((_) => _appendLocked(event));
    _writeTails[path] = write;
    try {
      await write;
    } finally {
      if (identical(_writeTails[path], write)) _writeTails.remove(path);
    }
  }

  Future<void> _appendLocked(DiagnosticEvent event) async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      await handle.setPosition(await handle.length());
      await handle.writeString(event.toJsonLine() + '\n');
      await handle.flush();
    } finally {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
    }
  }

  Future<List<DiagnosticEvent>> read({int? limit}) async {
    if (!await file.exists()) return const [];
    final events = <DiagnosticEvent>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          events.add(DiagnosticEvent.fromJson(
            Map<String, Object?>.from(decoded),
          ));
        }
      } on FormatException {
        // Corrupt or partial records do not stop diagnostic inspection.
      }
    }
    if (limit == null || events.length <= limit) return events;
    return events.sublist(events.length - limit);
  }

  /// Emits current tail records, then newly completed JSONL records. The
  /// reader owns no main-TUI resource, so cancellation/exiting is isolated.
  Stream<DiagnosticEvent> follow({int? initialLimit}) {
    late StreamController<DiagnosticEvent> controller;
    Timer? timer;
    var offset = 0;
    var polling = false;

    Future<void> poll() async {
      if (polling || controller.isClosed) return;
      polling = true;
      try {
        if (!await file.exists()) {
          offset = 0;
          return;
        }
        final length = await file.length();
        if (length < offset) offset = 0;
        if (length <= offset) return;
        final handle = await file.open();
        try {
          await handle.setPosition(offset);
          final bytes = await handle.read(length - offset);
          final start = offset;
          offset = length;
          final text = utf8.decode(bytes, allowMalformed: true);
          var consumed = 0;
          for (final line in text.split('\n')) {
            final encodedLength = utf8.encode(line).length;
            if (line.trim().isEmpty) {
              consumed += encodedLength + 1;
              continue;
            }
            try {
              final decoded = jsonDecode(line);
              if (decoded is Map && !controller.isClosed) {
                controller.add(DiagnosticEvent.fromJson(
                  Map<String, Object?>.from(decoded),
                ));
              }
              consumed += encodedLength + 1;
            } on FormatException {
              offset = start + consumed;
              break;
            }
          }
        } finally {
          await handle.close();
        }
      } on FileSystemException {
        offset = 0;
      } finally {
        polling = false;
      }
    }

    controller = StreamController<DiagnosticEvent>(
      onListen: () async {
        try {
          final bytes = await file.readAsBytes();
          offset = bytes.length;
          var initial = _decodeEvents(bytes);
          if (initialLimit != null && initial.length > initialLimit) {
            initial = initial.sublist(initial.length - initialLimit);
          }
          for (final event in initial) {
            if (!controller.isClosed) controller.add(event);
          }
        } on FileSystemException {
          // Follow may begin before the first writer creates the journal.
        }
        if (!controller.isClosed) {
          timer = Timer.periodic(pollInterval, (_) => poll());
        }
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return controller.stream;
  }
}

List<DiagnosticEvent> _decodeEvents(List<int> bytes) {
  final events = <DiagnosticEvent>[];
  for (final line in utf8.decode(bytes, allowMalformed: true).split('\n')) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        events.add(
          DiagnosticEvent.fromJson(Map<String, Object?>.from(decoded)),
        );
      }
    } on FormatException {
      // The next poll will retry an incomplete trailing record.
    }
  }
  return events;
}
