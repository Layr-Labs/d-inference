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
  it('shows the fleet on Home and opens a Mac from it', async () => {
    render(<App />);
    const fleet = await screen.findByRole('region', { name: 'Across your Macs' });
    expect(within(fleet).getByText('$2,146.20')).toBeVisible();
    expect(within(fleet).getByText('$46.10')).toBeVisible();
    expect(screen.queryByRole('heading', { name: 'My Macs', level: 1 })).not.toBeInTheDocument();
    fireEvent.change(within(fleet).getByRole('textbox', { name: 'Search Macs' }), {
      target: { value: 'Ultra' },
    });
    expect(within(fleet).queryByRole('button', { name: 'Open MacBook Pro' })).toBeNull();
    fireEvent.click(within(fleet).getByRole('button', { name: 'Open Mac Studio' }));
    expect(
      await screen.findByRole('button', { name: 'Select Mac Studio, View only' }),
    ).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByText(/^View only\. Controls for this Mac/)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Home' }));
    fireEvent.click(
      within(await screen.findByRole('region', { name: 'Across your Macs' })).getByRole('button', {
        name: 'Open MacBook Pro',
      }),
    );
    expect(await screen.findByRole('region', { name: 'Health' })).toBeVisible();
    expect(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
  });
  it('opens My Macs on This Mac and returns there from a remote Mac', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    fireEvent.click(screen.getByRole('button', { name: 'My Macs' }));
    expect(await screen.findByRole('region', { name: 'Health' })).toBeVisible();
    expect(screen.queryByText('Fleet overview')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Select Mac Studio, View only' }));
    expect(screen.queryByRole('region', { name: 'Health' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'My Macs' }));
    expect(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    expect(screen.getByRole('region', { name: 'Health' })).toBeVisible();
  });
  it('lists serviced requests under Stats > Activity', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name: 'Stats' }));
    fireEvent.click(await screen.findByRole('tab', { name: 'Activity' }));
    const table = await screen.findByRole('table');
    expect(within(table).getAllByRole('row')).toHaveLength(26);
    expect(screen.getByText(/never stored or shown/)).toBeVisible();
  });
  it('keeps remote machines read-only', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    fireEvent.click(screen.getByRole('button', { name: 'My Macs' }));
    const remote = await screen.findByRole('button', { name: /Select Mac Studio.*View only/ });
    fireEvent.click(remote);
    expect(screen.getByText(/^View only\. Controls for this Mac/)).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Stop provider' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Restart' })).not.toBeInTheDocument();
  });
  it('downloads a catalog model into the Autopilot pool', { timeout: 15_000 }, async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name: 'Manage models' }));
    expect(screen.getByRole('region', { name: 'Autopilot' })).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Apply selection' })).not.toBeInTheDocument();
    fireEvent.change(screen.getByRole('textbox', { name: 'Search models' }), {
      target: { value: 'Qwen 3.6' },
    });
    expect(screen.queryByRole('heading', { name: 'GPT-OSS 20B' })).not.toBeInTheDocument();
    const row = screen.getByRole('heading', { name: 'Qwen 3.6 35B A3B' }).closest('article')!;
    expect(within(row).getByText('Not downloaded')).toBeVisible();
    fireEvent.click(within(row).getByRole('button', { name: /Download/ }));
    await within(row).findByRole('progressbar', { name: 'Download progress' });
    expect(await within(row).findByText('In pool', {}, { timeout: 10_000 })).toBeVisible();
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
    expect(screen.getByRole('spinbutton', { name: 'Free memory after' })).toHaveValue(15);
  });
});

async function openLocalMac() {
  fireEvent.click(screen.getByRole('button', { name: 'My Macs' }));
  fireEvent.click(await screen.findByRole('button', { name: /Select MacBook Pro.*This Mac/ }));
}

it('preserves Cooling, Analysis, Studio, and Settings through This Mac', async () => {
  render(<App />);
  await screen.findByRole('heading', { name: 'Your contribution' });
  for (const name of ['Cooling', 'Stats', 'Studio', 'Settings']) {
    await openLocalMac();
    fireEvent.click(screen.getByRole('button', { name }));
    expect(await screen.findByRole('heading', { name, level: 2 })).toBeVisible();
  }
});
