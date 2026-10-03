import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  group('DisplayDiscovery & GUI Environment Discovery Suite', () {
    late Directory tempDir;
    late String runnerUid;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('display_discovery_test');
      try {
        final res = Process.runSync('id', ['-u']);
        runnerUid = res.exitCode == 0 ? res.stdout.toString().trim() : '1000';
      } catch (_) {
        runnerUid = '1000';
      }
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('prefers inherited WAYLAND_DISPLAY and logs one-line diagnostic', () {
      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {
          'WAYLAND_DISPLAY': 'wayland-custom',
          'DISPLAY': ':99',
        },
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env['WAYLAND_DISPLAY'], equals('wayland-custom'));
      expect(logs.length, equals(1));
      expect(logs.first, equals('ubuntu-shell-mcp: GUI display resolved via inherited WAYLAND_DISPLAY'));
    });

    test('prefers inherited DISPLAY if WAYLAND_DISPLAY is absent', () {
      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {
          'DISPLAY': ':42',
        },
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env['DISPLAY'], equals(':42'));
      expect(logs.length, equals(1));
      expect(logs.first, equals('ubuntu-shell-mcp: GUI display resolved via inherited DISPLAY'));
    });

    test('owned socket accepted: discovers Wayland and X11 sockets owned by current user', () {
      final fakeRunUser = Directory('${tempDir.path}/run_user')..createSync();
      final fakeUidDir = Directory('${fakeRunUser.path}/$runnerUid')..createSync();
      File('${fakeUidDir.path}/wayland-0').createSync();
      File('${fakeUidDir.path}/bus').createSync();

      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {}, // stripped environment
        runUserBaseDir: fakeRunUser.path,
        currentUid: runnerUid,
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env['WAYLAND_DISPLAY'], equals('wayland-0'));
      expect(env['XDG_RUNTIME_DIR'], equals(fakeUidDir.path));
      expect(env['DBUS_SESSION_BUS_ADDRESS'], equals('unix:path=${fakeUidDir.path}/bus'));
      expect(logs.length, equals(1));
      expect(
        logs.first,
        equals('ubuntu-shell-mcp: GUI display resolved via session socket ${fakeUidDir.path}/wayland-0'),
      );
    });

    test('owned socket accepted: falls back to owned X11 socket when Wayland is absent', () {
      final fakeRunUser = Directory('${tempDir.path}/run_user')..createSync();
      Directory('${fakeRunUser.path}/$runnerUid').createSync();
      // No Wayland socket in fakeUidDir
      final fakeX11Dir = Directory('${tempDir.path}/x11_unix')..createSync();
      final fakeXSocket = File('${fakeX11Dir.path}/X0')..createSync();

      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {}, // stripped environment
        runUserBaseDir: fakeRunUser.path,
        x11UnixBaseDir: fakeX11Dir.path,
        currentUid: runnerUid,
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env.containsKey('WAYLAND_DISPLAY'), isFalse);
      expect(env['DISPLAY'], equals(':0'));
      expect(logs.length, equals(1));
      expect(
        logs.first,
        equals('ubuntu-shell-mcp: GUI display resolved via X11 fallback ${fakeXSocket.path}'),
      );
    });

    test('socket owned by another uid rejected: rejects socket when file stat owner does not match uid', () {
      final fakeX11Dir = Directory('${tempDir.path}/x11_unix')..createSync();
      // Create a real file on disk (owned by runnerUid)
      File('${fakeX11Dir.path}/X0').createSync();

      final logs = <String>[];
      // Configure currentUid as 99999 (different from runnerUid)
      final discovery = DisplayDiscovery(
        environment: {},
        x11UnixBaseDir: fakeX11Dir.path,
        currentUid: '99999',
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      // Socket MUST be rejected because real owner (runnerUid) != currentUid (99999)
      expect(env.containsKey('DISPLAY'), isFalse);
      expect(logs, isEmpty);
    });

    test('socket owned by another uid rejected: rejects when fileOwnerResolver reports mismatched UID', () {
      final fakeRunUser = Directory('${tempDir.path}/run_user')..createSync();
      final fakeUidDir = Directory('${fakeRunUser.path}/$runnerUid')..createSync();
      File('${fakeUidDir.path}/wayland-0').createSync();

      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {},
        runUserBaseDir: fakeRunUser.path,
        currentUid: runnerUid,
        fileOwnerResolver: (path) => '99999', // Simulates foreign owner
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env.containsKey('WAYLAND_DISPLAY'), isFalse);
      expect(logs, isEmpty);
    });

    test('symlinked socket rejected: rejects X11 and Wayland sockets that are symlinks', () {
      // 1. Test X11 symlinked socket (isolate from host Wayland)
      final fakeX11Dir = Directory('${tempDir.path}/x11_unix')..createSync();
      final realTarget = File('${tempDir.path}/real_x_socket')..createSync();
      // Create symlink X0 -> real_x_socket
      Link('${fakeX11Dir.path}/X0').createSync(realTarget.path);

      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {},
        runUserBaseDir: '${tempDir.path}/empty_run_user', // Isolate from host
        x11UnixBaseDir: fakeX11Dir.path,
        currentUid: runnerUid,
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env.containsKey('DISPLAY'), isFalse);
      expect(logs, isEmpty);

      // 2. Test Wayland symlinked socket
      final fakeRunUser = Directory('${tempDir.path}/run_user')..createSync();
      final fakeUidDir = Directory('${fakeRunUser.path}/$runnerUid')..createSync();
      final realWaylandTarget = File('${tempDir.path}/real_wayland_socket')..createSync();
      Link('${fakeUidDir.path}/wayland-0').createSync(realWaylandTarget.path);

      final waylandDiscovery = DisplayDiscovery(
        environment: {},
        runUserBaseDir: fakeRunUser.path,
        x11UnixBaseDir: '${tempDir.path}/empty_x11',
        currentUid: runnerUid,
        onLogStderr: logs.add,
      );

      final waylandEnv = waylandDiscovery.discover();
      expect(waylandEnv.containsKey('WAYLAND_DISPLAY'), isFalse);
    });

    test('never uses a socket outside /run/user/<uid>/ or /tmp/.X11-unix/', () {
      final rogueFile = File('${tempDir.path}/rogue_socket')..createSync();
      final discovery = DisplayDiscovery(
        environment: {},
        currentUid: runnerUid,
      );

      // Sockets outside /run/user/<uid>/ and /tmp/.X11-unix/ are strictly rejected
      expect(discovery.isValidDisplaySocket(rogueFile.path, runnerUid), isFalse);
      expect(discovery.isValidDisplaySocket('/etc/shadow', runnerUid), isFalse);
      expect(discovery.isValidDisplaySocket('/tmp/unauthorized/X0', runnerUid), isFalse);
      expect(discovery.isValidDisplaySocket('/tmp/.X11-unix/../rogue', runnerUid), isFalse);
      expect(discovery.isValidDisplaySocket('/run/user/99999/wayland-0', runnerUid), isFalse);
    });

    test('returns unresolvable display when stripped env has no sockets anywhere', () {
      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {},
        runUserBaseDir: '${tempDir.path}/empty_run_user',
        x11UnixBaseDir: '${tempDir.path}/empty_x11',
        currentUid: '9999',
        onLogStderr: logs.add,
      );

      final env = discovery.discover();
      expect(env.containsKey('DISPLAY'), isFalse);
      expect(env.containsKey('WAYLAND_DISPLAY'), isFalse);
      expect(logs, isEmpty);
    });

    test('diagnostic logs contain no secrets or credentials', () {
      final logs = <String>[];
      final discovery = DisplayDiscovery(
        environment: {
          'WAYLAND_DISPLAY': 'wayland-0',
          'SECRET_TOKEN': 'super_secret_token_12345',
        },
        onLogStderr: logs.add,
      );

      discovery.discover();
      expect(logs.length, equals(1));
      expect(logs.first.contains('super_secret'), isFalse);
      expect(logs.first.contains('token'), isFalse);
    });
  });
}
