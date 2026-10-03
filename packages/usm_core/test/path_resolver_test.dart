import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  group('PathResolver', () {
    test('resolves HOME and standard XDG paths', () {
      final fakeHomeDir = Directory.systemTemp.createTempSync('fake_home');
      addTearDown(() {
        if (fakeHomeDir.existsSync()) fakeHomeDir.deleteSync(recursive: true);
      });
      final fakeHome = fakeHomeDir.path;
      final resolver = PathResolver({'HOME': fakeHome});

      expect(resolver.homeDirectory, equals(fakeHome));
      expect(resolver.xdgDataHome, equals('$fakeHome/.local/share'));
      expect(resolver.xdgConfigHome, equals('$fakeHome/.config'));
      expect(
        resolver.auditLogPath,
        equals('$fakeHome/.local/share/ubuntu-shell-mcp/audit.log'),
      );
    });

    test('respects custom XDG_DATA_HOME and XDG_CONFIG_HOME', () {
      final fakeHomeDir = Directory.systemTemp.createTempSync('fake_home_custom');
      addTearDown(() {
        if (fakeHomeDir.existsSync()) fakeHomeDir.deleteSync(recursive: true);
      });
      final fakeHome = fakeHomeDir.path;
      final customData = '$fakeHome/custom_data';
      final customConfig = '$fakeHome/custom_config';

      final resolver = PathResolver({
        'HOME': fakeHome,
        'XDG_DATA_HOME': customData,
        'XDG_CONFIG_HOME': customConfig,
      });

      expect(resolver.xdgDataHome, equals(customData));
      expect(resolver.xdgConfigHome, equals(customConfig));
      expect(
        resolver.auditLogPath,
        equals('$customData/ubuntu-shell-mcp/audit.log'),
      );
    });

    test('allows paths strictly inside HOME or /tmp', () {
      final fakeHomeDir = Directory.systemTemp.createTempSync('allowed_home');
      addTearDown(() {
        if (fakeHomeDir.existsSync()) fakeHomeDir.deleteSync(recursive: true);
      });
      final fakeHome = fakeHomeDir.path;
      final resolver = PathResolver({'HOME': fakeHome});

      final subDir = Directory('$fakeHome/subfolder')..createSync();
      expect(resolver.resolveAndValidatePath('subfolder'), equals(subDir.path));
      expect(resolver.resolveAndValidatePath('/tmp'), equals('/tmp'));
    });

    test('rejects path traversal attempting to escape allowed roots', () {
      final fakeHomeDir = Directory.systemTemp.createTempSync('escape_home');
      addTearDown(() {
        if (fakeHomeDir.existsSync()) fakeHomeDir.deleteSync(recursive: true);
      });
      final fakeHome = fakeHomeDir.path;
      final resolver = PathResolver({'HOME': fakeHome});

      expect(
        () => resolver.resolveAndValidatePath('../../../etc'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => resolver.resolveAndValidatePath('/etc'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => resolver.resolveAndValidatePath('/root'),
        throwsA(isA<FormatException>()),
      );
    });

    test('reads cooldown and max dialogs per minute with sensible defaults', () {
      final fakeHomeDir = Directory.systemTemp.createTempSync('config_home');
      addTearDown(() {
        if (fakeHomeDir.existsSync()) fakeHomeDir.deleteSync(recursive: true);
      });
      final fakeHome = fakeHomeDir.path;
      final resolver = PathResolver({'HOME': fakeHome});

      expect(resolver.cooldownDurationSeconds, equals(300));
      expect(resolver.maxDialogsPerMinute, equals(5));

      // Now create custom config.json
      final confDir = Directory('$fakeHome/.config/ubuntu-shell-mcp')..createSync(recursive: true);
      File('${confDir.path}/config.json').writeAsStringSync('{"cooldown_seconds": 60, "max_dialogs_per_minute": 2}');

      expect(resolver.cooldownDurationSeconds, equals(60));
      expect(resolver.maxDialogsPerMinute, equals(2));
    });
  });
}
