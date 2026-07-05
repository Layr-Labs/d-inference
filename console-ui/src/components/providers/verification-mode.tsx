"use client";

import { createContext, useContext, useEffect, useState, useCallback } from "react";
import { STORAGE_KEYS } from "@/lib/constants";

type VerificationMode = "normal" | "technical";

interface VerificationModeContextValue {
  mode: VerificationMode;
  toggle: () => void;
}

const VerificationModeContext = createContext<VerificationModeContextValue>({
  mode: "normal",
  toggle: () => {},
});

const STORAGE_KEY = STORAGE_KEYS.verificationMode;

export function VerificationModeProvider({ children }: { children: React.ReactNode }) {
  // Start "normal" on the server AND the first client render, then load the
  // persisted preference in an effect. Reading localStorage during render (in a
  // useState initializer) diverged the first client render from the server HTML
  // whenever the user had toggled "technical", causing a React hydration
  // mismatch. On a mismatch React discards the server DOM and regenerates the
  // tree on the client, which breaks App Router client navigation app-wide —
  // links render but router.push silently no-ops (the symptom #458 band-aided
  // with native <a>). Same hydration-determinism fix #457 applied to the store
  // and InviteCodeBanner; this provider (added in #450) was missed.
  const [mode, setMode] = useState<VerificationMode>("normal");

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "technical" || stored === "normal") {
      setMode(stored);
    }
  }, []);

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
