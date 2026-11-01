import { execFileSync } from 'node:child_process';
import { cp, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const desktop = path.join(root, 'desktop-app');
const identity = process.env.CSC_NAME;
const team = process.env.DARKBLOOM_PREVIEW_TEAM_ID;
if (!identity || !team || !/^[A-Z0-9]{10}$/.test(team))
  throw new Error(
    'Set CSC_NAME to your Developer ID identity and DARKBLOOM_PREVIEW_TEAM_ID to its Apple team ID.',
  );
const run = (command, args, options = {}) =>
  execFileSync(command, args, { cwd: desktop, stdio: 'inherit', ...options });
run('swift', [
  'build',
  '--package-path',
  path.join(root, 'provider-swift'),
  '--product',
  'darkbloom',
  '-j',
  '8',
]);
const build = path.join(root, 'provider-swift/.build/debug');
const stage = await mkdtemp(path.join(tmpdir(), 'darkbloom-preview-'));
try {
  await cp(path.join(build, 'darkbloom'), path.join(stage, 'darkbloom'));
  for (const name of await readdir(build))
    if (name.endsWith('.bundle'))
      await cp(path.join(build, name), path.join(stage, name), { recursive: true });
  run('/usr/bin/codesign', [
    '--force',
    '--sign',
    identity,
    '--options',
    'runtime',
    '--timestamp',
    '--identifier',
    'io.darkbloom.desktop.preview.runtime',
    path.join(stage, 'darkbloom'),
  ]);
  run('/usr/bin/codesign', [
    '--verify',
    '--strict',
    `-R=anchor apple generic and identifier "io.darkbloom.desktop.preview.runtime" and certificate leaf[subject.OU] = "${team}"`,
    path.join(stage, 'darkbloom'),
  ]);
  run('npm', ['run', 'dist'], { env: { ...process.env, DARKBLOOM_PREVIEW_RUNTIME: stage } });
} finally {
  await rm(stage, { recursive: true, force: true });
}
