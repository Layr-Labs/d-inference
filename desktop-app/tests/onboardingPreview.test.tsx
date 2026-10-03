// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import {
  evaluateEligibility,
  failedChecks,
} from '../src/renderer/components/onboarding/eligibility';
import type { Snapshot } from '../src/shared/contracts';
import { snapshot } from './onboardingFixtures';

async function load<T>(search: string, module: () => Promise<T>) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  return module();
}
const scenarios = (search: string) =>
  load(search, () => import('../src/renderer/previewEligibility'));
const app = async (search: string) =>
  (await load(search, () => import('../src/renderer/App'))).default;

afterEach(() => {
  cleanup();
  localStorage.clear();
});

describe('preview scenarios', () => {
  it('opens onboarding only for a known scenario in the development preview', async () => {
    expect((await scenarios('?preview&onboarding=ineligible')).onboardingScenario).toBe(
      'ineligible',
    );
    expect((await scenarios('?preview&onboarding=eligible')).onboardingScenario).toBe('eligible');
    expect((await scenarios('?onboarding=ineligible')).onboardingScenario).toBeUndefined();
    expect((await scenarios('?preview&onboarding=other')).onboardingScenario).toBeUndefined();
    expect((await scenarios('?preview')).onboardingScenario).toBeUndefined();
  });

  it('gives each scenario the matching scan result', async () => {
    const { withOnboardingScenario } = await scenarios('?preview');
    const base = snapshot();
    const eligible = evaluateEligibility(withOnboardingScenario(base, 'eligible'));
    expect(eligible.verdict).toBe('eligible');
    expect(eligible.checks.map((check) => check.id)).toEqual([
      'apple_silicon',
      'memory',
      'macos',
      'storage',
      'security',
    ]);
    const ineligible = evaluateEligibility(withOnboardingScenario(base, 'ineligible'));
    expect(ineligible.verdict).toBe('ineligible');
    expect(failedChecks(ineligible.checks).map((check) => check.id)).toEqual(['memory']);
    const unknown = withOnboardingScenario(base, 'unknown');
    expect(unknown.eligibility).toBeUndefined();
    expect(evaluateEligibility(unknown).verdict).toBe('unknown');
    expect(withOnboardingScenario(base, undefined)).toBe(base);
  });
});

describe('preview onboarding', () => {
  it('opens on the scenario and joins the waitlist through the preview runtime', async () => {
    const App = await app('?preview&onboarding=ineligible');
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: 'Start' }));
    expect(await screen.findByRole('heading', { name: 'Checking this Mac…' })).toBeVisible();
    fireEvent.click(await screen.findByRole('button', { name: /Skip/ }));
    expect(screen.getByRole('heading', { name: 'This Mac isn’t eligible yet.' })).toBeVisible();
    expect(screen.getByText('MacBook Air')).toBeVisible();
    fireEvent.change(screen.getByRole('textbox', { name: 'Email address' }), {
      target: { value: 'ada@example.com' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Join the waitlist/ }));
    expect(await screen.findByText('You’re on the waitlist.', {}, { timeout: 3000 })).toBeVisible();
  });

  it('can simulate a runtime that rejects sign-ups', async () => {
    const App = await app('?preview&onboarding=ineligible&waitlist=fail');
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: 'Start' }));
    fireEvent.click(await screen.findByRole('button', { name: /Skip/ }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Email address' }), {
      target: { value: 'ada@example.com' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Join the waitlist/ }));
    expect(
      await screen.findByText(
        'We couldn’t add you to the waitlist. This version of Darkbloom doesn’t support sign-ups yet.',
        {},
        { timeout: 3000 },
      ),
    ).toBeVisible();
  });
});

describe('preview Autopilot', () => {
  const preview = async (search: string) =>
    (await load(search, () => import('../src/renderer/preview'))).previewAPI;
  const action = {
    action: 'autopilot' as const,
    models: ['qwen-3.5-9b'],
    pinned: ['qwen-3.5-9b'],
    endpoint: true,
  };

  it('turns Autopilot on with the pins it was given', async () => {
    const api = await preview('?preview&onboarding=eligible');
    await api.act(action);
    const state = await api.read<Snapshot>('state');
    expect(state.state).toBe('running');
    expect(state.autopilot).toMatchObject({
      enabled: true,
      paused: false,
      pinned: ['qwen-3.5-9b'],
    });
    expect(state.autopilot?.selected).toContain('qwen-3.5-9b');
  });

  it('rejects Autopilot the way a runtime without the action does', async () => {
    const api = await preview('?preview&autopilot=unsupported');
    await expect(api.act(action)).rejects.toThrow('Unknown action');
  });

  it('shows a link code and approves it a few seconds later', async () => {
    const api = await preview('?preview&account=unlinked');
    vi.useFakeTimers();
    try {
      await api.act({ action: 'link' });
      const pending = await api.read<Snapshot>('state');
      expect(pending.linked).toBe(false);
      expect(pending.link?.code).toBeTruthy();
      vi.advanceTimersByTime(6000);
      const linked = await api.read<Snapshot>('state');
      expect(linked.linked).toBe(true);
      expect(linked.link).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });

  it('offers manual setup when the preview runtime rejects Autopilot', async () => {
    const App = await app('?preview&onboarding=eligible&autopilot=unsupported');
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: 'Start' }));
    fireEvent.click(await screen.findByRole('button', { name: /Skip/ }));
    fireEvent.click(screen.getByRole('button', { name: /Start serving with Autopilot/ }));
    expect(
      await screen.findByRole('button', { name: /Choose models manually/ }, { timeout: 3000 }),
    ).toBeVisible();
  });
});
