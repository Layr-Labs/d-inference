"use client";

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { TrustBadge } from "./TrustBadge";
import { VerificationPanel } from "./VerificationPanel";
import type { Message } from "@/lib/store";
import { Copy, Check, ChevronRight, Brain, Gauge, Clock, Hash, Sparkles } from "lucide-react";
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
      <div className="flex items-center justify-between px-3 py-2 bg-bg-tertiary rounded-t-lg border border-b-0 border-border-dim">
        <span className="text-xs font-mono text-text-tertiary uppercase tracking-wider">
          {language || "code"}
        </span>
        <button
          onClick={copyCode}
          className="flex items-center gap-1.5 text-xs font-mono text-text-tertiary hover:text-text-secondary transition-colors"
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

function ThinkingBlock({
  thinking,
  streaming,
}: {
  thinking: string;
  streaming?: boolean;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="mb-3">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 px-3 py-2 rounded-lg
                   bg-accent-amber/8 hover:bg-accent-amber/12
                   transition-all text-accent-amber group"
      >
        <ChevronRight
          size={14}
          className={`transition-transform duration-200 ${
            expanded ? "rotate-90" : ""
          }`}
        />
        <Brain size={14} />
        <span className="text-xs font-medium">
          {streaming && !thinking.length
            ? "Thinking..."
            : `Thinking${streaming ? "..." : ""}`}
        </span>
        {!expanded && thinking.length > 0 && (
          <span className="text-xs text-text-tertiary ml-1">
            ({thinking.length} chars)
          </span>
        )}
      </button>

      {expanded && (
        <div className="mt-2 ml-1 pl-3 border-l-2 border-accent-amber/20">
          <div
            className={`prose text-text-secondary text-sm leading-relaxed opacity-80 ${
              streaming ? "streaming-cursor" : ""
            }`}
          >
            <ReactMarkdown remarkPlugins={[remarkGfm]}>
              {thinking}
            </ReactMarkdown>
          </div>
        </div>
      )}
    </div>
  );
}

function StreamMetrics({
  tps,
  ttft,
  tokenCount,
  streaming,
}: {
  tps?: number;
  ttft?: number;
  tokenCount?: number;
  streaming?: boolean;
}) {
  if (!tps && !ttft) return null;

  return (
    <div
      className={`flex items-center gap-3 mt-3 py-2 px-3 rounded-lg text-xs font-mono ${
        streaming
          ? "bg-accent-green/8 shadow-sm"
          : "bg-bg-secondary"
      }`}
    >
      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-accent-green" : "text-text-secondary"
        }`}
      >
        <Gauge size={12} />
        <span className="tabular-nums font-semibold">
          {tps ? tps.toFixed(1) : "—"}
        </span>
        <span className="text-text-tertiary">tok/s</span>
      </span>

      <span className="text-border-subtle">|</span>

      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-accent-amber" : "text-text-secondary"
        }`}
      >
        <Clock size={12} />
        <span className="tabular-nums font-semibold">
          {ttft ? (ttft < 1000 ? `${Math.round(ttft)}ms` : `${(ttft / 1000).toFixed(2)}s`) : "—"}
        </span>
        <span className="text-text-tertiary">TTFT</span>
      </span>

      <span className="text-border-subtle">|</span>

      <span className="flex items-center gap-1 text-text-secondary">
        <Hash size={12} />
        <span className="tabular-nums font-semibold">
          {tokenCount || 0}
        </span>
        <span className="text-text-tertiary">tokens</span>
      </span>

      {streaming && (
        <span className="ml-auto flex items-center gap-1.5 text-accent-green">
          <span className="w-1.5 h-1.5 rounded-full bg-accent-green animate-pulse" />
          <span className="text-xs">live</span>
        </span>
      )}
    </div>
  );
}

/* eslint-disable @typescript-eslint/no-explicit-any */
const markdownComponents: any = {
  code({ className, children, ...props }: any) {
    const isInline = !className;
    if (isInline) {
      return (
        <code className={className} {...props}>
          {children}
        </code>
      );
    }
    return <CodeBlock className={className}>{children}</CodeBlock>;
  },
  pre({ children }: any) {
    return <>{children}</>;
  },
};

function parseThinkFromContent(content: string, existingThinking?: string): { thinking: string; content: string } {
  if (existingThinking || !content) return { thinking: existingThinking || "", content };

  const trimmed = content.trimStart();

  if (trimmed.startsWith("<think>")) {
    const closeIdx = trimmed.indexOf("</think>");
    if (closeIdx !== -1) {
      const thinking = trimmed.slice(7, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 8).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  if (trimmed.startsWith("Thinking Process:") || trimmed.startsWith("Thinking Process\n")) {
    const closeIdx = trimmed.indexOf("</think>");
    if (closeIdx !== -1) {
      const thinkStart = trimmed.indexOf(":") !== -1 && trimmed.indexOf(":") < 20
        ? trimmed.indexOf(":") + 1
        : trimmed.indexOf("\n") + 1;
      const thinking = trimmed.slice(thinkStart, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 8).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  return { thinking: "", content };
}

export function ChatMessage({ message }: { message: Message }) {
  const isUser = message.role === "user";

  const parsed = !isUser && !message.streaming
    ? parseThinkFromContent(message.content, message.thinking)
    : { thinking: message.thinking || "", content: message.content };

  const displayContent = parsed.content;
  const displayThinking = parsed.thinking;

  const hasThinking = !isUser && displayThinking.length > 0;
  const isThinking = message.streaming && !message.content && !!message.thinking;

  if (isUser) {
    return (
      <div className="message-animate py-4">
        <div className="max-w-4xl mx-auto px-6 flex justify-end">
          <div className="max-w-[80%] bg-bg-elevated rounded-2xl rounded-br-md px-4 py-3">
            <p className="text-[15px] text-text-primary leading-relaxed whitespace-pre-wrap">
              {message.content}
            </p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="message-animate py-4">
      <div className="max-w-4xl mx-auto px-6">
        <div className="flex gap-3">
          {/* Avatar */}
          <div className="shrink-0 w-7 h-7 rounded-lg bg-accent-brand/10 flex items-center justify-center mt-0.5">
            <Sparkles size={14} className="text-accent-brand" />
          </div>

          {/* Content */}
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-2">
              <span className="text-xs font-medium text-text-tertiary">
                EigenInference
              </span>
              {message.trust && <TrustBadge trust={message.trust} />}
            </div>

            {hasThinking && (
              <ThinkingBlock
                thinking={displayThinking}
                streaming={isThinking}
              />
            )}

            {message.trust && !message.streaming && (
              <div className="mb-3">
                <VerificationPanel trust={message.trust} />
              </div>
            )}

            <div
              className={`prose text-text-primary text-[15px] leading-relaxed ${
                message.streaming && !isThinking ? "streaming-cursor" : ""
              }`}
            >
              {displayContent ? (
                <ReactMarkdown
                  remarkPlugins={[remarkGfm]}
                  components={markdownComponents}
                >
                  {displayContent}
                </ReactMarkdown>
              ) : message.streaming && !hasThinking ? (
                <span className="text-text-tertiary text-sm streaming-cursor" />
              ) : null}
            </div>

            {(message.streaming || message.tps) && (
              <StreamMetrics
                tps={message.tps}
                ttft={message.ttft}
                tokenCount={message.tokenCount}
                streaming={message.streaming}
              />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
