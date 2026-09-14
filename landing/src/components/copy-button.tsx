"use client";

import { useState } from "react";

export function CopyButton({
  text,
  label = "Copy",
}: {
  text: string;
  label?: string;
}) {
  const [status, setStatus] = useState("");
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setStatus("Copied");
    } catch {
      setStatus("Select text to copy");
    }
  }
  return (
    <button
      className="copy-button"
      onClick={copy}
      aria-label={label}
      type="button"
    >
      <svg
        width="15"
        height="15"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        aria-hidden="true"
      >
        <rect x="8" y="8" width="12" height="13" rx="2" />
        <path d="M15 8V3H3v13h5" />
      </svg>
      <span aria-live="polite">{status || "Copy"}</span>
    </button>
  );
}
