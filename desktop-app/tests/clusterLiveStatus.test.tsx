// @vitest-environment jsdom
// The Clusters page on `cluster status --json` exactly as a live, serving pair printed it
// (two M5 Ultras serving Qwen 3.8 27B in tensor parallel through Darkbloom; only this Mac's own
// name is replaced), and the actions it posts there.
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { ClusterStatus } from '../src/shared/cluster';
import type { Snapshot } from '../src/shared/contracts';
import live from './fixtures/cluster-status-live-serving.json';

const bridge = vi.hoisted(() => ({
  read: vi.fn(),
  copy: vi.fn(async (_text: string) => {}),
  clusterSession: vi.fn(async () => null),
  startClusterSession: vi.fn(),
  answerClusterSession: vi.fn(),
  onClusterSession: vi.fn((_callback: unknown) => () => {}),
}));
vi.mock('../src/renderer/useBackend', () => ({ api: bridge, isPreview: false }));

import { Cluster } from '../src/renderer/features/cluster/Cluster';
import { resetWaitlists } from '../src/renderer/features/waitlists/waitlistStore';
import { backendWith, pairedMac } from './onboardingFixtures';

const status = live as ClusterStatus;
// What the same Mac's snapshot says about its pair (`DesktopBackend.pairSnapshot`).
const state = {
  ...pairedMac({ model: 'Qwen 3.8 27B', state: 'serving', leads: true }),
  capabilities: ['account-signin', 'request-history', 'waitlists', 'cluster', 'cluster_session'],
} as Snapshot;

beforeEach(() => {
  bridge.read.mockImplementation(async (resource: string) => {
    if (resource === 'cluster') return structuredClone(status);
    if (resource === 'waitlists') return { data: [] };
    throw new Error(`No fixture for ${resource}`);
  });
  bridge.clusterSession.mockResolvedValue(null);
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  resetWaitlists();
});

function show() {
  const backend = backendWith(state);
  render(<Cluster backend={backend} navigate={vi.fn()} />);
  return backend;
}

it('reads the live document as the CLI printed it', () => {
  expect(status).toMatchObject({
    schema: 1,
    paired: true,
    role: 'leader',
    state: 'serving',
    serves: 'darkbloom',
    mode: 'tensor parallel',
    model: { id: 'EigenLabs/Qwen3.8-27B-4bit-mtp', name: 'Qwen 3.8 27B' },
    other_mac: { name: 'Apple M5 Ultra, 256 GB', answers: true },
    service: { running: true, starts_at_login: true },
    exit_code: 0,
  });
});

it('shows both Macs, the model and how it serves', async () => {
  show();
  // A placeholder says "Reading the pair…" until the document arrives.
  await screen.findByText('Apple M5 Ultra, 256 GB / Apple M5 Ultra, 256 GB');
  const pair = screen.getByRole('region', { name: 'Pair' });
  expect(pair).toHaveTextContent('Mac Studio');
  expect(pair).toHaveTextContent('Apple M5 Ultra, 256 GB');
  expect(pair).toHaveTextContent('Leads');
  expect(pair).toHaveTextContent('Follows');
  expect(pair).toHaveTextContent('Answers');
  expect(pair).toHaveTextContent('Qwen 3.8 27B');
  expect(pair).toHaveTextContent('tensor parallel');
  // This runtime's split names the Macs without shares: it is said as it is, not as a bar.
  expect(pair).toHaveTextContent('Apple M5 Ultra, 256 GB / Apple M5 Ultra, 256 GB');
  expect(screen.getByText('Serving')).toBeVisible();
});

it('offers the serving actions of a serving pair on the Mac that leads', async () => {
  const backend = show();
  const stop = await screen.findByRole('button', { name: /Stop serving/ });
  expect(screen.getByRole('button', { name: /Restart serving/ })).toBeEnabled();
  expect(screen.getByRole('button', { name: /Change model or how it serves/ })).toBeEnabled();
  expect(screen.queryByRole('button', { name: /^Start serving/ })).toBeNull();
  fireEvent.click(stop);
  expect(backend.act).toHaveBeenCalledWith({ action: 'stop' }, true);
  await waitFor(() =>
    expect(screen.getByRole('button', { name: /Restart serving/ })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole('button', { name: /Restart serving/ }));
  expect(backend.act).toHaveBeenLastCalledWith({ action: 'restart' }, true);
});

it('opens the guided setup to change the model, on the Mac that leads', async () => {
  bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
  show();
  fireEvent.click(await screen.findByRole('button', { name: /Change model or how it serves/ }));
  await waitFor(() => expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'setup' }));
});

it('says the runtime’s next step with its command', async () => {
  show();
  const code = await screen.findByText('darkbloom cluster');
  expect(code.tagName).toBe('CODE');
  expect(within(code.parentElement!).getByText(/To stop or change it/)).toBeVisible();
});
