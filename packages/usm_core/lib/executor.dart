import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'approval_provider.dart';
import 'audit_logger.dart';
import 'command_validator.dart';
import 'path_resolver.dart';

/// Result of an executed process.
class ExecutionResult {
  final int exitCode;
  final String output;
  final ValidationGroup group;
  final bool isError;
  final int? pid;

  const ExecutionResult({
    required this.exitCode,
    required this.output,
    required this.group,
    required this.isError,
    this.pid,
  });
}

class Executor {
  static const Duration executionTimeout = Duration(seconds: 15);
  static const int maxOutputCharacters = 20000;
  static const String hardcodedPath = '/usr/local/bin:/usr/bin:/bin';

  final PathResolver pathResolver;
  final CommandValidator validator;
  final AuditLogger auditLogger;
  final ApprovalProvider approvalProvider;
  final DateTime Function() clock;
  final Duration? _cooldownDurationOverride;
  final int? _maxDialogsPerMinuteOverride;
  final Map<String, DateTime> _cooldowns = {};
  final List<DateTime> _dialogTimestamps = [];

  Executor({
    PathResolver? pathResolver,
    CommandValidator? validator,
    AuditLogger? auditLogger,
    ApprovalProvider? approvalProvider,
    DateTime Function()? clock,
    Duration? cooldownDuration,
    int? maxDialogsPerMinute,
  })  : pathResolver = pathResolver ?? PathResolver(),
        validator = validator ?? CommandValidator(pathResolver ?? PathResolver()),
        auditLogger = auditLogger ?? AuditLogger(pathResolver ?? PathResolver()),
        approvalProvider = approvalProvider ?? ZenityApprovalProvider(),
        clock = clock ?? DateTime.now,
        _cooldownDurationOverride = cooldownDuration,
        _maxDialogsPerMinuteOverride = maxDialogsPerMinute;

  Duration get cooldownDuration =>
      _cooldownDurationOverride ?? Duration(seconds: pathResolver.cooldownDurationSeconds);

  int get maxDialogsPerMinute =>
      _maxDialogsPerMinuteOverride ?? pathResolver.maxDialogsPerMinute;

  /// Strips ANSI escape codes from output text.
  static String stripAnsiCodes(String input) {
    var text = input.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
    text = text.replaceAll(RegExp(r'\x1B\].*?(\x07|\x1B\\)'), '');
    return text;
  }

  /// Spawns a process directly with Process.start, enforcing execution timeouts.
  /// On timeout, sends SIGTERM, waits up to 3 seconds, and escalates to SIGKILL if necessary.
  Future<ExecutionResult> executeProcess(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? executionTimeout;
    final workDir = workingDirectory ?? pathResolver.homeDirectory;

    Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: workDir,
        environment: {'PATH': hardcodedPath},
      );
    } catch (e) {
      return ExecutionResult(
        exitCode: 1,
        output: 'Error executing command: $e',
        group: ValidationGroup.group1AutoRun,
        isError: true,
      );
    }

    final pid = process.pid;
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write)
        .asFuture();
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture();

    int exitCode;
    bool timedOut = false;

    try {
      exitCode = await process.exitCode.timeout(effectiveTimeout);
      await Future.wait([stdoutFuture, stderrFuture]);
    } on TimeoutException {
      timedOut = true;

      // 1. Send SIGTERM for graceful termination
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}

      // 2. Wait up to 3 seconds for process to exit
      final exitedGracefully = await process.exitCode
          .then((_) => true)
          .timeout(const Duration(seconds: 3), onTimeout: () => false);

      // 3. Escalate to SIGKILL if still alive
      if (!exitedGracefully) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }

      exitCode = 124; // Standard GNU timeout exit code
    } catch (e) {
      return ExecutionResult(
        exitCode: 1,
        output: 'Process execution error: $e',
        group: ValidationGroup.group1AutoRun,
        isError: true,
        pid: pid,
      );
    }

    if (timedOut) {
      return ExecutionResult(
        exitCode: 124,
        output: 'Command timed out after ${effectiveTimeout.inSeconds} seconds and was terminated.',
        group: ValidationGroup.group1AutoRun,
        isError: true,
        pid: pid,
      );
    }

    final rawStdout = stdoutBuffer.toString();
    final rawStderr = stderrBuffer.toString();

    var combined = rawStdout;
    if (rawStderr.trim().isNotEmpty) {
      combined = combined.isEmpty ? rawStderr : '$combined\n$rawStderr';
    }

    var cleaned = stripAnsiCodes(combined).trim();
    if (cleaned.isEmpty && exitCode == 0) {
      cleaned = '(Command completed with no output)';
    }

    if (cleaned.length > maxOutputCharacters) {
      cleaned =
          '${cleaned.substring(0, maxOutputCharacters)}\n... [output truncated to 20,000 characters]';
    }

    return ExecutionResult(
      exitCode: exitCode,
      output: cleaned,
      group: ValidationGroup.group1AutoRun,
      isError: exitCode != 0,
      pid: pid,
    );
  }

  /// Executes a command adhering strictly to the approval security model.
  Future<ExecutionResult> executeCommand(
    String rawCommand, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final validation = validator.validate(rawCommand, workingDirectory);
    final effectiveCwd = (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        ? workingDirectory.trim()
        : pathResolver.homeDirectory;
    final commandHash = sha256.convert(utf8.encode(rawCommand)).toString();

    switch (validation.group) {
      case ValidationGroup.group1AutoRun:
        auditLogger.log(
          command: rawCommand,
          commandHash: commandHash,
          group: 1,
          level: 'NONE',
          decision: 'ALLOWED',
          cwd: effectiveCwd,
        );

        final sw = Stopwatch()..start();
        final execResult = await executeProcess(
          validation.executable!,
          validation.args,
          workingDirectory: effectiveCwd,
          timeout: timeout,
        );
        sw.stop();

        auditLogger.logExecution(
          command: rawCommand,
          commandHash: commandHash,
          exitCode: execResult.exitCode,
          durationMs: sw.elapsedMilliseconds,
        );

        return execResult;

      case ValidationGroup.group3Refused:
        auditLogger.log(
          command: rawCommand,
          commandHash: commandHash,
          group: 3,
          level: 'RED',
          decision: 'REFUSED',
          cwd: effectiveCwd,
        );
        return ExecutionResult(
          exitCode: 1,
          output: validation.reason,
          group: ValidationGroup.group3Refused,
          isError: true,
        );

      case ValidationGroup.group2NeedsApproval:
      case ValidationGroup.redApprovalRequired:
        final isRed = validation.group == ValidationGroup.redApprovalRequired;
        final level = isRed ? ApprovalLevel.red : ApprovalLevel.normal;
        final levelStr = isRed ? 'RED' : 'NORMAL';

        final now = clock();

        // 1. Fatigue check: auto-deny identical commandHash during cooldown after DENIED or TIMEOUT
        final lastDeniedTime = _cooldowns[commandHash];
        if (lastDeniedTime != null) {
          final elapsed = now.difference(lastDeniedTime);
          if (elapsed < cooldownDuration) {
            final remainingSec = (cooldownDuration - elapsed).inSeconds;
            auditLogger.log(
              command: rawCommand,
              commandHash: commandHash,
              group: 2,
              level: levelStr,
              decision: 'DENIED',
              cwd: effectiveCwd,
              provider: 'fatigue_protection',
            );
            return ExecutionResult(
              exitCode: 1,
              output:
                  'Command auto-denied: recent denial/timeout cooldown active ($remainingSec seconds remaining).',
              group: validation.group,
              isError: true,
            );
          } else {
            _cooldowns.remove(commandHash);
          }
        }

        // 2. Dialog rate limiting: limit dialog prompts per minute
        _dialogTimestamps.removeWhere((t) => now.difference(t) >= const Duration(seconds: 60));
        if (_dialogTimestamps.length >= maxDialogsPerMinute) {
          auditLogger.log(
            command: rawCommand,
            commandHash: commandHash,
            group: 2,
            level: levelStr,
            decision: 'DENIED',
            cwd: effectiveCwd,
            provider: 'rate_limiter',
          );
          return ExecutionResult(
            exitCode: 1,
            output:
                'Command denied: rate limit exceeded (maximum $maxDialogsPerMinute approval dialogs per minute).',
            group: validation.group,
            isError: true,
          );
        }

        // Record dialog prompt timestamp
        _dialogTimestamps.add(now);

        final approvalRequest = ApprovalRequest(
          command: rawCommand,
          cwd: effectiveCwd,
          level: level,
          reason: validation.reason,
        );

        final approvalResult = await approvalProvider.request(approvalRequest);

        switch (approvalResult.status) {
          case ApprovalStatus.approved:
            auditLogger.log(
              command: rawCommand,
              commandHash: commandHash,
              group: 2,
              level: levelStr,
              decision: 'APPROVED',
              cwd: effectiveCwd,
              latencyMs: approvalResult.latencyMs,
              provider: approvalResult.providerName ?? approvalProvider.name,
              stages: approvalResult.stages?.map((s) => s.toJson()).toList(),
              fastApproval: approvalResult.fastApproval,
            );

            // Execute the EXACT validated object without re-parsing
            final sw = Stopwatch()..start();
            final execResult = await executeProcess(
              validation.executable!,
              validation.args,
              workingDirectory: effectiveCwd,
              timeout: timeout,
            );
            sw.stop();

            auditLogger.logExecution(
              command: rawCommand,
              commandHash: commandHash,
              exitCode: execResult.exitCode,
              durationMs: sw.elapsedMilliseconds,
            );

            return execResult;

          case ApprovalStatus.denied:
            _cooldowns[commandHash] = now;
            auditLogger.log(
              command: rawCommand,
              commandHash: commandHash,
              group: 2,
              level: levelStr,
              decision: 'DENIED',
              cwd: effectiveCwd,
              latencyMs: approvalResult.latencyMs,
              provider: approvalResult.providerName ?? approvalProvider.name,
              stages: approvalResult.stages?.map((s) => s.toJson()).toList(),
              fastApproval: approvalResult.fastApproval,
            );
            return ExecutionResult(
              exitCode: 1,
              output: 'Command denied by user',
              group: validation.group,
              isError: true,
            );

          case ApprovalStatus.timeout:
            _cooldowns[commandHash] = now;
            auditLogger.log(
              command: rawCommand,
              commandHash: commandHash,
              group: 2,
              level: levelStr,
              decision: 'TIMEOUT',
              cwd: effectiveCwd,
              latencyMs: approvalResult.latencyMs,
              provider: approvalResult.providerName ?? approvalProvider.name,
              stages: approvalResult.stages?.map((s) => s.toJson()).toList(),
              fastApproval: approvalResult.fastApproval,
            );
            return ExecutionResult(
              exitCode: 1,
              output: 'Approval timed out (60s)',
              group: validation.group,
              isError: true,
            );

          case ApprovalStatus.unavailable:
            auditLogger.log(
              command: rawCommand,
              commandHash: commandHash,
              group: 2,
              level: levelStr,
              decision: 'UNAVAILABLE',
              cwd: effectiveCwd,
              provider: approvalResult.providerName ?? approvalProvider.name,
            );
            final reason = approvalResult.message ?? 'dialog error';
            return ExecutionResult(
              exitCode: 1,
              output: 'Approval dialog unavailable: $reason',
              group: validation.group,
              isError: true,
            );
        }
    }
  }

  /// Returns a structured, fast system summary.
  Future<String> getSystemSummary() async {
    Future<String> runSafe(String executable, List<String> args) async {
      try {
        final res = await executeProcess(
          executable,
          args,
          timeout: const Duration(seconds: 5),
        );
        return res.isError ? 'N/A' : res.output;
      } catch (_) {
        return 'N/A';
      }
    }

    final hostname = Platform.localHostname;
    final unameA = await runSafe('uname', ['-a']);
    final uptime = await runSafe('uptime', ['-p']);
    final dfH = await runSafe('df', ['-h', '/']);
    final freeM = await runSafe('free', ['-h']);

    final buffer = StringBuffer();
    buffer.writeln('=== SYSTEM SUMMARY ===');
    buffer.writeln('Hostname: $hostname');
    buffer.writeln('Kernel & OS: $unameA');
    buffer.writeln('Uptime: $uptime');
    buffer.writeln('\n--- Disk Usage (/) ---');
    buffer.writeln(dfH);
    buffer.writeln('\n--- Memory Usage ---');
    buffer.writeln(freeM);

    return buffer.toString().trim();
  }
}
