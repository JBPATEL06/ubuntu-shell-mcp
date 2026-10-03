# Comprehensive Security & Architectural Diagnosis

This document provides a line-by-line evidence-backed diagnosis of the `ubuntu-shell-mcp` security implementation in `~/ubuntu-shell-mcp-dart`.

---

## 1. RED Double Confirmation
**Verdict: OK**

### Evidence & Analysis
- **Sequential Two-Dialog Flow:**
  In [`packages/usm_core/lib/approval_provider.dart`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L212-L228), RED requests execute two sequential dialogs:
  ```dart
  // Red level: requires two confirmation dialogs
  final firstResult = await _showDialog(
    args: _buildRedFirstArgs(request),
    env: env,
  );
  if (!firstResult.isApproved) {
    return firstResult;
  }

  // Second confirmation dialog
  return _showDialog(
    args: _buildRedSecondArgs(request),
    env: env,
  );
  ```
  Both `_showDialog` calls are properly awaited. The second dialog is only initiated if `firstResult.isApproved` (`exitCode == 0`).

- **Dialog Arguments & Visual Presentation:**
  - **Dialog 1** ([`packages/usm_core/lib/approval_provider.dart#L251-L271`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L251-L271)):
    - Title: `"DANGEROUS: review carefully"`
    - Icon: `"dialog-warning"`
    - Buttons: `"Allow"` (`--ok-label`), `"Deny"` (`--cancel-label`)
    - Body text:
      ```text
      WARNING: DANGEROUS / SENSITIVE COMMAND REQUESTED

      Command to execute:
      --------------------------------------------------
      <command>
      --------------------------------------------------
      Working Directory: <cwd>
      Reason: <reason>
      ```
  - **Dialog 2** ([`packages/usm_core/lib/approval_provider.dart#L273-L294`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L273-L294)):
    - Title: `"DANGEROUS: Final Confirmation"`
    - Icon: `"dialog-warning"`
    - Buttons: `"Yes, Execute Dangerous Command"` (`--ok-label`), `"Cancel / Deny"` (`--cancel-label`)
    - Default button: `--default-cancel` (Enter defaults to Deny)
    - Body text:
      ```text
      FINAL CONFIRMATION REQUIRED:

      Are you ABSOLUTELY sure you want to execute this dangerous command?
      This action cannot be undone.

      Command:
      --------------------------------------------------
      <command>
      --------------------------------------------------
      ```

- **Branches Where RED Shows Fewer Than Two Dialogs:**
  1. `!hasDisplay`: Zero dialogs shown, returns `unavailable` immediately ([`approval_provider.dart#L193-L198`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L193-L198)).
  2. `!_isZenityAvailable`: Zero dialogs shown, returns `unavailable` immediately ([`approval_provider.dart#L201-L205`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L201-L205)).
  3. First Dialog Denied (`exitCode == 1`): Exactly 1 dialog shown, returns `denied` ([`approval_provider.dart#L218-L220`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L218-L220)).
  4. First Dialog Timeout (`exitCode == 5` or 60s timeout): Exactly 1 dialog shown, returns `timeout`.
  5. First Dialog Process Error (`exitCode` unknown or process spawn failure): Returns `denied` or `unavailable`.
  *Note:* There is NO code path where an approved RED command shows only one dialog. If `APPROVED` is recorded in the audit log, both dialogs exited with code 0. In Wayland/GNOME, because both dialogs spawn at identical center screen coordinates, clicking "Allow" on Dialog 1 causes Dialog 2 to appear in the exact same footprint, which can be perceived as a single step if clicked rapidly.

- **Proof That Denying Dialog 2 Blocks Execution:**
  In [`packages/usm_core/lib/executor.dart#L246-L260`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L246-L260), if the result is `denied`, the executor logs `"DENIED"` and exits without invoking `executeProcess`.
  Tested and verified in [`packages/usm_core/test/approval_flow_test.dart#L168-L209`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/test/approval_flow_test.dart#L168-L209): Dialog 1 accepted (exitCode 0), Dialog 2 denied (exitCode 1) -> `redResult.status == ApprovalStatus.denied` and `execRes.output == 'Command denied by user'`.

- **`--test-dialog` Flag:**
  In [`packages/usm_server/bin/main.dart#L7-L28`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_server/bin/main.dart#L7-L28), `--test-dialog` spawns real interactive Zenity dialogs (`Normal` then `Red`) requiring manual user clicks. Per user instruction (*"If it needs my clicks, tell me and skip it"*), automated execution was skipped.

---

## 2. Audit Log Gaps
**Verdict: PROBLEM**

### Evidence & Analysis
- **Current Log Schema:**
  [`packages/usm_core/lib/audit_logger.dart#L24-L31`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/audit_logger.dart#L24-L31) records:
  ```dart
  final record = <String, dynamic>{
    'time': timestamp,
    'command': command,
    'commandHash': hash,
    if (group != null) 'group': group,
    if (level != null) 'level': level,
    'decision': decision,
  };
  ```
- **Identified Deficiencies:**
  1. **No Stage-by-Stage Visibility:** For RED commands, only the final `decision` (`APPROVED`, `DENIED`, etc.) is recorded. It does not record whether Stage 1 succeeded when Stage 2 failed, nor does it record intermediate timestamps.
  2. **No Response Latency:** The log does not record user review duration (elapsed time between dialog display and user click). Sub-second approvals on RED commands (potential click-jacking or accidental double-clicking) cannot be audited.
  3. **No Approval Provider Attribution:** The log does not distinguish between approvals from `ZenityApprovalProvider`, MCP elicitation, or automated unit test providers.
  4. **No Working Directory:** The working directory (`cwd`) where the command was approved to run is omitted from the log.
  5. **No Execution Result:** The log records the approval decision, but does NOT record command exit code, execution duration, or stdout/stderr length.
  6. **No Client Attribution:** Client metadata (`clientInfo`: `claude-ai v0.1.0` vs `cursor`) is not tied to the audit record.

---

## 3. The UNAVAILABLE Entry
**Verdict: PROBLEM**

### Evidence & Analysis
- **Why the 14:03 Request Was UNAVAILABLE:**
  In `audit.log`:
  ```json
  {"time":"2026-10-03T14:03:28.164474Z","command":"find ~ -mindepth 1 -maxdepth 1 -type d | wc -l","commandHash":"c4a4f689d7146ddcd2ec53b3a5c6dd2831b7a567eb63399f3173af45ba3d3f64","group":2,"level":"RED","decision":"UNAVAILABLE"}
  ```
  Prior to our environment discovery patch, [`packages/usm_core/lib/approval_provider.dart#L96-L109`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/approval_provider.dart#L96-L109) only read `Platform.environment['DISPLAY']` and `Platform.environment['WAYLAND_DISPLAY']`.
  When Claude Desktop spawns MCP servers on Linux (verified via `/proc/17197/environ`), it strips the environment down to:
  `HOME`, `LOGNAME`, `PATH`, `SHELL`, `USER`.
  Because `DISPLAY` and `WAYLAND_DISPLAY` were both absent, line 194 triggered:
  ```dart
  if (!hasDisplay) {
    return const ApprovalResult.unavailable(
      'neither DISPLAY nor WAYLAND_DISPLAY is set in server environment',
    );
  }
  ```
  Zenity was never launched; the server immediately rejected the request.

- **Why the 14:13 Request Was APPROVED:**
  Between 14:08 and 14:10 UTC (19:38-19:40 local), we updated `approval_provider.dart` with Linux session socket discovery (`/run/user/<uid>/wayland-0`, `/run/user/<uid>/bus`), recompiled the binary, and terminated the stale process. When Claude Desktop re-invoked the tool at 14:13, the new binary auto-detected Wayland, displayed the dialogs, and the user clicked to approve.

- **How to Inspect Environment Under Claude Desktop:**
  Without code changes, inspect the process environment from the terminal:
  ```bash
  tr '\0' '\n' < /proc/$(pgrep -f "packages/usm_server/ubuntu-shell-mcp" | head -n 1)/environ
  ```

- **Proof That UNAVAILABLE Aborts Execution:**
  In [`packages/usm_core/lib/executor.dart#L276-L291`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L276-L291):
  ```dart
  case ApprovalStatus.unavailable:
    auditLogger.log(
      command: rawCommand,
      commandHash: commandHash,
      group: 2,
      level: levelStr,
      decision: 'UNAVAILABLE',
    );
    final reason = approvalResult.message ?? 'dialog error';
    return ExecutionResult(
      exitCode: 1,
      output: 'Approval dialog unavailable: $reason',
      group: validation.group,
      isError: true,
    );
  ```
  `executeProcess` is never reached. Verified in test [`packages/usm_core/test/approval_flow_test.dart#L134-L152`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/test/approval_flow_test.dart#L134-L152).

---

## 4. Classification Checks
**Verdict: OK**

### Evidence & Analysis
- **Why `ip -br a` Was Group 2 / NORMAL:**
  [`packages/usm_core/lib/command_validator.dart#L324-L565`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L324-L565) explicitly lists all Group 1 auto-run commands (`whoami`, `uname`, `uptime`, `free`, `df`, `lsb_release`, constrained `ls`, constrained `ps`, `systemctl status *.service`).
  `ip` is not on the auto-run allowlist. Under the fail-closed architecture, line 568 triggers:
  ```dart
  // --- 5. GROUP 2: EVERYTHING ELSE REQUIRES NORMAL APPROVAL ---
  return ValidationResult.approvalRequired(
    "Command '$cmd' requires approval before execution",
    executable: cmd,
    args: args,
    rawCommand: trimmed,
  );
  ```
  This is intended: network enumeration (`ip`) reveals interface MAC addresses, VPN routes, and local topology.

- **Full List of Rules That Produce RED Classification:**
  1. **Sensitive Path Arguments** ([`command_validator.dart#L170-L184`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L170-L184)): Target paths matching `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `/etc/shadow`, `/root`, etc.
  2. **Base64 Decode Piped to Shell** ([`command_validator.dart#L188-L203`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L188-L203)): `base64 -d ... | bash/sh/eval/source`.
  3. **Piping to Shell Interpreters** ([`command_validator.dart#L205-L219`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L205-L219)): `... | bash|sh|zsh|eval|source`.
  4. **Piping Web Downloads to Shell** ([`command_validator.dart#L221-L235`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L221-L235)): `curl|wget ... | bash|sh`.
  5. **Recursive Root/Home Deletion** ([`command_validator.dart#L237-L251`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L237-L251)): `rm -r ... / | ~ | $HOME`.
  6. **Disk Manipulation Tools** ([`command_validator.dart#L253-L267`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L253-L267)): `dd`, `mkfs.*`.
  7. **Recursive System `chmod`** ([`command_validator.dart#L269-L283`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L269-L283)): `chmod -R ... /etc | /usr | /var | ...`.
  8. **Shell Metacharacters & Pipelines** ([`command_validator.dart#L285-L299`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L285-L299)): Any command with `|`, `&`, `;`, `<`, `>`, `(`, `)`, `$`, `` ` ``, `\`.
  9. **Sensitive Paths in `df`** ([`command_validator.dart#L403-L413`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L403-L413)).
  10. **Sensitive Paths in `ls`** ([`command_validator.dart#L491-L501`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L491-L501)).

- **Execution Path for `find ~ ... | wc -l`:**
  Matches rule #8 (contains pipe `|`). In [`command_validator.dart#L292-L298`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart#L292-L298), it yields:
  `executable: '/bin/bash', args: ['-c', trimmed], isShell: true, rawCommand: trimmed`.
  Upon approval, [`executor.dart#L239-L244`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L239-L244) executes `/bin/bash` with `args: ['-c', 'find ~ -mindepth 1 -maxdepth 1 -type d | wc -l']`.
  The string passed to `/bin/bash -c` is identical to the string shown in the dialog.

---

## 5. Executed = Approved
**Verdict: OK**

### Evidence & Analysis
- **Data Flow Trace:**
  1. [`packages/usm_core/lib/command_validator.dart`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/command_validator.dart): Tokenizes or builds shell arguments into an immutable `ValidationResult` (`validation.executable`, `validation.args`).
  2. [`packages/usm_core/lib/executor.dart#L219-L224`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L219-L224): `ApprovalRequest` is instantiated with `rawCommand` and `effectiveCwd`.
  3. User reviews and approves the dialog.
  4. [`packages/usm_core/lib/executor.dart#L239-L244`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L239-L244):
     ```dart
     // Execute the EXACT validated object without re-parsing
     return executeProcess(
       validation.executable!,
       validation.args,
       workingDirectory: effectiveCwd,
       timeout: timeout,
     );
     ```
  5. [`packages/usm_core/lib/executor.dart#L68-L82`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/lib/executor.dart#L68-L82): `executeProcess` forwards `validation.executable!` and `validation.args` directly to `Process.start` without any string re-splitting or shell re-wrapping.
  Tested and verified in [`packages/usm_core/test/approval_flow_test.dart#L361-L383`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/test/approval_flow_test.dart#L361-L383).

---

## 6. Test Quality
**Verdict: PROBLEM**

### Evidence & Analysis
- **Mock vs Real Test Coverage:**
  - Automated tests heavily rely on `FakeApprovalProvider` or `ZenityApprovalProvider` with `processStarter` mocks.
  - **No automated test validates real GUI rendering or button click handling with the native `/usr/bin/zenity` binary.**
  - **No test launches the compiled binary under a stripped desktop environment like Claude Desktop.**
- **Leftover `/tmp` Directories:**
  - `allowed_home*`, `escape_home*`, `fake_home*`, `fake_home_custom*` are created by [`packages/usm_core/test/path_resolver_test.dart#L8,L21,L40,L49`](file:///home/jeel/ubuntu-shell-mcp-dart/packages/usm_core/test/path_resolver_test.dart#L8).
  - The test uses `Directory.systemTemp.createTempSync(...)` but contains NO `tearDown()` or `addTearDown()` blocks. Every test execution leaves orphaned directories in `/tmp/`.
  - `scoped_dir*` in `/tmp` was created by Chromium / Electron (Claude Desktop) for its single-instance lock (`SingletonCookie`, `SingletonSocket`), not by the Dart test suite.

---

## Ranked Problems by Security Impact

| Rank | Severity | Issue | Impact |
|:---:|:---:|:---|:---|
| **1** | **Medium** | **Audit Log Gaps** | Incomplete audit trail: no stage-1 vs stage-2 tracking for RED dialogs, no response latency measurement, no `cwd` logged, and no client attribution. |
| **2** | **Low-Medium** | **Lack of Real End-to-End GUI Integration Tests** | Without an integration test running in an isolated/headless Xvfb/Weston runner, regressions in GUI environment discovery cannot be caught by CI. |
| **3** | **Low** | **Test Hygiene (Leftover `/tmp` Dirs)** | `path_resolver_test.dart` leaks temporary directories on every test run due to missing teardown hooks. |

---

## Proposed Fix List (For Future Implementation)

1. **Audit Logging Enhancements (`audit_logger.dart`):**
   - Add fields: `cwd`, `latencyMs`, `stages` (`[{stage: 1, approved: true}, {stage: 2, approved: true}]`), `provider: 'zenity'`, and `clientInfo`.
   - Log both pre-execution approval and post-execution exit status (`exitCode`, `durationMs`).

2. **Automated Teardown in Tests (`path_resolver_test.dart`):**
   - Add `addTearDown(() => Directory(fakeHome).deleteSync(recursive: true));` to each test case in `path_resolver_test.dart`.

3. **Headless Desktop Integration Test:**
   - Add an integration test using a virtual Wayland compositor (e.g. `headless-backend` or Xvfb) to assert that Zenity actually launches and renders without mocks.

