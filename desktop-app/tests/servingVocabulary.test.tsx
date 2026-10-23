// @vitest-environment jsdom
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { BackendState } from '../src/renderer/useBackend';
import type { Snapshot } from '../src/shared/contracts';
import { operationLabel } from '../src/renderer/components/operations/labels';
import { trayMenuModel, trayMenuTemplate } from '../src/main/trayMenu';
import { previewAPI } from '../src/renderer/preview';

// One verb for putting this Mac to work, everywhere it is offered: Home, This Mac, the menu bar
// and progress labels all say "serving".

let Home: typeof import('../src/renderer/features/Home').Home;
let MachineHeader: typeof import('../src/renderer/features/machines/MachineHeader').MachineHeader;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ MachineHeader } = await import('../src/renderer/features/machines/MachineHeader'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(cleanup);

async function backendIn(state: Snapshot['state']): Promise<BackendState> {
  const backend = await previewBackend();
  return { ...backend, state: { ...backend.state!, state } };
}

it('offers Start serving and Stop serving on Home', async () => {
  const { rerender } = render(
    <Home backend={await backendIn('stopped')} navigate={vi.fn()} openMachine={vi.fn()} />,
  );
  expect(screen.getAllByRole('button', { name: 'Start serving' })[0]).toBeVisible();
  rerender(<Home backend={await backendIn('running')} navigate={vi.fn()} openMachine={vi.fn()} />);
  expect(screen.getByRole('button', { name: 'Stop serving' })).toBeVisible();
});

it('offers Start, Stop and Restart serving in This Mac’s header', async () => {
  const backend = await backendIn('stopped');
  const machine = backend.state!.machine;
  const { rerender } = render(
    <MachineHeader machine={machine} local backend={backend} navigate={vi.fn()} />,
  );
  expect(screen.getAllByRole('button', { name: 'Start serving' })[0]).toBeVisible();
  expect(screen.getByRole('button', { name: 'Restart serving' })).toHaveAttribute(
    'title',
    'Restart serving',
  );
  rerender(
    <MachineHeader
      machine={machine}
      local
      backend={await backendIn('running')}
      navigate={vi.fn()}
    />,
  );
  expect(screen.getByRole('button', { name: 'Stop serving' })).toBeVisible();
});

it('uses the same words in the menu bar', async () => {
  const state = await previewAPI.read<Snapshot>('state');
  const actions = { show: vi.fn(), start: vi.fn(), stop: vi.fn(), restart: vi.fn(), quit: vi.fn() };
  const labels = (snapshot: Snapshot | undefined) =>
    trayMenuTemplate(trayMenuModel(snapshot), actions).map((item) => item.label);
  expect(labels({ ...state, state: 'running', operations: [] })).toEqual([
    'Darkbloom — Serving',
    'Open Darkbloom',
    'Models',
    'Studio',
    'Earnings',
    undefined,
    'Start serving',
    'Stop serving',
    'Restart serving',
    undefined,
    'Quit Darkbloom',
  ]);
  expect(labels({ ...state, state: 'stopped' })[0]).toBe('Darkbloom — Stopped');
  expect(labels({ ...state, state: 'starting' })[0]).toBe('Darkbloom — Starting…');
  expect(labels({ ...state, state: 'draining' })[0]).toBe('Darkbloom — Finishing requests');
  expect(labels(undefined)[0]).toBe('Darkbloom — Connecting…');
});

it('names start, stop and restart operations after serving', () => {
  expect(operationLabel({ action: 'start', state: 'running' })).toBe('Starting to serve');
  expect(operationLabel({ action: 'stop', state: 'succeeded' })).toBe('Stop serving · Complete');
  expect(operationLabel({ action: 'restart', state: 'failed' })).toBe('Restart serving · Failed');
});

// The competing verbs the review found. "Provider" stays as the role noun (provider version,
// provider earnings), and "contribution" as the name of the session metrics.
const retired =
  /\b(?:start|stop|restart|starting|stopping|restarting)\s+(?:the\s+)?provider\b|\bproviding\b|\bcontribut(?:e|ing)\b/i;

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    return statSync(file).isDirectory() ? sources(file) : /\.tsx?$/.test(name) ? [file] : [];
  });
}

it('keeps the retired start and stop wording out of the app source', () => {
  const root = path.join(__dirname, '../src');
  const hits = sources(root).flatMap((file) =>
    readFileSync(file, 'utf8')
      .split('\n')
      .flatMap((line, i) =>
        retired.test(line) ? [`${path.relative(root, file)}:${i + 1}: ${line.trim()}`] : [],
      ),
  );
  expect(hits).toEqual([]);
});
