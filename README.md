# ubuntu-shell MCP Server

A hardened, local **Model Context Protocol (MCP)** server built in TypeScript for **Claude Desktop** on **Ubuntu 24.04 / Linux**.

This server provides Claude with controlled, safe access to the Ubuntu terminal environment over standard input/output (`stdio`). It enforces a strict **three-tier security gate**, desktop graphical authorization (`zenity`), safe `sudo` isolation via `SUDO_ASKPASS`, filesystem path hardening, structured JSONL audit logging, and a robust **background job engine** for long-running commands.

---

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Three-Tier Security Model](#three-tier-security-model)
- [Sudo Lockdown & Password Isolation](#sudo-lockdown--password-isolation)
- [Path & Working Directory Hardening](#path--working-directory-hardening)
- [Background Jobs Engine](#background-jobs-engine)
- [MCP Tools Reference](#mcp-tools-reference)
- [Audit Logging](#audit-logging)
- [Claude Desktop Setup](#claude-desktop-setup)
- [Building & Testing](#building--testing)
- [Known Limitations & Design Trade-offs](#known-limitations--design-trade-offs)
- [Project Structure](#project-structure)

---

## Overview & Architecture

- **Pure Stdio Transport**: Operates exclusively over `stdio` without opening any network listeners, ports, HTTP endpoints, or tunnels.
- **Fail-Closed Design**: Any authorization dialog failure, missing desktop display, timeout, or runtime error results in an immediate **DENY**. Commands never run on error.
- **Exact String Binding**: The authorization dialog displays the exact command string that will execute. Approval is strictly bound to that string.
- **Multilingual Support**: Supports English and Gujarati (ગુજરાતી) explanations and bilingual desktop prompts.

---

## Three-Tier Security Model

Every command sent to `run_command` or `start_job` is inspected and categorized into one of three security tiers before anything executes:

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
- `uname`: Simple letter flags only (`-a`, `-r`, `-s`, `-n`, `-m`, `-v`).
- `uptime`: Zero arguments or safe letter flags (`-p`, `-s`).
- `free`: Simple letter flags only (`-h`, `-m`, `-g`, `-b`, `-k`).
- `df`: Safe letter flags (`-h`, `-k`, `-m`) and paths inside home or `/tmp`.
- `lsb_release`: Simple letter flags only (`-a`, `-d`, `-r`, `-c`, `-s`).
- `ls`: Non-recursive listing within allowed roots (`~` or `/tmp`) with simple flags (`-l`, `-a`, `-lh`, `-1`, `-t`, `-S`, `-d`).
  - *Strictly rejected:* Recursive flags (`-R`, `-r`, `--recursive`) and long options (`--*`).
- `ps`: Fixed safe forms only (`ps`, `ps aux`, `ps -ef`, `ps ax`, `ps -u <user>`).
  - *Strictly rejected:* Process environment leakage flags (`ps e`, `ps -e e`, `ps eww`).
- `systemctl`: Strictly `systemctl status <unit>.service` (or `<unit>`).
  - *Strictly rejected:* Remote hosts (`systemctl --host`, `systemctl -H`), missing unit, or any modifying actions (`restart`, `stop`, `start`).
- *Strict Rule:* Must not contain shell metacharacters (`;`, `&&`, `||`, `|`, `>`, `<`, `$`, `` ` ``, `\n`).

### Tier 2: Needs Desktop Dialog (Zenity)
Commands not in Tier 1 and not in Tier 3 trigger a native Ubuntu dialog on your desktop screen:
- Shows the **exact command string**, the **working directory (`cwd`)**, and whether **sudo is used**.
- **`[Allow]`** and **`[Deny]`** buttons with a 45-second timeout (default-cancel).
- Any failure, timeout, or cancellation immediately aborts execution.

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

## Sudo Lockdown & Password Isolation

Root privileges are strictly isolated to prevent prompt injection attacks or accidental system breakage:

1. **Permitted Sudo Commands Only**:
   - `sudo apt update` / `sudo apt-get update`
   - `sudo apt install <packages...>` (with optional `-y` / `--yes`)
   - `sudo apt remove <packages...>` (with optional `-y` / `--yes`)
   - *All other sudo commands are permanently blocked.*
2. **Always Prompts**: Sudo commands always trigger the Tier 2 confirmation dialog.
3. **Graphical Password Box (`SUDO_ASKPASS`)**:
   - Commands execute using `dist/askpass.sh` calling `zenity --password`.
   - You enter your password in an OS-level desktop dialog.
   - **Password Isolation**: The password never enters Node.js, is never returned to Claude, and is never written to logs or audit records.
4. **Extended Timeout**: Sudo operations automatically receive an extended **120-second timeout** to accommodate large package downloads.

---

## Path & Working Directory Hardening

1. **Working Directory (`cwd`) Validation**:
   - Defaults to your home directory (`/home/jeel`).
   - Validated via `fs.realpathSync`.
   - **Traversal Protection**: Escaping home via `..` or symlinks pointing outside `/home/jeel` is strictly blocked.
2. **Hardcoded PATH**:
   - Commands execute with a fixed, safe environment: `PATH=/usr/local/bin:/usr/bin:/bin`.
   - Eliminates vulnerabilities where untrusted binaries could shadow core utilities.

---

## Background Jobs Engine

Solves the limitations of short timeouts and blocking calls by allowing long-running tasks (compilations, long scripts, server tasks) to run safely in the background:

- **Detached Process Groups**: Spawns `/bin/bash` with `detached: true`. The process group ID equals `child.pid`, allowing clean termination of the parent and all child sub-processes.
- **Persistent State**:
  - Saved under `<projectRoot>/jobs/<job_id>/`:
    - `meta.json`: Job ID, command, cwd, PID, started timestamp.
    - `output.log`: Standard output and standard error stream.
    - `exit_code`: Exit code captured automatically upon termination.
  - **Survives Server Restarts**: Because metadata and processes are detached on the OS level, restarting Claude Desktop does not lose track of active jobs.
- **Concurrency Limit**: Maximum of **5 concurrent running jobs** allowed at any given time.
- **Strict Job ID Validation**: `job_id` must match `/^[0-9a-f]{8}$/` (8 hex characters), preventing path traversal attacks.

---

## MCP Tools Reference

The server exposes 6 tools over `stdio`:

### 1. `run_command`
Runs a short-lived terminal command subject to the 3-tier security gate.
- **Parameters**:
  - `command` *(string, required)*: The command line to execute.
  - `cwd` *(string, optional)*: Working directory (must be inside home).
- **Timeouts**: 15 seconds (extended to 60s/120s for permitted sudo). Output capped at 20,000 characters.

### 2. `start_job`
Starts a long-running background command in its own detached process group.
- **Parameters**:
  - `command` *(string, required)*: The command line to execute.
  - `cwd` *(string, optional)*: Working directory (must be inside home).
- **Behavior**: Goes through the same 3-tier validation and approval gate. Returns the `job_id` in < 1 second.

### 3. `job_status`
Checks the live status of a background job.
- **Parameters**:
  - `job_id` *(string, required)*: 8-character hex job ID.
- **Returns**: Status (`running`, `finished`, or `died`), exit code, elapsed runtime in seconds, command, and cwd.

### 4. `job_output`
Reads output logs from a background job with byte-offset pagination.
- **Parameters**:
  - `job_id` *(string, required)*: 8-character hex job ID.
  - `offset` *(number, optional)*: Starting byte offset (defaults to 0).
- **Returns**: Up to 20,000 bytes per chunk, current offset, `nextOffset`, and total log size in bytes.

### 5. `cancel_job`
Terminates a running background job.
- **Parameters**:
  - `job_id` *(string, required)*: 8-character hex job ID.
- **Behavior**: Sends `SIGTERM` to the entire process group (`-pid`). If still running after 5 seconds, escalates to `SIGKILL`.

### 6. `system_summary`
Returns a fast, structured system overview.
- **Returns**: Hostname, OS version, uptime, root partition disk usage (`df -h /`), and memory usage (`free -h`).

---

## Audit Logging

Every execution attempt and authorization decision is recorded in a single file: `<projectRoot>/audit.log`.

Entries are stored as **JSON Lines (`.jsonl`)**—one JSON object per line:

```json
{"timestamp":"2026-10-02T12:13:10.000Z","command":"uptime","tier":"auto","decision":"ALLOWED","cwd":"/home/jeel","isSudo":false,"reason":"Auto-run: uptime"}
{"timestamp":"2026-10-02T12:14:05.120Z","command":"sudo apt update","tier":"prompt","decision":"ALLOWED","cwd":"/home/jeel","isSudo":true,"reason":"Approved by user via authorization dialog"}
{"timestamp":"2026-10-02T12:15:22.450Z","command":"echo a | base64 -d | bash","tier":"refused","decision":"BLOCKED","cwd":"/home/jeel","isSudo":false,"reason":"Refused: Base64 decode piped to shell execution is prohibited."}
```

To monitor the audit log in real time:
```bash
tail -f /home/jeel/Desktop/demofolder/audit.log
```

---

## Claude Desktop Setup

### 1. Configure Claude Desktop
Add the server entry to `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ubuntu-shell": {
      "command": "/home/jeel/tools/node/bin/node",
      "args": [
        "/home/jeel/Desktop/demofolder/dist/server.js"
      ]
    }
  }
}
```

### 2. Restart Claude Desktop
On Ubuntu, closing the window with the **`X`** button does not kill Claude Desktop—it keeps running in the background/system tray. Fully restart Claude by running:

```bash
pkill -f claude-desktop
claude-desktop &
```

---

## Building & Testing

### Build the Server
Compiles TypeScript, packages the askpass script, and ensures permissions:
```bash
cd /home/jeel/Desktop/demofolder
npm run build
```

### Run Vitest Tests
Runs the test suite verifying all 22 security gates, symlink protections, and background job lifecycles:
```bash
npm test
```

**Test Coverage Summary:**
- Cwd validation (inside home, `..` traversal rejected, symlink escape rejected).
- Three-tier classification (auto-run allowlist, rejected options, base64-to-shell refused, pipe-to-shell refused, destructive rm refused, dd/mkfs refused, chmod -R refused).
- Sudo lockdown (permitted apt actions vs. refused arbitrary sudo).
- Fail-closed approval gate (missing display denies, user deny blocks execution).
- Audit logging (JSON-escaped single-line records, no passwords).
- Background job tools (validates `job_id`, sleeps 2s and verifies running/finished, cancels process groups, output paging, denied dialog starts no job).

---

## Known Limitations & Design Trade-offs

1. **No Interactive Terminal (No TTY)**:
   - Does not support interactive curses-based tools (`vim`, `nano`, `htop`, `less`).
   - Commands expecting interactive console input will hang unless non-interactive flags are supplied (e.g. `apt install -y`).
2. **Desktop Display Requirement**:
   - The interactive approval popup and sudo password dialog require an active GUI display (`DISPLAY` or `WAYLAND_DISPLAY`).
   - In headless or SSH environments, the fail-closed security model automatically denies commands requiring approval.
3. **Subshell Isolation**:
   - Each `run_command` executes in an independent subshell. Changes to environment variables (`export FOO=1`) or directory changes (`cd /path`) do not persist to the next tool call. Use the `cwd` parameter to specify directories across calls.
4. **Output Truncation**:
   - `run_command` output is capped at 20,000 characters to prevent overflowing LLM context windows. Use `start_job` and `job_output` for reading large logs in paged chunks.

---

## Project Structure

```
├── audit.log                   # Single JSONL audit log of all decisions
├── dist/                       # Compiled JavaScript entrypoints & askpass helper
│   ├── askpass.sh
│   ├── server.js
│   └── ...
├── jobs/                       # Detached background job state
│   └── <job_id>/
│       ├── meta.json           # Job metadata (PID, command, cwd, timestamp)
│       ├── output.log          # Combined stdout/stderr output stream
│       └── exit_code           # Exit code written on completion
├── package.json
├── src/
│   ├── askpass.sh              # Graphical sudo password prompt helper
│   ├── audit.ts                # JSONL audit logger
│   ├── config.ts               # Project paths, hardcoded PATH, constants
│   ├── exec.test.ts            # 22 Vitest integration & security tests
│   ├── exec.ts                 # Hardened execution engine
│   ├── jobs.ts                 # Background job lifecycle manager
│   ├── mcp-server.ts           # MCP tool definitions
│   ├── security.ts             # 3-tier classification & Zenity approval gate
│   └── server.ts               # Pure stdio transport entrypoint
└── tsconfig.json
```
