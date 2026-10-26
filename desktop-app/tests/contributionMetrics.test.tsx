// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { ContributionMetrics } from '../src/renderer/features/home/ContributionMetrics';
import { contribution } from '../src/renderer/features/home/contribution';

afterEach(cleanup);
it('counts input plus output once and displays cached and reasoning subsets', () => {
  const activity = {
    samples: [],
    tokens: '30',
    prompt_tokens: '120',
    cached_input_tokens: '80',
    reasoning_tokens: '20',
  };
  expect(contribution(activity)).toMatchObject({
    tokens: '150',
    input: '120',
    output: '30',
    cached: '80',
    reasoning: '20',
    label: 'Tokens processed this session',
  });
  render(<ContributionMetrics activity={activity} explore={vi.fn()} />);
  expect(screen.getByText('150')).toBeVisible();
  expect(screen.getByLabelText('Token breakdown')).toHaveTextContent(
    'Input 120Cached 80Output 30Reasoning 20',
  );
});
it('keeps the requested label and unknown totals blank instead of showing output as the total', () => {
  render(
    <ContributionMetrics
      activity={{ samples: [], tokens: '5641', requests: '12' }}
      explore={vi.fn()}
    />,
  );
  expect(screen.getByText('Tokens processed this session')).toBeVisible();
  expect(screen.getByTitle('Waiting for complete input and output usage')).toHaveTextContent('—');
  expect(screen.queryByText(/≥/)).not.toBeInTheDocument();
  expect(screen.getByTitle('Session earnings unavailable')).toHaveTextContent('—');
});
it('uses verified history without combining it with newer output-only totals', () => {
  expect(
    contribution({
      samples: [],
      tokens: '45',
      requests: '3',
      processed_tokens: '150',
      processed_input_tokens: '120',
      processed_output_tokens: '30',
      pending_usage_requests: '1',
      usage_source: 'settled-history',
      earnings_micro_usd: '1000',
    }),
  ).toMatchObject({ tokens: '150', pending: '1', earnings: '$0.0010' });
});
it('distinguishes complete zero, incomplete usage and invalid counters with exact large integers', () => {
  expect(
    contribution({ samples: [], tokens: '0', prompt_tokens: '0', earnings_micro_usd: '0' }),
  ).toMatchObject({ tokens: '0', earnings: '$0.0000' });
  expect(
    contribution({ samples: [], tokens: '30', prompt_tokens: '120', usage_gaps: '1' }).tokens,
  ).toBe('—');
  expect(contribution({ samples: [], tokens: 'invalid', prompt_tokens: '120' }).tokens).toBe('—');
  expect(
    contribution({ samples: [], tokens: '30', prompt_tokens: '9007199254740993' }).tokens,
  ).toBe('9,007,199,254,741,023');
});
