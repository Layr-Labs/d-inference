// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { ClusterStatus } from '../src/shared/cluster';
import type { Snapshot } from '../src/shared/contracts';
import type { Waitlists } from '../src/shared/waitlists';

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
import { PairCard } from '../src/renderer/features/cluster/PairCard';
import { backendWith, pairedMac, snapshot } from './onboardingFixtures';

const guided = ['account-signin', 'request-history', 'cluster', 'cluster_session'];

const serving: ClusterStatus = {
  schema: 1,
  paired: true,
  role: 'leader',
  this_mac: 'Studio A',
  other_mac: { name: 'Apple M5 Max, 128 GB', answers: true },
  model: { id: 'mlx-community/Qwen3.8-27B-4bit-mtp', name: 'Qwen 3.8 27B' },
  mode: 'tensor parallel',
  split: 'M3 Ultra 50% / M5 Max 50%',
  serves: 'darkbloom',
  state: 'serving',
  reason: null,
  next: null,
  lines: [
    'Cluster: this Mac (Studio A) leads · the other Mac (Apple M5 Max, 128 GB) follows',
    'Serves: through Darkbloom, and on its local API with you first',
    'Local API: http://127.0.0.1:8001/v1 on this Mac (`darkbloom local` shows the key)',
  ],
  service: { running: true, starts_at_login: true },
  exit_code: 0,
};
const notPaired: ClusterStatus = {
  ...serving,
  paired: false,
  role: null,
  other_mac: null,
  model: null,
  mode: null,
  split: null,
  serves: null,
  state: 'not_paired',
  lines: ['This Mac isn’t in a two-Mac cluster.'],
  service: null,
  exit_code: 6,
};
const approved: Waitlists = {
  data: [
    {
      feature: 'cluster',
      title: 'Clusters',
      summary: 'Serve one model with two to four of your Macs.',
      status: 'approved',
    },
  ],
};

let cluster: ClusterStatus | Promise<ClusterStatus>;
let waitlists: Waitlists;
beforeEach(() => {
  cluster = serving;
  waitlists = approved;
  bridge.read.mockImplementation(async (resource: string) => {
    if (resource === 'cluster') return structuredClone(await cluster);
    if (resource === 'waitlists') return structuredClone(waitlists);
    throw new Error(`No fixture for ${resource}`);
  });
  bridge.clusterSession.mockResolvedValue(null);
  bridge.onClusterSession.mockImplementation(() => () => {});
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const paired = (patch: Partial<NonNullable<Snapshot['pair']>> = {}, capabilities = guided) =>
  ({ ...pairedMac({ state: 'serving', ...patch }), capabilities }) as Snapshot;
const alone = (capabilities = [...guided, 'autopilot']) =>
  snapshot({ capabilities, pair: null }) as Snapshot;

function show(state: Snapshot, status: ClusterStatus = serving) {
  cluster = status;
  const backend = backendWith(state);
  render(<Cluster backend={backend} navigate={vi.fn()} />);
  return backend;
}

describe('a runtime without clusters', () => {
  it('says it needs a newer CLI and reads nothing', async () => {
    const navigate = vi.fn();
    render(
      <Cluster
        backend={backendWith(snapshot({ capabilities: ['autopilot'] }))}
        navigate={navigate}
      />,
    );
    expect(screen.getByText(/Clusters need a newer Darkbloom CLI\./)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Updates' }));
    expect(navigate).toHaveBeenCalledWith('updates');
    expect(bridge.read).not.toHaveBeenCalledWith('cluster');
    expect(bridge.clusterSession).not.toHaveBeenCalled();
  });

  it('treats a runtime that lists no capabilities as one from before clusters', () => {
    render(<Cluster backend={backendWith(snapshot())} navigate={vi.fn()} />);
    expect(screen.getByText(/needs? a newer Darkbloom CLI/)).toBeVisible();
  });
});

describe('a Mac in no pair', () => {
  it('offers both ways to start once the account may pair', async () => {
    bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
    show(alone(), notPaired);
    expect(await screen.findByRole('heading', { name: 'Two Macs. One model.' })).toBeVisible();
    const needs = screen.getByRole('list', { name: 'What you need' });
    expect(
      within(needs)
        .getAllByRole('listitem')
        .map((item) => item.textContent),
    ).toEqual(['Two Apple silicon Macs', 'A Thunderbolt cable', 'Darkbloom on both']);
    const setUp = await screen.findByRole('button', { name: /Set up a pair/ });
    await waitFor(() => expect(setUp).toBeEnabled());
    expect(await screen.findByText('Approved.')).toBeVisible();
    fireEvent.click(setUp);
    expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'setup' });
  });

  it('serves your own Macs without approval, and keeps Set up a pair until approved', async () => {
    waitlists = { data: [{ ...approved.data[0], status: 'waitlisted', position: 7 }] };
    bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
    show(alone(), notPaired);
    expect(await screen.findByText('#7 in line.')).toBeVisible();
    expect(screen.queryByRole('button', { name: /Set up a pair/ })).not.toBeInTheDocument();
    expect(screen.getByText('Serving on your own Macs only needs no approval.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Serve on my own Macs only' }));
    expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'local' });
  });

  it('offers Set up a pair on a coordinator with no cluster waitlist', async () => {
    waitlists = { data: [], error: 'This coordinator has no waitlists.', code: 'none' };
    show(alone(), notPaired);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Set up a pair/ })).toBeEnabled(),
    );
  });

  it('says why the setup didn’t start', async () => {
    bridge.startClusterSession.mockRejectedValue(
      new Error("Error invoking remote method 'cluster:session-start': Error: A setup is running."),
    );
    show(alone(), notPaired);
    fireEvent.click(await screen.findByRole('button', { name: 'Serve on my own Macs only' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('A setup is running.');
  });

  it('points to Terminal when this runtime has no in-app setup', async () => {
    show(alone(['autopilot', 'cluster']), notPaired);
    expect(await screen.findByText('Run on each Mac in Terminal:')).toBeVisible();
    expect(screen.queryByRole('button', { name: /Set up a pair/ })).not.toBeInTheDocument();
    await screen.findByRole('button', { name: 'Copy darkbloom cluster' });
    fireEvent.click(screen.getByRole('button', { name: 'Copy darkbloom cluster local' }));
    expect(bridge.copy).toHaveBeenCalledWith('darkbloom cluster local');
    expect(
      await screen.findByRole('button', { name: 'Copied darkbloom cluster local' }),
    ).toBeVisible();
    expect(bridge.clusterSession).not.toHaveBeenCalled();
  });
});

describe('a paired Mac', () => {
  it('shows both Macs, the model with its split, how it serves and the service', async () => {
    show(paired());
    expect(await screen.findByRole('heading', { name: /Qwen 3\.8 27B/ })).toBeVisible();
    const pair = screen.getByRole('region', { name: 'Pair' });
    expect(within(pair).getByText('Serving')).toBeVisible();
    expect(within(pair).getByText('tensor parallel')).toBeVisible();
    expect(within(pair).getByText('Studio A')).toBeVisible();
    expect(within(pair).getByText('Apple M5 Max, 128 GB')).toBeVisible();
    expect(within(pair).getByText('Leads')).toBeVisible();
    expect(within(pair).getByText('Follows')).toBeVisible();
    expect(within(pair).getByText(/Answers/)).toBeVisible();
    const split = within(pair).getByRole('list', { name: 'Split' });
    expect(
      within(split)
        .getAllByRole('listitem')
        .map((item) => item.textContent),
    ).toEqual(['M3 Ultra 50%', 'M5 Max 50%']);
    expect(screen.getByText('Both, me first')).toBeVisible();
    expect(screen.getByText(/Running · Starts at login/)).toBeVisible();
    for (const name of [
      'Stop serving',
      'Restart serving',
      'Change model or how it serves',
      'Serve this Mac alone',
      'Leave the pair',
    ])
      expect(screen.getByRole('button', { name: new RegExp(name) })).toBeEnabled();
    expect(screen.queryByRole('button', { name: /Start serving/ })).not.toBeInTheDocument();
  });

  it('says the runtime’s reason and next step as they are, commands in code', async () => {
    show(paired({ state: 'started' }), {
      ...serving,
      state: 'not_serving',
      reason: 'Not offered to Darkbloom (no cluster approval is attached to its setup)',
      next: 'To offer it to Darkbloom: `darkbloom cluster` on this Mac, then choose the model again.',
      exit_code: 3,
    });
    expect(
      await screen.findByText(
        'Not offered to Darkbloom (no cluster approval is attached to its setup)',
      ),
    ).toBeVisible();
    const next = screen.getByText(/To offer it to Darkbloom:/);
    expect(within(next).getByText('darkbloom cluster').tagName).toBe('CODE');
    expect(screen.getByText('Not serving')).toBeVisible();
  });

  it('starts a stopped pair and waits for it, then reads the status again', async () => {
    const backend = show(paired({ state: 'stopped' }), {
      ...serving,
      state: 'stopped',
      next: '`darkbloom start` starts the pair again.',
      exit_code: 4,
    });
    const start = await screen.findByRole('button', { name: /Start serving/ });
    expect(start).toHaveClass('primary');
    expect(screen.queryByRole('button', { name: /Stop serving/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Restart serving/ })).not.toBeInTheDocument();
    const reads = bridge.read.mock.calls.filter(([resource]) => resource === 'cluster').length;
    fireEvent.click(start);
    expect(backend.act).toHaveBeenCalledWith({ action: 'start', models: [] }, true);
    await waitFor(() =>
      expect(bridge.read.mock.calls.filter(([resource]) => resource === 'cluster').length).toBe(
        reads + 1,
      ),
    );
  });

  it('stops and restarts the pair', async () => {
    const backend = show(paired());
    fireEvent.click(await screen.findByRole('button', { name: /Stop serving/ }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'stop' }, true);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Restart serving/ })).toBeEnabled(),
    );
    fireEvent.click(screen.getByRole('button', { name: /Restart serving/ }));
    expect(backend.act).toHaveBeenLastCalledWith({ action: 'restart' }, true);
  });

  it('asks before serving this Mac alone, and says the pair stops serving', async () => {
    const backend = show(paired());
    fireEvent.click(await screen.findByRole('button', { name: /Serve this Mac alone/ }));
    let dialog = screen.getByRole('dialog', { name: 'Serve this Mac alone?' });
    expect(dialog).toHaveTextContent('The pair stops serving.');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    expect(backend.act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /Serve this Mac alone/ }));
    dialog = screen.getByRole('dialog', { name: 'Serve this Mac alone?' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Serve this Mac alone' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'start', models: [], solo: true }, true);
  });

  it('asks before leaving, in the CLI’s words', async () => {
    const backend = show(paired());
    fireEvent.click(await screen.findByRole('button', { name: /Leave the pair/ }));
    const dialog = screen.getByRole('dialog', { name: 'Leave the pair?' });
    expect(dialog).toHaveTextContent(
      'Leaving stops the pair (on both Macs while the other Mac answers) and this Mac’s cluster service, and forgets this Mac’s pairing. The other Mac keeps its own pairing until it leaves too.',
    );
    fireEvent.click(within(dialog).getByRole('button', { name: 'Leave the pair' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'cluster_leave' }, true);
  });

  it('changes the model through the guided setup on the Mac that leads', async () => {
    bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
    show(paired());
    fireEvent.click(await screen.findByRole('button', { name: /Change model or how it serves/ }));
    expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'setup' });
  });

  it('says the other Mac chooses the model on the Mac that follows', async () => {
    show(paired({ leads: false, state: 'started' }), {
      ...serving,
      role: 'member',
      this_mac: 'Studio B',
      other_mac: { name: 'Apple M3 Ultra, 256 GB', answers: true },
    });
    expect(await screen.findByText('The other Mac leads: choose the model there.')).toBeVisible();
    expect(
      screen.queryByRole('button', { name: /Change model or how it serves/ }),
    ).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Stop serving/ })).toBeEnabled();
  });

  it('names the Terminal step when this runtime has no in-app setup', async () => {
    show(paired({}, ['cluster']));
    expect(await screen.findByText('Change the model in Terminal:')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Copy darkbloom cluster' })).toBeVisible();
  });

  it('shows the other Mac away and what to do', async () => {
    show(paired({ state: 'not_running' }), {
      ...serving,
      state: 'other_mac_away',
      other_mac: { name: 'Apple M5 Max, 128 GB', answers: false },
      reason: 'The other Mac (Apple M5 Max, 128 GB) isn’t answering over the cable',
      next: 'Or serve this Mac alone: `darkbloom start --solo`.',
      exit_code: 5,
    });
    expect(await screen.findByText('Not answering')).toBeVisible();
    expect(screen.getByText('Other Mac away')).toBeVisible();
    expect(screen.getByText('darkbloom start --solo').tagName).toBe('CODE');
    expect(screen.getByRole('button', { name: /Stop serving/ })).toBeEnabled();
  });

  it('shows a pair that is loading', async () => {
    show(paired({ state: 'started' }), {
      ...serving,
      state: 'loading',
      reason: 'The pair is not serving yet: checking both Macs with Apple',
      exit_code: 3,
    });
    expect(await screen.findByText('Loading')).toBeVisible();
    expect(screen.getByRole('button', { name: /Stop serving/ })).toBeEnabled();
    expect(screen.queryByRole('button', { name: /Restart serving/ })).not.toBeInTheDocument();
  });

  it('checks an unreadable pairing record with the setup, and offers nothing it refuses', async () => {
    bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
    show(paired({ state: 'unreadable', model: null, leads: null }), {
      ...notPaired,
      paired: null,
      state: 'pairing_unreadable',
      reason: 'This Mac’s pairing record couldn’t be read (pairings.json is malformed).',
      next: 'Run `darkbloom cluster` on this Mac to check it.',
      service: { running: false, starts_at_login: false },
      exit_code: 7,
    });
    expect(await screen.findByText('Pairing unreadable')).toBeVisible();
    expect(screen.getByText(/pairings\.json is malformed/)).toBeVisible();
    for (const name of [/Start serving/, /Stop serving/, /Restart serving/, /Leave the pair/])
      expect(screen.queryByRole('button', { name })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Serve this Mac alone/ })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: /Check the pairing/ }));
    expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'setup' });
  });

  it('reads an unknown state from a newer runtime as unknown, with its own words', async () => {
    show(paired(), {
      ...serving,
      state: 'resting' as ClusterStatus['state'],
      reason: 'A newer reason.',
    });
    expect(await screen.findByText('Unknown')).toBeVisible();
    expect(screen.getByText('A newer reason.')).toBeVisible();
  });

  it('says when the status can’t be read, and reads it again on Refresh', async () => {
    show(paired(), { ...notPaired, state: 'unknown', error: 'The leading Mac didn’t answer.' });
    expect(await screen.findByText('Couldn’t read the pair.')).toBeVisible();
    expect(screen.getByText('The leading Mac didn’t answer.')).toBeVisible();
    cluster = serving;
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    expect(await screen.findByRole('heading', { name: /Qwen 3\.8 27B/ })).toBeVisible();
    expect(screen.queryByText('Couldn’t read the pair.')).not.toBeInTheDocument();
  });

  it('names the pair from the snapshot while the status loads', async () => {
    show(paired(), serving);
    cluster = new Promise(() => {});
    cleanup();
    render(<Cluster backend={backendWith(paired())} navigate={vi.fn()} />);
    expect(await screen.findByText('Reading the pair…')).toBeVisible();
    expect(screen.getByText('Qwen 3.8 27B')).toBeVisible();
  });
});

describe('the pair on This Mac’s overview', () => {
  it('says the pair in one line and opens Clusters', () => {
    const open = vi.fn();
    render(
      <PairCard pair={{ model: 'Qwen 3.8 27B', state: 'serving', leads: true }} onOpen={open} />,
    );
    expect(screen.getByRole('region', { name: 'Pair' })).toHaveTextContent(
      'In a pairQwen 3.8 27B · Serving · This Mac leads',
    );
    fireEvent.click(screen.getByRole('button', { name: /Clusters/ }));
    expect(open).toHaveBeenCalled();
    cleanup();
    render(<PairCard pair={{ model: null, state: 'unreadable', leads: null }} onOpen={open} />);
    expect(screen.getByRole('region', { name: 'Pair' })).toHaveTextContent('Pairing unreadable');
  });
});
