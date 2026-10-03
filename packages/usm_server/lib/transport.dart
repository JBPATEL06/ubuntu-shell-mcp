import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Generic message transport interface for MCP JSON-RPC communication.
/// Allows swapping stdio for HTTP / SSE or in-memory test transports.
abstract interface class ServerTransport {
  /// Incoming stream of parsed JSON-RPC messages or parse error signals.
  Stream<Map<String, dynamic>> get incomingMessages;

  /// Sends a protocol message to the client.
  void sendResponse(Map<String, dynamic> message);

  /// Closes the transport.
  Future<void> close();
}

/// Standard I/O implementation of [ServerTransport].
/// Guarantees that ONLY protocol messages are emitted to stdout.
class StdioServerTransport implements ServerTransport {
  final StreamController<Map<String, dynamic>> _controller = StreamController();
  StreamSubscription? _stdinSubscription;

  StdioServerTransport() {
    _stdinSubscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      _handleLine,
      onError: (err) {
        stderr.writeln('transport: stdin error: $err');
        _controller.addError(err);
      },
      onDone: () {
        _controller.close();
      },
    );
  }

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        _controller.add(decoded);
      } else {
        _controller.add({
          '_isParseError': true,
          'message': 'Invalid JSON-RPC payload: Expected JSON object',
        });
      }
    } catch (e) {
      _controller.add({
        '_isParseError': true,
        'message': 'Parse error: $e',
      });
    }
  }

  @override
  Stream<Map<String, dynamic>> get incomingMessages => _controller.stream;

  @override
  void sendResponse(Map<String, dynamic> message) {
    final encoded = jsonEncode(message);
    stdout.write('$encoded\n');
  }

  @override
  Future<void> close() async {
    await _stdinSubscription?.cancel();
    await _controller.close();
  }
}

/// In-memory transport for unit testing without child processes.
class MemoryServerTransport implements ServerTransport {
  final StreamController<Map<String, dynamic>> _incoming = StreamController.broadcast();
  final List<Map<String, dynamic>> sentMessages = [];
  final StreamController<Map<String, dynamic>> _outgoing = StreamController.broadcast();

  Stream<Map<String, dynamic>> get outgoingMessages => _outgoing.stream;

  void pushClientMessage(Map<String, dynamic> message) {
    _incoming.add(message);
  }

  void pushRawLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        _incoming.add(decoded);
      } else {
        _incoming.add({
          '_isParseError': true,
          'message': 'Invalid JSON-RPC payload: Expected JSON object',
        });
      }
    } catch (e) {
      _incoming.add({
        '_isParseError': true,
        'message': 'Parse error: $e',
      });
    }
  }

  @override
  Stream<Map<String, dynamic>> get incomingMessages => _incoming.stream;

  @override
  void sendResponse(Map<String, dynamic> message) {
    sentMessages.add(message);
    _outgoing.add(message);
  }

  @override
  Future<void> close() async {
    await _incoming.close();
    await _outgoing.close();
  }
}
