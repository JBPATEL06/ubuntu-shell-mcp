import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';
import 'package:usm_server/mcp_server.dart';
import 'package:usm_server/transport.dart';

void main() {
  group('MCP Elicitation Feature & Protocol Negotiation Suite', () {
    late Directory tempHome;
    late PathResolver pathResolver;
    late Executor executor;
    late MemoryServerTransport transport;
    late McpServer server;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('elicit_test_home');
      pathResolver = PathResolver({'HOME': tempHome.path});
      executor = Executor(pathResolver: pathResolver);
      transport = MemoryServerTransport();
      server = McpServer(
        transport: transport,
        executor: executor,
        elicitationTimeout: const Duration(milliseconds: 200), // Fast timeout for tests
      );
      server.start();
    });

    tearDown(() async {
      await server.stop();
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    test('negotiates protocolVersion and writes client-info.json without hardcoded paths', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {
            'elicitation': {'form': true},
          },
          'clientInfo': {
            'name': 'test-claude',
            'version': '0.1.0',
          },
        },
      });

      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sentMessages.length, equals(1));
      final initResp = transport.sentMessages.first;
      expect(initResp['id'], equals(1));
      expect(initResp['result']['protocolVersion'], equals('2024-11-05'));

      // Verify client-info.json was written to XDG data dir
      final clientInfoFile = File(pathResolver.clientInfoPath);
      expect(clientInfoFile.existsSync(), isTrue);
      final content = clientInfoFile.readAsStringSync().trim();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['protocolVersion'], equals('2024-11-05'));
      expect(decoded['negotiatedVersion'], equals('2024-11-05'));
      expect(decoded['elicitation'], isTrue);
      expect(decoded['capabilities']['elicitation'], isNotNull);
    });

    test('negotiates newer supported protocolVersion and falls back on unsupported', () async {
      // 1. If client offers 2025-06-18 (supported), reply with 2025-06-18
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));
      expect(transport.sentMessages.last['result']['protocolVersion'], equals('2025-06-18'));

      // 2. If client offers an unsupported version, reply with latest (2025-11-25)
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2023-01-01',
          'capabilities': {},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));
      expect(transport.sentMessages.last['result']['protocolVersion'], equals('2025-11-25'));
    });

    test('returns "elicitation not supported by this client" if client lacks capability', () async {
      // Initialize with no elicitation capability
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'elicit_test',
          'arguments': {},
        },
      });
      await Future.delayed(const Duration(milliseconds: 30));

      final toolResp = transport.sentMessages.last;
      expect(toolResp['id'], equals(2));
      expect(toolResp['result']['content'][0]['text'], equals('elicitation not supported by this client'));
      expect(toolResp['result']['isError'], isFalse);

      // Verify server did not send any elicitation/create requests
      final serverRequests = transport.sentMessages.where((m) => m['method'] == 'elicitation/create');
      expect(serverRequests, isEmpty);
    });

    test('handles accept response (approve = true and approve = false)', () async {
      // Initialize with elicitation capability
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {'elicitation': {}},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      // 1. Call elicit_test -> triggers server request
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });

      // Wait for server to send elicitation/create
      await Future.delayed(const Duration(milliseconds: 30));
      final srvReq = transport.sentMessages.firstWhere((m) => m['method'] == 'elicitation/create');
      expect(srvReq['id'], equals('srv-1'));
      expect(srvReq['params']['mode'], equals('form'));
      expect(srvReq['params']['message'], equals("Test: approve running 'uname -r'?"));
      expect(srvReq['params']['requestedSchema']['properties']['approve']['type'], equals('boolean'));

      // Fake client accepts with approve = true
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-1',
        'result': {
          'action': 'accept',
          'content': {'approve': true},
        },
      });

      await Future.delayed(const Duration(milliseconds: 30));
      final toolResp = transport.sentMessages.firstWhere((m) => m['id'] == 2);
      expect(toolResp['result']['content'][0]['text'], equals('accepted: true'));

      // 2. Call elicit_test again and accept with approve = false
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });
      await Future.delayed(const Duration(milliseconds: 30));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-2',
        'result': {
          'action': 'accept',
          'content': {'approve': false},
        },
      });
      await Future.delayed(const Duration(milliseconds: 30));
      final toolResp2 = transport.sentMessages.firstWhere((m) => m['id'] == 3);
      expect(toolResp2['result']['content'][0]['text'], equals('accepted: false'));
    });

    test('handles decline response', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {'elicitation': {}},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });
      await Future.delayed(const Duration(milliseconds: 30));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-1',
        'result': {'action': 'decline'},
      });
      await Future.delayed(const Duration(milliseconds: 30));

      final toolResp = transport.sentMessages.firstWhere((m) => m['id'] == 2);
      expect(toolResp['result']['content'][0]['text'], equals('declined'));
    });

    test('handles cancel response', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {'elicitation': {}},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });
      await Future.delayed(const Duration(milliseconds: 30));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-1',
        'result': {'action': 'cancel'},
      });
      await Future.delayed(const Duration(milliseconds: 30));

      final toolResp = transport.sentMessages.firstWhere((m) => m['id'] == 2);
      expect(toolResp['result']['content'][0]['text'], equals('cancelled'));
    });

    test('times out after duration and treats response as declined', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {'elicitation': {}},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });

      // Do NOT send any reply to srv-1. Wait for timeout (200ms configured in setUp)
      await Future.delayed(const Duration(milliseconds: 300));

      final toolResp = transport.sentMessages.firstWhere((m) => m['id'] == 2);
      expect(toolResp['result']['content'][0]['text'], equals('declined'));
    });

    test('proves NO DEADLOCK when reply arrives while another request is in flight', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {'elicitation': {}},
        },
      });
      await Future.delayed(const Duration(milliseconds: 20));

      // 1. First request: elicit_test (id 10)
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'tools/call',
        'params': {'name': 'elicit_test'},
      });

      // 2. Wait until srv-1 is emitted
      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sentMessages.any((m) => m['id'] == 'srv-1'), isTrue);

      // 3. Second request while elicit_test is in flight: ping (id 11)
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 11,
        'method': 'ping',
        'params': {},
      });

      // 4. Client sends reply to srv-1 (outside queue)
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-1',
        'result': {
          'action': 'accept',
          'content': {'approve': true},
        },
      });

      // Wait for both requests to complete
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify no deadlock: both requests responded in order
      final resp10 = transport.sentMessages.firstWhere((m) => m['id'] == 10);
      final resp11 = transport.sentMessages.firstWhere((m) => m['id'] == 11);

      expect(resp10['result']['content'][0]['text'], equals('accepted: true'));
      expect(resp11['result'], equals({}));

      // Order of responses for client requests must be 1, 10, 11
      final clientResponseIds = transport.sentMessages
          .where((m) => m['id'] is int)
          .map((m) => m['id'])
          .toList();
      expect(clientResponseIds, equals([1, 10, 11]));
    });

    test('ignores malformed or unsolicited server response without crashing', () async {
      // Send an unsolicited response with an unknown id
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 'srv-unknown-999',
        'result': {'action': 'accept'},
      });

      // Send a malformed response without id
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'result': {'action': 'accept'},
      });

      await Future.delayed(const Duration(milliseconds: 20));

      // Verify server is alive and responds normally to ping
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 50,
        'method': 'ping',
        'params': {},
      });

      await Future.delayed(const Duration(milliseconds: 30));
      final pingResp = transport.sentMessages.firstWhere((m) => m['id'] == 50);
      expect(pingResp['result'], equals({}));
    });
  });
}
