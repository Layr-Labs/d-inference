// Renders a FixAction — the "what can I do" affordance — consistently in the
// card hero and the attention feed: a copy-command pill, a link button, or a
// line of guidance. Shared so the action always looks and behaves the same.

import Link from "next/link";
import { ArrowRight, ExternalLink } from "lucide-react";
import { CopyCommand } from "./gauges/CopyCommand";
import type { FixAction } from "./fixes";

export function FixAffordance({
  fix,
  compact = false,
  showNote = true,
}: {
  fix: FixAction;
  compact?: boolean;
  showNote?: boolean;
}) {
  const note =
    showNote && fix.note ? (
      <span className="text-[11px] text-text-tertiary leading-snug">{fix.note}</span>
    ) : null;

  if (fix.kind === "command" && fix.command) {
    return (
      <div className="flex flex-col items-start gap-1">
        <CopyCommand command={fix.command} size={compact ? "xs" : "sm"} />
        {note}
      </div>
    );
  }

  if (fix.kind === "link" && fix.href) {
    const external = fix.href.startsWith("http");
    const cls =
      "inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-accent-brand/10 text-accent-brand text-xs font-medium hover:bg-accent-brand/15 transition-colors whitespace-nowrap";
    return (
      <div className="flex flex-col items-start gap-1">
        {external ? (
          <a href={fix.href} target="_blank" rel="noopener noreferrer" className={cls}>
            {fix.label} <ExternalLink size={11} />
          </a>
        ) : (
          <Link href={fix.href} className={cls}>
            {fix.label} <ArrowRight size={11} />
          </Link>
        )}
        {note}
      </div>
    );
  }

  // guidance
  return (
    <div className="flex flex-col items-start gap-0.5">
      <span className="text-xs font-medium text-text-secondary">{fix.label}</span>
      {note}
    </div>
  );
}
