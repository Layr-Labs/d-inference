import { useLayoutEffect, useRef, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Models } from '../../src/after/desktop-app/src/renderer/features/models/Models';
import { AutopilotCard } from '../../src/after/desktop-app/src/renderer/features/models/AutopilotCard';
import { ServingModels } from '../../src/after/desktop-app/src/renderer/features/machines/overview/ServingModels';
import { OperationFeed } from '../../src/after/desktop-app/src/renderer/components/operations/OperationFeed';
import type { BackendState } from '../../src/after/desktop-app/src/renderer/useBackend';
import type { AutopilotStatus } from '../../src/after/desktop-app/src/shared/autopilot';
import type {
  Action,
  NetworkData,
  Operation,
  Snapshot,
} from '../../src/after/desktop-app/src/shared/contracts';
import { Walkthrough } from '../support/Walkthrough';
import { resetBridges, succeeded } from '../support/bridge';
import { backendFor, poolSnapshot } from '../support/fixtures';

const meta: Meta = { title: 'Flows/Autopilot' };
export default meta;
type Story = StoryObj;

// ---------------------------------------------------------------------------------------------
// Fixtures. poolSnapshot() is Autopilot on: pool (`selected`) GPT-OSS 20B, Gemma 4 26B and
// Qwen 3.5 9B; Gemma kept in memory (`pinned`); GPT-OSS and Gemma loaded. Qwen 3.6 35B A3B is
// not downloaded and Kimi K2.6 is too large for this 64 GB Mac.

const now = () => Math.floor(Date.now() / 1000);
const machine = { ...poolSnapshot().machine, status: 'running', models: ['gpt-oss-20b', 'gemma-4-26b'] };

const on = (autopilot: Partial<AutopilotStatus> = {}, overrides: Partial<Snapshot> = {}) =>
  poolSnapshot(autopilot, { machine, ...overrides });
const off = (overrides: Partial<Snapshot> = {}) =>
  on({ enabled: false, phase: 'off' }, overrides);
// A Mac that never set Autopilot up: nothing loaded or chosen yet.
const neverSetUp = (overrides: Partial<Snapshot> = {}) =>
  on(
    { configured: false, enabled: false, selected: [], pinned: [], phase: 'off' },
    {
      state: 'stopped',
      models: poolSnapshot().models.map((model) => ({ ...model, loaded: false, serving: false })),
      machine: { ...machine, status: 'stopped', models: [] },
      ...overrides,
    },
  );

const operation = (
  action: Operation['action'],
  state: Operation['state'],
  extra: Partial<Operation> = {},
): Operation => ({
  id: `${action}-${state}-autopilot-flow`,
  action,
  state,
  started_at: now() - 40,
  message: '',
  cancellable: false,
  ...extra,
});

// Seven-day network earnings, fresh (recommendations ignore figures older than five minutes).
const network = (): NetworkData => ({
  model_earnings: {
    window: '7d',
    as_of: new Date().toISOString(),
    models: [
      { id: 'qwen-3.6-35b', earnings_micro_usd: '48210000' },
      { id: 'gemma-4-26b', earnings_micro_usd: '31800000' },
      { id: 'gpt-oss-20b', earnings_micro_usd: '22050000' },
      { id: 'qwen-3.5-9b', earnings_micro_usd: '9100000' },
    ],
  },
});

// As useBackend derives it: any running operation makes the app busy.
const backend = (state: Snapshot, overrides: Partial<BackendState> = {}) =>
  backendFor('after', state, {
    busy: state.operations.some((item) => item.state === 'running'),
    ...overrides,
  });

const later = <T,>(ms: number, value: T) =>
  new Promise<T>((resolve) => setTimeout(() => resolve(value), ms));
const region = (canvasElement: HTMLElement, label: string) =>
  within(within(canvasElement).getByRole('region', { name: label }));
const code = (text: string) => <code>{text}</code>;

// OperationToast portals to document.body and is fixed to the window; move it into this step's
// surface (whose transform contains fixed elements). It goes back to body before React unmounts
// it; Close only hides it here.
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

const Card = ({ state }: { state: Snapshot }) => {
  const noop = () => {};
  return (
    <AutopilotCard
      snapshot={state}
      onPause={noop}
      onResume={noop}
      onTurnOff={noop}
      onRefresh={noop}
    />
  );
};

// ---------------------------------------------------------------------------------------------

// Which link state the runtime's state read reports; the play step flips it for one step.
let linkedRead = true;

export const TurnOn: Story = {
  name: 'Turning Autopilot on',
  beforeEach: () => {
    linkedRead = true;
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return { ...off(), linked: linkedRead };
        throw new Error('Unavailable in Storybook');
      },
      act: (action: Action) => later(6000, succeeded(action.action)),
    });
  },
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Off: the turn-on offer').getByRole('button', { name: 'Turn on Autopilot' }),
    );
    linkedRead = false;
    await userEvent.click(
      region(canvasElement, 'This Mac isn’t linked yet').getByRole('button', {
        name: 'Link this Mac & turn on Autopilot',
      }),
    );
    linkedRead = true;
    await userEvent.click(
      region(canvasElement, 'Never set up: recommendations').getByRole('button', {
        name: 'Download & start Autopilot',
      }),
    );
  },
  render: () => (
    <Walkthrough
      title="Turning Autopilot on"
      intro={
        <p>
          <code>modelsMode()</code> in <code>pool.ts</code> picks the page: no{' '}
          {code('autopilot')} block means the runtime can't run it (manual only);{' '}
          {code('enabled: true')} or {code('configured: false')} shows the Autopilot pool; anything
          else is manual selection with a turn-on offer. Turning on has no confirmation: it's
          one action, {code('{"action":"autopilot", models, pinned, downloads?, endpoint}')},
          mirroring {code('darkbloom start --autopilot')}. The play step turns it on three ways;
          the log lists what was sent.
        </p>
      }
      log
      steps={[
        {
          label: 'Off: the turn-on offer',
          note: (
            <p>
              {code('autopilot.enabled: false')}, {code('phase: "off"')}: manual selection with the
              Autopilot offer above the memory summary. The play step clicks <b>Turn on
              Autopilot</b>; it shows “Turning on…” and sends the models serving now (GPT-OSS,
              Gemma) with {code('pinned: []')}. Saved pins stay with the runtime. While it turns
              on, <b>Apply selection</b>, <b>Download</b> and <b>Remove</b> are disabled too; before
              #1490 they only checked {code('backend.busy')}, which doesn't see the turn-on, so
              Apply could send {code('switch')} on top of it (fixed by #1490).
            </p>
          ),
          prs: [1490],
          node: <Models backend={backend(off())} embedded />,
        },
        {
          label: 'Off while another operation runs',
          prs: [1461],
          note: (
            <p>
              A running {code('download')} operation makes the app busy: <b>Turn on Autopilot</b>{' '}
              is disabled along with <b>Apply selection</b> (before #1461 it stayed clickable and
              could start Autopilot on top of the operation).
            </p>
          ),
          node: (
            <Models
              backend={backend(
                off({ operations: [operation('download', 'running', { model: 'qwen-3.6-35b', progress: 0.3 })] }),
              )}
              embedded
            />
          ),
        },
        {
          label: 'This Mac isn’t linked yet',
          note: (
            <p>
              {code('linked: false')}. The button reads <b>Link this Mac &amp; turn on
              Autopilot</b>, and a line under the offer says what happens before the click: a code
              shown here, the link page opened in the browser to approve it, then Autopilot starts
              (#1499; it read plain <b>Turn on Autopilot</b> with no warning). Before any{' '}
              {code('autopilot')} action the app re-reads state and, if the Mac still isn't
              linked, sends {code('link')} first and waits for it, then the {code('autopilot')}{' '}
              action (two entries in the log). Once the runtime reports a link code, the <i>Link
              this Mac</i> dialog shows it on this manual page too (it appeared only on the
              Autopilot page before #1499); see <i>Fourth pass › Team review fixes</i>.
            </p>
          ),
          prs: [1499],
          node: <Models backend={backend(off({ linked: false }))} embedded />,
        },
        {
          label: 'Never set up: recommendations',
          prs: [1472],
          note: (
            <p>
              {code('configured: false')} opens the Autopilot pool in setup form: “Ready to start”,
              and with fresh {code('network.model_earnings')} the three top-earning eligible models
              are pre-checked. One isn't downloaded, so the button reads <b>Download &amp; start
              Autopilot</b> and the footer “1 download · 21.3 GB total” (singular since #1472).
              The play step clicks it: {code('downloads')} lists Qwen 3.6, and {code('models')}{' '}
              holds only the first chosen model.
            </p>
          ),
          node: <Models backend={backend(neverSetUp(), { network: network() })} embedded />,
        },
        {
          label: 'Never set up, no recommendations',
          prs: [1461],
          note: (
            <p>
              Without network earnings: “Network recommendations are unavailable”. Downloaded
              models read “Downloaded · not in Autopilot”; their <b>Add to pool</b> starts
              Autopilot with that model (a no-op before #1461), and the toolbar's <b>Turn on
              Autopilot</b> starts with the default model.
            </p>
          ),
          node: <Models backend={backend(neverSetUp())} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

export const PauseAndSwitch: Story = {
  name: 'Pausing and switching to manual',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return on();
        throw new Error('Unavailable in Storybook');
      },
      act: (action: Action) => later(4000, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    await userEvent.click(region(canvasElement, 'Pause asks first').getByRole('button', { name: 'Pause' }));
    await userEvent.click(
      region(canvasElement, 'Switch to manual asks first').getByRole('button', { name: 'Switch to manual' }),
    );
    const confirmed = region(canvasElement, 'Switching to manual');
    await userEvent.click(confirmed.getByRole('button', { name: 'Switch to manual' }));
    await userEvent.click(confirmed.getByRole('button', { name: 'Turn off Autopilot' }));
    const paused = region(canvasElement, 'Paused');
    await userEvent.click(paused.getByText('Paused details'));
    await userEvent.click(paused.getByRole('button', { name: 'Resume' }));
  },
  render: () => (
    <Walkthrough
      title="Pausing Autopilot and switching back to manual"
      intro={
        <p>
          Pause and turn-off are confirmed first (<code>AutopilotConfirm</code>); resume isn't.
          Neither pause nor turn-off unloads anything. The play step opens both dialogs, confirms
          the switch, and resumes a paused Autopilot.
        </p>
      }
      log
      steps={[
        {
          label: 'Pause asks first',
          prs: [1477],
          note: (
            <p>
              <b>Pause</b> opens “Pause Autopilot?”. The copy says models kept in memory stay
              loaded (it said “pins keep protecting theirs” before #1477).
            </p>
          ),
          node: <Models backend={backend(on())} embedded />,
        },
        {
          label: 'Switch to manual asks first',
          prs: [1477],
          note: (
            <p>
              <b>Switch to manual</b> opens “Turn off Autopilot?” with a danger-styled confirm: the
              pool and the models kept in memory are saved for later (“pool and pins” before
              #1477).
            </p>
          ),
          node: <Models backend={backend(on())} embedded />,
        },
        {
          label: 'Switching to manual',
          prs: [1461],
          note: (
            <p>
              Confirming sends {code('autopilot_disable')}; the card shows “Turning off…” in place
              of its buttons and every model control is locked until it finishes.
            </p>
          ),
          node: <Models backend={backend(on())} embedded />,
        },
        {
          label: 'Back in manual selection',
          note: (
            <p>
              The runtime now reports {code('enabled: false')}, {code('phase: "off"')} with{' '}
              {code('selected')} / {code('pinned')} still saved. Models stay loaded (“In memory”
              tags), the serving ones are pre-checked for <b>Apply selection</b>, and the turn-on
              offer is back.
            </p>
          ),
          node: <Models backend={backend(off())} embedded />,
        },
        {
          label: 'Paused',
          prs: [1477],
          note: (
            <p>
              {code('paused: true')} / {code('phase: "paused"')}: amber “Paused”, <b>Resume</b> in
              place of Pause, and details saying loaded and kept models stay as they are. The play
              step resumes ({code('autopilot_resume')}, no dialog).
            </p>
          ),
          node: <Models backend={backend(on({ paused: true, phase: 'paused' }))} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const phases: { label: string; phase: AutopilotStatus['phase']; note: ReactNode }[] = [
  {
    label: 'Observing demand',
    phase: 'shadow',
    note: <p>{code('phase: "shadow"')}: records what it would load but changes nothing yet.</p>,
  },
  {
    label: 'Waiting for control',
    phase: 'waiting',
    note: <p>{code('phase: "waiting"')}: the network hasn't handed it control; models stay as they are.</p>,
  },
  {
    label: 'Changing models',
    phase: 'transitioning',
    note: <p>{code('phase: "transitioning"')}: swapping what's loaded; requests in progress finish first.</p>,
  },
  {
    label: 'Recovering',
    phase: 'recovering',
    note: <p>{code('phase: "recovering"')} (amber): reconciling what's loaded after an interruption.</p>,
  },
  {
    label: 'Checking status',
    phase: undefined,
    note: (
      <p>
        No {code('phase')} while {code('state: "running"')}: the daemon isn't reporting yet, so
        “Checking status” rather than guessing.
      </p>
    ),
  },
];

export const On: Story = {
  name: 'Autopilot on: what it chose',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    for (const { label } of phases)
      await userEvent.click(region(canvasElement, label).getByText(`${label} details`));
  },
  render: () => (
    <Walkthrough
      title="Autopilot on, and what it chose"
      intro={
        <p>
          With Autopilot on, people choose what's on disk ({code('downloaded')}), what's in the
          pool ({code('autopilot.selected')}) and what's kept in memory ({code('autopilot.pinned')});
          Autopilot chooses what's {code('loaded')}. There is no selection to apply. The card's
          label and detail come from <code>phaseCopy()</code> for {code('autopilot.phase')}; the
          play step opens each phase's details.
        </p>
      }
      steps={[
        {
          label: 'On: the pool and what is loaded',
          prs: [1477],
          note: (
            <p>
              {code('phase: "active"')}: green “On”, “3 available · 2 in memory” (pool size, and
              models with {code('loaded: true')}). Rows: GPT-OSS “In memory” (Autopilot's choice),
              Gemma “In memory · kept”, Qwen 3.5 “Available to Autopilot”. Footer “3 downloaded · 1
              kept in memory”. This Mac's model chips come from {code('machine.models')}.
            </p>
          ),
          node: (
            <>
              <Models backend={backend(on())} embedded />
              <ServingModels state={on()} models={machine.models} onManage={() => {}} />
            </>
          ),
        },
        ...phases.map(({ label, phase, note }) => ({
          label,
          note,
          node: <Card state={on({ phase })} />,
        })),
        {
          label: 'On, provider stopped',
          note: (
            <p>
              {code('enabled: true')} with {code('state: "stopped"')} and no phase: “Ready ·
              Autopilot takes over once this Mac is serving”, and the header offers <b>Start
              serving</b> (the same {code('autopilot')} action as turning on).
            </p>
          ),
          node: (
            <Models
              backend={backend(
                on(
                  { phase: undefined },
                  {
                    state: 'stopped',
                    models: poolSnapshot().models.map((model) => ({ ...model, loaded: false })),
                  },
                ),
              )}
              embedded
            />
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const slots = on({ pinned: ['gemma-4-26b', 'qwen-3.5-9b'] }, {
  memory: { total_gb: 64, active_gb: 37.8, free_for_load_gb: 20, max_model_slots: 2 },
});
const budget = on({}, { memory: { total_gb: 64, active_gb: 37.8, free_for_load_gb: 20, pin_budget_gb: 30 } });

export const ModelSlots: Story = {
  name: 'Model slots and memory limits',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Download & keep, over the budget').getByRole('button', { name: 'Not downloaded' }),
    );
  },
  render: () => (
    <Walkthrough
      title="Model slots and memory limits for kept models"
      intro={
        <p>
          Models kept in memory stay loaded together, so <code>pinnedMemory()</code> checks a new
          pin against {code('memory.max_model_slots')} (how many models can be loaded at once) and
          against {code('memory.pin_budget_gb')} (or {code('total_gb')}), using {code('memory_gb')}{' '}
          or the download size when unmeasured. A blocked <b>Keep in memory</b> is disabled with a
          tooltip; hover it to read it.
        </p>
      }
      steps={[
        {
          label: 'All slots kept',
          note: (
            <p>
              {code('max_model_slots: 2')} with Gemma and Qwen 3.5 kept: GPT-OSS's <b>Keep in
              memory</b> is disabled although the three need 45 GB of 64 GB. Its tooltip names the
              real limit: “All 2 model slots are in use. Stop keeping another model in memory
              first.” Before #1489 it said “Pinning this needs more memory than this Mac has.”,
              blaming memory for the slot count (fixed by #1489).
            </p>
          ),
          prs: [1489],
          node: <Models backend={backend(slots)} embedded />,
        },
        {
          label: 'Memory budget for kept models',
          note: (
            <p>
              {code('pin_budget_gb: 30')} with Gemma (21.4 GB) kept: GPT-OSS (16.4 GB) would make
              37.8 GB and is blocked, with the tooltip “Keeping this in memory needs more memory
              than this Mac has.” (reworded from “Pinning this…” by #1489); Qwen 3.5 (7.2 GB, 28.6
              GB total) can still be kept.
            </p>
          ),
          prs: [1489],
          node: <Models backend={backend(budget)} embedded />,
        },
        {
          label: 'Download & keep, over the budget',
          note: (
            <p>
              Under <b>Not downloaded</b> (the play step opens it), Qwen 3.6 35B A3B has no{' '}
              {code('memory_gb')}, so its 21.3 GB download size is counted: <b>Download &amp; keep
              in memory</b> is disabled, plain <b>Download</b> isn't.
            </p>
          ),
          node: <Models backend={backend(budget)} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const busyFlow = {
  downloading: on({}, {
    operations: [operation('download', 'running', { model: 'qwen-3.6-35b', progress: 0.7, cancellable: true })],
  }),
  refreshing: on({ phase: 'transitioning' }, {
    operations: [operation('autopilot_models', 'running')],
  }),
  waiting: on(
    { pinned: ['gemma-4-26b', 'qwen-3.5-9b'], phase: 'transitioning' },
  ),
};

export const WhileBusy: Story = {
  name: 'While models load or download',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return on();
        throw new Error('Unavailable in Storybook');
      },
      act: (action: Action) => later(8000, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Downloading into the pool').getByRole('button', { name: 'Show 1 more model' }),
    );
    await userEvent.click(
      region(canvasElement, 'An action from this page').getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' }),
    );
  },
  render: () => (
    <Walkthrough
      title="Autopilot while models load or download"
      intro={
        <p>
          Any running runtime {code('operation')} makes the app busy, and so does a model action
          this page is waiting on: Pause, Switch to manual and every row control are disabled
          until it ends. The toast at the bottom of a step is the app's operation notification.
        </p>
      }
      log
      steps={[
        {
          label: 'Downloading into the pool',
          note: (
            <p>
              A running {code('download')} for Qwen 3.6 at {code('progress: 0.7')}: it appears in{' '}
              <b>Your models</b> with a 70% bar (fourth, so the play step expands the list), the
              card's buttons are disabled, and the notification reads “Downloading Qwen 3.6 35B A3B
              · 70%” (the model and the row's progress, #1492; “Downloading model” before) with{' '}
              <b>Cancel</b>.
            </p>
          ),
          prs: [1492],
          node: (
            <>
              <Models backend={backend(busyFlow.downloading)} embedded />
              <Toast state={busyFlow.downloading} />
            </>
          ),
        },
        {
          label: 'Refreshing the pool',
          note: (
            <p>
              A running {code('autopilot_models')} (the runtime drains and restarts to re-inventory
              the pool) with {code('phase: "transitioning"')}: “Changing models” and “Refreshing
              available models”.
            </p>
          ),
          node: (
            <>
              <Models backend={backend(busyFlow.refreshing)} embedded />
              <Toast state={busyFlow.refreshing} />
            </>
          ),
        },
        {
          label: 'Kept model waiting to load',
          note: (
            <p>
              Qwen 3.5 newly kept ({code('pinned')}) but not yet {code('loaded')}: “Kept · waiting
              to load”, the card still counts 2 in memory, and the footer 2 kept.
            </p>
          ),
          node: <Models backend={backend(busyFlow.waiting)} embedded />,
        },
        {
          label: 'An action from this page',
          prs: [1461, 1477],
          note: (
            <p>
              The play step clicks <b>Keep in memory</b> on Qwen 3.5 (the mocked runtime takes 8 s).
              The row reads “Keeping in memory…” at once (“Pinning…” before the #1477 follow-up), and Pause / Switch to manual are disabled until the{' '}
              {code('autopilot_pin')} finishes; a second click is ignored.
            </p>
          ),
          node: <Models backend={backend(on())} embedded />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

export const Unsupported: Story = {
  name: 'Unsupported runtimes and errors',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return on();
        throw new Error('Unavailable in Storybook');
      },
      act: async (action: Action) => {
        if (action.action === 'autopilot_pin')
          throw new Error(
            "Error invoking remote method 'darkbloom:act': Error: Unknown action autopilot_pin",
          );
        if (action.action === 'autopilot')
          return {
            ...succeeded(action.action),
            state: 'failed',
            message: 'Autopilot could not start: no downloaded model fits in memory.',
          };
        return succeeded(action.action);
      },
    }),
  play: async ({ canvasElement }) => {
    await userEvent.click(
      region(canvasElement, 'Runtime rejects the action').getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' }),
    );
    await userEvent.click(
      region(canvasElement, 'Turning on fails').getByRole('button', { name: 'Turn on Autopilot' }),
    );
  },
  render: () => (
    <Walkthrough
      title="Unsupported runtimes and Autopilot errors"
      intro={
        <p>
          Older runtimes can't run Autopilot at all, and a supported one can still fail or reject
          a change. Failures from this page appear as a dismissible notice; the runtime's text is
          shown as-is unless it's the generic “unknown action” rejection. Message texts are
          fixture examples.
        </p>
      }
      log
      steps={[
        {
          label: 'Runtime without Autopilot',
          note: (
            <p>
              No {code('autopilot')} block in the snapshot: <code>modelsMode()</code> returns
              “unsupported”, so the page is manual selection with “Autopilot needs a newer
              Darkbloom runtime”.
            </p>
          ),
          node: <Models backend={backend(poolSnapshot(null, { machine }))} embedded />,
        },
        {
          label: 'Runtime that doesn’t offer Autopilot',
          note: (
            <p>
              {code('capabilities')} reported without {code('"autopilot"')}: manual selection with
              no Autopilot note or offer at all.
            </p>
          ),
          node: <Models backend={backend(off({ capabilities: ['account-signin', 'waitlist'] }))} embedded />,
        },
        {
          label: 'Runtime rejects the action',
          note: (
            <p>
              The play step clicks <b>Keep in memory</b>; the bridge rejects with “Unknown action
              autopilot_pin” (the IPC prefix is stripped). The notice explains in plain words:
              update the runtime, or turn Autopilot off.
            </p>
          ),
          node: <Models backend={backend(on())} embedded />,
        },
        {
          label: 'Turning on fails',
          note: (
            <p>
              The play step clicks <b>Turn on Autopilot</b>; the {code('autopilot')} operation ends{' '}
              {code('failed')} and its {code('message')} appears as a notice above the offer, which
              is clickable again.
            </p>
          ),
          node: <Models backend={backend(off())} embedded />,
        },
      ]}
    />
  ),
};
