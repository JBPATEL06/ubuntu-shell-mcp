import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  runApp(const UbuntuShellApp());
}

class UbuntuShellApp extends StatelessWidget {
  const UbuntuShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ubuntu Shell MCP',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF161618), // Clean neutral dark
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE95420), // Subdued Ubuntu accent
          surface: Color(0xFF202024),
          surfaceContainer: Color(0xFF26262B),
          onSurface: Color(0xFFECECED),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF202024),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: Color(0xFF2E2E34), width: 1),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF2A2A30),
          thickness: 1,
        ),
      ),
      home: const MainShellScaffold(),
    );
  }
}

class MainShellScaffold extends StatefulWidget {
  const MainShellScaffold({super.key});

  @override
  State<MainShellScaffold> createState() => _MainShellScaffoldState();
}

class _MainShellScaffoldState extends State<MainShellScaffold> {
  int _activeNavIndex = 0;
  final PathResolver _pathResolver = PathResolver();
  late final CommandValidator _validator;
  late final AuditLogger _auditLogger;
  late final Executor _executor;

  bool _isClientConnected = false;
  String _clientName = 'Standby';

  @override
  void initState() {
    super.initState();
    _validator = CommandValidator(_pathResolver);
    _auditLogger = AuditLogger(_pathResolver);
    _executor = Executor(
      pathResolver: _pathResolver,
      validator: _validator,
      auditLogger: _auditLogger,
    );
    _checkClientStatus();
  }

  Future<void> _checkClientStatus() async {
    try {
      final file = File(_pathResolver.clientInfoPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final clientInfo = json['clientInfo'] as Map<String, dynamic>?;
        if (mounted) {
          setState(() {
            _isClientConnected = true;
            _clientName = clientInfo != null ? '${clientInfo['name']} v${clientInfo['version']}' : 'Active Client';
          });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Minimalist, Clean Neutral Sidebar
          Container(
            width: 230,
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1D),
              border: Border(right: BorderSide(color: Color(0xFF28282E), width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Clean App Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE95420),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.terminal_rounded, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ubuntu Shell',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: -0.2),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'MCP Manager',
                              style: TextStyle(fontSize: 11, color: Color(0xFF888890)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Subdued Connection Status Pill
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF222226),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF2E2E34), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isClientConnected ? const Color(0xFF4ADE80) : const Color(0xFFFBBF24),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isClientConnected ? _clientName : 'Waiting for AI',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: _isClientConnected ? const Color(0xFFE4E4E7) : const Color(0xFFA1A1AA),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text(
                    'MENU',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF666670), letterSpacing: 0.8),
                  ),
                ),

                // Clean Nav Items
                _buildNavItem(0, 'Connect AI', Icons.link_rounded),
                _buildNavItem(1, 'Dashboard', Icons.dashboard_rounded),
                _buildNavItem(2, 'Activity Log', Icons.history_rounded),
                _buildNavItem(3, 'Command Sandbox', Icons.terminal_rounded),
                _buildNavItem(4, 'Security Rules', Icons.shield_rounded),

                const Spacer(),

                // Version Footer
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 14, color: Color(0xFF71717A)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'v1.0 • Pure Dart MCP',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Main View Content
          Expanded(
            child: Container(
              color: const Color(0xFF161618),
              child: IndexedStack(
                index: _activeNavIndex,
                children: [
                  ConnectAiView(pathResolver: _pathResolver, onConnected: _checkClientStatus),
                  DashboardView(pathResolver: _pathResolver, executor: _executor),
                  ActivityLogView(pathResolver: _pathResolver),
                  SandboxView(validator: _validator, executor: _executor, pathResolver: _pathResolver),
                  SecurityRulesView(pathResolver: _pathResolver),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, String label, IconData icon) {
    final isSelected = _activeNavIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _activeNavIndex = index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF26262B) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected ? const Color(0xFFE95420) : const Color(0xFF909096),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isSelected ? const Color(0xFFF4F4F5) : const Color(0xFF909096),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. CONNECT AI VIEW (Clean, Neutral, Step-by-Step)
// ---------------------------------------------------------------------------
class ConnectAiView extends StatefulWidget {
  final PathResolver pathResolver;
  final VoidCallback onConnected;

  const ConnectAiView({super.key, required this.pathResolver, required this.onConnected});

  @override
  State<ConnectAiView> createState() => _ConnectAiViewState();
}

class _ConnectAiViewState extends State<ConnectAiView> {
  int _clientTab = 0; // 0 = Claude Desktop, 1 = Cursor IDE, 2 = Terminal Test
  bool _isConfiguredInClaude = false;
  String _serverBinaryPath = '';
  String _claudeConfigFile = '';

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  Future<void> _checkSetup() async {
    final home = widget.pathResolver.homeDirectory;
    _serverBinaryPath = '$home/ubuntu-shell-mcp-dart/packages/usm_server/ubuntu-shell-mcp';
    _claudeConfigFile = '$home/.config/Claude/claude_desktop_config.json';

    final file = File(_claudeConfigFile);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.contains('ubuntu-shell-mcp')) {
          _isConfiguredInClaude = true;
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF27272A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final claudeJson = '''{
  "mcpServers": {
    "ubuntu-shell-mcp": {
      "command": "$_serverBinaryPath"
    }
  }
}''';

    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: ListView(
        children: [
          const Text('Connect AI Client', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.2)),
          const SizedBox(height: 3),
          const Text('Instructions to link this MCP shell server with Claude Desktop or Cursor.', style: TextStyle(color: Color(0xFF888890), fontSize: 13)),
          const SizedBox(height: 20),

          // Neutral Status Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConfiguredInClaude ? const Color(0xFF4ADE80) : const Color(0xFFFBBF24),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isConfiguredInClaude ? 'Configured in Claude Desktop' : 'Configuration Not Found Yet',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isConfiguredInClaude
                            ? 'Server entry detected in ~/.config/Claude/claude_desktop_config.json'
                            : 'Follow the steps below to register this server in your Claude config file.',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF909098)),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _checkSetup,
                  icon: const Icon(Icons.refresh_rounded, size: 14),
                  label: const Text('Re-check', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4D4D8),
                    side: const BorderSide(color: Color(0xFF383840)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Neutral Segmented Client Tabs
          Row(
            children: [
              _buildTabButton(0, 'Claude Desktop', Icons.chat_bubble_outline_rounded),
              const SizedBox(width: 8),
              _buildTabButton(1, 'Cursor IDE', Icons.code_rounded),
              const SizedBox(width: 8),
              _buildTabButton(2, 'Terminal Test', Icons.terminal_rounded),
            ],
          ),

          const SizedBox(height: 16),

          if (_clientTab == 0) ...[
            _buildStep(
              number: '1',
              title: 'Open your Claude configuration file',
              description: 'Claude Desktop loads local MCP tools from this JSON file on Linux:',
              code: _claudeConfigFile,
              onCopy: () => _copy(_claudeConfigFile, 'Config path copied!'),
            ),
            const SizedBox(height: 12),
            _buildStep(
              number: '2',
              title: 'Add the server definition',
              description: 'Paste this snippet inside the "mcpServers" object of that file:',
              code: claudeJson,
              onCopy: () => _copy(claudeJson, 'JSON snippet copied!'),
            ),
            const SizedBox(height: 12),
            _buildStep(
              number: '3',
              title: 'Restart Claude Desktop',
              description: 'Quit Claude Desktop completely (Ctrl + Q or system tray -> Quit) and relaunch it. Claude will start the server automatically.',
              code: null,
              onCopy: null,
            ),
          ] else if (_clientTab == 1) ...[
            _buildStep(
              number: '1',
              title: 'Open MCP Settings in Cursor',
              description: 'Press Ctrl + Shift + J or navigate to Settings -> Features -> MCP Servers.',
              code: null,
              onCopy: null,
            ),
            const SizedBox(height: 12),
            _buildStep(
              number: '2',
              title: 'Add a new command server',
              description: 'Set Name to "ubuntu-shell", Type to "command", and Command to:',
              code: _serverBinaryPath,
              onCopy: () => _copy(_serverBinaryPath, 'Binary path copied!'),
            ),
          ] else ...[
            _buildStep(
              number: '✓',
              title: 'Verify via command line',
              description: 'You can test the server right now in your terminal to see tool output:',
              code: 'echo \'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\' | $_serverBinaryPath',
              onCopy: () => _copy(
                'echo \'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\' | $_serverBinaryPath',
                'Command copied!',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTabButton(int index, String label, IconData icon) {
    final isSelected = _clientTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _clientTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF26262B) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFF3F3F46) : const Color(0xFF28282E),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? const Color(0xFFE95420) : const Color(0xFF71717A),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? const Color(0xFFF4F4F5) : const Color(0xFF888890),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep({
    required String number,
    required String title,
    required String description,
    required String? code,
    required VoidCallback? onCopy,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E2E34), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A30),
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Text(
                  number,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFFD4D4D8)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFF4F4F5)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(description, style: const TextStyle(fontSize: 12, color: Color(0xFF909098), height: 1.4)),
          if (code != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF141416),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF28282E), width: 1),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFD4D4D8), height: 1.35),
                    ),
                  ),
                  if (onCopy != null)
                    IconButton(
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF888890)),
                      tooltip: 'Copy',
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(4),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. DASHBOARD VIEW (Clean, Calm, Balanced)
// ---------------------------------------------------------------------------
class DashboardView extends StatefulWidget {
  final PathResolver pathResolver;
  final Executor executor;

  const DashboardView({super.key, required this.pathResolver, required this.executor});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  String? _systemSummary;
  FileStat? _binaryStat;
  int _auditCount = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVitals();
  }

  Future<void> _loadVitals() async {
    setState(() => _isLoading = true);
    try {
      final home = widget.pathResolver.homeDirectory;
      final serverPath = '$home/ubuntu-shell-mcp-dart/packages/usm_server/ubuntu-shell-mcp';
      final file = File(serverPath);
      if (await file.exists()) {
        _binaryStat = await file.stat();
      }

      final auditFile = File(widget.pathResolver.auditLogPath);
      if (await auditFile.exists()) {
        final lines = await auditFile.readAsLines();
        _auditCount = lines.where((l) => l.trim().isNotEmpty).length;
      }

      final summary = await widget.executor.getSystemSummary();
      _systemSummary = summary;
    } catch (_) {}
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _runTestPopup(ApprovalLevel level) async {
    final provider = ZenityApprovalProvider();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Displaying ${level.name.toUpperCase()} dialog on desktop...'),
        duration: const Duration(seconds: 2),
      ),
    );

    final req = ApprovalRequest(
      command: level == ApprovalLevel.normal ? 'ls -la ~/Documents' : 'rm -rf ~/.ssh',
      cwd: widget.pathResolver.homeDirectory,
      level: level,
      reason: level == ApprovalLevel.normal
          ? 'Directory listing outside auto-run roots requires approval'
          : 'Sensitive path access to SSH credentials',
    );

    final result = await provider.request(req);
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF202024),
          title: Text('${level.name.toUpperCase()} Result'),
          content: Text(
            'Outcome: ${result.status.name.toUpperCase()}\n\n(Fail-closed: timeout or dismissal cleanly aborts).',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: ListView(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Dashboard', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.2)),
                  SizedBox(height: 3),
                  Text('Overview of system resources and daemon status.', style: TextStyle(color: Color(0xFF888890), fontSize: 13)),
                ],
              ),
              OutlinedButton.icon(
                onPressed: _isLoading ? null : _loadVitals,
                icon: const Icon(Icons.refresh_rounded, size: 14),
                label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFD4D4D8),
                  side: const BorderSide(color: Color(0xFF383840)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 3 Clean Cards
          Row(
            children: [
              Expanded(
                child: _buildInfoCard(
                  title: 'SERVER BINARY',
                  primary: _binaryStat != null ? 'Installed' : 'Missing',
                  secondary: _binaryStat != null ? '${(_binaryStat!.size / (1024 * 1024)).toStringAsFixed(1)} MB compiled' : 'Compile needed',
                  icon: Icons.check_circle_outline_rounded,
                  iconColor: _binaryStat != null ? const Color(0xFF4ADE80) : const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInfoCard(
                  title: 'SECURITY POLICY',
                  primary: widget.pathResolver.strictMode ? 'Strict Mode' : 'Standard Gate',
                  secondary: widget.pathResolver.strictMode ? 'Auto-refuses red commands' : 'Prompts on sensitive paths',
                  icon: Icons.shield_outlined,
                  iconColor: const Color(0xFFE95420),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInfoCard(
                  title: 'LOGGED EVENTS',
                  primary: '$_auditCount Events',
                  secondary: 'Audit log active',
                  icon: Icons.receipt_long_outlined,
                  iconColor: const Color(0xFF60A5FA),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // System Vitals Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.memory_rounded, size: 16, color: Color(0xFFE95420)),
                    SizedBox(width: 8),
                    Text('Host System Vitals', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5))),
                  ],
                ),
                const SizedBox(height: 10),
                if (_systemSummary != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141416),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF28282E), width: 1),
                    ),
                    child: SelectableText(
                      _systemSummary!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.45, color: Color(0xFFD4D4D8)),
                    ),
                  )
                else
                  const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Dialog Testing Row
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Test Authorization Popups', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5))),
                const SizedBox(height: 4),
                const Text('Preview how Zenity prompts the user when commands need confirmation.', style: TextStyle(fontSize: 12, color: Color(0xFF888890))),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _runTestPopup(ApprovalLevel.normal),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF4F4F5),
                        side: const BorderSide(color: Color(0xFF383840)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                      child: const Text('Test Normal Popup (Allow / Deny)', style: TextStyle(fontSize: 12)),
                    ),
                    OutlinedButton(
                      onPressed: () => _runTestPopup(ApprovalLevel.red),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF87171),
                        side: const BorderSide(color: Color(0xFF522525)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                      child: const Text('Test Danger Popup (2-Step)', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String primary,
    required String secondary,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E2E34), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF71717A), letterSpacing: 0.5)),
              Icon(icon, size: 16, color: iconColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(primary, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFFF4F4F5))),
          const SizedBox(height: 2),
          Text(secondary, style: const TextStyle(fontSize: 11, color: Color(0xFF888890))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. ACTIVITY LOG VIEW (Clean, Subdued, Searchable)
// ---------------------------------------------------------------------------
class ActivityLogView extends StatefulWidget {
  final PathResolver pathResolver;

  const ActivityLogView({super.key, required this.pathResolver});

  @override
  State<ActivityLogView> createState() => _ActivityLogViewState();
}

class _ActivityLogViewState extends State<ActivityLogView> {
  List<Map<String, dynamic>> _logs = [];
  String _filter = 'ALL';
  String _search = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final file = File(widget.pathResolver.auditLogPath);
    if (!await file.exists()) return;
    try {
      final lines = await file.readAsLines();
      final parsed = <Map<String, dynamic>>[];
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        try {
          parsed.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {}
      }
      if (mounted) setState(() => _logs = parsed);
    } catch (_) {}
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF202024),
        title: const Text('Clear Audit History?'),
        content: const Text('Delete all execution logs from ~/.local/share/ubuntu-shell-mcp/audit.log?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final file = File(widget.pathResolver.auditLogPath);
      if (await file.exists()) {
        await file.writeAsString('');
        _fetch();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _logs.where((entry) {
      final decision = (entry['decision'] ?? '').toString().toUpperCase();
      if (_filter != 'ALL' && decision != _filter) return false;
      if (_search.isNotEmpty) {
        final cmd = (entry['command'] ?? '').toString().toLowerCase();
        if (!cmd.contains(_search.toLowerCase())) return false;
      }
      return true;
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Activity Log', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.2)),
                  SizedBox(height: 3),
                  Text('Cryptographically hashed execution audit trail.', style: TextStyle(color: Color(0xFF888890), fontSize: 13)),
                ],
              ),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _clear,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFF87171),
                      side: const BorderSide(color: Color(0xFF4A2525)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    child: const Text('Clear Log', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _fetch,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD4D4D8),
                      side: const BorderSide(color: Color(0xFF383840)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Search & Filter
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded, size: 16, color: Color(0xFF71717A)),
                    hintText: 'Search commands...',
                    hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
                    filled: true,
                    fillColor: const Color(0xFF202024),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF2E2E34)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF2E2E34)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (val) => setState(() => _search = val),
                ),
              ),
              const SizedBox(width: 10),
              _chip('ALL', 'All'),
              const SizedBox(width: 6),
              _chip('ALLOWED', 'Allowed'),
              const SizedBox(width: 6),
              _chip('APPROVED', 'Approved'),
              const SizedBox(width: 6),
              _chip('DENIED', 'Denied'),
              const SizedBox(width: 6),
              _chip('REFUSED', 'Refused'),
            ],
          ),
          const SizedBox(height: 14),

          // Log List
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.history_rounded, size: 36, color: Colors.grey.shade700),
                        const SizedBox(height: 8),
                        const Text('No log records match your filter', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, index) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return _buildRow(item);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String val, String label) {
    final active = _filter == val;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _filter = val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2A2A30) : const Color(0xFF202024),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? const Color(0xFF3F3F46) : const Color(0xFF28282E),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? const Color(0xFFF4F4F5) : const Color(0xFF888890),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> item) {
    final decision = (item['decision'] ?? 'UNKNOWN').toString().toUpperCase();
    final command = item['command'] ?? '';
    final time = (item['time'] ?? item['timestamp'] ?? '').toString();
    final hash = item['commandHash'] ?? item['command_hash'] ?? item['hash'] ?? '';

    Color statusColor;
    if (decision == 'ALLOWED' || decision == 'APPROVED') {
      statusColor = const Color(0xFF4ADE80);
    } else if (decision == 'DENIED' || decision == 'REFUSED') {
      statusColor = const Color(0xFFF87171);
    } else {
      statusColor = const Color(0xFFFBBF24);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF28282E)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
          ),
          const SizedBox(width: 10),
          Text(
            decision,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFE4E4E7)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 14),
          Text(
            time.length > 19 ? time.substring(11, 19) : time,
            style: const TextStyle(fontSize: 11, color: Color(0xFF71717A)),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF202024),
                  title: const Text('Audit Record Details', style: TextStyle(fontSize: 14)),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detail('Command:', command),
                      _detail('Decision:', decision),
                      _detail('Timestamp:', time),
                      if (hash.isNotEmpty) _detail('SHA-256 Hash:', hash),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.info_outline_rounded, size: 15, color: Color(0xFF71717A)),
            tooltip: 'Details',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF71717A), fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFE4E4E7))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. COMMAND SANDBOX VIEW (Minimal Terminal Console)
// ---------------------------------------------------------------------------
class SandboxView extends StatefulWidget {
  final CommandValidator validator;
  final Executor executor;
  final PathResolver pathResolver;

  const SandboxView({super.key, required this.validator, required this.executor, required this.pathResolver});

  @override
  State<SandboxView> createState() => _SandboxViewState();
}

class _SandboxViewState extends State<SandboxView> {
  final TextEditingController _cmdCtrl = TextEditingController(text: 'uname -r');
  ValidationResult? _result;
  ExecutionResult? _execResult;
  bool _isRunning = false;

  void _eval() {
    final text = _cmdCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _result = widget.validator.validate(text, widget.pathResolver.homeDirectory);
      _execResult = null;
    });
  }

  Future<void> _run() async {
    final text = _cmdCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _isRunning = true);
    try {
      final res = await widget.executor.executeCommand(text, workingDirectory: widget.pathResolver.homeDirectory);
      if (mounted) setState(() => _execResult = res);
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: ListView(
        children: [
          const Text('Security Sandbox', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.2)),
          const SizedBox(height: 3),
          const Text('Test how commands are evaluated and run through the security gates.', style: TextStyle(color: Color(0xFF888890), fontSize: 13)),
          const SizedBox(height: 20),

          // Terminal Input Box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 16, color: Color(0xFFE95420)),
                    SizedBox(width: 8),
                    Text('Command Input', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFFF4F4F5))),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _cmdCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF141416),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF28282E))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF28282E))),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _eval(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _chip('uname -r (Safe)', Icons.verified_outlined),
                    _chip('uptime (Safe)', Icons.timer_outlined),
                    _chip('ls ~/Downloads (Allowed)', Icons.folder_open_outlined),
                    _chip('ls ~/.ssh (Sensitive)', Icons.lock_outline_rounded),
                    _chip('cat /etc/shadow (Red Alert)', Icons.warning_amber_rounded),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _eval,
                      icon: const Icon(Icons.shield_outlined, size: 14),
                      label: const Text('Evaluate Tier', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFD4D4D8),
                        side: const BorderSide(color: Color(0xFF383840)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _isRunning ? null : _run,
                      icon: const Icon(Icons.play_arrow_rounded, size: 14),
                      label: Text(_isRunning ? 'Running...' : 'Execute with Gate', style: const TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE95420),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_result != null) ...[
            const SizedBox(height: 16),
            _buildResult(_result!),
          ],

          if (_execResult != null) ...[
            const SizedBox(height: 16),
            _buildOutput(_execResult!),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, IconData icon) {
    final cmd = label.split(' (')[0];
    return ActionChip(
      avatar: Icon(icon, size: 12, color: const Color(0xFFE95420)),
      label: Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFD4D4D8))),
      backgroundColor: const Color(0xFF161618),
      side: const BorderSide(color: Color(0xFF28282E)),
      padding: EdgeInsets.zero,
      onPressed: () {
        _cmdCtrl.text = cmd;
        _eval();
      },
    );
  }

  Widget _buildResult(ValidationResult res) {
    Color color;
    String tierName;
    switch (res.group) {
      case ValidationGroup.group1AutoRun:
        color = const Color(0xFF4ADE80);
        tierName = 'Tier 1: Safe to Auto-Run';
        break;
      case ValidationGroup.group2NeedsApproval:
        color = const Color(0xFFFBBF24);
        tierName = 'Tier 2: Requires Desktop User Approval';
        break;
      case ValidationGroup.redApprovalRequired:
        color = const Color(0xFFF87171);
        tierName = 'Tier 2 (Red): Dangerous Path (2-Step Dialog)';
        break;
      case ValidationGroup.group3Refused:
        color = const Color(0xFFEF4444);
        tierName = 'Tier 3: Permanently Refused';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2E2E34)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tierName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: color)),
                const SizedBox(height: 3),
                Text(res.reason, style: const TextStyle(fontSize: 12, color: Color(0xFFA1A1AA))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOutput(ExecutionResult res) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2E2E34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                res.isError ? 'Process Denied or Failed' : 'Console Output',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: res.isError ? const Color(0xFFF87171) : const Color(0xFF4ADE80)),
              ),
              Text('Exit: ${res.exitCode}', style: const TextStyle(fontSize: 11, color: Color(0xFF71717A))),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF141416),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              res.output,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFD4D4D8)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. SECURITY RULES VIEW (Clean Toggles & Tags)
// ---------------------------------------------------------------------------
class SecurityRulesView extends StatefulWidget {
  final PathResolver pathResolver;

  const SecurityRulesView({super.key, required this.pathResolver});

  @override
  State<SecurityRulesView> createState() => _SecurityRulesViewState();
}

class _SecurityRulesViewState extends State<SecurityRulesView> {
  bool _strictMode = false;
  final TextEditingController _ctrl = TextEditingController();
  List<String> _extraRoots = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final configFile = File(widget.pathResolver.serverConfigFile);
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        setState(() {
          _strictMode = json['strict_mode'] == true;
          if (json['extra_roots'] is List) {
            _extraRoots = List<String>.from(json['extra_roots'] as List);
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _save() async {
    final configFile = File(widget.pathResolver.serverConfigFile);
    if (!await configFile.parent.exists()) {
      await configFile.parent.create(recursive: true);
    }
    final data = {
      'strict_mode': _strictMode,
      'extra_roots': _extraRoots,
    };
    await configFile.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved!'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: ListView(
        children: [
          const Text('Security Rules', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.2)),
          const SizedBox(height: 3),
          const Text('Configure policy modes and folder confinement rules.', style: TextStyle(color: Color(0xFF888890), fontSize: 13)),
          const SizedBox(height: 20),

          // Strict Mode
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _strictMode ? const Color(0x28EF4444) : const Color(0x1AE95420),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _strictMode ? Icons.gavel_rounded : Icons.shield_outlined,
                    size: 18,
                    color: _strictMode ? const Color(0xFFF87171) : const Color(0xFFE95420),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Strict Mode', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5))),
                      const SizedBox(height: 2),
                      Text(
                        _strictMode
                            ? 'Enabled: Sensitive folders and high-risk actions are blocked immediately with no popups.'
                            : 'Disabled: Sensitive paths prompt for a 2-stage desktop confirmation before executing.',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF909098)),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _strictMode,
                  activeThumbColor: const Color(0xFFE95420),
                  onChanged: (val) {
                    setState(() => _strictMode = val);
                    _save();
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Allowed roots
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0x1AE95420),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.folder_shared_outlined, size: 16, color: Color(0xFFE95420)),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Allowed Folders for Auto-Run "ls"', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5))),
                          SizedBox(height: 2),
                          Text('Defaults: ~/Desktop, ~/Documents, ~/Downloads, /tmp, /var/log', style: TextStyle(fontSize: 12, color: Color(0xFF909098))),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.create_new_folder_outlined, size: 16, color: Color(0xFF71717A)),
                          hintText: 'Add custom folder (e.g. ~/Projects)',
                          hintStyle: const TextStyle(fontSize: 11, color: Color(0xFF71717A)),
                          filled: true,
                          fillColor: const Color(0xFF141416),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF28282E))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF28282E))),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        final val = _ctrl.text.trim();
                        if (val.isNotEmpty && !_extraRoots.contains(val)) {
                          setState(() {
                            _extraRoots.add(val);
                            _ctrl.clear();
                          });
                          _save();
                        }
                      },
                      icon: const Icon(Icons.add_rounded, size: 14),
                      label: const Text('Add', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFD4D4D8),
                        side: const BorderSide(color: Color(0xFF383840)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ],
                ),
                if (_extraRoots.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _extraRoots
                        .map(
                          (r) => Chip(
                            avatar: const Icon(Icons.folder_outlined, size: 13, color: Color(0xFF818CF8)),
                            label: Text(r, style: const TextStyle(fontSize: 11, color: Color(0xFFD4D4D8))),
                            backgroundColor: const Color(0xFF161618),
                            side: const BorderSide(color: Color(0xFF2E2E34)),
                            deleteIcon: const Icon(Icons.close_rounded, size: 13, color: Color(0xFF71717A)),
                            onDeleted: () {
                              setState(() => _extraRoots.remove(r));
                              _save();
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Protected paths list
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E2E34), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0x1AE95420),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.lock_outline_rounded, size: 16, color: Color(0xFFE95420)),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Protected Sensitive Directories', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFF4F4F5))),
                          SizedBox(height: 2),
                          Text('Paths guarded against unauthorized file inspection:', style: TextStyle(fontSize: 12, color: Color(0xFF909098))),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _protectedChip('~/.ssh', Icons.vpn_key_outlined),
                    _protectedChip('~/.gnupg', Icons.key_outlined),
                    _protectedChip('~/.aws', Icons.cloud_outlined),
                    _protectedChip('~/.kube', Icons.hub_outlined),
                    _protectedChip('~/.docker', Icons.developer_board_outlined),
                    _protectedChip('/etc/shadow', Icons.lock_rounded),
                    _protectedChip('/root', Icons.admin_panel_settings_outlined),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _protectedChip(String label, IconData icon) {
    return Chip(
      avatar: Icon(icon, size: 13, color: const Color(0xFFF87171)),
      label: Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFD4D4D8))),
      backgroundColor: const Color(0xFF161618),
      side: const BorderSide(color: Color(0xFF2E2E34)),
    );
  }
}
