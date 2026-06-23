"use client";

import { useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { ChevronRight, Brain } from "lucide-react";

export function ThinkingBlock({
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
          {streaming ? "Thinking..." : "Thinking"}
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
