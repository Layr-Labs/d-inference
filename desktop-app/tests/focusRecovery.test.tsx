// @vitest-environment jsdom
import React from 'react';
import { afterEach, beforeAll, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { backendWith, snapshot } from './onboardingFixtures';

// useBackend reads ?preview when it first loads, so the app is imported after setting it.
let App: typeof import('../src/renderer/App').default;
let Onboarding: typeof import('../src/renderer/components/Onboarding').Onboarding;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  App = (await import('../src/renderer/App')).default;
  ({ Onboarding } = await import('../src/renderer/components/Onboarding'));
});
afterEach(cleanup);

it('moves focus to the new page heading when the focused control disappears', async () => {
  render(<App />);
  const fleet = await screen.findByRole('region', { name: 'Fleet earnings' });
  const earnings = within(fleet).getByRole('button', { name: /View earnings/ });
  earnings.focus();
  fireEvent.click(earnings);
  const heading = await screen.findByRole('heading', { name: 'Earnings', level: 1 });
  await waitFor(() => expect(document.activeElement).toBe(heading));
  expect(document.title).toBe('Earnings · Darkbloom');
});

it('keeps focus that survived navigation, such as a sidebar button', async () => {
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  const updates = within(screen.getByRole('navigation', { name: 'Main navigation' })).getByRole(
    'button',
    { name: 'Updates' },
  );
  updates.focus();
  fireEvent.click(updates);
  await screen.findByRole('heading', { name: 'Updates', level: 1 });
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(document.activeElement).toBe(updates);
});

it('moves focus to the next onboarding step’s heading', async () => {
  render(<Onboarding backend={backendWith(snapshot())} done={() => {}} />);
  const start = screen.getByRole('button', { name: /^Start/ });
  start.focus();
  fireEvent.click(start);
  await waitFor(() => expect(document.activeElement?.tagName).toBe('H2'));
});
