import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';
await mkdir('public/fonts', { recursive: true });
await mkdir('public/brand', { recursive: true });
await mkdir('resources', { recursive: true });
for (const file of [
  'PPTelegraf-Regular.woff2',
  'PPTelegraf-Medium.woff2',
  'PPTelegraf-Semibold.woff2',
  'LICENSE.md',
])
  await copyFile(`../landing/public/fonts/${file}`, `public/fonts/${file}`);
await copyFile('../landing/public/logo.svg', 'public/brand/logo.svg');
await copyFile('../landing/public/favicon.svg', 'public/brand/mark.svg');
const css = await readFile('../landing/src/app/globals.css', 'utf8');
const tokens = ['black', 'ink', 'card', 'white', 'blue'].map((name) => {
  const value = css.match(new RegExp(`--${name}:\\s*(#[0-9a-f]+);`, 'i'))?.[1];
  if (!value) throw new Error(`Missing landing token: ${name}`);
  return `  --brand-${name}: ${value};`;
});
await writeFile(
  'src/renderer/brand.css',
  `/* Generated from the landing page. */\n:root {\n${tokens.join('\n')}\n}\n`,
);
const source = (await readFile('../landing/public/favicon.svg', 'utf8')).replaceAll(
  '#1456ff',
  '#ffffff',
);
const mark = await sharp(Buffer.from(source)).resize(420, 480, { fit: 'inside' }).png().toBuffer();
const background = Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect x="60" y="60" width="904" height="904" rx="205" fill="#0b41ff"/></svg>',
);
const png = await sharp(background)
  .composite([{ input: mark, gravity: 'centre' }])
  .png()
  .toBuffer();
await writeFile('resources/icon.png', png);
await sharp(Buffer.from(source.replaceAll('#ffffff', '#000000')))
  .resize(20, 22, { fit: 'inside' })
  .png()
  .toFile('resources/trayTemplate.png');
if (process.platform === 'darwin') {
  await mkdir('resources/icon.iconset', { recursive: true });
  for (const size of [16, 32, 128, 256, 512]) {
    await sharp(png).resize(size, size).toFile(`resources/icon.iconset/icon_${size}x${size}.png`);
    await sharp(png)
      .resize(size * 2, size * 2)
      .toFile(`resources/icon.iconset/icon_${size}x${size}@2x.png`);
  }
  execFileSync('/usr/bin/iconutil', [
    '-c',
    'icns',
    'resources/icon.iconset',
    '-o',
    'resources/icon.icns',
  ]);
}
