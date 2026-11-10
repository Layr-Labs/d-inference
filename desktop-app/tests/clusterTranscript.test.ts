import { describe, expect, it } from 'vitest';
import type { ClusterConsoleEvent, ClusterSession } from '../src/shared/cluster';
import {
  heading,
  option,
  pairingInProgress,
  percent,
  progressReport,
  sayLine,
  transcript,
} from '../src/renderer/features/cluster/transcript';
import { pairActions, servingWay, shares } from '../src/renderer/features/cluster/status';
import type { ClusterStatus } from '../src/shared/cluster';

const session = (
  events: ClusterConsoleEvent[],
  patch: Partial<ClusterSession> = {},
): ClusterSession => ({
  id: 's',
  kind: 'setup',
  state: 'running',
  started_at: 1,
  events,
  question: null,
  ...patch,
});
const say = (text: string): ClusterConsoleEvent => ({ type: 'say', text });

describe('the setup screen as steps', () => {
  it('reads numbered and plain headings', () => {
    expect(heading('2/4 Pair')).toEqual({ title: 'Pair', index: 2, total: 4 });
    expect(heading('Model')).toEqual({ title: 'Model' });
    expect(heading('5/4 Pair')).toEqual({ title: '5/4 Pair' });
  });

  it('groups said lines under their step and keeps the opening apart', () => {
    const view = transcript(
      session([
        { type: 'banner', title: 'Darkbloom cluster', subtitle: '' },
        say('  For a Mac with no display, open Screen Sharing to it first.'),
        { type: 'heading', text: '1/4 Connect' },
        say('  Allow macOS permissions.'),
        say(''),
        say('  ✓ Cable ready'),
        { type: 'heading', text: '2/4 Pair' },
        say('  ✗ Not paired.'),
      ]),
    );
    expect(view.title).toBe('Darkbloom cluster');
    expect(view.intro).toHaveLength(1);
    expect(view.steps.map((step) => step.title)).toEqual(['Connect', 'Pair']);
    expect(view.meter).toEqual({ index: 2, total: 4 });
    const lines = view.steps[0].blocks.map((block) => block.kind === 'line' && block.line);
    expect(lines).toMatchObject([
      { text: 'Allow macOS permissions.', tone: 'plain' },
      { text: 'Cable ready', tone: 'done' },
    ]);
    expect(view.steps[1].blocks[0]).toMatchObject({
      line: { text: 'Not paired.', tone: 'failed' },
    });
  });

  it('keeps the latest live work until a line, a settle or the session’s end replaces it', () => {
    const rows: ClusterConsoleEvent = {
      type: 'working',
      rows: ['This Mac: ready (layers 0–31)', 'The other Mac: loading its share · 42%'],
    };
    const live = transcript(session([{ type: 'heading', text: '4/4 Start' }, rows])).live;
    expect(live).toEqual({
      kind: 'working',
      rows: [
        { text: 'This Mac: ready (layers 0–31)', percent: undefined },
        { text: 'The other Mac: loading its share · 42%', percent: 42 },
      ],
    });
    expect(transcript(session([rows, say('✓ Loaded')])).live).toBeNull();
    expect(transcript(session([rows, { type: 'settle' }])).live).toBeNull();
    expect(transcript(session([rows], { state: 'failed' })).live).toBeNull();
  });

  it('reads a copy’s or download’s report as a bar only when it carries a percentage', () => {
    expect(
      progressReport('Downloading Gemma 4 26B  42%  6.5 GB of 15.6 GB  455 MB/s  20 s left'),
    ).toEqual({
      kind: 'progress',
      label: 'Downloading Gemma 4 26B',
      figures: ['42%', '6.5 GB of 15.6 GB', '455 MB/s', '20 s left'],
      percent: 42,
    });
    expect(
      progressReport('Waiting for Allow · 0:05 of 10 min (q cancels)').percent,
    ).toBeUndefined();
    // A share is not progress.
    expect(percent('M3 Ultra 50% / M5 Max 50%')).toBeUndefined();
    expect(percent('[████░░] 63%')).toBe(63);
  });

  it('marks pairing codes, commands to run and the pair’s card rows', () => {
    expect(
      sayLine({ type: 'say', text: '  Code 482 913. Same on the other Mac?' }, '1'),
    ).toMatchObject({ code: '482 913', text: 'Same on the other Mac?' });
    expect(sayLine({ type: 'say', text: 'Pairing code:  482 913' }, '1')).toMatchObject({
      code: '482 913',
      text: '',
    });
    expect(
      sayLine({ type: 'say', text: '  Run `darkbloom cluster` on the other Mac.' }, '1'),
    ).toMatchObject({ command: 'darkbloom cluster' });
    expect(sayLine({ type: 'say', text: '  Serves:  through Darkbloom' }, '1')?.fact).toEqual({
      label: 'Serves',
      value: 'through Darkbloom',
    });
    expect(
      sayLine({ type: 'say', text: '  darkbloom stop     Stop both Macs' }, '1')?.fact,
    ).toEqual({ label: 'darkbloom stop', value: 'Stop both Macs', command: true });
    expect(sayLine({ type: 'say', text: '────────────────' }, '1')).toBeNull();
    expect(
      sayLine(
        {
          type: 'say',
          text: '  Recommended: Tensor parallel, faster here.',
          stressed: {
            lead: '  Recommended: ',
            stressed: 'Tensor parallel',
            tail: ', faster here.',
          },
        },
        '1',
      )?.stressed,
    ).toEqual({ lead: 'Recommended: ', stressed: 'Tensor parallel', tail: ', faster here.' });
  });

  it('lifts the open question’s own lines, with its pairing code, out of the step', () => {
    const question = { id: 'q1', type: 'choose' as const, options: [['Yes'], ['No']], selected: 0 };
    const code = transcript(
      session(
        [
          { type: 'heading', text: '2/4 Pair' },
          say('  ✓ Found'),
          say('  Code 482 913. Same on the other Mac?'),
        ],
        { question },
      ),
    );
    expect(code.prompt).toMatchObject({
      code: '482 913',
      lines: [{ text: 'Same on the other Mac?' }],
    });
    expect(code.steps[0].blocks).toHaveLength(1);

    const terminal = transcript(
      session(
        [say('Pairing code:  482 913'), say(''), say('Do both screens show 482 913? Type y or n:')],
        { question },
      ),
    );
    expect(terminal.prompt?.code).toBe('482 913');

    const mode = transcript(
      session(
        [
          { type: 'heading', text: '3/4 Model' },
          say('  How should both Macs split Gemma 4 26B?'),
          {
            type: 'say',
            text: '  Recommended for Gemma 4 26B: Tensor parallel.',
            stressed: {
              lead: '  Recommended for Gemma 4 26B: ',
              stressed: 'Tensor parallel',
              tail: '.',
            },
          },
        ],
        { question },
      ),
    );
    expect(mode.prompt?.lines.map((line) => line.text)).toEqual([
      'How should both Macs split Gemma 4 26B?',
      'Recommended for Gemma 4 26B: Tensor parallel.',
    ]);
    expect(mode.steps[0].blocks).toEqual([]);

    // A list with no question line (the model list) leaves its step as it is.
    const list = transcript(
      session([{ type: 'heading', text: '3/4 Model' }, say('  ✓ Allowed')], { question }),
    );
    expect(list.prompt).toBeNull();
    expect(list.steps[0].blocks).toHaveLength(1);
  });

  it('keeps the last outcome and the terminal steps', () => {
    const view = transcript(
      session([
        { type: 'heading', text: '4/4 Start' },
        { type: 'needs_terminal', text: 'Run `sudo darkbloom cluster link --fix` in Terminal.' },
        { type: 'result', ok: false, title: 'Not serving: test failed', lines: ['  Retry below.'] },
      ]),
    );
    expect(view.steps[0].blocks[0]).toMatchObject({
      kind: 'terminal',
      command: 'sudo darkbloom cluster link --fix',
    });
    expect(view.outcome).toMatchObject({ ok: false, lines: ['Retry below.'] });
  });

  it('reads a list’s answer as its option, never as the next question’s prompt', () => {
    const question = { id: 'q2', type: 'choose' as const, options: [['A'], ['B']], selected: 0 };
    const view = transcript(
      session(
        [
          { type: 'heading', text: '3/4 Model' },
          say('  How should this pair serve?'),
          say('  ▸ Both, me first · The pair serves Darkbloom while you aren’t using it.'),
        ],
        { question },
      ),
    );
    expect(view.prompt).toBeNull();
    expect(view.steps[0].blocks[1]).toMatchObject({
      line: {
        answer: true,
        text: 'Both, me first · The pair serves Darkbloom while you aren’t using it.',
      },
    });
  });

  it('leaves out the keys a terminal reads while it waits', () => {
    const view = transcript(
      session([
        {
          type: 'working',
          rows: ['Waiting for the other Mac (run `darkbloom cluster` there; q cancels)'],
        },
      ]),
    );
    expect(view.live).toMatchObject({
      rows: [{ text: 'Waiting for the other Mac (run `darkbloom cluster` there)' }],
    });
    expect(progressReport('Waiting for Allow · 0:05 of 10 min (q cancels)')).toMatchObject({
      label: 'Waiting for Allow',
      figures: ['0:05 of 10 min'],
    });
  });

  it('skips events a newer runtime added', () => {
    const view = transcript(
      session([{ type: 'chart' } as unknown as ClusterConsoleEvent, say('  Still here')]),
    );
    expect(view.intro).toHaveLength(1);
  });

  it('says a pairing is in progress until the step says Paired', () => {
    const pairing = transcript(
      session([{ type: 'heading', text: '2/4 Pair' }, say('  Code 482 913.')]),
    );
    expect(pairingInProgress(pairing)).toBe(true);
    const paired = transcript(
      session([{ type: 'heading', text: '2/4 Pair' }, say('  ✓ Paired. This Mac leads.')]),
    );
    expect(pairingInProgress(paired)).toBe(false);
    expect(pairingInProgress(transcript(session([{ type: 'heading', text: '1/4 Connect' }])))).toBe(
      false,
    );
  });
});

describe('a choice’s rows', () => {
  it('shows the split and the state the CLI marks as tags', () => {
    expect(
      option(['Gemma 4 26B · 15.6 GB · tensor parallel or pipeline · download · serving now']),
    ).toEqual({
      title: 'Gemma 4 26B',
      details: [],
      modes: ['tensor parallel or pipeline'],
      marks: ['serving now'],
      warnings: [],
      facts: ['15.6 GB', 'download'],
    });
    expect(
      option(['MiMo-V2.6-Flash · 186.0 GB · speculative pipeline · does not fit now']),
    ).toMatchObject({
      modes: ['speculative pipeline'],
      warnings: ['does not fit now'],
    });
    expect(
      option([
        'Only me (this pair, local) · Darkbloom never contacts these Macs. Your tools use the leading Mac’s API.',
      ]),
    ).toMatchObject({
      title: 'Only me (this pair, local)',
      details: ['Darkbloom never contacts these Macs. Your tools use the leading Mac’s API.'],
    });
    // A mode's menu line pads its label before what it does, then its markers.
    expect(
      option([
        'Tensor parallel          both Macs work on every layer, each holding a share of it (this Mac 50% / the other Mac 50%) · serves up to 8 requests at once · recommended for these Macs',
      ]),
    ).toEqual({
      title: 'Tensor parallel',
      details: [
        'both Macs work on every layer, each holding a share of it (this Mac 50% / the other Mac 50%)',
      ],
      modes: [],
      marks: ['recommended for these Macs'],
      warnings: [],
      facts: ['serves up to 8 requests at once'],
    });
    expect(option(['Pipeline', 'second row']).details).toEqual(['second row']);
  });
});

describe('the pair’s status', () => {
  const status = (patch: Partial<ClusterStatus>): ClusterStatus => ({
    schema: 1,
    paired: true,
    role: 'leader',
    this_mac: 'Studio A',
    other_mac: { name: 'Apple M5 Max, 128 GB', answers: true },
    model: { id: 'qwen', name: 'Qwen 3.8 27B' },
    mode: 'tensor parallel',
    split: 'M3 Ultra 50% / M5 Max 50%',
    serves: 'darkbloom',
    state: 'serving',
    reason: null,
    next: null,
    lines: [],
    service: { running: true, starts_at_login: true },
    exit_code: 0,
    ...patch,
  });

  it('says how the pair serves, Both from its Serves line', () => {
    expect(servingWay(status({ serves: 'local' }))).toBe('local');
    expect(servingWay(status({ lines: ['Serves: through Darkbloom'] }))).toBe('network');
    expect(
      servingWay(
        status({ lines: ['Serves: through Darkbloom, and on its local API with you first'] }),
      ),
    ).toBe('both');
    expect(servingWay(status({ serves: null }))).toBeNull();
  });

  it('weighs each Mac’s share for the bar', () => {
    expect(shares('M3 Ultra 40 layers / M5 Ultra 24 layers')).toEqual([
      { name: 'M3 Ultra', amount: '40 layers', weight: 40 / 64 },
      { name: 'M5 Ultra', amount: '24 layers', weight: 24 / 64 },
    ]);
    expect(shares('M3 Ultra 50% / M5 Max 50%')?.map((share) => share.amount)).toEqual([
      '50%',
      '50%',
    ]);
    expect(shares('decided when it loads')).toBeNull();
  });

  it('offers what each state allows', () => {
    expect(pairActions(status({ state: 'stopped' }))).toMatchObject({
      start: true,
      stop: false,
      restart: false,
    });
    expect(pairActions(status({ state: 'serving' }))).toMatchObject({
      start: false,
      stop: true,
      restart: true,
    });
    expect(pairActions(status({ state: 'other_mac_away' }))).toMatchObject({
      stop: true,
      restart: false,
    });
    expect(pairActions(status({ state: 'pairing_unreadable', role: null }))).toMatchObject({
      start: false,
      stop: false,
      restart: false,
      leave: false,
      alone: true,
    });
    expect(pairActions(status({ role: 'member' })).change).toBe(false);
  });
});
