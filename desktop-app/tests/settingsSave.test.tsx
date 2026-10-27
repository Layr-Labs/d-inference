// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Settings } from '../src/renderer/features/Settings';
import { scheduleProblem } from '../src/renderer/components/ScheduleEditor';
import { backendWith, snapshot } from './onboardingFixtures';

afterEach(cleanup);
const save = () => screen.getByRole('button', { name: /Save changes/ });

it('offers Save only after a change', () => {
  render(<Settings backend={backendWith(snapshot())} />);
  expect(save()).toBeDisabled();
  fireEvent.change(screen.getByRole('textbox', { name: 'Mac name' }), {
    target: { value: 'Studio upstairs' },
  });
  expect(save()).toBeEnabled();
});

it('explains and blocks a weekly schedule the runtime would reject', () => {
  render(<Settings backend={backendWith(snapshot())} />);
  fireEvent.click(screen.getByRole('switch', { name: /Use a weekly schedule/ }));
  expect(save()).toBeEnabled();
  for (const day of ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) fireEvent.click(screen.getByText(day));
  expect(screen.getByRole('alert')).toHaveTextContent('Choose at least one day for window 1.');
  expect(save()).toBeDisabled();
  fireEvent.click(screen.getByRole('button', { name: 'Remove window 1' }));
  expect(screen.getByRole('alert')).toHaveTextContent(
    'Add a time window, or turn off the weekly schedule.',
  );
  expect(save()).toBeDisabled();
});

it('mirrors the runtime schedule rules', () => {
  const window = { days: ['mon'], start: '18:00', end: '09:00' };
  expect(scheduleProblem({ enabled: false, windows: [] })).toBeUndefined();
  expect(scheduleProblem({ enabled: true, windows: [window] })).toBeUndefined();
  expect(scheduleProblem({ enabled: true, windows: [{ ...window, end: '' }] })).toBe(
    'Enter a start and end time for window 1.',
  );
  expect(
    scheduleProblem({ enabled: true, windows: [{ ...window, start: '24:00' }] }),
  ).toBeDefined();
});
