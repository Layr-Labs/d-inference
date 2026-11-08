import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Models } from '../../src/after/desktop-app/src/renderer/features/models/Models';
import { PoolRow } from '../../src/after/desktop-app/src/renderer/features/models/PoolRow';
import { poolState, runningDownload } from '../../src/after/desktop-app/src/renderer/features/models/pool';
import { HealthBar } from '../../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { ServingModels } from '../../src/after/desktop-app/src/renderer/features/machines/overview/ServingModels';
import { LiveModels } from '../../src/after/desktop-app/src/renderer/features/insights/LiveModels';
import { OperationFeed } from '../../src/after/desktop-app/src/renderer/components/operations/OperationFeed';
import type { BackendState } from '../../src/after/desktop-app/src/renderer/useBackend';
import type {
  Action,
  NativeModel,
  Operation,
  Snapshot,
} from '../../src/after/desktop-app/src/shared/contracts';
import { Walkthrough } from '../support/Walkthrough';
import { resetBridges, succeeded } from '../support/bridge';
import { backendFor, eightGBMac, poolSnapshot } from '../support/fixtures';

const meta: Meta = { title: 'Flows/Model loading' };
export default meta;
type Story = StoryObj;

// ---------------------------------------------------------------------------------------------
// Fixtures. Everything starts from the app's own poolSnapshot(): GPT-OSS 20B and Gemma 4 26B
// loaded (Gemma kept in memory), Qwen 3.5 9B downloaded, Qwen 3.6 35B A3B not downloaded and
// Kimi K2.6 too large for this 64 GB Mac.

const QWEN = 'qwen-3.6-35b';
const now = () => Math.floor(Date.now() / 1000);

const withModel = (state: Snapshot, id: string, change: Partial<NativeModel>): Snapshot => ({
  ...state,
  models: state.models.map((model) => (model.id === id ? { ...model, ...change } : model)),
});

const operation = (
  action: Operation['action'],
  state: Operation['state'],
  extra: Partial<Operation> = {},
): Operation => ({
  id: `${action}-${state}-flow`,
  action,
  state,
  started_at: now() - 95,
  message: '',
  cancellable: false,
  ...extra,
});

/** Autopilot on (the default pool fixture), or manual selection with Autopilot off. */
const pool = (overrides: Partial<Snapshot> = {}, autopilot = {}) =>
  poolSnapshot(autopilot, { machine: { ...poolSnapshot().machine, status: 'running', models: ['gpt-oss-20b', 'gemma-4-26b'] }, ...overrides });
const manual = (overrides: Partial<Snapshot> = {}) =>
  pool(overrides, { enabled: false, phase: 'off' });

// As useBackend derives it: any running operation makes the app busy.
const backend = (state: Snapshot, overrides: Partial<BackendState> = {}) =>
  backendFor('after', state, {
    busy: state.operations.some((item) => item.state === 'running'),
    ...overrides,
  });

/** The runtime's state read (model actions re-read it between steps); nothing else answers. */
const readState = (state: () => Snapshot) => async (resource: string) => {
  if (resource === 'state') return state();
  throw new Error('Unavailable in Storybook');
};
const later = <T,>(ms: number, value: T) =>
  new Promise<T>((resolve) => setTimeout(() => resolve(value), ms));

const region = (canvasElement: HTMLElement, label: string) =>
  within(within(canvasElement).getByRole('region', { name: label }));

// OperationToast portals to document.body and is fixed to the window. Each step here moves its
// toast into its own surface (whose transform contains fixed elements) so every step shows its
// own notification. The node goes back to body before React unmounts it; Close only hides it.
function Docked({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const host = ref.current!;
    const toast = document.body.querySelector<HTMLElement>(':scope > aside.operation');
    if (!toast) return;
    host.append(toast);
    const close = (event: Event) => {
      if ((event.target as Element).closest('[aria-label="Close notification"]')) {
        event.stopPropagation();
        toast.style.display = 'none';
      }
    };
    host.addEventListener('click', close);
    return () => {
      host.removeEventListener('click', close);
      if (toast.parentNode === host) document.body.append(toast);
    };
  }, []);
  return <div ref={ref}>{children}</div>;
}

const Toast = ({ state }: { state: Snapshot }) => (
  <Docked>
    <OperationFeed backend={backend(state)} />
  </Docked>
);

/** Live activity is judged against the clock, so these snapshots are re-stamped every 2 s. */
function Fresh({ make, children }: { make: (at: number) => Snapshot; children: (state: Snapshot) => ReactNode }) {
  const [at, setAt] = useState(now);
  useEffect(() => {
    const timer = setInterval(() => setAt(now()), 2000);
    return () => clearInterval(timer);
  }, []);
  return <>{children(make(at))}</>;
}

/** One pool row, with the state, download and badge derived by the app's own pool.ts. */
function Row({ state, id, requested = {} }: { state: Snapshot; id: string; requested?: Record<string, string> }) {
  const model = state.models.find((item) => item.id === id)!;
  const download = runningDownload(state, id, requested);
  const noop = () => {};
  return (
    <div className="model-list">
      <PoolRow
        model={model}
        earnings={null}
        busy={state.operations.some((item) => item.state === 'running')}
        state={poolState(model, state.autopilot!, !!download)}
        download={download}
        onDownload={noop}
        onJoin={noop}
        onPin={noop}
        onUnpin={noop}
        onRemove={noop}
      />
    </div>
  );
}

const code = (text: string) => <code>{text}</code>;

// ---------------------------------------------------------------------------------------------

const lifecycle = (() => {
  const base = pool();
  const status = base.autopilot!;
  const downloaded = withModel(base, QWEN, { downloaded: true, memory_gb: 24.6 });
  const inPool = { ...downloaded, autopilot: { ...status, selected: [...status.selected, QWEN] } };
  const kept = { ...inPool, autopilot: { ...inPool.autopilot, pinned: [...status.pinned, QWEN] } };
  const keptLoaded = withModel(kept, QWEN, { loaded: true, serving: true });
  const loaded = withModel(inPool, QWEN, { loaded: true, serving: true });
  return {
    base,
    downloading: {
      ...base,
      operations: [operation('download', 'running', { model: QWEN, progress: 0.42, cancellable: true })],
    },
    unattributed: { ...base, operations: [operation('download', 'running', { cancellable: true })] },
    downloaded,
    inPool,
    kept,
    keptLoaded,
    loaded,
    removed: {
      ...withModel(inPool, QWEN, { downloaded: false }),
      autopilot: { ...inPool.autopilot, phase: 'waiting_inventory' as const },
    },
  };
})();

export const Lifecycle: Story = {
  name: 'One model, start to finish',
  beforeEach: () => resetBridges(),
  render: () => (
    <Walkthrough
      title="One model through its lifecycle (Autopilot pool)"
      intro={
        <p>
          Qwen 3.6 35B A3B as its row on <b>Models</b> shows it with Autopilot on, from catalog to
          memory and back off the disk. Each row is the real <code>PoolRow</code>; its badge and
          controls come from <code>poolState()</code> and <code>runningDownload()</code> in{' '}
          <code>features/models/pool.ts</code>, fed by <code>NativeModel</code> flags (
          {code('downloaded')}, {code('loaded')}, {code('serving')}, {code('eligible')}),{' '}
          {code('autopilot.selected')} / {code('autopilot.pinned')} and running{' '}
          {code('operations')}. The rest of the page is in the other Model loading stories.
        </p>
      }
      steps={[
        {
          label: 'Not downloaded',
          note: (
            <p>
              {code('downloaded: false')}, {code('eligible: true')}. Badge “Not downloaded”, the
              download size (no memory figure until the runtime reports {code('memory_gb')}),{' '}
              <b>Download</b> and <b>Download &amp; keep in memory</b>.
            </p>
          ),
          node: <Row state={lifecycle.base} id={QWEN} />,
        },
        {
          label: 'Downloading, with progress',
          note: (
            <p>
              A running {code('download')} operation whose {code('model')} is this model and{' '}
              {code('progress: 0.42')}: the controls become a 42% progress bar. Any running
              operation makes the app busy, so the row's controls are disabled too.
            </p>
          ),
          node: <Row state={lifecycle.downloading} id={QWEN} />,
        },
        {
          label: 'Downloading, progress not reported',
          note: (
            <p>
              A runtime that doesn't attribute downloads sends no {code('model')} or{' '}
              {code('progress')}. The row still shows the download if this page started it (the
              operation id is remembered from the submit), as an indeterminate bar labeled
              “Downloading…”. A download started elsewhere (for example from the CLI) is not
              attributed to any row.
            </p>
          ),
          node: (
            <Row
              state={lifecycle.unattributed}
              id={QWEN}
              requested={{ [lifecycle.unattributed.operations[0].id]: QWEN }}
            />
          ),
        },
        {
          label: 'Downloaded, not in the pool',
          prs: [1461],
          note: (
            <p>
              {code('downloaded: true')} but not in {code('autopilot.selected')}: downloading
              alone never adds a model to the pool. “Downloaded · not in Autopilot”, with{' '}
              <b>Add to pool</b>, <b>Keep in memory</b> and Remove. Since #1461, Add to pool also
              works before Autopilot is set up (it starts Autopilot with this model).
            </p>
          ),
          node: <Row state={lifecycle.downloaded} id={QWEN} />,
        },
        {
          label: 'In the pool, not in memory',
          note: (
            <p>
              In {code('autopilot.selected')}, {code('loaded: false')}: “Available to Autopilot”.
              Autopilot loads it when demand calls for it; nothing for the user to do.
            </p>
          ),
          node: <Row state={lifecycle.inPool} id={QWEN} />,
        },
        {
          label: 'Kept in memory, waiting to load',
          prs: [1477],
          note: (
            <p>
              In {code('autopilot.pinned')} with {code('loaded: false')}: the warming state,
              “Kept · waiting to load”. Remove is disabled; its tooltip says “Stop keeping it in
              memory first” (was “Unpin it first” before #1477).
            </p>
          ),
          node: <Row state={lifecycle.kept} id={QWEN} />,
        },
        {
          label: 'Kept in memory and loaded',
          prs: [1477],
          note: (
            <p>
              Pinned, {code('loaded: true')}, {code('serving: true')}: “In memory · kept”; the
              pressed <b>Keep in memory</b> toggle turns it off.
            </p>
          ),
          node: <Row state={lifecycle.keptLoaded} id={QWEN} />,
        },
        {
          label: 'In memory, managed by Autopilot',
          note: (
            <p>
              Not pinned, {code('loaded: true')}: “In memory”. Remove stays disabled while{' '}
              {code('loaded')} or {code('serving')} (“Stop serving this model before removing
              it”).
            </p>
          ),
          node: <Row state={lifecycle.loaded} id={QWEN} />,
        },
        {
          label: 'Removed from this Mac',
          note: (
            <p>
              After {code('remove')}, {code('downloaded: false')} takes precedence over pool
              membership: the row is “Not downloaded” again even though{' '}
              {code('autopilot.selected')} still lists it until the pool is refreshed (see the{' '}
              <i>Removing a model</i> story).
            </p>
          ),
          node: <Row state={lifecycle.removed} id={QWEN} />,
        },
        {
          label: 'Too large for this Mac',
          note: (
            <p>
              Kimi K2.6: {code('eligible: false')} with the runtime's {code('reason')} (“Needs 512
              GB of unified memory.”). “Not available”, the reason in place of size facts, and no
              controls.
            </p>
          ),
          node: <Row state={lifecycle.base} id="kimi-k2.6" />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const downloadFlow = {
  start: pool(),
  running: pool({
    operations: [
      operation('download', 'running', { id: 'download-qwen', model: QWEN, progress: 0.42, cancellable: true }),
    ],
  }),
  cancelled: pool({
    operations: [operation('download', 'cancelled', { id: 'download-qwen-cancelled', model: QWEN, finished_at: now() })],
  }),
  failed: pool({
    operations: [
      operation('download', 'failed', {
        id: 'download-qwen-failed',
        model: QWEN,
        finished_at: now(),
        message: 'Not enough disk space: Qwen 3.6 35B A3B needs 21.3 GB and 9.8 GB is free.',
      }),
    ],
  }),
  interrupted: pool({
    operations: [operation('download', 'interrupted', { id: 'download-qwen-interrupted', model: QWEN, finished_at: now() })],
  }),
};

export const Download: Story = {
  name: 'Downloading a model',
  beforeEach: () =>
    resetBridges({
      read: readState(() => downloadFlow.start),
      // A download and the pool refresh each take a moment, as they do against the runtime.
      act: (action: Action) => later(3500, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    const choose = region(canvasElement, 'Choose Download');
    await userEvent.click(choose.getByRole('button', { name: 'Not downloaded' }));
    await userEvent.click(choose.getByRole('button', { name: /^Download$/ }));
    const progress = region(canvasElement, 'Download in progress');
    await userEvent.click(progress.getByRole('button', { name: 'Show 1 more model' }));
    await userEvent.click(progress.getByRole('button', { name: 'Cancel' }));
    await userEvent.click(region(canvasElement, 'Download failed').getByText('Qwen 3.6 35B A3B download · Failed'));
    await userEvent.click(region(canvasElement, 'Download cancelled').getByRole('button', { name: 'Not downloaded' }));
  },
  render: () => (
    <Walkthrough
      title="Downloading a model"
      intro={
        <p>
          The full <b>Models</b> page with Autopilot on. Downloads are runtime{' '}
          {code('operations')} ({code('action: "download"')}); the row and the notification at
          the bottom both read the same operation. The play step downloads Qwen 3.6 35B A3B and
          cancels the running download; the log at the end lists what was sent.
        </p>
      }
      log
      steps={[
        {
          label: 'Choose Download',
          prs: [1461],
          note: (
            <p>
              Under <b>Not downloaded</b>, the play step clicks <b>Download</b>. The row shows
              “Downloading…” at once and every model control locks (the label is set before
              anything is awaited, #1461). The app sends {code('download')}, re-reads state, and
              because Autopilot is on and the model isn't in {code('autopilot.selected')}, follows
              with {code('autopilot_models')} (“Joining the pool…”). Each mocked step takes 3.5 s.
            </p>
          ),
          node: <Models backend={backend(downloadFlow.start)} embedded />,
        },
        {
          label: 'Download in progress',
          note: (
            <p>
              Running operation with {code('model')}, {code('progress: 0.42')},{' '}
              {code('cancellable: true')}: the row moves into <b>Your models</b> (fourth, so the
              play step expands the list) with a progress bar, and the notification names the
              model with the row's progress, “Downloading Qwen 3.6 35B A3B · 42%” (#1492; it read
              “Downloading model” before), with <b>Cancel</b>, which the play step clicks
              ({code('cancel')} with the operation id, in the log).
            </p>
          ),
          prs: [1492],
          node: (
            <>
              <Models backend={backend(downloadFlow.running)} embedded />
              <Toast state={downloadFlow.running} />
            </>
          ),
        },
        {
          label: 'Download cancelled',
          prs: [1492],
          note: (
            <p>
              Operation {code('state: "cancelled"')}: “Qwen 3.6 35B A3B download · Cancelled”
              (#1492; “Model download · Cancelled” before), closable. The
              model is {code('downloaded: false')} again, so it leaves <b>Your models</b>; the play
              step switches to <b>Not downloaded</b> to show the row back at Download.
            </p>
          ),
          node: (
            <>
              <Models backend={backend(downloadFlow.cancelled)} embedded />
              <Toast state={downloadFlow.cancelled} />
            </>
          ),
        },
        {
          label: 'Download failed',
          note: (
            <p>
              {code('state: "failed"')} with the runtime's {code('message')}: “Qwen 3.6 35B A3B
              download · Failed” (#1492; “Model download · Failed” before); the play step expands
              the title to show the message (fixture text). Failed toasts stay until closed. A
              download the runtime doesn't attribute to a model still reads “Downloading model” /
              “Model download · …”.
            </p>
          ),
          prs: [1492],
          height: 300,
          node: <Toast state={downloadFlow.failed} />,
        },
        {
          label: 'Download interrupted',
          note: (
            <p>
              {code('state: "interrupted"')} (for example the runtime restarted mid-download):
              “Qwen 3.6 35B A3B download · Interrupted” (#1492), announced as an alert like a
              failure.
            </p>
          ),
          prs: [1492],
          height: 200,
          node: <Toast state={downloadFlow.interrupted} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const chosen = ['gpt-oss-20b', 'gemma-4-26b'];
const loadFlow = {
  stopped: manual({
    state: 'stopped',
    models: pool().models.map((model) => ({ ...model, loaded: false })),
    memory: { total_gb: 64 },
    machine: { ...pool().machine, status: 'stopped', models: [] },
  }),
  starting: manual({
    state: 'starting',
    models: pool().models.map((model) => ({ ...model, loaded: false })),
    memory: { total_gb: 64 },
    operations: [operation('start', 'running', { id: 'start-flow' })],
  }),
  warming: (at: number) =>
    manual({
      observed_at: at,
      models: pool().models.map((model) => ({ ...model, loaded: false })),
      memory: { total_gb: 64, active_gb: 9.4, free_for_load_gb: 46 },
      activity: {
        samples: [],
        sampled_at: at,
        models: chosen.map((model) => ({ model, state: 'reloading', running: 0, waiting: 2 })),
      },
    }),
  serving: (at: number) =>
    manual({
      observed_at: at,
      activity: {
        samples: [],
        sampled_at: at,
        models: [
          { model: 'gpt-oss-20b', state: 'running', running: 3, waiting: 0 },
          { model: 'gemma-4-26b', state: 'idle', running: 0, waiting: 0 },
        ],
      },
    }),
};

export const LoadAndServe: Story = {
  name: 'Loading into memory and serving',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Chosen, not serving yet').getAllByRole('button', { name: /Start serving/ })[0],
    );
  },
  render: () => (
    <Walkthrough
      title="Loading models into memory and serving"
      intro={
        <p>
          Manual selection (Autopilot off): the user chooses downloaded models and starts the
          provider; the runtime loads them, then serves. Readiness (<code>HealthBar</code>, the top
          of This Mac) is derived from {code('state')}, {code('operations')}, the models'{' '}
          {code('serving')} / {code('loaded')} flags and the slot postures in{' '}
          {code('activity.models')}; <code>LiveModels</code> (Stats) and{' '}
          <code>ServingModels</code> (This Mac) show the same facts.
        </p>
      }
      log
      steps={[
        {
          label: 'Chosen, not serving yet',
          note: (
            <p>
              {code('state: "stopped"')}, GPT-OSS 20B and Gemma 4 26B {code('serving: true')}{' '}
              (chosen) and downloaded: Next steps says they're “selected and ready to serve”. The
              play step clicks <b>Start serving</b> (“Start providing” before #1501); the log
              shows{' '}
              {code('{"action":"start","models":[…]}')}.
            </p>
          ),
          node: <HealthBar backend={backend(loadFlow.stopped)} navigate={() => {}} />,
        },
        {
          label: 'Starting to serve',
          note: (
            <p>
              A running {code('start')} operation: the readiness status is the operation's own
              label, “Starting to serve” (“Starting provider” before #1501), and the notification
              says the same. While it runs the app is busy and other actions are disabled.
            </p>
          ),
          prs: [1501],
          height: 300,
          node: (
            <>
              <HealthBar backend={backend(loadFlow.starting)} navigate={() => {}} />
              <Toast state={loadFlow.starting} />
            </>
          ),
        },
        {
          label: 'Loading into memory',
          note: (
            <p>
              {code('state: "running"')}, chosen models {code('loaded: false')}, slots{' '}
              {code('state: "reloading"')}: “Loading models · GPT-OSS 20B and Gemma 4 26B are
              loading into memory”, and Models at work reads “Loading”. Waiting requests are
              counted, none processing. Models shows no “In memory” tag yet.
            </p>
          ),
          node: (
            <Fresh make={loadFlow.warming}>
              {(state) => (
                <>
                  <HealthBar backend={backend(state)} navigate={() => {}} />
                  <LiveModels state={state} />
                </>
              )}
            </Fresh>
          ),
        },
        {
          label: 'Loaded and serving',
          note: (
            <p>
              {code('loaded: true')}, slots {code('running')} / {code('idle')} with a fresh{' '}
              {code('activity.sampled_at')}: “Ready to serve”, three requests lit on GPT-OSS,
              Gemma “Ready”, the model chips from {code('machine.models')}, and “In memory” on the
              Models rows. Activity older than 10 s turns “Not current” (see{' '}
              <i>Unknown or stale memory</i>).
            </p>
          ),
          node: (
            <Fresh make={loadFlow.serving}>
              {(state) => (
                <>
                  <HealthBar backend={backend(state)} navigate={() => {}} />
                  <LiveModels state={state} />
                  <ServingModels state={state} models={state.machine.models} onManage={() => {}} />
                  <Models backend={backend(state)} embedded />
                </>
              )}
            </Fresh>
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const failureFlow = {
  crashed: (at: number) =>
    manual({
      observed_at: at,
      activity: {
        samples: [],
        sampled_at: at,
        models: [
          { model: 'gpt-oss-20b', state: 'running', running: 1, waiting: 0 },
          { model: 'gemma-4-26b', state: 'crashed', running: 0, waiting: 0 },
        ],
      },
    }),
  startFailed: manual({
    state: 'stopped',
    models: pool().models.map((model) => ({ ...model, loaded: false })),
    memory: { total_gb: 64 },
    operations: [
      operation('start', 'failed', {
        id: 'start-failed-flow',
        finished_at: now(),
        message:
          'Gemma 4 26B needs 21.4 GB of memory and 12.0 GB is free to load. Choose fewer or smaller models.',
      }),
    ],
  }),
  pinRejected: pool(),
};

export const LoadFailure: Story = {
  name: 'When loading fails',
  beforeEach: () =>
    resetBridges({
      read: readState(() => failureFlow.pinRejected),
      act: async (action: Action) =>
        action.action === 'autopilot_pin'
          ? {
              ...succeeded(action.action),
              state: 'failed',
              message: 'Keeping these models in memory needs 45.0 GB; 41.6 GB is available.',
            }
          : succeeded(action.action),
    }),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'A model stopped unexpectedly').getByRole('button', { name: 'Restart serving' }),
    );
    await userEvent.click(
      region(canvasElement, 'Keep in memory rejected').getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' }),
    );
    await userEvent.click(region(canvasElement, 'Start failed').getByText('Start serving · Failed'));
  },
  render: () => (
    <Walkthrough
      title="When a model fails to load"
      intro={
        <p>
          The desktop contract has no per-model load error field. A load failure reaches the UI
          three ways: a slot posture of {code('crashed')} in {code('activity.models')}, a failed
          lifecycle {code('operation')} with the runtime's {code('message')}, or a model action
          from the Models page that the runtime rejects (shown as a notice on the page). Message
          texts here are fixture examples.
        </p>
      }
      log
      steps={[
        {
          label: 'A model stopped unexpectedly',
          note: (
            <p>
              Gemma's slot reports {code('state: "crashed"')}: readiness reads “Needs restart ·
              Gemma 4 26B stopped unexpectedly” with <b>Restart serving</b> (the play step clicks
              it: {code('restart')} in the log), and Models at work shows “Needs restart” on that
              lane while GPT-OSS keeps serving.
            </p>
          ),
          node: (
            <Fresh make={failureFlow.crashed}>
              {(state) => (
                <>
                  <HealthBar backend={backend(state)} navigate={() => {}} />
                  <LiveModels state={state} />
                </>
              )}
            </Fresh>
          ),
        },
        {
          label: 'Start failed',
          note: (
            <p>
              A {code('start')} operation with {code('state: "failed"')}: “Start serving ·
              Failed” (“Provider start · Failed” before #1501), the runtime's message under the
              title (expanded by the play step). The provider is back at {code('stopped')}, so
              readiness offers Start serving again.
            </p>
          ),
          height: 340,
          node: (
            <>
              <HealthBar backend={backend(failureFlow.startFailed)} navigate={() => {}} />
              <Toast state={failureFlow.startFailed} />
            </>
          ),
        },
        {
          label: 'Keep in memory rejected',
          note: (
            <p>
              The play step clicks <b>Keep in memory</b> on Qwen 3.5 9B; the mocked runtime fails
              the {code('autopilot_pin')} operation. The page shows the runtime's message as a
              dismissible notice above the Autopilot card, and the row returns to its controls.
            </p>
          ),
          node: <Models backend={backend(failureFlow.pinRejected)} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const removeFlow = {
  pool: pool(),
  refresh: (() => {
    const state = withModel(pool(), 'qwen-3.5-9b', { downloaded: false });
    return { ...state, autopilot: { ...state.autopilot!, phase: 'waiting_inventory' as const } };
  })(),
  manual: manual(),
};

export const Remove: Story = {
  name: 'Removing a model',
  beforeEach: () =>
    resetBridges({
      read: readState(() => removeFlow.pool),
      act: (action: Action) => later(6000, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    const ask = region(canvasElement, 'Remove from the pool');
    await userEvent.click(ask.getByRole('button', { name: 'Remove Qwen 3.5 9B' }));
    const confirm = region(canvasElement, 'Confirm removal');
    await userEvent.click(confirm.getByRole('button', { name: 'Remove Qwen 3.5 9B' }));
    await userEvent.click(confirm.getByRole('button', { name: 'Remove model' }));
    const refresh = region(canvasElement, 'Refresh the pool');
    await userEvent.click(refresh.getByText('Refresh models needed details'));
    await userEvent.click(refresh.getByRole('button', { name: /Update available models/ }));
    const manualStep = region(canvasElement, 'Remove with Autopilot off');
    await userEvent.click(manualStep.getByRole('button', { name: 'Remove Qwen 3.5 9B' }));
    await userEvent.click(manualStep.getByRole('button', { name: 'Remove model' }));
  },
  render: () => (
    <Walkthrough
      title="Removing a model"
      intro={
        <p>
          Removing deletes a downloaded model from disk ({code('{"action":"remove"}')}). Only a
          model that is neither {code('loaded')}, {code('serving')} nor kept in memory can be
          removed; on this page GPT-OSS (loaded) and Gemma (kept) have their Remove buttons
          disabled with a tooltip saying why. The play step removes Qwen 3.5 9B.
        </p>
      }
      log
      steps={[
        {
          label: 'Remove from the pool',
          prs: [1477],
          note: (
            <p>
              Qwen 3.5 9B is in {code('autopilot.selected')}, so the dialog says to update
              available models afterward. “Keep model” has focus.
            </p>
          ),
          node: <Models backend={backend(removeFlow.pool)} embedded />,
        },
        {
          label: 'Confirm removal',
          prs: [1461],
          note: (
            <p>
              <b>Remove model</b> closes the dialog and the row shows “Removing…” while every
              model control stays locked until the operation ends ({code('remove')} in the log).
            </p>
          ),
          node: <Models backend={backend(removeFlow.pool)} embedded />,
        },
        {
          label: 'Refresh the pool',
          note: (
            <p>
              Afterwards the runtime reports {code('downloaded: false')} and Autopilot phase{' '}
              {code('waiting_inventory')}: “Refresh models needed”. The play step opens the details
              and clicks <b>Update available models</b> ({code('autopilot_models')}).
            </p>
          ),
          node: <Models backend={backend(removeFlow.refresh)} embedded />,
        },
        {
          label: 'Remove with Autopilot off',
          prs: [1468],
          note: (
            <p>
              Manual selection uses the plain dialog copy; the play step confirms and{' '}
              {code('remove')} is sent directly (no pool to refresh). Since
              #1468 a removed model also leaves the selection, so <b>Apply selection</b> can't
              submit it (see Fixes › Models).
            </p>
          ),
          node: <Models backend={backend(removeFlow.manual)} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const runtimeLimited = withModel(manual(), 'qwen-3.6-35b', {
  eligible: false,
  reason: 'Needs a newer Darkbloom runtime.',
});

export const NotForThisMac: Story = {
  name: 'Models this Mac can’t run',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Too large: Autopilot view').getByRole('button', { name: 'Browse models' }),
    );
    for (const label of ['Too large: manual view', 'Needs something the runtime lacks'])
      await userEvent.click(region(canvasElement, label).getByRole('button', { name: /Show 2 more models/ }));
  },
  render: () => (
    <Walkthrough
      title="Models this Mac can’t run"
      intro={
        <p>
          The runtime decides eligibility per model and reports it as {code('eligible: false')}{' '}
          with a free-text {code('reason')}; the app never re-derives it. A Mac where nothing is
          eligible can't turn Autopilot on, and a runtime without Autopilot gets manual selection
          only (see Flows › Autopilot).
        </p>
      }
      steps={[
        {
          label: 'Too large: Autopilot view',
          note: (
            <p>
              Under <b>Browse models</b> (opened by the play step), Kimi K2.6 reads “Not
              available” with its reason and has no controls.
            </p>
          ),
          node: <Models backend={backend(pool())} embedded />,
        },
        {
          label: 'Too large: manual view',
          prs: [1468],
          note: (
            <p>
              With Autopilot off the reason is shown under the name, the checkbox is disabled, and
              since a #1468 follow-up <b>Download</b> is disabled with the reason as its tooltip
              (it used to start a download the Mac couldn't use).
            </p>
          ),
          node: <Models backend={backend(manual())} embedded />,
        },
        {
          label: 'Needs something the runtime lacks',
          prs: [1468],
          note: (
            <p>
              The same path for a non-memory reason: Qwen 3.6 35B A3B with{' '}
              {code('reason: "Needs a newer Darkbloom runtime."')} (illustrative wording; the app
              shows whatever the runtime sends).
            </p>
          ),
          node: <Models backend={backend(runtimeLimited)} embedded />,
        },
        {
          label: 'An 8 GB Mac',
          note: (
            <p>
              The app's {code('eightGBMac()')} fixture: the only catalog model, GPT-OSS 20B, is on
              disk but {code('eligible: false')} (“Needs 16.4 GB of unified memory”), so it can't be
              selected; <b>Start serving</b> and <b>Turn on Autopilot</b> are disabled because
              there is no eligible model to start with.
            </p>
          ),
          node: (
            <Models
              backend={backend({
                ...eightGBMac(),
                autopilot: { enabled: false, paused: false, selected: [], pinned: [], phase: 'off' },
              })}
              embedded
            />
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const unknownFlow = {
  undetected: manual({ memory: { total_gb: 0 } }),
  unmeasured: (() => {
    const state = pool({ memory: { total_gb: 64, active_gb: 37.8 } });
    return withModel(withModel(state, 'qwen-3.5-9b', { memory_gb: null }), 'gpt-oss-20b', {
      memory_gb: undefined,
    });
  })(),
  stale: manual({
    state: 'stale',
    observed_at: now() - 300,
    activity: {
      samples: [],
      sampled_at: now() - 300,
      models: [
        { model: 'gpt-oss-20b', state: 'running', running: 4, waiting: 1 },
        { model: 'gemma-4-26b', state: 'idle', running: 0, waiting: 0 },
      ],
    },
  }),
};

export const UnknownMemory: Story = {
  name: 'Unknown or stale memory',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Status out of date').getByRole('button', { name: 'Restart serving' }),
    );
  },
  render: () => (
    <Walkthrough
      title="Unknown or stale memory and status"
      intro={
        <p>
          What the UI does when the runtime can't say how much memory there is, hasn't measured a
          model yet, or stops reporting. Unknown is never drawn as zero.
        </p>
      }
      log
      steps={[
        {
          label: 'Memory not detected',
          prs: [1465, 1477],
          note: (
            <p>
              {code('memory: { total_gb: 0 }')} (hardware detection failed) and no{' '}
              {code('active_gb')}: Models says “Memory available for models —” (renamed from
              “Native load allowance”, #1477), draws no usage bar and reads “Unified memory
              unknown”; the Memory cell reads “Memory unknown” (#1465).
            </p>
          ),
          node: (
            <>
              <HealthBar backend={backend(unknownFlow.undetected)} navigate={() => {}} />
              <Models backend={backend(unknownFlow.undetected)} embedded />
            </>
          ),
        },
        {
          label: 'Model memory not measured yet',
          note: (
            <p>
              GPT-OSS 20B and Qwen 3.5 9B without {code('memory_gb')}: their rows list only the
              size on disk, no “needs … memory”. Memory limits for keeping models in memory fall
              back to the download size for unmeasured models.
            </p>
          ),
          node: <Models backend={backend(unknownFlow.unmeasured)} embedded />,
        },
        {
          label: 'Status out of date',
          note: (
            <p>
              {code('state: "stale"')} and {code('observed_at')} / {code('activity.sampled_at')}{' '}
              five minutes old: readiness says “Status unavailable · Restart serving” (the play
              step clicks it), and Models at work hides the last counts (“—”, “Not current”)
              instead of showing four requests as live.
            </p>
          ),
          node: (
            <>
              <HealthBar backend={backend(unknownFlow.stale)} navigate={() => {}} />
              <LiveModels state={unknownFlow.stale} />
            </>
          ),
        },
      ]}
    />
  ),
};
