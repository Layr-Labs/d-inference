// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { CoolingData } from '../src/shared/contracts';
import { Cooling } from '../src/renderer/features/Cooling';
import { CoolingControls } from '../src/renderer/features/cooling/CoolingControls';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

afterEach(cleanup);

const cooling = (overrides: Partial<CoolingData> = {}): CoolingData => ({
  supported: true,
  enabled: true,
  mode: 'automatic',
  observed_at: Date.now() / 1000,
  temperature: 71,
  fans: [{ name: 'Left fan', rpm: 2400, max_rpm: 6000 }],
  speed: 75,
  threshold: 50,
  ...overrides,
});

it('does not present a reading older than a minute as current', () => {
  render(
    <Cooling
      backend={backendWith(poolSnapshot(), {
        cooling: cooling({ observed_at: Date.now() / 1000 - 300 }),
      })}
    />,
  );
  expect(screen.getByText('Fan status unavailable')).toBeVisible();
  expect(screen.queryByText('71°')).not.toBeInTheDocument();
  expect(screen.queryByRole('list', { name: 'Fans' })).not.toBeInTheDocument();
  cleanup();
  render(<Cooling backend={backendWith(poolSnapshot(), { cooling: cooling() })} />);
  expect(screen.getByText('71°')).toBeVisible();
  expect(screen.getByRole('list', { name: 'Fans' })).toBeVisible();
});

it('shows and submits the configured threshold even between presets', () => {
  const backend = backendWith(poolSnapshot(), { cooling: cooling({ threshold: 52, speed: 72.6 }) });
  render(<CoolingControls backend={backend} />);
  const select = screen.getByRole('combobox', { name: 'Engage above' }) as HTMLSelectElement;
  expect(select.selectedOptions[0]).toHaveTextContent('52°C');
  fireEvent.click(screen.getByRole('button', { name: 'Enable provider cooling' }));
  expect(backend.act).toHaveBeenCalledWith({
    action: 'cooling',
    enabled: true,
    speed: 73,
    temperature: 52,
  });
});

it('keeps CLI-set values within what the native cooling action accepts', () => {
  const backend = backendWith(poolSnapshot(), { cooling: cooling({ threshold: 30.5, speed: 95 }) });
  render(<CoolingControls backend={backend} />);
  expect(
    (screen.getByRole('combobox', { name: 'Engage above' }) as HTMLSelectElement)
      .selectedOptions[0],
  ).toHaveTextContent('40°C');
  fireEvent.click(screen.getByRole('button', { name: 'Enable provider cooling' }));
  expect(backend.act).toHaveBeenCalledWith(expect.objectContaining({ speed: 90, temperature: 40 }));
});
