"use client";

import { useEffect, useRef, useState } from "react";
import { Check, Copy, Loader2 } from "lucide-react";

type CopyState = "idle" | "copying" | "copied" | "failed";

function copyFeedback(state: CopyState) {
  if (state === "copying") return { label: "Copying…", icon: Loader2 };
  if (state === "copied") return { label: "Copied", icon: Check };
  return { label: "Copy command", icon: Copy };
}

export function SetupCommand({ command, label }: { command: string; label: string }) {
  const [state, setState] = useState<CopyState>("idle");
  const mounted = useRef(false);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  useEffect(() => {
    if (state !== "copied") return;
    const timer = setTimeout(() => setState("idle"), 2000);
    return () => clearTimeout(timer);
  }, [state]);

  const copy = async () => {
    setState("copying");
    try {
      await navigator.clipboard.writeText(command);
      if (mounted.current) setState("copied");
    } catch {
      if (mounted.current) setState("failed");
    }
  };

  const { label: feedback, icon: Icon } = copyFeedback(state);

  return (
    <div className="overflow-hidden rounded-xl border border-border-dim bg-bg-white">
      <div className="flex items-center justify-between gap-2 border-b border-border-dim bg-bg-secondary/60 px-4">
        <span className="text-xs text-text-secondary">Terminal</span>
        <button
          type="button"
          onClick={copy}
          disabled={state === "copying"}
          aria-label={`${feedback}: ${label}`}
          className="-mr-2 inline-flex min-h-11 items-center gap-2 rounded-md px-2 text-xs font-medium text-accent-brand hover:bg-accent-brand-dim disabled:cursor-wait"
        >
          <Icon aria-hidden size={14} className={state === "copying" ? "animate-spin motion-reduce:animate-none" : undefined} />
          <span aria-live="polite">{feedback}</span>
        </button>
      </div>
      <pre tabIndex={0} aria-label={`${label} command`} className="max-w-full overflow-x-auto p-4 font-mono text-[13px] leading-relaxed text-text-primary"><code>{command}</code></pre>
      {state === "failed" && (
        <p role="status" className="border-t border-border-dim px-4 py-3 text-xs leading-relaxed text-accent-red">
          Couldn’t copy. Select the command and copy it manually, or try again.
        </p>
      )}
    </div>
  );
}
