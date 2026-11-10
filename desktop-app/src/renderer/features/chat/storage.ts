// Chats are kept in this window's localStorage, on this Mac only. Every access is guarded: a
// storage that is unavailable or full leaves chat working for this session.

export interface StoredMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  created_at: number;
  // Answers only.
  reasoning?: string;
  model?: string;
  error?: string;
  // `stop`, `length`, `cancelled` or `error`; absent while the answer streams.
  finish?: string;
  // Milliseconds: thinking (first reasoning to the first answer text), and from the request to
  // the first token; then from the first token to the end, for tokens a second.
  thinking_ms?: number;
  first_token_ms?: number;
  duration_ms?: number;
  // Tokens written (the local API's usage, else the streamed pieces), and the prompt's.
  tokens?: number;
  prompt_tokens?: number;
}

export interface Conversation {
  id: string;
  title: string;
  // The model its next message goes to.
  model?: string;
  created_at: number;
  updated_at: number;
  messages: StoredMessage[];
}

export const storageKey = 'darkbloom.chat.conversations';
// Most chats kept, and the characters they may take together (localStorage holds about 5 MB
// for the whole app). The oldest chats go first; then an oversized chat's oldest messages.
export const storageLimits = { conversations: 200, characters: 1_500_000 } as const;

type Store = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

const text = (value: unknown, limit: number) =>
  typeof value === 'string' ? value.slice(0, limit) : undefined;
const number = (value: unknown) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined;

function readMessage(value: unknown): StoredMessage | undefined {
  const item = value as Record<string, unknown> | null;
  if (!item || typeof item !== 'object' || typeof item.id !== 'string') return undefined;
  if (item.role !== 'user' && item.role !== 'assistant') return undefined;
  const content = text(item.content, 500_000);
  if (content === undefined) return undefined;
  const message: StoredMessage = {
    id: item.id.slice(0, 64),
    role: item.role,
    content,
    created_at: number(item.created_at) ?? 0,
  };
  if (item.role === 'assistant') {
    const optional = {
      reasoning: text(item.reasoning, 500_000),
      model: text(item.model, 256),
      error: text(item.error, 600),
      // An answer saved mid-stream (the app quit) reads as stopped.
      finish: text(item.finish, 32) ?? (item.error ? 'error' : 'cancelled'),
      thinking_ms: number(item.thinking_ms),
      first_token_ms: number(item.first_token_ms),
      duration_ms: number(item.duration_ms),
      tokens: number(item.tokens),
      prompt_tokens: number(item.prompt_tokens),
    };
    for (const [key, entry] of Object.entries(optional))
      if (entry !== undefined && entry !== '') Object.assign(message, { [key]: entry });
  }
  return message;
}

function readConversation(value: unknown): Conversation | undefined {
  const item = value as Record<string, unknown> | null;
  if (!item || typeof item !== 'object' || typeof item.id !== 'string') return undefined;
  if (!Array.isArray(item.messages)) return undefined;
  const messages = item.messages.map(readMessage).filter((m): m is StoredMessage => !!m);
  if (!messages.length) return undefined;
  const created = number(item.created_at) ?? 0;
  return {
    id: item.id.slice(0, 64),
    title: text(item.title, 120)?.trim() || 'Chat',
    ...(typeof item.model === 'string' ? { model: item.model.slice(0, 256) } : {}),
    created_at: created,
    updated_at: number(item.updated_at) ?? created,
    messages,
  };
}

// The saved chats, newest first; anything unreadable is skipped.
export function loadConversations(storage: Store | undefined): Conversation[] {
  let raw: string | null | undefined;
  try {
    raw = storage?.getItem(storageKey);
  } catch {
    return [];
  }
  if (!raw) return [];
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return [];
  }
  const list = (value as { conversations?: unknown } | null)?.conversations;
  if (!Array.isArray(list)) return [];
  const seen = new Set<string>();
  return list
    .map(readConversation)
    .filter((item): item is Conversation => !!item && !seen.has(item.id) && !!seen.add(item.id))
    .sort((a, b) => b.updated_at - a.updated_at)
    .slice(0, storageLimits.conversations);
}

const size = (conversation: Conversation) => JSON.stringify(conversation).length;

// The chats that fit in `characters`: the newest first, whole, until one doesn't fit. When even
// the newest is too large, it keeps its newest messages that fit, without their reasoning.
export function fitConversations(conversations: Conversation[], characters: number) {
  const sorted = [...conversations]
    .filter((item) => item.messages.length > 0)
    .sort((a, b) => b.updated_at - a.updated_at)
    .slice(0, storageLimits.conversations);
  const kept: Conversation[] = [];
  let total = 0;
  for (const conversation of sorted) {
    const length = size(conversation);
    if (total + length <= characters) {
      kept.push(conversation);
      total += length;
      continue;
    }
    if (kept.length) break;
    const lean = conversation.messages.map(({ reasoning: _, ...message }) => message);
    const trimmed = { ...conversation, messages: lean };
    while (trimmed.messages.length > 1 && size(trimmed) > characters)
      trimmed.messages = trimmed.messages.slice(1);
    if (size(trimmed) <= characters) kept.push(trimmed);
    break;
  }
  return kept;
}

// Saves the chats that fit; a full storage halves the room and tries again, down to the newest
// chat alone. False when nothing could be saved.
export function saveConversations(storage: Store | undefined, conversations: Conversation[]) {
  if (!storage) return false;
  let room: number = storageLimits.characters;
  for (let attempt = 0; attempt < 10 && room >= 500; attempt++) {
    const kept = fitConversations(conversations, room);
    const payload = JSON.stringify({ conversations: kept });
    try {
      if (kept.length) storage.setItem(storageKey, payload);
      else storage.removeItem(storageKey);
      return true;
    } catch {
      room = Math.floor(Math.min(room, payload.length) / 2);
    }
  }
  return false;
}

// Small remembered choices: the last model, effort, speed line and chat list.
export const prefKeys = {
  model: 'darkbloom.chat.model',
  effort: 'darkbloom.chat.effort',
  speed: 'darkbloom.chat.speed',
  list: 'darkbloom.chat.list',
} as const;
export type Pref = keyof typeof prefKeys;

export function readPref(storage: Store | undefined, pref: Pref) {
  try {
    return storage?.getItem(prefKeys[pref]) ?? null;
  } catch {
    return null;
  }
}

export function writePref(storage: Store | undefined, pref: Pref, value: string | null) {
  try {
    if (value === null) storage?.removeItem(prefKeys[pref]);
    else storage?.setItem(prefKeys[pref], value.slice(0, 256));
  } catch {
    /* Remembered for this session only. */
  }
}

// This window's localStorage, or undefined where reading it throws.
export function windowStorage(): Store | undefined {
  try {
    return typeof window === 'undefined' ? undefined : (window.localStorage ?? undefined);
  } catch {
    return undefined;
  }
}
