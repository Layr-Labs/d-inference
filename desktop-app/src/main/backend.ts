import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, readFile, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { InstallTranscript, lineReader } from './installProgress';
import {
  protocolVersion,
  type Action,
  type DesktopStatus,
  type Operation,
  type Resource,
  type Snapshot,
} from '../shared/contracts';
import { frameData, splitFrames } from './sse';
import { PreviewStartError, type PreviewRuntime } from './previewRuntime';

const execute = promisify(execFile);
const runtimeRequirement =
  '-R=anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"';
// `desktop ensure` may wait for a launchd bootout, one restart, and the new API's version.
const ensureTimeoutMs = 90_000;
const installTimeoutMs = 10 * 60_000;
const resources = new Set<Resource>([
  'state',
  'cloud',
  'network',
  'cooling',
  'release',
  'release-history',
  'leaderboard',
  'endpoint-key',
  'insights-week',
  'insights-month',
  'request-history',
  'hardware',
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
// Every snapshot, initial or streamed, must speak this app's protocol.
function compatible(snapshot: Snapshot) {
  if (
    snapshot?.protocol !== protocolVersion ||
    !Array.isArray(snapshot.models) ||
    !snapshot.machine
  )
    throw new Error('Incompatible backend protocol');
  return snapshot;
}

export class Backend extends EventEmitter {
  current: DesktopStatus = { state: 'connecting' };
  snapshot?: Snapshot;
  private connection?: ReturnType<typeof validateDiscovery>;
  private stopped = false;
  // At most one install runs; the renderer's button and the automatic install share it.
  private installation?: Promise<void>;
  private installer?: ChildProcess;
  private cancelled = false;
  // Automatic install runs once per launch; any install attempt uses it up.
  private installAttempted = false;
  // A failed or cancelled install stays on screen until the next attempt.
  private installOutcome?: DesktopStatus;
  /** `autoInstallScript`: the bundled installer to run when the runtime is missing, if enabled. */
  constructor(
    private packaged: boolean,
    private preview?: PreviewRuntime,
    private autoInstallScript?: string,
  ) {
    super();
  }
  get binary() {
    return (
      this.preview?.binary ||
      (!this.packaged && process.env.DARKBLOOM_CLI_PATH) ||
      path.join(homedir(), '.darkbloom/bin/darkbloom')
    );
  }
  // Releases require Darkbloom's Developer ID; opt-in previews require their
  // compiled-in review signer and dedicated bundled-API identifier.
  private async verifyRuntime(binary: string) {
    if (this.packaged)
      await execute('/usr/bin/codesign', [
        '--verify',
        '--strict',
        this.preview?.requirement || runtimeRequirement,
        binary,
      ]);
  }
  private status(value: DesktopStatus) {
    // Reconnecting to a still-missing runtime must not hide why its install stopped.
    if (value.state === 'missing' && this.installOutcome) value = this.installOutcome;
    this.current = value;
    this.emit('status', value);
  }
  async connect() {
    try {
      const binary = await realpath(this.binary);
      await this.verifyRuntime(binary);
      if (this.preview) await this.preview.ensure();
      else if (this.packaged || process.env.DARKBLOOM_DESKTOP_ATTACH_ONLY !== '1')
        await execute(binary, ['desktop', 'ensure'], {
          timeout: ensureTimeoutMs,
          maxBuffer: 64_000,
        });
      await this.discover();
      this.snapshot = compatible(await this.read<Snapshot>('state'));
      this.status({ state: 'ready' });
      this.emit('state', this.snapshot);
    } catch (error) {
      // A discovered but rejected runtime must not be watched, or its events would bypass the
      // protocol check above.
      this.connection = undefined;
      const code = (error as NodeJS.ErrnoException).code;
      // The runtime answered, so it isn't unreachable: it needs an update, not a repair.
      if (error instanceof Error && error.message === 'Incompatible backend protocol')
        return this.status({
          state: 'incompatible',
          message:
            'The installed runtime is not compatible with this version of the app. Update Darkbloom.',
        });
      this.status({
        state: code === 'ENOENT' ? 'missing' : 'error',
        message:
          code === 'ENOENT'
            ? 'Install the Darkbloom runtime to connect this Mac.'
            : error instanceof PreviewStartError
              ? error.message
              : 'Could not connect to the runtime. Update or repair the installation.',
      });
    }
  }
  private async discover() {
    const file = path.join(
      this.preview?.directory ||
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
  async openHardwareEvents(signal: AbortSignal) {
    if (!this.connection) throw new Error('Runtime is not connected');
    return fetch(`http://127.0.0.1:${this.connection.port}/control/v1/hardware/events`, {
      headers: { Authorization: `Bearer ${this.connection.token}` },
      signal,
      redirect: 'error',
    });
  }
  async watch() {
    while (!this.stopped) {
      try {
        // An install connects when it finishes; meanwhile its progress owns the status.
        if (!this.connection && !this.installation) {
          await this.connect();
          this.autoInstall();
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
            const { frames, rest } = splitFrames(buffer);
            buffer = rest;
            for (const frame of frames) {
              const data = frameData(frame);
              if (data === undefined) continue;
              this.snapshot = compatible(JSON.parse(data));
              this.status({ state: 'ready' });
              this.emit('state', this.snapshot);
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
  // First launch of a release build: install a missing runtime without waiting for a click.
  private autoInstall() {
    if (
      !this.autoInstallScript ||
      this.preview ||
      this.installAttempted ||
      this.stopped ||
      this.current.state !== 'missing'
    )
      return;
    void this.install(this.autoInstallScript).catch(() => {});
  }
  install(script: string): Promise<void> {
    if (this.preview)
      return Promise.reject(
        new Error('Rebuild the local preview to update its bundled desktop API.'),
      );
    this.installAttempted = true;
    this.installation ??= this.runInstall(script).finally(() => {
      this.installation = undefined;
    });
    return this.installation;
  }
  /** Stops an in-progress install; the runtime stays as it was. */
  cancelInstall() {
    if (!this.installer) return;
    this.cancelled = true;
    killGroup(this.installer);
  }
  private async runInstall(script: string) {
    this.installOutcome = undefined;
    this.cancelled = false;
    const transcript = new InstallTranscript();
    this.status({ state: 'installing', message: 'Preparing to install the backend…' });
    let existing: string | undefined;
    try {
      try {
        existing = await realpath(this.binary);
      } catch {}
      if (existing) {
        await this.verifyRuntime(existing);
        this.status({ state: 'installing', message: 'Updating the backend…' });
        await this.runInstaller(existing, ['update'], process.env, transcript);
      } else
        await this.runInstaller(
          '/bin/bash',
          [script],
          { ...process.env, COORD_URL: 'https://api.darkbloom.dev' },
          transcript,
        );
    } catch (error) {
      // A runtime that never got installed is still missing (Install retries); a failed
      // update of an existing one needs a repair.
      const state = existing ? 'error' : 'missing';
      if (error instanceof InstallCancelled) {
        this.installOutcome = {
          state,
          message: existing ? 'Backend update cancelled.' : 'Backend installation cancelled.',
        };
        this.status(this.installOutcome);
        return;
      }
      this.installOutcome = {
        state,
        message: transcript.failure(
          error instanceof Error && error.message === 'timeout',
          existing ? 'update' : 'install',
        ),
        installFailed: true,
      };
      this.status(this.installOutcome);
      throw new Error('Runtime installation failed');
    }
    this.status({ state: 'installing', message: 'Backend installed. Starting it…' });
    await this.connect();
  }
  // Runs the installer without a terminal (it then never prompts), publishing its steps as
  // they print. Only the current line is buffered; a reason for failing is kept by the transcript.
  private runInstaller(
    command: string,
    args: string[],
    env: NodeJS.ProcessEnv,
    transcript: InstallTranscript,
  ) {
    return new Promise<void>((resolve, reject) => {
      // Its own process group, so cancelling also stops curl and other children.
      const child = spawn(command, args, {
        env,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      this.installer = child;
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        killGroup(child);
      }, installTimeoutMs);
      const onLine = (line: string) => {
        const message = transcript.observe(line);
        if (message && !this.cancelled) this.status({ state: 'installing', message });
      };
      const readers = [child.stdout, child.stderr].map((stream) => {
        const reader = lineReader(onLine);
        stream?.setEncoding('utf8');
        stream?.on('data', (chunk: string) => reader.push(chunk));
        return reader;
      });
      const finish = (error?: Error) => {
        clearTimeout(timer);
        if (this.installer === child) this.installer = undefined;
        readers.forEach((reader) => reader.end());
        if (this.cancelled) reject(new InstallCancelled());
        else if (timedOut) reject(new Error('timeout'));
        else if (error) reject(error);
        else resolve();
      };
      child.once('error', finish);
      child.once('close', (code) =>
        finish(code === 0 ? undefined : new Error(`Installer exited with ${code}`)),
      );
    });
  }
  // Quitting stops an install: with the app gone it could neither report nor finish cleanly.
  stop() {
    this.stopped = true;
    this.cancelInstall();
  }
}
function killGroup(child: ChildProcess) {
  try {
    if (child.pid) process.kill(-child.pid, 'SIGTERM');
  } catch {
    child.kill('SIGTERM');
  }
}
/**
 * Whether a missing runtime is installed on launch without a click: release builds only. The
 * signed preview refuses installs, smoke tests never touch the system, and development opts in
 * with DARKBLOOM_DESKTOP_AUTO_INSTALL=1.
 */
export function autoInstallEnabled(options: {
  packaged: boolean;
  preview: boolean;
  smokeTest: boolean;
  env: NodeJS.ProcessEnv;
}) {
  if (options.preview || options.smokeTest) return false;
  return options.packaged || options.env.DARKBLOOM_DESKTOP_AUTO_INSTALL === '1';
}
class InstallCancelled extends Error {}
