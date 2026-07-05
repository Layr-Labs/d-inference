"use client";

import { memo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Sparkles, RotateCcw } from "lucide-react";
import type { Message } from "@/lib/store";
import { parseThinkFromContent } from "@/lib/chat/think-parser";
import { TrustBadge } from "@/components/TrustBadge";
import { VerificationPanel } from "@/components/VerificationPanel";
import { UserMessage } from "./UserMessage";
import { ThinkingBlock } from "./ThinkingBlock";
import { StreamMetrics } from "./StreamMetrics";
import { markdownComponents } from "./markdown";

/** The rendered body of an assistant reply: plain text while streaming, parsed
 *  markdown once complete (perf F7). */
function MessageBody({
  message,
  content,
  hasThinking,
}: {
  message: Message;
  content: string;
  hasThinking: boolean;
}) {
  if (!content) {
    if (message.streaming && !hasThinking) {
      return <span className="text-text-tertiary text-sm streaming-cursor" />;
    }
    return null;
  }
  if (message.streaming) {
    return <p className="whitespace-pre-wrap">{content}</p>;
  }
  return (
    <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
      {content}
    </ReactMarkdown>
  );
}

// `retryable` + an id-keyed `onRetry` keep the retry handler referentially
// stable across renders, so React.memo below actually holds: only the streaming
// message (whose object reference changes) re-renders, not the whole list
// (proposal perf F3).
function ChatMessageImpl({
  message,
  onRetry,
  retryable,
}: {
  message: Message;
  onRetry?: (id: string) => void;
  retryable?: boolean;
}) {
  if (message.role === "user") {
    return <UserMessage message={message} />;
  }

  const parsed = !message.streaming
    ? parseThinkFromContent(message.content, message.thinking)
    : { thinking: message.thinking || "", content: message.content };

  const displayThinking = parsed.thinking;
  const hasThinking = displayThinking.length > 0;
  const isThinking = message.streaming && !message.content && !!message.thinking;

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
              <ThinkingBlock thinking={displayThinking} streaming={isThinking} />
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
              <MessageBody message={message} content={parsed.content} hasThinking={hasThinking} />
            </div>

            {(message.streaming || message.tps) && (
              <StreamMetrics
                tps={message.tps}
                ttft={message.ttft}
                tokenCount={message.tokenCount}
                streaming={message.streaming}
              />
            )}

            {retryable && onRetry && (
              <button
                onClick={() => onRetry(message.id)}
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

export const ChatMessage = memo(ChatMessageImpl);
