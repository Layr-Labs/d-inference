import { useEffect, useState } from 'react';
import { applyTheme, savedTheme, type ThemePreference } from '../theme';
export function Appearance() {
  const [theme, setTheme] = useState(savedTheme);
  useEffect(() => {
    applyTheme(theme);
    try {
      localStorage.setItem('darkbloom.appearance', theme);
    } catch {}
    const query = window.matchMedia?.('(prefers-color-scheme: dark)');
    const change = () => applyTheme(theme);
    query?.addEventListener('change', change);
    return () => query?.removeEventListener('change', change);
  }, [theme]);
  return (
    <select
      className="appearance-select"
      aria-label="Appearance"
      value={theme}
      onChange={(e) => setTheme(e.target.value as ThemePreference)}
    >
      <option value="system">System</option>
      <option value="light">Light</option>
      <option value="dark">Dark</option>
    </select>
  );
}
