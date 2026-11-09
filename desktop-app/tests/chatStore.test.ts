import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ChatAPI, ChatEvent } from '../src/shared/chat';

vi.mock('../src/renderer/useBackend', () => ({ api: undefined, isPreview: false }));
const { ChatStore, requestMessages } = await import('../src/renderer/features/chat/store');
const { fitConversations, loadConversations, readPref, saveConversations, storageKey, writePref } =
  await import('../src/renderer/features/chat/storage');
type Conversation = import('../src/renderer/features/chat/storage').Conversation;

const MEMORY =
  "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.";

function memory() {
  const data = new Map<string, string>();
  return {
    data,
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
    removeItem: (key: string) => void data.delete(key),
  };
}

function chatAPI(stream = 's1') {
  let listener: ((event: ChatEvent) => void) | undefined;
  const api = {
    chatModels: vi.fn(),
    chatSend: vi.fn(async () => ({ stream })),
    chatCancel: vi.fn(async () => {}),
    onChat: vi.fn((callback: (event: ChatEvent) => void) => {
      listener = callback;
      return () => (listener = undefined);
    }),
  } satisfies ChatAPI;
  return { api, emit: (event: ChatEvent) => listener?.(event) };
}

const stores: InstanceType<typeof ChatStore>[] = [];
function setup(saved?: Conversation[]) {
  const storage = memory();
  if (saved) storage.setItem(storageKey, JSON.stringify({ conversations: saved }));
  const { api, emit } = chatAPI();
  let clock = 1_000;
  const store = new ChatStore(api, storage, () => clock);
  store.subscribe(() => {});
  stores.push(store);
  const answer = () => store.current!.messages.at(-1)!;
  const saved_ = () => JSON.parse(storage.data.get(storageKey) ?? '{}').conversations;
  return { store, api, emit, storage, answer, saved: saved_, tick: (ms: number) => (clock += ms) };
}
afterEach(() => stores.splice(0).forEach((store) => store.dispose()));

describe('a chat', () => {
  it('asks the model and streams its answer into a new chat, then keeps it', async () => {
    const { store, api, emit, answer, saved, tick } = setup();
    await store.send('  How do I list models?  ', 'gpt-oss-20b', 'high');
    expect(api.chatSend).toHaveBeenCalledExactlyOnceWith({
      model: 'gpt-oss-20b',
      messages: [{ role: 'user', content: 'How do I list models?' }],
      reasoning_effort: 'high',
    });
    const state = store.getState();
    expect(store.current).toMatchObject({ title: 'How do I list models?', model: 'gpt-oss-20b' });
    expect(Object.values(state.live)).toEqual([
      { conversation: state.current, stream: 's1', started: 1_000, pieces: 0 },
    ]);
    tick(500);
    emit({ stream: 's1', type: 'reasoning', text: 'Let me ' });
    tick(100);
    emit({ stream: 's1', type: 'reasoning', text: 'look.' });
    tick(1_400);
    emit({ stream: 's1', type: 'content', text: 'Use ' });
    await vi.waitFor(() => expect(answer().content).toBe('Use '));
    expect(answer().reasoning).toBe('Let me look.');
    tick(1_000);
    emit({ stream: 's1', type: 'content', text: '`/v1/models`.' });
    emit({
      stream: 's1',
      type: 'done',
      finish_reason: 'stop',
      usage: { prompt_tokens: 31, completion_tokens: 9 },
    });
    expect(answer()).toMatchObject({
      role: 'assistant',
      content: 'Use `/v1/models`.',
      reasoning: 'Let me look.',
      model: 'gpt-oss-20b',
      finish: 'stop',
      thinking_ms: 1_500,
      first_token_ms: 500,
      duration_ms: 2_500,
      tokens: 9,
      prompt_tokens: 31,
    });
    expect(store.getState().live).toEqual({});
    expect(saved()).toHaveLength(1);
    expect(saved()[0].messages.map((message: { content: string }) => message.content)).toEqual([
      'How do I list models?',
      'Use `/v1/models`.',
    ]);
  });

  it('counts streamed pieces when the local API sends no usage', async () => {
    const { store, emit, answer } = setup();
    await store.send('Hi', 'qwen3-vl-30b');
    emit({ stream: 's1', type: 'content', text: 'Hello' });
    emit({ stream: 's1', type: 'content', text: ' there' });
    emit({ stream: 's1', type: 'done', finish_reason: 'length' });
    expect(answer()).toMatchObject({ content: 'Hello there', finish: 'length', tokens: 2 });
    expect(answer()).not.toHaveProperty('reasoning');
    expect(answer()).not.toHaveProperty('thinking_ms');
  });

  it('keeps events that arrive before the stream’s ID does', async () => {
    const { store, api, emit, answer } = setup();
    api.chatSend.mockImplementationOnce(async () => {
      emit({ stream: 's1', type: 'content', text: 'Early' });
      emit({ stream: 's1', type: 'done', finish_reason: 'stop' });
      return { stream: 's1' };
    });
    await store.send('Hi', 'gpt-oss-20b');
    expect(answer()).toMatchObject({ content: 'Early', finish: 'stop' });
  });

  it('stops an answer, keeps what it wrote, and ignores what follows', async () => {
    const { store, api, emit, answer } = setup();
    await store.send('Write a lot', 'gpt-oss-20b');
    emit({ stream: 's1', type: 'content', text: 'Half' });
    store.stop(store.getState().current);
    expect(api.chatCancel).toHaveBeenCalledExactlyOnceWith('s1');
    expect(answer()).toMatchObject({ content: 'Half', finish: 'cancelled' });
    emit({ stream: 's1', type: 'content', text: ' more' });
    emit({ stream: 's1', type: 'done', finish_reason: 'cancelled' });
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(answer()).toMatchObject({ content: 'Half', finish: 'cancelled' });
  });

  it('cancels a stream it stopped before the stream had an ID', async () => {
    const { store, api } = setup();
    let resolve!: (value: { stream: string }) => void;
    api.chatSend.mockImplementationOnce(() => new Promise((done) => (resolve = done)));
    const sending = store.send('Hi', 'gpt-oss-20b');
    store.stop(store.getState().current);
    resolve({ stream: 'late' });
    await sending;
    expect(api.chatCancel).toHaveBeenCalledExactlyOnceWith('late');
  });

  it('shows the local API’s own refusal on the answer', async () => {
    const { store, api, emit, answer } = setup();
    await store.send('Hi', 'gpt-oss-20b');
    emit({ stream: 's1', type: 'error', message: MEMORY });
    expect(answer()).toMatchObject({ content: '', error: MEMORY, finish: 'error' });
    api.chatSend.mockRejectedValueOnce(
      new Error(
        "Error invoking remote method 'chat:send': Error: Two answers are already streaming. Wait for one to finish.",
      ),
    );
    await store.send('Again', 'gpt-oss-20b');
    expect(answer()).toMatchObject({
      error: 'Two answers are already streaming. Wait for one to finish.',
      finish: 'error',
    });
  });

  it('answers one question at a time in each chat', async () => {
    const { store, api } = setup();
    await store.send('One', 'gpt-oss-20b');
    await store.send('Two', 'gpt-oss-20b');
    expect(api.chatSend).toHaveBeenCalledTimes(1);
    expect(store.current!.messages).toHaveLength(2);
  });

  it('says a question too long for the local API is too long, without sending it', async () => {
    const { store, api, answer } = setup();
    await store.send('x'.repeat(400_001), 'gpt-oss-20b');
    expect(api.chatSend).not.toHaveBeenCalled();
    expect(answer().error).toBe('This chat is too long to send. Start a new chat.');
  });

  it('removes a chat, stopping its answer', async () => {
    const { store, api, saved } = setup();
    await store.send('Hi', 'gpt-oss-20b');
    const id = store.getState().current!;
    store.remove(id);
    expect(api.chatCancel).toHaveBeenCalledWith('s1');
    expect(store.getState()).toMatchObject({ current: null, conversations: [], live: {} });
    expect(saved()).toBeUndefined();
  });

  it('opens saved chats as they are, and lets new messages settle in', async () => {
    const restored: Conversation = {
      id: 'saved',
      title: 'Earlier',
      model: 'gpt-oss-20b',
      created_at: 1,
      updated_at: 2,
      messages: [
        { id: 'q', role: 'user', content: 'Hello', created_at: 1 },
        { id: 'a', role: 'assistant', content: 'Hi.', created_at: 2, finish: 'stop' },
      ],
    };
    const { store, api } = setup([restored]);
    expect(store.getState().conversations).toEqual([restored]);
    store.select('saved');
    expect(store.getState().fresh.size).toBe(0);
    await store.send('And now?', 'gpt-oss-20b');
    const [, , question, answer] = store.current!.messages;
    expect([...store.getState().fresh]).toEqual([question.id, answer.id]);
    expect(api.chatSend).toHaveBeenCalledWith({
      model: 'gpt-oss-20b',
      messages: [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi.' },
        { role: 'user', content: 'And now?' },
      ],
    });
    store.select('saved');
    expect(store.getState().fresh.size).toBe(0);
  });

  it('keeps the unsent message while the page is away', () => {
    const { store } = setup();
    store.setDraft('Half a thought');
    expect(store.getState().draft).toBe('Half a thought');
  });
});

describe('what a request carries', () => {
  const message = (role: 'user' | 'assistant', content: string, error?: string) => ({
    id: content,
    role,
    content,
    created_at: 0,
    ...(error ? { error } : {}),
  });

  it('sends each question and each answer that has text and didn’t fail', () => {
    expect(
      requestMessages([
        message('user', 'One'),
        message('assistant', 'Partial', 'The answer stopped before it finished.'),
        message('user', 'Two'),
        message('assistant', '   '),
        message('user', 'Three'),
        message('assistant', 'Fine'),
        message('user', 'Four'),
      ]),
    ).toEqual([
      { role: 'user', content: 'One' },
      { role: 'user', content: 'Two' },
      { role: 'user', content: 'Three' },
      { role: 'assistant', content: 'Fine' },
      { role: 'user', content: 'Four' },
    ]);
  });

  it('keeps the newest that fit in 200 messages and 400,000 characters, from a question', () => {
    const many = Array.from({ length: 300 }, (_, index) =>
      message(index % 2 ? 'assistant' : 'user', `m${index}`),
    );
    const kept = requestMessages(many);
    expect(kept.length).toBeLessThanOrEqual(200);
    expect(kept[0].role).toBe('user');
    expect(kept.at(-1)!.content).toBe('m299');
    const long = requestMessages([
      message('user', 'x'.repeat(300_000)),
      message('assistant', 'y'.repeat(50_000)),
      message('user', 'z'.repeat(60_000)),
    ]);
    expect(long.map((item) => item.content.length)).toEqual([60_000]);
  });
});

describe('storage', () => {
  const conversation = (id: string, updated: number, size = 10): Conversation => ({
    id,
    title: id,
    created_at: updated,
    updated_at: updated,
    messages: [
      { id: `${id}q`, role: 'user', content: 'q'.repeat(size), created_at: updated },
      {
        id: `${id}a`,
        role: 'assistant',
        content: 'a'.repeat(size),
        reasoning: 'r'.repeat(size),
        created_at: updated,
        finish: 'stop',
      },
    ],
  });

  it('reads saved chats defensively, newest first', () => {
    const storage = memory();
    expect(loadConversations(storage)).toEqual([]);
    storage.setItem(storageKey, '{not json');
    expect(loadConversations(storage)).toEqual([]);
    storage.setItem(
      storageKey,
      JSON.stringify({
        conversations: [
          conversation('older', 1),
          { id: 'no messages', messages: [] },
          { id: 'bad', messages: [{ role: 'robot', content: 'x', id: 'x' }] },
          conversation('newer', 5),
          conversation('newer', 6),
          'junk',
        ],
      }),
    );
    expect(loadConversations(storage).map((item) => item.id)).toEqual(['newer', 'older']);
    const throwing = {
      ...storage,
      getItem: () => {
        throw new Error('SecurityError');
      },
    };
    expect(loadConversations(throwing)).toEqual([]);
    expect(loadConversations(undefined)).toEqual([]);
  });

  it('reads an answer saved mid-stream as stopped', () => {
    const storage = memory();
    const saved = conversation('mid', 1);
    delete saved.messages[1].finish;
    storage.setItem(storageKey, JSON.stringify({ conversations: [saved] }));
    expect(loadConversations(storage)[0].messages[1].finish).toBe('cancelled');
  });

  it('keeps the newest chats that fit, and trims an oversized newest chat', () => {
    const chats = [conversation('a', 1), conversation('b', 3), conversation('c', 2)];
    const one = JSON.stringify(chats[0]).length;
    expect(fitConversations(chats, one * 2 + 10).map((item) => item.id)).toEqual(['b', 'c']);
    const huge = conversation('huge', 9, 5_000);
    huge.messages.push(
      { id: 'q2', role: 'user', content: 'latest', created_at: 9 },
      { id: 'a2', role: 'assistant', content: 'answer', created_at: 9, finish: 'stop' },
    );
    const [trimmed] = fitConversations([huge], 600);
    expect(trimmed.messages.map((item) => item.id)).toEqual(['q2', 'a2']);
    expect(trimmed.messages.some((item) => 'reasoning' in item)).toBe(false);
  });

  it('saves with less room when storage is full, and never throws', () => {
    const storage = memory();
    const setItem = vi.fn((key: string, value: string) => {
      if (value.length > 5_000) throw new DOMException('Full', 'QuotaExceededError');
      storage.data.set(key, value);
    });
    const chats = Array.from({ length: 20 }, (_, index) => conversation(`c${index}`, index, 500));
    expect(saveConversations({ ...storage, setItem }, chats)).toBe(true);
    expect(setItem.mock.calls.length).toBeGreaterThan(1);
    const kept = JSON.parse(storage.data.get(storageKey)!).conversations;
    expect(kept.length).toBeGreaterThan(0);
    expect(kept[0].id).toBe('c19');
    const broken = {
      ...storage,
      setItem: () => {
        throw new Error('denied');
      },
    };
    expect(saveConversations(broken, chats)).toBe(false);
    expect(saveConversations(undefined, chats)).toBe(false);
  });

  it('remembers small choices, and survives a storage that throws', () => {
    const storage = memory();
    writePref(storage, 'model', 'gpt-oss-20b');
    expect(readPref(storage, 'model')).toBe('gpt-oss-20b');
    writePref(storage, 'model', null);
    expect(readPref(storage, 'model')).toBeNull();
    const broken = {
      getItem: () => {
        throw new Error('denied');
      },
      setItem: () => {
        throw new Error('denied');
      },
      removeItem: () => {
        throw new Error('denied');
      },
    };
    expect(() => writePref(broken, 'effort', 'high')).not.toThrow();
    expect(readPref(broken, 'effort')).toBeNull();
  });
});
