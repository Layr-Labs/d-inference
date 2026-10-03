// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { FanGlyph, fanTurnSeconds } from '../src/renderer/components/FanGlyph';
import { Cooling } from '../src/renderer/features/Cooling';
import { previewBackend } from './previewBackend';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const reduceMotion = () =>
  vi.stubGlobal(
    'matchMedia',
    (query: string) =>
      ({
        matches: query === '(prefers-reduced-motion: reduce)',
        addEventListener: () => {},
        removeEventListener: () => {},
      }) as unknown as MediaQueryList,
  );

it('turns faster as RPM approaches the fan’s maximum', () => {
  expect(fanTurnSeconds(0, 5000)).toBeNull();
  expect(fanTurnSeconds(-10, 5000)).toBeNull();
  expect(fanTurnSeconds(1, 5000)).toBeCloseTo(2.4, 1);
  expect(fanTurnSeconds(2500, 5000)).toBe(1.42);
  expect(fanTurnSeconds(5000, 5000)).toBe(0.45);
  expect(fanTurnSeconds(7000, 5000)).toBe(0.45);
  expect(fanTurnSeconds(2000, 0)).toBe(1.42);
});

it('spins only while the fan reports RPM, at a speed set by that RPM', () => {
  const { rerender } = render(<FanGlyph name="Left fan" rpm={2600} maxRpm={5200} />);
  const glyph = screen.getByRole('img', { name: 'Left fan spinning at 2,600 RPM' });
  expect(glyph).toHaveAttribute('data-animate', 'true');
  expect(glyph.style.getPropertyValue('--fan-turn')).toBe('1.42s');
  rerender(<FanGlyph name="Left fan" rpm={5200} maxRpm={5200} />);
  expect(glyph.style.getPropertyValue('--fan-turn')).toBe('0.45s');
  rerender(<FanGlyph name="Left fan" rpm={0} maxRpm={5200} />);
  expect(screen.getByRole('img', { name: 'Left fan stopped' })).toHaveAttribute(
    'data-animate',
    'false',
  );
  rerender(<FanGlyph name="Left fan" />);
  const unknown = screen.getByRole('img', { name: 'Left fan speed not reported' });
  expect(unknown).toHaveAttribute('data-spinning', 'false');
  expect(unknown.style.getPropertyValue('--fan-turn')).toBe('');
});

it('keeps a spinning fan still under reduced motion while still reporting that it spins', async () => {
  reduceMotion();
  render(<Cooling backend={await previewBackend()} />);
  const left = screen.getByRole('img', { name: 'Left fan spinning at 2,480 RPM' });
  expect(left).toHaveAttribute('data-spinning', 'true');
  expect(left).toHaveAttribute('data-animate', 'false');
  expect(left.style.getPropertyValue('--fan-turn')).toBe('');
  expect(left.closest('li')).toHaveTextContent('Spinning');
});

it('shows each fan beside the GPU temperature and keeps fanless or unreadable Macs still', async () => {
  const backend = await previewBackend();
  const { rerender } = render(<Cooling backend={backend} />);
  const fans = screen.getByRole('list', { name: 'Fans' });
  expect(fans.parentElement).toHaveTextContent('GPU temperature52°');
  for (const name of ['Left fan spinning at 2,480 RPM', 'Right fan spinning at 2,510 RPM']) {
    const glyph = within(fans).getByRole('img', { name });
    expect(glyph).toHaveAttribute('data-animate', 'true');
    expect(within(glyph.closest('li')!).getByText('Spinning')).toBeVisible();
  }
  expect(within(fans).getAllByRole('listitem')[0]).toHaveTextContent('2,480 RPM');
  expect(screen.getAllByRole('img')).toHaveLength(2);
  rerender(
    <Cooling
      backend={{
        ...backend,
        cooling: { ...backend.cooling!, fans: [{ name: 'Fan', rpm: 0, max_rpm: 5000 }] },
      }}
    />,
  );
  expect(screen.getByRole('img', { name: 'Fan stopped' })).toHaveAttribute('data-animate', 'false');
  expect(screen.getByText('Stopped')).toBeVisible();
  for (const cooling of [
    { supported: false, mode: 'automatic' as const, fans: [] },
    { supported: false, mode: 'unavailable' as const, fans: [], error: 'Unavailable' },
    undefined,
  ]) {
    rerender(<Cooling backend={{ ...backend, cooling }} />);
    expect(screen.queryByRole('list', { name: 'Fans' })).not.toBeInTheDocument();
    expect(screen.queryByRole('img', { name: /spinning/ })).not.toBeInTheDocument();
    expect(screen.getByText('GPU temperature')).toBeVisible();
    expect(screen.getByRole('heading', { name: 'Automatic cooling' })).toBeVisible();
  }
});
