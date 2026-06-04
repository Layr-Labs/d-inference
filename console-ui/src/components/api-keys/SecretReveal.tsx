"use client";

import { useState } from "react";
import { AlertTriangle, Check, Copy, Key } from "lucide-react";
import type { CreatedKey } from "@/lib/api";
import { LABEL_CLS, SECRET_WARNING } from "./constants";

// SecretReveal shows a freshly created/rotated secret exactly once, with an
// option to adopt it as this console's active key.
export function SecretReveal({
  created,
  alreadyConsole,
  onSetConsole,
  onClose,
}: {
  created: CreatedKey;
  alreadyConsole: boolean;
  onSetConsole: () => void;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);
  const [didSet, setDidSet] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(created.key);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-2.5 rounded-lg bg-accent-amber-dim border border-accent-amber/25 px-3.5 py-3">
        <AlertTriangle size={16} className="text-accent-amber shrink-0 mt-0.5" />
        <p className="text-sm text-text-secondary leading-relaxed">{SECRET_WARNING}</p>
      </div>

      <div>
        <label className={LABEL_CLS}>{created.data.name || "API key"}</label>
        <div className="flex items-stretch gap-2">
          <code className="flex-1 min-w-0 break-all rounded-lg bg-bg-primary border border-border-dim px-3 py-2.5 text-xs font-mono text-text-primary">
            {created.key}
          </code>
          <button
            onClick={copy}
            className="shrink-0 px-3 rounded-lg border border-border-dim text-text-secondary hover:bg-bg-hover transition-colors flex items-center gap-1.5 text-xs font-medium"
          >
            {copied ? <Check size={14} className="text-accent-green" /> : <Copy size={14} />}
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>

      {!alreadyConsole && (
        <button
          onClick={() => {
            onSetConsole();
            setDidSet(true);
          }}
          disabled={didSet}
          className="w-full flex items-center justify-center gap-2 py-2.5 rounded-lg border border-border-dim text-sm font-medium text-text-secondary hover:bg-bg-hover transition-colors disabled:opacity-60"
        >
          {didSet ? <Check size={14} className="text-accent-green" /> : <Key size={14} />}
          {didSet ? "Set as this console's key" : "Use as this console's key"}
        </button>
      )}

      <button
        onClick={onClose}
        className="w-full py-2.5 rounded-lg bg-coral text-white text-sm font-semibold hover:opacity-90 transition-all"
      >
        Done
      </button>
    </div>
  );
}
