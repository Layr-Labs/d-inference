import { ArrowRight } from "lucide-react";
import type { ReactNode } from "react";
import { WorkspacePreview } from "./WorkspacePreview";
import type { Workspace } from "./workspaces";

type Props = {
  mode: Workspace; title: string; description: string; href: string; action: string;
  lastUsed: boolean; onChoose: () => void; children: ReactNode;
};

export function WorkspaceChoice({ mode, title, description, href, action, lastUsed, onChoose, children }: Props) {
  return <section className="flex min-w-0 flex-col">
    <a href={href} onClick={onChoose} className="group flex flex-1 flex-col rounded-2xl border border-border-dim bg-bg-white p-5 transition-colors hover:border-accent-brand/40 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent-brand sm:p-8" aria-label={`${mode === "consumer" ? "Consumer" : "Provider"}: ${action}`}>
      <div className="flex items-center justify-between gap-3 text-xs"><span className="font-medium text-accent-brand">{mode === "consumer" ? "Consumer" : "Provider"}</span>{lastUsed && <span className="text-text-tertiary">Last workspace</span>}</div>
      <WorkspacePreview mode={mode} />
      <h2 className="mt-3 font-logo text-[30px] font-normal leading-tight tracking-tight text-ink sm:text-[34px]" style={{ fontFamily: "var(--font-logo)" }}>{title}</h2>
      <p className="mt-3 max-w-sm text-sm leading-relaxed text-text-secondary">{description}</p>
      <div className="mt-auto flex items-center justify-between gap-3 pt-5 text-sm font-medium text-accent-brand sm:pt-8"><span>{action}</span><ArrowRight size={18} className="motion-safe:transition-transform group-hover:translate-x-1" /></div>
    </a>
    <div className="flex flex-wrap items-start gap-x-5 gap-y-2 px-1 pt-3 text-xs leading-relaxed text-text-secondary sm:min-h-16 sm:pt-4">{children}</div>
  </section>;
}
