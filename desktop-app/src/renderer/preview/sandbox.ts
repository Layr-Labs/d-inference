import type { Action, Operation } from '../../shared/contracts';
import type {
  SandboxAction,
  SandboxDisk,
  SandboxLogs,
  SandboxSetupProgress,
  SandboxStatus,
} from '../../shared/sandbox';
import { setupStages } from '../features/sandboxes/setup';
import { isInstalled, jobs } from '../features/sandboxes/status';
import {
  previewOperation,
  previewParam,
  recordOperation,
  type FeaturePreview,
  type PreviewStore,
} from './types';

// Development preview of Darkbloom Sandbox. Never used for live data: the add-on's status is
// shaped like the CLI's own fixtures (provider-swift/Tests/DarkbloomCLITests/SandboxTestSupport.swift).
//
// `&sandbox=` sets the add-on's state: `not_installed`, `waiting_for_approval`, `waitlisted`,
// `enrolling`, `downloading_images`, `ready` (the default), `running`, `paused`, `stopped`,
// `error`, `disks` (ready, with an external work disk and one offline) or `unsupported` (a runtime
// without the `sandbox` capability). Setup walks the installer's stages with an approval code and
// reaches `ready`; `&sandbox-setup=` ends it otherwise: `waitlisted` (waits on the waitlist in the
// background), `cannot_host` (exit 2), `not_enrolled` (exit 3) or `job_running` (exit 4).

export const previewSandboxStates = [
  'not_installed',
  'waiting_for_approval',
  'waitlisted',
  'enrolling',
  'downloading_images',
  'ready',
  'running',
  'paused',
  'stopped',
  'error',
  'disks',
  'unsupported',
] as const;

const gib = 2 ** 30;
const host = '0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60';
const server = 'https://api-sandbox.darkbloom.dev';
const approval = {
  user_code: 'WDJB-MJHT',
  verification_uri: `${server}/device`,
  verification_uri_complete: `${server}/device?code=WDJB-MJHT`,
};
const now = () => Date.now() / 1000;
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const internalDisk = (linux: number, macos: number): SandboxDisk => ({
  path: '/System/Volumes/Data',
  root_volume: true,
  state: 'online',
  detail: null,
  free_bytes: 157 * gib,
  slots: { linux: { total: linux }, macos: { total: macos } },
});

const notInstalled = (): SandboxStatus => ({
  schema: 1,
  installed: false,
  version: null,
  host_id: null,
  state: 'not_installed',
  detail: 'Darkbloom Sandbox is not installed in /Users/ada/DarkbloomSandbox',
  slots: { linux: { total: 0, free: 0 }, macos: { total: 0, free: 0 } },
  jobs_running: 0,
  images: [],
  accepting: false,
  last_update_check: null,
  console_url: `${server}/macs`,
});

function ready(linux = 2, macos = 1): SandboxStatus {
  return {
    schema: 1,
    installed: true,
    version: '1.2.0',
    host_id: host,
    state: 'ready',
    detail: `Ready for jobs (free slots: Linux ${linux} of ${linux}, macOS ${macos} of ${macos})`,
    slots: { linux: { total: linux, free: linux }, macos: { total: macos, free: macos } },
    jobs_running: 0,
    images: [
      { platform: 'linux', state: 'installed', progress: null },
      { platform: 'macos', state: 'installed', progress: null },
    ],
    accepting: true,
    last_update_check: now() - 3 * 3600 - 840,
    console_url: `${server}/macs/${host}`,
    disks: [internalDisk(linux, macos)],
  };
}

const noFreeSlots = (status: SandboxStatus) => ({
  linux: { total: status.slots?.linux?.total ?? 0, free: 0 },
  macos: { total: status.slots?.macos?.total ?? 0, free: 0 },
});

// Installed, not yet enrolled: no host, no images, nothing free.
function enrolling(state: string, detail: string): SandboxStatus {
  const base = ready();
  return {
    ...base,
    state,
    detail,
    host_id: null,
    images: [],
    accepting: false,
    last_update_check: null,
    console_url: `${server}/macs`,
    slots: noFreeSlots(base),
  };
}

function downloading(progress: number, base = ready()): SandboxStatus {
  return {
    ...base,
    state: 'downloading_images',
    accepting: false,
    detail: `Downloading its linux image: ${Math.floor(progress * 100)}%`,
    images: [
      { platform: 'linux', state: 'downloading', progress },
      { platform: 'macos', state: 'missing', progress: null },
    ],
  };
}

function fixture(state: string | null): SandboxStatus {
  const base = ready();
  switch (state) {
    case 'not_installed':
      return notInstalled();
    case 'waiting_for_approval':
      return enrolling(
        state,
        `Approve this Mac at ${approval.verification_uri_complete} (code ${approval.user_code})`,
      );
    case 'waitlisted':
      return enrolling(
        state,
        'Your account is on the waitlist; this Mac enrolls by itself once Darkbloom approves it',
      );
    case 'enrolling':
      return enrolling(state, 'Enrolling this Mac');
    case 'downloading_images':
      return downloading(0.42);
    case 'running':
      return {
        ...base,
        state,
        jobs_running: 1,
        detail: 'Running 1 job',
        slots: { linux: { total: 2, free: 1 }, macos: { total: 1, free: 1 } },
      };
    case 'paused':
      return {
        ...base,
        state,
        accepting: false,
        jobs_running: 1,
        detail: 'Paused by you: no new jobs, 1 job finishing; resume with darkbloom-sandbox resume',
        slots: noFreeSlots(base),
      };
    case 'stopped':
      return {
        ...base,
        state,
        accepting: false,
        detail: 'The agent is not running',
        slots: noFreeSlots(base),
      };
    case 'error':
      return {
        ...base,
        state,
        accepting: false,
        images: [],
        detail: 'Not connected to the plane (cannot reach the plane); it keeps trying',
        slots: noFreeSlots(base),
      };
    case 'disks':
      return {
        ...base,
        detail: 'Ready for jobs (free slots: Linux 3 of 4, macOS 1 of 1)',
        slots: { linux: { total: 4, free: 3 }, macos: { total: 1, free: 1 } },
        disks: [
          {
            path: '/Volumes/FastSSD',
            root_volume: false,
            state: 'online',
            detail: null,
            free_bytes: 812 * gib,
            slots: { linux: { total: 2 }, macos: { total: 1 } },
          },
          internalDisk(1, 0),
          {
            path: '/Volumes/Archive',
            root_volume: false,
            state: 'offline',
            detail:
              'Not connected: connect it again; its slots take jobs once its images are checked',
            free_bytes: null,
            slots: { linux: { total: 1 } },
          },
        ],
      };
    default:
      return base;
  }
}

// The fixture follows the query, so a test that changes it gets the new state.
let selected: string | null | undefined;
let status: SandboxStatus = notInstalled();
function current() {
  const query = previewParam('sandbox');
  if (query !== selected) {
    selected = query;
    status = fixture(query);
  }
  return status;
}

const clock = (offset: number) =>
  new Date((now() - offset) * 1000).toLocaleTimeString('en-GB', { hour12: false });
const log: string[] = [];
function logLines(): string[] {
  return [
    `${clock(5400)} agent: Darkbloom Sandbox 1.2.0 starting (host ${host})`,
    `${clock(5399)} agent: connected to ${server}`,
    `${clock(5398)} slots: linux 2, macos 1 on /System/Volumes/Data`,
    `${clock(5397)} images: linux installed, macos installed`,
    `${clock(3120)} job 8812: accepted (linux, ubuntu-24.04)`,
    `${clock(3119)} hold: inference paused for the job`,
    `${clock(2313)} job 8812: finished (succeeded, 13m 26s)`,
    `${clock(2312)} hold: released; inference resumes`,
    `${clock(840)} update: checked; 1.2.0 is current`,
    ...log,
  ];
}

function logs(): SandboxLogs {
  if (!isInstalled(current()))
    return { lines: [], observed_at: now(), error: 'Darkbloom Sandbox is not set up on this Mac.' };
  return { lines: logLines(), observed_at: now() };
}

// A changed fixture moves the snapshot's resource revision, as the native 30-second clock does,
// so a shown page reads it again.
let revision = 0;
function setStatus(store: PreviewStore, next: SandboxStatus) {
  status = next;
  store.set({ ...store.get(), resource_revision: `preview-sandbox-${++revision}` });
}

// The simulated `sandbox_setup` run: its operation and pending steps.
let setup: { operation: Operation; timers: ReturnType<typeof setTimeout>[] } | undefined;
let downloadTimer: ReturnType<typeof setInterval> | undefined;

function stopDownload() {
  if (downloadTimer) clearInterval(downloadTimer);
  downloadTimer = undefined;
}

function simulateSetup(
  store: PreviewStore,
  action: Extract<SandboxAction, { action: 'sandbox_setup' }>,
) {
  stopDownload();
  const outcome = previewParam('sandbox-setup');
  const before = current();
  const firstSetup =
    !isInstalled(before) ||
    ['waiting_for_approval', 'waitlisted', 'enrolling'].includes(before.state);
  const linux = action.linux_slots ?? before.slots?.linux?.total ?? 2;
  const macos = action.macos_slots ?? before.slots?.macos?.total ?? 1;
  const lines: string[] = [];
  let operation: Operation = {
    id: crypto.randomUUID(),
    action: 'sandbox_setup',
    state: 'running',
    started_at: now(),
    message: 'Checking this Mac',
    cancellable: true,
    lines: [],
    sandbox_setup: {},
  };
  const timers: ReturnType<typeof setTimeout>[] = [];
  setup = { operation, timers };
  const publish = (progress: SandboxSetupProgress, end?: Partial<Operation>) => {
    operation = {
      ...operation,
      ...end,
      message: end?.message ?? progress.message ?? operation.message,
      lines: [...lines],
      sandbox_setup: { ...operation.sandbox_setup, ...progress },
    };
    if (setup) setup.operation = operation;
    if (end) setup = undefined;
    recordOperation(store, operation);
  };
  const stage = (id: string, extra: SandboxSetupProgress = {}) => {
    const index = setupStages.findIndex((item) => item.id === id);
    publish({ stage: id, step: index + 1, steps: 8, message: setupStages[index].title, ...extra });
  };
  const done = (title: string, result: string) => lines.push(`  ✓ ${title}`, `    ${result}`);
  const fail = (id: string, message: string, exit: number, advice: string) => {
    const index = setupStages.findIndex((item) => item.id === id);
    lines.push(`  ✗ ${setupStages[index].title}`, `    ${message}`, '', advice);
    publish(
      { stage: id, step: index + 1, message, exit_status: exit },
      { state: 'failed', finished_at: now(), cancellable: false, message: advice },
    );
  };
  const finish = () => {
    lines.push(
      '',
      'Darkbloom Sandbox is set up on this Mac.',
      `  Jobs at a time: ${linux} Linux, ${macos} macOS`,
    );
    publish(
      {},
      { state: 'succeeded', finished_at: now(), cancellable: false, message: lines.at(-2) },
    );
  };
  let at = 0;
  const then = (ms: number, step: () => void) => {
    at += ms;
    timers.push(setTimeout(step, at));
  };

  lines.push(
    '  [PASS] Chip: Apple M4 Max',
    '  [PASS] macOS: 27.0.1',
    '  [PASS] Session: logged in at this Mac’s desktop',
    '  [WARN] Network: Wi-Fi (jobs and VM images download a lot)',
    '         ↳ fix: use Ethernet if you can; it is faster and steadier',
    '  [PASS] Power: power adapter',
    '  [PASS] Sleep: off on the power adapter',
  );
  stage('checking_mac');
  if (outcome === 'cannot_host') {
    then(1100, () =>
      fail(
        'checking_mac',
        'No job fits: each job needs 4 cores besides the 4 kept for you; this Mac has 2 left',
        2,
        'This Mac cannot host Darkbloom Sandbox as it is; see why above.',
      ),
    );
    return operation;
  }
  then(1100, () => {
    done(
      'Checking this Mac',
      'Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1; logged in as ada',
    );
    stage('verifying_release');
  });
  then(1100, () => {
    done(
      'Verifying release',
      'Darkbloom Sandbox 1.2.0, signed by Darkbloom (Developer ID team SLDQ2GJ6TL); the release’s signature checks out',
    );
    stage('installing');
  });
  if (!firstSetup && (outcome === 'job_running' || (before.jobs_running ?? 0) > 0)) {
    then(1100, () =>
      fail(
        'installing',
        'A job is running on this Mac; the installer changed nothing',
        4,
        'A job is running on this Mac, so the installer changed nothing. Run `darkbloom sandbox setup` again when it finishes; `darkbloom sandbox pause` keeps new jobs from starting.',
      ),
    );
    return operation;
  }
  then(1100, () => {
    done('Installing', `~/DarkbloomSandbox: ${linux} Linux, ${macos} macOS`);
    if (!firstSetup) {
      done('Waiting for approval', 'Already approved');
      stage('enrolled');
      return;
    }
    setStatus(
      store,
      enrolling(
        'waiting_for_approval',
        `Approve this Mac at ${approval.verification_uri_complete} (code ${approval.user_code})`,
      ),
    );
    lines.push(
      '',
      '    Approve this Mac in your browser, signed in to the Darkbloom account that should own it:',
      `      ${approval.verification_uri_complete}`,
      `    Code: ${approval.user_code}. Check the Mac shown, then press Approve; the CLI cannot approve for you.`,
      '    Open the link in a browser on any device.',
      '    Earnings for jobs on this Mac go to the account that approves it.',
      '',
    );
    stage('waiting_for_approval', { approval, background: true });
  });
  if (firstSetup) {
    if (outcome === 'waitlisted') {
      then(4000, () => {
        lines.push(
          '    Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.',
        );
        setStatus(store, enrolling('waitlisted', 'Waiting for Darkbloom to approve your account'));
        publish({
          waitlisted: true,
          background: true,
          message: 'Waiting for Darkbloom to approve your account',
        });
      });
      return operation;
    }
    if (outcome === 'not_enrolled') {
      then(6000, () =>
        fail(
          'waiting_for_approval',
          'The code expired before this Mac was approved',
          3,
          'This Mac was not enrolled: the code was denied or expired, or the waitlist request ended. Run `darkbloom sandbox setup` to start again.',
        ),
      );
      return operation;
    }
    then(9000, () => {
      done('Waiting for approval', 'Approved after 0:09');
      setStatus(store, enrolling('enrolling', 'Enrolling this Mac'));
      stage('enrolled', { approval: null });
    });
  }
  then(1100, () => {
    done('Enrolled', `Host ${host}; App Attest verified this app`);
    stage('starting');
  });
  const waitReady = !!action.wait_ready && firstSetup;
  then(1100, () => {
    done('Starting', `Connected to ${server}`);
    stage('downloading_images', waitReady ? { progress: 0 } : {});
    if (firstSetup) setStatus(store, downloading(0, ready(linux, macos)));
  });
  if (waitReady)
    for (let tenth = 1; tenth <= 10; tenth++)
      then(450, () => {
        publish({ progress: tenth / 10 });
        setStatus(store, downloading(tenth / 10, ready(linux, macos)));
      });
  then(700, () => {
    done(
      'Downloading images',
      waitReady || !firstSetup
        ? 'Linux and macOS images installed'
        : 'In the background (about 13 GB for Linux and 42 GB for macOS)',
    );
    stage('ready', { progress: null });
  });
  then(700, () => {
    const background = firstSetup && !waitReady;
    done(
      'Ready',
      background
        ? 'Not yet: this Mac takes jobs once its first image is installed'
        : 'Ready for jobs',
    );
    setStatus(store, background ? downloading(0.08, ready(linux, macos)) : ready(linux, macos));
    finish();
    if (background) {
      // The images download on their own after setup ends.
      let fraction = 0.08;
      downloadTimer = setInterval(() => {
        fraction = Math.min(1, fraction + 0.16);
        if (fraction < 1) setStatus(store, downloading(fraction, ready(linux, macos)));
        else {
          stopDownload();
          setStatus(store, ready(linux, macos));
        }
      }, 1500);
    }
  });
  return operation;
}

function cancelSetup(store: PreviewStore) {
  if (!setup) return undefined;
  setup.timers.forEach(clearTimeout);
  const operation: Operation = {
    ...setup.operation,
    state: 'cancelled',
    finished_at: now(),
    cancellable: false,
    message: 'Cancelled',
    sandbox_setup: { ...setup.operation.sandbox_setup, exit_status: 130 },
  };
  setup = undefined;
  return recordOperation(store, operation);
}

async function simple(
  store: PreviewStore,
  action: Action,
  change: (status: SandboxStatus) => SandboxStatus,
  message: string,
) {
  await wait(700);
  const before = current();
  if (!isInstalled(before)) throw new Error('Darkbloom Sandbox is not set up on this Mac.');
  setStatus(store, change(before));
  log.push(`${clock(0)} owner: ${action.action.replace('sandbox_', '')}`);
  return recordOperation(store, previewOperation(action, 'succeeded', message));
}

export const sandboxPreview: FeaturePreview = {
  resources: () => ({ sandbox: structuredClone(current()), 'sandbox-logs': logs() }),
  async act(store, action) {
    if (action.action === 'cancel' && setup?.operation.id === action.operation)
      return cancelSetup(store);
    if (!action.action.startsWith('sandbox_')) return undefined;
    if (setup) throw new Error('An operation is already running. Wait for it to finish.');
    switch (action.action) {
      case 'sandbox_setup':
        return simulateSetup(store, action);
      case 'sandbox_pause':
        return simple(
          store,
          action,
          (before) => {
            const running = before.jobs_running ?? 0;
            return {
              ...before,
              state: 'paused',
              accepting: false,
              slots: noFreeSlots(before),
              detail: running
                ? `Paused by you: no new jobs, ${jobs(running)} finishing; resume with darkbloom-sandbox resume`
                : 'Paused by you: no new jobs; resume with darkbloom-sandbox resume',
            };
          },
          'Paused: running jobs finish; no new jobs start.',
        );
      case 'sandbox_resume':
        return simple(
          store,
          action,
          (before) => {
            const running = before.jobs_running ?? 0;
            const linux = before.slots?.linux?.total ?? 0;
            const macos = before.slots?.macos?.total ?? 0;
            return {
              ...before,
              state: running ? 'running' : 'ready',
              accepting: true,
              detail: running ? `Running ${jobs(running)}` : 'Ready for jobs',
              slots: {
                linux: { total: linux, free: Math.max(0, linux - running) },
                macos: { total: macos, free: macos },
              },
            };
          },
          'Resumed: this Mac takes jobs again.',
        );
      case 'sandbox_uninstall':
        stopDownload();
        return simple(store, action, notInstalled, 'Darkbloom Sandbox was removed from this Mac.');
      default:
        return undefined;
    }
  },
  snapshot(snapshot) {
    if (previewParam('sandbox') === 'unsupported') return snapshot;
    // A snapshot without a list reads as a runtime from before capabilities, which offers
    // Autopilot and the eligibility waitlist: keep both when naming sandbox.
    const capabilities = snapshot.capabilities ?? ['autopilot', 'waitlist'];
    return capabilities.includes('sandbox')
      ? snapshot
      : { ...snapshot, capabilities: [...capabilities, 'sandbox'] };
  },
};
