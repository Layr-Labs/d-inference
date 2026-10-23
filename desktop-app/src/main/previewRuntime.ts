import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

const run = promisify(execFile);
const stderrLimit = 2000;
const terminateMs = 4000;

/** A start failure whose message carries the bundled API's own diagnostics. */
export class PreviewStartError extends Error {}

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

declare const __DARKBLOOM_PREVIEW_TEAM__: string;
export const previewTeam =
  typeof __DARKBLOOM_PREVIEW_TEAM__ === 'string' ? __DARKBLOOM_PREVIEW_TEAM__ : '';

// Opt-in at compile time, never through the environment of a released app.
// The native attach-only mode keeps provider operations on the installed,
// vendor-signed runtime. Only its desktop API is bundled here for local review.
export class PreviewRuntime {
  private child?: ChildProcess;
  private starting?: Promise<void>;
  private stopped = false;
  readonly requirement: string;

  constructor(
    readonly binary: string,
    readonly directory: string,
    team: string,
    private readonly timeoutMs = 30_000,
  ) {
    if (!/^[A-Z0-9]{10}$/.test(team)) throw new Error('Invalid preview signing team');
    this.requirement =
      '-R=anchor apple generic and identifier "io.darkbloom.desktop.preview.runtime"' +
      ` and certificate leaf[subject.OU] = "${team}"`;
  }

  ensure(): Promise<void> {
    if (this.stopped) return Promise.reject(new Error('Preview runtime has stopped'));
    if (!this.starting) {
      this.starting = this.start().finally(() => {
        this.starting = undefined;
      });
    }
    return this.starting;
  }

  private async start() {
    if (this.child && this.child.exitCode === null && !this.child.killed) return;
    const directory = this.directory;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    if (this.stopped) {
      throw new Error('Preview runtime has stopped');
    }
    await this.replaceOrphan();
    const child = spawn(this.binary, ['desktop', 'serve'], {
      env: {
        ...process.env,
        DARKBLOOM_DESKTOP_ATTACH_ONLY: '1',
        DARKBLOOM_DESKTOP_DIR: directory,
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    this.child = child;
    // Keep a bounded tail of the API's stderr (it reports lock, discovery and runtime errors there);
    // reading continuously also keeps a long-lived child from blocking on a full pipe.
    let stderr = '';
    child.stderr?.setEncoding('utf8');
    child.stderr?.on('data', (chunk: string) => {
      stderr = (stderr + chunk).slice(-stderrLimit);
    });
    let failed = false;
    child.once('error', () => {
      failed = true;
    });
    let closed = false;
    child.once('close', () => {
      closed = true;
      if (this.child === child) this.child = undefined;
    });
    const deadline = Date.now() + this.timeoutMs;
    while (!this.stopped && !failed && child.exitCode === null && Date.now() < deadline) {
      try {
        const record = JSON.parse(await readFile(path.join(directory, 'connection.json'), 'utf8'));
        if (record.pid === child.pid) return;
      } catch {
        /* The native API writes discovery after binding its socket. */
      }
      await delay(100);
    }
    child.kill('SIGTERM');
    // Let the exiting API's last stderr arrive before reporting it.
    for (let wait = 0; wait < 5 && !closed && !failed; wait++) await delay(100);
    const detail = stderr.trim().split('\n').at(-1);
    throw new PreviewStartError(
      `The bundled preview API did not start${detail ? `: ${detail}` : ''}`,
    );
  }

  /**
   * Electron's single-instance lock means no other preview app owns this directory, so an API
   * still recorded in it was left by a previous app process that crashed or was killed. It holds
   * the native service lock and would make every new API exit, so stop it first. The recorded
   * pid is only signalled while it is still this bundled binary serving the desktop API.
   */
  private async replaceOrphan() {
    let pid: unknown;
    try {
      pid = JSON.parse(await readFile(path.join(this.directory, 'connection.json'), 'utf8')).pid;
    } catch {
      return;
    }
    if (!Number.isSafeInteger(pid) || (pid as number) <= 1 || pid === this.child?.pid) return;
    const orphan = pid as number;
    if (!alive(orphan) || !(await this.isBundledAPI(orphan))) return;
    process.kill(orphan, 'SIGTERM');
    const deadline = Date.now() + terminateMs;
    while (alive(orphan) && Date.now() < deadline) await delay(100);
    if (alive(orphan)) process.kill(orphan, 'SIGKILL');
  }

  private async isBundledAPI(pid: number) {
    try {
      const { stdout } = await run('/bin/ps', ['-ww', '-o', 'args=', '-p', String(pid)]);
      const command = `${this.binary} desktop serve`;
      const args = stdout.trim();
      return args === command || args.endsWith(` ${command}`);
    } catch {
      return false;
    }
  }

  async stop() {
    this.stopped = true;
    const child = this.child;
    if (!child) return;
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => child.kill('SIGKILL'), terminateMs);
      child.once('close', () => {
        clearTimeout(timeout);
        resolve();
      });
      child.kill('SIGTERM');
    });
  }
}
