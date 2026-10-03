import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  group('Executor & AuditLogger', () {
    late Directory tempDir;
    late File auditLogFile;
    late PathResolver pathResolver;
    late AuditLogger auditLogger;
    late Executor executor;
    late FakeApprovalProvider fakeApprovalProvider;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('executor_test');
      auditLogFile = File('${tempDir.path}/test_audit.log');
      pathResolver = PathResolver({'HOME': tempDir.path});
      auditLogger = AuditLogger(pathResolver, auditLogFile);
      fakeApprovalProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.denied);
      executor = Executor(
        pathResolver: pathResolver,
        validator: CommandValidator(pathResolver),
        auditLogger: auditLogger,
        approvalProvider: fakeApprovalProvider,
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('executes Group 1 auto-run commands directly without shell', () async {
      final res = await executor.executeCommand('uname -s');
      expect(res.exitCode, equals(0));
      expect(res.isError, isFalse);
      expect(res.output, contains('Linux'));
      expect(res.group, equals(ValidationGroup.group1AutoRun));

      expect(auditLogFile.existsSync(), isTrue);
      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(2));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['command'], equals('uname -s'));
      expect(record['group'], equals(1));
      expect(record['decision'], equals('ALLOWED'));
      expect(record.containsKey('time'), isTrue);

      final execRecord = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(execRecord['command'], equals('uname -s'));
      expect(execRecord['decision'], equals('EXECUTED'));
      expect(execRecord['event'], equals('execution'));
      expect(execRecord['exitCode'], equals(0));
      expect(execRecord.containsKey('durationMs'), isTrue);
    });

    test('refuses dangerous commands in strict mode without running', () async {
      final strictPathResolver = PathResolver({'HOME': tempDir.path}, true);
      final strictExecutor = Executor(
        pathResolver: strictPathResolver,
        validator: CommandValidator(strictPathResolver),
        auditLogger: auditLogger,
        approvalProvider: fakeApprovalProvider,
      );
      final res = await strictExecutor.executeCommand('rm -rf /');
      expect(res.isError, isTrue);
      expect(res.output, contains('Refused:'));
      expect(res.group, equals(ValidationGroup.group3Refused));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['group'], equals(3));
      expect(record['decision'], equals('REFUSED'));
    });

    test('halts Group 2 commands with user denial in default mode', () async {
      final res = await executor.executeCommand('cat /etc/hosts');
      expect(res.isError, isTrue);
      expect(res.output, equals('Command denied by user'));
      expect(res.group, equals(ValidationGroup.group2NeedsApproval));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['group'], equals(2));
      expect(record['decision'], equals('DENIED'));
      expect(record['level'], equals('NORMAL'));
    });

    test('halts sensitive path commands with RED level user denial in default mode', () async {
      final res = await executor.executeCommand('ls ~/.ssh');
      expect(res.isError, isTrue);
      expect(res.output, equals('Command denied by user'));
      expect(res.group, equals(ValidationGroup.redApprovalRequired));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['command'], equals('ls ~/.ssh'));
      expect(record['group'], equals(2));
      expect(record['decision'], equals('DENIED'));
      expect(record['level'], equals('RED'));
    });

    test('refuses sensitive path commands outright in strict_mode', () async {
      final strictPathResolver = PathResolver({'HOME': tempDir.path}, true);
      final strictExecutor = Executor(
        pathResolver: strictPathResolver,
        validator: CommandValidator(strictPathResolver),
        auditLogger: auditLogger,
        approvalProvider: fakeApprovalProvider,
      );
      final res = await strictExecutor.executeCommand('ls ~/.ssh');
      expect(res.isError, isTrue);
      expect(res.output, equals('Refused: sensitive path (strict mode)'));
      expect(res.group, equals(ValidationGroup.group3Refused));
    });

    test('strips ANSI escape codes from output', () {
      const ansiSample = '\x1B[31mRed Alert\x1B[0m: \x1B[1mBold text\x1B[22m';
      final stripped = Executor.stripAnsiCodes(ansiSample);
      expect(stripped, equals('Red Alert: Bold text'));
    });

    test('generates structured system summary', () async {
      final summary = await executor.getSystemSummary();
      expect(summary, contains('=== SYSTEM SUMMARY ==='));
      expect(summary, contains('Hostname:'));
      expect(summary, contains('Disk Usage'));
      expect(summary, contains('Memory Usage'));
    });
  });
}
