import 'dart:io';
import 'package:test/test.dart';
import 'package:usm_core/usm_core.dart';

void main() {
  group('Timeout Process Termination & SIGTERM/SIGKILL', () {
    late Directory tempHome;
    late Executor executor;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('timeout_test');
      final pathResolver = PathResolver({'HOME': tempHome.path});
      executor = Executor(pathResolver: pathResolver);
    });

    tearDown(() {
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    test('kills child process on timeout and verifies PID is dead', () async {
      // Execute a sleep command that would run for 10 seconds, with a 300ms timeout
      final result = await executor.executeProcess(
        'sleep',
        ['10'],
        timeout: const Duration(milliseconds: 300),
      );

      expect(result.isError, isTrue);
      expect(result.exitCode, equals(124));
      expect(result.output, contains('timed out'));
      expect(result.pid, isNotNull);

      final pid = result.pid!;

      // Wait a short grace period for the operating system to reap the terminated process
      await Future.delayed(const Duration(milliseconds: 200));

      // Verify the process is genuinely gone by signal check and procfs
      bool isAlive;
      try {
        isAlive = Process.killPid(pid);
      } catch (_) {
        isAlive = false;
      }

      final procExists = Directory('/proc/$pid').existsSync();

      expect(
        isAlive,
        isFalse,
        reason: 'Process $pid must not be running after timeout signal',
      );
      expect(
        procExists,
        isFalse,
        reason: '/proc/$pid must not exist after process termination',
      );
    });
  });
}
