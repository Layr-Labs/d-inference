// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

async function app(search: string) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  return (await import('../src/renderer/App')).default;
}
async function openEarlyAccess() {
  const nav = await screen.findByRole('navigation', { name: 'Main navigation' });
  fireEvent.click(within(nav).getByRole('button', { name: 'Early access' }));
  expect(await screen.findByRole('heading', { level: 1, name: 'Early access' })).toBeVisible();
}
afterEach(() => {
  cleanup();
  localStorage.clear();
});

it('opens Early access from the sidebar, then an approved feature from its card', async () => {
  const App = await app('?preview');
  render(<App />);
  await openEarlyAccess();
  const clusters = await screen.findByRole('article', { name: 'Clusters' });
  expect(screen.getByRole('article', { name: 'Darkbloom Sandbox' })).toHaveTextContent(
    '#3 in line',
  );
  fireEvent.click(within(clusters).getByRole('button', { name: 'Open' }));
  expect(await screen.findByRole('heading', { level: 1, name: 'Clusters' })).toBeVisible();
  const nav = screen.getByRole('navigation', { name: 'Main navigation' });
  expect(within(nav).getByRole('button', { name: 'Clusters' })).toHaveAttribute(
    'aria-current',
    'page',
  );
});

it('joins a waitlist and shows the new place in line', async () => {
  const App = await app('?preview&waitlist-sandbox=none');
  render(<App />);
  await openEarlyAccess();
  const sandbox = await screen.findByRole('article', { name: 'Darkbloom Sandbox' });
  expect(sandbox).toHaveTextContent('Not joined');
  fireEvent.click(within(sandbox).getByRole('button', { name: 'Join the waitlist' }));
  expect(await within(sandbox).findByText('#41', {}, { timeout: 4000 })).toBeVisible();
  expect(within(sandbox).queryByRole('button', { name: /Join/ })).not.toBeInTheDocument();
});

it('says the CLI is too old for waitlists=unsupported', async () => {
  const App = await app('?preview&waitlists=unsupported');
  render(<App />);
  await openEarlyAccess();
  expect(screen.getByText('Early access needs a newer Darkbloom CLI.')).toBeVisible();
});
