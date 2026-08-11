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
  final seen = <String>{};
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
      if (seen.add(candidate.key)) results.add(candidate);
    }
  }
  return results;
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

  final jsonBlock = RegExp(
    r'\{[^{}]*"productName"[^{}]*"token"[^{}]*\}|\{[^{}]*"token"[^{}]*"productName"[^{}]*\}',
  );
  for (final match in jsonBlock.allMatches(text)) {
    try {
      final decoded = jsonDecode(match.group(0)!);
      if (decoded is Map) {
        final product = decoded['productName'];
        final token = decoded['token'];
        final context = _contextAround(text, match.start, match.end);
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

  final productMatches = RegExp(
    r'''["']?productName["']?\s*[=:]\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(text).toList();
  final tokenMatches = RegExp(
    r'''["']?token["']?\s*[=:]\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(text).toList();
  final count = productMatches.length > tokenMatches.length
      ? productMatches.length
      : tokenMatches.length;
  for (var index = 0; index < count; index++) {
    final product =
        index < productMatches.length ? productMatches[index].group(1) : null;
    final token =
        index < tokenMatches.length ? tokenMatches[index].group(1) : null;
    final center = index < tokenMatches.length
        ? tokenMatches[index].start
        : (index < productMatches.length ? productMatches[index].start : 0);
    final context = _contextAround(text, center, center);
    add(token, productName: product, mac: _findMac(context));
  }

  final anchored = RegExp(
    r'''(?:encrypt_key|auth_key|authkey|bind[_ -]?token|token)\s*[:=]\s*["']?([0-9a-f]{32})''',
    caseSensitive: false,
  );
  for (final match in anchored.allMatches(text)) {
    add(
      match.group(1),
      mac: _findMac(_contextAround(text, match.start, match.end)),
    );
  }
  return results;
}

String _contextAround(String text, int start, int end) => text.substring(
      start > 1000 ? start - 1000 : 0,
      end + 1000 < text.length ? end + 1000 : text.length,
    );

String? _findMac(String text) => RegExp(
      r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}',
    ).firstMatch(text)?.group(0)?.toUpperCase();
