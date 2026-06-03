"use client";

import { useState } from "react";

// Tiny copy-to-clipboard button. Used for individual emails/ids in tables.
export function CopyButton({
  text,
  title = "Copy",
  className = "",
}: {
  text: string;
  title?: string;
  className?: string;
}) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      // clipboard unavailable (non-secure context) — no-op
    }
  }
  return (
    <button
      type="button"
      onClick={copy}
      title={title}
      aria-label={title}
      className={`text-[var(--text-faint)] hover:text-[var(--accent)] ${className}`}
    >
      {copied ? "✓" : "⧉"}
    </button>
  );
}
