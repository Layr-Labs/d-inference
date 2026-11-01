// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { LinkPanel } from '../src/renderer/components/onboarding/LinkPanel';

const api = vi.hoisted(() => ({ copy: vi.fn(), openExternal: vi.fn() }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const link = {
  url: 'https://console.darkbloom.dev/link',
  code: 'BLOOM-7Q4K',
  expires_at: 0,
  state: 'waiting',
};

it('copies the link code next to it and confirms it', async () => {
  api.copy.mockResolvedValue(undefined);
  render(<LinkPanel link={link} cancel={vi.fn()} />);
  expect(screen.getByLabelText('Link code BLOOM-7Q4K')).toBeVisible();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy code' })));
  expect(api.copy).toHaveBeenCalledWith('BLOOM-7Q4K');
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
  // Copying never opens the browser; only Open link page does.
  expect(api.openExternal).not.toHaveBeenCalled();
});

it('keeps offering Copy code when copying fails', async () => {
  api.copy.mockRejectedValue(new Error('denied'));
  render(<LinkPanel link={link} cancel={vi.fn()} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy code' })));
  expect(screen.getByRole('button', { name: 'Copy code' })).toBeVisible();
});
