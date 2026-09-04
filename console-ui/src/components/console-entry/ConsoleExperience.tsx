"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { STORAGE_KEYS } from "@/lib/constants";
import { useStore } from "@/lib/store";
import { useProviderAccount } from "./useProviderAccount";
import { workspaceForPath, type Workspace, type ProviderAccount } from "./workspaces";

type ConsoleExperience = {
  mode: Workspace;
  lastWorkspace: Workspace | null;
  chooseWorkspace: (mode: Workspace) => void;
  providerAccount: ProviderAccount;
  retryProviders: () => void;
};

const ExperienceContext = createContext<ConsoleExperience>({
  mode: "consumer", lastWorkspace: null, chooseWorkspace: () => {},
  providerAccount: { status: "guest", total: 0, online: 0 }, retryProviders: () => {},
});

export function ConsoleExperienceProvider({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const routeMode = workspaceForPath(pathname);
  const [lastWorkspace, setLastWorkspace] = useState<Workspace | null>(null);
  const chooseWorkspace = useCallback((mode: Workspace) => {
    setLastWorkspace(mode);
    if (window.innerWidth < 640) useStore.getState().setSidebarOpen(false);
    try { localStorage.setItem(STORAGE_KEYS.workspace, mode); } catch { /* Navigation still works without storage. */ }
  }, []);

  useEffect(() => {
    try {
      const saved = localStorage.getItem(STORAGE_KEYS.workspace);
      if (saved === "consumer" || saved === "provider") setLastWorkspace(saved);
    } catch { /* Use the route when storage is unavailable. */ }
  }, []);
  useEffect(() => { if (routeMode) chooseWorkspace(routeMode); }, [routeMode, chooseWorkspace]);

  const mode = routeMode ?? lastWorkspace ?? "consumer";
  const { account, retry } = useProviderAccount(pathname === "/" || mode === "provider");
  return <ExperienceContext.Provider value={{ mode, lastWorkspace, chooseWorkspace, providerAccount: account, retryProviders: retry }}>{children}</ExperienceContext.Provider>;
}

export const useConsoleExperience = () => useContext(ExperienceContext);
