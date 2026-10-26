// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';
import { chipNetwork } from './chipNetworkFixture';

vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);

describe('recommended models on the Models screen', () => {
  it('recommends what Macs with this chip earn and says so', () => {
    const setup = poolSnapshot({
      enabled: false,
      configured: false,
      selected: [],
      pinned: [],
      phase: undefined,
    });
    render(<Models backend={backendWith(setup, { network: chipNetwork() })} />);
    const section = screen.getByRole('region', { name: 'Recommended for your Mac' });
    expect(section).toHaveTextContent('Top earning on Apple M4 Max Macs · network · 24 hours');
    const cards = within(section)
      .getAllByRole('article')
      .map((card) => within(card).getByText(/./, { selector: 'strong' }).textContent);
    expect(cards).toEqual(['Qwen 3.5 9B', 'GPT-OSS 20B', 'Gemma 4 26B']);
    expect(within(section).getAllByRole('article')[0]).toHaveTextContent(
      '$0.12 a day typical · $0.15 average',
    );
  });
});
