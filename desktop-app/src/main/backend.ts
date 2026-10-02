import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, readFile, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import type { Action, DesktopStatus, Operation, Resource, Snapshot } from '../shared/contracts';

const execute = promisify(execFile);
const runtimeRequirement =
  '-R=anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"';
// `desktop ensure` may wait for a launchd bootout, one restart, and the new API's version.
const ensureTimeoutMs = 90_000;
const resources = new Set<Resource>([
  'state',
  'cloud',
  'network',
  'cooling',
  'release',
  'leaderboard',
  'endpoint-key',
  'insights-week',
  'insights-month',
]);
export function validateDiscovery(value: unknown): {
  port: number;
  token: string;
  pid: number;
  version: number;
} {
  const item = value as Record<string, unknown>;
  if (
    !item ||
    item.version !== 1 ||
    !Number.isInteger(item.port) ||
    Number(item.port) < 1 ||
    Number(item.port) > 65535 ||
    typeof item.token !== 'string' ||
    item.token.length < 32 ||
    !Number.isInteger(item.pid) ||
    Number(item.pid) <= 0
  )
    throw new Error('Invalid backend discovery record');
  return item as ReturnType<typeof validateDiscovery>;
}
export class Backend extends EventEmitter {
  current: DesktopStatus = { state: 'connecting' };
  snapshot?: Snapshot;
  private connection?: ReturnType<typeof validateDiscovery>;
  private stopped = false;
  constructor(private packaged: boolean) {
    super();
  }
  get binary() {
    return (
      (!this.packaged && process.env.DARKBLOOM_CLI_PATH) ||
      path.join(homedir(), '.darkbloom/bin/darkbloom')
    );
  }
  // Packaged builds only execute a runtime signed by Darkbloom's Developer ID.
  private async verifyRuntime(binary: string) {
    if (this.packaged)
      await execute('/usr/bin/codesign', ['--verify', '--strict', runtimeRequirement, binary]);
  }
  private status(value: DesktopStatus) {
    this.current = value;
    this.emit('status', value);
  }
  async connect() {
    try {
      const binary = await realpath(this.binary);
      await this.verifyRuntime(binary);
      if (this.packaged || process.env.DARKBLOOM_DESKTOP_ATTACH_ONLY !== '1')
        await execute(binary, ['desktop', 'ensure'], {
          timeout: ensureTimeoutMs,
          maxBuffer: 64_000,
        });
      await this.discover();
      this.snapshot = await this.read<Snapshot>('state');
      if (
        this.snapshot.protocol !== 1 ||
        !Array.isArray(this.snapshot.models) ||
        !this.snapshot.machine
      )
        throw new Error('Incompatible backend protocol');
      this.status({ state: 'ready' });
      this.emit('state', this.snapshot);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      this.status({
        state: code === 'ENOENT' ? 'missing' : 'error',
        message:
          code === 'ENOENT'
            ? 'Install the Darkbloom runtime to connect this Mac.'
            : 'Could not connect to the runtime. Update or repair the installation.',
      });
    }
  }
  private async discover() {
    const file = path.join(
      (!this.packaged && process.env.DARKBLOOM_DESKTOP_DIR) ||
        path.join(homedir(), '.darkbloom/desktop'),
      'connection.json',
    );
    const stat = await lstat(file);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      (stat.mode & 0o077) !== 0 ||
      stat.uid !== process.getuid?.() ||
      stat.size > 4096
    )
      throw new Error('Unsafe discovery record');
    this.connection = validateDiscovery(JSON.parse(await readFile(file, 'utf8')));
  }
  async request<T>(resource: string, body?: unknown): Promise<T> {
    if (!this.connection) throw new Error('Runtime is not connected');
    const response = await fetch(
      `http://127.0.0.1:${this.connection.port}/control/v1/${resource}`,
      {
        method: body ? 'POST' : 'GET',
        redirect: 'error',
        signal: AbortSignal.timeout(25_000),
        headers: {
          Authorization: `Bearer ${this.connection.token}`,
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      },
    );
    const text = await response.text();
    if (text.length > 4_000_000) throw new Error('Backend response too large');
    const data = JSON.parse(text);
    if (!response.ok) throw new Error(data.error || 'The operation failed');
    return data;
  }
  read<T>(resource: Resource): Promise<T> {
    if (!resources.has(resource)) throw new Error('Unknown resource');
    return this.request<T>(resource);
  }
  act(action: Action) {
    return this.request<Operation>('actions', { ...action, id: crypto.randomUUID() });
  }
  async watch() {
    while (!this.stopped) {
      try {
        if (!this.connection) {
          await this.connect();
        }
        if (this.connection) {
          const response = await fetch(
            `http://127.0.0.1:${this.connection.port}/control/v1/events`,
            {
              headers: { Authorization: `Bearer ${this.connection.token}` },
              signal: AbortSignal.timeout(70_000),
              redirect: 'error',
            },
          );
          if (!response.ok || !response.body) throw new Error('Connection interrupted');
          const reader = response.body.getReader();
          const decoder = new TextDecoder();
          let buffer = '';
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            if (buffer.length > 4_000_000) {
              await reader.cancel();
              throw new Error('Event too large');
            }
            let end: number;
            while ((end = buffer.indexOf('\n\n')) >= 0) {
              const event = buffer.slice(0, end);
              buffer = buffer.slice(end + 2);
              const data = event.split('\n').find((line) => line.startsWith('data: '));
              if (data) {
                this.snapshot = JSON.parse(data.slice(6));
                this.status({ state: 'ready' });
                this.emit('state', this.snapshot);
              }
            }
          }
        }
      } catch {
        this.connection = undefined;
        this.status({ state: 'connecting', message: 'Reconnecting to the runtime…' });
      }
      await new Promise((resolve) => setTimeout(resolve, this.connection ? 250 : 5000));
    }
  }
  async install(script: string) {
    this.status({ state: 'installing', message: 'Installing the verified Swift runtime…' });
    try {
      let existing: string | undefined;
      try {
        existing = await realpath(this.binary);
      } catch {}
      if (existing) {
        await this.verifyRuntime(existing);
        await execute(existing, ['update'], { timeout: 10 * 60_000, maxBuffer: 256_000 });
      } else
        await execute('/bin/bash', [script], {
          timeout: 10 * 60_000,
          maxBuffer: 256_000,
          env: { ...process.env, COORD_URL: 'https://api.darkbloom.dev' },
        });
      await this.connect();
    } catch {
      this.status({
        state: 'error',
        message: 'Installation failed. Check your connection and retry.',
      });
      throw new Error('Runtime installation failed');
    }
  }
  stop() {
    this.stopped = true;
  }
}
