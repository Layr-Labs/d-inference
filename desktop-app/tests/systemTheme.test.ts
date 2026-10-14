// @vitest-environment jsdom
import { readFileSync } from 'node:fs';
import { createElement } from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';

const systemCss = readFileSync(`${import.meta.dirname}/../src/renderer/styles/system.css`, 'utf8');
const themeCss = readFileSync(`${import.meta.dirname}/../src/renderer/styles/theme.css`, 'utf8');

let theme: typeof import('../src/renderer/theme');
let stop: (() => void) | undefined;

beforeEach(async () => {
  vi.resetModules();
  theme = await import('../src/renderer/theme');
});

afterEach(() => {
  stop?.();
  stop = undefined;
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  localStorage.clear();
  delete document.documentElement.dataset.theme;
});

// A controllable prefers-color-scheme query.
function systemScheme(dark: boolean) {
  const listeners = new Set<() => void>();
  const query = {
    get matches() {
      return dark;
    },
    addEventListener: (_: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_: string, listener: () => void) => listeners.delete(listener),
  };
  vi.stubGlobal('matchMedia', () => query);
  return (next: boolean) => {
    dark = next;
    listeners.forEach((listener) => listener());
  };
}

it('follows a macOS appearance change on screens without the Appearance control', () => {
  const setDark = systemScheme(true);
  theme.applyTheme(theme.savedTheme());
  stop = theme.followSystemTheme();
  expect(document.documentElement.dataset.theme).toBe('dark');
  setDark(false);
  expect(document.documentElement.dataset.theme).toBe('light');
  stop();
  setDark(true);
  expect(document.documentElement.dataset.theme).toBe('light');
});

it.each(['light', 'dark'] as const)(
  'keeps an explicit saved %s appearance when macOS changes',
  (preference) => {
    localStorage.setItem('darkbloom.appearance', preference);
    const setDark = systemScheme(preference === 'dark');
    theme.applyTheme(theme.savedTheme());
    stop = theme.followSystemTheme();
    setDark(preference !== 'dark');
    expect(document.documentElement.dataset.theme).toBe(preference);
  },
);

it.each([null, 'system', 'unknown'])('defaults to System for the stored value %s', (value) => {
  if (value !== null) localStorage.setItem('darkbloom.appearance', value);
  const setDark = systemScheme(true);
  expect(theme.savedTheme()).toBe('system');
  theme.applyTheme(theme.savedTheme());
  stop = theme.followSystemTheme();
  expect(document.documentElement.dataset.theme).toBe('dark');
  setDark(false);
  expect(document.documentElement.dataset.theme).toBe('light');
});

it('reads storage only when initializing the session preference', () => {
  const getItem = vi.spyOn(Storage.prototype, 'getItem');
  const setDark = systemScheme(true);
  theme.applyTheme(theme.savedTheme());
  stop = theme.followSystemTheme();
  setDark(false);
  setDark(true);
  expect(theme.savedTheme()).toBe('system');
  expect(getItem).toHaveBeenCalledExactlyOnceWith('darkbloom.appearance');
});

it.each([
  { preference: 'light', failure: 'writes' },
  { preference: 'dark', failure: 'writes' },
  { preference: 'light', failure: 'reads and writes' },
  { preference: 'dark', failure: 'reads and writes' },
] as const)(
  'keeps a session-only $preference selection when storage $failure fail',
  async ({ preference, failure }) => {
    localStorage.setItem('darkbloom.appearance', preference === 'light' ? 'dark' : 'light');
    const unavailable = () => {
      throw new DOMException('Storage unavailable', 'SecurityError');
    };
    const getItem = vi.spyOn(Storage.prototype, 'getItem');
    if (failure === 'reads and writes') getItem.mockImplementation(unavailable);
    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(unavailable);
    const setDark = systemScheme(preference === 'dark');
    theme.applyTheme(theme.savedTheme());
    stop = theme.followSystemTheme();
    const { Appearance } = await import('../src/renderer/components/Appearance');
    const { unmount } = render(createElement(Appearance));

    fireEvent.change(screen.getByRole('combobox', { name: 'Appearance' }), {
      target: { value: preference },
    });
    expect(document.documentElement.dataset.theme).toBe(preference);
    expect(setItem).toHaveBeenLastCalledWith('darkbloom.appearance', preference);
    act(() => setDark(preference !== 'dark'));
    expect(document.documentElement.dataset.theme).toBe(preference);
    expect(screen.getByRole('combobox', { name: 'Appearance' })).toHaveValue(preference);

    unmount();
    render(createElement(Appearance));
    expect(screen.getByRole('combobox', { name: 'Appearance' })).toHaveValue(preference);
    act(() => setDark(preference === 'dark'));
    expect(document.documentElement.dataset.theme).toBe(preference);
    expect(getItem).toHaveBeenCalledExactlyOnceWith('darkbloom.appearance');
  },
);

it('resumes following macOS when System is selected even if storage is unavailable', async () => {
  const unavailable = () => {
    throw new DOMException('Storage unavailable', 'SecurityError');
  };
  vi.spyOn(Storage.prototype, 'getItem').mockImplementation(unavailable);
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(unavailable);
  const setDark = systemScheme(true);
  theme.applyTheme(theme.savedTheme());
  stop = theme.followSystemTheme();
  const { Appearance } = await import('../src/renderer/components/Appearance');
  render(createElement(Appearance));
  const select = screen.getByRole('combobox', { name: 'Appearance' });
  fireEvent.change(select, { target: { value: 'light' } });
  expect(document.documentElement.dataset.theme).toBe('light');
  fireEvent.change(select, { target: { value: 'system' } });
  expect(document.documentElement.dataset.theme).toBe('dark');
  act(() => setDark(false));
  expect(document.documentElement.dataset.theme).toBe('light');
  act(() => setDark(true));
  expect(document.documentElement.dataset.theme).toBe('dark');
  expect(select).toHaveValue('system');
});

it('falls back to light for System when matchMedia is unavailable', () => {
  vi.stubGlobal('matchMedia', undefined);
  theme.applyTheme(theme.savedTheme());
  stop = theme.followSystemTheme();
  expect(document.documentElement.dataset.theme).toBe('light');
  theme.applyTheme('dark');
  expect(document.documentElement.dataset.theme).toBe('dark');
});

it.each(['light', 'dark'])(
  'keeps on and off switch tracks distinct in the %s theme',
  (appearance) => {
    document.documentElement.dataset.theme = appearance;
    const style = document.createElement('style');
    style.textContent = `${systemCss}\n${themeCss}`;
    document.head.append(style);
    try {
      render(
        createElement(
          'div',
          null,
          createElement('input', {
            type: 'checkbox',
            className: 'switch',
            'aria-label': 'Off',
            checked: false,
            readOnly: true,
          }),
          createElement('input', {
            type: 'checkbox',
            className: 'switch',
            'aria-label': 'On',
            checked: true,
            readOnly: true,
          }),
        ),
      );
      const off = getComputedStyle(screen.getByRole('checkbox', { name: 'Off' }));
      const on = getComputedStyle(screen.getByRole('checkbox', { name: 'On' }));
      expect(off.getPropertyValue('--switch-track').replace(/\s/g, '')).toBe(
        `rgba(var(--contrast-rgb),${appearance === 'light' ? '0.3' : '0.18'})`,
      );
      expect(off.getPropertyValue('--switch-track-hover').replace(/\s/g, '')).toBe(
        `rgba(var(--contrast-rgb),${appearance === 'light' ? '0.38' : '0.26'})`,
      );
      expect(on.getPropertyValue('--switch-track').trim()).toBe('var(--blue)');
      expect(on.getPropertyValue('--switch-track-hover').trim()).toBe('#2858ff');
    } finally {
      style.remove();
    }
  },
);
