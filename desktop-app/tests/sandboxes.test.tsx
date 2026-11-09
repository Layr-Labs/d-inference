// @vitest-environment jsdom
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Operation, Snapshot } from '../src/shared/contracts';
import type { SandboxStatus } from '../src/shared/sandbox';
import type { BackendState } from '../src/renderer/useBackend';
import { backendWith } from './onboardingFixtures';
import {
  approval,
  disks,
  fakeBridge,
  sandboxSnapshot,
  setupOperation,
  statuses,
  waitlists,
} from './sandboxFixtures';

const { bridge, read, resources } = fakeBridge();
let Sandboxes: typeof import('../src/renderer/features/sandboxes/Sandboxes').Sandboxes;

beforeAll(async () => {
  window.history.replaceState({}, '', '/');
  window.darkbloom = bridge;
  ({ Sandboxes } = await import('../src/renderer/features/sandboxes/Sandboxes'));
});
beforeEach(() => {
  for (const key of Object.keys(resources)) delete resources[key as keyof typeof resources];
  resources.waitlists = waitlists('approved');
});
afterEach(() => {
  cleanup();
  localStorage.clear();
  vi.clearAllMocks();
});
afterAll(() => {
  delete window.darkbloom;
});

function show(
  status: SandboxStatus | Error,
  { state = sandboxSnapshot(), ...overrides }: Partial<BackendState> & { state?: Snapshot } = {},
) {
  resources.sandbox = status;
  const backend = backendWith(state, overrides);
  const navigate = vi.fn();
  const view = render(<Sandboxes backend={backend} navigate={navigate} />);
  return { backend, navigate, ...view };
}

describe('a runtime without Darkbloom Sandbox', () => {
  it('says it needs a newer CLI and reads nothing', () => {
    const { navigate } = show(statuses.ready, {
      state: sandboxSnapshot({ capabilities: ['account-signin', 'autopilot'] }),
    });
    expect(screen.getByRole('heading', { level: 1, name: 'Sandboxes' })).toBeVisible();
    expect(screen.getByText('Darkbloom Sandbox needs a newer Darkbloom CLI.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Open Updates' }));
    expect(navigate).toHaveBeenCalledWith('updates');
    expect(read).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Set up' })).toBeNull();
  });

  it('counts a runtime from before capabilities as one without it', () => {
    show(statuses.ready, { state: sandboxSnapshot({ capabilities: undefined }) });
    expect(screen.getByText('Darkbloom Sandbox needs a newer Darkbloom CLI.')).toBeVisible();
  });
});

describe('a Mac without the add-on', () => {
  it('says what it is and what it needs, then sets up with what fits this Mac', async () => {
    const { backend } = show(statuses.notInstalled);
    expect(
      await screen.findByText(
        'Runs approved GitHub Actions jobs in Linux and macOS VMs on this Mac.',
      ),
    ).toBeVisible();
    expect(
      screen.getByText(
        'Each job pays its price minus a 10% fee into your Darkbloom balance. Inference pauses while a job runs.',
      ),
    ).toBeVisible();
    const needs = screen.getByRole('region', { name: 'Requirements' });
    expect(within(needs).getByText('Apple silicon').closest('li')).toHaveAttribute(
      'data-state',
      'met',
    );
    expect(within(needs).getByText('macOS 27.0')).toBeVisible();
    expect(within(needs).getByText('Wi-Fi')).toBeVisible();
    expect(within(needs).getByText('sudo pmset -c sleep 0')).toBeVisible();
    const form = await screen.findByRole('form', { name: 'Set up Darkbloom Sandbox' });
    expect(within(form).getByRole('radio', { name: /Automatic/ })).toBeChecked();
    expect(
      within(form).getByRole('checkbox', { name: 'Wait until images are downloaded' }),
    ).not.toBeChecked();
    fireEvent.click(within(form).getByRole('button', { name: 'Set up' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'sandbox_setup' });
  });

  it('sends the chosen jobs, work disk and wait, and refuses both counts at 0', async () => {
    const { backend } = show(statuses.notInstalled);
    const form = await screen.findByRole('form', { name: 'Set up Darkbloom Sandbox' });
    fireEvent.click(within(form).getByRole('radio', { name: /Choose/ }));
    const linux = within(form).getByRole('spinbutton', { name: 'Linux' });
    const macos = within(form).getByRole('spinbutton', { name: 'macOS' });
    fireEvent.change(linux, { target: { value: '0' } });
    fireEvent.change(macos, { target: { value: '0' } });
    expect(within(form).getByText('Choose at least one job.')).toBeVisible();
    expect(linux).toHaveAttribute('aria-invalid', 'true');
    expect(within(form).getByRole('button', { name: 'Set up' })).toBeDisabled();
    fireEvent.change(linux, { target: { value: '3' } });
    const disk = within(form).getByRole('textbox', { name: 'Work disk' });
    fireEvent.change(disk, { target: { value: 'FastSSD' } });
    expect(
      within(form).getByText('Enter the drive’s full path, such as /Volumes/FastSSD.'),
    ).toBeVisible();
    fireEvent.change(disk, { target: { value: '/Volumes/FastSSD' } });
    fireEvent.click(
      within(form).getByRole('checkbox', { name: 'Wait until images are downloaded' }),
    );
    fireEvent.click(within(form).getByRole('button', { name: 'Set up' }));
    expect(backend.act).toHaveBeenCalledWith({
      action: 'sandbox_setup',
      linux_slots: 3,
      macos_slots: 0,
      disks: ['/Volumes/FastSSD'],
      wait_ready: true,
    });
  });

  it('waits while another action runs', async () => {
    show(statuses.notInstalled, { busy: true });
    expect(await screen.findByRole('button', { name: 'Set up' })).toBeDisabled();
  });

  it('shows the waitlist instead of setup until the account is approved', async () => {
    resources.waitlists = waitlists('waitlisted');
    show(statuses.notInstalled);
    expect(await screen.findByText('#3 in line.')).toBeVisible();
    expect(screen.getByRole('heading', { name: 'Darkbloom Sandbox' })).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Set up' })).toBeNull();
  });

  it('offers setup on a coordinator without the waitlist', async () => {
    resources.waitlists = { data: [] };
    show(statuses.notInstalled);
    expect(await screen.findByRole('button', { name: 'Set up' })).toBeEnabled();
  });

  it('asks to link this Mac when the waitlist needs the account', async () => {
    resources.waitlists = { data: [], error: 'Link this Mac first.', code: 'login' };
    const { backend } = show(statuses.notInstalled);
    expect(await screen.findByText('Link this Mac to your Darkbloom account first.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Link account' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'link' });
  });

  it('says why the waitlist is unavailable, unless the runtime predates waitlists', async () => {
    resources.waitlists = new Error('Could not reach the Darkbloom Sandbox waitlist.');
    show(statuses.notInstalled);
    const failure = await screen.findByRole('alert');
    expect(failure).toHaveTextContent('Could not reach the Darkbloom Sandbox waitlist.');
    read.mockClear();
    fireEvent.click(within(failure).getByRole('button', { name: 'Try again' }));
    await waitFor(() => expect(read).toHaveBeenCalledWith('waitlists'));
    cleanup();
    show(statuses.notInstalled, {
      state: sandboxSnapshot({ capabilities: ['sandbox'] }),
    });
    expect(await screen.findByRole('button', { name: 'Set up' })).toBeEnabled();
  });

  it('stops before setup below macOS 27', async () => {
    show(statuses.notInstalled, { system: { macosVersion: '26.5' } });
    expect(
      await screen.findByText(
        'Darkbloom Sandbox needs macOS 27 or later. This Mac runs macOS 26.5.',
      ),
    ).toBeVisible();
    expect(screen.getByText('macOS 27 or later').closest('li')).toHaveAttribute(
      'data-state',
      'unmet',
    );
    fireEvent.click(screen.getByRole('button', { name: 'Open Software Update' }));
    expect(bridge.openSoftwareUpdate).toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Set up' })).toBeNull();
  });

  it('says when the status could not be read, and reads it again', async () => {
    show(new Error('The add-on did not answer within 10s'));
    const failure = await screen.findByRole('alert');
    expect(failure).toHaveTextContent('The add-on did not answer within 10s');
    resources.sandbox = statuses.ready;
    fireEvent.click(within(failure).getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('heading', { level: 2, name: 'Ready' })).toBeVisible();
  });
});

describe('a setup in progress', () => {
  const running = (progress: Parameters<typeof setupOperation>[0], overrides = {}) =>
    sandboxSnapshot({ operations: [setupOperation(progress, overrides)] });

  it('shows the stages and the one approval, opened only from the button', async () => {
    show(statuses.notInstalled, {
      state: running({
        stage: 'waiting_for_approval',
        step: 4,
        steps: 8,
        approval,
        background: true,
      }),
    });
    const setup = screen.getByRole('region', { name: 'Darkbloom Sandbox setup' });
    expect(
      within(setup).getByRole('heading', { name: 'Setting up Darkbloom Sandbox' }),
    ).toBeVisible();
    const steps = within(setup).getByRole('list', { name: 'Setup steps' });
    expect(within(steps).getAllByRole('listitem')).toHaveLength(8);
    expect(steps.querySelector('[aria-current="step"]')).toHaveTextContent(
      'In progress: Waiting for approval',
    );
    expect(within(steps).getByText('Installing').closest('li')).toHaveAttribute(
      'data-state',
      'done',
    );
    const card = within(setup).getByRole('region', { name: 'Approve this Mac' });
    expect(within(card).getByLabelText('Approval code WDJB-MJHT')).toBeVisible();
    expect(bridge.openApproval).not.toHaveBeenCalled();
    fireEvent.click(within(card).getByRole('button', { name: 'Open approval page' }));
    expect(bridge.openApproval).toHaveBeenCalledWith(approval.verification_uri_complete);
    fireEvent.click(within(card).getByRole('button', { name: 'Copy code' }));
    expect(bridge.copy).toHaveBeenCalledWith('WDJB-MJHT');
    expect(await within(card).findByRole('button', { name: 'Copied' })).toBeVisible();
    fireEvent.click(within(card).getByRole('button', { name: 'Copy link' }));
    expect(bridge.copy).toHaveBeenCalledWith(approval.verification_uri_complete);
    expect(
      within(card).getByText(
        'You can close the app: this Mac enrolls by itself once you approve it, also after a restart.',
      ),
    ).toBeVisible();
    // The form is not offered while the setup runs.
    expect(screen.queryByRole('form', { name: 'Set up Darkbloom Sandbox' })).toBeNull();
  });

  it('opens the plain page when the installer gives no complete link', () => {
    show(statuses.notInstalled, {
      state: running({
        stage: 'waiting_for_approval',
        approval: { ...approval, verification_uri_complete: null },
      }),
    });
    expect(screen.getByText(/enter the code, then press Approve/)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Open approval page' }));
    expect(bridge.openApproval).toHaveBeenCalledWith(approval.verification_uri);
  });

  it('says when the page could not open', async () => {
    vi.mocked(bridge.openApproval).mockRejectedValueOnce(new Error('Unsupported link'));
    show(statuses.notInstalled, {
      state: running({ stage: 'waiting_for_approval', approval }),
    });
    fireEvent.click(screen.getByRole('button', { name: 'Open approval page' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Couldn’t open the page. Copy the link and open it in a browser.',
    );
  });

  it('says the account waits on the waitlist, and when the app can close', () => {
    show(statuses.waiting, {
      state: running({
        stage: 'waiting_for_approval',
        approval,
        waitlisted: true,
        background: true,
      }),
    });
    const note = screen.getByRole('region', { name: 'On the waitlist' });
    expect(note).toHaveTextContent(
      'You can close the app: this Mac keeps waiting, also across restarts, and enrolls by itself once your account is approved.',
    );
    expect(screen.queryByRole('region', { name: 'Approve this Mac' })).toBeNull();
    // The installed add-on's own status would repeat the setup while it enrolls.
    expect(screen.queryByRole('region', { name: 'Darkbloom Sandbox status' })).toBeNull();
    cleanup();
    show(statuses.notInstalled, {
      state: running({ stage: 'waiting_for_approval', waitlisted: true }),
    });
    expect(screen.getByRole('region', { name: 'On the waitlist' })).toHaveTextContent(
      'Leave setup running; this Mac enrolls once your account is approved.',
    );
  });

  it('shows the download and cancels a cancellable setup', () => {
    const { backend } = show(statuses.notInstalled, {
      state: running({ stage: 'downloading_images', progress: 0.5 }),
    });
    expect(screen.getByText('Downloading images 50%')).toBeVisible();
    // The stage is announced once, not each percent.
    const announced = document.querySelector('p[aria-live="polite"]');
    expect(announced).toHaveTextContent(/^Downloading images$/);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'cancel', operation: 'setup-1' });
    cleanup();
    show(statuses.notInstalled, {
      state: running({ stage: 'installing' }, { cancellable: false }),
    });
    expect(screen.queryByRole('button', { name: 'Cancel' })).toBeNull();
    expect(screen.queryByText('Cancelling…')).toBeNull();
    cleanup();
    // The runtime takes Cancel away and says so until the installer has stopped.
    show(statuses.notInstalled, {
      state: running({ stage: 'installing' }, { cancellable: false, message: 'Cancelling…' }),
    });
    expect(screen.getByText('Cancelling…')).toBeVisible();
  });

  it('keeps the installed add-on’s status under a slot change', async () => {
    show(statuses.ready, { state: running({ stage: 'installing' }) });
    expect(screen.getByRole('region', { name: 'Darkbloom Sandbox setup' })).toBeVisible();
    expect(await screen.findByRole('heading', { level: 2, name: 'Ready' })).toBeVisible();
  });
});

describe('an ended setup', () => {
  const ended = (progress: Parameters<typeof setupOperation>[0], overrides: Partial<Operation>) =>
    sandboxSnapshot({
      operations: [setupOperation(progress, { cancellable: false, ...overrides })],
    });

  it('says what the installer’s exit status means until dismissed', async () => {
    show(statuses.ready, {
      state: ended(
        { stage: 'installing', exit_status: 4 },
        { state: 'failed', lines: ['  ✗ Installing', '    A job is running'] },
      ),
    });
    const setup = screen.getByRole('region', { name: 'Darkbloom Sandbox setup' });
    expect(
      within(setup).getByRole('heading', { name: 'A job is running, so nothing changed.' }),
    ).toBeVisible();
    expect(setup).toHaveTextContent('Pause keeps new jobs from starting.');
    expect(within(setup).getByText('Installing').closest('li')).toHaveAttribute(
      'data-state',
      'failed',
    );
    fireEvent.click(within(setup).getByText('Details'));
    expect(within(setup).getByText(/A job is running$/)).toBeVisible();
    fireEvent.click(within(setup).getByRole('button', { name: 'Dismiss setup result' }));
    expect(screen.queryByRole('region', { name: 'Darkbloom Sandbox setup' })).toBeNull();
    expect(localStorage.getItem('darkbloom.sandbox.dismissed-setup')).toBe('setup-1');
  });

  it('shows a stop before the installer ran without stages, beside the form', async () => {
    show(statuses.notInstalled, {
      state: ended(
        {},
        {
          state: 'failed',
          lines: ["You're on the Darkbloom Sandbox waitlist: #3 in line (joined Oct 29, 2026)"],
        },
      ),
    });
    const setup = screen.getByRole('region', { name: 'Darkbloom Sandbox setup' });
    expect(within(setup).getByRole('heading', { name: 'Setup did not finish.' })).toBeVisible();
    expect(setup).toHaveTextContent("You're on the Darkbloom Sandbox waitlist: #3 in line");
    expect(within(setup).queryByRole('list', { name: 'Setup steps' })).toBeNull();
    expect(await screen.findByRole('button', { name: 'Set up' })).toBeVisible();
  });

  it('leaves a succeeded setup to the status', async () => {
    show(statuses.ready, { state: ended({ stage: 'ready' }, { state: 'succeeded' }) });
    expect(await screen.findByRole('heading', { level: 2, name: 'Ready' })).toBeVisible();
    expect(screen.queryByRole('region', { name: 'Darkbloom Sandbox setup' })).toBeNull();
  });
});

describe('the installed add-on', () => {
  it('shows the state, what it means, free slots, jobs and images', async () => {
    show(statuses.running);
    const card = await screen.findByRole('region', { name: 'Darkbloom Sandbox status' });
    expect(within(card).getByRole('heading', { level: 2, name: 'Running 1 job' })).toBeVisible();
    expect(card).toHaveTextContent(
      'Inference is paused while jobs run, and resumes after the last one ends.',
    );
    expect(within(card).getByRole('meter', { name: 'Linux slots' })).toHaveAttribute(
      'aria-valuetext',
      '0 of 1 free',
    );
    expect(within(card).getByRole('meter', { name: 'macOS slots' })).toHaveAttribute(
      'aria-valuetext',
      '1 of 1 free',
    );
    expect(within(card).getByText('Jobs running').nextSibling).toHaveTextContent('1');
    expect(within(card).getAllByText('Installed')).toHaveLength(2);
    expect(card).toHaveTextContent('Darkbloom Sandbox 1.0.1');
    expect(card).toHaveTextContent('Host 0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60');
    expect(card).toHaveTextContent(/Updates automatic, last checked/);
  });

  it('opens the console through the approval channel, which takes only Darkbloom hosts', async () => {
    show(statuses.ready);
    fireEvent.click(await screen.findByRole('button', { name: 'Open console' }));
    expect(bridge.openApproval).toHaveBeenCalledWith(statuses.ready.console_url);
  });

  it('pauses after asking, and resumes', async () => {
    const { backend } = show(statuses.ready);
    fireEvent.click(await screen.findByRole('button', { name: 'Pause' }));
    const dialog = screen.getByRole('dialog', { name: 'Pause Darkbloom Sandbox?' });
    expect(dialog).toHaveTextContent('Running jobs finish; no new jobs start until you resume.');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Pause' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'sandbox_pause' }, true);
    cleanup();
    const paused = show(statuses.paused);
    expect(await screen.findByRole('heading', { level: 2, name: 'Paused' })).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Resume' }));
    expect(paused.backend.act).toHaveBeenCalledWith({ action: 'sandbox_resume' }, true);
  });

  it('says running jobs end unpaid before uninstalling', async () => {
    const { backend } = show(statuses.running);
    fireEvent.click(await screen.findByRole('button', { name: 'Uninstall' }));
    const dialog = screen.getByRole('dialog', { name: 'Uninstall Darkbloom Sandbox?' });
    expect(dialog).toHaveTextContent('Running jobs end and aren’t paid.');
    expect(dialog).toHaveTextContent(
      '1 job running now. Pause first, and uninstall once it finishes.',
    );
    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    expect(backend.act).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Uninstall' }));
    fireEvent.click(
      within(screen.getByRole('dialog', { name: 'Uninstall Darkbloom Sandbox?' })).getByRole(
        'button',
        { name: 'Uninstall' },
      ),
    );
    expect(backend.act).toHaveBeenCalledWith({ action: 'sandbox_uninstall' }, true);
  });

  it('changes jobs at a time with setup, except while a job runs', async () => {
    const { backend } = show({
      ...statuses.ready,
      slots: { linux: { total: 2, free: 2 }, macos: { total: 1, free: 1 } },
    });
    fireEvent.click(await screen.findByRole('button', { name: 'Change jobs at a time' }));
    let dialog = screen.getByRole('dialog', { name: 'Jobs at a time' });
    expect(within(dialog).getByRole('spinbutton', { name: 'Linux' })).toHaveValue(2);
    expect(within(dialog).getByRole('spinbutton', { name: 'macOS' })).toHaveValue(1);
    fireEvent.change(within(dialog).getByRole('spinbutton', { name: 'Linux' }), {
      target: { value: '4' },
    });
    fireEvent.change(within(dialog).getByRole('spinbutton', { name: 'macOS' }), {
      target: { value: '0' },
    });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Apply' }));
    expect(backend.act).toHaveBeenCalledWith(
      { action: 'sandbox_setup', linux_slots: 4, macos_slots: 0 },
      false,
    );
    cleanup();
    show(statuses.running);
    fireEvent.click(await screen.findByRole('button', { name: 'Change jobs at a time' }));
    dialog = screen.getByRole('dialog', { name: 'Jobs at a time' });
    expect(dialog).toHaveTextContent(
      'A job is running, and the installer changes nothing while one runs.',
    );
    expect(within(dialog).getByRole('button', { name: 'Apply' })).toBeDisabled();
  });

  it('reads the add-on’s log only when asked, and again on Refresh', async () => {
    resources['sandbox-logs'] = {
      lines: ['21:58:02 agent: connected', '22:10:41 job 8812: accepted'],
      observed_at: 1_790_000_000,
    };
    show(statuses.ready);
    const logs = await screen.findByRole('button', { name: 'Logs' });
    expect(read).not.toHaveBeenCalledWith('sandbox-logs');
    expect(logs).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(logs);
    expect(logs).toHaveAttribute('aria-expanded', 'true');
    const panel = screen.getByRole('region', { name: 'Add-on log' });
    expect(await within(panel).findByText(/22:10:41 job 8812: accepted/)).toBeVisible();
    const logReads = () => read.mock.calls.filter(([resource]) => resource === 'sandbox-logs');
    expect(logReads()).toHaveLength(1);
    fireEvent.click(within(panel).getByRole('button', { name: 'Refresh' }));
    await waitFor(() => expect(logReads()).toHaveLength(2));
    fireEvent.click(logs);
    expect(screen.queryByRole('region', { name: 'Add-on log' })).toBeNull();
  });

  it('says why the log is unavailable', async () => {
    resources['sandbox-logs'] = { lines: [], observed_at: 1, error: 'No log yet.' };
    show(statuses.ready);
    fireEvent.click(await screen.findByRole('button', { name: 'Logs' }));
    expect(await screen.findByText('No log yet.')).toBeVisible();
  });

  it('lists work disks with their state, free space and slots', async () => {
    show({ ...statuses.ready, disks });
    const card = await screen.findByRole('region', { name: 'Darkbloom Sandbox status' });
    const rows = within(card)
      .getAllByRole('listitem')
      .filter(
        (row) =>
          row.closest('ul')?.parentElement?.querySelector('h3')?.textContent === 'Work disks',
      );
    expect(rows.map((row) => row.textContent)).toEqual([
      '/Volumes/FastSSDOnline812 GiB freeLinux 2, macOS 1',
      '/System/Volumes/DataInternalOnline157 GiB freeLinux 1',
      '/Volumes/ArchiveOfflineLinux 1Not connected: connect it again',
    ]);
  });

  it('follows the setup or repairs, by state', async () => {
    const { backend } = show(statuses.waiting);
    expect(await screen.findByText(statuses.waiting.detail)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Continue setup' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'sandbox_setup' }, false);
    expect(screen.queryByRole('button', { name: 'Change jobs at a time' })).toBeNull();
    cleanup();
    const failed = show(statuses.error);
    fireEvent.click(await screen.findByRole('button', { name: 'Repair' }));
    expect(failed.backend.act).toHaveBeenCalledWith({ action: 'sandbox_setup' }, false);
  });

  it('shows the waitlist place while the add-on waits on it', async () => {
    resources.waitlists = waitlists('waitlisted');
    show({ ...statuses.waiting, state: 'waitlisted', detail: null });
    expect(await screen.findByRole('heading', { level: 2, name: 'On the waitlist' })).toBeVisible();
    expect(await screen.findByText('#3 in line.')).toBeVisible();
  });

  it('shows an add-on download, and a newer state as its words', async () => {
    show(statuses.downloading);
    expect(
      await screen.findByRole('heading', { level: 2, name: 'Downloading images · Linux 42%' }),
    ).toBeVisible();
    expect(screen.getByText('Downloading 42%')).toBeVisible();
    expect(screen.getByText('Missing')).toBeVisible();
    expect(screen.queryByRole('meter')).toBeNull();
    expect(screen.getByText('Linux 1, macOS 1')).toBeVisible();
    cleanup();
    show(statuses.future);
    expect(await screen.findByRole('heading', { level: 2, name: 'Hibernating' })).toBeVisible();
    expect(screen.getByText('Sleeping until 22:00')).toBeVisible();
  });

  it('offers repair when the status can’t be read', async () => {
    const { backend } = show({
      schema: 1,
      installed: true,
      state: 'error',
      error: 'The add-on did not answer within 10s.',
    });
    const card = await screen.findByRole('region', { name: 'Darkbloom Sandbox status' });
    expect(within(card).getByRole('heading', { name: 'Status unavailable' })).toBeVisible();
    expect(card).toHaveTextContent('The add-on did not answer within 10s.');
    expect(screen.queryByRole('button', { name: 'Open console' })).toBeNull();
    fireEvent.click(within(card).getByRole('button', { name: 'Repair' }));
    expect(backend.act).toHaveBeenCalledWith({ action: 'sandbox_setup' }, false);
  });

  it('reads the status again when a sandbox action finishes', async () => {
    const pause: Operation = {
      id: 'pause-1',
      action: 'sandbox_pause',
      state: 'running',
      started_at: 1,
      message: '',
      cancellable: false,
    };
    const backend = backendWith(sandboxSnapshot({ operations: [pause] }));
    resources.sandbox = statuses.ready;
    const { rerender } = render(<Sandboxes backend={backend} navigate={vi.fn()} />);
    await screen.findByRole('heading', { level: 2, name: 'Ready' });
    resources.sandbox = statuses.paused;
    const finished = { ...pause, state: 'succeeded' as const, finished_at: 2 };
    await act(async () =>
      rerender(
        <Sandboxes
          backend={{ ...backend, state: sandboxSnapshot({ operations: [finished] }) }}
          navigate={vi.fn()}
        />,
      ),
    );
    expect(await screen.findByRole('heading', { level: 2, name: 'Paused' })).toBeVisible();
  });
});
