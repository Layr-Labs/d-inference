// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Operation, Snapshot } from '../src/shared/contracts';
import type { Waitlists } from '../src/shared/waitlists';

async function preview(search: string) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  const api = (await import('../src/renderer/preview')).previewAPI;
  return {
    api,
    state: () => api.read<Snapshot>('state'),
    waitlists: () => api.read<Waitlists>('waitlists'),
  };
}
// The simulated join answers after a short pause, as a coordinator would.
async function join(api: Awaited<ReturnType<typeof preview>>['api'], feature: string) {
  vi.useFakeTimers();
  const operation = api.act({ action: 'waitlist_join', feature });
  await vi.advanceTimersByTimeAsync(700);
  return operation;
}

afterEach(() => vi.useRealTimers());

describe('preview waitlists', () => {
  it('offers the waitlists capability by default, keeping the ones the app assumed before', async () => {
    const capabilities = (await (await preview('?preview')).state()).capabilities;
    expect(capabilities).toEqual(['autopilot', 'waitlist', 'waitlists']);
  });

  it('drops the capability for waitlists=unsupported', async () => {
    const capabilities = (await (await preview('?preview&waitlists=unsupported')).state())
      .capabilities;
    expect(capabilities ?? []).not.toContain('waitlists');
  });

  it('lists Clusters approved and Darkbloom Sandbox third in line', async () => {
    const { data } = await (await preview('?preview')).waitlists();
    expect(data.map(({ feature, status, position }) => ({ feature, status, position }))).toEqual([
      { feature: 'cluster', status: 'approved', position: null },
      { feature: 'sandbox', status: 'waitlisted', position: 3 },
    ]);
  });

  it('sets where the account stands, and adds a waitlist with no page for waitlists=more', async () => {
    const { data } = await (
      await preview('?preview&waitlists=more&waitlist-cluster=revoked&waitlist-sandbox=none')
    ).waitlists();
    expect(data.map(({ feature, status }) => `${feature}:${status}`)).toEqual([
      'cluster:revoked',
      'sandbox:none',
      'labs:approved',
    ]);
    expect(data[2].start_command).toBe('darkbloom labs');
  });

  it.each([
    ['login', 'Link this Mac to your Darkbloom account first: darkbloom login'],
    ['none', 'https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there.'],
    ['fail', 'Could not reach the waitlists at https://api.darkbloom.dev: The request timed out.'],
  ])('answers waitlists=%s with its reason', async (flag, error) => {
    const answer = await (await preview(`?preview&waitlists=${flag}`)).waitlists();
    expect(answer).toEqual({
      data: [],
      error,
      code: flag === 'fail' ? 'unavailable' : flag,
    });
  });

  it('joins a waitlist and records the operation with the CLI’s line', async () => {
    const { api, state, waitlists } = await preview('?preview&waitlist-sandbox=none');
    const operation: Operation = await join(api, 'sandbox');
    expect(operation).toMatchObject({ action: 'waitlist_join', state: 'succeeded' });
    expect(operation.message).toMatch(
      /^You’re on the Darkbloom Sandbox waitlist: #41 in line \(joined .+\)\.$/,
    );
    expect((await waitlists()).data[1]).toMatchObject({ status: 'waitlisted', position: 41 });
    expect((await state()).operations[0].id).toBe(operation.id);
  });

  it('refuses every join for waitlist-join=fail', async () => {
    const { api, waitlists } = await preview('?preview&waitlist-cluster=none&waitlist-join=fail');
    const operation = await join(api, 'cluster');
    expect(operation).toMatchObject({
      state: 'failed',
      message:
        'Could not reach the Clusters waitlist at https://api.darkbloom.dev: The request timed out.',
    });
    expect((await waitlists()).data[0].status).toBe('none');
  });
});
