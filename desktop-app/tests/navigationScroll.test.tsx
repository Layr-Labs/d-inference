// @vitest-environment jsdom
import React from 'react';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

let App: typeof import('../src/renderer/App').default;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  App = (await import('../src/renderer/App')).default;
});
afterEach(cleanup);

const page = document.documentElement;

describe('navigation scroll position', () => {
  it('opens every page, Mac and tab at the top instead of the previous scroll offset', async () => {
    render(<App />);
    await screen.findByRole('heading', { name: 'Your contribution' });
    const nav = screen.getByRole('navigation', { name: 'Main navigation' });

    page.scrollTop = 1200;
    fireEvent.click(within(nav).getByRole('button', { name: 'My Macs' }));
    await screen.findByRole('region', { name: 'Health' });
    expect(page.scrollTop).toBe(0);

    page.scrollTop = 700;
    fireEvent.click(screen.getByRole('button', { name: 'Select Mac Studio, View only' }));
    await screen.findByText(/^View only\. Controls for this Mac/);
    expect(page.scrollTop).toBe(0);

    fireEvent.click(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' }));
    await screen.findByRole('region', { name: 'Health' });
    page.scrollTop = 500;
    fireEvent.click(screen.getByRole('button', { name: 'Cooling' }));
    await screen.findByRole('heading', { name: 'Cooling' });
    expect(page.scrollTop).toBe(0);

    fireEvent.click(within(nav).getByRole('button', { name: 'Home' }));
    const fleet = await screen.findByRole('region', { name: 'Fleet earnings' });
    page.scrollTop = 1500;
    fireEvent.click(within(fleet).getByRole('button', { name: /View earnings/ }));
    await screen.findByRole('heading', { name: 'Earnings', level: 1 });
    expect(page.scrollTop).toBe(0);
  });
});
