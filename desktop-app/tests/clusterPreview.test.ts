// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ClusterSession, ClusterStatus } from '../src/shared/cluster';
import type { Action, Snapshot } from '../src/shared/contracts';
import { snapshot } from './onboardingFixtures';

// Each preview module reads its query once, when it loads.
async function load(query = '') {
  vi.resetModules();
  window.history.replaceState({}, '', `/?preview${query}`);
  const session = await import('../src/renderer/preview/clusterSession');
  const cluster = await import('../src/renderer/preview/cluster');
  return { ...cluster, ...session };
}

afterEach(() => {
  vi.useRealTimers();
  window.history.replaceState({}, '', '/');
});

const base = () => snapshot({ capabilities: ['autopilot', 'waitlist', 'waitlists'] });

describe('status fixtures', () => {
  it.each([
    ['not_paired', 'not_paired', 6, null],
    ['serving', 'serving', 0, { model: 'Qwen 3.8 27B', state: 'serving', leads: true }],
    ['loading', 'loading', 3, { state: 'started' }],
    ['not_serving', 'not_serving', 3, { state: 'started' }],
    ['stopped', 'stopped', 4, { state: 'stopped' }],
    ['away', 'other_mac_away', 5, { state: 'not_running' }],
    ['unreadable', 'pairing_unreadable', 7, { model: null, state: 'unreadable', leads: null }],
  ])(
    '&cluster=%s reads %s (exit %i) and names the pair in the snapshot',
    async (query, state, exit, pair) => {
      const { previewClusterStatus, clusterPreview } = await load(`&cluster=${query}`);
      const status = previewClusterStatus();
      expect(status).toMatchObject({ schema: 1, state, exit_code: exit });
      // Every key is present.
      for (const key of [
        'paired',
        'role',
        'this_mac',
        'other_mac',
        'model',
        'mode',
        'split',
        'serves',
        'reason',
        'next',
        'lines',
        'service',
      ])
        expect(status).toHaveProperty(key);
      const next = clusterPreview.snapshot!(base());
      expect(next.capabilities).toEqual(
        expect.arrayContaining(['cluster', 'cluster_session', 'waitlists', 'waitlist']),
      );
      // A paired Mac's runtime offers no Autopilot.
      expect(next.capabilities!.includes('autopilot')).toBe(pair === null);
      if (pair === null) expect(next.pair).toBeNull();
      else expect(next.pair).toMatchObject(pair);
    },
  );

  it('serves the status as a resource, more slowly on the Mac that follows', async () => {
    vi.useFakeTimers();
    const { clusterPreview } = await load('&cluster=serving&cluster-role=member');
    let status: ClusterStatus | undefined;
    void (clusterPreview.resources!().cluster as Promise<ClusterStatus>).then(
      (value) => (status = value),
    );
    await vi.advanceTimersByTimeAsync(1000);
    expect(status).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1000);
    expect(status).toMatchObject({ role: 'member', this_mac: 'Studio B', state: 'serving' });
    expect(clusterPreview.snapshot!(base()).pair).toMatchObject({ state: 'started', leads: false });
  });

  it('&cluster=unsupported is a runtime from before clusters', async () => {
    const { clusterPreview, previewClusterSession } = await load('&cluster=unsupported');
    const next = clusterPreview.snapshot!(base());
    expect(next.capabilities).not.toContain('cluster');
    expect(next.capabilities).toContain('autopilot');
    expect(clusterPreview.resources!()).toEqual({});
    await expect(previewClusterSession.start({ kind: 'setup' })).rejects.toThrow();
  });

  it('&cluster=error is a status the runtime couldn’t read', async () => {
    const { previewClusterStatus } = await load('&cluster=error');
    expect(previewClusterStatus().error).toBeTruthy();
  });
});

describe('the pair’s actions', () => {
  function store(initial: Snapshot) {
    let value = initial;
    return { get: () => value, set: (next: Snapshot) => (value = next) };
  }
  const act = async (
    preview: Awaited<ReturnType<typeof load>>['clusterPreview'],
    state: ReturnType<typeof store>,
    action: Action,
  ) => {
    const done = preview.act!(state, action);
    await vi.advanceTimersByTimeAsync(1000);
    return done;
  };

  it('stops, starts, restarts, serves this Mac alone and leaves', async () => {
    vi.useFakeTimers();
    const { clusterPreview, previewClusterStatus } = await load('&cluster=serving');
    const state = store(clusterPreview.snapshot!(base()));
    expect(await act(clusterPreview, state, { action: 'stop' })).toMatchObject({
      action: 'stop',
      state: 'succeeded',
    });
    expect(previewClusterStatus().state).toBe('stopped');
    expect(state.get().pair?.state).toBe('stopped');
    const revision = state.get().resource_revision;
    await act(clusterPreview, state, { action: 'start', models: [] });
    expect(previewClusterStatus().state).toBe('loading');
    expect(state.get().resource_revision).not.toBe(revision);
    await vi.advanceTimersByTimeAsync(4000);
    expect(previewClusterStatus().state).toBe('serving');
    await act(clusterPreview, state, { action: 'restart' });
    expect(previewClusterStatus().state).toBe('loading');
    await vi.advanceTimersByTimeAsync(4000);
    await act(clusterPreview, state, { action: 'start', models: [], solo: true });
    expect(previewClusterStatus().state).toBe('stopped');
    expect(state.get().state).toBe('running');
    await act(clusterPreview, state, { action: 'cluster_leave' });
    expect(previewClusterStatus().state).toBe('not_paired');
    expect(state.get().pair).toBeNull();
    expect(state.get().capabilities).toContain('autopilot');
    // Not paired: a start with models is the ordinary preview's.
    expect(
      await clusterPreview.act!(state, { action: 'start', models: ['gpt-oss-20b'] }),
    ).toBeUndefined();
  });
});

describe('the scripted setup', () => {
  async function play(query: string) {
    vi.useFakeTimers();
    const preview = await load(query);
    let latest: ClusterSession | undefined;
    preview.previewClusterSession.watch((next) => (latest = next));
    const until = async (test: (session: ClusterSession) => boolean) => {
      for (let waited = 0; waited < 180_000; waited += 100) {
        if (latest && test(latest)) return latest;
        await vi.advanceTimersByTimeAsync(100);
      }
      throw new Error(`The script never got there: ${JSON.stringify(latest?.events.at(-1))}`);
    };
    const asked = (count: number) => (session: ClusterSession) =>
      session.question?.type === 'choose' && session.question.options.length === count;
    const answer = async (choice: number) => {
      const question = latest!.question!;
      await preview.previewClusterSession.answer({ question: question.id, choice });
    };
    return { ...preview, until, asked, answer, latest: () => latest! };
  }
  // The rows of the open list's options.
  const options = (session: ClusterSession) =>
    session.question?.type === 'choose' ? session.question.options.map((rows) => rows[0]) : [];
  const said = (session: ClusterSession) =>
    session.events.flatMap((event) => (event.type === 'say' ? [event.text.trim()] : []));

  it('plays the leader’s setup end to end, then the pair serves', async () => {
    const run = await play('');
    await run.previewClusterSession.start({ kind: 'setup' });
    // Waiting for the other Mac: q is the only key, and the wait ends by itself.
    const waiting = await run.until((session) => session.question?.type === 'key');
    expect(waiting.question).toMatchObject({ keys: [{ key: 'q', label: 'Stop waiting' }] });
    expect(said(waiting)).toContain('Run `darkbloom cluster` on the other Mac.');
    const code = await run.until(run.asked(2));
    expect(said(code).at(-1)).toBe('Code 482 913. Same on the other Mac?');
    await run.answer(0);
    const serving = await run.until(run.asked(3));
    expect(said(serving).at(-1)).toBe('How should this pair serve?');
    expect(serving.question).toMatchObject({ selected: 2 });
    await run.answer(2);
    const list = await run.until(run.asked(4));
    expect(options(list)).toEqual([
      'Qwen3.8-27B-4bit-mtp · 16.3 GB · tensor parallel',
      'Gemma 4 26B QAT · 15.6 GB · tensor parallel or pipeline · download',
      'GLM-5.3-Flash · 118.4 GB · tensor parallel or pipeline · copy',
      'MiMo-V2.6-Flash · 186.0 GB · speculative pipeline · does not fit now',
    ]);
    await run.answer(0);
    const done = await run.until((session) => session.state !== 'running');
    expect(done).toMatchObject({ state: 'succeeded', exit_code: 0, question: null });
    const headings = done.events.flatMap((event) => (event.type === 'heading' ? [event.text] : []));
    expect(headings).toEqual(['1/4 Connect', '2/4 Pair', '3/4 Model', '4/4 Start']);
    expect(done.events.find((event) => event.type === 'result')).toMatchObject({
      ok: true,
      title: 'Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (tensor parallel)',
    });
    expect(done.events.some((event) => event.type === 'working' && event.rows.length === 2)).toBe(
      true,
    );
    expect(run.previewClusterStatus()).toMatchObject({
      state: 'serving',
      role: 'leader',
      mode: 'tensor parallel',
      lines: expect.arrayContaining([
        'Serves: through Darkbloom, and on its local API with you first',
      ]),
    });
    // The session stays readable once it ended.
    expect(await run.previewClusterSession.current()).toMatchObject({ state: 'succeeded' });
  });

  it('downloads, copies and splits a model the way the mode question says', async () => {
    const run = await play('');
    await run.previewClusterSession.start({ kind: 'setup' });
    await run.until(run.asked(2));
    await run.answer(0);
    await run.until(run.asked(3));
    await run.answer(1);
    await run.until(run.asked(4));
    await run.answer(1);
    const mode = await run.until(run.asked(2));
    expect(said(mode).slice(-2)).toEqual([
      'How should both Macs split Gemma 4 26B QAT?',
      'Recommended for Gemma 4 26B QAT on these two Macs: Tensor parallel, faster here and serves up to 8 requests at once.',
    ]);
    await run.answer(1);
    const done = await run.until((session) => session.state !== 'running');
    expect(done.state).toBe('succeeded');
    expect(done.events.some((event) => event.type === 'progress' && /\d+%/.test(event.text))).toBe(
      true,
    );
    expect(
      done.events.some(
        (event) => event.type === 'working' && event.rows.every((row) => /\d+%/.test(row)),
      ),
    ).toBe(true);
    expect(run.previewClusterStatus()).toMatchObject({
      mode: 'pipeline',
      split: 'M3 Ultra 24 layers / M5 Max 22 layers',
      lines: expect.arrayContaining(['Serves: through Darkbloom']),
    });
  });

  it('ends at No to the code with nothing paired', async () => {
    const run = await play('');
    await run.previewClusterSession.start({ kind: 'setup' });
    await run.until(run.asked(2));
    await run.answer(1);
    const done = await run.until((session) => session.state !== 'running');
    expect(done.state).toBe('failed');
    expect(said(done)).toContain('Declined: nothing paired.');
    expect(run.previewClusterStatus().state).toBe('not_paired');
  });

  it('ends at Cancel, and refuses answers to a question no longer asked', async () => {
    const run = await play('');
    await run.previewClusterSession.start({ kind: 'local' });
    const waiting = await run.until((session) => session.question?.type === 'key');
    await expect(
      run.previewClusterSession.answer({ question: waiting.question!.id, key: 'x' }),
    ).rejects.toThrow('isn’t one of the answers');
    await run.previewClusterSession.answer({ cancel: true });
    expect(run.latest()).toMatchObject({ state: 'cancelled', question: null });
    await expect(
      run.previewClusterSession.answer({ question: waiting.question!.id, key: 'q' }),
    ).rejects.toThrow('No cluster setup is running.');
    // A new setup can start once the last one ended.
    await expect(run.previewClusterSession.start({ kind: 'setup' })).resolves.toMatchObject({
      state: 'running',
    });
  });

  it('plays the Mac that joins: it pairs and follows the leading Mac’s start', async () => {
    const run = await play('&cluster-role=member');
    await run.previewClusterSession.start({ kind: 'setup' });
    await run.until(run.asked(2));
    await run.answer(0);
    const following = await run.until((session) => session.question?.type === 'key');
    expect(following.question).toMatchObject({ keys: [{ key: 'q', label: 'Leave' }] });
    expect(said(following)).toContain('✓ Paired. The other Mac leads.');
    const done = await run.until((session) => session.state !== 'running');
    expect(done.state).toBe('succeeded');
    expect(done.events.find((event) => event.type === 'result')).toMatchObject({
      ok: true,
      lines: expect.arrayContaining(['Test response in 0.61 s (the leading Mac’s test)']),
    });
    expect(run.previewClusterStatus()).toMatchObject({ state: 'serving', role: 'member' });
  });

  it('changes a set-up pair’s model from its list', async () => {
    const run = await play('&cluster=serving');
    const started = await run.previewClusterSession.start({ kind: 'setup' });
    expect(started.state).toBe('running');
    const list = await run.until(run.asked(6));
    expect(list.question).toMatchObject({ selected: 0 });
    expect(options(list)[0]).toMatch(/serving now$/);
    await run.answer(2);
    await run.until(run.asked(2));
    expect(said(run.latest()).at(-1)).toMatch(/^Switch to GLM-5.3-Flash\?/);
    await run.answer(0);
    await run.until(run.asked(2));
    await run.answer(0);
    const done = await run.until((session) => session.state !== 'running');
    expect(done.state).toBe('succeeded');
    const headings = done.events.flatMap((event) => (event.type === 'heading' ? [event.text] : []));
    expect(headings).toEqual(['Model', 'Start']);
    expect(run.previewClusterStatus().model).toMatchObject({ name: 'GLM-5.3-Flash' });
  });
});
