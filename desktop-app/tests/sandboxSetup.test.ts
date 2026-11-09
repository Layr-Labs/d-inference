import { describe, expect, it } from 'vitest';
import {
  exitStatus,
  pendingApproval,
  setupOutcome,
  setupRequest,
  setupSteps,
  slotCounts,
  workDisk,
  type SetupChoice,
} from '../src/renderer/features/sandboxes/setup';
import { approval, setupOperation } from './sandboxFixtures';

const states = (operation: ReturnType<typeof setupOperation>) =>
  setupSteps(operation).map((step) => `${step.state} ${step.title}`);

describe('the installer’s stages', () => {
  it('marks the stages before the current one done and the rest not started', () => {
    expect(states(setupOperation({ stage: 'waiting_for_approval', step: 4, steps: 8 }))).toEqual([
      'done Checking this Mac',
      'done Verifying release',
      'done Installing',
      'active Waiting for approval',
      'pending Enrolled',
      'pending Starting',
      'pending Downloading images',
      'pending Ready',
    ]);
  });

  it('starts at the CLI’s own check before the installer reports anything', () => {
    expect(states(setupOperation({}))[0]).toBe('active Checking this Mac');
    expect(setupSteps(setupOperation({}, { state: 'failed' }))).toEqual([]);
  });

  it('says what the stage waits for and how far the download is', () => {
    expect(states(setupOperation({ stage: 'waiting_for_approval', waitlisted: true }))[3]).toBe(
      'active Waiting for Darkbloom to approve your account',
    );
    const download = setupSteps(setupOperation({ stage: 'downloading_images', progress: 0.427 }));
    expect(download[6]).toMatchObject({
      state: 'active',
      title: 'Downloading images 42%',
      progress: 0.427,
    });
  });

  it('keeps an unknown stage’s words at its step', () => {
    const steps = setupSteps(
      setupOperation({ stage: 'warming_up', step: 6, message: 'Warming up' }),
    );
    expect(steps[5]).toMatchObject({ state: 'active', title: 'Warming up' });
    expect(steps[4].state).toBe('done');
  });

  it('marks where a failed setup stopped, with the installer’s reason', () => {
    const failed = setupOperation(
      { stage: 'checking_mac', step: 1, message: 'No job fits this Mac' },
      { state: 'failed' },
    );
    expect(setupSteps(failed)[0]).toEqual({
      id: 'checking_mac',
      title: 'Checking this Mac',
      state: 'failed',
      detail: 'No job fits this Mac',
    });
    expect(states(setupOperation({ stage: 'installing' }, { state: 'cancelled' }))[2]).toBe(
      'stopped Installing',
    );
    expect(
      states(setupOperation({ stage: 'starting' }, { state: 'succeeded' })).every((step) =>
        step.startsWith('done'),
      ),
    ).toBe(true);
  });
});

describe('the approval', () => {
  it('is the page with the code filled in while the setup waits for it', () => {
    expect(pendingApproval(setupOperation({ stage: 'waiting_for_approval', approval }))).toEqual({
      code: 'WDJB-MJHT',
      url: approval.verification_uri_complete,
      codeFilled: true,
    });
    expect(
      pendingApproval(
        setupOperation({
          stage: 'waiting_for_approval',
          approval: { ...approval, verification_uri_complete: null },
        }),
      ),
    ).toEqual({ code: 'WDJB-MJHT', url: approval.verification_uri, codeFilled: false });
  });

  it('goes once the Mac is enrolled, waitlisted or the setup ended', () => {
    expect(pendingApproval(setupOperation({ stage: 'enrolled', approval }))).toBeUndefined();
    expect(
      pendingApproval(
        setupOperation({ stage: 'waiting_for_approval', approval, waitlisted: true }),
      ),
    ).toBeUndefined();
    expect(
      pendingApproval(
        setupOperation({ stage: 'waiting_for_approval', approval }, { state: 'failed' }),
      ),
    ).toBeUndefined();
  });
});

describe('an ended setup', () => {
  const failed = (lines: string[], progress = {}) =>
    setupOperation(progress, { state: 'failed', lines, message: lines.join('\n') });

  it('reads the exit status the runtime reports, else the CLI’s last line', () => {
    expect(exitStatus(failed([], { exit_status: 4 }))).toBe(4);
    expect(
      exitStatus(failed(['This Mac cannot host Darkbloom Sandbox as it is; see why above.'])),
    ).toBe(2);
    expect(
      exitStatus(
        failed([
          'This Mac was not enrolled: the code was denied or expired, or the waitlist request ended. Run `darkbloom sandbox setup` to start again.',
        ]),
      ),
    ).toBe(3);
    expect(
      exitStatus(
        failed([
          'A job is running on this Mac, so the installer changed nothing. Run `darkbloom sandbox setup` again when it finishes.',
          '',
        ]),
      ),
    ).toBe(4);
    expect(exitStatus(failed(["You're on the Darkbloom Sandbox waitlist: #3 in line"]))).toBe(1);
    expect(exitStatus(setupOperation({}, { state: 'cancelled' }))).toBe(130);
    expect(exitStatus(setupOperation({}))).toBeUndefined();
  });

  it('says what each exit status means', () => {
    expect(
      setupOutcome(failed([], { stage: 'checking_mac', message: 'No job fits', exit_status: 2 })),
    ).toEqual({ title: 'This Mac can’t host Darkbloom Sandbox as it is.', detail: 'No job fits' });
    expect(setupOutcome(failed([], { exit_status: 3 }))?.title).toBe('This Mac was not enrolled.');
    expect(setupOutcome(failed([], { exit_status: 4 }))).toEqual({
      title: 'A job is running, so nothing changed.',
      detail:
        'The installer refuses rather than waits. Try again when the job finishes; Pause keeps new jobs from starting.',
    });
    expect(setupOutcome(setupOperation({}, { state: 'running' }))).toBeUndefined();
    expect(setupOutcome(setupOperation({}, { state: 'succeeded' }))).toBeUndefined();
  });

  it('says an enrollment goes on only when the setup reached the approval', () => {
    expect(setupOutcome(setupOperation({ stage: 'installing' }, { state: 'cancelled' }))).toEqual({
      title: 'Setup stopped.',
      detail: undefined,
    });
    expect(
      setupOutcome(setupOperation({ stage: 'waiting_for_approval' }, { state: 'cancelled' }))
        ?.detail,
    ).toBe('An enrollment waiting for approval goes on. Set up again to follow it.');
    expect(
      setupOutcome(
        setupOperation({ stage: 'waiting_for_approval', background: true }, { state: 'cancelled' }),
      )?.detail,
    ).toBe(
      'This Mac keeps waiting for approval in the background, also across restarts, and enrolls by itself once approved.',
    );
  });

  it('gives another failure the CLI’s own reason', () => {
    expect(
      setupOutcome(
        failed([
          'Darkbloom Sandbox waitlist',
          "You're on the Darkbloom Sandbox waitlist: #3 in line (joined Oct 29, 2026)",
        ]),
      ),
    ).toEqual({
      title: 'Setup did not finish.',
      detail: "You're on the Darkbloom Sandbox waitlist: #3 in line (joined Oct 29, 2026)",
    });
    expect(
      setupOutcome(
        failed(
          [
            '  ✗ Installing',
            '    could not write ~/DarkbloomSandbox',
            '',
            'Setup did not finish. When the problem above is fixed, run `darkbloom sandbox setup` again; it is safe to rerun.',
          ],
          { stage: 'installing', message: 'could not write ~/DarkbloomSandbox' },
        ),
      ),
    ).toEqual({ title: 'Setup did not finish.', detail: 'could not write ~/DarkbloomSandbox' });
    expect(
      setupOutcome(
        setupOperation({}, { state: 'interrupted', message: 'The control connection restarted.' }),
      ),
    ).toEqual({ title: 'Setup was interrupted.', detail: 'The control connection restarted.' });
  });
});

describe('the setup form', () => {
  const choice = (overrides: Partial<SetupChoice> = {}): SetupChoice => ({
    automatic: true,
    linux: '1',
    macos: '1',
    disk: '',
    keepInternal: false,
    waitReady: false,
    ...overrides,
  });

  it('takes Linux 0 to 16 and macOS 0 to 2, never both 0', () => {
    expect(slotCounts('2', '1')).toEqual({ counts: { linux_slots: 2, macos_slots: 1 } });
    expect(slotCounts('0', '2')).toEqual({ counts: { linux_slots: 0, macos_slots: 2 } });
    expect(slotCounts('0', '0').error).toBe('Choose at least one job.');
    expect(slotCounts('17', '1').error).toBe('Linux jobs: 0 to 16.');
    expect(slotCounts('1', '3').error).toBe('macOS jobs: 0 to 2.');
    expect(slotCounts('', '1').error).toBe('Linux jobs: 0 to 16.');
    expect(slotCounts('1.5', '1').error).toBe('Linux jobs: 0 to 16.');
    expect(slotCounts('-1', '1').error).toBe('Linux jobs: 0 to 16.');
  });

  it('takes a work disk as a full path', () => {
    expect(workDisk('  ')).toEqual({});
    expect(workDisk(' /Volumes/FastSSD ')).toEqual({ path: '/Volumes/FastSSD' });
    expect(workDisk('~/Jobs')).toEqual({ path: '~/Jobs' });
    expect(workDisk('Volumes/FastSSD').error).toBe(
      'Enter the drive’s full path, such as /Volumes/FastSSD.',
    );
    expect(workDisk('/Volumes/Fast\nSSD').error).toBe(
      'Enter the drive’s path, such as /Volumes/FastSSD.',
    );
    expect(workDisk('/' + 'a'.repeat(1024)).error).toBeDefined();
  });

  it('sends only what was chosen', () => {
    expect(setupRequest(choice())).toEqual({ action: { action: 'sandbox_setup' } });
    expect(
      setupRequest(
        choice({
          automatic: false,
          linux: '3',
          macos: '0',
          disk: '/Volumes/FastSSD',
          keepInternal: true,
          waitReady: true,
        }),
      ),
    ).toEqual({
      action: {
        action: 'sandbox_setup',
        linux_slots: 3,
        macos_slots: 0,
        disks: ['/Volumes/FastSSD', '~'],
        wait_ready: true,
      },
    });
    expect(setupRequest(choice({ disk: '~', keepInternal: true })).action?.disks).toEqual(['~']);
    expect(setupRequest(choice({ keepInternal: true })).action).toEqual({
      action: 'sandbox_setup',
    });
    expect(setupRequest(choice({ automatic: false, linux: '0', macos: '0', disk: 'x' }))).toEqual({
      slotsError: 'Choose at least one job.',
      diskError: 'Enter the drive’s full path, such as /Volumes/FastSSD.',
    });
  });
});
