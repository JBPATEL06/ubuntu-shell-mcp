import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';
import 'package:usm_server/mcp_server.dart';
import 'package:usm_server/transport.dart';

void main() {
  group('JSON-RPC 2.0 Protocol & Stdio Verification', () {
    late MemoryServerTransport transport;
    late Directory tempHome;
    late Executor executor;
    late McpServer server;

    setUp(() {
      transport = MemoryServerTransport();
      tempHome = Directory.systemTemp.createTempSync('server_test');
      final pathResolver = PathResolver({'HOME': tempHome.path});
      executor = Executor(
        pathResolver: pathResolver,
        validator: CommandValidator(pathResolver),
        auditLogger: AuditLogger(pathResolver),
        approvalProvider: FakeApprovalProvider(defaultStatus: ApprovalStatus.denied),
      );
      server = McpServer(
        transport: transport,
        executor: executor,
      );
      server.start();
    });

    tearDown(() async {
      await server.stop();
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    void assertValidJsonRpc(Map<String, dynamic> msg) {
      expect(msg['jsonrpc'], equals('2.0'));
      expect(msg.containsKey('result') || msg.containsKey('error'), isTrue);

      final encoded = jsonEncode(msg);
      final decoded = jsonDecode(encoded);
      expect(decoded, isA<Map<String, dynamic>>());
    }

    test('handles initialize handshake with compliant JSON-RPC', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'test-client', 'version': '1.0.0'},
        },
      });

      await Future.delayed(const Duration(milliseconds: 30));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(1));
      final result = resp['result'] as Map<String, dynamic>;
      expect(result['protocolVersion'], equals('2024-11-05'));
      expect(result['serverInfo']['name'], equals('ubuntu-shell-mcp'));
    });

    test('ignores notifications without sending any stdout response', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
        'params': {},
      });

      await Future.delayed(const Duration(milliseconds: 30));
      expect(transport.sentMessages, isEmpty);
    });

    test('handles tools/list request with valid JSON-RPC', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': {},
      });

      await Future.delayed(const Duration(milliseconds: 30));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(2));
      final tools = resp['result']['tools'] as List<dynamic>;
      expect(tools.length, equals(2));
    });

    test('handles tools/call for run_command auto-run', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'uname -s'},
        },
      });

      await Future.delayed(const Duration(milliseconds: 100));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(3));
      final content = resp['result']['content'] as List<dynamic>;
      expect(content.first['text'], contains('Linux'));
      expect(resp['result']['isError'], isFalse);
    });

    test('handles tools/call for run_command approval required', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': 'cat /etc/passwd'},
        },
      });

      await Future.delayed(const Duration(milliseconds: 100));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(4));
      final content = resp['result']['content'] as List<dynamic>;
      expect(content.first['text'], contains('Command denied by user'));
      expect(resp['result']['isError'], isTrue);
    });

    test('handles tools/call for system_summary', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {
          'name': 'system_summary',
          'arguments': {},
        },
      });

      await Future.delayed(const Duration(milliseconds: 200));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(5));
      final content = resp['result']['content'] as List<dynamic>;
      expect(content.first['text'], contains('=== SYSTEM SUMMARY ==='));
    });

    test('returns standard -32601 error for unknown methods', () async {
      transport.pushClientMessage({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'unknown/method',
        'params': {},
      });

      await Future.delayed(const Duration(milliseconds: 30));

      expect(transport.sentMessages.length, equals(1));
      final resp = transport.sentMessages.first;
      assertValidJsonRpc(resp);
      expect(resp['id'], equals(6));
      expect(resp['error']['code'], equals(-32601));
    });
  });
}
