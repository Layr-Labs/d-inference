import { afterEach, beforeEach, expect, it } from 'vitest';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Backend } from '../src/main/backend';
import { startAction } from '../src/renderer/components/onboarding/startPlan';
import type { Resource, Snapshot } from '../src/shared/contracts';
import { pairedMac } from './onboardingFixtures';

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

it('reports a runtime that answers in another protocol as incompatible, not unreachable', async () => {
  const server = createServer((_, response) =>
    response.end(JSON.stringify({ protocol: 2, models: [], machine: {} })),
  );
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
  await backend.connect();
  server.close();
  expect(backend.current.state).toBe('incompatible');
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

// A runtime whose initial state and event stream report the given protocols.
async function runtimeSpeaking(initial: number, streamed: number) {
  const state = (protocol: number, observed_at: number) => ({
    protocol,
    models: [],
    machine: {},
    observed_at,
  });
  const server = createServer((request, response) => {
    if (request.url === '/control/v1/state')
      return void response.end(JSON.stringify(state(initial, 0)));
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    response.end(`event: state\ndata: ${JSON.stringify(state(streamed, 1))}\n\n`);
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
  return server;
}

function observe(backend: Backend) {
  const seen = { protocols: [] as number[], statuses: [] as string[] };
  backend.on('state', (snapshot: Snapshot) => seen.protocols.push(snapshot.protocol));
  backend.on('status', (status: { state: string }) => seen.statuses.push(status.state));
  return seen;
}

it('never watches a runtime whose protocol it rejected', async () => {
  const server = await runtimeSpeaking(2, 2);
  const backend = new Backend(false);
  const seen = observe(backend);
  void backend.watch();
  await new Promise((resolve) => setTimeout(resolve, 600));
  backend.stop();
  server.close();
  expect(seen.protocols).toEqual([]);
  expect(seen.statuses).toEqual(['incompatible']);
  expect(backend.current.state).toBe('incompatible');
});

it('stops forwarding when a streamed snapshot changes protocol', async () => {
  const server = await runtimeSpeaking(1, 2);
  const backend = new Backend(false);
  const seen = observe(backend);
  void backend.watch();
  await new Promise((resolve) => setTimeout(resolve, 600));
  backend.stop();
  server.close();
  expect(seen.protocols).toEqual([1]);
  expect(seen.statuses.at(-1)).not.toBe('ready');
});

// The onboarding's Start on a paired Mac as the runtime receives it: the body the main process posts is what
// `/control/v1/actions` decodes. The provider's DesktopAppOnAPairedMacTests post this same JSON.
it('posts the onboarding’s paired start as JSON with no model and no local API', async () => {
  const posted: { method?: string; url?: string; type?: string; body: string }[] = [];
  const server = createServer((request, response) => {
    if (request.url === '/control/v1/state')
      return void response.end(
        JSON.stringify({ protocol: 1, models: [], machine: {}, observed_at: 0 }),
      );
    let body = '';
    request.on('data', (chunk) => (body += chunk));
    request.on('end', () => {
      const type = request.headers['content-type'];
      posted.push({ method: request.method, url: request.url, type, body });
      response.writeHead(202, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ id: 'x', action: 'start', state: 'running', started_at: 0 }));
    });
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
  await backend.connect();
  await backend.act(startAction(pairedMac(), 'manual', ['gpt-oss-20b']));
  server.close();
  expect(posted).toHaveLength(1);
  expect(posted[0]).toMatchObject({
    method: 'POST',
    url: '/control/v1/actions',
    type: 'application/json',
  });
  expect(posted[0].body).toMatch(
    /^\{"action":"start","models":\[\],"local":false,"id":"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"\}$/,
  );
});
