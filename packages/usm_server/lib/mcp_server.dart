import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:usm_core/usm_core.dart';
import 'transport.dart';

class McpServer {
  static const String serverName = 'ubuntu-shell-mcp';
  static const String serverVersion = '1.0.0';
  static const String defaultProtocolVersion = '2024-11-05';
  static const String latestProtocolVersion = '2025-11-25';

  /// Supported MCP protocol versions per specification.
  /// 2024-11-05: initial release
  /// 2025-03-26: interim specification
  /// 2025-06-18: introduced form-mode elicitation
  /// 2025-11-25: introduced URL-mode elicitation (latest)
  static const List<String> supportedProtocolVersions = [
    '2024-11-05',
    '2025-03-26',
    '2025-06-18',
    '2025-11-25',
  ];

  final ServerTransport transport;
  final Executor executor;
  final Duration elicitationTimeout;
  final Queue<Map<String, dynamic>> _messageQueue = Queue();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  int _serverRequestIdCounter = 1;
  bool _isProcessing = false;
  StreamSubscription? _subscription;
  Map<String, dynamic> _clientCapabilities = {};
  bool _hasElicitationCapability = false;
  String _negotiatedProtocolVersion = defaultProtocolVersion;

  McpServer({
    required this.transport,
    required this.executor,
    this.elicitationTimeout = const Duration(seconds: 60),
  });

  bool get hasElicitationCapability => _hasElicitationCapability;
  Map<String, dynamic> get clientCapabilities => Map.unmodifiable(_clientCapabilities);
  String get negotiatedProtocolVersion => _negotiatedProtocolVersion;
  Map<String, Completer<Map<String, dynamic>>> get pendingRequests => _pendingRequests;

  /// The list of tools provided by this server.
  /// Compact descriptions kept under 100 characters.
  /// elicit_test is hidden unless USM_EXPERIMENTAL=1.
  static List<Map<String, dynamic>> get toolsDefinition {
    final showExperimental = Platform.environment['USM_EXPERIMENTAL'] == '1';
    final tools = <Map<String, dynamic>>[
      {
        'name': 'run_command',
        'description': 'Run a read-only terminal command.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The command line to execute',
            },
          },
          'required': ['command'],
        },
      },
      {
        'name': 'system_summary',
        'description': 'Show host, OS, uptime, disk and memory.',
        'inputSchema': {
          'type': 'object',
          'properties': {},
        },
      },
    ];

    if (showExperimental) {
      tools.add({
        'name': 'elicit_test',
        'description': 'Test client elicitation support (experimental).',
        'inputSchema': {
          'type': 'object',
          'properties': {},
        },
      });
    }

    return tools;
  }

  /// Starts listening for incoming JSON-RPC messages and processes them in strict request order.
  void start() {
    _subscription = transport.incomingMessages.listen(
      (message) {
        // Immediate routing of server-initiated request responses (has 'id', 'result'/'error', NO 'method').
        // This avoids deadlocking pending tool calls waiting on client replies.
        final hasId = message.containsKey('id') && message['id'] != null;
        final hasResultOrError = message.containsKey('result') || message.containsKey('error');
        final hasMethod = message.containsKey('method');

        if (hasId && hasResultOrError && !hasMethod) {
          final idStr = message['id'].toString();
          final completer = _pendingRequests.remove(idStr);
          if (completer != null && !completer.isCompleted) {
            completer.complete(message);
          }
          // Unsolicited or unmatched response is cleanly ignored without crashing
          return;
        }

        _messageQueue.add(message);
        _processQueue();
      },
      onError: (err) {
        // Transport level errors handled or logged
      },
    );
  }

  /// Processes queued incoming messages sequentially to ensure responses arrive in request order.
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_messageQueue.isNotEmpty) {
        final message = _messageQueue.removeFirst();
        await _handleMessage(message);
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// Stops the server.
  Future<void> stop() async {
    await _subscription?.cancel();
    await transport.close();
  }

  /// Dispatches incoming JSON-RPC request or notification.
  Future<void> _handleMessage(Map<String, dynamic> message) async {
    // Check if this was an incoming raw parse error
    if (message['_isParseError'] == true) {
      transport.sendResponse({
        'jsonrpc': '2.0',
        'id': null,
        'error': {
          'code': -32700,
          'message': message['message']?.toString() ?? 'Parse error',
        },
      });
      return;
    }

    final method = message['method'] as String?;
    final id = message['id']; // null for notifications

    if (method == null) {
      if (id != null) {
        transport.sendResponse({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32600,
            'message': 'Invalid Request: Missing method',
          },
        });
      }
      return;
    }

    // Notifications (no response expected)
    if (id == null) {
      final rawParams = message['params'];
      _handleNotification(
        method,
        rawParams is Map ? rawParams.cast<String, dynamic>() : null,
      );
      return;
    }

    final rawParams = message['params'];
    final params =
        rawParams is Map ? rawParams.cast<String, dynamic>() : <String, dynamic>{};

    switch (method) {
      case 'initialize':
        _handleInitialize(id, params);
        break;

      case 'ping':
        transport.sendResponse({
          'jsonrpc': '2.0',
          'id': id,
          'result': {},
        });
        break;

      case 'tools/list':
        _handleToolsList(id);
        break;

      case 'tools/call':
        await _handleToolsCall(id, params);
        break;

      default:
        transport.sendResponse({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32601,
            'message': 'Method not found: $method',
          },
        });
        break;
    }
  }

  void _handleNotification(String method, Map<String, dynamic>? params) {
    if (method == 'notifications/initialized') {
      // Client confirmed initialization handshake
      return;
    }
  }

  void _handleInitialize(dynamic id, Map<String, dynamic> params) {
    final clientVersion = params['protocolVersion']?.toString();
    final negotiatedVersion = (clientVersion != null && supportedProtocolVersions.contains(clientVersion))
        ? clientVersion
        : latestProtocolVersion;
    _negotiatedProtocolVersion = negotiatedVersion;

    final rawCaps = params['capabilities'];
    final capabilities = rawCaps is Map ? rawCaps.cast<String, dynamic>() : <String, dynamic>{};
    _clientCapabilities = capabilities;

    // Check if elicitation capability is present
    _hasElicitationCapability = capabilities.containsKey('elicitation') &&
        capabilities['elicitation'] != null &&
        capabilities['elicitation'] != false;

    // Write client capabilities to XDG client-info.json (one line)
    try {
      final clientInfoFile = File(executor.pathResolver.clientInfoPath);
      clientInfoFile.parent.createSync(recursive: true);
      final record = {
        'protocolVersion': clientVersion,
        'negotiatedVersion': negotiatedVersion,
        'clientInfo': params['clientInfo'] ?? {},
        'capabilities': capabilities,
        'elicitation': _hasElicitationCapability,
      };
      clientInfoFile.writeAsStringSync('${jsonEncode(record)}\n');
    } catch (_) {}

    transport.sendResponse({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': negotiatedVersion,
        'capabilities': {
          'tools': {},
        },
        'serverInfo': {
          'name': serverName,
          'version': serverVersion,
        },
      },
    });
  }

  void _handleToolsList(dynamic id) {
    transport.sendResponse({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'tools': toolsDefinition,
      },
    });
  }

  /// Sends a server-to-client JSON-RPC request and awaits the client's reply.
  Future<Map<String, dynamic>?> sendServerRequest(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final requestId = 'srv-${_serverRequestIdCounter++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    transport.sendResponse({
      'jsonrpc': '2.0',
      'id': requestId,
      'method': method,
      'params': params,
    });

    final effectiveTimeout = timeout ?? elicitationTimeout;
    try {
      final response = await completer.future.timeout(effectiveTimeout);
      return response;
    } on TimeoutException {
      _pendingRequests.remove(requestId);
      return null;
    } catch (_) {
      _pendingRequests.remove(requestId);
      return null;
    }
  }

  Future<void> _handleToolsCall(dynamic id, Map<String, dynamic> params) async {
    final toolName = params['name'] as String?;
    final rawArgs = params['arguments'];
    final args = rawArgs is Map ? rawArgs.cast<String, dynamic>() : <String, dynamic>{};

    if (toolName == 'run_command') {
      final command = args['command']?.toString() ?? '';
      final result = await executor.executeCommand(command);

      transport.sendResponse({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': result.output,
            },
          ],
          'isError': result.isError,
        },
      });
      return;
    }

    if (toolName == 'system_summary') {
      final summary = await executor.getSystemSummary();

      transport.sendResponse({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': summary,
            },
          ],
          'isError': false,
        },
      });
      return;
    }

    if (toolName == 'elicit_test') {
      await _handleElicitTest(id);
      return;
    }

    // Unknown tool name
    transport.sendResponse({
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': -32602,
        'message': "Unknown tool: '$toolName'",
      },
    });
  }

  /// EXPERIMENTAL: Tests whether the client supports the MCP elicitation feature.
  /// Must NOT execute any system command.
  Future<void> _handleElicitTest(dynamic id) async {
    if (!_hasElicitationCapability) {
      transport.sendResponse({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': 'elicitation not supported by this client',
            },
          ],
          'isError': false,
        },
      });
      return;
    }

    final response = await sendServerRequest(
      'elicitation/create',
      {
        'mode': 'form',
        'message': "Test: approve running 'uname -r'?",
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'approve': {
              'type': 'boolean',
              'title': 'Approve this command?',
            },
          },
          'required': ['approve'],
        },
      },
    );

    String resultText;
    if (response == null) {
      // 60-second timeout -> treated as DECLINED
      resultText = 'declined';
    } else if (response.containsKey('error')) {
      resultText = 'declined';
    } else {
      final rawResult = response['result'];
      if (rawResult is Map) {
        final action = rawResult['action']?.toString().toLowerCase();
        if (action == 'accept') {
          final content = rawResult['content'];
          if (content is Map && content.containsKey('approve')) {
            final approveVal = content['approve'];
            resultText = 'accepted: $approveVal';
          } else if (content is bool) {
            resultText = 'accepted: $content';
          } else {
            resultText = 'accepted: true';
          }
        } else if (action == 'decline') {
          resultText = 'declined';
        } else if (action == 'cancel') {
          resultText = 'cancelled';
        } else {
          resultText = 'declined';
        }
      } else {
        resultText = 'declined';
      }
    }

    transport.sendResponse({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'content': [
          {
            'type': 'text',
            'text': resultText,
          },
        ],
        'isError': false,
      },
    });
  }
}
