"use client";

import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { TrustBadge } from "./TrustBadge";
import { VerificationPanel } from "./VerificationPanel";
import type { Message } from "@/lib/store";
import { User, Bot, Copy, Check, ChevronRight, Brain, Volume2, RotateCcw } from "lucide-react";
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
        className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg bg-accent-amber/8 border border-accent-amber/15 hover:bg-accent-amber/12 transition-all text-accent-amber group"
      >
        <ChevronRight
          size={12}
          className={`transition-transform duration-200 ${
            expanded ? "rotate-90" : ""
          }`}
        />
        <Brain size={12} />
        <span className="text-[11px] font-mono">
          {streaming && !thinking.length
            ? "Thinking..."
            : `Thinking${streaming ? "..." : ""}`}
        </span>
        {!expanded && thinking.length > 0 && (
          <span className="text-[10px] text-text-tertiary ml-1">
            ({thinking.length} chars)
          </span>
        )}
      </button>

      {expanded && (
        <div className="mt-1.5 ml-1 pl-3 border-l-2 border-accent-amber/20">
          <div
            className={`prose text-text-secondary text-[13px] leading-relaxed opacity-80 ${
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

export function ChatMessage({ message, onRetry }: { message: Message; onRetry?: () => void }) {
  const isUser = message.role === "user";
  const hasThinking = !isUser && message.thinking && message.thinking.length > 0;
  const isThinking = message.streaming && !message.content && !!message.thinking;
  const isError = !isUser && !message.streaming && message.content.startsWith("Error:") || message.content.startsWith("Transcription error:") || message.content.startsWith("Connection error:");

  return (
    <div className={`message-animate py-5`}>
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

            {/* Audio player for messages with audio */}
            {message.audioUrl && (
              <div className="flex items-center gap-2 mb-3 px-3 py-2 rounded-lg bg-bg-tertiary border border-border-dim">
                <Volume2 size={14} className="text-accent-purple shrink-0" />
                <audio
                  controls
                  src={message.audioUrl}
                  className="h-8 flex-1"
                  style={{ minWidth: 0 }}
                />
                {message.audioDuration != null && (
                  <span className="text-[10px] font-mono text-text-tertiary shrink-0">
                    {Math.round(message.audioDuration)}s
                  </span>
                )}
              </div>
            )}

            {/* Thinking block */}
            {hasThinking && (
              <ThinkingBlock
                thinking={message.thinking!}
                streaming={isThinking}
              />
            )}

            {/* Verification panel — shown after streaming completes */}
            {message.trust && !message.streaming && (
              <div className="mb-3">
                <VerificationPanel trust={message.trust} />
              </div>
            )}

            {/* Main content */}
            <div
              className={`prose text-text-primary text-[15px] leading-relaxed ${
                message.streaming && !isThinking ? "streaming-cursor" : ""
              }`}
            >
              {message.content ? (
                <ReactMarkdown
                  remarkPlugins={[remarkGfm]}
                  components={markdownComponents}
                >
                  {message.content}
                </ReactMarkdown>
              ) : message.streaming && !hasThinking ? (
                <span className="text-text-tertiary text-sm streaming-cursor" />
              ) : null}
            </div>

            {/* Retry button on error messages */}
            {isError && onRetry && (
              <button
                onClick={onRetry}
                className="mt-2 flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-mono text-text-tertiary hover:text-accent-purple hover:bg-accent-purple/10 border border-border-dim hover:border-accent-purple/30 transition-all"
              >
                <RotateCcw size={12} />
                Retry
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
