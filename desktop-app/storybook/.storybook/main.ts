import type { StorybookConfig } from '@storybook/react-vite';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import type { Plugin } from 'vite';
import remarkGfm from 'remark-gfm';

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

// Stories import the current app through `src/after/desktop-app/…`; that prefix is the live
// desktop app this Storybook lives in (no copy is kept). `src/before/` is a frozen snapshot of
// the base build the audit compared against.
const desktopApp = here('../..');
const afterPrefix = here('../src/after/desktop-app/');
const liveAfter: Plugin = {
  name: 'darkbloom-live-after',
  enforce: 'pre',
  async resolveId(source, importer, options) {
    if (!importer || !source.startsWith('.')) return null;
    const target = path.resolve(path.dirname(importer.split('?')[0]), source);
    if (!target.startsWith(afterPrefix)) return null;
    return this.resolve(path.join(desktopApp, target.slice(afterPrefix.length)), importer, {
      ...options,
      skipSelf: true,
    });
  },
};

// Each version's renderer reads its native bridge from its own useBackend module. Route those
// imports to small wrappers so Before and After each get a separate mock bridge and action log.
const beforeBackend = here('../src/before/desktop-app/src/renderer/useBackend.ts');
const afterBackend = path.join(desktopApp, 'src/renderer/useBackend.ts');
const versionBridges: Plugin = {
  name: 'darkbloom-version-bridges',
  enforce: 'pre',
  async resolveId(source, importer, options) {
    if (!importer || importer.includes('/stories/support/')) return null;
    const resolved = await this.resolve(source, importer, { ...options, skipSelf: true });
    if (resolved?.id === beforeBackend) return here('../stories/support/useBackend.before.ts');
    if (resolved?.id === afterBackend) return here('../stories/support/useBackend.after.ts');
    return null;
  },
};

const config: StorybookConfig = {
  framework: { name: '@storybook/react-vite', options: {} },
  stories: ['../stories/**/*.mdx', '../stories/**/*.stories.tsx'],
  addons: [
    {
      // GitHub-style tables in the Introduction.
      name: '@storybook/addon-docs',
      options: { mdxPluginOptions: { mdxCompileOptions: { remarkPlugins: [remarkGfm] } } },
    },
  ],
  staticDirs: ['../public'],
  core: { disableTelemetry: true },
  async viteFinal(config) {
    config.plugins = [liveAfter, versionBridges, ...(config.plugins ?? [])];
    config.resolve ??= {};
    const alias = config.resolve.alias;
    config.resolve.alias = [
      ...(Array.isArray(alias)
        ? alias
        : Object.entries(alias ?? {}).map(([find, replacement]) => ({ find, replacement }))),
      { find: /^vitest$/, replacement: here('../stories/support/vitestShim.ts') },
    ];
    config.resolve.dedupe = ['react', 'react-dom', 'lucide-react'];
    return config;
  },
};
export default config;
