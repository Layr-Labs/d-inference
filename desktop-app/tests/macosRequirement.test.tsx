// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Snapshot } from '../src/shared/contracts';
import { macosMajor, supportsNewProviders } from '../src/shared/macos';

let Home: typeof import('../src/renderer/features/Home').Home;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
let withOnboardingScenario: typeof import('../src/renderer/previewEligibility').withOnboardingScenario;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ previewAPI } = await import('../src/renderer/preview'));
  ({ withOnboardingScenario } = await import('../src/renderer/previewEligibility'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  sessionStorage.clear();
  window.history.replaceState({}, '', '/?preview');
});

describe('macOS version', () => {
  it('reads the major release, and nothing from a version it can’t parse', () => {
    expect(['27.0', '26.5.1', '15.6', '28', ' 27.1 '].map(macosMajor)).toEqual([
      27, 26, 15, 28, 27,
    ]);
    for (const version of ['', undefined, 'macOS 27', '27.0.0.1', 'beta'])
      expect(macosMajor(version)).toBeUndefined();
  });

  it('accepts new providers on macOS 27 or later, and never guesses an unknown version', () => {
    expect(['27.0', '27.1.2', '28.0'].every(supportsNewProviders)).toBe(true);
    expect(['26.5', '26.0', '15.6.1'].some(supportsNewProviders)).toBe(false);
    expect(supportsNewProviders('')).toBe(true);
    expect(supportsNewProviders(undefined)).toBe(true);
  });

  it('is 27.0 in the preview unless the address names another', async () => {
    expect(await previewAPI.system()).toEqual({ macosVersion: '27.0' });
    window.history.replaceState({}, '', '/?preview&macos=26.5');
    expect(await previewAPI.system()).toEqual({ macosVersion: '26.5' });
    window.history.replaceState({}, '', '/?preview&macos=latest');
    expect(await previewAPI.system()).toEqual({ macosVersion: '27.0' });
  });

  it('reports the preview’s macOS in the scenarios’ eligibility', async () => {
    const snapshot = await previewAPI.read<Snapshot>('state');
    const macos = () =>
      withOnboardingScenario(snapshot, 'eligible').eligibility?.checks.find(
        (check) => check.id === 'macos',
      );
    expect(macos()).toEqual({ id: 'macos', label: 'macOS', ok: true, value: '27.0' });
    window.history.replaceState({}, '', '/?preview&onboarding=eligible&macos=26.5');
    expect(macos()).toMatchObject({ ok: false, value: '26.5' });
  });
});

describe('Home on an existing install', () => {
  const prompt = 'Darkbloom needs macOS 27 or later. Update macOS to keep serving.';

  it('prompts below macOS 27 to update macOS, opening Software Update', async () => {
    const open = vi.spyOn(previewAPI, 'openSoftwareUpdate');
    const backend = await previewBackend({ system: { macosVersion: '26.5' } });
    render(<Home backend={backend} navigate={vi.fn()} openMachine={vi.fn()} />);
    expect(screen.getByRole('alert')).toHaveTextContent(prompt);
    // Serving is untouched: the provider can still be stopped as usual.
    expect(screen.getByRole('button', { name: 'Stop serving' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Open Software Update' }));
    expect(open).toHaveBeenCalledOnce();
  });

  it('stays dismissed for the rest of the session', async () => {
    const backend = await previewBackend({ system: { macosVersion: '26.5' } });
    const view = render(<Home backend={backend} navigate={vi.fn()} openMachine={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }));
    expect(screen.queryByText(prompt)).not.toBeInTheDocument();
    view.unmount();
    render(<Home backend={backend} navigate={vi.fn()} openMachine={vi.fn()} />);
    expect(screen.queryByText(prompt)).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Open Software Update' })).toBeNull();
  });

  it('says nothing on macOS 27 or later, or before the version is known', async () => {
    for (const system of [{ macosVersion: '27.0' }, { macosVersion: '' }, undefined]) {
      const view = render(
        <Home
          backend={await previewBackend({ system })}
          navigate={vi.fn()}
          openMachine={vi.fn()}
        />,
      );
      expect(screen.queryByText(prompt)).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: 'Open Software Update' })).toBeNull();
      view.unmount();
    }
  });
});
