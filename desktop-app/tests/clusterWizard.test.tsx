// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type {
  ClusterConsoleEvent,
  ClusterQuestion,
  ClusterSession,
  ClusterStatus,
} from '../src/shared/cluster';
import type { Waitlists } from '../src/shared/waitlists';

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
import { backendWith, snapshot } from './onboardingFixtures';

const notPaired: ClusterStatus = {
  schema: 1,
  paired: false,
  role: null,
  this_mac: 'Studio A',
  other_mac: null,
  model: null,
  mode: null,
  split: null,
  serves: null,
  state: 'not_paired',
  reason: null,
  next: null,
  lines: [],
  service: null,
  exit_code: 6,
};
const approved: Waitlists = {
  data: [{ feature: 'cluster', title: 'Clusters', status: 'approved' }],
};

const say = (text: string): ClusterConsoleEvent => ({ type: 'say', text: `  ${text}` });
const opening: ClusterConsoleEvent[] = [
  { type: 'banner', title: 'Darkbloom cluster', subtitle: '' },
  say('For a Mac with no display, open Screen Sharing to it first.'),
  { type: 'heading', text: '1/4 Connect' },
  say('Allow macOS permissions.'),
  say('✓ Cable ready'),
];
const session = (
  events: ClusterConsoleEvent[],
  question: ClusterQuestion | null = null,
  patch: Partial<ClusterSession> = {},
): ClusterSession => ({
  id: 'setup-1',
  kind: 'setup',
  state: 'running',
  started_at: 1_790_000_000,
  events: [...opening, ...events],
  question,
  ...patch,
});
const yesNo: ClusterQuestion = {
  id: 'code',
  type: 'choose',
  options: [['Yes'], ['No']],
  selected: 0,
};

let stream: ((session: ClusterSession) => void) | undefined;
beforeEach(() => {
  stream = undefined;
  bridge.read.mockImplementation(async (resource: string) =>
    resource === 'cluster' ? structuredClone(notPaired) : structuredClone(approved),
  );
  bridge.clusterSession.mockResolvedValue(null);
  bridge.onClusterSession.mockImplementation((callback: (session: ClusterSession) => void) => {
    stream = callback;
    return () => {
      stream = undefined;
    };
  });
  bridge.answerClusterSession.mockImplementation(async () => new Promise(() => {}));
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const backend = () =>
  backendWith(
    snapshot({
      capabilities: ['autopilot', 'cluster', 'cluster_session'],
      pair: null,
    }),
  );

async function open(current: ClusterSession | null = null) {
  bridge.clusterSession.mockResolvedValue(current);
  render(<Cluster backend={backend()} navigate={vi.fn()} />);
  await waitFor(() => expect(stream).toBeDefined());
}
const push = (next: ClusterSession) => act(() => stream!(next));

describe('restoring a setup', () => {
  it('shows a running session when the page opens', async () => {
    await open(
      session([
        { type: 'heading', text: '2/4 Pair' },
        say('Run `darkbloom cluster` on the other Mac.'),
      ]),
    );
    expect(
      await screen.findByRole('heading', { name: 'Darkbloom cluster', level: 1 }),
    ).toBeVisible();
    expect(screen.getByRole('img', { name: 'Step 2 of 4' })).toBeVisible();
    // The finished step folds to its title; the current one is open.
    expect(screen.getByText('Connect').closest('summary')).not.toBeNull();
    expect(screen.getByRole('heading', { name: 'Pair', level: 2 })).toBeVisible();
    const instruction = screen.getByText('darkbloom cluster').closest('p')!;
    expect(instruction).toHaveTextContent('Run darkbloom cluster on the other Mac.');
    fireEvent.click(screen.getByRole('button', { name: 'Copy darkbloom cluster' }));
    expect(bridge.copy).toHaveBeenCalledWith('darkbloom cluster');
  });

  it('leaves a session that ended before the page opened', async () => {
    await open(session([], null, { state: 'succeeded' }));
    expect(await screen.findByRole('heading', { name: 'Two Macs. One model.' })).toBeVisible();
    expect(screen.queryByRole('heading', { name: 'Darkbloom cluster' })).not.toBeInTheDocument();
  });

  it('takes the stream’s newer session over the first read', async () => {
    let answer!: (value: ClusterSession) => void;
    bridge.clusterSession.mockReturnValue(new Promise((resolve) => (answer = resolve)));
    render(<Cluster backend={backend()} navigate={vi.fn()} />);
    await waitFor(() => expect(stream).toBeDefined());
    push(session([{ type: 'heading', text: '3/4 Model' }]));
    await act(async () => answer(session([{ type: 'heading', text: '2/4 Pair' }])));
    expect(screen.getByRole('heading', { name: 'Model', level: 2 })).toBeVisible();
  });
});

describe('questions', () => {
  it('makes the pairing code and its question unmistakable', async () => {
    await open();
    push(
      session(
        [{ type: 'heading', text: '2/4 Pair' }, say('Code 482 913. Same on the other Mac?')],
        yesNo,
      ),
    );
    const code = await screen.findByLabelText('Pairing code 482913');
    expect(code).toHaveTextContent('482913');
    const question = screen.getByRole('region', { name: 'Same on the other Mac?' });
    expect(within(question).getByText('Pairing code')).toBeVisible();
    const yes = within(question).getByRole('button', { name: 'Yes' });
    await waitFor(() => expect(yes).toHaveFocus());
    fireEvent.click(yes);
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ question: 'code', choice: 0 });
  });

  it('moves through options with the arrow keys and takes one with Enter, from its default', async () => {
    await open();
    push(
      session([{ type: 'heading', text: '3/4 Model' }, say('How should this pair serve?')], {
        id: 'serve',
        type: 'choose',
        options: [
          ['Only me (this pair, local)', 'Darkbloom never contacts these Macs.'],
          ['Darkbloom network', 'The pair serves Darkbloom and earns while it runs.'],
          ['Both, me first', 'The pair serves Darkbloom while you aren’t using it.'],
        ],
        selected: 2,
      }),
    );
    const list = await screen.findByRole('list', { name: 'How should this pair serve?' });
    const [only, network, both] = within(list).getAllByRole('button');
    await waitFor(() => expect(both).toHaveFocus());
    expect(both).toHaveAttribute('tabindex', '0');
    expect(only).toHaveAttribute('tabindex', '-1');
    expect(both).toHaveAccessibleDescription(
      'The pair serves Darkbloom while you aren’t using it.',
    );
    fireEvent.keyDown(both, { key: 'ArrowDown' });
    expect(only).toHaveFocus();
    fireEvent.keyDown(only, { key: 'ArrowDown' });
    expect(network).toHaveFocus();
    fireEvent.keyDown(network, { key: 'End' });
    expect(both).toHaveFocus();
    fireEvent.keyDown(both, { key: 'ArrowUp' });
    expect(network).toHaveFocus();
    fireEvent.keyDown(network, { key: 'Enter' });
    expect(bridge.answerClusterSession).toHaveBeenCalledTimes(1);
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ question: 'serve', choice: 1 });
  });

  it('shows the split and state of each model as tags', async () => {
    await open();
    push(
      session([{ type: 'heading', text: '3/4 Model' }], {
        id: 'model',
        type: 'choose',
        options: [
          ['Qwen3.8-27B-4bit-mtp · 16.3 GB · tensor parallel · serving now'],
          ['Gemma 4 26B QAT · 15.6 GB · tensor parallel or pipeline · download'],
          ['MiMo-V2.6-Flash · 186.0 GB · speculative pipeline · does not fit now'],
        ],
        selected: 0,
      }),
    );
    const list = await screen.findByRole('list', { name: 'Model' });
    const [qwen, gemma, mimo] = within(list).getAllByRole('button');
    expect(within(qwen).getByText('tensor parallel')).toBeVisible();
    expect(within(qwen).getByText('serving now')).toBeVisible();
    expect(within(gemma).getByText('tensor parallel or pipeline')).toBeVisible();
    expect(gemma).toHaveAccessibleDescription('15.6 GB · download');
    expect(within(mimo).getByText('does not fit now')).toBeVisible();
  });

  it('labels key buttons from the setup’s keys and sends the key', async () => {
    await open();
    push(
      session(
        [
          { type: 'heading', text: '2/4 Pair' },
          { type: 'working', rows: ['Waiting for the other Mac (q cancels)'] },
        ],
        { id: 'wait', type: 'key', keys: [{ key: 'q', label: 'Stop waiting' }] },
      ),
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Stop waiting' }));
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ question: 'wait', key: 'q' });
  });

  it('says when an answer isn’t taken', async () => {
    bridge.answerClusterSession.mockRejectedValue(new Error('That question isn’t asked anymore.'));
    await open();
    push(
      session(
        [{ type: 'heading', text: '2/4 Pair' }, say('Code 482 913. Same on the other Mac?')],
        yesNo,
      ),
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Yes' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'That question isn’t asked anymore.',
    );
  });
});

describe('live work', () => {
  it('shows one row per Mac with its own spinner, and a bar for a percentage', async () => {
    await open();
    push(
      session([
        { type: 'heading', text: '4/4 Start' },
        {
          type: 'working',
          rows: ['This Mac: sending the model · 47%', 'The other Mac: receiving · 47%'],
        },
      ]),
    );
    await screen.findByText('This Mac: sending the model · 47%');
    const live = within(document.querySelector<HTMLElement>('[aria-live="polite"]')!).getAllByRole(
      'listitem',
    );
    expect(live).toHaveLength(2);
    for (const row of live) {
      expect(row.querySelector('svg.spin')).not.toBeNull();
      expect(within(row).getByRole('progressbar')).toHaveAttribute('aria-valuenow', '47');
    }
    push(
      session([
        { type: 'heading', text: '4/4 Start' },
        {
          type: 'progress',
          text: 'Downloading Gemma 4 26B  31%  4.8 GB of 15.6 GB  455 MB/s  24 s left',
        },
      ]),
    );
    const bar = await screen.findByRole('progressbar', { name: 'Downloading Gemma 4 26B' });
    expect(bar).toHaveAttribute('aria-valuenow', '31');
    expect(screen.getByText('31% · 4.8 GB of 15.6 GB · 455 MB/s · 24 s left')).toBeVisible();
  });

  it('shows a step that needs Terminal with its command', async () => {
    await open();
    push(
      session([
        { type: 'heading', text: '1/4 Connect' },
        { type: 'needs_terminal', text: 'Run `sudo darkbloom cluster link --fix` in Terminal.' },
      ]),
    );
    const alert = await screen.findByRole('alert');
    expect(within(alert).getByText('sudo darkbloom cluster link --fix').tagName).toBe('CODE');
    expect(
      within(alert).getByRole('button', { name: 'Copy sudo darkbloom cluster link --fix' }),
    ).toBeVisible();
  });
});

describe('cancel', () => {
  it('cancels at once outside a pairing, and the page comes back when it ends', async () => {
    bridge.answerClusterSession.mockImplementation(async () =>
      session([], null, { state: 'cancelled' }),
    );
    await open(session([say('Allow macOS permissions.')]));
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ cancel: true });
    expect(await screen.findByRole('heading', { name: 'Two Macs. One model.' })).toBeVisible();
  });

  it('asks first while a pairing is in progress', async () => {
    await open(
      session(
        [{ type: 'heading', text: '2/4 Pair' }, say('Code 482 913. Same on the other Mac?')],
        yesNo,
      ),
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    let dialog = screen.getByRole('dialog', { name: 'Stop pairing?' });
    expect(dialog).toHaveTextContent('The Macs won’t be paired.');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Keep pairing' }));
    expect(bridge.answerClusterSession).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    dialog = screen.getByRole('dialog', { name: 'Stop pairing?' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Stop pairing' }));
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ cancel: true });
  });

  it('doesn’t ask once the Macs are paired', async () => {
    await open(session([{ type: 'heading', text: '2/4 Pair' }, say('✓ Paired. This Mac leads.')]));
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(bridge.answerClusterSession).toHaveBeenCalledWith({ cancel: true });
  });
});

describe('the outcome', () => {
  const served: ClusterConsoleEvent[] = [
    { type: 'heading', text: '4/4 Start' },
    {
      type: 'result',
      ok: true,
      title: 'Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (tensor parallel)',
      lines: ['  Test response in 0.61 s'],
    },
    say('Serves:  through Darkbloom'),
    say('darkbloom stop     Stop both Macs'),
  ];

  it('shows ✓ with the pair’s card until Done, then the status read again', async () => {
    await open(session([{ type: 'heading', text: '3/4 Model' }]));
    const reads = bridge.read.mock.calls.filter(([resource]) => resource === 'cluster').length;
    push(session(served, null, { state: 'succeeded', exit_code: 0 }));
    const outcome = await screen.findByRole('status');
    expect(outcome).toHaveTextContent(
      'Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (tensor parallel)',
    );
    expect(within(outcome).getByRole('img', { name: 'Done' })).toBeVisible();
    expect(screen.getByText('Serves').tagName).toBe('DT');
    expect(screen.getByText('darkbloom stop').tagName).toBe('CODE');
    expect(screen.queryByRole('button', { name: 'Cancel' })).not.toBeInTheDocument();
    await waitFor(() =>
      expect(bridge.read.mock.calls.filter(([resource]) => resource === 'cluster').length).toBe(
        reads + 1,
      ),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(await screen.findByRole('heading', { name: 'Two Macs. One model.' })).toBeVisible();
  });

  it('offers Run again after ✗', async () => {
    bridge.startClusterSession.mockReturnValue(new Promise(() => {}));
    await open(session([{ type: 'heading', text: '4/4 Start' }], null, { kind: 'local' }));
    push(
      session(
        [
          { type: 'heading', text: '4/4 Start' },
          { type: 'result', ok: false, title: 'Not serving: the test failed', lines: [] },
        ],
        null,
        { state: 'failed', exit_code: 1, kind: 'local' },
      ),
    );
    expect(await screen.findByRole('img', { name: 'Failed' })).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Run again' }));
    expect(bridge.startClusterSession).toHaveBeenCalledWith({ kind: 'local' });
  });

  it('says why a session couldn’t start', async () => {
    bridge.startClusterSession.mockResolvedValue(
      session([], null, {
        state: 'failed',
        events: [],
        error: 'Another cluster command is running.',
      }),
    );
    await open();
    fireEvent.click(await screen.findByRole('button', { name: 'Serve on my own Macs only' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Another cluster command is running.',
    );
    expect(screen.getByRole('button', { name: 'Done' })).toBeVisible();
  });
});
