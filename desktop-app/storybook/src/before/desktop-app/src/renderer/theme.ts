export type ThemePreference = 'light' | 'dark' | 'system';
export function savedTheme(): ThemePreference {
  try {
    const value = localStorage.getItem('darkbloom.appearance');
    if (value === 'light' || value === 'dark') return value;
  } catch {
    /* Session-only appearance remains available. */
  }
  return 'system';
}
export function applyTheme(preference: ThemePreference) {
  const dark =
    preference === 'dark' ||
    (preference === 'system' && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}
