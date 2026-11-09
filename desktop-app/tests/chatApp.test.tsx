// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

let App: typeof import('../src/renderer/App').default;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  App = (await import('../src/renderer/App')).default;
});
afterEach(cleanup);

const frame = () =>
  act(async () => {
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  });

it('opens Chat from the sidebar as a full-height chat page and streams a preview answer', async () => {
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  const nav = screen.getByRole('navigation', { name: 'Main navigation' });
  fireEvent.click(within(nav).getByRole('button', { name: 'Chat' }));
  expect(await screen.findByRole('heading', { level: 1, name: 'Chat' })).toBeInTheDocument();
  expect(document.querySelector('main')).toHaveClass('page-content', 'chat-page');
  await frame();
  expect(document.title).toBe('Chat · Darkbloom');
  expect(await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' })).toBeVisible();
  const field = screen.getByRole('textbox', { name: 'Message' });
  fireEvent.change(field, { target: { value: 'Which models does this Mac serve?' } });
  await act(async () => {
    fireEvent.keyDown(field, { key: 'Enter' });
  });
  expect(screen.getByRole('status', { name: 'Reading your message' })).toBeVisible();
  expect(await screen.findByRole('button', { name: /Thinking/ }, { timeout: 3_000 })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Stop' }));
  expect(await screen.findByText('Stopped')).toBeVisible();
  const chats = screen.getByRole('navigation', { name: 'Chats' });
  expect(
    within(chats).getByRole('button', { name: 'Which models does this Mac serve?' }),
  ).toHaveAttribute('aria-current', 'true');
});
