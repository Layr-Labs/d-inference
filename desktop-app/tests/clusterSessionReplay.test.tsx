// @vitest-environment jsdom
// The guided setup on the sessions the real desktop API streamed while the real
// `darkbloom cluster --app-console` ran, in a home of its own, to its clusters waitlist question
// and took No (`scripts/test-desktop-cluster-session.py --record`); and the answer the page sends
// back, which is the one the real API accepted for that question.
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { ClusterSession, ClusterStatus } from '../src/shared/cluster';
import recorded from './fixtures/cluster-session-waitlist-gate.json';

const bridge = vi.hoisted(() => ({
  read: vi.fn(),
  copy: vi.fn(async (_text: string) => {}),
  clusterSession: vi.fn(),
  startClusterSession: vi.fn(),
  answerClusterSession: vi.fn(),
  onClusterSession: vi.fn(),
}));
vi.mock('../src/renderer/useBackend', () => ({ api: bridge, isPreview: false }));

import { Cluster } from '../src/renderer/features/cluster/Cluster';
import { resetWaitlists } from '../src/renderer/features/waitlists/waitlistStore';
import { backendWith, snapshot } from './onboardingFixtures';

const frames = recorded as ClusterSession[];
const [started, asking, finished] = frames;

const notPaired: ClusterStatus = {
  schema: 1,
  paired: false,
  role: null,
  this_mac: null,
  other_mac: null,
  model: null,
  mode: null,
  split: null,
  serves: null,
  state: 'not_paired',
  reason: null,
  next: 'To set up a cluster: `darkbloom cluster` on each Mac.',
  lines: [],
  service: { running: false, starts_at_login: false },
  exit_code: 6,
};

let stream: ((session: ClusterSession) => void) | undefined;
beforeEach(() => {
  stream = undefined;
  bridge.read.mockImplementation(async (resource: string) =>
    resource === 'cluster' ? structuredClone(notPaired) : { data: [] },
  );
  bridge.onClusterSession.mockImplementation((callback: (session: ClusterSession) => void) => {
    stream = callback;
    return () => {
      stream = undefined;
    };
  });
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  resetWaitlists();
});

const push = (next: ClusterSession) => act(() => stream!(structuredClone(next)));

it('records a real run: the question, then the end with the CLI’s own lines', () => {
  expect(frames.map((frame) => [frame.state, !!frame.question])).toEqual([
    ['running', false],
    ['running', true],
    ['failed', false],
  ]);
  expect(asking.question).toMatchObject({
    type: 'choose',
    options: [['Yes'], ['No']],
    selected: 1,
  });
  expect(finished.exit_code).toBe(1);
});

it('asks the gate’s question as the app’s own list, and answers it as the real API took it', async () => {
  bridge.clusterSession.mockResolvedValue(structuredClone(started));
  bridge.answerClusterSession.mockResolvedValue({ ...structuredClone(asking), question: null });
  render(
    <Cluster
      backend={backendWith(
        snapshot({ capabilities: ['cluster', 'cluster_session', 'waitlists'], pair: null }),
      )}
      navigate={vi.fn()}
    />,
  );
  await waitFor(() => expect(stream).toBeDefined());
  expect(await screen.findByRole('region', { name: 'Cluster setup' })).toBeVisible();

  push(asking);
  expect(await screen.findByText('Join the Clusters waitlist now?')).toBeVisible();
  const no = screen.getByRole('button', { name: 'No' });
  const yes = screen.getByRole('button', { name: 'Yes' });
  // The setup's own default (No) is where the list starts.
  expect(no).toHaveAttribute('data-default');
  expect(yes).not.toHaveAttribute('data-default');
  fireEvent.click(no);
  await waitFor(() =>
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({
      question: asking.question!.id,
      choice: 1,
    }),
  );

  push(finished);
  const setup = screen.getByRole('region', { name: 'Cluster setup' });
  // The CLI's own lines, as it said them (they quote no command, so none is set as code).
  await waitFor(() =>
    expect(within(setup).getByText('Join it: darkbloom waitlist cluster')).toBeVisible(),
  );
  expect(
    within(setup).getByText(
      'Serving on your own Macs only needs no approval: darkbloom cluster local',
    ),
  ).toBeVisible();
  // A run that ended without success can run again, or be put away.
  expect(screen.getByRole('button', { name: 'Run again' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Done' })).toBeVisible();
});
