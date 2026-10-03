import 'dart:io';
import 'package:path/path.dart' as p;
import 'path_resolver.dart';

enum ValidationGroup {
  group1AutoRun,
  group2NeedsApproval,
  redApprovalRequired,
  group3Refused,
}

class ValidationResult {
  final ValidationGroup group;
  final String reason;
  final String? executable;
  final List<String> args;
  final bool isShell;
  final String? rawCommand;

  const ValidationResult.autoRun(
    this.executable,
    this.args, [
    this.reason = 'Auto-run read-only command',
    this.rawCommand,
  ])  : group = ValidationGroup.group1AutoRun,
        isShell = false;

  const ValidationResult.approvalRequired(
    this.reason, {
    this.executable,
    this.args = const [],
    this.isShell = false,
    this.rawCommand,
  }) : group = ValidationGroup.group2NeedsApproval;

  const ValidationResult.redApprovalRequired(
    this.reason, {
    this.executable,
    this.args = const [],
    this.isShell = false,
    this.rawCommand,
  }) : group = ValidationGroup.redApprovalRequired;

  const ValidationResult.refused(
    this.reason, {
    this.rawCommand,
  })  : group = ValidationGroup.group3Refused,
        executable = null,
        args = const [],
        isShell = false;

  bool get isAutoRun => group == ValidationGroup.group1AutoRun;
  bool get isApprovalRequired => group == ValidationGroup.group2NeedsApproval;
  bool get isRedApprovalRequired => group == ValidationGroup.redApprovalRequired;
  bool get isRefused => group == ValidationGroup.group3Refused;
}

class CommandValidator {
  final PathResolver pathResolver;
  final Set<String> safeHiddenDirs;

  CommandValidator([PathResolver? resolver, Set<String>? safeHidden])
      : pathResolver = resolver ?? PathResolver(),
        safeHiddenDirs = safeHidden ?? const {};

  /// Extracts candidate path arguments from any command line string.
  List<String> extractCandidatePaths(String command, String workingDir) {
    final tokens = command.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final candidates = <String>[];

    for (var token in tokens) {
      // Remove enclosing quotes if present
      if ((token.startsWith('"') && token.endsWith('"')) ||
          (token.startsWith("'") && token.endsWith("'"))) {
        token = token.substring(1, token.length - 1);
      }

      if (token.startsWith('--') && token.contains('=')) {
        final val = token.substring(token.indexOf('=') + 1);
        if (val.isNotEmpty) {
          candidates.add(val);
        }
        continue;
      }

      if (token.startsWith('-')) {
        continue;
      }

      // Check if it appears to be a path or existing entity
      final looksLikePath = token.startsWith('/') ||
          token.startsWith('~') ||
          token.startsWith('.') ||
          token.contains('/');

      if (looksLikePath) {
        candidates.add(token);
      } else {
        // Check if token exists in working directory as file, dir, or symlink
        final localPath = p.join(workingDir, token);
        try {
          if (FileSystemEntity.typeSync(localPath, followLinks: false) !=
              FileSystemEntityType.notFound) {
            candidates.add(token);
          }
        } catch (_) {}
      }
    }

    return candidates;
  }

  /// Validates a raw command string and assigns it to one of the groups.
  ValidationResult validate(String rawCommand, [String? workingDir]) {
    final trimmed = rawCommand.trim();
    if (trimmed.isEmpty) {
      return const ValidationResult.refused('Refused: empty command string');
    }

    // --- 0. PRE-CHECKS: Control Characters, ANSI, BiDi, Length ---
    if (trimmed.length > 2000) {
      return const ValidationResult.refused(
        'Refused: Command too long',
      );
    }

    if (trimmed.contains('\x1B')) {
      return const ValidationResult.refused(
        'Refused: invalid characters in command',
      );
    }

    if (RegExp(r'[\u202A-\u202E\u2066-\u2069\u200E\u200F\u061C]').hasMatch(trimmed)) {
      return const ValidationResult.refused(
        'Refused: invalid characters in command',
      );
    }

    if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]').hasMatch(trimmed)) {
      return const ValidationResult.refused(
        'Refused: invalid characters in command',
      );
    }

    final effectiveCwd = (workingDir != null && workingDir.trim().isNotEmpty)
        ? workingDir.trim()
        : pathResolver.homeDirectory;

    final hasMetachars = RegExp(r'[;&|><$`\n\r]').hasMatch(trimmed);

    // Determine default execution targets for approval
    String defaultExec;
    List<String> defaultArgs;
    bool defaultIsShell;

    if (hasMetachars) {
      defaultExec = '/bin/bash';
      defaultArgs = ['-c', trimmed];
      defaultIsShell = true;
    } else {
      final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      defaultExec = tokens.isNotEmpty ? tokens.first : '';
      defaultArgs = tokens.length > 1 ? tokens.sublist(1) : const [];
      defaultIsShell = false;
    }

    // --- 1. SENSITIVE PATH CHECK (Applies to EVERY command) ---
    final candidatePaths = extractCandidatePaths(trimmed, effectiveCwd);
    for (final candidate in candidatePaths) {
      if (pathResolver.isSensitivePath(candidate, effectiveCwd)) {
        if (pathResolver.strictMode) {
          return const ValidationResult.refused(
            'Refused: sensitive path (strict mode)',
          );
        }
        return ValidationResult.redApprovalRequired(
          'Sensitive path: needs explicit approval',
          executable: defaultExec,
          args: defaultArgs,
          isShell: defaultIsShell,
          rawCommand: trimmed,
        );
      }
    }

    // --- 2. DANGEROUS COMMAND PATTERNS (RED APPROVAL, OR REFUSED IN STRICT MODE) ---

    // Base64 decode piped to shell/eval/source
    if (RegExp(r'base64\s+(-d|--decode).*\|\s*(bash|sh|eval|source)\b').hasMatch(trimmed) ||
        RegExp(r'\|\s*base64\s+(-d|--decode).*\|\s*(bash|sh)\b').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Base64 decode piped to shell execution is prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Base64 decode piped to shell execution is dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // Piping output into shell interpreters
    if (RegExp(r'\|\s*(bash|sh|zsh|eval|source)\b').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Piping output directly into shell, eval, or source is prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Piping output directly into shell, eval, or source is dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // Downloading and piping scripts into shell interpreters
    if (RegExp(r'(curl|wget)\b.*\|\s*(bash|sh|zsh|eval|source)\b').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Piping downloaded scripts from curl or wget into a shell is prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Piping downloaded scripts from curl or wget into a shell is dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // Recursive rm targeting root, home, or wildcards
    if (RegExp(r'\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+.*(\/|~|\$HOME|\/\*|~\/\*)(\s|$)').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Recursive deletion targeting root (/) or home (~) is prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Recursive deletion targeting root (/) or home (~) is dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // Low-level disk manipulation tools
    if (RegExp(r'\b(dd|mkfs(\.[a-z0-9]+)?)\b').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Low-level disk manipulation tools (dd, mkfs) are prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Low-level disk manipulation tools (dd, mkfs) are dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // Recursive chmod on critical system directories
    if (RegExp(r'\bchmod\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+.*(\/|\/etc|\/boot|\/usr|\/var|\/bin|\/sbin|\/lib|\/lib64)(\s|\/|\*|$)').hasMatch(trimmed)) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: Recursive chmod on system paths is prohibited (strict mode).',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Recursive chmod on system paths is dangerous',
        executable: defaultExec,
        args: defaultArgs,
        isShell: defaultIsShell,
        rawCommand: trimmed,
      );
    }

    // --- 3. CHECK SHELL METACHARACTERS (RED LEVEL APPROVAL) ---
    if (hasMetachars) {
      if (pathResolver.strictMode) {
        return const ValidationResult.refused(
          'Refused: shell syntax commands are prohibited (strict mode)',
        );
      }
      return ValidationResult.redApprovalRequired(
        'Command contains shell syntax (pipes, redirects, metacharacters)',
        executable: '/bin/bash',
        args: ['-c', trimmed],
        isShell: true,
        rawCommand: trimmed,
      );
    }

    // Split command into tokens by whitespace
    final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) {
      return const ValidationResult.refused('Refused: empty command tokens');
    }

    final cmd = tokens.first;
    final args = tokens.sublist(1);

    // Rule: Reject any argument that starts with '-' unless it is a simple letter flag
    for (final arg in args) {
      if (arg.startsWith('-')) {
        if (!RegExp(r'^-[a-zA-Z]+$').hasMatch(arg)) {
          return ValidationResult.approvalRequired(
            "Flag '$arg' is not a simple letter flag and requires approval",
            executable: cmd,
            args: args,
            rawCommand: trimmed,
          );
        }
      }
    }

    // --- 4. GROUP 1: AUTO-RUN READ-ONLY ALLOWLIST ---

    // whoami (zero arguments)
    if (cmd == 'whoami') {
      if (args.isEmpty) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: whoami', trimmed);
      }
      return ValidationResult.approvalRequired(
        'whoami with arguments requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // uname (simple letter flags: -a, -r, -s, -n, -m, -v)
    if (cmd == 'uname') {
      if (args.every((a) => RegExp(r'^-[arnsmv]+$').hasMatch(a))) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: uname', trimmed);
      }
      return ValidationResult.approvalRequired(
        'uname with unapproved flags requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // uptime (zero arguments or simple flags: -p, -s)
    if (cmd == 'uptime') {
      if (args.isEmpty || args.every((a) => RegExp(r'^-[ps]+$').hasMatch(a))) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: uptime', trimmed);
      }
      return ValidationResult.approvalRequired(
        'uptime with unapproved flags requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // free (simple letter flags: -h, -m, -g, -b, -k)
    if (cmd == 'free') {
      if (args.isEmpty || args.every((a) => RegExp(r'^-[hmgbk]+$').hasMatch(a))) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: free', trimmed);
      }
      return ValidationResult.approvalRequired(
        'free with unapproved flags requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // df (safe letter flags: -h, -k, -m, and allowed filesystem query paths: / or inside allowed roots)
    if (cmd == 'df') {
      final flagsValid = args.every((a) => a.startsWith('-') ? RegExp(r'^-[hkm]+$').hasMatch(a) : true);
      if (!flagsValid) {
        return ValidationResult.approvalRequired(
          'df with unapproved flags requires approval',
          executable: cmd,
          args: args,
          rawCommand: trimmed,
        );
      }

      final nonFlags = args.where((a) => !a.startsWith('-')).toList();
      bool pathsAllowed = true;
      for (final pth in nonFlags) {
        if (pth.contains('..')) {
          pathsAllowed = false;
          break;
        }
        if (pth == '/') {
          // Querying root filesystem usage is allowed
          continue;
        }
        try {
          final canonical = pathResolver.canonicalizePath(pth, effectiveCwd);
          if (pathResolver.isSensitivePath(canonical, effectiveCwd)) {
            if (pathResolver.strictMode) {
              return const ValidationResult.refused('Refused: sensitive path (strict mode)');
            }
            return ValidationResult.redApprovalRequired(
              'Sensitive path: needs explicit approval',
              executable: cmd,
              args: args,
              rawCommand: trimmed,
            );
          }
          if (!pathResolver.isInsideAutoRunRoots(canonical)) {
            pathsAllowed = false;
            break;
          }
        } catch (_) {
          pathsAllowed = false;
          break;
        }
      }

      if (pathsAllowed) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: df', trimmed);
      }
      return ValidationResult.approvalRequired(
        'df on path outside allowed roots requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // lsb_release (simple letter flags: -a, -d, -r, -c, -s)
    if (cmd == 'lsb_release') {
      if (args.isNotEmpty && args.every((a) => RegExp(r'^-[adrcsu]+$').hasMatch(a))) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: lsb_release', trimmed);
      }
      return ValidationResult.approvalRequired(
        'lsb_release requires simple flags',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // ls (narrowed auto-run roots: ~/Desktop, ~/Documents, ~/Downloads, /var/log, /tmp)
    if (cmd == 'ls') {
      // Must not contain recursive options in flags
      final hasRecursive = args.any(
        (a) => a.startsWith('-') && (a.contains('R') || a.contains('r') || a == '--recursive'),
      );
      if (hasRecursive) {
        return ValidationResult.approvalRequired(
          'Recursive ls requires approval',
          executable: cmd,
          args: args,
          rawCommand: trimmed,
        );
      }

      final flagsValid = args.every((a) => a.startsWith('-') ? RegExp(r'^-[la1tSdfFh]+$').hasMatch(a) : true);
      if (!flagsValid) {
        return ValidationResult.approvalRequired(
          'ls with unapproved flags requires approval',
          executable: cmd,
          args: args,
          rawCommand: trimmed,
        );
      }

      final nonFlags = args.where((a) => !a.startsWith('-')).toList();

      // If no path is specified, target is the effective working directory
      final targetPaths = nonFlags.isEmpty ? [effectiveCwd] : nonFlags;

      for (final pth in targetPaths) {
        if (pth.contains('..')) {
          return ValidationResult.approvalRequired(
            'ls with parent traversal requires approval',
            executable: cmd,
            args: args,
            rawCommand: trimmed,
          );
        }

        final canonical = pathResolver.canonicalizePath(pth, effectiveCwd);

        // Sensitive path check
        if (pathResolver.isSensitivePath(canonical, effectiveCwd)) {
          if (pathResolver.strictMode) {
            return const ValidationResult.refused('Refused: sensitive path (strict mode)');
          }
          return ValidationResult.redApprovalRequired(
            'Sensitive path: needs explicit approval',
            executable: cmd,
            args: args,
            rawCommand: trimmed,
          );
        }

        // Must be strictly inside narrowed auto-run roots
        if (!pathResolver.isInsideAutoRunRoots(canonical)) {
          return ValidationResult.approvalRequired(
            'ls on path outside auto-run roots requires approval',
            executable: cmd,
            args: args,
            rawCommand: trimmed,
          );
        }

        // Treat hidden directories inside home as needing approval
        if (pathResolver.hasHiddenHomeSegment(canonical, safeList: safeHiddenDirs)) {
          return ValidationResult.approvalRequired(
            'Hidden directory access requires approval',
            executable: cmd,
            args: args,
            rawCommand: trimmed,
          );
        }
      }

      return ValidationResult.autoRun(cmd, args, 'Auto-run: ls', trimmed);
    }

    // ps (strictly fixed safe forms, NO 'aux', NO 'eww')
    if (cmd == 'ps') {
      const allowedForms = {'', '-ef', 'ax', '-A'};
      final argStr = args.join(' ');

      final isForbiddenForm = args.contains('aux') ||
          args.any((a) => a.contains('eww') || (a.contains('e') && a != '-ef' && a != '-A'));

      final isAllowedFixed = allowedForms.contains(argStr) ||
          RegExp(r'^-[uU]\s+[a-zA-Z0-9_\-]+$').hasMatch(argStr);

      if (isAllowedFixed && !isForbiddenForm) {
        return ValidationResult.autoRun(cmd, args, 'Auto-run: ps', trimmed);
      }
      return ValidationResult.approvalRequired(
        'ps in this form requires approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // systemctl status (only as "status <name>.service")
    if (cmd == 'systemctl') {
      if (args.length == 2 && args[0] == 'status') {
        final unit = args[1];
        if (!unit.startsWith('-') &&
            unit.endsWith('.service') &&
            RegExp(r'^[a-zA-Z0-9_\-\.:@]+\.service$').hasMatch(unit)) {
          return ValidationResult.autoRun(cmd, args, 'Auto-run: systemctl status', trimmed);
        }
      }
      return ValidationResult.approvalRequired(
        'systemctl commands other than status <name>.service require approval',
        executable: cmd,
        args: args,
        rawCommand: trimmed,
      );
    }

    // --- 5. GROUP 2: EVERYTHING ELSE REQUIRES NORMAL APPROVAL ---
    return ValidationResult.approvalRequired(
      "Command '$cmd' requires approval before execution",
      executable: cmd,
      args: args,
      rawCommand: trimmed,
    );
  }
}
