import { spawn } from 'node:child_process';
import { createServer } from 'vite';
import electron from 'electron';
await import('./build.mjs');
const server = await createServer();
await server.listen();
const app = spawn(electron, ['.'], {
  stdio: 'inherit',
  env: { ...process.env, DARKBLOOM_DEV_URL: 'http://127.0.0.1:4318' },
});
app.on('exit', async () => {
  await server.close();
  process.exit();
});
