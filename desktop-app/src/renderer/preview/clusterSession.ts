import type {
  ClusterConsoleEvent,
  ClusterQuestion,
  ClusterSession,
  ClusterSessionAnswer,
  ClusterSessionStart,
} from '../../shared/cluster';
import {
  previewModels,
  previewPair,
  setPreviewPair,
  unsupported,
  type PreviewPair,
} from './cluster';

// Development preview of the guided cluster setup: `darkbloom cluster`'s screen as a script, in the
// CLI's own words, that answers advance and Cancel ends. A setup that ends serving leaves the
// preview's pair serving. Never used for live data.

type Answer = Exclude<ClusterSessionAnswer, { cancel: true }>;

type Step =
  | { kind: 'event'; event: ClusterConsoleEvent; wait: number }
  | {
      kind: 'ask';
      question: ClusterQuestion;
      then: (answer: Answer) => Step[];
      // A wait that ends by itself (the other Mac shows up) unless its key is pressed first.
      after?: { ms: number; then: () => Step[] };
    }
  | { kind: 'run'; effect: () => void }
  | { kind: 'end'; state: 'succeeded' | 'failed'; exit: number };

const event = (value: ClusterConsoleEvent, wait = 380): Step => ({
  kind: 'event',
  event: value,
  wait,
});
const say = (text: string, wait = 380) => event({ type: 'say', text: `  ${text}` }, wait);
const heading = (text: string) => event({ type: 'heading', text }, 450);
const working = (rows: string[], wait: number) => event({ type: 'working', rows }, wait);
const progress = (text: string, wait: number) => event({ type: 'progress', text }, wait);
const settle = (): Step => event({ type: 'settle' }, 0);
const result = (ok: boolean, title: string, lines: string[]) =>
  event({ type: 'result', ok, title, lines }, 500);
const run = (effect: () => void): Step => ({ kind: 'run', effect });
const end = (state: 'succeeded' | 'failed', exit = state === 'succeeded' ? 0 : 1): Step => ({
  kind: 'end',
  state,
  exit,
});

let questions = 0;
const choose = (options: string[][], selected: number, then: (choice: number) => Step[]): Step => ({
  kind: 'ask',
  question: { id: `q${++questions}`, type: 'choose', options, selected },
  then: (answer) => ('choice' in answer ? then(answer.choice) : []),
});
const waitKeys = (
  keys: { key: string; label: string }[],
  after: { ms: number; then: () => Step[] },
  then: (key: string) => Step[],
): Step => ({
  kind: 'ask',
  question: { id: `q${++questions}`, type: 'key', keys },
  then: (answer) => ('key' in answer ? then(answer.key) : []),
  after,
});

// The two Macs, as each screen names them.
const leaderMacs = { thisMac: 'Studio A', other: 'Apple M5 Max, 128 GB' };
const memberMacs = { thisMac: 'Studio B', other: 'Apple M3 Ultra, 256 GB' };

type Serves = PreviewPair['serves'];

const servingAnswers = [
  [
    'Only me (this pair, local)',
    'Darkbloom never contacts these Macs. Your tools use the leading Mac’s API.',
  ],
  ['Darkbloom network', 'The pair serves Darkbloom and earns while it runs.'],
  [
    'Both, me first',
    'The pair serves Darkbloom while you aren’t using it. When you use its API, Darkbloom pauses until you’ve been idle for 2 minutes.',
  ],
];
const servesByAnswer: Serves[] = ['local', 'network', 'both'];

interface Model {
  model: { id: string; name: string };
  title: string;
  line: string;
  modes: string[];
  move?: 'copy' | 'download';
  size: string;
}

const models: Model[] = [
  {
    model: previewModels.qwen,
    title: 'Qwen3.8-27B-4bit-mtp',
    line: 'Qwen3.8-27B-4bit-mtp · 16.3 GB · tensor parallel',
    modes: ['tensor parallel'],
    size: '16.3 GB',
  },
  {
    model: previewModels.gemma,
    title: 'Gemma 4 26B QAT',
    line: 'Gemma 4 26B QAT · 15.6 GB · tensor parallel or pipeline · download',
    modes: ['tensor parallel', 'pipeline'],
    move: 'download',
    size: '15.6 GB',
  },
  {
    model: previewModels.glm,
    title: 'GLM-5.3-Flash',
    line: 'GLM-5.3-Flash · 118.4 GB · tensor parallel or pipeline · copy',
    modes: ['tensor parallel', 'pipeline'],
    move: 'copy',
    size: '118.4 GB',
  },
];
const tooLarge = 'MiMo-V2.6-Flash · 186.0 GB · speculative pipeline · does not fit now';

const firstRun = (local: boolean) => [
  say(
    `You'll approve macOS prompts on each Mac's own screen: its password for the cable port, Allow for Local Network, and Yes to the pairing code${local ? '.' : '; then a Darkbloom login to serve through Darkbloom.'}`,
    200,
  ),
  say('For a Mac with no display, open Screen Sharing to it first.', 200),
  say(
    'It takes about 2 minutes to connect and pair; a model copy or download depends on its size; loading takes a few minutes.',
    700,
  ),
];

const connect = (): Step[] => [
  heading('1/4 Connect'),
  say('Allow macOS permissions.'),
  working(['Checking the Thunderbolt cable'], 1400),
  say('✓ Cable ready'),
  working(['Checking local network access'], 900),
  settle(),
];

// Both Macs ask for Local Network at the same moment, once paired.
const allow = (other: string): Step[] => [
  say(
    `Click Allow on the Local Network prompt for Darkbloom. Approve it on the other Mac's screen too (${other}); use Screen Sharing if it has no display.`,
    500,
  ),
  progress('Waiting for Allow · 0:04 of 10 min (q cancels)', 1100),
  progress('Waiting for Allow · 0:05 of 10 min (q cancels)', 1100),
  say('✓ Allowed'),
];

const declined = (): Step[] => [
  say('Declined: nothing paired.'),
  say('Not paired.'),
  say('Run `darkbloom cluster` again.'),
  end('failed'),
];

const code = '482 913';

// The Mac you start on: it waits for the other Mac, shows the code, and leads.
function pairAsLeader(next: () => Step[]): Step[] {
  return [
    heading('2/4 Pair'),
    working(['Looking for the other Mac on the cable'], 1200),
    say('Run `darkbloom cluster` on the other Mac.', 200),
    working(['Waiting for the other Mac (run `darkbloom cluster` there; q cancels)'], 0),
    waitKeys(
      [{ key: 'q', label: 'Cancel' }],
      {
        ms: 5200,
        then: () => [
          working(['Exchanging keys with the other Mac'], 1300),
          say(`Code ${code}. Same on the other Mac?`, 0),
          choose([['Yes'], ['No']], 0, (choice) =>
            choice === 0
              ? [
                  say('Now confirm on the other Mac.'),
                  working(['Waiting for the other Mac to confirm the code'], 1700),
                  say(`✓ Paired. This Mac (${leaderMacs.thisMac}) leads.`),
                  ...allow(leaderMacs.other),
                  ...next(),
                ]
              : declined(),
          ),
        ],
      },
      () => [say('Stopped: nothing paired.'), end('failed')],
    ),
  ];
}

// How a start is said: on the Mac that follows (`follows`), and as the first setup's numbered step
// or a set-up pair's plain one.
interface Start {
  follows?: boolean;
  numbered?: boolean;
}

// Each Mac's part loads; the leading Mac then answers a test request.
function start(
  model: Model,
  mode: string,
  serves: Serves,
  { follows = false, numbered = true }: Start = {},
): Step[] {
  const { thisMac, other } = follows ? memberMacs : leaderMacs;
  const layers =
    mode === 'pipeline'
      ? ['layers 0–23', 'layers 24–45']
      : ['50% of each layer', '50% of each layer'];
  const transfer: Step[] =
    model.move === 'download'
      ? [
          progress(
            `Downloading ${model.title}  4%  0.6 GB of ${model.size}  420 MB/s  36 s left`,
            900,
          ),
          progress(
            `Downloading ${model.title}  31%  4.8 GB of ${model.size}  455 MB/s  24 s left`,
            900,
          ),
          progress(
            `Downloading ${model.title}  67%  10.5 GB of ${model.size}  460 MB/s  11 s left`,
            900,
          ),
          progress(`Downloading ${model.title}  100%  ${model.size} of ${model.size}`, 500),
          say('✓ Downloaded (35 s)'),
          working(['This Mac: sending the model · 18%', 'The other Mac: receiving · 18%'], 900),
          working(['This Mac: sending the model · 64%', 'The other Mac: receiving · 64%'], 900),
          working(['This Mac: sending the model · 100%', 'The other Mac: checking the files'], 700),
          say('✓ Copied to the other Mac (12 s)'),
        ]
      : model.move === 'copy'
        ? [
            working(['This Mac: sending the model · 9%', 'The other Mac: receiving · 9%'], 900),
            working(['This Mac: sending the model · 47%', 'The other Mac: receiving · 47%'], 900),
            working(['This Mac: sending the model · 88%', 'The other Mac: receiving · 88%'], 900),
            working(
              ['This Mac: sending the model · 100%', 'The other Mac: checking the files'],
              700,
            ),
            say('✓ Copied to the other Mac (1 min 14 s)'),
          ]
        : [];
  const where =
    serves === 'local'
      ? `on this Mac's local API only (${mode})`
      : `through Darkbloom on both Macs (${mode})`;
  const served = `Serving ${model.title} ${where}`;
  const card = [
    say(
      `Model:   ${model.title} · ${mode} (Apple M3 Ultra ${layers[0]} / Apple M5 Max ${layers[1]})`,
      150,
    ),
    say(
      follows
        ? `Macs:    The other Mac (${other}) leads · this Mac (${thisMac}) follows`
        : `Macs:    This Mac leads · the other Mac (${other}) follows`,
      150,
    ),
    say(
      serves === 'local'
        ? 'Local:   http://localhost:8001'
        : serves === 'both'
          ? 'Serves:  through Darkbloom, and on its local API with you first'
          : 'Serves:  through Darkbloom',
      150,
    ),
    say('Starts by itself at login on both Macs.', 150),
    ...(follows
      ? []
      : [
          say('darkbloom stop     Stop both Macs', 100),
          say('darkbloom restart  Restart with the current model', 100),
          say('darkbloom status   Check status', 100),
        ]),
  ];
  return [
    heading(numbered ? '4/4 Start' : 'Start'),
    say('Loading takes a few minutes for a large model; both Macs show progress here.'),
    ...transfer,
    working(['Starting both Macs'], 1000),
    working(
      [
        `This Mac: loading its share (${layers[0]}) · 0:04`,
        `The other Mac: loading its share (${layers[1]}) · 0:04`,
      ],
      1300,
    ),
    working(
      [
        `This Mac: ready (${layers[0]}) · 0:41`,
        `The other Mac: loading its share (${layers[1]}) · 0:41`,
      ],
      1300,
    ),
    working([`This Mac: ready (${layers[0]})`, `The other Mac: ready (${layers[1]})`], 700),
    say('✓ Loaded on both Macs (52 s)'),
    working(['Sending a test request'], 1000),
    ...(serves === 'local'
      ? []
      : [
          working(
            [
              `Offered to Darkbloom as a pair for ${model.title}; waiting for Darkbloom to accept this pair`,
            ],
            1600,
          ),
        ]),
    result(true, served, [
      ...(serves === 'network' ? [] : ['API at http://localhost:8001 on this Mac']),
      follows ? 'Test response in 0.61 s (the leading Mac’s test)' : 'Test response in 0.61 s',
    ]),
    ...card,
    say('You can close this window.', 200),
    run(() =>
      setPreviewPair({
        state: 'serving',
        role: follows ? 'member' : 'leader',
        model: model.model,
        mode,
        split:
          mode === 'pipeline'
            ? 'M3 Ultra 24 layers / M5 Max 22 layers'
            : 'M3 Ultra 50% / M5 Max 50%',
        serves,
      }),
    ),
    end('succeeded'),
  ];
}

// How both Macs split a model that runs more than one way, recommended mode first.
function split(model: Model, serves: Serves, how: Start = {}): Step[] {
  if (model.modes.length < 2) return start(model, model.modes[0], serves, how);
  return [
    say(`How should both Macs split ${model.title}?`, 0),
    event(
      {
        type: 'say',
        text: `  Recommended for ${model.title} on these two Macs: Tensor parallel, faster here and serves up to 8 requests at once.`,
        stressed: {
          lead: `  Recommended for ${model.title} on these two Macs: `,
          stressed: 'Tensor parallel',
          tail: ', faster here and serves up to 8 requests at once.',
        },
      },
      0,
    ),
    choose(
      [
        [
          'Tensor parallel',
          'both Macs work on every layer, each holding a share of it (this Mac 50% / the other Mac 50%) · serves up to 8 requests at once · recommended for these Macs',
        ],
        [
          'Pipeline',
          'each Mac runs its share of the layers (this Mac 24 layers / the other Mac 22 layers) · serves one request at a time',
        ],
      ],
      0,
      (choice) => start(model, choice === 0 ? 'tensor parallel' : 'pipeline', serves, how),
    ),
  ];
}

// The model list: approved models these two Macs can serve, those that fit first.
function modelList(serves: Serves, extra: string[] = [], current?: string, how: Start = {}): Step {
  const lines = models.map((item) =>
    item.model.id === current ? `${item.line} · serving now` : item.line,
  );
  const selected = Math.max(
    0,
    models.findIndex((item) => item.model.id === current),
  );
  return choose(
    [...lines, tooLarge, ...extra].map((line) => [line]),
    selected,
    (choice) => {
      if (choice === models.length)
        return [say('MiMo-V2.6-Flash does not fit in both Macs’ free memory now.'), end('failed')];
      if (choice > models.length) return [];
      return split(models[choice], serves, how);
    },
  );
}

function chooseModel(local: boolean): Step[] {
  return [
    heading('3/4 Model'),
    working(['Reading both Macs over the cable'], 1300),
    ...(local
      ? [working(['Planning each model for both Macs'], 1200), modelList('local')]
      : [
          say('How should this pair serve?', 0),
          choose(servingAnswers, 2, (choice) => [
            working(['Planning each model for both Macs'], 1300),
            modelList(servesByAnswer[choice]),
          ]),
        ]),
  ];
}

// The Mac you start on, never paired before.
function leaderFlow(local: boolean): Step[] {
  return [
    event({ type: 'banner', title: 'Darkbloom cluster', subtitle: '' }, 300),
    ...firstRun(local),
    ...connect(),
    ...pairAsLeader(() => chooseModel(local)),
  ];
}

// The Mac that joins a waiting Mac: it pairs, then follows the leading Mac's start.
function memberFlow(local: boolean): Step[] {
  const other = memberMacs.other;
  return [
    event({ type: 'banner', title: 'Darkbloom cluster', subtitle: '' }, 300),
    ...firstRun(local),
    ...connect(),
    heading('2/4 Pair'),
    working(['Looking for the other Mac on the cable'], 1500),
    working(['Exchanging keys with the other Mac'], 1100),
    say(`Code ${code}. Same on the other Mac?`, 0),
    choose([['Yes'], ['No']], 0, (choice) =>
      choice !== 0
        ? declined()
        : [
            working(['Waiting for the other Mac to confirm the code'], 900),
            say('✓ Paired. The other Mac leads.'),
            ...(local ? [say('Run `darkbloom cluster local` on the other Mac: it leads.')] : []),
            ...allow(other),
            heading('3/4 Model'),
            say(`Waiting for the other Mac (${other}) to choose the model and start…`, 300),
            working(
              [`The other Mac (${other}): choosing the model · 0:20 of 15 min (q leaves)`],
              0,
            ),
            waitKeys(
              [{ key: 'q', label: 'Leave' }],
              {
                ms: 4200,
                then: () => [
                  say(`The other Mac (${other}): it's copying the model to this Mac.`),
                  ...start(models[2], 'tensor parallel', local ? 'local' : 'both', {
                    follows: true,
                  }),
                ],
              },
              () => [
                say('The pair keeps going; run `darkbloom cluster` here to see it.'),
                end('succeeded'),
              ],
            ),
          ],
    ),
  ];
}

// A set-up pair on the Mac that leads: its status, then the model list with its two other
// choices, as `darkbloom cluster` shows it again.
function changeFlow(): Step[] {
  const pair = previewPair();
  const named = models.find((item) => item.model.id === pair.model.id) ?? models[0];
  const serving = pair.state === 'serving';
  const now = { local: 'only me, local', network: 'Darkbloom network', both: 'Both, me first' }[
    pair.serves
  ];
  return [
    event(
      {
        type: 'banner',
        title: 'Darkbloom cluster · Leading Mac',
        subtitle: `This Mac (${leaderMacs.thisMac}) leads`,
      },
      300,
    ),
    say(
      `This Mac (${leaderMacs.thisMac}) leads · the other Mac (${leaderMacs.other}) follows · cable ready`,
    ),
    ...(serving
      ? [result(true, `Serving ${named.title} through Darkbloom on both Macs (${pair.mode})`, [])]
      : [say(`Stopped; last model ${named.title}`)]),
    heading('Model'),
    modelList(
      pair.serves,
      [`Change how the pair serves (now: ${now})`, 'Start over (unpair and set up again)'],
      pair.model.id,
      { numbered: false },
    ),
  ].map((step) =>
    // The list's last two lines: how the pair serves, and starting over.
    step.kind === 'ask' && step.question.type === 'choose'
      ? {
          ...step,
          then: (answer: Answer) => {
            if (!('choice' in answer)) return [];
            const count = models.length + 1;
            if (answer.choice === count)
              return [
                say('How should this pair serve?', 0),
                choose(servingAnswers, servesByAnswer.indexOf(pair.serves), (choice) => [
                  say(
                    choice === 0
                      ? 'Switching to local only: the leading Mac’s part starts again that way.'
                      : 'Switching to serving through Darkbloom: both Macs load the model again from a plan made for Darkbloom.',
                  ),
                  ...start(named, pair.mode, servesByAnswer[choice], { numbered: false }),
                ]),
              ];
            if (answer.choice === count + 1)
              return [
                say(
                  'Unpair this Mac and pair the two Macs again? The Mac that leads then chooses the model.',
                  0,
                ),
                choose([['Yes, start over'], ['No']], 1, (choice) =>
                  choice === 0
                    ? [
                        working(['Unpairing this Mac'], 1100),
                        say('✓ Unpaired this Mac.'),
                        run(() => setPreviewPair({ state: 'not_paired' })),
                        ...connect(),
                        ...pairAsLeader(() => chooseModel(false)),
                      ]
                    : [say('Nothing changed.'), end('succeeded')],
                ),
              ];
            if (
              answer.choice < models.length &&
              models[answer.choice].model.id !== pair.model.id &&
              serving
            )
              return [
                say(
                  `Switch to ${models[answer.choice].title}? ${named.title} stops serving on both Macs while ${models[answer.choice].title} loads (a few minutes for a large model).`,
                  0,
                ),
                choose([['Yes, switch'], ['No']], 1, (choice) =>
                  choice === 0
                    ? [
                        say(`✓ Stopped ${named.title} on both Macs`),
                        ...split(models[answer.choice], pair.serves, { numbered: false }),
                      ]
                    : [say(`Nothing changed: ${named.title} keeps serving.`), end('succeeded')],
                ),
              ];
            // The model it serves, in its mode: one test request, nothing else changes.
            if (
              answer.choice < models.length &&
              models[answer.choice].model.id === pair.model.id &&
              serving
            )
              return [
                heading('Start'),
                working(['Sending a test request'], 1100),
                result(true, `Already serving ${named.title}; test response in 0.61 s`, []),
                end('succeeded'),
              ];
            return step.then(answer);
          },
        }
      : step,
  );
}

// The Mac that follows a set-up pair: its status, and where the model is chosen.
function memberStatusFlow(): Step[] {
  const pair = previewPair();
  return [
    event(
      {
        type: 'banner',
        title: 'Darkbloom cluster · Joining Mac',
        subtitle: `This Mac (${memberMacs.thisMac}) follows the other Mac`,
      },
      300,
    ),
    say(
      `This Mac (${memberMacs.thisMac}) follows · the other Mac (${memberMacs.other}) leads · cable ready`,
    ),
    ...(pair.state === 'serving'
      ? [
          result(
            true,
            `Serving ${pair.model.name} through Darkbloom on both Macs (${pair.mode})`,
            [],
          ),
        ]
      : [say(`Stopped; last model ${pair.model.name}`)]),
    say('This Mac runs its part by itself.'),
    say(
      `To change the model, run \`darkbloom cluster\` or \`darkbloom start\` on the other Mac (${memberMacs.other}). \`darkbloom stop\` here stops both Macs.`,
      0,
    ),
    choose([['Close'], ['Start over (unpair and set up again)']], 0, (choice) =>
      choice === 0 ? [end('succeeded')] : [say('Nothing changed.'), end('succeeded')],
    ),
  ];
}

// A pairing record that can't be read: the setup checks it and offers to pair again.
function unreadableFlow(): Step[] {
  return [
    event({ type: 'banner', title: 'Darkbloom cluster', subtitle: '' }, 300),
    say(
      'This Mac’s pairing record couldn’t be read (pairings.json is malformed; nothing is trusted from it), so it may be in a two-Mac cluster.',
      0,
    ),
    choose([['Pair again'], ['Quit']], 0, (choice) =>
      choice === 0
        ? [
            working(['Unpairing this Mac'], 1000),
            say('✓ Unpaired this Mac.'),
            run(() => setPreviewPair({ state: 'not_paired' })),
            ...connect(),
            ...pairAsLeader(() => chooseModel(false)),
          ]
        : [say('Nothing changed.'), end('succeeded')],
    ),
  ];
}

function script(start: ClusterSessionStart): Step[] {
  const pair = previewPair();
  const local = start.kind === 'local';
  if (pair.state === 'pairing_unreadable') return unreadableFlow();
  if (pair.state !== 'not_paired' && pair.state !== 'error')
    return pair.role === 'member' ? memberStatusFlow() : changeFlow();
  return pair.role === 'member' ? memberFlow(local) : leaderFlow(local);
}

const clone = <T>(value: T): T => structuredClone(value);

// Plays a script: each event after its wait, each question until it's answered.
class Player {
  session: ClusterSession | null = null;
  private queue: Step[] = [];
  private asking: Extract<Step, { kind: 'ask' }> | null = null;
  private timer?: ReturnType<typeof setTimeout>;
  private listeners = new Set<(session: ClusterSession) => void>();
  private count = 0;

  watch(callback: (session: ClusterSession) => void) {
    this.listeners.add(callback);
    return () => {
      this.listeners.delete(callback);
    };
  }

  start(start: ClusterSessionStart) {
    if (unsupported()) throw new Error('Unknown route');
    if (this.session?.state === 'running')
      throw new Error('A cluster setup is already running. Finish or cancel it first.');
    clearTimeout(this.timer);
    this.session = {
      id: `preview-setup-${++this.count}`,
      kind: start.kind,
      state: 'running',
      started_at: Date.now() / 1000,
      events: [],
      question: null,
    };
    this.queue = script(start);
    this.asking = null;
    this.publish();
    this.schedule(200);
    return clone(this.session);
  }

  answer(answer: ClusterSessionAnswer) {
    const session = this.session;
    if (!session || session.state !== 'running') throw new Error('No cluster setup is running.');
    if ('cancel' in answer) {
      clearTimeout(this.timer);
      this.asking = null;
      session.question = null;
      this.add({ type: 'say', text: 'Nothing changed.' });
      this.finish('cancelled', 0);
      return clone(session);
    }
    const asking = this.asking;
    if (!asking || asking.question.id !== answer.question)
      throw new Error('That question isn’t asked anymore.');
    const question = asking.question;
    if (
      ('choice' in answer &&
        (question.type !== 'choose' || answer.choice >= question.options.length)) ||
      ('key' in answer &&
        (question.type !== 'key' || !question.keys.some((item) => item.key === answer.key)))
    )
      throw new Error('That isn’t one of the answers.');
    clearTimeout(this.timer);
    this.asking = null;
    session.question = null;
    // A list folds to the option it took, as in Terminal.
    if ('choice' in answer && question.type === 'choose')
      this.add({ type: 'say', text: `  ▸ ${question.options[answer.choice][0]}` });
    this.queue = [...asking.then(answer), ...this.queue];
    this.publish();
    this.schedule(250);
    return clone(session);
  }

  private schedule(ms: number) {
    this.timer = setTimeout(() => this.advance(), ms);
  }

  private publish() {
    if (!this.session) return;
    const session = clone(this.session);
    this.listeners.forEach((callback) => callback(clone(session)));
  }

  // As the desktop API keeps the screen: live work only as the last event, ended by the next one
  // or by `settle`, which isn't kept.
  private add(event: ClusterConsoleEvent) {
    const events = this.session?.events;
    if (!events) return;
    const last = events.at(-1);
    if (last && (last.type === 'working' || last.type === 'progress')) events.pop();
    if (event.type !== 'settle') events.push(event);
  }

  private finish(state: ClusterSession['state'], exit: number) {
    if (!this.session) return;
    this.add({ type: 'settle' });
    this.session.state = state;
    this.session.exit_code = exit;
    this.session.finished_at = Date.now() / 1000;
    this.session.question = null;
    this.queue = [];
    this.publish();
  }

  private advance() {
    const session = this.session;
    if (!session || session.state !== 'running') return;
    while (this.queue.length) {
      const step = this.queue.shift()!;
      if (step.kind === 'run') {
        step.effect();
        continue;
      }
      if (step.kind === 'end') return this.finish(step.state, step.exit);
      if (step.kind === 'ask') {
        this.asking = step;
        session.question = step.question;
        this.publish();
        const after = step.after;
        if (after)
          this.timer = setTimeout(() => {
            if (this.asking !== step) return;
            this.asking = null;
            session.question = null;
            this.queue = [...after.then(), ...this.queue];
            this.advance();
          }, after.ms);
        return;
      }
      this.add(step.event);
      if (step.wait > 0) {
        this.publish();
        return this.schedule(step.wait);
      }
    }
    this.publish();
  }
}

const player = new Player();

export const previewClusterSession = {
  async current(): Promise<ClusterSession | null> {
    return player.session ? clone(player.session) : null;
  },
  async start(start: ClusterSessionStart): Promise<ClusterSession> {
    return player.start(start);
  },
  async answer(answer: ClusterSessionAnswer): Promise<ClusterSession> {
    return player.answer(answer);
  },
  watch(callback: (session: ClusterSession) => void): () => void {
    return player.watch(callback);
  },
};
