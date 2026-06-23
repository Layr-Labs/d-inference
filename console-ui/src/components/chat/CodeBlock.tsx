"use client";

import { useState, useCallback } from "react";
import { Copy, Check } from "lucide-react";

export function CodeBlock({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  const [copied, setCopied] = useState(false);
  const language = className?.replace("language-", "") || "";
  const code = String(children).replace(/\n$/, "");

  const copyCode = useCallback(() => {
    navigator.clipboard.writeText(code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [code]);

  return (
    <div className="relative group my-3">
      {/* Terminal-style header (landing page code block style) */}
      <div className="code-header">
        <div className="code-dot code-dot-r" />
        <div className="code-dot code-dot-y" />
        <div className="code-dot code-dot-g" />
        <span className="ml-2 text-xs text-white/30 font-sans uppercase tracking-wider">
          {language || "code"}
        </span>
        <button
          onClick={copyCode}
          className="ml-auto flex items-center gap-1.5 text-xs font-mono text-white/30 hover:text-white/60 transition-colors"
        >
          {copied ? <Check size={12} /> : <Copy size={12} />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre className="!mt-0 !rounded-t-none">
        <code className={className}>{children}</code>
      </pre>
    </div>
  );
}
