import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

// Electron keeps a `-webkit-app-region: drag` area (sidebar, top bar, onboarding strip) draggable
// under anything stacked above it unless the covering element declares `no-drag`. jsdom doesn't
// compute app regions, so this reads the stylesheets.
const renderer = fileURLToPath(new URL('../src/renderer', import.meta.url));
const stylesheets = (readdirSync(renderer, { recursive: true }) as string[])
  .filter((file) => file.endsWith('.css'))
  .map((file) => readFileSync(path.join(renderer, file), 'utf8'));
const rules = stylesheets.flatMap((css) =>
  [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(
    ([, selector, body]) => ({ selector: selector.trim(), body }),
  ),
);

it('lets clicks on full-window overlays reach them instead of dragging the window', () => {
  const overlays = rules.filter(
    ({ body }) => /position:\s*fixed;/.test(body) && /inset:\s*0;/.test(body),
  );
  expect(overlays.map(({ selector }) => selector)).toContain('.modal-backdrop');
  expect(
    overlays
      .filter(({ body }) => !/-webkit-app-region:\s*no-drag;/.test(body))
      .map(({ selector }) => selector),
  ).toEqual([]);
});
