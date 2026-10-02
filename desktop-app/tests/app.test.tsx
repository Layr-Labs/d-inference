// @vitest-environment jsdom
import React from 'react';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
let App: typeof import('../src/renderer/App').default;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  App = (await import('../src/renderer/App')).default;
});
afterEach(cleanup);
describe('desktop operator journeys', () => {
  it('shows the explicit development banner and navigates the complete app', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    expect(screen.getByText('Development preview')).toBeVisible();
    expect(screen.getByRole('link', { name: 'Darkbloom on X' })).toHaveAttribute(
      'href',
      'https://x.com/darkbloomai',
    );
    expect(screen.getByRole('link', { name: 'Darkbloom on GitHub' })).toHaveAttribute(
      'href',
      'https://github.com/Layr-Labs/d-inference',
    );
    expect(screen.getByRole('link', { name: 'Join the Darkbloom Slack' })).toHaveAttribute(
      'target',
      '_blank',
    );
    const nav = screen.getByRole('navigation', { name: 'Main navigation' });
    expect(
      within(nav)
        .getAllByRole('button')
        .map((button) => button.textContent),
    ).toEqual(['Home', 'My Macs2', 'Leaderboard', 'Updates']);
    for (const name of ['Leaderboard', 'Updates']) {
      fireEvent.click(within(nav).getByRole('button', { name }));
      expect(await screen.findByRole('heading', { name, level: 1 })).toBeVisible();
    }
  });
  it('keeps remote machines read-only', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    fireEvent.click(screen.getByRole('button', { name: /My Macs/ }));
    const remote = await screen.findByRole('button', { name: /Mac Studio.*Remote/ });
    fireEvent.click(remote);
    expect(screen.getByText(/Status and earnings only/)).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Stop provider' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Restart' })).not.toBeInTheDocument();
  });
  it('filters catalog entries and blocks selecting an undownloaded model', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name: 'Manage models' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: 'Qwen 3.5' },
    });
    expect(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' })).toBeDisabled();
    expect(screen.queryByRole('heading', { name: 'GPT-OSS 20B' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Download' }));
    await waitFor(() =>
      expect(screen.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' })).toBeEnabled(),
    );
  });
  it('does not overwrite a concurrent CLI settings change with a stale draft', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Mac name' }), {
      target: { value: 'My unsaved draft' },
    });
    const { previewAPI } = await import('../src/renderer/preview');
    await act(async () => {
      await previewAPI.act({
        action: 'settings',
        revision: 'external-change',
        name: 'Changed from CLI',
        idle_minutes: 15,
        auto_update: true,
      });
    });
    expect(screen.getByRole('textbox', { name: 'Mac name' })).toHaveValue('My unsaved draft');
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Reload settings' }));
    expect(screen.getByRole('textbox', { name: 'Mac name' })).toHaveValue('Changed from CLI');
  });
});

async function openLocalMac() {
  fireEvent.click(screen.getByRole('button', { name: /My Macs/ }));
  fireEvent.click(await screen.findByRole('button', { name: /MacBook Pro.*This Mac/ }));
}

it('preserves Cooling, Analysis, Studio, and Settings through This Mac', async () => {
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  for (const name of ['Cooling', 'Analysis', 'Studio', 'Settings']) {
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name }));
    expect(await screen.findByRole('heading', { name, level: 1 })).toBeVisible();
  }
});
