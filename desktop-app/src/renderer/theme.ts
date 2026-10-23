export type ThemePreference = 'light' | 'dark' | 'system';
let activePreference: ThemePreference | undefined;

/** Load the initial preference once, then retain the active choice for this session. */
export function savedTheme(): ThemePreference {
  if (activePreference !== undefined) return activePreference;
  activePreference = 'system';
  try {
    const value = localStorage.getItem('darkbloom.appearance');
    if (value === 'light' || value === 'dark') activePreference = value;
  } catch {
    /* Session-only appearance remains available. */
  }
  return activePreference;
}
/** Re-apply the active preference when macOS switches appearance, on every screen. */
export function followSystemTheme() {
  const query = window.matchMedia?.('(prefers-color-scheme: dark)');
  const change = () => applyTheme(savedTheme());
  query?.addEventListener('change', change);
  return () => query?.removeEventListener('change', change);
}
export function applyTheme(preference: ThemePreference) {
  activePreference = preference;
  const dark =
    preference === 'dark' ||
    (preference === 'system' && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}
