"use client";

import { createContext, useContext, useState, useCallback } from "react";

type VerificationMode = "normal" | "technical";

interface VerificationModeContextValue {
  mode: VerificationMode;
  toggle: () => void;
}

const VerificationModeContext = createContext<VerificationModeContextValue>({
  mode: "normal",
  toggle: () => {},
});

const STORAGE_KEY = "eigeninference-verification-mode";

function getInitialMode(): VerificationMode {
  if (typeof window === "undefined") return "normal";
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === "technical" || stored === "normal") return stored;
  return "normal";
}

export function VerificationModeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setMode] = useState<VerificationMode>(getInitialMode);

  const toggle = useCallback(() => {
    setMode((prev) => {
      const next = prev === "normal" ? "technical" : "normal";
      localStorage.setItem(STORAGE_KEY, next);
      return next;
    });
  }, []);

  return (
    <VerificationModeContext.Provider value={{ mode, toggle }}>
      {children}
    </VerificationModeContext.Provider>
  );
}

export function useVerificationMode() {
  return useContext(VerificationModeContext);
}
