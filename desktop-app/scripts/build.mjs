import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
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
  });
await mkdir('resources', { recursive: true });
await copyFile('../scripts/install.sh', 'resources/install-runtime.sh');

await copyFile('resources/trayTemplate.png', 'dist/trayTemplate.png');
