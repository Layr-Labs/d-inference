import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The development preview reads these public endpoints same-origin: the rankings endpoint does
// not allow cross-origin reads.
const coordinator = { target: 'https://api.darkbloom.dev', changeOrigin: true };

export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist/renderer', emptyOutDir: true },
  server: {
    host: '127.0.0.1',
    port: 4318,
    strictPort: true,
    watch: { ignored: ['**/release/**', '**/dist/**', '**/resources/**'] },
    proxy: { '/v1/stats': coordinator, '/v1/leaderboard': coordinator },
  },
});
