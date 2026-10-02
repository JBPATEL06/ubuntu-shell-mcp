import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { executeCommand, getSystemSummary } from "./exec.js";
import { startJob, getJobStatus, getJobOutput, cancelJob } from "./jobs.js";
import { DEFAULT_CWD } from "./config.js";

export function createServer(): McpServer {
  const server = new McpServer({
    name: "ubuntu-shell",
    version: "3.0.0",
  });

  // Tool 1: run_command
  server.tool(
    "run_command",
    `Executes a short command on Ubuntu with a strict three-tier security model:
1. Auto-run: Safe read-only commands (ls, df, free, uptime, whoami, uname, safe ps, systemctl status <unit>.service).
2. Needs dialog: Other commands require desktop authorization showing the exact command, cwd, and sudo flag.
3. Always refused: Piping to shells (curl | sh, base64 | bash), dd, mkfs, destructive rm -rf / or ~, chmod -R on system paths, or arbitrary sudo.
Default working directory is your home folder (${DEFAULT_CWD}).`,
    {
      command: z.string().describe("The exact command line to execute on Ubuntu"),
      cwd: z.string().optional().describe(`Optional working directory. Must be inside home directory (${DEFAULT_CWD})`),
    },
    async ({ command, cwd }) => {
      try {
        const result = await executeCommand(command, { cwd });
        return {
          content: [
            {
              type: "text" as const,
              text: `[cwd: ${result.cwd}] [tier: ${result.tier}]\n\n${result.output}`,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  // Tool 2: start_job
  server.tool(
    "start_job",
    "Starts a long-running background command in its own detached process group. Goes through the exact same security validation and desktop approval as run_command. Returns the job_id immediately.",
    {
      command: z.string().describe("The exact command line to run in background"),
      cwd: z.string().optional().describe(`Optional working directory. Must be inside home directory (${DEFAULT_CWD})`),
    },
    async ({ command, cwd }) => {
      try {
        const result = await startJob(command, cwd);
        return {
          content: [
            {
              type: "text" as const,
              text: `${result.message}\nUse job_status('${result.jobId}') to check progress, or job_output('${result.jobId}') to read logs.`,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error starting job: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  // Tool 3: job_status
  server.tool(
    "job_status",
    "Checks the status of a background job. Returns running, finished (with exit code), or died, along with elapsed seconds.",
    {
      job_id: z.string().describe("The 8-character hex job ID"),
    },
    async ({ job_id }) => {
      try {
        const status = await getJobStatus(job_id);
        const exitStr = status.exitCode !== null ? ` (exit code: ${status.exitCode})` : "";
        return {
          content: [
            {
              type: "text" as const,
              text: `Job ID: ${status.jobId}\nStatus: ${status.status}${exitStr}\nElapsed: ${status.elapsedSeconds}s\nCommand: ${status.command}\nCwd: ${status.cwd}`,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error checking job status: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  // Tool 4: job_output
  server.tool(
    "job_output",
    "Reads up to 20,000 bytes from a background job's output log, supporting offset paging.",
    {
      job_id: z.string().describe("The 8-character hex job ID"),
      offset: z.number().optional().describe("Starting byte offset (defaults to 0)"),
    },
    async ({ job_id, offset }) => {
      try {
        const output = await getJobOutput(job_id, offset);
        return {
          content: [
            {
              type: "text" as const,
              text: `Job ID: ${output.jobId}\nOffset: ${output.offset} / ${output.totalSize} bytes (next offset: ${output.nextOffset})\n\n${output.content || "(No output yet)"}`,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error reading job output: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  // Tool 5: cancel_job
  server.tool(
    "cancel_job",
    "Terminates a running background job by sending SIGTERM (and SIGKILL if needed) to the entire process group.",
    {
      job_id: z.string().describe("The 8-character hex job ID to cancel"),
    },
    async ({ job_id }) => {
      try {
        const result = await cancelJob(job_id);
        return {
          content: [
            {
              type: "text" as const,
              text: result.message,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error cancelling job: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  // Tool 6: system_summary
  server.tool(
    "system_summary",
    "Returns a quick system summary: hostname, OS version, uptime, disk usage, and memory usage.",
    {},
    async () => {
      try {
        const summary = await getSystemSummary();
        return {
          content: [
            {
              type: "text" as const,
              text: summary,
            },
          ],
        };
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        return {
          content: [
            {
              type: "text" as const,
              text: `Error generating summary: ${errorMsg}`,
            },
          ],
        };
      }
    }
  );

  return server;
}
