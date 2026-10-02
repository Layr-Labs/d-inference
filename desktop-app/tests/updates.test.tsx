// @vitest-environment jsdom
import React from 'react';
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { GUIUpdate } from '../src/shared/contracts';

let App: typeof import('../src/renderer/App').default;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  App = (await import('../src/renderer/App')).default;
  ({ previewAPI } = await import('../src/renderer/preview'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const unconfigured: GUIUpdate = {
  state: 'unconfigured',
  message: 'Desktop app updates are not configured for this build.',
};

async function openUpdates() {
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  fireEvent.click(screen.getByRole('button', { name: 'Updates' }));
  await screen.findByRole('heading', { name: 'Updates', level: 1 });
}

it('shows that desktop updates are not configured without claiming automatic checks', async () => {
  vi.spyOn(previewAPI, 'updateStatus').mockResolvedValue(unconfigured);
  const check = vi.spyOn(previewAPI, 'checkUpdate').mockResolvedValue(unconfigured);
  await openUpdates();
  expect(await screen.findByText(unconfigured.message!)).toBeVisible();
  expect(screen.queryByText(/checks for updates automatically/)).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Check for updates/ }));
  await waitFor(() => expect(check).toHaveBeenCalled());
  expect(screen.getByText(unconfigured.message!)).toBeVisible();
  expect(screen.queryByRole('button', { name: 'Restart desktop app' })).not.toBeInTheDocument();
});

it('offers a restart once a configured update is ready', async () => {
  vi.spyOn(previewAPI, 'updateStatus').mockResolvedValue({ state: 'ready', version: '0.2.0' });
  await openUpdates();
  expect(await screen.findByText('Version 0.2.0 is ready.')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Restart desktop app' })).toBeVisible();
});

it('does not claim automatic checks before the update status arrives', async () => {
  vi.spyOn(previewAPI, 'updateStatus').mockReturnValue(new Promise<GUIUpdate>(() => {}));
  await openUpdates();
  expect(screen.getByText('Checking desktop update status…')).toBeVisible();
  expect(screen.queryByText(/checks for updates automatically/)).not.toBeInTheDocument();
});
