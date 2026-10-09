import { BloomMark } from "@/components/brand/BloomMark";
import { ArrowUp, Cpu } from "lucide-react";
import type { Workspace } from "./workspaces";

/** A small illustration of each workspace, with no invented activity or earnings. */
export function WorkspacePreview({ mode }: { mode: Workspace }) {
  return <div aria-hidden="true" className="hidden h-44 items-center justify-center overflow-hidden sm:flex">
    {mode === "consumer" ? <div className="w-[82%] max-w-[340px] space-y-3 motion-safe:transition-transform motion-safe:duration-200 group-hover:-translate-y-1">
      <div className="ml-auto w-fit rounded-xl rounded-br-sm bg-accent-brand-dim px-4 py-2.5 text-xs text-accent-brand">What can we make together?</div>
      <div className="flex items-center gap-3 px-1"><BloomMark size={21} className="shrink-0 text-accent-brand" /><div className="space-y-2"><div className="h-1.5 w-40 rounded-full bg-accent-brand/25" /><div className="h-1.5 w-28 rounded-full bg-accent-brand/15" /></div></div>
      <div className="flex items-center justify-between rounded-xl border border-border-dim bg-bg-white px-4 py-3 text-xs text-text-tertiary"><span>Ask anything…</span><ArrowUp size={16} className="text-accent-brand" /></div>
    </div> : <div className="relative flex h-36 w-56 items-center justify-center motion-safe:transition-transform motion-safe:duration-200 group-hover:-translate-y-1">
      <div className="absolute inset-x-4 top-0 h-28 rounded-xl border border-accent-brand/25 bg-bg-white p-2"><div className="flex h-full items-center justify-center rounded-md bg-accent-brand-dim"><div className="rounded-xl border border-accent-brand/20 bg-bg-white p-3 text-accent-brand"><Cpu size={32} strokeWidth={1.3} /></div></div></div>
      <div className="absolute bottom-3 h-6 w-1.5 bg-accent-brand/20" /><div className="absolute bottom-2 h-1.5 w-20 rounded-full bg-accent-brand/30" />
    </div>}
  </div>;
}
