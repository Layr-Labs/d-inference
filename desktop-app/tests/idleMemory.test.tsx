// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Settings } from '../src/renderer/features/Settings';
import type { BackendState } from '../src/renderer/useBackend';
import { previewBackend } from './previewBackend';
vi.mock('../src/renderer/useBackend', () => ({ api: undefined }));
afterEach(cleanup);

async function renderSettings(idleMinutes: number) {
  const backend = await previewBackend();
  backend.state!.settings.idle_minutes = idleMinutes;
  render(<Settings backend={backend} />);
  return backend;
}

const keepLoaded = () => screen.getByRole('switch', { name: /Keep models loaded/ });
const amount = () => screen.getByRole('spinbutton', { name: 'Free memory after' });
const unit = () => screen.getByRole('combobox', { name: 'Duration unit' });
const save = () => screen.getByRole('button', { name: /Save changes/ });

function savedPayload(backend: BackendState) {
  fireEvent.click(save());
  return vi.mocked(backend.act).mock.calls.at(-1)![0];
}

it('keeps models loaded by saving idle_minutes 0 without touching preload', async () => {
  const backend = await renderSettings(60);
  expect(keepLoaded()).not.toBeChecked();
  fireEvent.click(keepLoaded());
  expect(screen.queryByRole('spinbutton', { name: 'Free memory after' })).not.toBeInTheDocument();
  const payload = savedPayload(backend);
  expect(payload).toMatchObject({ action: 'settings', idle_minutes: 0 });
  expect(payload).not.toHaveProperty('startup_preload');
});

it('saves custom minutes and hours as idle minutes', async () => {
  const backend = await renderSettings(60);
  fireEvent.change(amount(), { target: { value: '45' } });
  fireEvent.change(unit(), { target: { value: 'minutes' } });
  expect(savedPayload(backend)).toMatchObject({ idle_minutes: 45 });
  fireEvent.change(amount(), { target: { value: '2.5' } });
  fireEvent.change(unit(), { target: { value: 'hours' } });
  expect(savedPayload(backend)).toMatchObject({ idle_minutes: 150 });
  fireEvent.click(screen.getByRole('button', { name: '15 min' }));
  expect(screen.getByRole('button', { name: '15 min' })).toHaveAttribute('aria-pressed', 'true');
  expect(savedPayload(backend)).toMatchObject({ idle_minutes: 15 });
});

it('blocks saving durations outside 1 minute to 7 days', async () => {
  const backend = await renderSettings(60);
  for (const [value, units] of [
    ['0', 'minutes'],
    ['-5', 'minutes'],
    ['10081', 'minutes'],
    ['169', 'hours'],
  ]) {
    fireEvent.change(unit(), { target: { value: units } });
    fireEvent.change(amount(), { target: { value } });
    expect(screen.getByRole('alert')).toBeVisible();
    expect(amount()).toHaveAttribute('aria-invalid', 'true');
    expect(save()).toBeDisabled();
  }
  fireEvent.change(amount(), { target: { value: '168' } });
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  expect(save()).toBeEnabled();
  expect(savedPayload(backend)).toMatchObject({ idle_minutes: 10080 });
});

it('shows an existing custom idle period that is not a quick preset', async () => {
  await renderSettings(90);
  expect(keepLoaded()).not.toBeChecked();
  expect(amount()).toHaveValue(90);
  expect(unit()).toHaveValue('minutes');
  for (const preset of ['15 min', '1 h', '4 h'])
    expect(screen.getByRole('button', { name: preset })).toHaveAttribute('aria-pressed', 'false');
  expect(screen.getByText(/Apply changes by restarting the provider/)).toBeVisible();
});

it('restores the last custom duration when models stop being kept loaded', async () => {
  const backend = await renderSettings(90);
  fireEvent.change(amount(), { target: { value: '3' } });
  fireEvent.change(unit(), { target: { value: 'hours' } });
  fireEvent.click(keepLoaded());
  fireEvent.click(keepLoaded());
  expect(amount()).toHaveValue(3);
  expect(unit()).toHaveValue('hours');
  expect(savedPayload(backend)).toMatchObject({ idle_minutes: 180 });
});

it('defaults to 1 hour when turning off a native keep-loaded setting', async () => {
  await renderSettings(0);
  expect(keepLoaded()).toBeChecked();
  fireEvent.click(keepLoaded());
  expect(amount()).toHaveValue(1);
  expect(unit()).toHaveValue('hours');
  expect(screen.getByRole('button', { name: '1 h' })).toHaveAttribute('aria-pressed', 'true');
});
