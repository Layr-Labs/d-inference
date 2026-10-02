import { afterEach, beforeEach, expect, it } from 'vitest';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Backend } from '../src/main/backend';

// A real (unsigned) runtime executable in an isolated HOME. It records every
// `update` invocation so the test observes what install() actually executed.
let home: string;
const saved = { HOME: process.env.HOME, CLI: process.env.DARKBLOOM_CLI_PATH };
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
  if (saved.CLI === undefined) delete process.env.DARKBLOOM_CLI_PATH;
  else process.env.DARKBLOOM_CLI_PATH = saved.CLI;
  await rm(home, { recursive: true, force: true });
});

it('refuses to run an existing runtime that fails the packaged code requirement', async () => {
  const backend = new Backend(true);
  await expect(backend.install(path.join(home, 'unused-install.sh'))).rejects.toThrow(
    'Runtime installation failed',
  );
  expect(existsSync(path.join(home, 'update-ran'))).toBe(false);
  expect(backend.current.state).toBe('error');
});

it('runs the existing runtime update without the signature gate in development', async () => {
  process.env.DARKBLOOM_CLI_PATH = path.join(home, '.darkbloom/bin/darkbloom');
  const backend = new Backend(false);
  await backend.install(path.join(home, 'unused-install.sh'));
  expect(existsSync(path.join(home, 'update-ran'))).toBe(true);
});
