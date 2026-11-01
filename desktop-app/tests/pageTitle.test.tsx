// @vitest-environment jsdom
import { afterAll, afterEach, beforeAll, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { CloudData, DesktopAPI, Resource, Snapshot } from '../src/shared/contracts';
import { operation, snapshot } from './onboardingFixtures';

let App: typeof import('../src/renderer/App').default;
let state: Snapshot;
let cloud: CloudData;
let initialState: () => Promise<Snapshot>;
let receiveState: ((state: Snapshot) => void) | undefined;
const read = vi.fn(async (resource: Resource): Promise<unknown> => {
  if (resource === 'state') return initialState();
  if (resource === 'cloud') return cloud;
  if (resource === 'network') return {};
  if (resource === 'cooling') return { supported: false, mode: 'unavailable', fans: [] };
  throw new Error(`No fixture for ${resource}`);
});
const bridge: DesktopAPI = {
  read: <T,>(resource: Resource) => read(resource) as Promise<T>,
  act: vi.fn(async () => operation('succeeded')),
  status: async () => ({ state: 'ready' }),
  install: async () => {},
  cancelInstall: async () => {},
  openExternal: async () => {},
  copy: async () => {},
  updateStatus: async () => ({ state: 'idle' }),
  checkUpdate: async () => ({ state: 'idle' }),
  applyUpdate: async () => {},
  onState: (callback) => {
    receiveState = callback;
    return () => {
      receiveState = undefined;
    };
  },
  onStatus: () => () => {},
  onNavigate: () => () => {},
  onHardware: () => () => {},
  system: async () => ({ macosVersion: '27.0' }),
  openSoftwareUpdate: async () => {},
};

beforeAll(async () => {
  window.history.replaceState({}, '', '/');
  window.darkbloom = bridge;
  App = (await import('../src/renderer/App')).default;
});
beforeEach(() => {
  localStorage.setItem('darkbloom.onboardingComplete', '1');
  document.title = 'Darkbloom';
  state = snapshot({ account_revision: 'signed-in', account: { signed_in: true } });
  cloud = {
    linked: true,
    observed_at: state.observed_at,
    machines: [{ ...state.machine, id: 'remote-studio', name: 'Mac Studio' }],
  };
  initialState = async () => state;
});
afterEach(() => {
  cleanup();
  localStorage.clear();
  vi.clearAllMocks();
});
afterAll(() => {
  delete window.darkbloom;
});

const frame = () =>
  act(async () => {
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  });

it('sets the Home title when the first snapshot arrives after the initial frame', async () => {
  let deliver!: (state: Snapshot) => void;
  initialState = () =>
    new Promise((resolve) => {
      deliver = resolve;
    });
  render(<App />);
  await waitFor(() => expect(read).toHaveBeenCalledWith('state'));
  await frame();
  expect(document.title).toBe('Darkbloom');

  await act(async () => deliver(state));
  await screen.findByRole('heading', { level: 1, name: 'Your contribution' });
  await frame();
  expect(document.title).toBe('Your contribution · Darkbloom');
  expect(document.body).toHaveFocus();
});

it.each(['sign-out', 'cloud removal'])(
  'updates the title to the local fallback after same-route %s without refocusing',
  async (change) => {
    render(<App />);
    await screen.findByRole('heading', { level: 1, name: 'Your contribution' });
    const nav = screen.getByRole('navigation', { name: 'Main navigation' });
    fireEvent.click(within(nav).getByRole('button', { name: 'My Macs' }));
    const remote = await screen.findByRole('button', { name: 'Select Mac Studio, View only' });
    remote.focus();
    fireEvent.click(remote);
    await frame();
    expect(document.title).toBe('Mac Studio View only · Darkbloom');

    const home = within(nav).getByRole('button', { name: 'Home' });
    home.focus();
    if (change === 'sign-out') {
      state = { ...state, account_revision: 'signed-out', account: { signed_in: false } };
    } else {
      cloud = { ...cloud, machines: [] };
      state = { ...state, resource_revision: 'cloud-removed' };
    }
    act(() => receiveState!(state));
    await screen.findByRole('heading', { level: 1, name: 'MacBook Pro This Mac' });
    await frame();
    expect(document.title).toBe('MacBook Pro This Mac · Darkbloom');
    expect(home).toHaveFocus();

    // Even when focus is on the body, a routine snapshot must not re-run navigation recovery.
    home.blur();
    act(() => receiveState!({ ...state, observed_at: state.observed_at + 1 }));
    await frame();
    expect(document.body).toHaveFocus();
    expect(document.title).toBe('MacBook Pro This Mac · Darkbloom');
  },
);
