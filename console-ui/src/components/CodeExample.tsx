"use client";

import { useState, useCallback } from "react";
import { Copy, Check } from "lucide-react";

interface CodeExampleProps {
  examples: { label: string; language: string; code: string }[];
}

export function CodeExample({ examples }: CodeExampleProps) {
  const [activeTab, setActiveTab] = useState(0);
  const [copied, setCopied] = useState(false);

  const copyCode = useCallback(() => {
    navigator.clipboard.writeText(examples[activeTab].code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [examples, activeTab]);

  return (
    <div className="rounded-xl overflow-hidden bg-bg-tertiary shadow-sm">
      <div className="flex items-center justify-between border-b border-border-dim">
        <div className="flex">
          {examples.map((ex, i) => (
            <button
              key={ex.label}
              onClick={() => setActiveTab(i)}
              className={`px-4 py-2.5 text-xs font-medium transition-colors ${
                i === activeTab
                  ? "text-accent-brand border-b-2 border-accent-brand bg-bg-tertiary"
                  : "text-text-tertiary hover:text-text-secondary"
              }`}
            >
              {ex.label}
            </button>
          ))}
        </div>
        <button
          onClick={copyCode}
          className="flex items-center gap-1.5 px-3 py-2 text-xs text-text-tertiary hover:text-text-secondary transition-colors"
        >
          {copied ? <Check size={12} /> : <Copy size={12} />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre className="p-4 overflow-x-auto text-sm font-mono text-text-primary leading-relaxed">
        <code>{examples[activeTab].code}</code>
      </pre>
    </div>
  );
}
