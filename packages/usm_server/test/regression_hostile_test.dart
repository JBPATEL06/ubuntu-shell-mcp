import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';
import 'package:usm_server/mcp_server.dart';
import 'package:usm_server/transport.dart';

void main() {
  group('Hostile Test Regression & Ordered Processing Suite', () {
    late Directory tempHome;
    late PathResolver pathResolver;
    late Executor executor;
    late MemoryServerTransport transport;
    late McpServer server;
    late Link testSymlink;

    late FakeApprovalProvider fakeApprovalProvider;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('hostile_test');
      pathResolver = PathResolver({'HOME': tempHome.path});
      fakeApprovalProvider = FakeApprovalProvider(defaultStatus: ApprovalStatus.denied);
      executor = Executor(
        pathResolver: pathResolver,
        approvalProvider: fakeApprovalProvider,
      );
      transport = MemoryServerTransport();
      server = McpServer(transport: transport, executor: executor);
      server.start();

      // Create fake .ssh folder in test home directory
      final sshDir = Directory(p.join(tempHome.path, '.ssh'))..createSync();
      File(p.join(sshDir.path, 'id_rsa')).writeAsStringSync('dummy_key');

      // Create temp symlink pointing to ~/.ssh
      testSymlink = Link(p.join(tempHome.path, 'symlink_to_ssh'))
        ..createSync(sshDir.path);
    });

    tearDown(() async {
      await server.stop();
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    test('replays the hostile test sequence and asserts exact responses and ordering', () async {
      // 1. initialize -> ok
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'hostile-tester', 'version': '1.0.0'},
        },
      });

      // 2. "systemctl status --host=a@b ssh.service" -> not executed
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'systemctl status --host=a@b ssh.service'},
        },
      });

      // 3. "ls -R /" -> not executed
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ls -R /'},
        },
      });

      // 4. "ps eww" -> not executed
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ps eww'},
        },
      });

      // 5. "ls ~/.ssh" (using the real resolved home) -> not executed, requires sensitive path approval
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ls ${pathResolver.homeDirectory}/.ssh'},
        },
      });

      // 6. symlink test: create a temp symlink pointing to ~/.ssh and "ls" it -> not executed
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ls ${testSymlink.path}'},
        },
      });

      // 7. "uname -r" -> executed
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'uname -r'},
        },
      });

      // 8. the text "not json" -> JSON-RPC error -32700, server keeps running
      transport.pushRawLine('not json');

      // 9. unknown method -> error -32601
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'unknown/nonexistent_method',
        'params': {},
      });

      // Wait for all queued sequential requests to complete processing
      while (transport.sentMessages.length < 9) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      expect(transport.sentMessages.length, equals(9));

      // Assert Response 1: initialize -> ok
      final resp1 = transport.sentMessages[0];
      expect(resp1['id'], equals(1));
      expect(resp1['result']['serverInfo']['name'], equals('ubuntu-shell-mcp'));
      expect(resp1['result']['protocolVersion'], equals('2024-11-05'));

      // Assert Response 2: systemctl status --host=a@b -> not executed
      final resp2 = transport.sentMessages[1];
      expect(resp2['id'], equals(2));
      expect(resp2['result']['isError'], isTrue);
      expect(resp2['result']['content'][0]['text'], contains('Command denied by user'));

      // Assert Response 3: ls -R / -> not executed
      final resp3 = transport.sentMessages[2];
      expect(resp3['id'], equals(3));
      expect(resp3['result']['isError'], isTrue);
      expect(resp3['result']['content'][0]['text'], contains('Command denied by user'));

      // Assert Response 4: ps eww -> not executed
      final resp4 = transport.sentMessages[3];
      expect(resp4['id'], equals(4));
      expect(resp4['result']['isError'], isTrue);
      expect(resp4['result']['content'][0]['text'], contains('Command denied by user'));

      // Assert Response 5: ls ~/.ssh -> Sensitive path: needs explicit approval, not executed
      final resp5 = transport.sentMessages[4];
      expect(resp5['id'], equals(5));
      expect(resp5['result']['isError'], isTrue);
      expect(resp5['result']['content'][0]['text'], contains('Command denied by user'));

      // Assert Response 6: symlink to ~/.ssh -> Sensitive path: needs explicit approval
      final resp6 = transport.sentMessages[5];
      expect(resp6['id'], equals(6));
      expect(resp6['result']['isError'], isTrue);
      expect(resp6['result']['content'][0]['text'], contains('Command denied by user'));

      // Assert that requests received by the approval provider correctly distinguish levels:
      expect(fakeApprovalProvider.requestsReceived.length, equals(5));
      expect(fakeApprovalProvider.requestsReceived[0].level, equals(ApprovalLevel.normal));
      expect(fakeApprovalProvider.requestsReceived[1].level, equals(ApprovalLevel.normal));
      expect(fakeApprovalProvider.requestsReceived[2].level, equals(ApprovalLevel.normal));
      expect(fakeApprovalProvider.requestsReceived[3].level, equals(ApprovalLevel.red));
      expect(fakeApprovalProvider.requestsReceived[3].reason, contains('Sensitive path: needs explicit approval'));
      expect(fakeApprovalProvider.requestsReceived[4].level, equals(ApprovalLevel.red));
      expect(fakeApprovalProvider.requestsReceived[4].reason, contains('Sensitive path: needs explicit approval'));

      // Assert Response 7: uname -r -> executed
      final resp7 = transport.sentMessages[6];
      expect(resp7['id'], equals(7));
      expect(resp7['result']['isError'], isFalse);
      expect(resp7['result']['content'][0]['text'], isNotEmpty);

      // Assert Response 8: not json -> -32700 error, server kept running
      final resp8 = transport.sentMessages[7];
      expect(resp8['id'], isNull);
      expect(resp8['error']['code'], equals(-32700));

      // Assert Response 9: unknown method -> -32601
      final resp9 = transport.sentMessages[8];
      expect(resp9['id'], equals(8));
      expect(resp9['error']['code'], equals(-32601));

      // Assert Responses come back in the exact same order as the requests
      final receivedIds = transport.sentMessages.map((m) => m['id']).toList();
      expect(receivedIds, equals([1, 2, 3, 4, 5, 6, 7, null, 8]));
    });

    test('replays hostile sequence in strict_mode and refuses sensitive paths outright', () async {
      final strictResolver = PathResolver({'HOME': tempHome.path}, true);
      final strictExecutor = Executor(pathResolver: strictResolver);
      final strictTransport = MemoryServerTransport();
      final strictServer = McpServer(transport: strictTransport, executor: strictExecutor);
      strictServer.start();

      strictTransport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 101,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ls ${pathResolver.homeDirectory}/.ssh'},
        },
      });

      strictTransport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 102,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'ls ${testSymlink.path}'},
        },
      });

      while (strictTransport.sentMessages.length < 2) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final r1 = strictTransport.sentMessages[0];
      expect(r1['id'], equals(101));
      expect(r1['result']['isError'], isTrue);
      expect(r1['result']['content'][0]['text'], contains('Refused: sensitive path (strict mode)'));

      final r2 = strictTransport.sentMessages[1];
      expect(r2['id'], equals(102));
      expect(r2['result']['isError'], isTrue);
      expect(r2['result']['content'][0]['text'], contains('Refused: sensitive path (strict mode)'));

      await strictServer.stop();
    });
  });
}
