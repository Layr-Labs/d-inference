// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { FanStatus } from '../src/renderer/features/home/chip/FanStatus';
import type { CoolingData } from '../src/shared/contracts';

afterEach(cleanup);
const status: CoolingData = {
  supported: true,
  enabled: false,
  mode: 'automatic',
  temperature: 60,
  fans: [],
};

it('keeps enabled cooling blue at any temperature, including below its trigger', () => {
  const open = vi.fn();
  const { rerender } = render(
    <FanStatus cooling={{ ...status, enabled: true, temperature: 90 }} onOpen={open} />,
  );
  const button = screen.getByRole('button', { name: /Auto fan on/ });
  expect(button).toHaveAttribute('data-enabled', 'true');
  expect(button.style.color).toBe('');
  fireEvent.click(button);
  expect(open).toHaveBeenCalledOnce();
  rerender(<FanStatus cooling={{ ...status, enabled: true, temperature: 45 }} onOpen={open} />);
  expect(button).toHaveTextContent('45°C');
  expect(button.style.color).toBe('');
});

it('progressively reddens above 60 when the fan option is off and withholds stale readings', () => {
  const { rerender } = render(<FanStatus cooling={status} onOpen={() => {}} />);
  const button = screen.getByRole('button', { name: /Auto fan off/ });
  // The hue is set inline; each theme chooses a readable lightness in CSS.
  const hue = () => button.style.getPropertyValue('--heat-hue');
  expect(hue()).toBe('');
  expect(button).not.toHaveAttribute('data-heat');
  rerender(<FanStatus cooling={{ ...status, temperature: 70 }} onOpen={() => {}} />);
  const warm = hue();
  expect(warm).not.toBe('');
  expect(button).toHaveAttribute('data-heat', 'true');
  rerender(<FanStatus cooling={{ ...status, temperature: 90 }} onOpen={() => {}} />);
  expect(Number(hue())).toBeLessThan(Number(warm));
  rerender(<FanStatus cooling={{ ...status, enabled: true, observed_at: 1 }} onOpen={() => {}} />);
  expect(button).toHaveTextContent('Fan status unavailable');
  expect(button).not.toHaveTextContent('°C');
  expect(button).toHaveAttribute('data-enabled', 'false');
});
