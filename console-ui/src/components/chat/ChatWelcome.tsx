"use client";

import Link from "next/link";
import { ArrowUpRight, Code2, FileText, Lightbulb, PenLine } from "lucide-react";
import { BloomMark } from "@/components/brand/BloomMark";
import { trackEvent } from "@/lib/google-analytics";

const STARTERS = [
  { label: "Write something", icon: PenLine, prompt: "Help me write a clear, thoughtful message. First, ask me who it’s for and what I want to say." },
  { label: "Work through code", icon: Code2, prompt: "Help me work through a coding problem. Ask me about my goal, the language I’m using, and where I’m stuck." },
  { label: "Explore an idea", icon: Lightbulb, prompt: "Help me explore an idea. Ask me what I’m considering, then help me examine the possibilities and tradeoffs." },
  { label: "Make it clearer", icon: FileText, prompt: "Help me make a piece of writing clearer and more concise while keeping my voice. Ask me to paste the text." },
];

export function ChatWelcome({ authenticated }: { authenticated: boolean }) {
  return (
    <div className="mb-6 text-center message-animate sm:mb-8">
      <BloomMark size={42} className="mx-auto mb-5 text-accent-brand" />
      <h1 className="!font-logo !text-[42px] !font-normal !leading-[1.12] !tracking-[-0.04em] text-ink sm:!text-[54px]">
        {authenticated ? "What are you working on?" : "Darkbloom"}
      </h1>
      <p className="mx-auto mt-4 max-w-md text-sm leading-relaxed text-text-secondary sm:text-[15px]">
        {authenticated ? "Choose a model and start a private conversation." : "Your workspace for private AI. Write, code, and explore with end-to-end encrypted conversations."}
      </p>
      {!authenticated && (
        <div className="mt-5 flex justify-center gap-6 text-xs text-text-secondary">
          <Link href="/models" className="inline-flex items-center gap-1 hover:text-accent-brand">Explore models <ArrowUpRight size={13} /></Link>
          <Link href="/api-console" className="inline-flex items-center gap-1 hover:text-accent-brand">Build with the API <ArrowUpRight size={13} /></Link>
        </div>
      )}
    </div>
  );
}

export function ChatStarters({ onSelect }: { onSelect: (prompt: string) => void }) {
  return (
    <div className="mt-5 flex flex-wrap justify-center gap-2" aria-label="Prompt suggestions">
      {STARTERS.map(({ label, icon: Icon, prompt }) => (
        <button
          key={label}
          type="button"
          onClick={() => {
            trackEvent("suggested_prompt_click", { prompt_label: label });
            onSelect(prompt);
          }}
          className="group flex min-h-10 items-center gap-2 rounded-lg px-3 py-2 text-xs text-text-secondary transition-colors hover:bg-bg-secondary hover:text-text-primary"
        >
          <Icon size={14} className="text-text-tertiary group-hover:text-accent-brand" />
          {label}
        </button>
      ))}
    </div>
  );
}
