import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The development preview reads these public, keyless endpoints same-origin: the rankings
// endpoint does not allow cross-origin reads (previewNetwork.ts).
const coordinator = { target: 'https://api.darkbloom.dev', changeOrigin: true };
const publicPaths = [
  '/v1/stats',
  '/v1/leaderboard',
  '/v1/releases/latest',
  '/v1/models/catalog',
  '/v1/models/capacity',
];

export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist/renderer', emptyOutDir: true },
  server: {
    host: '127.0.0.1',
    port: 4318,
    strictPort: true,
    watch: { ignored: ['**/release/**', '**/dist/**', '**/resources/**'] },
    proxy: Object.fromEntries(publicPaths.map((path) => [path, coordinator])),
  },
});
