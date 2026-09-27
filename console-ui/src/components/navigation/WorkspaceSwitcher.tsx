import { useConsoleExperience } from "../console-entry/ConsoleExperience";
import { providerDestination } from "../console-entry/workspaces";

export function WorkspaceSwitcher({ onNavigate }: { onNavigate: () => void }) {
  const { mode, chooseWorkspace, providerAccount } = useConsoleExperience();
  return <nav aria-label="Workspace selection" className="mb-4 mt-4 grid grid-cols-2 gap-1 rounded-lg bg-bg-tertiary p-1">
    {(["consumer", "provider"] as const).map((workspace) => <a key={workspace} href={workspace === "consumer" ? "/chat" : providerDestination(providerAccount)} onClick={() => { chooseWorkspace(workspace); onNavigate(); }} aria-current={mode === workspace ? "true" : undefined} className={`rounded-md px-2 py-2 text-center text-xs transition-colors ${mode === workspace ? "bg-bg-white font-medium text-accent-brand shadow-sm" : "text-text-secondary hover:text-text-primary"}`}>{workspace === "consumer" ? "Consumer" : "Provider"}</a>)}
  </nav>;
}
