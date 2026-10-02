import { execFile } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { HARDCODED_PATH } from './config.js';

export type Tier = 'auto' | 'prompt' | 'refused';

export interface CommandClassification {
  tier: Tier;
  reason: string;
  isSudo: boolean;
  exactCommand: string;
  cwd: string;
}

/**
 * Validates that cwd exists and resolves within the user's home directory.
 * Prevents traversal via '..' or symlinks pointing outside home.
 */
export function validateCwd(requestedCwd?: string): string {
  const homeReal = fs.realpathSync(os.homedir());
  if (!requestedCwd || requestedCwd.trim() === '') {
    return homeReal;
  }
  const resolved = path.isAbsolute(requestedCwd)
    ? path.normalize(requestedCwd)
    : path.resolve(homeReal, requestedCwd);

  if (!fs.existsSync(resolved)) {
    throw new Error(`Invalid cwd: Directory does not exist: '${requestedCwd}'`);
  }

  const realCwd = fs.realpathSync(resolved);
  if (realCwd !== homeReal && !realCwd.startsWith(homeReal + path.sep)) {
    throw new Error(`Invalid cwd: Path '${requestedCwd}' escapes home directory (resolved: '${realCwd}')`);
  }

  return realCwd;
}

/**
 * Validates that a job_id is strictly 8 hexadecimal characters.
 */
export function validateJobId(jobId: string): string {
  if (!jobId || typeof jobId !== 'string' || !/^[0-9a-f]{8}$/.test(jobId.trim())) {
    throw new Error(`Invalid job_id: '${jobId}'. Must be exactly 8 hexadecimal characters.`);
  }
  return jobId.trim();
}

/**
 * Escape string for Pango markup in Zenity dialogs.
 */
function escapePango(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * Classifies a command into one of three tiers:
 * - refused: Prohibited commands (pipe to shell, base64 to shell, dd, mkfs, destructive rm, chmod -R system, unapproved sudo)
 * - auto: Safe read-only commands with strict argument parsing
 * - prompt: Everything else requiring explicit desktop approval
 */
export function classifyCommand(rawCommand: string, validatedCwd: string): CommandClassification {
  const trimmed = (rawCommand || '').trim();
  if (!trimmed) {
    return {
      tier: 'refused',
      reason: 'Empty command string',
      isSudo: false,
      exactCommand: '',
      cwd: validatedCwd,
    };
  }

  const isSudo = /\b(sudo|pkexec|su|doas)\b/.test(trimmed);

  // --- TIER 3: ALWAYS REFUSED (No dialog) ---

  // 1. Base64-decode-to-shell
  if (/base64\s+(-d|--decode).*\|\s*(bash|sh|eval|source)/.test(trimmed) ||
      /\|\s*base64\s+(-d|--decode).*\|\s*(bash|sh)/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Base64 decode piped to shell execution is prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 2. Pipe into bash, sh, zsh, eval, source
  if (/\|\s*(bash|sh|zsh|eval|source)\b/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Piping output directly into shell, eval, or source is prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 3. Curl or wget piped to a shell
  if (/(curl|wget)\b.*\|\s*(bash|sh|zsh|eval|source)/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Piping downloaded scripts from curl or wget into a shell is prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 4. rm -rf on / or ~ (or root / home variations)
  if (/\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+.*(\/|~|\$HOME|\/\*|~\/\*)(\s|$)/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Recursive deletion targeting root (/) or home (~) is prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 5. Low-level disk formatting/partitioning: dd, mkfs
  if (/\bdd\b|\bmkfs(\.[a-z0-9]+)?\b/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Low-level disk manipulation tools (dd, mkfs) are prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 6. chmod -R on system paths
  if (/\bchmod\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+.*(\/|\/etc|\/boot|\/usr|\/var|\/bin|\/sbin|\/lib|\/lib64)(\s|\/|\*|$)/.test(trimmed)) {
    return {
      tier: 'refused',
      reason: 'Refused: Recursive chmod on system paths is prohibited.',
      isSudo,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // 7. Sudo lockdown:
  // Restrict sudo strictly to:
  // sudo apt update
  // sudo apt install <name...> (optional -y)
  // sudo apt remove <name...> (optional -y)
  // sudo apt-get update / install / remove
  if (isSudo) {
    const isAllowedApt = /^sudo\s+(apt|apt-get)\s+(update|install(\s+(-y|--yes))?(\s+[a-zA-Z0-9_\-\.\+]+)+|remove(\s+(-y|--yes))?(\s+[a-zA-Z0-9_\-\.\+]+)+)$/.test(trimmed);
    if (!isAllowedApt) {
      return {
        tier: 'refused',
        reason: "Refused: Sudo is strictly locked down to 'apt update', 'apt install <package>', and 'apt remove <package>'. Arbitrary sudo commands are not permitted.",
        isSudo: true,
        exactCommand: trimmed,
        cwd: validatedCwd,
      };
    }
    // Allowed apt action with sudo: always Tier 2 (Needs dialog)
    return {
      tier: 'prompt',
      reason: 'Sudo package management requires explicit desktop authorization.',
      isSudo: true,
      exactCommand: trimmed,
      cwd: validatedCwd,
    };
  }

  // --- TIER 1: AUTO-RUN READ-ONLY ALLOWLIST ---
  // Must NOT contain shell chaining (; && || |), redirects (> <), or substitutions ($ `)
  const hasMetachars = /[;&|><$`\n\r]/.test(trimmed);
  if (!hasMetachars) {
    const tokens = trimmed.split(/\s+/).filter(Boolean);
    const [cmd, ...args] = tokens;

    // Check 1: whoami
    if (cmd === 'whoami' && args.length === 0) {
      return { tier: 'auto', reason: 'Auto-run: whoami without arguments', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
    }

    // Check 2: uname
    if (cmd === 'uname' && args.every((a) => /^-[arnsmv]+$/.test(a))) {
      return { tier: 'auto', reason: 'Auto-run: uname with safe flags', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
    }

    // Check 3: uptime
    if (cmd === 'uptime' && (args.length === 0 || args.every((a) => /^-[ps]+$/.test(a)))) {
      return { tier: 'auto', reason: 'Auto-run: uptime', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
    }

    // Check 4: free
    if (cmd === 'free' && (args.length === 0 || args.every((a) => /^-[hmgbk]+$/.test(a)))) {
      return { tier: 'auto', reason: 'Auto-run: free with safe flags', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
    }

    // Check 5: df
    if (cmd === 'df') {
      const flagsValid = args.every((a) => a.startsWith('-') ? /^-[hkm]+$/.test(a) : true);
      const pathsValid = args
        .filter((a) => !a.startsWith('-'))
        .every((p) => {
          if (p.includes('..')) return false;
          try {
            const resolved = path.resolve(validatedCwd, p);
            return resolved === os.homedir() || resolved.startsWith(os.homedir() + path.sep) || resolved === '/tmp' || resolved.startsWith('/tmp/');
          } catch {
            return false;
          }
        });
      if (flagsValid && pathsValid) {
        return { tier: 'auto', reason: 'Auto-run: df with safe flags and paths', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
      }
    }

    // Check 6: lsb_release
    if (cmd === 'lsb_release' && args.every((a) => /^-[adrcsu]+$/.test(a))) {
      return { tier: 'auto', reason: 'Auto-run: lsb_release with safe flags', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
    }

    // Check 7: ls
    if (cmd === 'ls') {
      // Must not contain recursive options (-R, -r, --recursive) or long options (--)
      const hasRecursive = args.some((a) => /[rR]/.test(a) || a.startsWith('--'));
      const flagsValid = args.every((a) => a.startsWith('-') ? /^-[la1tSdfFh]+$/.test(a) : true);
      const pathsValid = args
        .filter((a) => !a.startsWith('-'))
        .every((p) => {
          if (p.includes('..')) return false;
          try {
            const resolved = path.resolve(validatedCwd, p);
            return resolved === os.homedir() || resolved.startsWith(os.homedir() + path.sep) || resolved === '/tmp' || resolved.startsWith('/tmp/');
          } catch {
            return false;
          }
        });
      if (!hasRecursive && flagsValid && pathsValid) {
        return { tier: 'auto', reason: 'Auto-run: ls within allowed roots with safe flags', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
      }
    }

    // Check 8: ps
    // ps only in fixed safe forms: 'ps', 'ps aux', 'ps -ef', 'ps ax', 'ps -u <user>'
    // Explicitly reject: ps e, ps -e e, ps eww, etc.
    if (cmd === 'ps') {
      const fixedForms = ['aux', '-ef', 'ax', '-A', ''];
      const argStr = args.join(' ');
      const isFixed = fixedForms.includes(argStr) || /^-(u|U)\s+[a-zA-Z0-9_\-]+$/.test(argStr);
      // Strictly ensure 'e' environment leakage flag is NOT present
      const hasEnvLeakage = args.some((a) => /\b(e|ew|eww)\b/.test(a) || a === '-e' && args.includes('e') || a.includes('e') && !['-ef', '-A'].includes(a));
      if (isFixed && !hasEnvLeakage) {
        return { tier: 'auto', reason: 'Auto-run: ps in safe fixed form', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
      }
    }

    // Check 9: systemctl status <unit>.service only
    // Strictly reject systemctl --host, systemctl -H, or any other verb
    if (cmd === 'systemctl') {
      if (args.length === 2 && args[0] === 'status') {
        const unit = args[1];
        // Must match unit name pattern, e.g. ssh, ssh.service, nginx.service
        // Must NOT start with a dash (-)
        if (/^[a-zA-Z0-9_\-\.:@]+(\.service)?$/.test(unit) && !unit.startsWith('-')) {
          return { tier: 'auto', reason: 'Auto-run: systemctl status <unit>.service', isSudo: false, exactCommand: trimmed, cwd: validatedCwd };
        }
      }
    }
  }

  // --- TIER 2: EVERYTHING ELSE REQUIRES THE DIALOG ---
  return {
    tier: 'prompt',
    reason: 'Standard command execution requires explicit desktop authorization.',
    isSudo: false,
    exactCommand: trimmed,
    cwd: validatedCwd,
  };
}

/**
 * Prompts user on Ubuntu with native Zenity dialog showing the exact command string and cwd.
 * Fail closed: any dialog failure, missing display, timeout, or error = DENY.
 */
export async function promptApproval(
  exactCommand: string,
  cwd: string,
  isSudo: boolean
): Promise<{ approved: boolean; reason: string }> {
  // Fail closed: must have graphical display
  const display = process.env.DISPLAY || process.env.WAYLAND_DISPLAY;
  if (!display) {
    return {
      approved: false,
      reason: 'Denied: No graphical display detected (DISPLAY/WAYLAND_DISPLAY unset). Fail closed.',
    };
  }

  return new Promise((resolve) => {
    const sudoNotice = isSudo
      ? "<span foreground='#d9534f' size='large'><b>⚠️ SUDO: Requires Administrator Privileges (Root)</b></span>\n"
      : '';

    const dialogText = [
      `<b>Approval requested for execution on Ubuntu:</b>\n`,
      sudoNotice,
      `<b>Exact Command:</b>\n<tt>${escapePango(exactCommand)}</tt>\n`,
      `<b>Working Directory (cwd):</b>\n<tt>${escapePango(cwd)}</tt>\n`,
      `<b>Sudo Used:</b> ${isSudo ? 'YES' : 'NO'}\n`,
      `Do you allow this exact command to execute?`,
    ]
      .filter(Boolean)
      .join('\n');

    const zenityArgs = [
      '--question',
      '--title=ubuntu-shell: Command Authorization',
      `--text=${dialogText}`,
      '--ok-label=Allow',
      '--cancel-label=Deny',
      '--default-cancel',
      '--width=540',
      '--timeout=45',
    ];

    const child = execFile(
      'zenity',
      zenityArgs,
      {
        env: {
          PATH: HARDCODED_PATH,
          DISPLAY: process.env.DISPLAY,
          WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY,
          XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
          XAUTHORITY: process.env.XAUTHORITY,
        },
        timeout: 50000,
      },
      (error) => {
        if (error) {
          if (error.code === 1) {
            resolve({ approved: false, reason: 'Denied by user' });
          } else if (error.code === 5 || error.killed) {
            resolve({ approved: false, reason: 'Denied: Dialog timed out without approval (45s)' });
          } else {
            resolve({ approved: false, reason: `Denied: Dialog failed (${error.message})` });
          }
          return;
        }
        resolve({ approved: true, reason: 'Approved by user' });
      }
    );

    child.on('error', (err) => {
      resolve({ approved: false, reason: `Denied: Failed to launch dialog (${err.message})` });
    });
  });
}
