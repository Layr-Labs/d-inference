// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Snapshot } from '../src/shared/contracts';
import type { SandboxLogs, SandboxStatus } from '../src/shared/sandbox';

// The development preview of Darkbloom Sandbox: `&sandbox=` states, the capability, and the
// simulated setup, pause, resume and uninstall.
async function preview(search: string) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  const api = (await import('../src/renderer/preview')).previewAPI;
  const { previewSandboxStates } = await import('../src/renderer/preview/sandbox');
  return {
    api,
    states: previewSandboxStates,
    sandbox: () => api.read<SandboxStatus>('sandbox'),
    logs: () => api.read<SandboxLogs>('sandbox-logs'),
    operation: async () => (await api.read<Snapshot>('state')).operations[0],
  };
}

afterEach(() => {
  vi.useRealTimers();
});

describe('preview states', () => {
  it('serves each `&sandbox=` state, and ready by default', async () => {
    const { states } = await preview('?preview');
    for (const state of states.filter((item) => item !== 'unsupported')) {
      const { sandbox } = await preview(`?preview&sandbox=${state}`);
      const status = await sandbox();
      expect(status.schema).toBe(1);
      expect(status.state).toBe(state === 'disks' ? 'ready' : state);
    }
    expect((await (await preview('?preview')).sandbox()).state).toBe('ready');
    const disks = await (await preview('?preview&sandbox=disks')).sandbox();
    expect(disks.disks?.map((disk) => `${disk.path} ${disk.state}`)).toEqual([
      '/Volumes/FastSSD online',
      '/System/Volumes/Data online',
      '/Volumes/Archive offline',
    ]);
    const missing = await (await preview('?preview&sandbox=not_installed')).sandbox();
    expect(missing).toMatchObject({ installed: false, state: 'not_installed' });
  });

  it('adds the `sandbox` capability and keeps what the preview offered before', async () => {
    const { api } = await preview('?preview');
    const state = await api.read<Snapshot>('state');
    expect(state.capabilities).toEqual(
      expect.arrayContaining(['sandbox', 'autopilot', 'waitlist']),
    );
    const older = await (await preview('?preview&sandbox=unsupported')).api.read<Snapshot>('state');
    expect(older.capabilities ?? []).not.toContain('sandbox');
  });

  it('serves the add-on’s log, and says when there is none', async () => {
    const lines = (await (await preview('?preview')).logs()).lines;
    expect(lines.length).toBeGreaterThan(3);
    expect(lines.at(-1)).toMatch(/update: checked/);
    const none = await (await preview('?preview&sandbox=not_installed')).logs();
    expect(none).toMatchObject({
      lines: [],
      error: 'Darkbloom Sandbox is not set up on this Mac.',
    });
  });
});

describe('the simulated setup', () => {
  it('walks the stages with an approval code and reaches ready', async () => {
    vi.useFakeTimers();
    const { api, sandbox, operation } = await preview('?preview&sandbox=not_installed');
    const started = await api.act({ action: 'sandbox_setup' });
    expect(started).toMatchObject({ action: 'sandbox_setup', state: 'running', cancellable: true });
    expect(started.sandbox_setup?.stage).toBe('checking_mac');
    await vi.advanceTimersByTimeAsync(3300);
    const waiting = await operation();
    expect(waiting.sandbox_setup).toMatchObject({
      stage: 'waiting_for_approval',
      step: 4,
      approval: {
        user_code: 'WDJB-MJHT',
        verification_uri_complete: 'https://api-sandbox.darkbloom.invalid/device?code=WDJB-MJHT',
      },
      background: true,
    });
    expect(waiting.lines).toContain('  ✓ Installing');
    expect((await sandbox()).state).toBe('waiting_for_approval');
    await vi.advanceTimersByTimeAsync(9000);
    expect((await operation()).sandbox_setup?.stage).toBe('enrolled');
    expect((await operation()).sandbox_setup?.approval).toBeNull();
    await vi.advanceTimersByTimeAsync(5000);
    const done = await operation();
    expect(done.state).toBe('succeeded');
    expect(done.lines).toContain('Darkbloom Sandbox is set up on this Mac.');
    // The images download in the background after setup ends.
    expect((await sandbox()).state).toBe('downloading_images');
    await vi.advanceTimersByTimeAsync(10_000);
    expect((await sandbox()).state).toBe('ready');
  });

  it('waits for the images with `wait_ready`', async () => {
    vi.useFakeTimers();
    const { api, sandbox, operation } = await preview('?preview&sandbox=not_installed');
    await api.act({ action: 'sandbox_setup', linux_slots: 1, macos_slots: 0, wait_ready: true });
    await vi.advanceTimersByTimeAsync(3300 + 9000 + 2200 + 900);
    expect((await operation()).sandbox_setup).toMatchObject({
      stage: 'downloading_images',
      progress: 0.2,
    });
    await vi.advanceTimersByTimeAsync(10_000);
    expect((await operation()).state).toBe('succeeded');
    expect(await sandbox()).toMatchObject({
      state: 'ready',
      slots: { linux: { total: 1, free: 1 }, macos: { total: 0, free: 0 } },
    });
  });

  it('stops on Cancel, leaving the enrollment waiting', async () => {
    vi.useFakeTimers();
    const { api, sandbox, operation } = await preview('?preview&sandbox=not_installed');
    const started = await api.act({ action: 'sandbox_setup' });
    await vi.advanceTimersByTimeAsync(4000);
    await expect(api.act({ action: 'sandbox_pause' })).rejects.toThrow(
      'An operation is already running.',
    );
    const cancelled = await api.act({ action: 'cancel', operation: started.id });
    expect(cancelled).toMatchObject({ state: 'cancelled', sandbox_setup: { exit_status: 130 } });
    await vi.advanceTimersByTimeAsync(30_000);
    expect((await operation()).state).toBe('cancelled');
    expect((await sandbox()).state).toBe('waiting_for_approval');
  });

  it.each([
    ['cannot_host', 'not_installed', 2, 'checking_mac'],
    ['not_enrolled', 'not_installed', 3, 'waiting_for_approval'],
    ['job_running', 'ready', 4, 'installing'],
  ])('ends with `&sandbox-setup=%s` as the installer would', async (setup, from, exit, stage) => {
    vi.useFakeTimers();
    const { api, operation } = await preview(`?preview&sandbox=${from}&sandbox-setup=${setup}`);
    await api.act({ action: 'sandbox_setup', linux_slots: 2, macos_slots: 1 });
    await vi.advanceTimersByTimeAsync(20_000);
    const ended = await operation();
    expect(ended).toMatchObject({ state: 'failed', sandbox_setup: { exit_status: exit, stage } });
    const { exitStatus } = await import('../src/renderer/features/sandboxes/setup');
    // Without the reported status, the CLI's last line says the same.
    expect(
      exitStatus({ ...ended, sandbox_setup: { ...ended.sandbox_setup, exit_status: null } }),
    ).toBe(exit);
  });

  it('waits on the waitlist in the background with `&sandbox-setup=waitlisted`', async () => {
    vi.useFakeTimers();
    const { api, sandbox, operation } = await preview(
      '?preview&sandbox=not_installed&sandbox-setup=waitlisted',
    );
    await api.act({ action: 'sandbox_setup' });
    await vi.advanceTimersByTimeAsync(3300 + 4000);
    expect((await operation()).sandbox_setup).toMatchObject({ waitlisted: true, background: true });
    expect((await sandbox()).state).toBe('waitlisted');
    await vi.advanceTimersByTimeAsync(60_000);
    expect((await operation()).state).toBe('running');
  });
});

describe('pause, resume and uninstall', () => {
  it('change the fixture', async () => {
    vi.useFakeTimers();
    const { api, sandbox, logs } = await preview('?preview&sandbox=running');
    const pause = api.act({ action: 'sandbox_pause' });
    await vi.advanceTimersByTimeAsync(700);
    expect(await pause).toMatchObject({ action: 'sandbox_pause', state: 'succeeded' });
    expect(await sandbox()).toMatchObject({ state: 'paused', accepting: false, jobs_running: 1 });
    expect((await logs()).lines.at(-1)).toMatch(/owner: pause$/);
    const resume = api.act({ action: 'sandbox_resume' });
    await vi.advanceTimersByTimeAsync(700);
    await resume;
    expect(await sandbox()).toMatchObject({
      state: 'running',
      accepting: true,
      slots: { linux: { total: 2, free: 1 } },
    });
    const uninstall = api.act({ action: 'sandbox_uninstall' });
    await vi.advanceTimersByTimeAsync(700);
    await uninstall;
    expect(await sandbox()).toMatchObject({ installed: false, state: 'not_installed' });
    const again = api.act({ action: 'sandbox_pause' });
    const refused = expect(again).rejects.toThrow('Darkbloom Sandbox is not set up on this Mac.');
    await vi.advanceTimersByTimeAsync(700);
    await refused;
  });

  it('move the resource revision so a shown page reads again', async () => {
    vi.useFakeTimers();
    const { api } = await preview('?preview&sandbox=ready');
    const before = (await api.read<Snapshot>('state')).resource_revision;
    const pause = api.act({ action: 'sandbox_pause' });
    await vi.advanceTimersByTimeAsync(700);
    await pause;
    expect((await api.read<Snapshot>('state')).resource_revision).not.toBe(before);
  });
});
