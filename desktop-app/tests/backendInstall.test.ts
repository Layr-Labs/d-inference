import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Backend } from '../src/main/backend';
import { InstallTranscript, lineReader, sanitizeInstallLine } from '../src/main/installProgress';
import type { PreviewRuntime } from '../src/main/previewRuntime';
import type { DesktopStatus } from '../src/shared/contracts';

// Every child the Backend starts goes through spawn; the spy proves none starts without a click.
const spawned = vi.hoisted(() => ({ calls: 0 }));
vi.mock('node:child_process', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:child_process')>();
  return {
    ...actual,
    spawn: (...args: Parameters<typeof actual.spawn>) => {
      spawned.calls++;
      return actual.spawn(...args);
    },
  };
});

// An isolated HOME with no runtime, and a stand-in installer script that records each run. The
// real installer is never executed.
let home: string;
const savedHome = process.env.HOME;
beforeEach(async () => {
  spawned.calls = 0;
  home = await mkdtemp(path.join(tmpdir(), 'darkbloom-install-'));
  process.env.HOME = home;
});
afterEach(async () => {
  vi.useRealTimers();
  process.env.HOME = savedHome;
  await rm(home, { recursive: true, force: true });
});

async function installer(body: string) {
  const file = path.join(home, 'install-runtime.sh');
  await writeFile(file, `echo run >> "$HOME/install-runs"\n${body}\n`);
  return file;
}
const runs = async () =>
  existsSync(path.join(home, 'install-runs'))
    ? (await readFile(path.join(home, 'install-runs'), 'utf8')).trim().split('\n').length
    : 0;
const record = (backend: Backend) => {
  const seen: DesktopStatus[] = [];
  backend.on('status', (status: DesktopStatus) => seen.push(status));
  return seen;
};
const until = (backend: Backend, test: (status: DesktopStatus) => boolean) =>
  new Promise<void>((resolve) => {
    if (test(backend.current)) return resolve();
    const listener = (status: DesktopStatus) => {
      if (!test(status)) return;
      backend.off('status', listener);
      resolve();
    };
    backend.on('status', listener);
  });
// The watch loop's reconnect may still be awaiting real file-system I/O when the fake clock
// advances, so its next 5 s wait can be scheduled after an advance. Keep advancing until it exits.
const stopWatching = async (backend: Backend, watching: Promise<void>) => {
  backend.stop();
  let done = false;
  void watching.then(() => (done = true));
  while (!done) await vi.advanceTimersByTimeAsync(5_000);
  await watching;
};
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const steps = `
echo "$COORD_URL" > "$HOME/coord-url"
echo "→ [1/5] Fetching latest release from $COORD_URL ..."
echo "→ [2/5] Downloading Darkbloom v1.2.3..."
printf '###               12.5%%\\r########          50.0%%\\r'
echo "  Bundle hash verified ✓"
echo "  Staging and verifying the complete app before touching the live install ..."
echo "→ [3/5] Provisioning Secure Enclave identity..."
echo "→ [4/5] Enrollment + device attestation..."
echo "→ [5/5] Inference model..."`;

describe('install on click', () => {
  it('never installs a missing CLI without a click', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    await installer(steps);
    const backend = new Backend(true);
    const seen = record(backend);
    const watching = backend.watch();
    await until(backend, (status) => status.state === 'missing');
    // Several reconnect attempts later the CLI is still only reported missing.
    for (let attempt = 0; attempt < 3; attempt++) await vi.advanceTimersByTimeAsync(5_000);
    expect(backend.current).toEqual({
      state: 'missing',
      message: 'Install the Darkbloom CLI to connect this Mac.',
    });
    expect(seen.some((status) => status.state === 'installing')).toBe(false);
    expect(spawned.calls).toBe(0);
    expect(await runs()).toBe(0);
    await stopWatching(backend, watching);
  });

  it('installs once the user clicks, with plain progress, while the watch loop waits', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const script = await installer(steps);
    const backend = new Backend(true);
    const watching = backend.watch();
    await until(backend, (status) => status.state === 'missing');
    const seen = record(backend);
    const click = backend.install(script);
    // A second click joins the install in flight.
    expect(backend.install(script)).toBe(click);
    await click;
    expect(await runs()).toBe(1);
    expect(seen.filter((s) => s.state === 'installing').map((s) => s.message)).toEqual([
      'Installing the Darkbloom CLI…',
      'Finding the latest CLI release…',
      'Downloading the CLI…',
      'Downloading the CLI… 12%',
      'Downloading the CLI… 50%',
      'Verifying the CLI’s signature…',
      'Setting up this Mac’s identity…',
      'Setting up device verification…',
      'Finishing up…',
      'CLI installed. Starting it…',
    ]);
    // The watch loop never reconnected over the install's progress.
    expect(seen.some((status) => status.state === 'connecting')).toBe(false);
    expect(await readFile(path.join(home, 'coord-url'), 'utf8')).toBe(
      'https://api.darkbloom.dev\n',
    );
    // The stand-in installs nothing: later attempts still find no CLI and start nothing.
    expect(backend.current.state).toBe('missing');
    await vi.advanceTimersByTimeAsync(5_000);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(await runs()).toBe(1);
    expect(spawned.calls).toBe(1);
    expect(backend.current.state).toBe('missing');
    await stopWatching(backend, watching);
  });

  it('installs a missing CLI in the signed preview, but never updates one', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const script = await installer(steps);
    // The preview's bundled API exists; the installed CLI it attaches to does not.
    const bundled = path.join(home, 'preview-runtime');
    await writeFile(bundled, '');
    const preview = {
      binary: bundled,
      directory: path.join(home, 'preview-api'),
      ensure: async () => {},
    } as unknown as PreviewRuntime;
    const backend = new Backend(true, preview);
    // The app is unsigned in tests; the signature check is not what this covers.
    vi.spyOn(
      backend as unknown as { verifyRuntime: () => Promise<void> },
      'verifyRuntime',
    ).mockResolvedValue();
    await backend.connect();
    expect(backend.current.state).toBe('missing');
    await backend.install(script).catch(() => {});
    expect(await runs()).toBe(1);
    // With the CLI installed, a preview still refuses to update or repair it.
    await mkdir(path.join(home, '.darkbloom/bin'), { recursive: true });
    await writeFile(path.join(home, '.darkbloom/bin/darkbloom'), '');
    await expect(backend.install(script)).rejects.toThrow('Rebuild the local preview');
    expect(await runs()).toBe(1);
  });
});

describe('install', () => {
  it('keeps the step and the installer’s reason when it fails, until the user retries', async () => {
    const script = await installer(`
echo "→ [1/5] Fetching latest release..."
echo "→ [2/5] Downloading Darkbloom v1.2.3..."
echo "  ✗ Bundle hash mismatch — refusing to install possibly-tampered binary." >&2
echo "    Expected: ${'a'.repeat(64)}"
exit 1`);
    const backend = new Backend(true);
    await expect(backend.install(script)).rejects.toThrow('Runtime installation failed');
    const failed = {
      state: 'missing',
      message:
        'Couldn’t install the CLI while downloading it: Bundle hash mismatch — refusing to install possibly-tampered binary.',
      installFailed: true,
    };
    expect(backend.current).toEqual(failed);
    // Reconnecting to the still-missing CLI keeps the reason and starts nothing.
    await backend.connect();
    expect(backend.current).toEqual(failed);
    expect(await runs()).toBe(1);
  });

  it('shares one installer between concurrent requests', async () => {
    const script = await installer('sleep 0.2');
    const backend = new Backend(true);
    const first = backend.install(script);
    const second = backend.install(script);
    expect(second).toBe(first);
    await Promise.all([first, second]);
    expect(await runs()).toBe(1);
  });

  it('cancels the installer and everything it started', async () => {
    const script = await installer(`
echo $$ > "$HOME/installer-pid"
sleep 30 &
echo $! > "$HOME/download-pid"
echo "→ [2/5] Downloading Darkbloom v1.2.3..."
wait`);
    const backend = new Backend(true);
    const installing = backend.install(script);
    await until(backend, (status) => status.message === 'Downloading the CLI…');
    const pids = await Promise.all(
      ['installer-pid', 'download-pid'].map(async (name) =>
        Number(await readFile(path.join(home, name), 'utf8')),
      ),
    );
    backend.cancelInstall();
    await installing;
    expect(backend.current).toEqual({
      state: 'missing',
      message: 'CLI install cancelled.',
    });
    await vi.waitFor(() => expect(pids.filter(alive)).toEqual([]), { timeout: 2_000 });
  });
});

describe('installer output', () => {
  it('reads lines split across chunks and carriage returns, without unbounded buffering', () => {
    const lines: string[] = [];
    const reader = lineReader((line) => lines.push(line), 16);
    reader.push('→ [1/5] Fet');
    reader.push('ching\r## 10%\r## 20');
    reader.push('%\n' + 'x'.repeat(40));
    reader.push('y'.repeat(40));
    reader.push('\ndone');
    reader.end();
    expect(lines).toEqual(['→ [1/5] Fetching', '## 10%', '## 20%', 'x'.repeat(16), 'done']);
  });

  it('never shows tokens, credentials or URL queries', () => {
    expect(
      sanitizeInstallLine(
        `✗ Could not reach https://api.darkbloom.dev/v1/enroll?token=abc Authorization: Bearer ${'z'.repeat(40)} key=hunter2`,
      ),
    ).toBe('Could not reach https://api.darkbloom.dev/v1/enroll Authorization … key …');
  });

  it('reports a timeout, a reason without a step, and a bare failure', () => {
    const transcript = new InstallTranscript();
    expect(transcript.failure()).toBe('Couldn’t install the CLI. Check your connection and retry.');
    transcript.observe('Error: Darkbloom requires Apple Silicon (arm64).');
    expect(transcript.failure()).toBe(
      'Couldn’t install the CLI: Darkbloom requires Apple Silicon (arm64).',
    );
    transcript.observe('→ [3/5] Provisioning Secure Enclave identity...');
    expect(transcript.failure(true)).toBe(
      'Installing the CLI timed out while setting up this Mac’s identity. Check your connection and retry.',
    );
    expect(new InstallTranscript().failure(false, 'update')).toBe(
      'Couldn’t update the CLI. Check your connection and retry.',
    );
  });
});
