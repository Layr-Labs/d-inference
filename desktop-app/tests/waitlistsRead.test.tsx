// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, render, renderHook, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { BackendState } from '../src/renderer/useBackend';
import { useWaitlist } from '../src/renderer/features/waitlists/useWaitlist';
import { WaitlistCard } from '../src/renderer/features/waitlists/WaitlistCard';
import { Waitlists } from '../src/renderer/features/waitlists/Waitlists';
import { resetWaitlists } from '../src/renderer/features/waitlists/waitlistStore';
import { cluster, deferred, list, sandbox, waitlistBackend } from './waitlistsFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), act: vi.fn(), copy: vi.fn() }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api }));
afterEach(() => {
  cleanup();
  resetWaitlists();
  vi.resetAllMocks();
});

const waitlistReads = () => api.read.mock.calls.filter(([resource]) => resource === 'waitlists');

// A feature's page: its own hook and the compact card above it, as Clusters and Sandboxes use them.
function FeaturePage({ backend, feature }: { backend: BackendState; feature: string }) {
  const waitlist = useWaitlist(backend, feature);
  return (
    <>
      <p>standing: {waitlist.standing}</p>
      <WaitlistCard feature={feature} backend={backend} compact />
    </>
  );
}

describe('one read for the page', () => {
  it('keeps the hook’s fields stable', async () => {
    api.read.mockResolvedValue(list(cluster));
    const { result } = renderHook(() => useWaitlist(waitlistBackend(), 'cluster'));
    await waitFor(() => expect(result.current.standing).toBe('approved'));
    expect(Object.keys(result.current)).toEqual(
      expect.arrayContaining(['entry', 'standing', 'open', 'error', 'joining', 'join', 'refresh']),
    );
    expect(result.current).toMatchObject({ entry: cluster, open: true, joining: false });
    expect(result.current.join).toBeTypeOf('function');
    expect(result.current.refresh).toBeTypeOf('function');
  });

  it('reads once for a page, its hook and its cards, including cards that mount later', async () => {
    api.read.mockResolvedValue(list(cluster, sandbox));
    const backend = waitlistBackend();
    render(
      <>
        <FeaturePage backend={backend} feature="sandbox" />
        <Waitlists backend={backend} navigate={vi.fn()} />
      </>,
    );
    expect(await screen.findByRole('article', { name: 'Darkbloom Sandbox' })).toBeVisible();
    expect(screen.getByRole('article', { name: 'Clusters' })).toBeVisible();
    expect(screen.getByText('standing: waitlisted')).toBeVisible();
    expect(screen.getByRole('region', { name: 'Darkbloom Sandbox waitlist' })).toBeVisible();
    expect(waitlistReads()).toHaveLength(1);
  });

  it('reads again on a new page, a new resource clock, a visible window and refresh', async () => {
    api.read.mockResolvedValue(list(cluster));
    const backend = waitlistBackend();
    const view = render(<FeaturePage backend={backend} feature="cluster" />);
    await screen.findByText('standing: approved');
    expect(waitlistReads()).toHaveLength(1);

    // Another page with the same clock reads afresh, and shows the last answer meanwhile.
    view.unmount();
    render(<FeaturePage backend={backend} feature="cluster" />);
    expect(screen.getByText('standing: approved')).toBeVisible();
    await waitFor(() => expect(waitlistReads()).toHaveLength(2));

    cleanup();
    const page = render(<FeaturePage backend={backend} feature="cluster" />);
    await waitFor(() => expect(waitlistReads()).toHaveLength(3));
    page.rerender(
      <FeaturePage backend={waitlistBackend({ resource_revision: '1001' })} feature="cluster" />,
    );
    await waitFor(() => expect(waitlistReads()).toHaveLength(4));

    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'));
    });
    expect(waitlistReads()).toHaveLength(5);

    const { result } = renderHook(() =>
      useWaitlist(waitlistBackend({ resource_revision: '1001' }), 'cluster'),
    );
    await act(() => result.current.refresh());
    expect(waitlistReads()).toHaveLength(6);
  });

  it('never shows another account’s waitlists', async () => {
    const next = deferred<unknown>();
    api.read.mockResolvedValueOnce(list(cluster)).mockReturnValueOnce(next.promise);
    const view = render(<FeaturePage backend={waitlistBackend()} feature="cluster" />);
    await screen.findByText('standing: approved');
    view.rerender(
      <FeaturePage
        backend={waitlistBackend({ account_revision: 'account-2' })}
        feature="cluster"
      />,
    );
    expect(screen.getByText('standing: loading')).toBeVisible();
    await act(async () => next.resolve(list({ ...cluster, status: 'none', decided_at: null })));
    expect(screen.getByText('standing: none')).toBeVisible();
  });

  it('keeps the last answer when a later read fails, and says why', async () => {
    api.read
      .mockResolvedValueOnce(list(cluster))
      .mockRejectedValueOnce(
        new Error("Error invoking remote method 'backend:read': Error: Runtime is not connected"),
      );
    const { result } = renderHook(() => useWaitlist(waitlistBackend(), 'cluster'));
    await waitFor(() => expect(result.current.standing).toBe('approved'));
    await act(() => result.current.refresh());
    expect(result.current).toMatchObject({
      standing: 'approved',
      open: true,
      error: 'Runtime is not connected',
    });
  });
});

describe('where the account stands', () => {
  // Each answer is read afresh: nothing from an earlier answer is shared.
  const standing = async (answer: () => Promise<unknown>, feature = 'cluster') => {
    cleanup();
    resetWaitlists();
    api.read.mockImplementation(answer);
    const { result } = renderHook(() => useWaitlist(waitlistBackend(), feature));
    await waitFor(() => expect(result.current.standing).not.toBe('loading'));
    return result.current;
  };

  it('is open once approved, and on a coordinator without that waitlist', async () => {
    expect(await standing(async () => list(cluster))).toMatchObject({
      standing: 'approved',
      open: true,
    });
    expect(await standing(async () => list(sandbox), 'cluster')).toMatchObject({
      standing: 'no_waitlist',
      open: true,
    });
    expect(
      await standing(async () => ({
        data: [],
        error: 'https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there.',
        code: 'none',
      })),
    ).toMatchObject({ standing: 'no_waitlist', open: true });
  });

  it.each([
    ['none', { ...cluster, status: 'none' as const }],
    ['waitlisted', { ...cluster, status: 'waitlisted' as const, position: 4 }],
    ['revoked', { ...cluster, status: 'revoked' as const }],
  ])('is closed while %s', async (status, entry) => {
    expect(await standing(async () => list(entry))).toMatchObject({
      standing: status,
      open: false,
    });
  });

  it('says to link this Mac, or why the list is unavailable, in the runtime’s words', async () => {
    const login = 'Link this Mac to your Darkbloom account first: darkbloom login';
    expect(await standing(async () => ({ data: [], error: login, code: 'login' }))).toMatchObject({
      standing: 'login',
      open: false,
      error: login,
    });
    const down = 'Could not reach the waitlists at https://api.darkbloom.dev: timed out';
    expect(
      await standing(async () => ({ data: [], error: down, code: 'unavailable' })),
    ).toMatchObject({ standing: 'unavailable', open: false, error: down });
    expect(
      await standing(async () => {
        throw new Error('Unknown resource');
      }),
    ).toMatchObject({ standing: 'unavailable', open: false, error: 'Unknown resource' });
    expect(await standing(async () => ({ nonsense: true }))).toMatchObject({
      standing: 'unavailable',
      error: 'Waitlists are unavailable.',
    });
  });

  it('drops entries it can’t read', async () => {
    const answer = {
      data: [
        { feature: 'cluster', title: '', status: 'approved' },
        { feature: 'cluster', title: 'Clusters', status: 'paused' },
        null,
        sandbox,
      ],
    };
    const result = await standing(async () => answer, 'sandbox');
    expect(result).toMatchObject({ standing: 'waitlisted', entry: sandbox });
    expect((await standing(async () => answer)).standing).toBe('no_waitlist');
  });

  it('reads nothing on a runtime without waitlists', async () => {
    const { result } = renderHook(() =>
      useWaitlist(waitlistBackend({ capabilities: ['autopilot'] }), 'cluster'),
    );
    expect(result.current).toMatchObject({ standing: 'unsupported', open: false });
    await act(() => result.current.refresh());
    expect(api.read).not.toHaveBeenCalled();
  });
});
