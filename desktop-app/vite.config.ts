import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist/renderer', emptyOutDir: true },
  server: {
    host: '127.0.0.1',
    port: 4318,
    strictPort: true,
    watch: { ignored: ['**/release/**', '**/dist/**', '**/resources/**'] },
  },
});
