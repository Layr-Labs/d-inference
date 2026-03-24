"use client";

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { TrustBadge } from "./TrustBadge";
import type { Message } from "@/lib/store";
import { User, Bot, Copy, Check } from "lucide-react";
import { useState, useCallback } from "react";

function CodeBlock({
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
      <div className="flex items-center justify-between px-3 py-1.5 bg-bg-tertiary rounded-t-lg border border-b-0 border-border-dim">
        <span className="text-[10px] font-mono text-text-tertiary uppercase tracking-wider">
          {language || "code"}
        </span>
        <button
          onClick={copyCode}
          className="flex items-center gap-1 text-[10px] font-mono text-text-tertiary hover:text-text-secondary transition-colors"
        >
          {copied ? <Check size={10} /> : <Copy size={10} />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre className="!mt-0 !rounded-t-none">
        <code className={className}>{children}</code>
      </pre>
    </div>
  );
}

export function ChatMessage({ message }: { message: Message }) {
  const isUser = message.role === "user";

  return (
    <div className={`message-animate py-5 ${isUser ? "" : ""}`}>
      <div className="max-w-3xl mx-auto px-6">
        <div className="flex gap-4">
          {/* Avatar */}
          <div
            className={`shrink-0 w-7 h-7 rounded-md flex items-center justify-center mt-0.5 ${
              isUser
                ? "bg-accent-purple/15 border border-accent-purple/25"
                : "bg-accent-green/15 border border-accent-green/25"
            }`}
          >
            {isUser ? (
              <User size={13} className="text-accent-purple" />
            ) : (
              <Bot size={13} className="text-accent-green" />
            )}
          </div>

          {/* Content */}
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1.5">
              <span className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
                {isUser ? "You" : "DGInf"}
              </span>
              {message.trust && <TrustBadge trust={message.trust} />}
            </div>

            <div
              className={`prose text-text-primary text-[15px] leading-relaxed ${
                message.streaming ? "streaming-cursor" : ""
              }`}
            >
              <ReactMarkdown
                remarkPlugins={[remarkGfm]}
                components={{
                  code({ className, children, ...props }) {
                    const isInline = !className;
                    if (isInline) {
                      return (
                        <code className={className} {...props}>
                          {children}
                        </code>
                      );
                    }
                    return (
                      <CodeBlock className={className}>{children}</CodeBlock>
                    );
                  },
                  pre({ children }) {
                    return <>{children}</>;
                  },
                }}
              >
                {message.content}
              </ReactMarkdown>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
