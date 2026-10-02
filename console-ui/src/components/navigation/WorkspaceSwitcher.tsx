import { useConsoleExperience } from "../console-entry/ConsoleExperience";
import { providerDestination } from "../console-entry/workspaces";

export function WorkspaceSwitcher({ onNavigate }: { onNavigate: () => void }) {
  const { mode, chooseWorkspace, providerAccount } = useConsoleExperience();
  return <nav aria-label="Workspace selection" className="mb-5 mt-5 grid grid-cols-2 border-b border-border-dim">
    {(["consumer", "provider"] as const).map((workspace) => <a key={workspace} href={workspace === "consumer" ? "/chat" : providerDestination(providerAccount)} onClick={() => { chooseWorkspace(workspace); onNavigate(); }} aria-current={mode === workspace ? "true" : undefined} className={`workspace-tab px-2 py-3 text-center text-xs transition-colors ${mode === workspace ? "font-medium text-text-primary" : "text-text-secondary hover:text-text-primary"}`}>{workspace === "consumer" ? "Consumer" : "Provider"}</a>)}
  </nav>;
}
