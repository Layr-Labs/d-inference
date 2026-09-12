"use client";

import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { AlertCircle, Check, Copy, Loader2 } from "lucide-react";

interface CodeExampleProps {
  examples: { label: string; language: string; code: string }[];
}

type CopyStatus = "idle" | "copying" | "copied" | "error";

export function CodeExample({ examples }: CodeExampleProps) {
  const [activeTab, setActiveTab] = useState(0);
  const [copyStatus, setCopyStatus] = useState<CopyStatus>("idle");
  const copyAttempt = useRef(0);
  const tabRefs = useRef(new Map<number, HTMLButtonElement | null>());
  const id = useId();
  const activeExample = examples.at(activeTab);

  useEffect(() => {
    if (copyStatus !== "copied") return;
    const timer = setTimeout(() => setCopyStatus("idle"), 2000);
    return () => clearTimeout(timer);
  }, [copyStatus]);

  const selectTab = (index: number) => {
    copyAttempt.current += 1;
    setActiveTab(index);
    setCopyStatus("idle");
  };

  const handleTabKey = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    let nextIndex: number;
    switch (event.key) {
      case "ArrowRight": nextIndex = (index + 1) % examples.length; break;
      case "ArrowLeft": nextIndex = (index - 1 + examples.length) % examples.length; break;
      case "Home": nextIndex = 0; break;
      case "End": nextIndex = examples.length - 1; break;
      default: return;
    }
    event.preventDefault();
    selectTab(nextIndex);
    tabRefs.current.get(nextIndex)?.focus();
  };

  const copyCode = async () => {
    const attempt = ++copyAttempt.current;
    setCopyStatus("copying");
    try {
      await navigator.clipboard.writeText(activeExample?.code ?? "");
      if (copyAttempt.current === attempt) setCopyStatus("copied");
    } catch {
      if (copyAttempt.current === attempt) setCopyStatus("error");
    }
  };

  const { Icon: CopyIcon, label: copyLabel } = copyFeedback(copyStatus);
  if (!activeExample) return null;

  return (
    <div className="min-w-0 overflow-hidden rounded-xl border border-border-dim bg-bg-white">
      <div className="flex flex-wrap items-center justify-between gap-x-2 border-b border-border-dim bg-bg-secondary/50 px-2">
        <div role="tablist" aria-label="Code language" className="flex min-w-0 flex-wrap">
          {examples.map((example, index) => (
            <button
              key={example.label}
              ref={(node) => { tabRefs.current.set(index, node); }}
              id={`${id}-tab-${index}`}
              type="button"
              role="tab"
              aria-selected={index === activeTab}
              aria-controls={`${id}-panel`}
              tabIndex={index === activeTab ? 0 : -1}
              onClick={() => selectTab(index)}
              onKeyDown={(event) => handleTabKey(event, index)}
              className={`min-h-11 border-b-2 px-3 py-2.5 text-xs font-medium transition-colors sm:px-4 ${index === activeTab ? "border-accent-brand text-accent-brand" : "border-transparent text-text-secondary hover:text-text-primary"}`}
            >
              {example.label}
            </button>
          ))}
        </div>
        <button type="button" onClick={copyCode} disabled={copyStatus === "copying"} className="ml-auto flex min-h-11 shrink-0 items-center gap-1.5 px-3 py-2 text-xs font-medium text-text-secondary transition-colors hover:text-text-primary disabled:cursor-wait">
          <CopyIcon size={14} className={copyStatus === "copying" ? "animate-spin" : undefined} />
          <span aria-live="polite">{copyLabel}</span>
        </button>
      </div>
      {copyStatus === "error" && <p role="status" className="flex items-start gap-2 border-b border-border-dim px-4 py-3 text-xs leading-relaxed text-accent-red"><AlertCircle size={14} className="mt-0.5 shrink-0" />Copy failed. Select the code below and copy it manually, or try again.</p>}
      <pre id={`${id}-panel`} role="tabpanel" aria-labelledby={`${id}-tab-${activeTab}`} tabIndex={0} className="max-w-full overflow-x-auto p-4 font-mono text-[13px] leading-relaxed text-text-primary sm:p-5 sm:text-sm"><code>{activeExample.code}</code></pre>
    </div>
  );
}

function copyFeedback(status: CopyStatus) {
  if (status === "copied") return { Icon: Check, label: "Copied" };
  if (status === "copying") return { Icon: Loader2, label: "Copying…" };
  return { Icon: Copy, label: "Copy" };
}
