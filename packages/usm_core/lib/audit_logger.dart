import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'path_resolver.dart';

class AuditLogger {
  final PathResolver pathResolver;
  final File? _overrideFile;
  final Map<String, dynamic>? _clientInfoOverride;

  AuditLogger(this.pathResolver, [this._overrideFile, this._clientInfoOverride]);

  /// Resolves clientInfo (name, version) from XDG client-info.json or override.
  Map<String, dynamic>? resolveClientInfo([Map<String, dynamic>? explicitClientInfo]) {
    if (explicitClientInfo != null) return explicitClientInfo;
    if (_clientInfoOverride != null) return _clientInfoOverride;
    try {
      final file = File(pathResolver.clientInfoPath);
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map && decoded['clientInfo'] is Map) {
          final info = decoded['clientInfo'] as Map;
          final result = <String, dynamic>{};
          if (info['name'] != null) result['name'] = info['name'];
          if (info['version'] != null) result['version'] = info['version'];
          if (result.isNotEmpty) return result;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Appends a single JSON decision record per line to the audit log.
  void log({
    required String command,
    required String decision,
    int? group,
    String? level,
    String? commandHash,
    DateTime? time,
    String? cwd,
    int? latencyMs,
    String? provider,
    Map<String, dynamic>? clientInfo,
    List<Map<String, dynamic>>? stages,
    bool? fastApproval,
  }) {
    final timestamp = (time ?? DateTime.now().toUtc()).toIso8601String();
    final hash = commandHash ?? sha256.convert(utf8.encode(command)).toString();
    final resolvedClientInfo = resolveClientInfo(clientInfo);

    final record = <String, dynamic>{
      'time': timestamp,
      'command': command,
      'commandHash': hash,
      if (group != null) 'group': group,
      if (level != null) 'level': level,
      'decision': decision,
      if (cwd != null) 'cwd': cwd,
      if (latencyMs != null) 'latencyMs': latencyMs,
      if (fastApproval == true || (fastApproval == null && latencyMs != null && latencyMs < 800))
        'fastApproval': true,
      if (provider != null) 'provider': provider,
      if (resolvedClientInfo != null) 'clientInfo': resolvedClientInfo,
      if (stages != null && stages.isNotEmpty) 'stages': stages,
    };

    _writeRecord(record);
  }

  /// Appends an execution result record (sharing the same commandHash).
  /// Output (stdout/stderr) is NEVER logged for privacy and security.
  void logExecution({
    required String command,
    required String commandHash,
    required int exitCode,
    required int durationMs,
    DateTime? time,
  }) {
    final timestamp = (time ?? DateTime.now().toUtc()).toIso8601String();
    final record = <String, dynamic>{
      'time': timestamp,
      'command': command,
      'commandHash': commandHash,
      'event': 'execution',
      'decision': 'EXECUTED',
      'exitCode': exitCode,
      'durationMs': durationMs,
    };

    _writeRecord(record);
  }

  void _writeRecord(Map<String, dynamic> record) {
    final jsonLine = jsonEncode(record);
    final targetFile = _overrideFile ?? File(pathResolver.auditLogPath);

    try {
      final parentDir = targetFile.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      targetFile.writeAsStringSync('$jsonLine\n', mode: FileMode.append, flush: true);
    } catch (err) {
      stderr.writeln('Warning: Failed to write to audit log: $err');
    }
  }
}

