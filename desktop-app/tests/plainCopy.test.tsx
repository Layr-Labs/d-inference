// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Settings } from '../src/renderer/features/Settings';
import { backendWith, snapshot } from './onboardingFixtures';

afterEach(cleanup);

it('describes Settings without implementation terms', () => {
  const state = snapshot();
  const { container, rerender } = render(<Settings backend={backendWith(state)} />);
  expect(screen.getByText('Managed by the Darkbloom runtime.')).toBeVisible();
  // A revision change made outside the app (for example from the CLI).
  rerender(
    <Settings
      backend={backendWith({ ...state, settings: { ...state.settings, revision: 'changed' } })}
    />,
  );
  expect(screen.getByText(/changed elsewhere, for example from the command line/)).toBeVisible();
  expect(container).not.toHaveTextContent(/Swift|backend/);
});
