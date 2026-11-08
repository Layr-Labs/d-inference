import { spawn, type ChildProcess } from 'node:child_process';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

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
    const child = spawn(this.binary, ['desktop', 'serve'], {
      env: {
        ...process.env,
        DARKBLOOM_DESKTOP_ATTACH_ONLY: '1',
        DARKBLOOM_DESKTOP_DIR: directory,
      },
      stdio: 'ignore',
    });
    this.child = child;
    let failed = false;
    child.once('error', () => {
      failed = true;
    });
    child.once('close', () => {
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
    throw new Error('The bundled preview API did not start');
  }

  async stop() {
    this.stopped = true;
    const child = this.child;
    if (!child) return;
    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => child.kill('SIGKILL'), 4000);
      child.once('close', () => {
        clearTimeout(timeout);
        resolve();
      });
      child.kill('SIGTERM');
    });
  }
}
