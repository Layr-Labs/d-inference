export type Theme = "light" | "dark";
export type ThemePreference = Theme | "system";
export const THEME_STORAGE_KEY = "darkbloom-theme";

/** Self-contained so the exact same code can run before first paint. */
export function initializeTheme(): { preference: ThemePreference; theme: Theme } {
  let stored: string | null = null;
  try {
    stored = localStorage.getItem("darkbloom-theme") ?? localStorage.getItem("eigeninference-theme");
  } catch { /* Appearance remains available when storage is blocked. */ }
  const preference = stored === "light" || stored === "dark" ? stored : "system";
  const dark = preference === "dark" || (preference === "system" && window.matchMedia?.("(prefers-color-scheme: dark)").matches);
  const theme = dark ? "dark" : "light";
  document.documentElement.classList.toggle("dark", dark);
  document.documentElement.style.colorScheme = theme;
  return { preference, theme };
}

export const THEME_INIT_SCRIPT = `(${initializeTheme.toString()})();`;
