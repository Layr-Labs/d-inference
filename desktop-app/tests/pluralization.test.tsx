// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { compact, plural } from '../src/renderer/format';
import { FleetMacs } from '../src/renderer/features/home/FleetMacs';
import { LiveModels } from '../src/renderer/features/insights/LiveModels';
import { ExpandableModelList } from '../src/renderer/features/models/ExpandableModelList';
import { describeTokenBar, tokenBars } from '../src/renderer/features/stats/tokenSeries';
import type { Machine, Snapshot } from '../src/shared/contracts';

afterEach(cleanup);

it('agrees nouns with their counts', () => {
  expect(plural(1, 'Mac')).toBe('1 Mac');
  expect(plural(2, 'Mac')).toBe('2 Macs');
  expect(plural(0, 'download')).toBe('0 downloads');
  expect(plural(1200, 'request', 'requests', compact)).toBe('1.2K requests');
  expect(plural(12_345, 'token')).toBe('12,345 tokens');
});

it('says “1 Mac” for a single Mac', () => {
  const mac = {
    id: 'this-mac',
    name: 'MacBook Pro',
    chip: 'Apple M4 Max',
    memory_gb: 64,
    status: 'running',
    models: [],
  } as unknown as Machine;
  render(<FleetMacs machines={[mac]} localID="this-mac" onOpen={() => {}} />);
  expect(screen.getByText('1 Mac')).toBeVisible();
  expect(screen.queryByText('1 Macs')).not.toBeInTheDocument();
});

it('offers “Show 1 more model” when one model is hidden', () => {
  render(
    <ExpandableModelList items={[1, 2, 3, 4]}>{(n) => <p key={n}>{n}</p>}</ExpandableModelList>,
  );
  expect(screen.getByRole('button', { name: 'Show 1 more model' })).toBeVisible();
});

it('describes a single-token bar in the singular', () => {
  const [bar] = tokenBars([{ at: 0, requests: 1, tokens: 1, input: 0, cached: 0 }]);
  expect(describeTokenBar(bar)).toContain('Total 1 token');
  expect(describeTokenBar(bar)).not.toContain('1 tokens');
});

it('says “1 request processing” for a single live request', () => {
  const now = Date.now() / 1000;
  const state = {
    state: 'running',
    observed_at: now,
    models: [],
    activity: {
      sampled_at: now,
      models: [{ model: 'test', state: 'running', running: 1, waiting: 0 }],
    },
  } as unknown as Snapshot;
  const { container } = render(<LiveModels state={state} />);
  expect(container).toHaveTextContent('1request processing');
  expect(container).not.toHaveTextContent('requests processing');
});
