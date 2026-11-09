// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

// The Sandboxes page in the app, on the development preview's runtime.
async function openSandboxes(search: string) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  const App = (await import('../src/renderer/App')).default;
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  const nav = screen.getByRole('navigation', { name: 'Main navigation' });
  fireEvent.click(within(nav).getByRole('button', { name: 'Sandboxes' }));
  expect(await screen.findByRole('heading', { level: 1, name: 'Sandboxes' })).toBeVisible();
}

afterEach(cleanup);

it('shows the installed add-on from the sidebar', async () => {
  await openSandboxes('?preview&sandbox=ready');
  expect(await screen.findByRole('heading', { level: 2, name: 'Ready' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Open console' })).toBeVisible();
  expect(document.title).toBe('Sandboxes · Darkbloom');
});

it('offers setup once the waitlist approved the account', async () => {
  await openSandboxes('?preview&sandbox=not_installed&waitlist-sandbox=approved');
  expect(await screen.findByRole('button', { name: 'Set up' })).toBeEnabled();
});

it('explains an older runtime', async () => {
  await openSandboxes('?preview&sandbox=unsupported');
  expect(screen.getByText('Darkbloom Sandbox needs a newer Darkbloom CLI.')).toBeVisible();
});
