// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Operation, Snapshot } from '../src/shared/contracts';
import type { BackendState } from '../src/renderer/useBackend';
import { Waitlists } from '../src/renderer/features/waitlists/Waitlists';
import { resetWaitlists } from '../src/renderer/features/waitlists/waitlistStore';
import { cluster, day, deferred, labs, list, sandbox, waitlistBackend } from './waitlistsFixtures';

const api = vi.hoisted(() => ({
  read: vi.fn(),
  act: vi.fn(),
  copy: vi.fn(),
  openExternal: vi.fn(),
}));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api }));
afterEach(() => {
  cleanup();
  resetWaitlists();
  vi.resetAllMocks();
});

const login = 'Link this Mac to your Darkbloom account first: darkbloom login';

function page(backend: BackendState = waitlistBackend()) {
  const navigate = vi.fn();
  const view = render(<Waitlists backend={backend} navigate={navigate} />);
  return { navigate, view, backend };
}

describe('Early access', () => {
  it('lists every waitlist in the coordinator’s order under its heading', async () => {
    api.read.mockResolvedValue(list(sandbox, cluster, labs));
    page();
    expect(screen.getByRole('heading', { level: 1, name: 'Early access' })).toBeVisible();
    const waitlists = await screen.findByRole('list', { name: 'Waitlists' });
    expect(
      within(waitlists)
        .getAllByRole('heading', { level: 2 })
        .map((heading) => heading.textContent),
    ).toEqual(['Darkbloom Sandbox', 'Clusters', 'Darkbloom Labs']);
    expect(within(waitlists).getAllByRole('listitem')).toHaveLength(3);
  });

  it.each([
    ['cluster', 'Clusters', 'cluster'],
    ['sandbox', 'Darkbloom Sandbox', 'sandboxes'],
  ])('opens the %s page once approved', async (feature, title, route) => {
    const entry = feature === 'cluster' ? cluster : { ...sandbox, status: 'approved' as const };
    api.read.mockResolvedValue(list(entry));
    const { navigate } = page();
    const card = await screen.findByRole('article', { name: title });
    const open = within(card).getByRole('button', { name: 'Open' });
    expect(open).toHaveAccessibleDescription(title);
    fireEvent.click(open);
    expect(navigate).toHaveBeenCalledExactlyOnceWith(route);
  });

  it('shows the start command of a waitlist with no page here', async () => {
    api.read.mockResolvedValue(list(labs));
    page();
    const card = await screen.findByRole('article', { name: 'Darkbloom Labs' });
    expect(card).toHaveTextContent(`Approved since ${day(labs.decided_at!)}`);
    expect(within(card).getByText('darkbloom labs')).toBeVisible();
    expect(within(card).getByRole('button', { name: 'Copy darkbloom labs' })).toBeVisible();
    expect(within(card).queryByRole('button', { name: 'Open' })).not.toBeInTheDocument();
  });

  it('shows the shape of the list while it loads', () => {
    api.read.mockReturnValue(new Promise(() => {}));
    page();
    expect(screen.getByRole('list', { name: 'Loading waitlists' })).toHaveAttribute(
      'aria-busy',
      'true',
    );
  });

  it('keeps the list when a later read fails, and says why', async () => {
    api.read
      .mockResolvedValueOnce(list(cluster))
      .mockRejectedValueOnce(new Error('Runtime is not connected'));
    const { view, navigate } = page();
    await screen.findByRole('article', { name: 'Clusters' });
    view.rerender(
      <Waitlists backend={waitlistBackend({ resource_revision: '1001' })} navigate={navigate} />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent('Runtime is not connected');
    expect(screen.getByRole('article', { name: 'Clusters' })).toBeVisible();
  });
});

describe('when the list is unavailable', () => {
  it('links this Mac with the app’s own flow, then reads the list for the account', async () => {
    api.read.mockResolvedValue({ data: [], error: login, code: 'login' });
    const backend = waitlistBackend({ linked: false });
    const { view, navigate } = page(backend);
    const panel = await screen.findByRole('region', { name: 'Waitlists' });
    expect(panel).toHaveTextContent('Link this Mac to your Darkbloom account first.');
    expect(panel).not.toHaveTextContent('darkbloom login');
    await act(async () =>
      fireEvent.click(within(panel).getByRole('button', { name: 'Link account' })),
    );
    expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'link' });

    // The runtime shows the code; Cancel stops the link.
    const linking: Operation = {
      id: 'link-1',
      action: 'link',
      state: 'running',
      started_at: 1_790_000_000,
      message: '',
      cancellable: true,
    };
    const withCode = waitlistBackend({
      linked: false,
      operations: [linking],
      link: {
        url: 'https://console.darkbloom.dev/link',
        code: 'KXQF-7M2P',
        expires_at: 0,
        state: '',
      },
    });
    view.rerender(<Waitlists backend={withCode} navigate={navigate} />);
    expect(screen.getByLabelText('Link code KXQF-7M2P')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Open link page' }));
    expect(api.openExternal).toHaveBeenCalledWith('link');

    // Once linked, the account changes and its waitlists are read.
    api.read.mockResolvedValue(list(cluster));
    view.rerender(
      <Waitlists
        backend={waitlistBackend({ linked: true, account_revision: 'account-2' })}
        navigate={navigate}
      />,
    );
    expect(await screen.findByRole('article', { name: 'Clusters' })).toBeVisible();
  });

  it('shows the code of a link that is already running, with Cancel', async () => {
    api.read.mockResolvedValue({ data: [], error: login, code: 'login' });
    const backend = waitlistBackend({
      linked: false,
      operations: [
        {
          id: 'link-1',
          action: 'link',
          state: 'running',
          started_at: 1_790_000_000,
          message: '',
          cancellable: true,
        },
      ],
      link: {
        url: 'https://console.darkbloom.dev/link',
        code: 'KXQF-7M2P',
        expires_at: 0,
        state: '',
      },
    });
    page(backend);
    expect(await screen.findByLabelText('Link code KXQF-7M2P')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'cancel', operation: 'link-1' });
  });

  it('sends a linked Mac whose link the coordinator refuses to Settings', async () => {
    const refused =
      'https://api.darkbloom.dev refused this account: HTTP 403: suspended\n  Link this Mac to your Darkbloom account again: darkbloom login';
    api.read.mockResolvedValue({ data: [], error: refused, code: 'login' });
    const { navigate } = page(waitlistBackend({ linked: true }));
    const panel = await screen.findByRole('region', { name: 'Waitlists' });
    expect(panel).toHaveTextContent('refused this account: HTTP 403: suspended');
    expect(panel).toHaveTextContent('Unlink this Mac in Settings, then link it again.');
    expect(within(panel).queryByRole('button', { name: 'Link account' })).not.toBeInTheDocument();
    fireEvent.click(within(panel).getByRole('button', { name: 'Open Settings' }));
    expect(navigate).toHaveBeenCalledExactlyOnceWith('settings');
  });

  it('says there is nothing to join on a coordinator without waitlists', async () => {
    const none =
      'https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there.';
    api.read.mockResolvedValue({ data: [], error: none, code: 'none' });
    page();
    const panel = await screen.findByRole('region', { name: 'Waitlists' });
    expect(panel).toHaveTextContent(`No waitlists${none}`);
    expect(within(panel).queryByRole('button')).not.toBeInTheDocument();
    cleanup();
    resetWaitlists();
    api.read.mockResolvedValue(list());
    page();
    expect(await screen.findByRole('region', { name: 'Waitlists' })).toHaveTextContent(
      'There’s nothing to join here yet.',
    );
  });

  it('says why it is unavailable and reads again on Try again', async () => {
    const down = 'Could not reach the waitlists at https://api.darkbloom.dev: timed out';
    const retry = deferred<unknown>();
    api.read
      .mockResolvedValueOnce({ data: [], error: down, code: 'unavailable' })
      .mockReturnValueOnce(retry.promise);
    page();
    const panel = await screen.findByRole('region', { name: 'Waitlists' });
    expect(panel).toHaveTextContent(down);
    await act(async () =>
      fireEvent.click(within(panel).getByRole('button', { name: 'Try again' })),
    );
    expect(within(panel).getByRole('button', { name: 'Trying…' })).toBeDisabled();
    await act(async () => retry.resolve(list(cluster)));
    expect(screen.getByRole('article', { name: 'Clusters' })).toBeVisible();
  });

  it('says why when the runtime can’t be read at all', async () => {
    api.read.mockRejectedValue(
      new Error("Error invoking remote method 'backend:read': Error: Runtime is not connected"),
    );
    page();
    expect(await screen.findByRole('region', { name: 'Waitlists' })).toHaveTextContent(
      'Runtime is not connected',
    );
  });

  it('asks for a newer CLI on a runtime without waitlists, and reads nothing', () => {
    const backend = waitlistBackend({ capabilities: ['autopilot'] } as Partial<Snapshot>);
    const { navigate } = page(backend);
    expect(screen.getByText('Early access needs a newer Darkbloom CLI.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Open Updates' }));
    expect(navigate).toHaveBeenCalledExactlyOnceWith('updates');
    expect(api.read).not.toHaveBeenCalled();
  });
});
