import { Fragment, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { ArrowDown, Brain, Check, ChevronRight, Copy, Info, TriangleAlert } from 'lucide-react';
import { api } from '../../useBackend';
import { inked, PixelLoader, SweepText, type Ink } from './Indicators';
import type { LiveAnswer } from './store';
import type { Conversation, StoredMessage } from './storage';
import { fixed, grouped, parseBlocks, parseInline, proseLine, type Block } from './text';
import styles from './chat.module.css';

const cx = (...names: (string | false | undefined)[]) => names.filter(Boolean).join(' ');

// Re-renders every `ms` while `active`, for live seconds.
function useTicker(active: boolean, ms = 1000) {
  const [, setTick] = useState(0);
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(() => setTick((tick) => tick + 1), ms);
    return () => clearInterval(timer);
  }, [active, ms]);
}

// The messages, pinned to the bottom while you are there; a Latest button when you have scrolled
// up. A chat opened from the list starts at its end and appears as it is.
export function MessageList({
  conversation,
  live,
  fresh,
  reduced,
  names,
}: {
  conversation: Conversation;
  live: Readonly<Record<string, LiveAnswer>>;
  fresh: ReadonlySet<string>;
  reduced: boolean;
  names: (model: string | undefined) => string | undefined;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);
  const [nearBottom, setNearBottom] = useState(true);
  const lastQuestion = conversation.messages
    .filter((message) => message.role === 'user')
    .at(-1)?.id;
  const toBottom = (smooth: boolean) => {
    const element = scroller.current;
    if (!element) return;
    pinned.current = true;
    setNearBottom(true);
    if (smooth && typeof element.scrollTo === 'function')
      element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' });
    else element.scrollTop = element.scrollHeight;
  };
  // A new chat, or a new question, starts at the end.
  useLayoutEffect(() => toBottom(false), [conversation.id, lastQuestion]);
  // While pinned, every change keeps the newest text in view.
  useLayoutEffect(() => {
    const element = scroller.current;
    if (element && pinned.current) element.scrollTop = element.scrollHeight;
  });
  const onScroll = () => {
    const element = scroller.current;
    if (!element) return;
    const near = element.scrollHeight - element.scrollTop - element.clientHeight < 48;
    pinned.current = near;
    if (near !== nearBottom) setNearBottom(near);
  };
  return (
    <>
      <div ref={scroller} className={styles.scroller} onScroll={onScroll}>
        <div className={styles.messages}>
          {conversation.messages.map((message) =>
            message.role === 'user' ? (
              <Question key={message.id} message={message} fresh={fresh.has(message.id)} />
            ) : (
              <Answer
                key={message.id}
                message={message}
                live={live[message.id]}
                fresh={fresh.has(message.id)}
                reduced={reduced}
                name={names(message.model)}
              />
            ),
          )}
        </div>
      </div>
      {!nearBottom && (
        <button
          type="button"
          className={styles.latest}
          onClick={() => toBottom(!reduced)}
          aria-label="Scroll to the latest message"
        >
          <ArrowDown size={13} strokeWidth={1.8} /> Latest
        </button>
      )}
    </>
  );
}

// Your words: a quiet blue-tinted slab on the right.
function Question({ message, fresh }: { message: StoredMessage; fresh: boolean }) {
  return (
    <p className={cx(styles.question, fresh && styles.enter)}>
      <span className={styles.srOnly}>You: </span>
      {message.content}
    </p>
  );
}

// The model's reply: plain text on the canvas, with its reasoning above and its actions below.
function Answer({
  message,
  live,
  fresh,
  reduced,
  name,
}: {
  message: StoredMessage;
  live?: LiveAnswer;
  fresh: boolean;
  reduced: boolean;
  name?: string;
}) {
  const streaming = !!live;
  const thinking = streaming && !message.content;
  // Before the first token: the model is reading the prompt.
  const reading = thinking && !message.reasoning;
  // Once the answer is done its newest glyphs still reach full ink, over 0.6 s.
  const [settling, setSettling] = useState(false);
  const wasStreaming = useRef(streaming);
  useEffect(() => {
    if (wasStreaming.current && !streaming && !reduced) {
      setSettling(true);
      const timer = setTimeout(() => setSettling(false), 650);
      wasStreaming.current = streaming;
      return () => clearTimeout(timer);
    }
    wasStreaming.current = streaming;
  }, [streaming, reduced]);
  const ink: Ink | undefined =
    (streaming || settling) && !reduced
      ? { end: message.content.length, glyphs: 28, settling: !streaming }
      : undefined;
  return (
    <article
      className={cx(styles.answer, fresh && styles.enter)}
      aria-label={name ? `Answer from ${name}` : 'Answer'}
      aria-busy={streaming || undefined}
    >
      {reading ? (
        <div className={styles.status} role="status" aria-label="Reading your message">
          <PixelLoader size={11} />
          <SweepText>Reading</SweepText>
        </div>
      ) : (
        (message.reasoning || thinking) && (
          <Reasoning message={message} live={live} reduced={reduced} />
        )
      )}
      {message.content && <Reply text={message.content} ink={ink} />}
      {message.error && (
        <p className={styles.error} role={fresh ? 'alert' : undefined}>
          <TriangleAlert size={14} strokeWidth={1.8} aria-hidden="true" />
          <span>{message.error}</span>
        </p>
      )}
      {!streaming && <Actions message={message} name={name} />}
    </article>
  );
}

// "Thinking N s" while it reasons, with the last lines of its reasoning drifting up; "Thought for
// N s" afterwards, which opens to the reasoning.
function Reasoning({
  message,
  live,
  reduced,
}: {
  message: StoredMessage;
  live?: LiveAnswer;
  reduced: boolean;
}) {
  const [open, setOpen] = useState(false);
  const panel = useId();
  const thinking = !!live && !message.content;
  useTicker(thinking);
  const reasoning = message.reasoning ?? '';
  const seconds = thinking
    ? Math.max(0, Math.floor((Date.now() - (live?.reasoning_started ?? Date.now())) / 1000))
    : (message.thinking_ms ?? 0) / 1000;
  const tail = thinking && !open && reasoning ? lastLines(reasoning) : '';
  return (
    <div className={styles.reasoning}>
      <button
        type="button"
        className={styles.disclosure}
        aria-expanded={open}
        aria-controls={open ? panel : undefined}
        onClick={() => setOpen(!open)}
      >
        {thinking ? (
          <>
            <PixelLoader size={11} />
            <SweepText>Thinking</SweepText>
            <span className={styles.seconds}>{seconds} s</span>
          </>
        ) : (
          <>
            <Brain size={15} strokeWidth={1.55} aria-hidden="true" />
            <span>
              {message.thinking_ms !== undefined ? `Thought for ${fixed(seconds)} s` : 'Reasoning'}
            </span>
          </>
        )}
        <ChevronRight
          size={12}
          strokeWidth={1.8}
          className={styles.chevron}
          data-open={open || undefined}
          aria-hidden="true"
        />
      </button>
      {open && (
        <div id={panel} className={styles.thoughts}>
          {reasoning || '…'}
        </div>
      )}
      {tail && (
        <div className={styles.thoughtTail} aria-hidden="true">
          <span>
            {inked(
              tail,
              reasoning.length - tail.length,
              reduced ? undefined : { end: reasoning.length, glyphs: 40 },
            )}
          </span>
        </div>
      )}
    </div>
  );
}

// While collapsed and live, only the newest few lines of reasoning.
function lastLines(text: string) {
  const lines = text.split('\n').slice(-3).join('\n');
  return lines.length > 320 ? lines.slice(-320) : lines;
}

// A reply: prose with a little inline styling, and fenced code as monospace blocks.
function Reply({ text, ink }: { text: string; ink?: Ink }) {
  const blocks = useMemo(() => parseBlocks(text), [text]);
  return (
    <div className={cx(styles.reply, ink?.settling && styles.settle)}>
      {blocks.map((block) =>
        block.kind === 'code' ? (
          <CodeBlock key={`code-${block.start}`} block={block} ink={ink} />
        ) : (
          <Prose key={`text-${block.start}`} block={block} ink={ink} />
        ),
      )}
    </div>
  );
}

function Prose({ block, ink }: { block: Extract<Block, { kind: 'text' }>; ink?: Ink }) {
  let offset = block.start;
  return (
    <p className={styles.prose}>
      {block.text.split('\n').map((line, index) => {
        const parsed = proseLine(line, offset);
        offset += line.length + 1;
        const spans = parseInline(parsed.text, parsed.start).map((span) => {
          const text = inked(span.text, span.start, ink);
          if (span.kind === 'code')
            return (
              <code key={span.start} className={styles.inlineCode}>
                {text}
              </code>
            );
          if (span.kind === 'strong') return <strong key={span.start}>{text}</strong>;
          if (span.kind === 'em') return <em key={span.start}>{text}</em>;
          return <Fragment key={span.start}>{text}</Fragment>;
        });
        return (
          <Fragment key={parsed.start}>
            {index > 0 && '\n'}
            {parsed.kind === 'heading' ? (
              <strong className={styles.heading}>{spans}</strong>
            ) : parsed.kind === 'bullet' ? (
              <>
                {parsed.indent}
                <span className={styles.bullet} aria-hidden="true">
                  •{' '}
                </span>
                {spans}
              </>
            ) : (
              spans
            )}
          </Fragment>
        );
      })}
    </p>
  );
}

function CodeBlock({ block, ink }: { block: Extract<Block, { kind: 'code' }>; ink?: Ink }) {
  return (
    <div className={styles.code}>
      <div className={styles.codeBar}>
        <span>{block.language || 'Code'}</span>
        {!block.open && <CopyButton text={block.text} label="Copy code" />}
      </div>
      <pre
        role="region"
        tabIndex={0}
        aria-label={block.language ? `${block.language} code` : 'Code'}
      >
        <code>{inked(block.text, block.start, ink)}</code>
      </pre>
    </div>
  );
}

// Copy, with the icon swapping to a check for 1.5 s.
function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');
  useEffect(() => {
    if (state === 'idle') return;
    const timer = setTimeout(() => setState('idle'), state === 'copied' ? 1500 : 2500);
    return () => clearTimeout(timer);
  }, [state]);
  const copy = async () => {
    try {
      if (!api) throw new Error('No clipboard');
      await api.copy(text);
      setState('copied');
    } catch {
      setState('failed');
    }
  };
  return (
    <button
      type="button"
      className={styles.iconButton}
      data-copied={state === 'copied' || undefined}
      aria-label={state === 'copied' ? 'Copied' : label}
      title={label}
      onClick={() => void copy()}
    >
      <span className={styles.copyIcons} aria-hidden="true">
        <Copy size={15} strokeWidth={1.55} />
        <Check size={15} strokeWidth={1.8} />
      </span>
      {state === 'failed' && (
        <span className={styles.copyFailed} role="status">
          Couldn’t copy
        </span>
      )}
    </button>
  );
}

// Below a finished answer: copy, its details, and how it ended when not on its own.
function Actions({ message, name }: { message: StoredMessage; name?: string }) {
  const [details, setDetails] = useState(false);
  const stats = statsLine(message, name);
  return (
    <div className={styles.footer}>
      <div className={styles.actions}>
        {(message.content || message.reasoning) && (
          <CopyButton text={message.content || message.reasoning || ''} />
        )}
        {stats && (
          <button
            type="button"
            className={styles.iconButton}
            aria-label={details ? 'Hide details' : 'Show details'}
            aria-pressed={details}
            onClick={() => setDetails(!details)}
          >
            <Info size={15} strokeWidth={1.55} />
          </button>
        )}
        {message.finish === 'length' && (
          <span className={styles.badge} data-tone="caution">
            Reached the length limit
          </span>
        )}
        {message.finish === 'cancelled' && <span className={styles.badge}>Stopped</span>}
      </div>
      {details && stats && <p className={styles.stats}>{stats}</p>}
    </div>
  );
}

// "Qwen 3.8 27B · 1,204 tokens · 42.1 tok/s · first token 0.84 s · 312 in"
export function statsLine(message: StoredMessage, name?: string) {
  if (!message.tokens) return undefined;
  const parts = [name, `${grouped(message.tokens)} tokens`];
  if (message.duration_ms && message.duration_ms > 100)
    parts.push(`${fixed(message.tokens / (message.duration_ms / 1000))} tok/s`);
  if (message.first_token_ms !== undefined)
    parts.push(`first token ${fixed(message.first_token_ms / 1000, 2)} s`);
  if (message.prompt_tokens) parts.push(`${grouped(message.prompt_tokens)} in`);
  return parts.filter(Boolean).join(' · ');
}
