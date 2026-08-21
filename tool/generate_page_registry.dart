import 'dart:io';

/// macOS-friendly equivalent of generate_page_registry.ps1.
///
/// Primary page modules opt in by declaring the standard descriptor constant;
/// this script intentionally does not inspect module metadata so generated
/// imports remain a mechanical reflection of page files.
void main() {
  final projectRoot = Directory.current;
  final pageRoot = Directory(
    '${projectRoot.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
    'presentation${Platform.pathSeparator}pages',
  );
  final output = File(
    '${projectRoot.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
    'presentation${Platform.pathSeparator}generated_page_registry.dart',
  );
  final pages =
      pageRoot
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) => RegExp(
              r'const\s+wristloadPage\s*=\s*WristloadPageModule',
            ).hasMatch(file.readAsStringSync()),
          )
          .toList()
        ..sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));

  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT EDIT.')
    ..writeln(
      '// Run tool/generate_page_registry.ps1 or '
      'tool/generate_page_registry.dart after adding or removing a page module.',
    )
    ..writeln("import 'page_module.dart';");
  for (var index = 0; index < pages.length; index++) {
    buffer.writeln(
      "import 'pages/${_baseName(pages[index].path)}' as page$index;",
    );
  }
  buffer
    ..writeln()
    ..writeln('const generatedPageModules = <WristloadPageModule>[');
  for (var index = 0; index < pages.length; index++) {
    buffer.writeln('  page$index.wristloadPage,');
  }
  buffer.writeln('];');
  output.writeAsStringSync(buffer.toString());
  stdout.writeln('Generated page registry with ${pages.length} module(s).');
}

String _baseName(String path) => path.split(Platform.pathSeparator).last;
