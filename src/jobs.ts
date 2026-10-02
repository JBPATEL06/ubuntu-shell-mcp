import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as crypto from 'node:crypto';
import { JOBS_DIR, HARDCODED_PATH, MAX_CONCURRENT_JOBS, ASKPASS_SCRIPT } from './config.js';
import { validateCwd, validateJobId, classifyCommand, promptApproval } from './security.js';
import { logAudit } from './audit.js';

export interface JobMeta {
  id: string;
  command: string;
  cwd: string;
  pid: number;
  startedAt: string;
}

export interface JobStatusResult {
  jobId: string;
  status: 'running' | 'finished' | 'died';
  exitCode: number | null;
  elapsedSeconds: number;
  command: string;
  cwd: string;
}

export interface JobOutputResult {
  jobId: string;
  content: string;
  offset: number;
  nextOffset: number;
  totalSize: number;
}

/**
 * Checks how many jobs are currently running across the system.
 */
export function getRunningJobCount(): number {
  if (!fs.existsSync(JOBS_DIR)) return 0;
  const entries = fs.readdirSync(JOBS_DIR);
  let running = 0;

  for (const id of entries) {
    if (!/^[0-9a-f]{8}$/.test(id)) continue;
    const metaPath = path.join(JOBS_DIR, id, 'meta.json');
    const exitCodePath = path.join(JOBS_DIR, id, 'exit_code');

    if (fs.existsSync(metaPath) && !fs.existsSync(exitCodePath)) {
      try {
        const meta: JobMeta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
        // Test if process is still alive
        process.kill(meta.pid, 0);
        running++;
      } catch {
        // Process is dead
      }
    }
  }

  return running;
}

/**
 * Starts a background job after validation and approval.
 */
export async function startJob(rawCommand: string, requestedCwd?: string): Promise<{ jobId: string; message: string }> {
  const cwd = validateCwd(requestedCwd);
  const classification = classifyCommand(rawCommand, cwd);

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
    throw new Error(classification.reason);
  }

  // Check concurrency limit before prompting
  const runningCount = getRunningJobCount();
  if (runningCount >= MAX_CONCURRENT_JOBS) {
    throw new Error(`Concurrency limit reached: Maximum ${MAX_CONCURRENT_JOBS} background jobs can run concurrently.`);
  }

  // Approval gate: same as run_command
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
      throw new Error(`Job execution denied: ${approval.reason}`);
    }
    logAudit({
      timestamp: new Date().toISOString(),
      command: classification.exactCommand,
      tier: 'prompt',
      decision: 'ALLOWED',
      cwd,
      isSudo: classification.isSudo,
      reason: 'Approved by user via dialog',
    });
  } else {
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

  const jobId = crypto.randomBytes(4).toString('hex');
  const jobDir = path.join(JOBS_DIR, jobId);
  fs.mkdirSync(jobDir, { recursive: true });

  const outputLogPath = path.join(jobDir, 'output.log');
  const exitCodePath = path.join(jobDir, 'exit_code');
  const metaPath = path.join(jobDir, 'meta.json');

  const outFd = fs.openSync(outputLogPath, 'a');

  // Bash execution wrapper that captures exit code
  const bashScript = `shopt -s expand_aliases; alias sudo='sudo -A'; (${classification.exactCommand}); __ec=$?; echo $__ec > "${exitCodePath}"`;

  const child = spawn('/bin/bash', ['-c', bashScript], {
    cwd,
    detached: true,
    stdio: ['ignore', outFd, outFd],
    env: {
      PATH: HARDCODED_PATH,
      SUDO_ASKPASS: ASKPASS_SCRIPT,
      DISPLAY: process.env.DISPLAY,
      WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY,
      XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
      XAUTHORITY: process.env.XAUTHORITY,
    },
  });

  const pid = child.pid!;
  child.unref();
  fs.closeSync(outFd);

  const meta: JobMeta = {
    id: jobId,
    command: classification.exactCommand,
    cwd,
    pid,
    startedAt: new Date().toISOString(),
  };

  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2), 'utf8');

  return {
    jobId,
    message: `Job started successfully with ID: ${jobId} (PID: ${pid})`,
  };
}

/**
 * Gets the live status of a job.
 */
export async function getJobStatus(rawJobId: string): Promise<JobStatusResult> {
  const jobId = validateJobId(rawJobId);
  const jobDir = path.join(JOBS_DIR, jobId);

  if (!fs.existsSync(jobDir)) {
    throw new Error(`Job not found: '${jobId}'`);
  }

  const metaPath = path.join(jobDir, 'meta.json');
  const exitCodePath = path.join(jobDir, 'exit_code');

  if (!fs.existsSync(metaPath)) {
    throw new Error(`Job metadata missing for: '${jobId}'`);
  }

  const meta: JobMeta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - new Date(meta.startedAt).getTime()) / 1000));

  if (fs.existsSync(exitCodePath)) {
    const rawCode = fs.readFileSync(exitCodePath, 'utf8').trim();
    const exitCode = parseInt(rawCode, 10);
    return {
      jobId,
      status: 'finished',
      exitCode: Number.isNaN(exitCode) ? 0 : exitCode,
      elapsedSeconds,
      command: meta.command,
      cwd: meta.cwd,
    };
  }

  // Check if process is still running via signal 0
  let isAlive = false;
  try {
    process.kill(meta.pid, 0);
    isAlive = true;
  } catch {
    isAlive = false;
  }

  if (isAlive) {
    return {
      jobId,
      status: 'running',
      exitCode: null,
      elapsedSeconds,
      command: meta.command,
      cwd: meta.cwd,
    };
  } else {
    // Process terminated but no exit_code file was created
    return {
      jobId,
      status: 'died',
      exitCode: null,
      elapsedSeconds,
      command: meta.command,
      cwd: meta.cwd,
    };
  }
}

/**
 * Reads output chunks from a job's output.log with paging.
 */
export async function getJobOutput(rawJobId: string, requestedOffset: number = 0): Promise<JobOutputResult> {
  const jobId = validateJobId(rawJobId);
  const jobDir = path.join(JOBS_DIR, jobId);

  if (!fs.existsSync(jobDir)) {
    throw new Error(`Job not found: '${jobId}'`);
  }

  const logPath = path.join(jobDir, 'output.log');
  if (!fs.existsSync(logPath)) {
    return {
      jobId,
      content: '',
      offset: 0,
      nextOffset: 0,
      totalSize: 0,
    };
  }

  const stat = fs.statSync(logPath);
  const totalSize = stat.size;
  const offset = Math.max(0, requestedOffset);

  if (offset >= totalSize) {
    return {
      jobId,
      content: '',
      offset,
      nextOffset: totalSize,
      totalSize,
    };
  }

  const chunkSize = Math.min(20000, totalSize - offset);
  const buffer = Buffer.alloc(chunkSize);

  const fd = fs.openSync(logPath, 'r');
  try {
    fs.readSync(fd, buffer, 0, chunkSize, offset);
  } finally {
    fs.closeSync(fd);
  }

  return {
    jobId,
    content: buffer.toString('utf8'),
    offset,
    nextOffset: offset + chunkSize,
    totalSize,
  };
}

/**
 * Cancels a running job process group.
 * Sends SIGTERM to -pid, then SIGKILL after 5 seconds if still alive.
 */
export async function cancelJob(rawJobId: string): Promise<{ success: boolean; message: string }> {
  const jobId = validateJobId(rawJobId);
  const jobDir = path.join(JOBS_DIR, jobId);

  if (!fs.existsSync(jobDir)) {
    throw new Error(`Job not found: '${jobId}'`);
  }

  const metaPath = path.join(jobDir, 'meta.json');
  const exitCodePath = path.join(jobDir, 'exit_code');

  if (!fs.existsSync(metaPath)) {
    throw new Error(`Job metadata missing for: '${jobId}'`);
  }

  const meta: JobMeta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));

  // If already finished
  if (fs.existsSync(exitCodePath)) {
    return {
      success: true,
      message: `Job '${jobId}' has already finished with exit code ${fs.readFileSync(exitCodePath, 'utf8').trim()}`,
    };
  }

  let killed = false;
  try {
    // Send SIGTERM to process group (-pid)
    process.kill(-meta.pid, 'SIGTERM');
    killed = true;
  } catch (err: any) {
    if (err.code === 'ESRCH') {
      return { success: true, message: `Job '${jobId}' (PID ${meta.pid}) was already stopped.` };
    }
    // If process group kill failed, try killing individual pid
    try {
      process.kill(meta.pid, 'SIGTERM');
      killed = true;
    } catch {
      // already dead
    }
  }

  // Schedule SIGKILL after 5 seconds if still running
  setTimeout(() => {
    try {
      process.kill(meta.pid, 0);
      // Still alive, escalate to SIGKILL
      try {
        process.kill(-meta.pid, 'SIGKILL');
      } catch {
        process.kill(meta.pid, 'SIGKILL');
      }
    } catch {
      // Process already terminated
    }
  }, 5000).unref();

  // Record cancellation in exit_code file if not already present
  if (!fs.existsSync(exitCodePath)) {
    try {
      fs.writeFileSync(exitCodePath, '143\n', 'utf8'); // 128 + 15 (SIGTERM)
    } catch {
      // ignore
    }
  }

  return {
    success: true,
    message: `Job '${jobId}' received cancellation signal (SIGTERM to process group -${meta.pid}).`,
  };
}
