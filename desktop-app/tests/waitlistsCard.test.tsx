// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { WaitlistEntry } from '../src/shared/waitlists';
import { WaitlistCard } from '../src/renderer/features/waitlists/WaitlistCard';
import { resetWaitlists } from '../src/renderer/features/waitlists/waitlistStore';
import {
  cluster,
  day,
  deferred,
  joinOperation,
  labs,
  list,
  sandbox,
  waitlistBackend,
} from './waitlistsFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), act: vi.fn(), copy: vi.fn() }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api }));
afterEach(() => {
  cleanup();
  resetWaitlists();
  vi.resetAllMocks();
});

const notJoined: WaitlistEntry = { ...cluster, status: 'none', decided_at: null };
const revoked: WaitlistEntry = {
  ...cluster,
  status: 'revoked',
  decided_at: '2026-11-03T12:00:00Z',
};
const reviewOrder = 'Darkbloom reviews accounts in the order they joined.';

async function card(
  entry: WaitlistEntry,
  props: { onOpen?: () => void } = {},
  backend = waitlistBackend(),
) {
  api.read.mockResolvedValue(list(entry));
  render(<WaitlistCard feature={entry.feature} backend={backend} {...props} />);
  return screen.findByRole('article', { name: entry.title });
}

describe('the card', () => {
  it('offers Join while not on the waitlist', async () => {
    const article = await card(notJoined);
    expect(within(article).getByRole('heading', { level: 2, name: 'Clusters' })).toBeVisible();
    expect(article).toHaveTextContent('Serve one model with two to four of your Macs.');
    expect(article).toHaveTextContent('Not joined');
    expect(within(article).getByRole('button', { name: 'Join the waitlist' })).toBeEnabled();
  });

  it('shows the place in line, the day it joined and how Darkbloom reviews', async () => {
    const article = await card(sandbox);
    expect(within(article).getByText('#3').parentElement).toHaveTextContent('#3 in line');
    expect(article).toHaveTextContent(`Joined ${day(sandbox.requested_at!)}`);
    expect(article).toHaveTextContent(reviewOrder);
    expect(within(article).queryByRole('button')).not.toBeInTheDocument();
  });

  it('says it is on the waitlist when the coordinator gives no place', async () => {
    const article = await card({ ...sandbox, position: null });
    expect(article).toHaveTextContent(`On the waitlist · joined ${day(sandbox.requested_at!)}`);
    expect(within(article).queryByText(/^#/)).not.toBeInTheDocument();
  });

  it('opens an approved feature that has a page in the app', async () => {
    const onOpen = vi.fn();
    const article = await card(cluster, { onOpen });
    expect(article).toHaveTextContent(`Approved since ${day(cluster.decided_at!)}`);
    expect(article).not.toHaveTextContent('darkbloom cluster');
    fireEvent.click(within(article).getByRole('button', { name: 'Open' }));
    expect(onOpen).toHaveBeenCalledOnce();
  });

  it('shows the start command of an approved feature without a page, to copy', async () => {
    api.copy.mockResolvedValue(undefined);
    const article = await card(labs);
    expect(within(article).queryByRole('button', { name: 'Open' })).not.toBeInTheDocument();
    expect(within(article).getByText('darkbloom labs').tagName).toBe('CODE');
    await act(async () =>
      fireEvent.click(within(article).getByRole('button', { name: 'Copy darkbloom labs' })),
    );
    expect(api.copy).toHaveBeenCalledWith('darkbloom labs');
    expect(within(article).getByRole('button', { name: 'Copied darkbloom labs' })).toBeVisible();
  });

  it('says a revoked account stays revoked, with nothing to join', async () => {
    const article = await card(revoked);
    expect(article).toHaveTextContent(`Revoked on ${day(revoked.decided_at!)}`);
    expect(article).toHaveTextContent('Joining again doesn’t restore it.');
    expect(within(article).queryByRole('button')).not.toBeInTheDocument();
  });

  it('shows coordinator text with no control or format characters', async () => {
    api.read.mockResolvedValue(
      list({ ...notJoined, title: 'Clusters\u202e', summary: 'Serve\u200b one model\u0007.' }),
    );
    render(<WaitlistCard feature="cluster" backend={waitlistBackend()} />);
    const article = await screen.findByRole('article', { name: 'Clusters\uFFFD' });
    expect(within(article).getByRole('heading', { level: 2 })).toHaveTextContent('Clusters\uFFFD');
    expect(article).toHaveTextContent('Serve\uFFFD one model\uFFFD.');
  });

  it('waits to join while another operation runs', async () => {
    const article = await card(notJoined, {}, waitlistBackend({}, { busy: true }));
    expect(within(article).getByRole('button', { name: 'Join the waitlist' })).toBeDisabled();
  });

  it('shows nothing for a waitlist the coordinator doesn’t offer', async () => {
    api.read.mockResolvedValue(list(sandbox));
    const view = render(<WaitlistCard feature="cluster" backend={waitlistBackend()} />);
    await act(async () => {});
    expect(view.container).toBeEmptyDOMElement();
  });
});

describe('joining', () => {
  it('joins, says so while it runs, then shows the place and moves focus to it', async () => {
    const answer = deferred<unknown>();
    api.read.mockResolvedValueOnce(list(notJoined)).mockReturnValueOnce(answer.promise);
    api.act.mockResolvedValue(joinOperation('succeeded', 'You’re on the Clusters waitlist.'));
    const article = await card(notJoined);
    const join = within(article).getByRole('button', { name: 'Join the waitlist' });
    join.focus();
    await act(async () => fireEvent.click(join));
    expect(api.act).toHaveBeenCalledExactlyOnceWith({
      action: 'waitlist_join',
      feature: 'cluster',
    });
    expect(within(article).getByRole('button', { name: 'Joining…' })).toBeDisabled();
    expect(article).toHaveAttribute('aria-busy', 'true');
    await act(async () =>
      answer.resolve(
        list({
          ...notJoined,
          status: 'waitlisted',
          position: 41,
          requested_at: '2026-11-08T12:00:00Z',
        }),
      ),
    );
    expect(within(article).getByText('#41').parentElement).toHaveTextContent('#41 in line');
    expect(within(article).queryByRole('button')).not.toBeInTheDocument();
    expect(article).not.toHaveAttribute('aria-busy');
    expect(document.activeElement).toHaveTextContent(`Joined ${day('2026-11-08T12:00:00Z')}`);
  });

  it('shows a refusal in the runtime’s words, reads again and offers Join again', async () => {
    api.read.mockResolvedValue(list(notJoined));
    const refusal = 'https://api.darkbloom.dev refused this account: HTTP 403: suspended';
    api.act.mockResolvedValue(joinOperation('failed', refusal));
    const article = await card(notJoined);
    await act(async () =>
      fireEvent.click(within(article).getByRole('button', { name: 'Join the waitlist' })),
    );
    expect(within(article).getByRole('alert')).toHaveTextContent(refusal);
    expect(api.read.mock.calls.filter(([name]) => name === 'waitlists')).toHaveLength(2);
    expect(within(article).getByRole('button', { name: 'Join the waitlist' })).toBeEnabled();
  });

  it('asks for a newer CLI when the runtime has no such action', async () => {
    api.read.mockResolvedValue(list(notJoined));
    api.act.mockRejectedValue(
      new Error("Error invoking remote method 'backend:act': Error: Unknown action"),
    );
    const article = await card(notJoined);
    await act(async () =>
      fireEvent.click(within(article).getByRole('button', { name: 'Join the waitlist' })),
    );
    expect(within(article).getByRole('alert')).toHaveTextContent(
      'Joining a waitlist needs a newer Darkbloom CLI.',
    );
  });
});

describe('the compact card above a feature’s page', () => {
  async function compact(entry: WaitlistEntry) {
    api.read.mockResolvedValue(list(entry));
    const view = render(
      <WaitlistCard feature={entry.feature} backend={waitlistBackend()} compact />,
    );
    await act(async () => {});
    return view;
  }

  it('says the account isn’t on the waitlist and offers Join', async () => {
    await compact(notJoined);
    const row = screen.getByRole('region', { name: 'Clusters waitlist' });
    expect(row).toHaveTextContent('You’re not on the Clusters waitlist.');
    expect(within(row).getByRole('button', { name: 'Join the waitlist' })).toBeEnabled();
    expect(row).not.toHaveTextContent('Serve one model');
  });

  it('says where the account stands in the CLI’s sentences', async () => {
    await compact(sandbox);
    expect(screen.getByRole('region', { name: 'Darkbloom Sandbox waitlist' })).toHaveTextContent(
      `You’re on the Darkbloom Sandbox waitlist: #3 in line.Joined ${day(sandbox.requested_at!)}. ${reviewOrder}`,
    );
    cleanup();
    resetWaitlists();
    await compact(revoked);
    expect(screen.getByRole('region', { name: 'Clusters waitlist' })).toHaveTextContent(
      `Darkbloom revoked your account’s access to Clusters on ${day(revoked.decided_at!)}.Joining again doesn’t restore it.`,
    );
  });

  it('shows nothing while loading, once approved, or without that waitlist', async () => {
    api.read.mockReturnValue(new Promise(() => {}));
    const loading = render(<WaitlistCard feature="cluster" backend={waitlistBackend()} compact />);
    expect(loading.container).toBeEmptyDOMElement();
    cleanup();
    resetWaitlists();
    expect((await compact(cluster)).container).toBeEmptyDOMElement();
    cleanup();
    resetWaitlists();
    expect((await compact(sandbox)).container).not.toBeEmptyDOMElement();
    api.read.mockResolvedValue({ data: [], error: 'No waitlists here.', code: 'none' });
    cleanup();
    resetWaitlists();
    const none = render(<WaitlistCard feature="cluster" backend={waitlistBackend()} compact />);
    await act(async () => {});
    expect(none.container).toBeEmptyDOMElement();
  });

  it('offers the app’s link flow when this Mac isn’t linked', async () => {
    api.read.mockResolvedValue({
      data: [],
      error: 'Link this Mac to your Darkbloom account first: darkbloom login',
      code: 'login',
    });
    const backend = waitlistBackend({ linked: false });
    render(<WaitlistCard feature="cluster" backend={backend} compact />);
    const row = await screen.findByRole('region', { name: 'Waitlist' });
    expect(row).toHaveTextContent('Link this Mac to your Darkbloom account first.');
    await act(async () =>
      fireEvent.click(within(row).getByRole('button', { name: 'Link account' })),
    );
    expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'link' });
  });

  it('says why the list is unavailable and reads again on Try again', async () => {
    const down = 'Could not reach the waitlists at https://api.darkbloom.dev: timed out';
    api.read
      .mockResolvedValueOnce({ data: [], error: down, code: 'unavailable' })
      .mockResolvedValueOnce(list(notJoined));
    render(<WaitlistCard feature="cluster" backend={waitlistBackend()} compact />);
    const row = await screen.findByRole('region', { name: 'Waitlist' });
    expect(row).toHaveTextContent(down);
    await act(async () => fireEvent.click(within(row).getByRole('button', { name: 'Try again' })));
    expect(screen.getByRole('region', { name: 'Clusters waitlist' })).toHaveTextContent(
      'You’re not on the Clusters waitlist.',
    );
  });

  it('asks for a newer CLI, and reads nothing, on a runtime without waitlists', () => {
    render(
      <WaitlistCard feature="cluster" backend={waitlistBackend({ capabilities: [] })} compact />,
    );
    expect(screen.getByText('Early access needs a newer Darkbloom CLI.')).toBeVisible();
    expect(api.read).not.toHaveBeenCalled();
  });
});
