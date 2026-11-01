// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import stats from './fixtures/public-stats.json';
import { NetworkMap } from '../src/renderer/features/leaderboard/NetworkMap';
import { cellLevel, cellsFrom, regionsFrom } from '../src/renderer/features/leaderboard/geography';
import { networkFromStats } from '../src/renderer/previewNetwork';

afterEach(cleanup);

it('places production regions on their grid cells and aggregates regions sharing one', () => {
  const cells = cellsFrom(regionsFrom(stats.provider_regions));
  expect(cells.map(({ key, providers, level, label }) => [key, providers, level, label])).toEqual([
    ['14:13', 114, 4, 'California, United States'],
    ['79:13', 55, 4, 'Tokyo, Japan and 5 nearby'],
    ['26:12', 46, 4, 'New York, United States and 1 nearby'],
    ['44:8', 37, 3, 'England, United Kingdom'],
    ['75:16', 25, 3, 'Taipei City, Taiwan and 1 nearby'],
    ['5:17', 3, 2, 'Hawaii, United States'],
    ['44:7', 2, 1, 'Scotland, United Kingdom'],
    ['55:11', 1, 1, 'Georgia'],
  ]);
  expect(regionsFrom([{ region: 'Nowhere', latitude: 1, longitude: 1, providers: 2 }])).toEqual([]);
});

it('shades cells by Mac count rather than presence', () => {
  expect([1, 2, 3, 9, 10, 39, 40, 500].map(cellLevel)).toEqual([1, 1, 2, 2, 3, 3, 4, 4]);
});

it('shows real totals and keeps a chosen region while the pointer explores others', () => {
  const { container } = render(<NetworkMap network={networkFromStats(stats)} />);
  const lit = [...container.querySelectorAll('rect[data-level]')];
  expect(lit.map((cell) => cell.getAttribute('data-level'))).toEqual([
    '4',
    '4',
    '4',
    '3',
    '3',
    '2',
    '1',
    '1',
  ]);
  expect(lit[0]).toHaveTextContent('California, United States: 114 Macs');
  expect(screen.getByText('Macs connected').nextSibling).toHaveTextContent('1,137');
  expect(screen.getByText('Tokens processed').nextSibling).toHaveTextContent('659.1B');
  const ring = () => container.querySelector('svg > rect');
  expect(ring()).toBeNull();

  const tokyo = screen.getByRole('option', { name: 'Tokyo, Japan and 5 nearby: 55 Macs' });
  fireEvent.change(screen.getByRole('combobox', { name: 'Explore provider regions' }), {
    target: { value: (tokyo as HTMLOptionElement).value },
  });
  expect(screen.getByText('55 Macs · Tokyo, Japan and 5 nearby')).toBeVisible();
  expect(ring()).toHaveAttribute('x', String(79 * 12 + 1));

  fireEvent.pointerEnter(lit[0]);
  expect(screen.getByText('114 Macs · California, United States')).toBeVisible();
  expect(ring()).toHaveAttribute('x', String(14 * 12 + 1));
  expect(tokyo).toHaveProperty('selected', true);

  fireEvent.pointerLeave(container.querySelector('svg')!);
  expect(screen.getByText('55 Macs · Tokyo, Japan and 5 nearby')).toBeVisible();
});
