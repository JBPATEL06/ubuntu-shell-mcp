import * as fs from 'node:fs';
import * as path from 'node:path';
import { AUDIT_LOG_PATH } from './config.js';

export interface AuditRecord {
  timestamp: string;
  command: string;
  tier: 'auto' | 'prompt' | 'refused';
  decision: 'ALLOWED' | 'BLOCKED' | 'DENIED_BY_USER';
  cwd: string;
  isSudo: boolean;
  reason?: string;
}

export function logAudit(record: AuditRecord): void {
  try {
    const dir = path.dirname(AUDIT_LOG_PATH);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    // Clean record to guarantee no sensitive passwords can ever be included
    const cleanRecord = {
      timestamp: record.timestamp || new Date().toISOString(),
      command: record.command,
      tier: record.tier,
      decision: record.decision,
      cwd: record.cwd,
      isSudo: Boolean(record.isSudo),
      reason: record.reason || '',
    };
    const line = JSON.stringify(cleanRecord) + '\n';
    fs.appendFileSync(AUDIT_LOG_PATH, line, 'utf8');
  } catch (err) {
    console.error('Failed to append to audit log:', err);
  }
}
