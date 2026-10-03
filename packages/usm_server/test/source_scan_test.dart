import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('usm_server source code does NOT contain hardcoded user paths', () {
    // Construct forbidden needle dynamically to prevent self-matching
    final slash = String.fromCharCode(47); // '/'
    final forbiddenPattern = '$slash' 'home' '$slash';

    var current = Directory.current;
    while (!Directory('${current.path}/packages').existsSync() && current.parent.path != current.path) {
      current = current.parent;
    }
    final packagesDir = Directory('${current.path}/packages');
    expect(packagesDir.existsSync(), isTrue);

    final dartFiles = packagesDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    expect(dartFiles, isNotEmpty);

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
      reason: 'Found forbidden hardcoded user path pattern "$forbiddenPattern":\n${violations.join('\n')}',
    );
  });
}
