"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { useToastStore } from "@/hooks/useToast";

export function BaseUrl({ url }: { url: string }) {
  const [copied, setCopied] = useState(false);
  const addToast = useToastStore((state) => state.addToast);

  const copyUrl = async () => {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
    } catch {
      addToast("Unable to copy. Select and copy the URL directly.", "error");
    }
  };

  return (
    <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-border-dim bg-bg-white px-5 py-4">
      <div className="min-w-0">
        <p className="mb-1.5 text-xs font-medium text-text-secondary">Base URL</p>
        <p className="select-all break-all font-mono text-sm text-text-primary">{url}</p>
      </div>
      <button type="button" onClick={() => copyUrl()} className="inline-flex min-h-10 shrink-0 items-center gap-2 rounded-lg px-3 text-sm font-medium text-accent-brand transition-colors hover:bg-accent-brand/5">
        {copied ? <Check size={15} /> : <Copy size={15} />}
        <span aria-live="polite">{copied ? "Copied" : "Copy URL"}</span>
      </button>
    </div>
  );
}
