# ubuntu-shell MCP Server

A hardened, local **Model Context Protocol (MCP)** server written in **Dart** with a companion **Flutter** desktop management application for **Ubuntu Linux** and **Claude Desktop**.

This server provides Claude Desktop with controlled, safe access to the Ubuntu terminal environment over standard input/output (`stdio`). It enforces a strict **three-tier security gate**, sequential desktop graphical authorization dialogs (`zenity`), safe `sudo` isolation via `zenity --password`, filesystem path traversal protection, approval fatigue cooldowns, rate limiting, Wayland/X11 socket auto-discovery, and structured JSONL audit logging.

---

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Three-Tier Security Model](#three-tier-security-model)
- [Approval Fatigue & Rate Limiting](#approval-fatigue--rate-limiting)
- [Display Discovery & Stripped Environments](#display-discovery--stripped-environments)
- [Sudo Lockdown & Password Isolation](#sudo-lockdown--password-isolation)
- [Path & Working Directory Hardening](#path--working-directory-hardening)
- [Audit Logging](#audit-logging)
- [MCP Tools Reference](#mcp-tools-reference)
- [Flutter Management Dashboard](#flutter-management-dashboard)
- [Building & Testing](#building--testing)
- [Claude Desktop Configuration](#claude-desktop-configuration)
- [Project Structure](#project-structure)

---

## Overview & Architecture

- **Pure Stdio Transport**: Operates strictly over `stdio` without opening any network ports, web servers, or sockets.
- **Fail-Closed Design**: Any authorization dialog failure, missing desktop display, timeout, or runtime error results in an immediate **DENIED** decision. Commands never run on error.
- **Exact String Binding**: Authorization dialogs display the exact command string that will execute. Approval is strictly bound to that string with no re-parsing or mutation between authorization and execution.
- **Dart 3.5+ Workspace**: Modular architecture separating reusable core security/execution logic (`usm_core`) from MCP protocol handling (`usm_server`).
- **Compiled Native Binary**: High-performance AOT compilation (`dart compile exe`) with instantaneous startup and low memory footprint.

---

## Three-Tier Security Model

Every command sent to `run_command` is inspected and classified into one of three security tiers before anything executes:

```
                          [ Incoming Command ]
                                   │
                                   ▼
                    ┌───────────────────────────────┐
                    │   Security Classification     │
                    └───────────────┬───────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
    [ TIER 1: Auto-Run ]   [ TIER 2: Prompt User ]   [ TIER 3: Refused ]
    Safe read-only         Requires native Ubuntu    Permanently blocked
    allowlist commands     desktop dialog (Zenity)   (No dialog, denied)
          │                         │                         │
          ▼                         ▼                         ▼
    Execute directly       Approved? ──► Run          Returns error & logs
                           Denied?   ──► Abort
```

### Tier 1: Auto-Run Read-Only Allowlist
Commands that only inspect system state without side effects execute immediately without prompting:
- `whoami`: Zero arguments.
- `uname`: Safe flags only (`-a`, `-r`, `-s`, `-n`, `-m`, `-v`).
- `uptime`: Zero arguments or safe letter flags (`-p`, `-s`).
- `free`: Safe letter flags only (`-h`, `-m`, `-g`, `-b`, `-k`).
- `df`: Safe letter flags (`-h`, `-k`, `-m`) and paths inside home or `/tmp`.
- `lsb_release`: Safe flags only (`-a`, `-d`, `-r`, `-c`, `-s`).
- `ls`: Non-recursive listing within allowed roots (`~` or `/tmp`) with simple flags (`-l`, `-a`, `-lh`, `-1`, `-t`, `-S`, `-d`).
  - *Strictly rejected:* Recursive flags (`-R`, `-r`, `--recursive`) and long options (`--*`).
- `ps`: Fixed safe forms only (`ps`, `ps aux`, `ps -ef`, `ps ax`, `ps -u <user>`).
  - *Strictly rejected:* Process environment leakage flags (`ps e`, `ps -e e`, `ps eww`).
- `systemctl`: Strictly `systemctl status <unit>.service` (or `<unit>`).
  - *Strictly rejected:* Remote hosts (`systemctl --host`, `systemctl -H`), missing unit, or any modifying actions (`restart`, `stop`, `start`).
- *Strict Rule:* Must not contain shell metacharacters (`;`, `&&`, `||`, `|`, `>`, `<`, `$`, `` ` ``, `\n`).

### Tier 2: Needs Desktop Dialog (Zenity)
Commands requiring explicit user authorization:
- **NORMAL Risk**: Shows a native desktop authorization dialog with the command, working directory, and risk level.
- **RED Risk (Double Confirmation)**: High-risk operations (e.g. accessing `.ssh/`, `.gnupg/`, sensitive configuration, or piped commands) require **two sequential confirmation dialogs**. If either dialog is cancelled or rejected, execution is immediately stopped.

### Tier 3: Always Refused (No Dialog)
Dangerous, destructive, or obfuscated patterns are rejected immediately:
- **Piping into shell/interpreters**: `| bash`, `| sh`, `| zsh`, `| eval`, `| source`.
- **Base64 decode to shell**: `base64 -d | bash`, `base64 --decode | sh`.
- **Remote script execution**: `curl ... | sh`, `wget ... | bash`.
- **Destructive deletion**: `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf /*`, `rm -rf ~/*`.
- **Low-level disk manipulation**: `dd`, `mkfs`, `mkfs.*`.
- **Recursive permissions on system paths**: `chmod -R ... /etc`, `/boot`, `/usr`, `/var`, `/bin`, `/sbin`, `/lib`.
- **Unapproved Sudo Commands**: Any sudo command outside permitted `apt` actions.

---

## Approval Fatigue & Rate Limiting

To protect users against authorization dialog flooding and rubber-stamping fatigue:
1. **Denial Cooldown**: If a command is **DENIED** or times out, identical requests (matching the command hash) are automatically blocked for **5 minutes** without popping up further dialogs.
2. **Dialog Rate Limiting**: The server limits dialog prompts to a maximum of **5 dialogs per minute**. Excess requests are immediately denied with an informative message.
3. **Configurable via XDG**: Default thresholds can be customized via `~/.config/ubuntu-shell-mcp/config.json`:
   ```json
   {
     "denialCooldownSeconds": 300,
     "maxDialogsPerMinute": 5
   }
   ```

---

## Display Discovery & Stripped Environments

When desktop applications (like Claude Desktop) launch subprocesses, they often strip out environment variables such as `DISPLAY` and `WAYLAND_DISPLAY`:
- **Active Socket Discovery**: Automatically scans `/run/user/<uid>/` for active Wayland sockets (`wayland-0`, etc.) and `/tmp/.X11-unix/` for X11 sockets (`X0`, `X1`, etc.).
- **Strict Security Validation**:
  - Validates that socket files are owned by the current user's UID (via `stat`). Sockets owned by other users or `root` are strictly rejected.
  - Rejects symlinks pointing outside the designated directories.
- **Safe Diagnostic Logging**: Emits a single sanitised line to `stderr` upon startup (e.g. `GUI display resolved via session socket /run/user/1000/wayland-0`) without leaking environment secrets.

---

## Sudo Lockdown & Password Isolation

Root privileges are strictly guarded:
1. **Permitted Sudo Commands Only**:
   - `sudo apt update` / `sudo apt-get update`
   - `sudo apt install <packages...>` (with optional `-y` / `--yes`)
   - `sudo apt remove <packages...>` (with optional `-y` / `--yes`)
   - *All other sudo commands are permanently blocked.*
2. **Graphical Password Box (`SUDO_ASKPASS`)**:
   - Invokes `zenity --password` isolated from the process memory.
   - The password is never passed through the MCP server, never exposed to Claude, and never written to logs or audit records.

---

## Path & Working Directory Hardening

1. **Working Directory (`cwd`) Validation**:
   - Validated via canonical path resolution (`Directory.resolveSymbolicLinksSync()`).
   - Traversal attacks using `..` or symlinks pointing outside permitted directories are strictly blocked.
2. **Sanitized Environment**:
   - Executed under a locked-down PATH (`/usr/local/bin:/usr/bin:/bin`).

---

## Audit Logging

Every execution attempt, classification decision, and execution duration is recorded in `<projectRoot>/audit.log` as structured **JSON Lines (`.jsonl`)**:

```json
{"timestamp":"2026-10-03T18:40:00.000Z","commandHash":"a1b2c3d4...","command":"whoami","tier":"auto","decision":"ALLOWED","cwd":"/home/jeel","provider":"auto","latencyMs":0,"clientInfo":{"name":"Claude Desktop","version":"0.7.1"}}
{"timestamp":"2026-10-03T18:40:05.120Z","commandHash":"e5f6g7h8...","command":"ls -la /home/jeel/.ssh","tier":"red","decision":"APPROVED","cwd":"/home/jeel","provider":"zenity","latencyMs":1420,"stages":["APPROVED","APPROVED"],"clientInfo":{"name":"Claude Desktop","version":"0.7.1"}}
{"timestamp":"2026-10-03T18:40:05.150Z","type":"execution","commandHash":"e5f6g7h8...","exitCode":0,"durationMs":28}
```

- **Execution Records**: Execution results (`exitCode`, `durationMs`) are logged separately from approval decisions linked by `commandHash`.
- **Fast Approval Flag**: Approvals answered in under 800ms are flagged (`fastApproval: true`) for security auditing.
- **Privacy Guarantee**: Command outputs and passwords are **NEVER** logged.

---

## MCP Tools Reference

### 1. `run_command`
Runs a terminal command subject to the 3-tier security gate.
- **Arguments**:
  - `command` *(string, required)*: The command line to execute.
- **Returns**: Formatted text output or security error description.

### 2. `system_summary`
Returns an instant, structured overview of system health without requiring dialog approval:
- Hostname, OS version, kernel release, uptime, root filesystem disk usage, and memory statistics.

---

## Flutter Management Dashboard

The repository includes a companion Flutter desktop application (`app/`):
- **Dashboard**: Real-time status of the MCP server, active session, and system metrics.
- **Audit Viewer**: Live searchable and filterable view of `audit.log` events.
- **Settings**: GUI configuration for approval fatigue cooldowns and rate limits.

To run the dashboard:
```bash
cd app
flutter run -d linux
```

---

## Building & Testing

### Prerequisites
- Dart SDK `>= 3.5.0`
- Flutter SDK (for companion app)
- `zenity` (native Ubuntu package)

### Install Dependencies
```bash
dart pub get
```

### Run Static Analysis
```bash
# Analyze core and server packages
dart analyze packages/usm_core packages/usm_server

# Analyze companion app
flutter pub get --directory=app
flutter analyze app/
```

### Run Unit & Integration Tests
```bash
# Run 136 core and server tests
dart test packages/usm_core packages/usm_server

# Run Flutter widget tests
flutter test app/
```

### Compile Server Binary
```bash
dart compile exe packages/usm_server/bin/main.dart -o packages/usm_server/ubuntu-shell-mcp
```

### Run Stripped-Environment Regression Test
```bash
./test/integration/stripped_env.sh
```

---

## Claude Desktop Configuration

Add the server to your Claude Desktop configuration (`~/.config/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "ubuntu-shell": {
      "command": "/home/jeel/Desktop/Projects/Local_Mcp/ubuntu-shell-mcp/packages/usm_server/ubuntu-shell-mcp"
    }
  }
}
```

Restart Claude Desktop:
```bash
pkill -f claude-desktop
claude-desktop &
```

---

## Project Structure

```
├── DIAGNOSIS.md                     # Security & architectural diagnosis report
├── README.md                        # Documentation
├── claude_desktop_config.snippet.json# Sample Claude Desktop configuration
├── pubspec.yaml                     # Workspace configuration
├── pubspec.lock                     # Workspace lockfile
├── packages/
│   ├── usm_core/                    # Core library
│   │   ├── lib/
│   │   │   ├── approval_provider.dart # Zenity dialogs & display discovery
│   │   │   ├── audit_logger.dart      # JSONL audit logger & fatigue tracker
│   │   │   ├── command_validator.dart # 3-tier classification & rule engine
│   │   │   ├── executor.dart          # Process execution & timeout killer
│   │   │   └── path_resolver.dart     # Safe path resolution
│   │   └── test/                    # Core unit tests
│   └── usm_server/                  # MCP Server
│       ├── bin/main.dart            # Native executable entrypoint
│       ├── lib/
│       │   ├── mcp_server.dart      # JSON-RPC 2.0 & MCP protocol handler
│       │   └── transport.dart       # Stdio transport
│       └── test/                    # Protocol & regression tests
├── app/                             # Flutter companion management app
│   ├── lib/main.dart                # Management dashboard UI
│   └── test/widget_test.dart        # Flutter widget tests
└── test/
    └── integration/
        └── stripped_env.sh          # Claude Desktop environment regression test
```
