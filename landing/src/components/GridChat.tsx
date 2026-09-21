"use client";

import { FormEvent, forwardRef, useEffect, useImperativeHandle, useRef, useState } from "react";
import Image from "next/image";
import { prompts } from "../content/site";

/* R9: the live chat is a self-contained Q&A panel. It owns every piece of
   conversation state and talks only to /api/chat. Nothing in here reads or
   writes scroll position, and nothing on the map reacts to it — the proof
   that a real Mac answered lives inside each reply instead. */

export type GridChatHandle = { focus: () => void };

const CHAT_SESSION_LIMIT = 5;
const CHAT_INPUT_MAX_LENGTH = 180;
const PROMPT_ICONS = ["compass", "layers", "wallet"] as const;

type ChatErrorPayload = { error?: { message?: string } };
type ChatStreamPayload = {
  choices?: Array<{ delta?: { content?: string } }>;
  usage?: { completion_tokens?: number; total_tokens?: number };
  metadata?: {
    provider_public_id?: string;
    provider_chip?: string;
    provider_machine_model?: string;
  };
  error?: { message?: string };
};

type Provider = { mac: string; chip: string; model: string; tokens: number | null };
type ExchangeStatus = "routing" | "connected" | "answer" | "unavailable";
type Exchange = {
  id: number;
  question: string;
  status: ExchangeStatus;
  provider: Provider | null;
  answer: string;
};

function formatTokens(value: number) {
  return new Intl.NumberFormat("en-US").format(value);
}

function normalizePrompt(value: string) {
  return value.trim().toLowerCase().replace(/[^a-z0-9\s]/g, "").replace(/\s+/g, " ");
}

function providerFromHeaders(headers: Headers): Provider {
  const publicId = headers.get("x-darkbloom-provider-id");
  return {
    mac: publicId ? `Mac ${publicId}` : "Mac",
    chip: headers.get("x-darkbloom-provider-chip") ?? "",
    model: headers.get("x-darkbloom-provider-model") ?? "",
    tokens: null,
  };
}

export const GridChat = forwardRef<GridChatHandle, { className?: string }>(function GridChat({ className = "" }, ref) {
  const input = useRef<HTMLInputElement>(null);
  const history = useRef<HTMLDivElement>(null);
  const abort = useRef<AbortController | null>(null);
  const requestId = useRef(0);
  const nextExchangeId = useRef(1);
  const interactionCount = useRef(0);
  const inProgress = useRef(false);
  const [exchanges, setExchanges] = useState<Exchange[]>([]);
  const [selectedPrompt, setSelectedPrompt] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [isResponding, setIsResponding] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [sessionCount, setSessionCount] = useState(0);
  const [isOpen, setIsOpen] = useState(true);

  useImperativeHandle(ref, () => ({
    focus: () => {
      setIsOpen(true);
      requestAnimationFrame(() => input.current?.focus({ preventScroll: true }));
    },
  }), []);

  useEffect(() => () => abort.current?.abort(), []);

  // The dialogue builds from the top of the panel (Figma 71) and, once it
  // outgrows the zone, keeps the newest line in view. This scroll is scoped
  // to the panel's own scroller and never touches the document.
  const latest = exchanges[exchanges.length - 1];
  const latestAnswerLength = latest?.answer.length ?? 0;
  const latestStatus = latest?.status;
  useEffect(() => {
    const node = history.current;
    if (!node) return;
    const frame = requestAnimationFrame(() => {
      node.toggleAttribute("data-overflow", node.scrollHeight > node.clientHeight + 1);
      node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
    });
    return () => cancelAnimationFrame(frame);
  }, [exchanges.length, latestAnswerLength, latestStatus]);

  const limitReached = sessionCount >= CHAT_SESSION_LIMIT;
  const status = notice ?? (limitReached ? `You’ve used all ${CHAT_SESSION_LIMIT} questions for this chat session.` : null);
  const busy = isResponding || limitReached;

  function patchExchange(id: number, patch: Partial<Exchange> | ((exchange: Exchange) => Partial<Exchange>)) {
    setExchanges((current) => current.map((exchange) => (
      exchange.id === id ? { ...exchange, ...(typeof patch === "function" ? patch(exchange) : patch) } : exchange
    )));
  }

  function beginInteraction() {
    if (inProgress.current) {
      setNotice("Please wait for the current response to finish.");
      return false;
    }
    if (interactionCount.current >= CHAT_SESSION_LIMIT) return false;
    inProgress.current = true;
    interactionCount.current += 1;
    setSessionCount(interactionCount.current);
    setIsResponding(true);
    setNotice(null);
    return true;
  }

  async function ask(question: string) {
    if (!beginInteraction()) return;
    const id = nextExchangeId.current++;
    const request = ++requestId.current;
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    setExchanges((current) => [...current, { id, question, status: "routing", provider: null, answer: "" }]);

    let fullAnswer = "";
    let completionTokens: number | null = null;
    try {
      const response = await fetch("/api/chat", {
        method: "POST",
        cache: "no-store",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prompt: question }),
        signal: controller.signal,
      });
      if (!response.ok || !response.body) {
        let message = "Live inference is temporarily unavailable. Please try again.";
        try {
          const payload = (await response.json()) as ChatErrorPayload;
          if (payload.error?.message) message = payload.error.message;
        } catch {
          // Keep the safe fallback for a non-JSON proxy failure.
        }
        patchExchange(id, { status: "unavailable", answer: message });
        return;
      }

      patchExchange(id, { status: "connected", provider: providerFromHeaders(response.headers) });

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      const consumeEvent = (event: string) => {
        const data = event
          .split(/\r?\n/)
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trimStart())
          .join("\n");
        if (!data || data === "[DONE]") return;
        const payload = JSON.parse(data) as ChatStreamPayload;
        if (payload.error?.message) throw new Error("The provider could not complete this response.");
        const content = payload.choices?.[0]?.delta?.content;
        if (content) {
          fullAnswer += content;
          patchExchange(id, { status: "answer", answer: fullAnswer });
        }
        if (typeof payload.usage?.completion_tokens === "number") {
          completionTokens = payload.usage.completion_tokens;
        }
        if (payload.metadata) {
          const metadata = payload.metadata;
          patchExchange(id, (exchange) => ({
            provider: {
              mac: metadata.provider_public_id ? `Mac ${metadata.provider_public_id}` : exchange.provider?.mac ?? "Mac",
              chip: metadata.provider_chip || exchange.provider?.chip || "",
              model: metadata.provider_machine_model || exchange.provider?.model || "",
              tokens: exchange.provider?.tokens ?? null,
            },
          }));
        }
      };

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split(/\r?\n\r?\n/);
        buffer = events.pop() ?? "";
        for (const event of events) consumeEvent(event);
      }
      buffer += decoder.decode();
      if (buffer.trim()) consumeEvent(buffer);

      if (!fullAnswer) throw new Error("The provider returned an empty response.");
      const tokens = completionTokens;
      patchExchange(id, (exchange) => ({
        status: "answer",
        provider: exchange.provider ? { ...exchange.provider, tokens } : exchange.provider,
      }));
    } catch (error) {
      if (controller.signal.aborted || requestId.current !== request) return;
      if (fullAnswer) {
        patchExchange(id, { status: "answer", answer: fullAnswer });
      } else {
        const message = error instanceof Error && error.message
          ? error.message
          : "The live response was interrupted. Please try again.";
        patchExchange(id, { status: "unavailable", answer: message });
      }
    } finally {
      if (requestId.current === request) {
        inProgress.current = false;
        setIsResponding(false);
        if (abort.current === controller) abort.current = null;
      }
    }
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    const question = draft.trim();
    if (!question) return;
    const templateIndex = prompts.findIndex((prompt) => normalizePrompt(prompt.question) === normalizePrompt(question));
    setSelectedPrompt(templateIndex >= 0 ? templateIndex : null);
    setDraft("");
    void ask(templateIndex >= 0 ? prompts[templateIndex].question : question);
  }

  return (
    <section
      className={`chat-layer ${className}`.trim()}
      aria-hidden={!isOpen}
      aria-label="Try the Darkbloom grid"
      data-user-open={isOpen}
      inert={!isOpen}
    >
      <header className="chat-panel-header">
        <p>Try the Darkbloom grid</p>
        <button
          type="button"
          className="chat-close"
          aria-label="Close chat"
          onClick={() => setIsOpen(false)}
        >
          <Image src="/icons/close.svg" alt="" width={8} height={8} />
        </button>
      </header>
      <div className="chat-zone">
        <div className="chat-history" ref={history} aria-live="polite">
          {exchanges.map((exchange) => {
            const provider = exchange.provider;
            const hardware = provider ? [provider.chip, provider.model].filter(Boolean).join(" · ") : "";
            return (
              <div className="chat-exchange" key={exchange.id}>
                <p className="chat-question">{exchange.question}</p>
                <div className={`chat-response-bubble is-${exchange.status}`}>
                  {exchange.status === "routing" && (
                    <p className="chat-provider-proof">Routing to a Mac on the grid<span className="typing-dots" aria-hidden="true">…</span></p>
                  )}
                  {provider && exchange.status !== "unavailable" && (
                    <p className="chat-provider-proof">
                      Connected to {provider.mac}
                      {hardware && <><br />{hardware}</>}
                      {provider.tokens != null && <><br />{formatTokens(provider.tokens)} Tokens generated</>}
                    </p>
                  )}
                  {exchange.answer && (
                    <p className={`chat-answer ${exchange.status === "unavailable" ? "is-unavailable" : ""}`}>{exchange.answer}</p>
                  )}
                </div>
              </div>
            );
          })}
        </div>
        <div className="chat-controls">
          <div className="prompt-list" aria-label="Suggested questions">
            {prompts.slice(0, PROMPT_ICONS.length).map((prompt, index) => (
              <button
                type="button"
                className={selectedPrompt === index ? "is-selected" : ""}
                key={prompt.question}
                disabled={busy}
                onClick={() => {
                  setSelectedPrompt(index);
                  void ask(prompt.question);
                }}
              >
                <Image src={`/icons/${PROMPT_ICONS[index]}.svg`} alt="" width={16} height={16} />
                <span>{prompt.question}</span>
              </button>
            ))}
          </div>
          <form className="prompt-form" onSubmit={submit} aria-busy={isResponding}>
            <label className="sr-only" htmlFor="grid-prompt">Ask Darkbloom something</label>
            <input
              id="grid-prompt"
              name="prompt"
              ref={input}
              value={draft}
              onChange={(event) => {
                setDraft(event.target.value);
                setSelectedPrompt(null);
              }}
              placeholder="Ask something..."
              maxLength={CHAT_INPUT_MAX_LENGTH}
              autoComplete="off"
              disabled={busy}
              aria-describedby={status ? "chat-status" : undefined}
            />
            <button aria-label="Send prompt" type="submit" disabled={busy}>
              <Image src="/icons/send.svg" alt="" width={24} height={24} />
            </button>
          </form>
          {status && (
            <p className="chat-status" id="chat-status" role="status">{status}</p>
          )}
        </div>
      </div>
    </section>
  );
});
