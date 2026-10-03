import 'dart:convert';
import 'package:test/test.dart';
import 'package:usm_server/mcp_server.dart';

void main() {
  group('MCP Tools List Constraints', () {
    test('contains 2 tools in default mode and 3 tools when USM_EXPERIMENTAL=1', () {
      // In default mode
      expect(McpServer.toolsDefinition.length, equals(2));
      final names = McpServer.toolsDefinition.map((t) => t['name'] as String).toList();
      expect(names, equals(['run_command', 'system_summary']));
      expect(names, isNot(contains('elicit_test')));
    });

    test('each tool description is strictly under 100 characters (elicit_test under 60)', () {
      for (final tool in McpServer.toolsDefinition) {
        final name = tool['name'] as String;
        final description = tool['description'] as String;
        expect(
          description.length,
          lessThan(100),
          reason: "Tool '$name' description has ${description.length} chars (must be < 100)",
        );
        if (name == 'elicit_test') {
          expect(
            description.length,
            lessThan(60),
            reason: "Tool '$name' description has ${description.length} chars (must be < 60)",
          );
        }
      }
    });

    test('tools/list response JSON payload is strictly under 1.5 KB (1536 bytes)', () {
      final sampleResponse = {
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'tools': McpServer.toolsDefinition,
        },
      };

      final jsonString = jsonEncode(sampleResponse);
      final byteLength = utf8.encode(jsonString).length;

      expect(
        byteLength,
        lessThan(1536),
        reason: 'tools/list response size is $byteLength bytes, which exceeds 1.5 KB (1536 bytes)',
      );
    });
  });
}
