"use client";

import { X } from "lucide-react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { WeaverTrace } from "@/lib/api";

function groupedScores(weaver: WeaverTrace) {
  return weaver.candidates.map((candidate) => ({
    candidate,
    scores: weaver.verifierScores.filter((score) => score.candidateId === candidate.id),
  }));
}

export function WeaverTraceModal({
  weaver,
  finalContent,
  usage,
  initialTab,
  onClose,
  onSelectTab,
}: {
  weaver: WeaverTrace;
  finalContent: string;
  usage?: { tokenCount?: number; tps?: number; ttft?: number };
  initialTab?: string;
  onClose: () => void;
  onSelectTab: (tab: string) => void;
}) {
  const activeTab = initialTab || weaver.candidates[0]?.id || "verifiers";
  const activeCandidate = weaver.candidates.find((candidate) => candidate.id === activeTab);
  let tabContent;

  if (activeCandidate) {
    tabContent = (
      <div className="h-full overflow-y-auto pr-2">
        <div className="mb-3 flex flex-wrap items-center gap-2 text-xs font-mono text-text-tertiary">
          <span>{activeCandidate.model}</span>
          <span>·</span>
          <span>{activeCandidate.status}</span>
        </div>
        {activeCandidate.error ? (
          <p className="text-sm text-accent-red">{activeCandidate.error}</p>
        ) : (
          <div className="prose text-[14px] leading-relaxed text-text-primary">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>
              {activeCandidate.content || "Waiting for this agent..."}
            </ReactMarkdown>
          </div>
        )}
      </div>
    );
  } else if (activeTab === "verifiers") {
    tabContent = (
      <div className="h-full space-y-4 overflow-y-auto pr-2">
        {groupedScores(weaver).map(({ candidate, scores }) => (
          <div key={candidate.id} className="border-b border-border-dim pb-3 last:border-b-0">
            <div className="mb-2 flex items-center gap-2">
              <span className="text-sm font-semibold text-text-primary">{candidate.label}</span>
              <span className="text-xs font-mono text-text-tertiary">{scores.length} scores</span>
            </div>
            {scores.length ? (
              <div className="space-y-2">
                {scores.map((score, idx) => (
                  <div key={`${score.candidateId}-${score.verifierModel}-${idx}`} className="rounded-lg bg-bg-secondary px-3 py-2">
                    <div className="flex items-center gap-2 text-xs font-mono">
                      <span className="text-coral">{score.score.toFixed(1)}</span>
                      <span className="text-text-tertiary">{score.verifierModel}</span>
                    </div>
                    {score.rationale && (
                      <p className="mt-1 text-sm text-text-secondary">{score.rationale}</p>
                    )}
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-text-tertiary">No verifier scores yet.</p>
            )}
          </div>
        ))}
      </div>
    );
  } else {
    tabContent = (
      <div className="h-full space-y-3 overflow-y-auto pr-2">
        <div className="flex flex-wrap gap-3 text-xs font-mono text-text-tertiary">
          <span>Winner: {weaver.selectedCandidate || "pending"}</span>
          <span>Confidence: {weaver.confidence ? `${Math.round(weaver.confidence * 100)}%` : "pending"}</span>
          <span>Tokens: {usage?.tokenCount ?? 0}</span>
        </div>
        <div className="prose text-[14px] leading-relaxed text-text-primary">
          <ReactMarkdown remarkPlugins={[remarkGfm]}>
            {finalContent || "Final answer pending..."}
          </ReactMarkdown>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink/30 px-3 py-6">
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Weaver trace"
        className="flex h-[min(760px,86vh)] w-full max-w-4xl flex-col rounded-lg border-2 border-border-dim bg-bg-white shadow-xl"
      >
        <div className="flex items-center gap-3 border-b-2 border-border-dim px-4 py-3">
          <div>
            <h3 className="text-sm font-bold text-text-primary">Weaver Trace</h3>
            <p className="text-xs font-mono text-text-tertiary">
              {weaver.candidateCount} agents · {weaver.verifierCount} verifier passes
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close trace"
            className="ml-auto flex h-8 w-8 items-center justify-center rounded-lg text-text-tertiary hover:bg-bg-hover hover:text-text-primary"
          >
            <X size={16} />
          </button>
        </div>

        <div className="flex gap-1 overflow-x-auto border-b-2 border-border-dim px-3 py-2">
          {weaver.candidates.map((candidate) => (
            <button
              key={candidate.id}
              type="button"
              onClick={() => onSelectTab(candidate.id)}
              className={`shrink-0 rounded-md px-3 py-1.5 text-xs font-semibold transition-colors ${
                activeTab === candidate.id
                  ? "bg-coral text-white"
                  : "text-text-secondary hover:bg-bg-hover"
              }`}
            >
              {candidate.label}
            </button>
          ))}
          {["verifiers", "final"].map((tab) => (
            <button
              key={tab}
              type="button"
              onClick={() => onSelectTab(tab)}
              className={`shrink-0 rounded-md px-3 py-1.5 text-xs font-semibold capitalize transition-colors ${
                activeTab === tab
                  ? "bg-coral text-white"
                  : "text-text-secondary hover:bg-bg-hover"
              }`}
            >
              {tab === "verifiers" ? "Verifiers" : "Final"}
            </button>
          ))}
        </div>

        <div className="min-h-0 flex-1 overflow-hidden px-4 py-4">
          {tabContent}
        </div>
      </div>
    </div>
  );
}
