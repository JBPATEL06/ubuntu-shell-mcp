import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';
import 'package:usm_server/mcp_server.dart';
import 'package:usm_server/transport.dart';

class MockProcess implements Process {
  @override
  final int pid = 12345;
  final int _exitCode;
  final Duration delay;
  final void Function()? onDone;

  MockProcess(this._exitCode, [this.delay = Duration.zero, this.onDone]);

  @override
  Future<int> get exitCode async {
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    onDone?.call();
    return _exitCode;
  }

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  group('Approval Flow & Security Gates Suite', () {
    late Directory tempDir;
    late File auditLogFile;
    late PathResolver pathResolver;
    late AuditLogger auditLogger;
    late CommandValidator validator;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('approval_flow_test');
      auditLogFile = File('${tempDir.path}/audit.log');
      pathResolver = PathResolver({'HOME': tempDir.path});
      auditLogger = AuditLogger(pathResolver, auditLogFile);
      validator = CommandValidator(pathResolver);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('approved normal command runs once and records APPROVED with SHA-256 in audit log', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.approved);
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      final testFile = File('${tempDir.path}/sample.txt')..writeAsStringSync('sample content');
      final res = await executor.executeCommand('cat ${testFile.path}');

      expect(res.exitCode, equals(0));
      expect(res.isError, isFalse);
      expect(res.output, contains('sample content'));
      expect(fakeProvider.requestsReceived.length, equals(1));
      expect(fakeProvider.requestsReceived.first.level, equals(ApprovalLevel.normal));

      // Verify audit log entry
      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(2));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['decision'], equals('APPROVED'));
      expect(record['level'], equals('NORMAL'));
      expect(record['command'], equals('cat ${testFile.path}'));
      final expectedHash = sha256.convert(utf8.encode('cat ${testFile.path}')).toString();
      expect(record['commandHash'], equals(expectedHash));
      expect(record['cwd'], equals(tempDir.path));
      expect(record['provider'], equals('fake'));
      expect(record.containsKey('latencyMs'), isTrue);

      final execRecord = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(execRecord['command'], equals('cat ${testFile.path}'));
      expect(execRecord['commandHash'], equals(expectedHash));
      expect(execRecord['event'], equals('execution'));
      expect(execRecord['decision'], equals('EXECUTED'));
      expect(execRecord['exitCode'], equals(0));
      expect(execRecord.containsKey('durationMs'), isTrue);
    });

    test('denied normal command does not run and records DENIED in audit log', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.denied);
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      final res = await executor.executeCommand('mkdir ${tempDir.path}/new_folder');

      expect(res.isError, isTrue);
      expect(res.output, equals('Command denied by user'));
      expect(Directory('${tempDir.path}/new_folder').existsSync(), isFalse);
      expect(fakeProvider.requestsReceived.length, equals(1));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['decision'], equals('DENIED'));
      expect(record['level'], equals('NORMAL'));
    });

    test('timeout command does not run and records TIMEOUT in audit log', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.timeout);
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      final res = await executor.executeCommand('cat /etc/hosts');

      expect(res.isError, isTrue);
      expect(res.output, equals('Approval timed out (60s)'));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['decision'], equals('TIMEOUT'));
    });

    test('unavailable command does not run and records UNAVAILABLE in audit log', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.unavailable);
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      final res = await executor.executeCommand('cat /etc/hosts');

      expect(res.isError, isTrue);
      expect(res.output, contains('Approval dialog unavailable:'));

      final lines = auditLogFile.readAsLinesSync();
      expect(lines.length, equals(1));
      final record = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(record['decision'], equals('UNAVAILABLE'));
    });

    test('ZenityApprovalProvider requires both dialogs for RED level and fails closed if second is denied', () async {
      // 1. Simulate Zenity provider with headless environment override without display
      final providerWithoutDisplay = ZenityApprovalProvider(
        environmentOverride: {'HOME': tempDir.path},
      );
      final unavailResult = await providerWithoutDisplay.request(ApprovalRequest(
        command: 'rm -rf /',
        cwd: tempDir.path,
        level: ApprovalLevel.red,
        reason: 'Dangerous root deletion',
      ));
      expect(unavailResult.status, equals(ApprovalStatus.unavailable));
      expect(unavailResult.message, contains('neither DISPLAY nor WAYLAND_DISPLAY is set'));

      // 2. Test ZenityApprovalProvider with mock process spawner: dialog 1 accepted, dialog 2 denied
      final dialogArgsHistory = <List<String>>[];
      final mockZenityProvider = ZenityApprovalProvider(
        environmentOverride: {'DISPLAY': ':0', 'HOME': tempDir.path},
        processStarter: (executable, arguments, {environment}) async {
          dialogArgsHistory.add(arguments);
          // Return approved (0) for dialog 1, denied (1) for dialog 2
          final exitCode = dialogArgsHistory.length == 1 ? 0 : 1;
          return MockProcess(exitCode);
        },
      );

      final redReq = ApprovalRequest(
        command: 'rm -rf /',
        cwd: tempDir.path,
        level: ApprovalLevel.red,
        reason: 'Dangerous root deletion',
      );

      final redResult = await mockZenityProvider.request(redReq);
      expect(redResult.status, equals(ApprovalStatus.denied));
      expect(dialogArgsHistory.length, equals(2));
      // First dialog args
      expect(dialogArgsHistory[0], contains('--title=DANGEROUS: review carefully'));
      expect(dialogArgsHistory[0], contains('--icon-name=dialog-warning'));
      expect(dialogArgsHistory[0], contains('--no-markup'));
      // Second dialog args
      expect(dialogArgsHistory[1], contains('--title=DANGEROUS: Final Confirmation'));
      expect(dialogArgsHistory[1], contains('--default-cancel'));
      expect(dialogArgsHistory[1], contains('--no-markup'));

      // 3. Test that in Executor, denying the second dialog means the command is not run
      final redExecutor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: mockZenityProvider,
      );
      final execRes = await redExecutor.executeCommand('rm -rf /');
      expect(execRes.isError, isTrue);
      expect(execRes.output, equals('Command denied by user'));
    });

    test('red command runs when both dialogs are approved', () async {
      final sampleFile = File('${tempDir.path}/test_del.txt')..writeAsStringSync('delete me');
      final dialogArgsHistory = <List<String>>[];
      final mockZenityProvider = ZenityApprovalProvider(
        environmentOverride: {'DISPLAY': ':0', 'HOME': tempDir.path},
        processStarter: (executable, arguments, {environment}) async {
          dialogArgsHistory.add(arguments);
          return MockProcess(0); // approve both
        },
      );

      final executorWithApproval = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: mockZenityProvider,
      );

      final res = await executorWithApproval.executeCommand('rm ${sampleFile.path} ; echo done');
      expect(res.isError, isFalse);
      expect(res.output, contains('done'));
      expect(sampleFile.existsSync(), isFalse);
      expect(dialogArgsHistory.length, equals(2));
    });

    test('ZenityApprovalProvider auto-detects GUI environment from Linux session when not explicitly provided', () async {
      Map<String, String>? capturedEnv;
      final provider = ZenityApprovalProvider(
        // No environmentOverride, so it triggers Linux session auto-detection
        processStarter: (executable, arguments, {environment}) async {
          capturedEnv = environment;
          return MockProcess(0);
        },
      );

      final result = await provider.request(ApprovalRequest(
        command: 'ls ~/Documents',
        cwd: tempDir.path,
        level: ApprovalLevel.normal,
        reason: 'Test auto detection',
      ));

      expect(result.status, equals(ApprovalStatus.approved));
      expect(capturedEnv, isNotNull);
      expect(
        capturedEnv!.containsKey('WAYLAND_DISPLAY') || capturedEnv!.containsKey('DISPLAY'),
        isTrue,
      );
    });

    test('ZenityApprovalProvider serializes rapid requests in FIFO order without overlapping', () async {
      int activeProcesses = 0;
      int maxConcurrentProcesses = 0;

      final mockQueueProvider = ZenityApprovalProvider(
        environmentOverride: {'DISPLAY': ':0', 'HOME': tempDir.path},
        processStarter: (executable, arguments, {environment}) async {
          activeProcesses++;
          if (activeProcesses > maxConcurrentProcesses) {
            maxConcurrentProcesses = activeProcesses;
          }
          return MockProcess(0, const Duration(milliseconds: 15), () {
            activeProcesses--;
          });
        },
      );

      // Fire two concurrent requests
      final future1 = mockQueueProvider.request(ApprovalRequest(
        command: 'cmd1',
        cwd: tempDir.path,
        level: ApprovalLevel.normal,
        reason: 'Reason 1',
      ));
      final future2 = mockQueueProvider.request(ApprovalRequest(
        command: 'cmd2',
        cwd: tempDir.path,
        level: ApprovalLevel.normal,
        reason: 'Reason 2',
      ));

      await Future.wait([future1, future2]);
      expect(maxConcurrentProcesses, equals(1));
    });

    test('strict_mode refuses red commands with no dialog', () async {
      final strictPathResolver = PathResolver({'HOME': tempDir.path}, true);
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.approved);
      final strictExecutor = Executor(
        pathResolver: strictPathResolver,
        validator: CommandValidator(strictPathResolver),
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      final redCommands = [
        'rm -rf /',
        'dd if=/dev/zero of=/dev/sda',
        'echo "bad" | bash',
        'ls ~/.ssh',
      ];

      for (final cmd in redCommands) {
        final res = await strictExecutor.executeCommand(cmd);
        expect(res.isError, isTrue);
        expect(res.output, contains('strict mode'));
        expect(res.group, equals(ValidationGroup.group3Refused));
      }

      // No dialog must ever be shown in strict mode
      expect(fakeProvider.requestsReceived, isEmpty);
    });

    test('control characters, bidi characters, and over-long commands are denied without a dialog', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.approved);
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      // Over-long (> 2000 chars)
      final overlong = 'echo ${'A' * 2005}';
      final res1 = await executor.executeCommand(overlong);
      expect(res1.isError, isTrue);
      expect(res1.output, contains('Command too long'));

      // ANSI escapes
      final ansiCmd = 'echo \x1B[31mRedAlert\x1B[0m';
      final res2 = await executor.executeCommand(ansiCmd);
      expect(res2.isError, isTrue);
      expect(res2.output, contains('invalid characters'));

      // Unicode BiDi override (\u202E)
      final bidiCmd = 'echo \u202ERightToLeftOverride';
      final res3 = await executor.executeCommand(bidiCmd);
      expect(res3.isError, isTrue);
      expect(res3.output, contains('invalid characters'));

      // Control characters (\x00, \x07)
      final controlCmd = 'echo \x00NullByte';
      final res4 = await executor.executeCommand(controlCmd);
      expect(res4.isError, isTrue);
      expect(res4.output, contains('invalid characters'));

      // Assert that none of these showed any dialog
      expect(fakeProvider.requestsReceived, isEmpty);
    });

    test('the executed argv equals the approved argv exactly without re-parsing', () async {
      String? approvedCmd;
      final fakeProvider = FakeApprovalProvider(
        onHandleRequest: (req) {
          approvedCmd = req.command;
          return const ApprovalResult.approved();
        },
      );

      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );

      const targetCommand = 'echo hello   world';
      final res = await executor.executeCommand(targetCommand);

      expect(res.isError, isFalse);
      expect(res.output, equals('hello world'));
      expect(approvedCmd, equals(targetCommand));
    });

    test('approval cannot be triggered through any MCP tool', () {
      final toolNames = McpServer.toolsDefinition.map((t) => t['name'] as String).toList();
      for (final name in toolNames) {
        expect(name.toLowerCase(), isNot(contains('approve')));
        expect(name.toLowerCase(), isNot(contains('approval')));
        expect(name.toLowerCase(), isNot(contains('dialog')));
      }
    });

    test('model-supplied text never appears in the dialog text', () async {
      ApprovalRequest? capturedRequest;
      final fakeProvider = FakeApprovalProvider(
        onHandleRequest: (req) {
          capturedRequest = req;
          return const ApprovalResult.denied();
        },
      );

      final transport = MemoryServerTransport();
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );
      final server = McpServer(transport: transport, executor: executor);
      server.start();

      // Client attempts to inject extra reasoning/metadata
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 100,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {
            'command': 'cat /etc/passwd',
            'explanation': 'Injected model text that must never appear in GUI',
            'userReason': 'Fake user reason',
          },
        },
      });

      await Future.delayed(const Duration(milliseconds: 30));
      await server.stop();

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.command, equals('cat /etc/passwd'));
      expect(capturedRequest!.reason, isNot(contains('Injected model text')));
      expect(capturedRequest!.reason, isNot(contains('Fake user reason')));
      expect(capturedRequest!.reason, contains('approval'));
    });

    test('two quick requests produce two sequential dialogs, never overlapping', () async {
      final fakeProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.approved);
      final transport = MemoryServerTransport();
      final executor = Executor(
        pathResolver: pathResolver,
        validator: validator,
        auditLogger: auditLogger,
        approvalProvider: fakeProvider,
      );
      final server = McpServer(transport: transport, executor: executor);
      server.start();

      // Rapidly push two tool calls requiring approval
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'cat /etc/hosts'},
        },
      });

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'cat /etc/resolv.conf'},
        },
      });

      await Future.delayed(const Duration(milliseconds: 100));
      await server.stop();

      expect(transport.sentMessages.length, equals(2));
      expect(fakeProvider.requestsReceived.length, equals(2));
      // Assert that dialogs never overlapped (max concurrent requests was strictly 1)
      expect(fakeProvider.maxConcurrentRequests, equals(1));
    });
  });
}
