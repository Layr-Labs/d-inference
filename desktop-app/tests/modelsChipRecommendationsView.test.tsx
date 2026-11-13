// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Models } from '../src/renderer/features/models/Models';
import { StartServing } from '../src/renderer/components/onboarding/StartServing';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';
import { chipNetwork, uncoveredChipNetwork } from './chipNetworkFixture';

vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);

// Autopilot is not on yet, so the screen shows its recommendations.
const firstUse = () =>
  poolSnapshot({ enabled: false, configured: false, selected: [], pinned: [], phase: undefined });
const cardNames = (section: HTMLElement) =>
  within(section)
    .getAllByRole('article')
    .map((card) => within(card).getByText(/./, { selector: 'strong' }).textContent);

describe('recommended models on the Models screen', () => {
  it('recommends what Macs with this chip earn and says so', () => {
    const setup = firstUse();
    render(<Models backend={backendWith(setup, { network: chipNetwork() })} />);
    const section = screen.getByRole('region', { name: 'Recommended for your Mac' });
    expect(section).toHaveTextContent('Top earning on Apple M4 Max Macs · network · 24 hours');
    expect(cardNames(section)).toEqual(['Qwen 3.5 9B', 'GPT-OSS 20B', 'Gemma 4 26B']);
    expect(within(section).getAllByRole('article')[0]).toHaveTextContent(
      '$0.12 a day typical · $0.15 average',
    );
  });

  it('falls back to network totals and says so when this chip earned from no model here', () => {
    const setup = firstUse();
    render(<Models backend={backendWith(setup, { network: uncoveredChipNetwork() })} />);
    const section = screen.getByRole('region', { name: 'Recommended for your Mac' });
    expect(section).toHaveTextContent('Top earning compatible models · network · 7 days');
    expect(cardNames(section)).toEqual(['Qwen 3.6 35B A3B', 'Qwen 3.5 9B', 'GPT-OSS 20B']);
    expect(within(section).getAllByRole('article')[0]).toHaveTextContent('$4.00 network earnings');
  });
});

describe('recommended models in onboarding', () => {
  it('starts from what Macs with this chip earn and says so', () => {
    const setup = firstUse();
    render(
      <StartServing
        backend={backendWith(setup, { network: chipNetwork() })}
        snapshot={setup}
        link={vi.fn()}
        done={vi.fn()}
      />,
    );
    const section = screen.getByRole('region', { name: 'Recommended for your Mac' });
    expect(section).toHaveTextContent('Top earning on Apple M4 Max Macs · network · 24 hours');
    expect(cardNames(section)).toEqual(['Qwen 3.5 9B', 'GPT-OSS 20B', 'Gemma 4 26B']);
    expect(within(section).getAllByRole('article')[0]).toHaveTextContent(
      '$0.12 a day typical · $0.15 average',
    );
  });
});
