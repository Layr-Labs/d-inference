// @vitest-environment jsdom
import { StrictMode } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { AccountControl } from '../src/renderer/components/AccountControl';
import { Models } from '../src/renderer/features/models/Models';
import type { BackendState } from '../src/renderer/useBackend';
import { backendWith, operation } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

vi.mock('../src/renderer/useBackend', () => ({ api: undefined }));
afterEach(cleanup);

const pending = { ...operation('running', '', 'account-signin'), cancellable: true };
const link = {
  code: 'ABCD-EFGH',
  url: 'https://example.com/link',
  expires_at: 1_790_001_000,
  state: 'waiting',
};
const page = (backend: BackendState) => (
  <>
    <AccountControl backend={backend} />
    <Models backend={backend} />
  </>
);

it.each([true, false])(
  'keeps the account portal active with an overlapping link dialog (link present initially: %s)',
  async (linkedInitially) => {
    const state = poolSnapshot(
      {},
      {
        capabilities: ['account-signin', 'autopilot'],
        operations: [pending],
        link: linkedInitially ? link : undefined,
      },
    );
    const backend = backendWith(state);
    const view = render(page(backendWith({ ...state, link: undefined })), {
      wrapper: StrictMode,
    });
    const trigger = screen.getByRole('button', { name: 'Continue sign-in' });
    trigger.focus();
    if (linkedInitially) view.rerender(page(backend));
    trigger.focus();
    fireEvent.click(trigger);
    const account = screen.getByRole('dialog', { name: 'Sign in to Darkbloom' });
    const close = within(account).getByRole('button', { name: 'Close dialog' });
    expect(close).toHaveFocus();

    // A later link snapshot mounts the inline dialog after the portal's effect, but below it.
    await act(async () => view.rerender(page({ ...backend, state: { ...state, link } })));
    expect(close).toHaveFocus();
    const lower = screen.getByRole('dialog', { name: 'Link this Mac' });
    const copy = within(account).getByRole('button', { name: 'Copy code' });
    copy.focus();
    const tab = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    act(() => copy.dispatchEvent(tab));
    expect(tab.defaultPrevented).toBe(false);
    expect(copy).toHaveFocus();

    // Refreshing both codes must not re-run focus setup or disturb the active control.
    await act(async () =>
      view.rerender(
        page({
          ...backend,
          state: { ...state, link: { ...link, code: 'IJKL-MNOP' } },
        }),
      ),
    );
    expect(copy).toHaveFocus();
    const cancel = within(account).getByRole('button', { name: 'Cancel' });
    cancel.focus();
    fireEvent.keyDown(cancel, { key: 'Tab' });
    expect(close).toHaveFocus();
    fireEvent.keyDown(close, { key: 'Tab', shiftKey: true });
    expect(cancel).toHaveFocus();

    fireEvent.keyDown(cancel, { key: 'Escape' });
    expect(account).not.toBeInTheDocument();
    expect(lower).toContainElement(document.activeElement as HTMLElement);
    expect(backend.act).not.toHaveBeenCalled();

    // The original trigger is still restored if the lower dialog outlives the portal.
    view.rerender(page(backendWith({ ...state, link: undefined })));
    expect(trigger).toHaveFocus();
  },
);
