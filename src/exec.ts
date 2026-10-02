import { execFile } from 'node:child_process';
import { HARDCODED_PATH, ASKPASS_SCRIPT } from './config.js';
import { validateCwd, classifyCommand, promptApproval, Tier } from './security.js';
import { logAudit } from './audit.js';

export interface ExecOptions {
  timeoutMs?: number;
  maxBuffer?: number;
  maxOutputChars?: number;
  cwd?: string;
}

export interface ExecResult {
  output: string;
  cwd: string;
  tier: Tier;
  isSudo: boolean;
}

/**
 * Executes a command following the hardened three-tier security model.
 */
export async function executeCommand(
  rawCommand: string,
  options: ExecOptions = {}
): Promise<ExecResult> {
  const cwd = validateCwd(options.cwd);
  const timeoutMs = options.timeoutMs ?? 15000;
  const maxBuffer = options.maxBuffer ?? 1024 * 1024;
  const maxOutputChars = options.maxOutputChars ?? 20000;

  const classification = classifyCommand(rawCommand, cwd);

  // 1. Tier 3: Always refused, no dialog
  if (classification.tier === 'refused') {
    logAudit({
      timestamp: new Date().toISOString(),
      command: rawCommand,
      tier: 'refused',
      decision: 'BLOCKED',
      cwd,
      isSudo: classification.isSudo,
      reason: classification.reason,
    });
    return {
      output: `Blocked: ${classification.reason}`,
      cwd,
      tier: 'refused',
      isSudo: classification.isSudo,
    };
  }

  // 2. Tier 2: Needs dialog
  if (classification.tier === 'prompt') {
    const approval = await promptApproval(classification.exactCommand, cwd, classification.isSudo);
    if (!approval.approved) {
      logAudit({
        timestamp: new Date().toISOString(),
        command: classification.exactCommand,
        tier: 'prompt',
        decision: 'DENIED_BY_USER',
        cwd,
        isSudo: classification.isSudo,
        reason: approval.reason,
      });
      return {
        output: `Permission Denied: ${approval.reason}. Command execution aborted.`,
        cwd,
        tier: 'prompt',
        isSudo: classification.isSudo,
      };
    }
    logAudit({
      timestamp: new Date().toISOString(),
      command: classification.exactCommand,
      tier: 'prompt',
      decision: 'ALLOWED',
      cwd,
      isSudo: classification.isSudo,
      reason: 'Approved by user via authorization dialog',
    });
  } else {
    // 3. Tier 1: Auto-run read-only allowlist
    logAudit({
      timestamp: new Date().toISOString(),
      command: classification.exactCommand,
      tier: 'auto',
      decision: 'ALLOWED',
      cwd,
      isSudo: false,
      reason: classification.reason,
    });
  }

  // Execute command via bash with hardcoded PATH and sudo askpass
  const actualTimeoutMs = classification.isSudo ? Math.max(timeoutMs, 60000) : timeoutMs;
  const bashScript = `shopt -s expand_aliases; alias sudo='sudo -A'; ${classification.exactCommand}`;

  return new Promise((resolve) => {
    execFile(
      '/bin/bash',
      ['-c', bashScript],
      {
        cwd,
        timeout: actualTimeoutMs,
        maxBuffer,
        env: {
          PATH: HARDCODED_PATH,
          SUDO_ASKPASS: ASKPASS_SCRIPT,
          DISPLAY: process.env.DISPLAY,
          WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY,
          XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
          XAUTHORITY: process.env.XAUTHORITY,
        },
      },
      (error, stdout, stderr) => {
        let output = '';

        if (error) {
          if (error.killed || error.signal === 'SIGTERM') {
            output = `Error: Command timed out after ${actualTimeoutMs / 1000} seconds.`;
          } else {
            const details = (stdout ? stdout + '\n' : '') + (stderr || error.message);
            output = details.trim() || `Command failed with code ${error.code ?? 1}`;
          }
        } else {
          output = stdout;
          if (stderr) {
            output += (output ? '\n' : '') + stderr;
          }
        }

        if (output.length > maxOutputChars) {
          output = output.slice(0, maxOutputChars) + `\n... [output truncated to ${maxOutputChars} characters]`;
        }

        resolve({
          output: output || '(Command completed with no output)',
          cwd,
          tier: classification.tier,
          isSudo: classification.isSudo,
        });
      }
    );
  });
}

/**
 * Returns a structured system overview.
 */
export async function getSystemSummary(): Promise<string> {
  const execSimple = (cmd: string): Promise<string> =>
    new Promise((resolve) => {
      execFile('/bin/bash', ['-c', cmd], { env: { PATH: HARDCODED_PATH } }, (err, stdout) => {
        resolve((stdout || '').trim());
      });
    });

  const [hostname, osVersion, uptime, disk, memory] = await Promise.all([
    execSimple('uname -n'),
    execSimple('lsb_release -d 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2'),
    execSimple('uptime'),
    execSimple('df -h /'),
    execSimple('free -h'),
  ]);

  return [
    '=== SYSTEM SUMMARY ===',
    `Hostname: ${hostname}`,
    `OS Version: ${osVersion.replace(/"/g, '')}`,
    `Uptime: ${uptime}`,
    '',
    '--- Disk Usage (/) ---',
    disk,
    '',
    '--- Memory Usage ---',
    memory,
  ].join('\n');
}
