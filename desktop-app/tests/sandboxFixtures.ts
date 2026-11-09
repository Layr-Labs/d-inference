import { vi } from 'vitest';
import type { DesktopAPI, Operation, Resource, Snapshot } from '../src/shared/contracts';
import type { SandboxSetupProgress, SandboxStatus } from '../src/shared/sandbox';
import type { Waitlists } from '../src/shared/waitlists';
import { snapshot } from './onboardingFixtures';

// The add-on's `status --json` documents as add-on 1.0.1 writes them (the CLI's own fixtures,
// provider-swift/Tests/DarkbloomCLITests/SandboxTestSupport.swift), plus work disks.
const host = '0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60';
const console = `https://api-sandbox.darkbloom.dev/macs/${host}`;
const installed = [
  { platform: 'linux', progress: null, state: 'installed' },
  { platform: 'macos', progress: null, state: 'installed' },
];

export const statuses = {
  ready: {
    accepting: true,
    console_url: console,
    detail: 'Ready for jobs (free slots: Linux 1 of 1, macOS 1 of 1)',
    host_id: host,
    images: installed,
    installed: true,
    jobs_running: 0,
    last_update_check: 1_793_000_000,
    schema: 1,
    slots: { linux: { free: 1, total: 1 }, macos: { free: 1, total: 1 } },
    state: 'ready',
    version: '1.0.1',
  },
  running: {
    accepting: true,
    console_url: console,
    detail: 'Running 1 job',
    host_id: host,
    images: installed,
    installed: true,
    jobs_running: 1,
    last_update_check: 1_793_000_000,
    schema: 1,
    slots: { linux: { free: 0, total: 1 }, macos: { free: 1, total: 1 } },
    state: 'running',
    version: '1.0.1',
  },
  paused: {
    accepting: false,
    console_url: console,
    detail: 'Paused by you: no new jobs, 1 job finishing; resume with darkbloom-sandbox resume',
    host_id: host,
    images: installed,
    installed: true,
    jobs_running: 1,
    last_update_check: null,
    schema: 1,
    slots: { linux: { free: 0, total: 1 }, macos: { free: 0, total: 1 } },
    state: 'paused',
    version: '1.0.1',
  },
  downloading: {
    accepting: false,
    console_url: console,
    detail: 'Downloading its linux image: 42%',
    host_id: host,
    images: [
      { platform: 'linux', progress: 0.42, state: 'downloading' },
      { platform: 'macos', progress: null, state: 'missing' },
    ],
    installed: true,
    jobs_running: 0,
    last_update_check: 1_793_000_000,
    schema: 1,
    slots: { linux: { free: 1, total: 1 }, macos: { free: 1, total: 1 } },
    state: 'downloading_images',
    version: '1.0.1',
  },
  waiting: {
    accepting: false,
    console_url: 'https://api-sandbox.darkbloom.dev/macs',
    detail:
      'Approve this Mac at https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT (code WDJB-MJHT)',
    host_id: null,
    images: [],
    installed: true,
    jobs_running: 0,
    last_update_check: null,
    schema: 1,
    slots: { linux: { free: 0, total: 1 }, macos: { free: 0, total: 1 } },
    state: 'waiting_for_approval',
    version: '1.0.1',
  },
  error: {
    accepting: false,
    console_url: console,
    detail: 'Not connected to the plane (cannot reach the plane); it keeps trying',
    host_id: host,
    images: [],
    installed: true,
    jobs_running: 0,
    last_update_check: 1_793_000_000,
    schema: 1,
    slots: { linux: { free: 0, total: 1 }, macos: { free: 0, total: 1 } },
    state: 'error',
    version: '1.0.1',
  },
  notInstalled: {
    accepting: false,
    console_url: 'https://api-sandbox.darkbloom.dev/macs',
    detail: 'Darkbloom Sandbox is not installed in /Users/ada/DarkbloomSandbox',
    host_id: null,
    images: [],
    installed: false,
    jobs_running: 0,
    last_update_check: null,
    schema: 1,
    slots: { linux: { free: 0, total: 0 }, macos: { free: 0, total: 0 } },
    state: 'not_installed',
    version: '1.0.1',
  },
  future: { schema: 2, state: 'hibernating', detail: 'Sleeping until 22:00', jobs_running: 0 },
  minimal: { schema: 1, state: 'ready' },
} satisfies Record<string, SandboxStatus>;

export const disks: SandboxStatus['disks'] = [
  {
    path: '/Volumes/FastSSD',
    root_volume: false,
    state: 'online',
    detail: null,
    free_bytes: 812 * 2 ** 30 + 5,
    slots: { linux: { total: 2 }, macos: { total: 1 } },
  },
  {
    path: '/System/Volumes/Data',
    root_volume: true,
    state: 'online',
    free_bytes: 157 * 2 ** 30,
    slots: { linux: { total: 1 } },
  },
  {
    path: '/Volumes/Archive',
    root_volume: false,
    state: 'offline',
    detail: 'Not connected: connect it again',
    free_bytes: null,
    slots: { linux: { total: 1 } },
  },
];

export const approval = {
  user_code: 'WDJB-MJHT',
  verification_uri: 'https://api-sandbox.darkbloom.dev/device',
  verification_uri_complete: 'https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT',
};

export function setupOperation(
  progress: SandboxSetupProgress,
  overrides: Partial<Operation> = {},
): Operation {
  return {
    id: 'setup-1',
    action: 'sandbox_setup',
    state: 'running',
    started_at: 1_790_000_000,
    message: '',
    cancellable: true,
    lines: [],
    sandbox_setup: progress,
    ...overrides,
  };
}

export const sandboxSnapshot = (overrides: Partial<Snapshot> = {}) =>
  snapshot({
    capabilities: ['account-signin', 'autopilot', 'sandbox', 'waitlists'],
    resource_revision: 'r1',
    ...overrides,
  });

export const waitlists = (status: 'none' | 'waitlisted' | 'approved' | 'revoked'): Waitlists => ({
  data: [
    {
      feature: 'sandbox',
      title: 'Darkbloom Sandbox',
      summary: 'Run Darkbloom Sandbox CI jobs on your Mac.',
      start_command: 'darkbloom sandbox setup',
      status,
      position: status === 'waitlisted' ? 3 : null,
    },
  ],
});

// A preload bridge whose resources the test sets; reads of anything else fail.
export function fakeBridge() {
  const resources: Partial<Record<Resource, unknown>> = {};
  const read = vi.fn(async (resource: Resource): Promise<unknown> => {
    if (!(resource in resources)) throw new Error(`No fixture for ${resource}`);
    const value = resources[resource];
    if (value instanceof Error) throw value;
    return structuredClone(value);
  });
  const bridge: DesktopAPI = {
    read: <T>(resource: Resource) => read(resource) as Promise<T>,
    act: vi.fn(),
    status: async () => ({ state: 'ready' }),
    install: async () => {},
    cancelInstall: async () => {},
    openExternal: vi.fn(async () => {}),
    copy: vi.fn(async () => {}),
    system: async () => ({ macosVersion: '27.0' }),
    openSoftwareUpdate: vi.fn(async () => {}),
    updateStatus: async () => ({ state: 'idle' }),
    checkUpdate: async () => ({ state: 'idle' }),
    applyUpdate: async () => {},
    onState: () => () => {},
    onStatus: () => () => {},
    onNavigate: () => () => {},
    onHardware: () => () => {},
    chatModels: async () => ({ models: [] }),
    chatSend: async () => ({ stream: 'test' }),
    chatCancel: async () => {},
    onChat: () => () => {},
    clusterSession: async () => null,
    startClusterSession: async () => {
      throw new Error('No cluster session in this test');
    },
    answerClusterSession: async () => {
      throw new Error('No cluster session in this test');
    },
    onClusterSession: () => () => {},
    openApproval: vi.fn(async () => {}),
  };
  return { bridge, read, resources };
}
