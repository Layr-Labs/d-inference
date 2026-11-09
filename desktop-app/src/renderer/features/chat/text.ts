// Text logic for the chat page, free of React so it is unit tested directly: fenced code blocks
// and a little inline styling in replies (no Markdown dependency), titles, date groups, the
// launch line, and how a model is named.
import type { ChatModel } from '../../../shared/chat';

// A run of a reply: prose, or a fenced code block. `start` is the offset of its first character
// in the reply, so streamed text can settle by its distance from the end.
export type Block =
  | { kind: 'text'; text: string; start: number }
  | { kind: 'code'; text: string; start: number; language: string; open: boolean };

const fencePattern = /^ {0,3}(`{3,}|~{3,})[ \t]*([^\s`]*)/;

// Splits a reply into prose and fenced code blocks (``` or ~~~). A fence still open while the
// answer streams is a code block up to the end.
export function parseBlocks(source: string): Block[] {
  const blocks: Block[] = [];
  let offset = 0;
  let prose: number | undefined;
  let code: { start: number; fence: string; language: string } | undefined;
  const pushProse = (end: number) => {
    if (prose === undefined) return;
    let start = prose;
    while (start < end && source[start] === '\n') start++;
    const text = source.slice(start, end).replace(/\s+$/, '');
    if (text) blocks.push({ kind: 'text', text, start });
    prose = undefined;
  };
  for (const line of source.split('\n')) {
    const lineStart = offset;
    offset += line.length + 1;
    const fence = fencePattern.exec(line);
    if (code) {
      const closes =
        fence &&
        fence[1][0] === code.fence[0] &&
        fence[1].length >= code.fence.length &&
        line.trim() === fence[1];
      if (closes) {
        blocks.push({
          kind: 'code',
          text: source.slice(code.start, Math.max(code.start, lineStart - 1)),
          start: code.start,
          language: code.language,
          open: false,
        });
        code = undefined;
      }
      continue;
    }
    if (fence) {
      pushProse(Math.max(0, lineStart - 1));
      code = { start: Math.min(offset, source.length), fence: fence[1], language: fence[2] };
      continue;
    }
    prose ??= lineStart;
  }
  if (code)
    blocks.push({
      kind: 'code',
      text: source.slice(code.start),
      start: code.start,
      language: code.language,
      open: true,
    });
  else pushProse(source.length);
  return blocks;
}

// A piece of one prose line: plain, `code`, **strong** or *emphasis*.
export interface Span {
  kind: 'text' | 'code' | 'strong' | 'em';
  text: string;
  start: number;
}

const inlinePattern =
  /`([^`\n]+)`|\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*|(?<![*\w])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![*\w])|(?<![_\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![_\w])/g;

export function parseInline(text: string, start = 0): Span[] {
  const spans: Span[] = [];
  let last = 0;
  for (const match of text.matchAll(inlinePattern)) {
    const index = match.index ?? 0;
    if (index > last)
      spans.push({ kind: 'text', text: text.slice(last, index), start: start + last });
    const [whole, code, strong, star, underscore] = match;
    const inner = code ?? strong ?? star ?? underscore ?? '';
    const marker = strong !== undefined ? 2 : 1;
    spans.push({
      kind: code !== undefined ? 'code' : strong !== undefined ? 'strong' : 'em',
      text: inner,
      start: start + index + marker,
    });
    last = index + whole.length;
  }
  if (last < text.length) spans.push({ kind: 'text', text: text.slice(last), start: start + last });
  return spans;
}

// One prose line: a heading (`#` to `######`) loses its marks, a bullet (`-`, `*`, `+`) becomes
// a dot; anything else is plain. `start` is where its text begins in the reply.
export function proseLine(line: string, start: number) {
  const heading = /^(#{1,6})\s+/.exec(line);
  if (heading)
    return {
      kind: 'heading' as const,
      text: line.slice(heading[0].length),
      start: start + heading[0].length,
    };
  const bullet = /^(\s*)[-*+]\s+/.exec(line);
  if (bullet)
    return {
      kind: 'bullet' as const,
      indent: bullet[1],
      text: line.slice(bullet[0].length),
      start: start + bullet[0].length,
    };
  return { kind: 'plain' as const, text: line, start };
}

// A chat's title: the first line of its first message, at most 42 characters.
export function chatTitle(prompt: string) {
  const line = prompt.trim().split('\n')[0]?.trim() || 'New chat';
  return line.length > 42 ? `${line.slice(0, 42).trimEnd()}…` : line;
}

const day = 86_400_000;
const groupTitles = ['Today', 'Yesterday', 'Previous 7 days', 'Earlier'] as const;

// Today / Yesterday / Previous 7 days / Earlier, newest first, by each chat's last change.
export function dateGroups<T extends { updated_at: number }>(items: T[], now = Date.now()) {
  const midnight = new Date(now);
  midnight.setHours(0, 0, 0, 0);
  const today = midnight.getTime();
  const bucket = (time: number) => {
    const at = new Date(time);
    at.setHours(0, 0, 0, 0);
    const days = Math.round((today - at.getTime()) / day);
    return days < 1 ? 0 : days === 1 ? 1 : days <= 7 ? 2 : 3;
  };
  const sorted = [...items].sort((a, b) => b.updated_at - a.updated_at);
  return groupTitles
    .map((title, index) => ({
      title,
      items: sorted.filter((item) => bucket(item.updated_at) === index),
    }))
    .filter((group) => group.items.length > 0);
}

// The launch lines under the mark: one per launch, in order, so the idea comes from a few angles
// without repeats. They speak of this Mac, so they show only for a model it serves.
export const taglines = [
  'Own your intelligence.',
  'Your AI. Your Mac. Nobody else’s.',
  'Private by design, not by promise.',
  'Intelligence that stays home.',
  'Own your AI.',
  'No cloud. No account. Just yours.',
  'Think out loud. Nobody’s listening.',
  'Your questions never leave this Mac.',
];

const taglineKey = 'darkbloom.chat.tagline';

// Advances once per launch (the first read in this window), remembered across launches.
export function launchTagline(storage: Pick<Storage, 'getItem' | 'setItem'> | undefined) {
  let index = 0;
  try {
    index = Number.parseInt(storage?.getItem(taglineKey) ?? '0', 10) || 0;
    storage?.setItem(taglineKey, String((index + 1) % taglines.length));
  } catch {
    /* A launch without storage starts at the first line. */
  }
  return taglines[((index % taglines.length) + taglines.length) % taglines.length];
}

// Where a model runs, as the list's `owned_by` says.
export type ModelPlace = 'this-mac' | 'my-macs' | 'darkbloom';
export const modelPlace = (model: Pick<ChatModel, 'owned_by'> | undefined): ModelPlace =>
  model?.owned_by === 'my-macs' || model?.owned_by === 'darkbloom' ? model.owned_by : 'this-mac';

export const placeLabels: Record<ModelPlace, string> = {
  'this-mac': 'This Mac',
  'my-macs': 'Your Macs',
  darkbloom: 'Darkbloom network',
};

// Under the mark: which model answers, and where.
export const placeLines: Record<ModelPlace, string> = {
  'this-mac': 'on this Mac',
  'my-macs': 'on your Macs',
  darkbloom: 'on Darkbloom · billed',
};

// Replaces the launch line for a model this Mac doesn't serve, whose words would not be true.
export const placeTaglines: Partial<Record<ModelPlace, string>> = {
  'my-macs': 'Bigger models, from your own Macs.',
  darkbloom: 'Compute, powered by people.',
};

// A model's name: the list's or this Mac's, else the last part of its ID.
export const modelName = (model: Pick<ChatModel, 'id' | 'name'>) =>
  model.name?.trim() || model.id.split('/').at(-1) || model.id;

// `1,204`, `42.1`, `0.84`.
export const grouped = (value: number) => Math.round(value).toLocaleString('en-US');
export const fixed = (value: number, digits = 1) =>
  value.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });

// `262K context`
export const contextLabel = (tokens: number | null | undefined) =>
  tokens ? `${Math.round(tokens / 1024)}K context` : undefined;
