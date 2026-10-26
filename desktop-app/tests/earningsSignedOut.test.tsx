// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Earnings } from '../src/renderer/features/Earnings';
import { FleetEarnings } from '../src/renderer/features/home/FleetEarnings';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

afterEach(cleanup);

// Signing out (or a dashboard session expiring) keeps the Mac's provider link.
const signedOut = () => ({
  ...poolSnapshot(),
  linked: true,
  account: { signed_in: false, legacy_data: false },
});

it('asks a linked but signed-out Mac to sign in instead of loading forever', () => {
  render(<Earnings backend={backendWith(signedOut())} />);
  expect(screen.getByRole('heading', { name: 'Sign in to see earnings' })).toBeVisible();
  expect(screen.queryByText('Loading settled earnings…')).not.toBeInTheDocument();
  cleanup();
  render(<FleetEarnings backend={backendWith(signedOut())} onEarnings={vi.fn()} />);
  expect(screen.getByText('Sign in to see earnings')).toBeVisible();
  expect(screen.queryByText('Loading…')).not.toBeInTheDocument();
});

it('still shows loading while a signed-in account reads its earnings', () => {
  const state = { ...signedOut(), account: { signed_in: true } };
  render(<Earnings backend={backendWith(state)} />);
  expect(screen.getByRole('heading', { name: 'Earnings insights' })).toBeVisible();
  expect(screen.getByText('Loading settled earnings…')).toBeVisible();
});
