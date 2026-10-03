import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  group('Approval Fatigue, Rate Limiting & Audit Hardening', () {
    late Directory tempDir;
    late PathResolver pathResolver;
    late CommandValidator validator;
    late File auditLogFile;
    late AuditLogger auditLogger;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fatigue_test');
      auditLogFile = File('${tempDir.path}/audit.log');
      pathResolver = PathResolver({'HOME': tempDir.path});
      validator = CommandValidator(pathResolver);
      auditLogger = AuditLogger(pathResolver, auditLogFile);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('auto-denies identical commandHash for 5 minutes after DENIED without dialog', () async {
      var currentTime = DateTime(2026, 10, 3, 14, 0, 0);
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.denied);

      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
        clock: () => currentTime,
      );

      final testFile = File('${tempDir.path}/secret.txt')..writeAsStringSync('data');
      final cmd = 'cat ${testFile.path}';

      // 1. First execution -> prompts user, user denies
      final res1 = await executor.executeCommand(cmd);
      expect(res1.isError, isTrue);
      expect(res1.output, contains('denied by user'));
      expect(fakeProvider.requestsReceived.length, equals(1));

      // 2. Second execution 10 seconds later -> auto-denied WITHOUT dialog
      currentTime = currentTime.add(const Duration(seconds: 10));
      final res2 = await executor.executeCommand(cmd);
      expect(res2.isError, isTrue);
      expect(res2.output, contains('Command auto-denied: recent denial/timeout cooldown active'));
      expect(fakeProvider.requestsReceived.length, equals(1)); // Dialog was NOT prompted!

      // 3. Advance clock by 5 minutes and 1 second -> cooldown expired, dialog prompted again
      currentTime = currentTime.add(const Duration(minutes: 5, seconds: 1));
      final res3 = await executor.executeCommand(cmd);
      expect(res3.isError, isTrue);
      expect(res3.output, contains('denied by user'));
      expect(fakeProvider.requestsReceived.length, equals(2)); // Prompted again!
    });

    test('auto-denies identical commandHash for 5 minutes after TIMEOUT without dialog', () async {
      var currentTime = DateTime(2026, 10, 3, 14, 0, 0);
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.timeout);

      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
        clock: () => currentTime,
      );

      final testFile = File('${tempDir.path}/secret2.txt')..writeAsStringSync('data');
      final cmd = 'cat ${testFile.path}';

      // 1. First execution -> times out
      final res1 = await executor.executeCommand(cmd);
      expect(res1.isError, isTrue);
      expect(res1.output, contains('timed out'));
      expect(fakeProvider.requestsReceived.length, equals(1));

      // 2. Immediate second execution -> auto-denied without dialog
      currentTime = currentTime.add(const Duration(seconds: 5));
      final res2 = await executor.executeCommand(cmd);
      expect(res2.isError, isTrue);
      expect(res2.output, contains('Command auto-denied: recent denial/timeout cooldown active'));
      expect(fakeProvider.requestsReceived.length, equals(1));
    });

    test('rate limits dialogs to 5 per minute and permits next after window elapses', () async {
      var currentTime = DateTime(2026, 10, 3, 15, 0, 0);
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.approved);

      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
        clock: () => currentTime,
      );

      // Create 6 distinct files requiring approval
      for (var i = 1; i <= 5; i++) {
        final f = File('${tempDir.path}/file$i.txt')..writeAsStringSync('content $i');
        currentTime = currentTime.add(const Duration(seconds: 5));
        final res = await executor.executeCommand('cat ${f.path}');
        expect(res.isError, isFalse);
        expect(fakeProvider.requestsReceived.length, equals(i));
      }

      // 6th distinct command at second 30 within the same 1-minute window
      final f6 = File('${tempDir.path}/file6.txt')..writeAsStringSync('content 6');
      currentTime = currentTime.add(const Duration(seconds: 5));
      final res6 = await executor.executeCommand('cat ${f6.path}');
      expect(res6.isError, isTrue);
      expect(res6.output, contains('Command denied: rate limit exceeded (maximum 5 approval dialogs per minute)'));
      expect(fakeProvider.requestsReceived.length, equals(5)); // 6th did NOT prompt!

      // Advance clock past the 1-minute mark of the first command
      currentTime = currentTime.add(const Duration(seconds: 40));
      final res7 = await executor.executeCommand('cat ${f6.path}');
      expect(res7.isError, isFalse);
      expect(fakeProvider.requestsReceived.length, equals(6)); // 6th dialog allowed now!
    });

    test('audit log includes latencyMs, fastApproval, provider, clientInfo, and RED stages', () async {
      // Write client-info.json
      final clientInfoDir = Directory('${tempDir.path}/.local/share/ubuntu-shell-mcp')..createSync(recursive: true);
      File('${clientInfoDir.path}/client-info.json').writeAsStringSync(jsonEncode({
        'protocolVersion': '2025-11-25',
        'clientInfo': {'name': 'claude-ai', 'version': '0.1.0'},
      }));

      final fakeProvider = FakeApprovalProvider(
        defaultStatus: ApprovalStatus.approved,
        onHandleRequest: (req) {
          if (req.level == ApprovalLevel.red) {
            return const ApprovalResult(
              status: ApprovalStatus.approved,
              latencyMs: 450,
              providerName: 'zenity',
              stages: [
                ApprovalStage(stage: 1, status: ApprovalStatus.approved, latencyMs: 200),
                ApprovalStage(stage: 2, status: ApprovalStatus.approved, latencyMs: 250),
              ],
              fastApproval: true,
            );
          }
          return const ApprovalResult(
            status: ApprovalStatus.approved,
            latencyMs: 1200,
            providerName: 'zenity',
            fastApproval: false,
          );
        },
      );

      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      // 1. Normal approval with latency 1200ms (fastApproval should be omitted/false)
      final normalFile = File('${tempDir.path}/normal.txt')..writeAsStringSync('normal');
      await executor.executeCommand('cat ${normalFile.path}');

      // 2. Red approval with latency 450ms (fastApproval should be true and stages array present)
      final sshDir = Directory('${tempDir.path}/.ssh')..createSync();
      await executor.executeCommand('ls ${sshDir.path}');

      final lines = auditLogFile.readAsLinesSync();
      // 4 records expected:
      // Line 0: normal decision
      // Line 1: normal execution
      // Line 2: red decision
      // Line 3: red execution
      expect(lines.length, equals(4));

      final normalDecision = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(normalDecision['decision'], equals('APPROVED'));
      expect(normalDecision['level'], equals('NORMAL'));
      expect(normalDecision['latencyMs'], equals(1200));
      expect(normalDecision['fastApproval'], isNull); // > 800ms
      expect(normalDecision['provider'], equals('zenity'));
      expect(normalDecision['clientInfo'], equals({'name': 'claude-ai', 'version': '0.1.0'}));
      expect(normalDecision['cwd'], equals(tempDir.path));

      final normalExecution = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(normalExecution['event'], equals('execution'));
      expect(normalExecution['decision'], equals('EXECUTED'));
      expect(normalExecution['exitCode'], equals(0));
      expect(normalExecution['durationMs'], isNotNull);
      expect(normalExecution.containsKey('output'), isFalse); // NEVER log output!
      expect(normalExecution.containsKey('stdout'), isFalse);

      final redDecision = jsonDecode(lines[2]) as Map<String, dynamic>;
      expect(redDecision['decision'], equals('APPROVED'));
      expect(redDecision['level'], equals('RED'));
      expect(redDecision['latencyMs'], equals(450));
      expect(redDecision['fastApproval'], isTrue);
      expect(redDecision['provider'], equals('zenity'));
      expect(redDecision['stages'], isA<List>());
      final stages = redDecision['stages'] as List;
      expect(stages.length, equals(2));
      expect(stages[0]['stage'], equals(1));
      expect(stages[0]['status'], equals('approved'));
      expect(stages[1]['stage'], equals(2));
      expect(stages[1]['status'], equals('approved'));

      final redExecution = jsonDecode(lines[3]) as Map<String, dynamic>;
      expect(redExecution['event'], equals('execution'));
      expect(redExecution['decision'], equals('EXECUTED'));
      expect(redExecution['exitCode'], equals(0));
      expect(redExecution.containsKey('output'), isFalse);
    });

    test('generates sample audit log lines for allowed, denied, and RED commands', () async {
      // Setup client info
      final clientInfoDir = Directory('${tempDir.path}/.local/share/ubuntu-shell-mcp')..createSync(recursive: true);
      File('${clientInfoDir.path}/client-info.json').writeAsStringSync(jsonEncode({
        'protocolVersion': '2025-11-25',
        'clientInfo': {'name': 'claude-ai', 'version': '0.1.0'},
      }));

      final sampleLogFile = File('${tempDir.path}/sample_audit.log');
      final sampleLogger = AuditLogger(pathResolver, sampleLogFile);

      final fakeProvider = FakeApprovalProvider(
        onHandleRequest: (req) {
          if (req.command.startsWith('ip')) {
            return const ApprovalResult(
              status: ApprovalStatus.denied,
              message: 'Denied by user',
              latencyMs: 1420,
              providerName: 'zenity',
            );
          }
          if (req.level == ApprovalLevel.red) {
            return const ApprovalResult(
              status: ApprovalStatus.approved,
              message: 'Approved by user',
              latencyMs: 620,
              providerName: 'zenity',
              fastApproval: true,
              stages: [
                ApprovalStage(stage: 1, status: ApprovalStatus.approved, latencyMs: 290),
                ApprovalStage(stage: 2, status: ApprovalStatus.approved, latencyMs: 330),
              ],
            );
          }
          return const ApprovalResult.approved('Approved by user');
        },
      );

      final sampleExecutor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: sampleLogger,
        approvalProvider: fakeProvider,
      );

      // 1. Allowed (Auto-run: ls Desktop)
      final desktopDir = Directory('${tempDir.path}/Desktop')..createSync();
      await sampleExecutor.executeCommand('ls ${desktopDir.path}');

      // 2. Denied (Normal: ip -br a)
      await sampleExecutor.executeCommand('ip -br a');

      // 3. RED (Approved: ls ~/.ssh)
      final sshDir = Directory('${tempDir.path}/.ssh')..createSync();
      await sampleExecutor.executeCommand('ls ${sshDir.path}');

      final lines = sampleLogFile.readAsLinesSync();

      // Expected:
      // lines[0]: Allowed decision
      // lines[1]: Allowed execution
      // lines[2]: Denied decision
      // lines[3]: RED decision
      // lines[4]: RED execution
      expect(lines.length, equals(5));
    });
  });
}
