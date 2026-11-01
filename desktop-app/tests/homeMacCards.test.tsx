// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Snapshot } from '../src/shared/contracts';

let Home: typeof import('../src/renderer/features/Home').Home;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(cleanup);

async function renderHome(state: Snapshot['state'], remoteStatus = 'online') {
  const backend = await previewBackend();
  backend.state = { ...backend.state!, state };
  backend.cloud!.machines = backend.cloud!.machines.map((machine) => ({
    ...machine,
    status: remoteStatus,
  }));
  const navigate = vi.fn(),
    openMachine = vi.fn();
  render(<Home backend={backend} navigate={navigate} openMachine={openMachine} />);
  return { backend, navigate, openMachine };
}
const macs = () => screen.getByRole('region', { name: 'Your Macs' });
const card = (name: string) => within(macs()).getByRole('button', { name: `Open ${name}` });
// The header's start verb ("Start serving" after #1501).
const startName = /^Start (?:providing|serving)$/;
const startCTA = () => within(macs()).queryByRole('button', { name: startName });

it('marks each Mac card as a button that opens it, with a visible open affordance', async () => {
  const { openMachine, backend } = await renderHome('running');
  for (const name of ['MacBook Pro', 'Mac Studio']) {
    const button = card(name);
    expect(button.tagName).toBe('BUTTON');
    expect(button.querySelector('[data-open-affordance]')).not.toBeNull();
  }
  fireEvent.click(card('MacBook Pro'));
  expect(openMachine.mock.calls).toEqual([[backend.state!.machine.id]]);
});

it('offers the header start action on a stopped This Mac card', async () => {
  const { navigate, openMachine, backend } = await renderHome('stopped');
  const cta = startCTA();
  const [header, ...others] = screen
    .getAllByRole('button', { name: startName })
    .filter((button) => !macs().contains(button));
  expect(others).toEqual([]);
  expect(cta).toBeVisible();
  // The CTA is not nested inside the open button.
  expect(card('MacBook Pro').contains(cta)).toBe(false);
  fireEvent.click(header);
  fireEvent.click(cta!);
  expect(navigate.mock.calls).toEqual([['models'], ['models']]);
  expect(openMachine).not.toHaveBeenCalled();
  expect(backend.act).not.toHaveBeenCalled();
});

it('shows live status instead of a start action while This Mac serves', async () => {
  await renderHome('running');
  expect(within(card('MacBook Pro')).getByText('Online')).toBeVisible();
  expect(startCTA()).toBeNull();
});

it('never offers to start a view-only Mac', async () => {
  await renderHome('running', 'stopped');
  expect(within(card('Mac Studio')).getByText('Stopped')).toBeVisible();
  expect(startCTA()).toBeNull();
});
