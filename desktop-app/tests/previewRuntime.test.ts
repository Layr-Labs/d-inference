import { afterEach, beforeEach, expect, it } from 'vitest';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Backend } from '../src/main/backend';
import { PreviewRuntime, previewTeam } from '../src/main/previewRuntime';
import { desktopBuildConfig } from '../electron-builder';

const runtimes: PreviewRuntime[] = [];
const directories: string[] = [];
// A preview's API attaches to the installed CLI; give each test its own HOME with one, so the
// results don't depend on whether this machine has Darkbloom installed.
const savedHome = process.env.HOME;
beforeEach(async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'desktop-preview-home-'));
  directories.push(home);
  await mkdir(path.join(home, '.darkbloom/bin'), { recursive: true });
  await writeFile(path.join(home, '.darkbloom/bin/darkbloom'), '');
  process.env.HOME = home;
});
afterEach(async () => {
  process.env.HOME = savedHome;
  await Promise.all(runtimes.splice(0).map((runtime) => runtime.stop()));
  await Promise.all(
    directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

async function fixture(source: string, timeout = 2000) {
  const root = await mkdtemp(path.join(tmpdir(), 'desktop-preview-test-'));
  directories.push(root);
  const binary = path.join(root, 'darkbloom');
  await writeFile(binary, `#!${process.execPath}\n${source}`);
  await chmod(binary, 0o755);
  const runtime = new PreviewRuntime(binary, path.join(root, 'state'), 'ABCDEFGHIJ', timeout);
  runtimes.push(runtime);
  return runtime;
}

const ready = `
const fs = require('node:fs');
const dir = process.env.DARKBLOOM_DESKTOP_DIR;
if (process.env.DARKBLOOM_DESKTOP_ATTACH_ONLY !== '1') process.exit(2);
fs.writeFileSync(dir + '/connection.json', JSON.stringify({pid: process.pid}), {mode: 0o600});
setInterval(() => {}, 1000);
`;

it('starts one API process, stops it, and preserves state across launches', async () => {
  const runtime = await fixture(ready);
  await Promise.all([runtime.ensure(), runtime.ensure()]);
  const first = JSON.parse(await readFile(path.join(runtime.directory, 'connection.json'), 'utf8'));
  await runtime.ensure();
  expect(
    JSON.parse(await readFile(path.join(runtime.directory, 'connection.json'), 'utf8')).pid,
  ).toBe(first.pid);
  await writeFile(path.join(runtime.directory, 'saved-state'), 'preserved');
  await runtime.stop();
  expect(() => process.kill(first.pid, 0)).toThrow();
  await expect(runtime.ensure()).rejects.toThrow('stopped');
  const next = new PreviewRuntime(runtime.binary, runtime.directory, 'ABCDEFGHIJ');
  runtimes.push(next);
  await next.ensure();
  expect(await readFile(path.join(runtime.directory, 'saved-state'), 'utf8')).toBe('preserved');
});

it('fails promptly for a crashed child and bounds a child that never becomes ready', async () => {
  await expect((await fixture('process.exit(3);')).ensure()).rejects.toThrow('did not start');
  await expect((await fixture('setInterval(() => {}, 1000);', 200)).ensure()).rejects.toThrow(
    'did not start',
  );
});

it('rejects an unsigned preview backend before executing it or updating it', async () => {
  const runtime = await fixture(ready);
  const backend = new Backend(true, runtime);
  await backend.connect();
  // macOS codesign rejects the unsigned fixture; CI's Linux runner has no codesign at all. Either
  // way the binary exists, so it is an untrusted runtime (an error), never a missing install.
  expect(backend.current.state).toBe('error');
  await expect(readFile(path.join(runtime.directory, 'connection.json'))).rejects.toThrow();
  await expect(backend.install('unused')).rejects.toThrow('Rebuild the local preview');
});

it('keeps release identity and trust unchanged unless both build settings are present', () => {
  expect(previewTeam).toBe('');
  expect(desktopBuildConfig({}).appId).toBe('io.darkbloom.desktop');
  expect(() => desktopBuildConfig({ DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ' })).toThrow();
  expect(() => desktopBuildConfig({ DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime' })).toThrow();
  expect(() => new PreviewRuntime('/tmp/runtime', '/tmp/state', 'bad"team')).toThrow();
  const config = desktopBuildConfig({
    DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
    DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
    DARKBLOOM_DESKTOP_UPDATE_URL: 'https://updates.example.test/',
  });
  expect(config.productName).toBe('Darkbloom Preview');
  expect(config.appId).toBe('io.darkbloom.desktop.preview');
  expect(config.publish).toBeNull();
});

// Mirrors the native API's exclusive service lock: a second API exits while the first holds it.
const locked = `
const fs = require('node:fs');
const dir = process.env.DARKBLOOM_DESKTOP_DIR;
const lock = dir + '/service.pid';
try {
  process.kill(Number(fs.readFileSync(lock, 'utf8')), 0);
  console.error('Error: Desktop API is already running');
  process.exit(64);
} catch {}
fs.writeFileSync(lock, String(process.pid));
fs.writeFileSync(dir + '/connection.json', JSON.stringify({pid: process.pid}), {mode: 0o600});
setInterval(() => {}, 1000);
`;

it('replaces an API left running by a crashed app instead of failing every relaunch', async () => {
  const crashed = await fixture(locked);
  await crashed.ensure();
  const orphan = JSON.parse(
    await readFile(path.join(crashed.directory, 'connection.json'), 'utf8'),
  ).pid;
  // The crashed app never ran stop(); a relaunch gets a fresh runtime for the same directory.
  const relaunched = new PreviewRuntime(crashed.binary, crashed.directory, 'ABCDEFGHIJ', 2000);
  runtimes.push(relaunched);
  await relaunched.ensure();
  const current = JSON.parse(
    await readFile(path.join(crashed.directory, 'connection.json'), 'utf8'),
  ).pid;
  expect(current).not.toBe(orphan);
  expect(() => process.kill(orphan, 0)).toThrow();
});

it('leaves an unrelated process recorded in discovery untouched', async () => {
  const runtime = await fixture(ready);
  await mkdir(runtime.directory, { recursive: true });
  // A stale record whose pid now belongs to another program (here, this test process).
  await writeFile(
    path.join(runtime.directory, 'connection.json'),
    JSON.stringify({ pid: process.pid }),
  );
  await runtime.ensure();
  expect(() => process.kill(process.pid, 0)).not.toThrow();
});

it('reports the API’s own startup error instead of discarding it', async () => {
  const runtime = await fixture(
    "console.error('Cannot publish desktop API discovery: disk full'); process.exit(1);",
  );
  await expect(runtime.ensure()).rejects.toThrow(
    'The bundled preview API did not start: Cannot publish desktop API discovery: disk full',
  );
  const backend = new Backend(false, runtime);
  await backend.connect();
  expect(backend.current).toMatchObject({
    state: 'error',
    message: expect.stringContaining('disk full'),
  });
});
