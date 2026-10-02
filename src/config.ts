import * as path from 'node:path';
import * as os from 'node:os';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const PROJECT_ROOT = path.resolve(__dirname, '..');
export const AUDIT_LOG_PATH = path.join(PROJECT_ROOT, 'audit.log');
export const JOBS_DIR = path.join(PROJECT_ROOT, 'jobs');
export const HARDCODED_PATH = '/usr/local/bin:/usr/bin:/bin';
export const MAX_CONCURRENT_JOBS = 5;
export const DEFAULT_CWD = os.homedir();
export const ASKPASS_SCRIPT = path.join(PROJECT_ROOT, 'dist', 'askpass.sh');
