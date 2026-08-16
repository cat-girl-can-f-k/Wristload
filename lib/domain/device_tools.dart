import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

enum UnlockAlgorithm { old, newer }

String normalizeUnlockSn(String value) => value.trim().toUpperCase();

String normalizeUnlockMac(String value) =>
    value.toUpperCase().replaceAll(RegExp(r'[：:\-\s.]'), '');

bool isValidUnlockSn(String value) => normalizeUnlockSn(value).length >= 4;

bool isValidUnlockMac(String value) =>
    RegExp(r'^[0-9A-F]{12}$').hasMatch(normalizeUnlockMac(value));

/// Computes the ten-digit unlock code used by the tools page.
///
/// The old/Vela 4 variant hashes MAC + SN + XIAOMI. The newer/Vela 5
/// variant hashes SN + MAC + XIAOMI. The reference implementation uses the
/// first ten SHA-256 bytes, mapped to decimal digits.
String computeUnlockCode(
  String sn,
  String mac, {
  UnlockAlgorithm algorithm = UnlockAlgorithm.old,
}) {
  final normalizedSn = normalizeUnlockSn(sn);
  final normalizedMac = normalizeUnlockMac(mac);
  if (!isValidUnlockSn(normalizedSn)) {
    throw const FormatException('SN 至少需要 4 个字符');
  }
  if (!isValidUnlockMac(normalizedMac)) {
    throw const FormatException('MAC 地址必须是 12 位十六进制字符');
  }
  final payload = algorithm == UnlockAlgorithm.newer
      ? '$normalizedSn$normalizedMac' 'XIAOMI'
      : '$normalizedMac$normalizedSn' 'XIAOMI';
  final digest = sha256.convert(utf8.encode(payload)).bytes;
  return digest.take(10).map((byte) => (byte % 10).toString()).join();
}

class AuthKeyCandidate {
  const AuthKeyCandidate({
    required this.key,
    this.productName,
    this.mac,
    this.sourcePath,
  });

  final String key;
  final String? productName;
  final String? mac;
  final String? sourcePath;
}

/// Extracts 32-hex authkeys from Xiaomi/Zepp exported ZIP logs.
///
/// XiaomiFit.main.log is processed first. Structured productName/token pairs
/// follow the reference web tool; explicit authkey anchors provide a fallback.
List<AuthKeyCandidate> extractAuthKeysFromZip(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes, verify: false);
  final entries = archive.where((entry) => entry.isFile).toList();
  entries.sort((left, right) {
    final leftPriority = _isMainLog(left.name) ? 0 : 1;
    final rightPriority = _isMainLog(right.name) ? 0 : 1;
    return leftPriority.compareTo(rightPriority);
  });

  final results = <AuthKeyCandidate>[];
  final indexesByKey = <String, int>{};
  var totalBytes = 0;
  for (final entry in entries.take(10000)) {
    if (entry.size > 16 * 1024 * 1024) continue;
    totalBytes += entry.size;
    if (totalBytes > 64 * 1024 * 1024) {
      throw const FormatException('ZIP 解压后的日志总量超过 64 MB');
    }
    final content = entry.content;
    if (content is! List<int>) continue;
    final text = utf8.decode(content, allowMalformed: true);
    for (final candidate in _parseText(text, entry.name)) {
      final existingIndex = indexesByKey[candidate.key];
      if (existingIndex == null) {
        indexesByKey[candidate.key] = results.length;
        results.add(candidate);
        continue;
      }

      final existing = results[existingIndex];
      final hasRicherMetadata =
          (existing.productName == null && candidate.productName != null) ||
              (existing.mac == null && candidate.mac != null);
      if (hasRicherMetadata) {
        // The same key may be first seen in XiaomiFit.main.log without
        // metadata and later appear in a chronological device-list snapshot.
        // Move that enriched record to the end: final per-MAC selection must
        // use its most recent snapshot, not its first anonymous occurrence.
        final enriched = AuthKeyCandidate(
          key: existing.key,
          productName: candidate.productName ?? existing.productName,
          mac: candidate.mac ?? existing.mac,
          sourcePath: candidate.sourcePath ?? existing.sourcePath,
        );
        results.removeAt(existingIndex);
        for (var index = existingIndex; index < results.length; index++) {
          indexesByKey[results[index].key] = index;
        }
        indexesByKey[enriched.key] = results.length;
        results.add(enriched);
      }
    }
  }
  return _keepLatestCandidatePerDevice(results);
}

/// Device-list snapshots can contain historical credentials for one watch.
/// The log is read from oldest to newest, so scan backwards and retain only
/// the final record for each reliable MAC address. Candidates without a MAC
/// stay separate rather than risking a false merge of identically named devices.
List<AuthKeyCandidate> _keepLatestCandidatePerDevice(
  List<AuthKeyCandidate> candidates,
) {
  final macs = <String>{};
  final latestFirst = <AuthKeyCandidate>[];
  for (final candidate in candidates.reversed) {
    final mac = candidate.mac;
    if (mac == null || mac.isEmpty) {
      latestFirst.add(candidate);
      continue;
    }
    final normalizedMac = mac.toUpperCase();
    if (macs.add(normalizedMac)) {
      latestFirst.add(candidate);
    }
  }
  return latestFirst.reversed.toList(growable: false);
}

bool _isMainLog(String path) =>
    path.replaceAll('\\', '/').split('/').last.toLowerCase() ==
    'xiaomifit.main.log';

List<AuthKeyCandidate> _parseText(String text, String sourcePath) {
  final results = <AuthKeyCandidate>[];
  final seen = <String>{};

  void add(String? key, {String? productName, String? mac}) {
    final normalized = key?.trim().toLowerCase();
    if (normalized == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized) ||
        !seen.add(normalized)) {
      return;
    }
    results.add(AuthKeyCandidate(
      key: normalized,
      productName: productName?.trim(),
      mac: mac,
      sourcePath: sourcePath,
    ));
  }

  // Xiaomi Fitness device-list responses keep the display name on the outer
  // object and the 32-hex credential inside `detail`. Parse the complete JSON
  // line so an authkey is never separated from its own device metadata.
  void parseDeviceListJsonLine(String line) {
    if (!line.contains('encrypt_key') && !line.contains('\"token\"')) {
      return;
    }
    final jsonStart = line.indexOf('{');
    if (jsonStart == -1) return;
    try {
      final decoded = jsonDecode(line.substring(jsonStart));
      void visit(Object? value, {String? name, String? mac}) {
        if (value is List) {
          for (final item in value) {
            visit(item, name: name, mac: mac);
          }
          return;
        }
        if (value is! Map) return;

        final localName = value['name'];
        final localMac = value['mac'];
        final resolvedName = localName is String && localName.trim().isNotEmpty
            ? localName.trim()
            : name;
        final resolvedMac = localMac is String && _findMac(localMac) != null
            ? _findMac(localMac)
            : mac;
        for (final field in const ['encrypt_key', 'auth_key', 'authkey', 'token']) {
          final key = value[field];
          if (key is String) {
            add(key, productName: resolvedName, mac: resolvedMac);
          }
        }
        for (final child in value.values) {
          visit(child, name: resolvedName, mac: resolvedMac);
        }
      }

      visit(decoded);
    } on Object {
      // Ordinary log lines can contain partial JSON; the anchor scanner below
      // remains available for those formats.
    }
  }

  for (final line in const LineSplitter().convert(text)) {
    parseDeviceListJsonLine(line);
  }

  final jsonBlock = RegExp(
    r'\{[^{}]*"productName"[^{}]*"token"[^{}]*\}|\{[^{}]*"token"[^{}]*"productName"[^{}]*\}',
  );
  for (final match in jsonBlock.allMatches(text)) {
    try {
      final decoded = jsonDecode(match.group(0)!);
      if (decoded is Map) {
        final product = decoded['productName'];
        final token = decoded['token'];
        final context = _lineAround(text, match.start, match.end);
        add(
          token is String ? token : null,
          productName: product is String ? product : null,
          mac: _findMac(context),
        );
      }
    } on Object {
      // Alternative-format parsing below handles malformed JSON log lines.
    }
  }

  // Do not pair the Nth productName with the Nth token in the whole log.
  // Multi-device logs can interleave records, so that would attach another
  // watch's name/MAC to a valid key. Associate fields only on one log line;
  // standalone token entries are still returned by the anchored scan below.
  final productField = RegExp(
    r'''["']?productName["']?\s*[=:]\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  final tokenField = RegExp(
    r'''["']?token["']?\s*[=:]\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  for (final line in const LineSplitter().convert(text)) {
    final product = productField.firstMatch(line)?.group(1);
    final token = tokenField.firstMatch(line)?.group(1);
    if (token != null) {
      add(token, productName: product, mac: _findMac(line));
    }
  }

  final anchored = RegExp(
    r'''(?:encrypt_key|auth_key|authkey|bind[_ -]?token|token)\s*[:=]\s*["']?([0-9a-f]{32})''',
    caseSensitive: false,
  );
  for (final match in anchored.allMatches(text)) {
    add(
      match.group(1),
      mac: _findMac(_lineAround(text, match.start, match.end)),
    );
  }
  return results;
}

String _lineAround(String text, int start, int end) {
  final lineStart = text.lastIndexOf('\n', start - 1) + 1;
  final lineEnd = text.indexOf('\n', end);
  return text.substring(lineStart, lineEnd == -1 ? text.length : lineEnd);
}

String? _findMac(String text) => RegExp(
      r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}',
    ).firstMatch(text)?.group(0)?.toUpperCase();
