// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { applyTheme, followSystemTheme, savedTheme } from '../src/renderer/theme';

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
  window.matchMedia = (() => query) as unknown as typeof window.matchMedia;
  return (next: boolean) => {
    dark = next;
    listeners.forEach((listener) => listener());
  };
}

afterEach(() => localStorage.clear());

it('follows a macOS appearance change on screens without the Appearance control', () => {
  const setDark = systemScheme(true);
  applyTheme(savedTheme());
  const stop = followSystemTheme();
  expect(document.documentElement.dataset.theme).toBe('dark');
  setDark(false);
  expect(document.documentElement.dataset.theme).toBe('light');
  stop();
  setDark(true);
  expect(document.documentElement.dataset.theme).toBe('light');
});

it('keeps an explicit appearance when macOS changes', () => {
  localStorage.setItem('darkbloom.appearance', 'dark');
  const setDark = systemScheme(true);
  applyTheme(savedTheme());
  const stop = followSystemTheme();
  setDark(false);
  expect(document.documentElement.dataset.theme).toBe('dark');
  stop();
});
