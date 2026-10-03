import 'dart:io';
import 'package:usm_core/usm_core.dart';
import 'package:usm_server/mcp_server.dart';
import 'package:usm_server/transport.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--test-dialog')) {
    final sampleHome = Platform.environment['HOME'] ?? '/tmp';
    final provider = ZenityApprovalProvider();
    stderr.writeln('Testing Normal Approval Dialog with Zenity...');
    final normalResult = await provider.request(ApprovalRequest(
      command: 'ls ~/Documents',
      cwd: sampleHome,
      level: ApprovalLevel.normal,
      reason: 'Directory listing outside auto-run roots requires approval',
    ));
    stderr.writeln('Normal Dialog Result: ${normalResult.status} (${normalResult.message ?? "none"})');

    stderr.writeln('\nTesting Red Approval Dialog with Zenity (requires 2 confirmations)...');
    final redResult = await provider.request(ApprovalRequest(
      command: 'rm -rf ~/.ssh',
      cwd: sampleHome,
      level: ApprovalLevel.red,
      reason: 'Sensitive path access to SSH credentials',
    ));
    stderr.writeln('Red Dialog Result: ${redResult.status} (${redResult.message ?? "none"})');
    return;
  }

  if (args.contains('--check-display')) {
    final provider = ZenityApprovalProvider();
    final env = provider.buildGuiEnvironment();
    final hasDisplay = env.containsKey('DISPLAY') || env.containsKey('WAYLAND_DISPLAY');
    if (hasDisplay) {
      exit(0);
    } else {
      stderr.writeln('ubuntu-shell-mcp: No graphical display found');
      exit(2);
    }
  }

  // Ensure that all diagnostic information and logs are directed ONLY to stderr.
  // stdout must contain exclusively valid JSON-RPC protocol messages.
  stderr.writeln('ubuntu-shell-mcp: Starting headless stdio MCP server (Dart)...');

  final pathResolver = PathResolver();
  final validator = CommandValidator(pathResolver);
  final auditLogger = AuditLogger(pathResolver);
  final approvalProvider = ZenityApprovalProvider();
  // Trigger display discovery diagnostic once at startup
  approvalProvider.buildGuiEnvironment();

  final executor = Executor(
    pathResolver: pathResolver,
    validator: validator,
    auditLogger: auditLogger,
    approvalProvider: approvalProvider,
  );

  final transport = StdioServerTransport();
  final server = McpServer(
    transport: transport,
    executor: executor,
  );

  server.start();
  stderr.writeln('ubuntu-shell-mcp: Server initialized and listening on stdio.');
}
