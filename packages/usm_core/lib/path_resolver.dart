import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Resolves user and system paths following XDG standards and HOME.
/// Guarantees that paths remain confined to allowed roots without traversal
/// and enforces sensitive path protections with configurable strict mode.
class PathResolver {
  final Map<String, String> _env;
  final bool? _strictModeOverride;

  PathResolver([Map<String, String>? env, bool? strictMode])
      : _env = env ?? Platform.environment,
        _strictModeOverride = strictMode;

  /// The user's home directory retrieved from the HOME environment variable.
  String get homeDirectory {
    final home = _env['HOME'];
    if (home == null || home.trim().isEmpty) {
      throw StateError('HOME environment variable is not set');
    }
    return p.normalize(home.trim());
  }

  /// XDG_DATA_HOME with standard fallback to $HOME/.local/share
  String get xdgDataHome {
    final xdg = _env['XDG_DATA_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return p.normalize(xdg.trim());
    }
    return p.join(homeDirectory, '.local', 'share');
  }

  /// XDG_CONFIG_HOME with standard fallback to $HOME/.config
  String get xdgConfigHome {
    final xdg = _env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return p.normalize(xdg.trim());
    }
    return p.join(homeDirectory, '.config');
  }

  /// Full path to the JSONL audit log under XDG data directory.
  String get auditLogPath {
    return p.join(xdgDataHome, 'ubuntu-shell-mcp', 'audit.log');
  }

  /// Full path to client-info.json under XDG data directory.
  String get clientInfoPath {
    return p.join(xdgDataHome, 'ubuntu-shell-mcp', 'client-info.json');
  }

  /// Config file path for extra allowed roots in XDG config dir.
  String get allowedRootsConfigFile {
    return p.join(xdgConfigHome, 'ubuntu-shell-mcp', 'allowed_roots.conf');
  }

  /// Configuration file for general server settings (including strict_mode).
  String get serverConfigFile {
    return p.join(xdgConfigHome, 'ubuntu-shell-mcp', 'config.json');
  }

  /// Whether strict_mode is enabled.
  /// When true, RED_APPROVAL_REQUIRED commands are refused outright.
  /// Defaults to false.
  bool get strictMode {
    if (_strictModeOverride != null) {
      return _strictModeOverride;
    }
    final conf = File(serverConfigFile);
    if (conf.existsSync()) {
      try {
        final content = conf.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map && decoded['strict_mode'] is bool) {
          return decoded['strict_mode'] as bool;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Duration in seconds for cooldown after a DENIED or TIMEOUT decision.
  /// Defaults to 300 (5 minutes).
  int get cooldownDurationSeconds {
    final conf = File(serverConfigFile);
    if (conf.existsSync()) {
      try {
        final content = conf.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          final val = decoded['cooldown_seconds'] ??
              decoded['cooldown_duration_seconds'] ??
              decoded['deny_cooldown_seconds'];
          if (val is int && val > 0) {
            return val;
          }
        }
      } catch (_) {}
    }
    return 300;
  }

  /// Maximum number of approval dialogs permitted per minute.
  /// Defaults to 5.
  int get maxDialogsPerMinute {
    final conf = File(serverConfigFile);
    if (conf.existsSync()) {
      try {
        final content = conf.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          final val = decoded['max_dialogs_per_minute'] ??
              decoded['dialog_rate_limit_per_minute'];
          if (val is int && val > 0) {
            return val;
          }
        }
      } catch (_) {}
    }
    return 5;
  }

  /// List of sensitive targets that require RED_APPROVAL_REQUIRED (or refused in strict mode).
  List<String> get sensitivePaths {
    final home = homeDirectory;
    return [
      p.join(home, '.ssh'),
      p.join(home, '.gnupg'),
      p.join(home, '.aws'),
      p.join(home, '.kube'),
      p.join(home, '.docker'),
      p.join(home, '.config', 'gcloud'),
      p.join(home, '.mozilla'),
      p.join(home, '.config', 'google-chrome'),
      p.join(home, '.config', 'chromium'),
      p.join(home, '.local', 'share', 'keyrings'),
      p.join(home, '.password-store'),
      '/etc/shadow',
      '/etc/gshadow',
      '/etc/sudoers',
      '/etc/sudoers.d',
      '/root',
    ];
  }

  /// Default auto-run roots for ls:
  /// ~/Desktop, ~/Documents, ~/Downloads, /var/log, /tmp
  List<String> get defaultAutoRunRoots {
    final home = homeDirectory;
    return [
      p.join(home, 'Desktop'),
      p.join(home, 'Documents'),
      p.join(home, 'Downloads'),
      '/var/log',
      '/tmp',
    ];
  }

  /// Returns all auto-run roots for ls: default roots plus any extra roots
  /// defined in the XDG config file ($XDG_CONFIG_HOME/ubuntu-shell-mcp/allowed_roots.conf).
  List<String> getAutoRunRoots() {
    final roots = <String>[...defaultAutoRunRoots];
    final confFile = File(allowedRootsConfigFile);
    if (confFile.existsSync()) {
      try {
        final lines = confFile.readAsLinesSync();
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          final resolved = canonicalizePath(trimmed);
          if (!roots.contains(resolved)) {
            roots.add(resolved);
          }
        }
      } catch (_) {}
    }
    return roots;
  }

  /// Resolves [rawPath] completely: expands '~', resolves relative paths and '..',
  /// and follows symlinks via realpath (resolveSymbolicLinksSync).
  String canonicalizePath(String rawPath, [String? workingDir]) {
    var expanded = rawPath.trim();
    if (expanded == '~') {
      expanded = homeDirectory;
    } else if (expanded.startsWith('~/')) {
      expanded = p.join(homeDirectory, expanded.substring(2));
    }

    final baseDir = (workingDir != null && workingDir.trim().isNotEmpty)
        ? workingDir.trim()
        : homeDirectory;

    final absolutePath = p.isAbsolute(expanded)
        ? p.normalize(expanded)
        : p.normalize(p.join(baseDir, expanded));

    // Try resolving real path directly
    try {
      final type = FileSystemEntity.typeSync(absolutePath, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        return FileSystemEntity.isDirectorySync(absolutePath)
            ? Directory(absolutePath).resolveSymbolicLinksSync()
            : File(absolutePath).resolveSymbolicLinksSync();
      }
    } catch (_) {}

    // If the path does not exist, resolve its closest existing ancestor
    final parts = p.split(absolutePath);
    for (var i = parts.length - 1; i >= 0; i--) {
      final sub = p.joinAll(parts.sublist(0, i + 1));
      try {
        final type = FileSystemEntity.typeSync(sub, followLinks: false);
        if (type != FileSystemEntityType.notFound) {
          final resolvedParent = FileSystemEntity.isDirectorySync(sub)
              ? Directory(sub).resolveSymbolicLinksSync()
              : File(sub).resolveSymbolicLinksSync();
          final remaining = parts.sublist(i + 1);
          return p.normalize(p.joinAll([resolvedParent, ...remaining]));
        }
      } catch (_) {}
    }

    return absolutePath;
  }

  /// Checks if [rawPath] resolves into any protected sensitive target or /proc/<pid>/environ.
  bool isSensitivePath(String rawPath, [String? workingDir]) {
    final realPath = canonicalizePath(rawPath, workingDir);

    // Check /proc/<pid>/environ or /proc/self/environ
    if (RegExp(r'^/proc/(\d+|self)/environ(/.*)?$').hasMatch(realPath)) {
      return true;
    }

    for (final sensitive in sensitivePaths) {
      final canonicalSensitive = canonicalizePath(sensitive);
      if (realPath == canonicalSensitive) {
        return true;
      }
      final sensitivePrefix = canonicalSensitive.endsWith(p.separator)
          ? canonicalSensitive
          : '$canonicalSensitive${p.separator}';
      if (realPath.startsWith(sensitivePrefix)) {
        return true;
      }
    }

    return false;
  }

  /// Checks if [canonicalPath] is inside one of the auto-run roots for ls.
  bool isInsideAutoRunRoots(String canonicalPath) {
    final roots = getAutoRunRoots();
    for (final root in roots) {
      final canonicalRoot = canonicalizePath(root);
      if (canonicalPath == canonicalRoot) return true;
      final rootWithSep = canonicalRoot.endsWith(p.separator)
          ? canonicalRoot
          : '$canonicalRoot${p.separator}';
      if (canonicalPath.startsWith(rootWithSep)) return true;
    }
    return false;
  }

  /// Checks if [canonicalPath] points to or inside a hidden directory (starting with '.')
  /// within the user's home folder.
  bool hasHiddenHomeSegment(String canonicalPath, {Set<String> safeList = const {}}) {
    final home = canonicalizePath(homeDirectory);
    if (canonicalPath != home && canonicalPath.startsWith('$home${p.separator}')) {
      final rel = p.relative(canonicalPath, from: home);
      final parts = p.split(rel);
      for (final part in parts) {
        if (part.startsWith('.') && !safeList.contains(part)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Validates that a path is strictly inside HOME or /tmp (used for general checks).
  String resolveAndValidatePath(String targetPath, [String? workingDir]) {
    final realPath = canonicalizePath(targetPath, workingDir);
    final home = canonicalizePath(homeDirectory);
    const tmpDir = '/tmp';

    final isAllowed = realPath == home ||
        realPath.startsWith('$home${p.separator}') ||
        realPath == tmpDir ||
        realPath.startsWith('$tmpDir${p.separator}');

    if (!isAllowed) {
      throw FormatException(
        "Path '$targetPath' escapes allowed roots (resolved to '$realPath')",
      );
    }

    return realPath;
  }

  /// Discovers the path to the compiled ubuntu-shell-mcp executable.
  /// Checks candidate locations in order:
  /// 1. Directory of current executable (Platform.resolvedExecutable)
  /// 2. User local bin: $HOME/.local/bin/ubuntu-shell-mcp
  /// 3. System paths: /usr/local/bin/ubuntu-shell-mcp, /usr/bin/ubuntu-shell-mcp
  /// 4. Current working directory or subpaths (for dev / testing)
  /// 5. Common project paths in home
  /// Returns the path to the binary if found, or the default target install path ($HOME/.local/bin/ubuntu-shell-mcp).
  String resolveServerBinaryPath({String? workingDir}) {
    final candidates = <String>[];

    // 1. Next to current running app executable (for bundled release distributions)
    try {
      final appExecutable = Platform.resolvedExecutable;
      if (appExecutable.isNotEmpty) {
        final appDir = p.dirname(appExecutable);
        candidates.add(p.join(appDir, 'ubuntu-shell-mcp'));
      }
    } catch (_) {}

    // 2. User binary path
    candidates.add(p.join(homeDirectory, '.local', 'bin', 'ubuntu-shell-mcp'));

    // 3. System binary paths
    candidates.add('/usr/local/bin/ubuntu-shell-mcp');
    candidates.add('/usr/bin/ubuntu-shell-mcp');

    // 4. Current working directory or subpaths (for dev / testing)
    try {
      final cwd = workingDir ?? Directory.current.path;
      candidates.add(p.join(cwd, 'packages', 'usm_server', 'ubuntu-shell-mcp'));
      candidates.add(p.join(cwd, 'ubuntu-shell-mcp'));
    } catch (_) {}

    // 5. Common project paths in home
    candidates.add(p.join(homeDirectory, 'Desktop', 'Projects', 'Local_Mcp', 'ubuntu-shell-mcp', 'packages', 'usm_server', 'ubuntu-shell-mcp'));
    candidates.add(p.join(homeDirectory, 'ubuntu-shell-mcp-dart', 'packages', 'usm_server', 'ubuntu-shell-mcp'));

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    // Default fallback is the standard user binary location
    return p.join(homeDirectory, '.local', 'bin', 'ubuntu-shell-mcp');
  }

  /// Whether the server binary exists at the resolved path.
  bool isServerBinaryInstalled({String? workingDir}) {
    return File(resolveServerBinaryPath(workingDir: workingDir)).existsSync();
  }
}
