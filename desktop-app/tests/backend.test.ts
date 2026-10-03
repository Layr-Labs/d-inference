import { afterEach, beforeEach, expect, it } from 'vitest';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Backend } from '../src/main/backend';
import type { Resource, Snapshot } from '../src/shared/contracts';

// A real (unsigned) runtime executable in an isolated HOME. It records every
// `update` invocation so the test observes what install() actually executed.
let home: string;
const saved = {
  HOME: process.env.HOME,
  CLI: process.env.DARKBLOOM_CLI_PATH,
  DIR: process.env.DARKBLOOM_DESKTOP_DIR,
  ATTACH: process.env.DARKBLOOM_DESKTOP_ATTACH_ONLY,
};
const restore = (name: string, value?: string) =>
  value === undefined ? delete process.env[name] : (process.env[name] = value);
beforeEach(async () => {
  home = await mkdtemp(path.join(tmpdir(), 'darkbloom-backend-'));
  await mkdir(path.join(home, '.darkbloom/bin'), { recursive: true });
  const runtime = path.join(home, '.darkbloom/bin/darkbloom');
  await writeFile(
    runtime,
    '#!/bin/sh\nif [ "$1" = update ]; then touch "$HOME/update-ran"; fi\nexit 0\n',
  );
  await chmod(runtime, 0o755);
  process.env.HOME = home;
  delete process.env.DARKBLOOM_CLI_PATH;
});
afterEach(async () => {
  process.env.HOME = saved.HOME;
  restore('DARKBLOOM_CLI_PATH', saved.CLI);
  restore('DARKBLOOM_DESKTOP_DIR', saved.DIR);
  restore('DARKBLOOM_DESKTOP_ATTACH_ONLY', saved.ATTACH);
  await rm(home, { recursive: true, force: true });
});

it('streams runtime state from event frames split across chunks', async () => {
  const state = (observed_at: number) => ({ protocol: 1, models: [], machine: {}, observed_at });
  const frames = [
    `event: state\ndata: ${JSON.stringify(state(1))}\n\n`,
    ': keepalive\n\n',
    `event: state\ndata: ${JSON.stringify(state(2))}\n\n`,
  ].join('');
  const server = createServer((request, response) => {
    if (request.url === '/control/v1/state') return void response.end(JSON.stringify(state(0)));
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    response.write(frames.slice(0, 30));
    setTimeout(() => response.end(frames.slice(30)), 20);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const dir = path.join(home, 'desktop');
  await mkdir(dir);
  const record = path.join(dir, 'connection.json');
  const port = (server.address() as AddressInfo).port;
  await writeFile(
    record,
    JSON.stringify({ version: 1, port, pid: process.pid, token: 't'.repeat(40) }),
  );
  await chmod(record, 0o600);
  process.env.DARKBLOOM_DESKTOP_DIR = dir;
  process.env.DARKBLOOM_DESKTOP_ATTACH_ONLY = '1';

  const backend = new Backend(false);
  const seen: number[] = [];
  const latest = new Promise<void>((resolve) =>
    backend.on('state', (snapshot: Snapshot) => {
      seen.push(snapshot.observed_at);
      if (snapshot.observed_at === 2) resolve();
    }),
  );
  const watching = backend.watch();
  await latest;
  backend.stop();
  await watching;
  server.close();
  expect(seen.slice(0, 3)).toEqual([0, 1, 2]);
  expect(backend.current.state).toBe('ready');
});

it('refuses to run an existing runtime that fails the packaged code requirement', async () => {
  const backend = new Backend(true);
  await expect(backend.install(path.join(home, 'unused-install.sh'))).rejects.toThrow(
    'Runtime installation failed',
  );
  expect(existsSync(path.join(home, 'update-ran'))).toBe(false);
  expect(backend.current.state).toBe('error');
});

it('forwards only allowlisted resources, including request history', async () => {
  const backend = new Backend(false);
  expect(() => backend.read('prompts' as Resource)).toThrow('Unknown resource');
  await expect(backend.read('request-history')).rejects.toThrow('Runtime is not connected');
});

it('runs the existing runtime update without the signature gate in development', async () => {
  process.env.DARKBLOOM_CLI_PATH = path.join(home, '.darkbloom/bin/darkbloom');
  const backend = new Backend(false);
  await backend.install(path.join(home, 'unused-install.sh'));
  expect(existsSync(path.join(home, 'update-ran'))).toBe(true);
});
