"use client";

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { TrustBadge } from "./TrustBadge";
import { VerificationPanel } from "./VerificationPanel";
import type { Message } from "@/lib/store";
import { Copy, Check, ChevronRight, Brain, Gauge, Clock, Hash, Sparkles, RotateCcw } from "lucide-react";
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
                   bg-gold-light/50 border-2 border-gold hover:bg-gold-light/70
                   transition-all text-ink group"
      >
        <ChevronRight
          size={14}
          className={`transition-transform duration-200 ${
            expanded ? "rotate-90" : ""
          }`}
        />
        <Brain size={14} className="text-gold" />
        <span className="text-xs font-semibold">
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
        <div className="mt-2 ml-1 pl-3 border-l-2 border-gold/30">
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
      className={`flex items-center gap-2 sm:gap-3 mt-3 py-2 px-2 sm:px-3 rounded-lg text-xs font-mono border-2 flex-wrap ${
        streaming
          ? "bg-teal-light/30 border-teal shadow-sm"
          : "bg-bg-secondary border-border-dim"
      }`}
    >
      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-teal" : "text-text-secondary"
        }`}
      >
        <Gauge size={12} />
        <span className="tabular-nums font-semibold">
          {tps ? tps.toFixed(1) : "\u2014"}
        </span>
        <span className="text-text-tertiary">tok/s</span>
      </span>

      <span className="text-border-subtle">|</span>

      <span
        className={`flex items-center gap-1 ${
          streaming ? "text-gold" : "text-text-secondary"
        }`}
      >
        <Clock size={12} />
        <span className="tabular-nums font-semibold">
          {ttft ? (ttft < 1000 ? `${Math.round(ttft)}ms` : `${(ttft / 1000).toFixed(2)}s`) : "\u2014"}
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
        <span className="ml-auto flex items-center gap-1.5 text-teal">
          <span className="w-1.5 h-1.5 rounded-full bg-teal animate-pulse" />
          <span className="text-xs font-semibold">live</span>
        </span>
      )}
    </div>
  );
}

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
  if (!content) return { thinking: existingThinking || "", content };

  // Always strip thinking tags from content, even when reasoning_content
  // was already extracted server-side. Old providers may leave tags in content.
  let cleaned = content;

  // Strip <think>...</think>
  cleaned = cleaned.replace(/<think>[\s\S]*?<\/think>\s*/g, "");

  // Strip Thinking Process:...</think>
  cleaned = cleaned.replace(/Thinking Process:?[\s\S]*?<\/think>\s*/g, "");

  // Strip <|channel>thought\n...<channel|>
  cleaned = cleaned.replace(/<\|channel>thought[\s\S]*?<channel\|>\s*/g, "");

  // If we already have thinking from the server, return cleaned content
  if (existingThinking) {
    return { thinking: existingThinking, content: cleaned.trimStart() };
  }

  // Otherwise, try to extract thinking from content
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

  // Gemma 4: <|channel>thought\n...<channel|>
  if (trimmed.startsWith("<|channel>thought")) {
    const closeIdx = trimmed.indexOf("<channel|>");
    if (closeIdx !== -1) {
      const thinkStart = trimmed.indexOf("\n") + 1;
      const thinking = trimmed.slice(thinkStart, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 10).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  return { thinking: "", content: cleaned };
}

export function ChatMessage({ message, onRetry }: { message: Message; onRetry?: () => void }) {
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
        <div className="max-w-4xl mx-auto px-3 sm:px-6 flex justify-end">
          <div className="max-w-[90%] sm:max-w-[80%] bg-coral/10 border-2 border-coral/30 rounded-2xl rounded-br-md px-4 py-3">
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
      <div className="max-w-4xl mx-auto px-3 sm:px-6">
        <div className="flex gap-2 sm:gap-3">
          {/* Avatar — hand-drawn style */}
          <div className="shrink-0 w-7 h-7 rounded-lg bg-teal-light border-2 border-teal flex items-center justify-center mt-0.5 hidden sm:flex">
            <Sparkles size={14} className="text-teal" />
          </div>

          {/* Content */}
          <div className="flex-1 min-w-0 overflow-hidden">
            <div className="flex items-center gap-2 mb-2 flex-wrap">
              <span className="text-sm font-semibold text-text-secondary">
                Darkbloom
              </span>
              {message.trust && (
                <>
                  <span className="hidden sm:inline"><TrustBadge trust={message.trust} /></span>
                  <span className="sm:hidden"><TrustBadge trust={message.trust} compact /></span>
                </>
              )}
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

            {onRetry && (
              <button
                onClick={onRetry}
                className={`mt-3 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg
                           text-xs font-semibold transition-all ${
                             message.error
                               ? "bg-coral/10 border-2 border-coral/30 text-coral hover:bg-coral/20 hover:border-coral/50"
                               : "bg-bg-secondary border-2 border-ink/10 text-text-secondary hover:bg-bg-tertiary hover:border-ink/20"
                           }`}
              >
                <RotateCcw size={12} />
                {message.error ? "Retry" : "Regenerate"}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
