import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('source code does NOT contain hardcoded user paths or forbidden home prefixes', () {
    // Dynamically construct the forbidden needle so this test file does not trigger false positives
    final slash = String.fromCharCode(47); // '/'
    final forbiddenPattern = '$slash' 'home' '$slash';

    // Find the packages root directory
    var current = Directory.current;
    while (!Directory('${current.path}/packages').existsSync() && current.parent.path != current.path) {
      current = current.parent;
    }
    final packagesDir = Directory('${current.path}/packages');
    expect(packagesDir.existsSync(), isTrue, reason: 'packages directory must exist');

    final dartFiles = packagesDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    expect(dartFiles, isNotEmpty, reason: 'Must find Dart source files to scan');

    final violations = <String>[];

    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.contains(forbiddenPattern)) {
          violations.add('${file.path}:${i + 1}: $line');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Found hardcoded user path pattern "$forbiddenPattern" in source files:\n${violations.join('\n')}',
    );
  });
}
