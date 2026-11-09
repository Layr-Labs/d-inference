import { useSyncExternalStore } from 'react';
import {
  chatLimits,
  validateChatRequest,
  type ChatAPI,
  type ChatEvent,
  type ChatMessage,
  type ReasoningEffort,
} from '../../../shared/chat';
import { errorMessage } from '../../actions';
import { api } from '../../useBackend';
import {
  loadConversations,
  saveConversations,
  windowStorage,
  type Conversation,
  type StoredMessage,
} from './storage';
import { chatTitle } from './text';

// An answer streaming now: its chat, its stream once the main process named it, and its timing
// (milliseconds), for "Thinking N s", "Thought for N s" and tokens a second.
export interface LiveAnswer {
  conversation: string;
  stream?: string;
  started: number;
  first_token?: number;
  reasoning_started?: number;
  reasoning_ended?: number;
  // Streamed pieces so far: about one token each.
  pieces: number;
}

export interface ChatState {
  // Newest first.
  conversations: Conversation[];
  // The chat on screen; null for a new chat that has no message yet.
  current: string | null;
  // Answers streaming now, by message ID.
  live: Readonly<Record<string, LiveAnswer>>;
  // Messages written since this chat was opened: they settle in. A chat opened from the list
  // appears as it is.
  fresh: ReadonlySet<string>;
  // The unsent message, kept while the page is away.
  draft: string;
}

type Usage = { prompt_tokens?: number; completion_tokens?: number } | null | undefined;

const schedule = (callback: () => void) =>
  typeof requestAnimationFrame === 'function'
    ? requestAnimationFrame(callback)
    : (setTimeout(callback, 16) as unknown as number);
const unschedule = (handle: number) =>
  typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame(handle) : clearTimeout(handle);
const id = () => crypto.randomUUID();
// Events for a stream the page doesn't know yet (its ID is still on its way back), at most.
const maxEarlyEvents = 2_000;

// The messages a request carries: each question, and each answer that has text and didn't fail,
// the newest that fit in the main process's limits, starting with a question.
export function requestMessages(messages: StoredMessage[]): ChatMessage[] {
  const turns = messages
    .filter((message) => message.role === 'user' || (message.content.trim() && !message.error))
    .map((message) => ({ role: message.role, content: message.content }));
  const kept: ChatMessage[] = [];
  let characters = 0;
  for (let index = turns.length - 1; index >= 0; index--) {
    characters += turns[index].content.length;
    if (kept.length >= chatLimits.messages || characters > chatLimits.characters) break;
    kept.unshift(turns[index]);
  }
  while (kept[0]?.role === 'assistant') kept.shift();
  // A question too long on its own is still sent, so the refusal says why.
  if (!kept.length && turns.length) kept.push(turns[turns.length - 1]);
  return kept;
}

// Every chat and the answers streaming now, outside React so an answer keeps streaming while
// another page is shown. Streamed text reaches the screen once a frame.
export class ChatStore {
  private state: ChatState;
  private listeners = new Set<() => void>();
  // Stream ID → its answer's message ID.
  private streams = new Map<string, string>();
  private early = new Map<string, ChatEvent[]>();
  private earlyCount = 0;
  // Streams that ended here (stopped, or finished): their late events are ignored.
  private ended = new Set<string>();
  // Text and timing not yet on screen, by message ID.
  private pending = new Map<string, { content: string; reasoning: string }>();
  private timing = new Map<string, LiveAnswer>();
  private frame?: number;
  private saveTimer?: ReturnType<typeof setTimeout>;
  private off?: () => void;

  constructor(
    private chat: ChatAPI | undefined,
    private storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> | undefined,
    private now: () => number = () => Date.now(),
  ) {
    this.state = {
      conversations: loadConversations(storage),
      current: null,
      live: {},
      fresh: new Set(),
      draft: '',
    };
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    this.off ??= this.chat?.onChat((event) => this.receive(event));
    return () => {
      this.listeners.delete(listener);
    };
  };

  getState = () => this.state;

  // Stops listening, for tests and a replaced store.
  dispose() {
    this.off?.();
    this.off = undefined;
    if (this.frame !== undefined) unschedule(this.frame);
    if (this.saveTimer) clearTimeout(this.saveTimer);
  }

  get current() {
    return this.state.conversations.find((item) => item.id === this.state.current);
  }

  // The answer streaming in a chat, if any.
  answering(conversation: string | null) {
    return Object.entries(this.state.live).find(([, live]) => live.conversation === conversation);
  }

  setDraft(draft: string) {
    if (draft !== this.state.draft) this.set({ draft });
  }

  select(conversation: string | null) {
    this.set({ current: conversation, fresh: new Set() });
  }

  // The model a chat's next message goes to, remembered with it.
  setModel(model: string) {
    const current = this.current;
    if (!current || current.model === model) return;
    this.replace(current.id, (item) => ({ ...item, model }));
    this.save();
  }

  remove(conversation: string) {
    const answering = this.answering(conversation);
    if (answering) this.stop(conversation);
    this.set({
      conversations: this.state.conversations.filter((item) => item.id !== conversation),
      current: this.state.current === conversation ? null : this.state.current,
    });
    this.save();
  }

  // Asks the model and streams its answer into the chat on screen (a new chat when none is).
  async send(prompt: string, model: string, effort?: ReasoningEffort | null) {
    const text = prompt.trim();
    if (!text || this.answering(this.state.current)) return;
    const now = this.now();
    const existing = this.current;
    const conversation: Conversation = existing ?? {
      id: id(),
      title: chatTitle(text),
      model,
      created_at: now,
      updated_at: now,
      messages: [],
    };
    const question: StoredMessage = { id: id(), role: 'user', content: text, created_at: now };
    const answer: StoredMessage = {
      id: id(),
      role: 'assistant',
      content: '',
      reasoning: '',
      model,
      created_at: now,
    };
    const next = {
      ...conversation,
      model,
      updated_at: now,
      messages: [...conversation.messages, question, answer],
    };
    const live: LiveAnswer = { conversation: next.id, started: now, pieces: 0 };
    this.timing.set(answer.id, live);
    this.set({
      conversations: [next, ...this.state.conversations.filter((item) => item.id !== next.id)],
      current: next.id,
      live: { ...this.state.live, [answer.id]: { ...live } },
      fresh: new Set([...this.state.fresh, question.id, answer.id]),
      draft: '',
    });
    this.save();
    let request;
    try {
      request = validateChatRequest({
        model,
        messages: requestMessages(next.messages.slice(0, -1)),
        ...(effort ? { reasoning_effort: effort } : {}),
      });
    } catch (error) {
      return this.finish(answer.id, { error: errorMessage(error) || 'Couldn’t send this.' });
    }
    if (!this.chat) return this.finish(answer.id, { error: 'Chat needs the Darkbloom app.' });
    try {
      const { stream } = await this.chat.chatSend(request);
      if (!this.state.live[answer.id]) {
        // Stopped before the main process named the stream.
        this.forget(stream);
        void this.chat.chatCancel(stream).catch(() => {});
        return;
      }
      this.streams.set(stream, answer.id);
      const named = { ...this.timing.get(answer.id)!, stream };
      this.timing.set(answer.id, named);
      this.set({ live: { ...this.state.live, [answer.id]: { ...named } } });
      const early = this.early.get(stream) ?? [];
      this.early.delete(stream);
      this.earlyCount -= early.length;
      early.forEach((event) => this.receive(event));
    } catch (error) {
      this.finish(answer.id, {
        error: errorMessage(error) || 'Couldn’t reach this Mac’s local API.',
      });
    }
  }

  // Stops the answer streaming in a chat; what it wrote so far stays.
  stop(conversation: string | null) {
    const answering = this.answering(conversation);
    if (!answering) return;
    const [message, live] = answering;
    if (live.stream) void this.chat?.chatCancel(live.stream).catch(() => {});
    this.finish(message, { finish: 'cancelled' });
  }

  private receive(event: ChatEvent) {
    if (this.ended.has(event.stream)) return;
    const message = this.streams.get(event.stream);
    if (!message) {
      if (this.earlyCount >= maxEarlyEvents) return;
      const list = this.early.get(event.stream) ?? [];
      list.push(event);
      this.early.set(event.stream, list);
      this.earlyCount++;
      return;
    }
    const live = this.timing.get(message);
    if (!live) return;
    const now = this.now();
    if (event.type === 'reasoning' || event.type === 'content') {
      const text = this.pending.get(message) ?? { content: '', reasoning: '' };
      text[event.type] += event.text;
      this.pending.set(message, text);
      live.first_token ??= now;
      live.pieces++;
      if (event.type === 'reasoning') live.reasoning_started ??= now;
      else if (live.reasoning_started !== undefined) live.reasoning_ended ??= now;
      this.frame ??= schedule(this.flush);
      return;
    }
    if (event.type === 'done')
      this.finish(message, { finish: event.finish_reason || 'stop', usage: event.usage });
    else this.finish(message, { error: event.message });
  }

  private forget(stream: string) {
    this.streams.delete(stream);
    this.ended.add(stream);
    // Only the latest few can still send anything.
    if (this.ended.size > 64) this.ended.delete(this.ended.values().next().value!);
  }

  // Puts streamed text on screen.
  private flush = () => {
    if (this.frame !== undefined) unschedule(this.frame);
    this.frame = undefined;
    if (!this.pending.size) return;
    let conversations = this.state.conversations;
    const live = { ...this.state.live };
    for (const [message, text] of this.pending) {
      const answer = this.timing.get(message);
      if (!answer || !live[message]) continue;
      conversations = edit(conversations, answer.conversation, message, (item) => ({
        ...item,
        content: item.content + text.content,
        reasoning: (item.reasoning ?? '') + text.reasoning,
      }));
      live[message] = { ...answer };
    }
    this.pending.clear();
    this.set({ conversations, live });
    this.saveSoon();
  };

  private finish(message: string, outcome: { finish?: string; error?: string; usage?: Usage }) {
    this.flush();
    const live = this.timing.get(message);
    if (!live || !this.state.live[message]) return;
    this.timing.delete(message);
    if (live.stream) this.forget(live.stream);
    const end = this.now();
    const { [message]: _, ...rest } = this.state.live;
    const tokens = outcome.usage?.completion_tokens || live.pieces || undefined;
    const conversations = edit(this.state.conversations, live.conversation, message, (item) => {
      const next: StoredMessage = {
        ...item,
        content: item.content.trim(),
        reasoning: item.reasoning?.trim() || undefined,
        finish: outcome.error ? 'error' : outcome.finish,
        error: outcome.error,
        thinking_ms:
          live.reasoning_started !== undefined
            ? (live.reasoning_ended ?? end) - live.reasoning_started
            : undefined,
        first_token_ms:
          live.first_token !== undefined ? live.first_token - live.started : undefined,
        duration_ms: live.first_token !== undefined ? end - live.first_token : undefined,
        tokens,
        prompt_tokens: outcome.usage?.prompt_tokens || undefined,
      };
      for (const key of Object.keys(next) as (keyof StoredMessage)[])
        if (next[key] === undefined) delete next[key];
      return next;
    });
    this.set({
      conversations: conversations.map((item) =>
        item.id === live.conversation ? { ...item, updated_at: end } : item,
      ),
      live: rest,
    });
    this.save();
  }

  private replace(conversation: string, change: (item: Conversation) => Conversation) {
    this.set({
      conversations: this.state.conversations.map((item) =>
        item.id === conversation ? change(item) : item,
      ),
    });
  }

  private set(change: Partial<ChatState>) {
    this.state = { ...this.state, ...change };
    this.listeners.forEach((listener) => listener());
  }

  private save() {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    saveConversations(this.storage, this.state.conversations);
  }

  // While answers stream, at most every two seconds.
  private saveSoon() {
    this.saveTimer ??= setTimeout(() => this.save(), 2_000);
  }
}

function edit(
  conversations: Conversation[],
  conversation: string,
  message: string,
  change: (item: StoredMessage) => StoredMessage,
) {
  return conversations.map((item) =>
    item.id === conversation
      ? {
          ...item,
          messages: item.messages.map((entry) => (entry.id === message ? change(entry) : entry)),
        }
      : item,
  );
}

let shared: ChatStore | undefined;

// The app's one chat store: it outlives the page, so answers keep streaming elsewhere.
export const chatStore = () => (shared ??= new ChatStore(api, windowStorage()));

export function useChatState(store: ChatStore) {
  return useSyncExternalStore(store.subscribe, store.getState);
}
