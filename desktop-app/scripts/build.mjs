import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
const previewTeam = process.env.DARKBLOOM_PREVIEW_TEAM_ID || '';
if (previewTeam && !/^[A-Z0-9]{10}$/.test(previewTeam))
  throw new Error('DARKBLOOM_PREVIEW_TEAM_ID must be a ten-character Apple team ID');
if (!!previewTeam !== !!process.env.DARKBLOOM_PREVIEW_RUNTIME)
  throw new Error(
    'Set both DARKBLOOM_PREVIEW_TEAM_ID and DARKBLOOM_PREVIEW_RUNTIME for a local preview',
  );
await mkdir('dist', { recursive: true });
for (const name of ['main', 'preload'])
  await build({
    entryPoints: [`src/${name}/index.ts`],
    outfile: `dist/${name}.cjs`,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node22',
    external: ['electron', 'electron-updater'],
    define: { __DARKBLOOM_PREVIEW_TEAM__: JSON.stringify(previewTeam) },
  });
await mkdir('resources', { recursive: true });
await copyFile('../scripts/install.sh', 'resources/install-runtime.sh');

await copyFile('resources/trayTemplate.png', 'dist/trayTemplate.png');
await copyFile('resources/trayTemplate@2x.png', 'dist/trayTemplate@2x.png');
