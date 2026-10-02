"use client";

import { createContext, useContext, useEffect, useRef, useState } from "react";
import { migrateStorage } from "@/lib/migrate-storage";
import { initializeTheme, THEME_STORAGE_KEY, type Theme, type ThemePreference } from "@/lib/theme";

// Migrate old eigeninference_* localStorage keys to darkbloom_* before any
// component reads them. Module-scope call ensures it runs once on bundle load.
try { migrateStorage(); } catch { /* Private browsing can block localStorage. */ }

interface ThemeContextValue {
  theme: Theme;
  preference: ThemePreference;
  setTheme: (t: ThemePreference) => void;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextValue>({
  theme: "light",
  preference: "system",
  setTheme: () => {},
  toggleTheme: () => {},
});

export function useTheme() {
  return useContext(ThemeContext);
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [theme, setThemeState] = useState<Theme>("light");
  const [preference, setPreference] = useState<ThemePreference>("system");
  const currentPreference = useRef<ThemePreference>("system");

  const apply = (next: Theme) => {
    setThemeState(next);
    document.documentElement.classList.toggle("dark", next === "dark");
    document.documentElement.style.colorScheme = next;
  };

  useEffect(() => {
    const syncStorage = () => {
      const initial = initializeTheme();
      currentPreference.current = initial.preference;
      setPreference(initial.preference);
      setThemeState(initial.theme);
    };
    syncStorage();
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const syncSystem = () => {
      if (currentPreference.current === "system") apply(media.matches ? "dark" : "light");
    };
    const onStorage = (event: StorageEvent) => {
      if (event.key === THEME_STORAGE_KEY || event.key === null) syncStorage();
    };
    media.addEventListener("change", syncSystem);
    window.addEventListener("storage", onStorage);
    return () => {
      media.removeEventListener("change", syncSystem);
      window.removeEventListener("storage", onStorage);
    };
  }, []);

  const setTheme = (next: ThemePreference) => {
    currentPreference.current = next;
    setPreference(next);
    const resolved = next === "system" ? (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light") : next;
    apply(resolved);
    try { localStorage.setItem(THEME_STORAGE_KEY, next); } catch { /* Keep this session's choice. */ }
  };

  const toggleTheme = () => {
    setTheme(theme === "light" ? "dark" : "light");
  };

  return (
    <ThemeContext.Provider value={{ theme, preference, setTheme, toggleTheme }}>
      {children}
    </ThemeContext.Provider>
  );
}
