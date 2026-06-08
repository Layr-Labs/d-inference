"use client";

// A copyable shell command rendered as an inline pill. Clicking copies and
// flips the icon to a check for 2s. Falls back to a selectable <code> block
// (and execCommand) when the async clipboard API is unavailable, so the
// command is never trapped behind a missing secure context.

import { useState } from "react";
import { Check, Copy } from "lucide-react";

export function CopyCommand({
  command,
  size = "sm",
}: {
  command: string;
  size?: "sm" | "xs";
}) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    let ok = false;
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(command);
        ok = true;
      }
    } catch {
      ok = false;
    }
    if (!ok && typeof document !== "undefined") {
      try {
        const el = document.createElement("textarea");
        el.value = command;
        el.style.position = "fixed";
        el.style.opacity = "0";
        document.body.appendChild(el);
        el.select();
        document.execCommand("copy");
        document.body.removeChild(el);
        ok = true;
      } catch {
        ok = false;
      }
    }
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  };

  const pad = size === "xs" ? "px-2 py-1 text-[11px]" : "px-2.5 py-1.5 text-xs";

  return (
    <button
      type="button"
      onClick={copy}
      title="Copy command"
      className={`focus-ring group inline-flex items-center gap-2 max-w-full rounded-md bg-bg-tertiary hover:bg-bg-hover border border-border-dim/60 font-mono text-text-primary transition-colors ${pad}`}
    >
      <code className="select-all whitespace-pre overflow-x-auto max-w-full">{command}</code>
      {copied ? (
        <Check size={13} className="text-accent-green shrink-0" />
      ) : (
        <Copy size={13} className="text-text-tertiary group-hover:text-text-secondary shrink-0" />
      )}
    </button>
  );
}
