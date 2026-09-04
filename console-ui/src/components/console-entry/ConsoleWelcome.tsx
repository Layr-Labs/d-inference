"use client";

/* eslint-disable @next/next/no-html-link-for-pages */
import { Moon, Sun } from "lucide-react";
import { BloomMark } from "@/components/brand/BloomMark";
import { useAuthContext } from "@/components/providers/PrivyClientProvider";
import { useTheme } from "@/components/providers/ThemeProvider";
import { useConsoleExperience } from "./ConsoleExperience";
import { WorkspaceChoice } from "./WorkspaceChoice";
import { providerDestination, type ProviderAccount } from "./workspaces";

function providerCopy(account: ProviderAccount) {
  if (account.status === "linked") return {
    title: "Your Macs, at work.", action: "Open your fleet",
    description: `${account.total} ${account.total === 1 ? "Mac linked" : "Macs linked"} · ${account.online} online. ${account.online ? "Check machine health, manage capacity, and track your earnings." : "See what needs attention and bring your machines back online."}`,
  };
  if (account.status === "loading" || account.status === "error") return {
    title: "Earn with your Mac.", action: "Open provider workspace",
    description: "Connect Apple Silicon to the network, or return to your machines and earnings.",
  };
  return { title: "Earn with your Mac.", action: "Set up your first Mac", description: "Put your Apple Silicon Mac to work serving AI. Check the requirements, then get connected." };
}

export function ConsoleWelcome() {
  const { ready, authenticated, login } = useAuthContext();
  const { theme, toggleTheme } = useTheme();
  const { lastWorkspace, chooseWorkspace, providerAccount, retryProviders } = useConsoleExperience();
  const provider = providerCopy(providerAccount);
  return <div className="mx-auto flex min-h-dvh w-full max-w-[1200px] flex-col px-5 sm:px-10">
    <header className="flex min-h-20 shrink-0 items-center justify-between gap-4 border-b border-border-dim sm:min-h-24">
      <a href="/" aria-label="Darkbloom home" className="flex items-center gap-2.5 rounded text-ink"><BloomMark size={30} className="text-accent-brand" /><span className="font-logo text-[32px] tracking-tight" style={{ fontFamily: "var(--font-logo)" }}>Darkbloom</span></a>
      <div className="flex items-center gap-3"><button type="button" onClick={toggleTheme} aria-label={`Switch to ${theme === "light" ? "dark" : "light"} mode`} className="rounded-lg p-2.5 text-text-secondary hover:bg-bg-hover">{theme === "light" ? <Moon size={17} /> : <Sun size={17} />}</button>{ready && !authenticated && <button type="button" onClick={login} className="min-h-10 rounded-lg border border-border-dim px-4 text-sm text-text-primary hover:bg-bg-hover">Sign in</button>}</div>
    </header>
    <div className="mx-auto my-auto w-full max-w-[960px] py-7 sm:py-12">
      <div className="mb-6 text-center sm:mb-11"><h1 className="font-logo text-[36px] font-normal leading-[1.08] tracking-tight text-ink sm:text-[56px]" style={{ fontFamily: "var(--font-logo)" }}>How will you use Darkbloom?</h1><p className="mt-3 text-sm leading-relaxed text-text-secondary sm:mt-4 sm:text-base">Use the network. Power the network. One account for both.</p></div>
      <div className="grid gap-6 sm:grid-cols-2 sm:gap-8">
        <WorkspaceChoice mode="consumer" title="Use AI, your way." description="Chat with open models, explore what they can do, or build with the API." href="/chat" action="Open chat" lastUsed={lastWorkspace === "consumer"} onChoose={() => chooseWorkspace("consumer")}>
          <a href="/api-console" onClick={() => chooseWorkspace("consumer")} className="rounded underline-offset-4 hover:text-accent-brand hover:underline">Building an app? Use the API</a><a href="/models" onClick={() => chooseWorkspace("consumer")} className="rounded underline-offset-4 hover:text-accent-brand hover:underline">Explore models</a>
        </WorkspaceChoice>
        <WorkspaceChoice mode="provider" title={provider.title} description={provider.description} href={providerDestination(providerAccount)} action={provider.action} lastUsed={lastWorkspace === "provider"} onChoose={() => chooseWorkspace("provider")}>
          {providerAccount.status === "linked" ? <a href="/providers/earnings" onClick={() => chooseWorkspace("provider")} className="rounded underline-offset-4 hover:text-accent-brand hover:underline">View your earnings</a> : <a href="/earn" onClick={() => chooseWorkspace("provider")} className="rounded underline-offset-4 hover:text-accent-brand hover:underline">Estimate earning potential</a>}
          {providerAccount.status === "guest" && <button type="button" onClick={login} className="rounded underline-offset-4 hover:text-accent-brand hover:underline">Already providing? Sign in</button>}
          {providerAccount.status === "error" && <span role="status">We couldn’t check your Macs. <button type="button" onClick={retryProviders} className="rounded text-accent-brand underline underline-offset-4">Retry</button></span>}
          {providerAccount.status === "loading" && <span role="status">Checking your workspace…</span>}
        </WorkspaceChoice>
      </div>
      <p className="mt-3 text-center text-xs text-text-tertiary">You can switch workspaces at any time.</p>
    </div>
    <footer className="flex flex-wrap items-center justify-between gap-4 border-t border-border-dim py-6 text-xs text-text-tertiary"><span>Darkbloom console · Public alpha</span><a href="/stats" className="rounded text-text-secondary hover:text-accent-brand">Explore the network</a></footer>
  </div>;
}
