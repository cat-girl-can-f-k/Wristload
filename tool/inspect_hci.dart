/// Read-only developer helper for extracting decrypted install PB frames.
/// The authkey is accepted only through MIWEAR_INSPECT_AUTHKEY and is never printed.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:wristload/domain/protocol/hci_decoder.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: inspect_hci.dart <btsnoop_hci.log>');
    exitCode = 64;
    return;
  }
  final key = Platform.environment['MIWEAR_INSPECT_AUTHKEY'];
  if (key == null || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(key)) {
    stderr.writeln('MIWEAR_INSPECT_AUTHKEY must be 32 hexadecimal characters.');
    exitCode = 64;
    return;
  }
  final file = File(arguments.single);
  if (!await file.exists()) {
    stderr.writeln('Capture does not exist.');
    exitCode = 66;
    return;
  }
  final length = await file.length();
  if (length <= 0 || length > maxHciCaptureBytes) {
    stderr.writeln('Capture must be between 1 byte and 512 MiB.');
    exitCode = 65;
    return;
  }
  final bytes = Uint8List.fromList(await file.readAsBytes());
  final report = const HciDecoder().decode(hciBytes: bytes, authKeyHex: key);
  for (final line in report.lines) {
    if (line.startsWith('安装业务命中：') || line.startsWith('  PB 明文：')) {
      stdout.writeln(line);
    }
  }
}
