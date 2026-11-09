// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Studio } from '../src/renderer/features/Studio';
import { backendWith } from './onboardingFixtures';
import { localCapabilities, localSnapshot } from './studioFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

const tools = () => within(screen.getByRole('region', { name: 'Use it in your tools' }));

it('sets OpenCode and Hermes up with the runtime’s tool setup', () => {
  const backend = backendWith(localSnapshot());
  render(<Studio backend={backend} />);
  fireEvent.click(tools().getByRole('button', { name: 'Set up OpenCode' }));
  fireEvent.click(tools().getByRole('button', { name: 'Set up Hermes' }));
  expect(vi.mocked(backend.act).mock.calls).toEqual([
    [{ action: 'tool_setup', tool: 'opencode' }],
    [{ action: 'tool_setup', tool: 'hermes' }],
  ]);
});

it('sets tools up only while the local API runs with its key', () => {
  const stopped = localSnapshot({}, { state: 'stopped', endpoint: undefined });
  const view = render(<Studio backend={backendWith(stopped)} />);
  expect(tools().getByRole('button', { name: 'Set up OpenCode' })).toBeDisabled();
  expect(tools().getByText('Start serving first.')).toBeVisible();
  const keyless = localSnapshot();
  keyless.endpoint = { ...keyless.endpoint!, authenticated: false };
  view.rerender(<Studio backend={backendWith(keyless)} />);
  expect(tools().getByRole('button', { name: 'Set up Hermes' })).toBeDisabled();
  expect(
    tools().getByText('Tools need the local API’s key. Start it without --no-auth.'),
  ).toBeVisible();
});

it('shows the command to run where the runtime can’t set tools up', async () => {
  api.copy.mockResolvedValue(undefined);
  const backend = backendWith(
    localSnapshot({}, { capabilities: localCapabilities.filter((name) => name !== 'tool_setup') }),
  );
  render(<Studio backend={backend} />);
  expect(tools().queryByRole('button', { name: /Set up/ })).not.toBeInTheDocument();
  expect(tools().getByText('darkbloom --opencode')).toBeVisible();
  expect(tools().getByText('darkbloom --hermes')).toBeVisible();
  await act(async () =>
    fireEvent.click(tools().getByRole('button', { name: 'Copy darkbloom --hermes' })),
  );
  expect(api.copy).toHaveBeenCalledExactlyOnceWith('darkbloom --hermes');
  expect(tools().getByRole('button', { name: 'darkbloom --hermes copied' })).toBeVisible();
  expect(tools().getByRole('button', { name: 'Copy darkbloom --opencode' })).toBeVisible();
  expect(backend.act).not.toHaveBeenCalled();
});

it('names the port and address this Mac’s local API listens on', () => {
  const view = render(<Studio backend={backendWith(localSnapshot())} />);
  const details = () => within(screen.getByRole('region', { name: 'Connection details' }));
  expect(details().getByText('127.0.0.1:8001')).toBeVisible();
  expect(details().getByText('Requires an API key. Accessible only on this Mac.')).toBeVisible();
  view.rerender(<Studio backend={backendWith(localSnapshot({ bind: '0.0.0.0' }))} />);
  expect(details().getByText('0.0.0.0:8001')).toBeVisible();
  expect(
    details().getByText('Requires an API key. Accessible on your local network.'),
  ).toBeVisible();
  view.rerender(<Studio backend={backendWith(localSnapshot({ bind: '::1', port: 8007 }))} />);
  expect(details().getByText('[::1]:8007')).toBeVisible();
  expect(details().getByText('Requires an API key. Accessible only on this Mac.')).toBeVisible();
});

it('says the local API isn’t running instead of an address it doesn’t have', () => {
  render(
    <Studio backend={backendWith(localSnapshot({}, { state: 'stopped', endpoint: undefined }))} />,
  );
  const details = within(screen.getByRole('region', { name: 'Connection details' }));
  expect(details.getByText('Not running')).toBeVisible();
  expect(details.getByRole('button', { name: 'Reveal' })).toBeDisabled();
  expect(details.getByText('127.0.0.1:8001')).toBeVisible();
  expect(screen.getByRole('button', { name: /Copy example/ })).toBeDisabled();
});

it('keeps the key reveal and the example that works as copied', async () => {
  api.read.mockResolvedValue({ key: 'dk-local-test' });
  api.copy.mockResolvedValue(undefined);
  render(<Studio backend={backendWith(localSnapshot())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('dk-local-test')).toBeVisible();
  expect(api.read).toHaveBeenCalledExactlyOnceWith('endpoint-key');
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Copy example/ })));
  const copied = api.copy.mock.calls[0][0] as string;
  expect(copied).toContain('curl http://127.0.0.1:8001/v1/chat/completions');
  expect(copied).toContain('"model":"gpt-oss-20b"');
  expect(copied).toContain('Authorization: Bearer <your-local-api-key>');
  expect(copied).not.toContain('dk-local-test');
});
