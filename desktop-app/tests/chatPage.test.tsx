// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { ChatEvent, ChatModel, ChatModels } from '../src/shared/chat';
import { previewChatModels } from '../src/renderer/preview/chat';
import { taglines } from '../src/renderer/features/chat/text';
import styles from '../src/renderer/features/chat/chat.module.css';
import { backendWith, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  chatModels: vi.fn(),
  chatSend: vi.fn(),
  chatCancel: vi.fn(),
  onChat: vi.fn(),
  copy: vi.fn(),
}));
vi.mock('../src/renderer/useBackend', () => ({ api, isPreview: false, useBackend: vi.fn() }));

const billed: ChatModel = {
  id: 'qwen3.8-27b',
  name: 'Qwen 3.8 27B',
  owned_by: 'darkbloom',
  reasoning: true,
  reasoning_efforts: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
};
const listed: ChatModels = {
  base_url: 'http://127.0.0.1:8000/v1',
  models: [...previewChatModels(), billed],
};
let emit: (event: ChatEvent) => void;
let reduce = false;

beforeEach(() => {
  localStorage.clear();
  reduce = false;
  window.matchMedia = vi.fn((query: string) => ({
    matches: query.includes('reduce') ? reduce : false,
    media: query,
    addEventListener() {},
    removeEventListener() {},
  })) as unknown as typeof window.matchMedia;
  api.chatSend.mockResolvedValue({ stream: 's1' });
  api.chatCancel.mockResolvedValue(undefined);
  api.copy.mockResolvedValue(undefined);
  api.onChat.mockImplementation((callback: (event: ChatEvent) => void) => {
    emit = (event) => act(() => callback(event));
    return () => {};
  });
});
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

async function mount(models: ChatModels = listed) {
  // A fresh page and store each time: the page keeps its last list and launch line per launch.
  vi.resetModules();
  const { Chat } = await import('../src/renderer/features/chat/Chat');
  const { ChatStore } = await import('../src/renderer/features/chat/store');
  api.chatModels.mockResolvedValue(models);
  const store = new ChatStore(api, localStorage);
  const navigate = vi.fn();
  const backend = backendWith(
    snapshot({
      endpoint: { base_url: 'http://127.0.0.1:8000/v1', authenticated: true, models: [] },
    }),
  );
  const view = render(<Chat backend={backend} navigate={navigate} store={store} />);
  await waitFor(() => expect(api.chatModels).toHaveBeenCalled());
  // The page again, as when you come back to it.
  const again = () => render(<Chat backend={backend} navigate={navigate} store={store} />);
  return { view, store, navigate, again };
}

const field = () => screen.getByRole('textbox', { name: 'Message' });
async function send(text: string) {
  fireEvent.change(field(), { target: { value: text } });
  await act(async () => {
    fireEvent.keyDown(field(), { key: 'Enter' });
  });
}
const flush = () => act(() => new Promise((resolve) => setTimeout(resolve, 40)));

it('says chat uses this Mac’s local API, and opens Studio, when it has none', async () => {
  const { navigate } = await mount({
    models: [],
    code: 'no_endpoint',
    error: 'This Mac’s local API isn’t running.',
  });
  expect(await screen.findByText('Chat uses this Mac’s local API.')).toBeVisible();
  expect(screen.queryByRole('textbox', { name: 'Message' })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Open Studio' }));
  expect(navigate).toHaveBeenCalledExactlyOnceWith('studio');
});

it('shows why the local API can’t be reached, and tries again', async () => {
  await mount({ models: [], code: 'unavailable', error: 'This Mac’s local API didn’t answer.' });
  expect(await screen.findByRole('alert')).toHaveTextContent('This Mac’s local API didn’t answer.');
  api.chatModels.mockResolvedValue(listed);
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(await screen.findByRole('textbox', { name: 'Message' })).toBeEnabled();
  expect(api.chatModels).toHaveBeenCalledTimes(2);
});

it('opens on the mark and the launch line, naming the model it will ask', async () => {
  await mount();
  expect(await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' })).toBeVisible();
  expect(screen.getByRole('heading', { level: 1, name: 'Chat' })).toBeInTheDocument();
  expect(screen.getByRole('img', { name: 'Darkbloom' })).toBeInTheDocument();
  expect(taglines).toContain(document.querySelector(`.${styles.tagline}`)?.textContent);
  expect(screen.getByText('GPT-OSS 20B · on this Mac')).toBeVisible();
  expect(field()).toHaveAttribute('placeholder', 'Ask GPT-OSS 20B');
  expect(screen.getByRole('button', { name: 'Reasoning effort: Default' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled();
  expect(screen.getByText('Your chats stay on this Mac.')).toBeVisible();
});

it('picks a model from a list grouped by where each runs, and remembers it', async () => {
  await mount();
  const button = await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  fireEvent.click(button);
  const list = screen.getByRole('listbox', { name: 'Model' });
  expect(list).toHaveFocus();
  expect(
    within(list)
      .getAllByRole('group')
      .map((group) => group.getAttribute('aria-labelledby') && group.firstChild?.textContent),
  ).toEqual(['This Mac', 'Your Macs', 'Darkbloom network · billed']);
  expect(within(list).getByRole('option', { name: /GPT-OSS 20B/ })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  fireEvent.keyDown(list, { key: 'ArrowDown' });
  fireEvent.keyDown(list, { key: 'Enter' });
  expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Model: Qwen3-VL 30B' })).toHaveFocus();
  expect(localStorage.getItem('darkbloom.chat.model')).toBe('qwen3-vl-30b');
  // A model that doesn't reason takes no effort.
  expect(screen.queryByRole('button', { name: /Reasoning effort/ })).not.toBeInTheDocument();
  // Your other Macs' models don't get this Mac's launch line, and Escape closes the list.
  fireEvent.click(screen.getByRole('button', { name: 'Model: Qwen3-VL 30B' }));
  fireEvent.click(screen.getByRole('option', { name: /Gemma 4 26B/ }));
  expect(screen.getByText('Bigger models, from your own Macs.')).toBeVisible();
  expect(screen.getByText('Gemma 4 26B · on your Macs')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Model: Gemma 4 26B' }));
  fireEvent.keyDown(screen.getByRole('listbox'), { key: 'Escape' });
  expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Model: Gemma 4 26B' })).toHaveFocus();
});

it('sends with Enter, keeps Shift+Enter for a new line, and streams the answer', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  fireEvent.change(field(), { target: { value: 'Hello' } });
  fireEvent.keyDown(field(), { key: 'Enter', shiftKey: true });
  expect(api.chatSend).not.toHaveBeenCalled();
  await send('List the models');
  expect(api.chatSend).toHaveBeenCalledExactlyOnceWith({
    model: 'gpt-oss-20b',
    messages: [{ role: 'user', content: 'List the models' }],
  });
  expect(field()).toHaveValue('');
  const question = screen.getByText('List the models', { selector: 'p' });
  expect(question).toHaveClass(styles.question, styles.enter);
  expect(screen.getByRole('status', { name: 'Reading your message' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Stop' })).toBeVisible();
  expect(screen.queryByRole('button', { name: 'Send' })).not.toBeInTheDocument();

  emit({ stream: 's1', type: 'reasoning', text: 'They want the list.' });
  await flush();
  expect(screen.getByRole('button', { name: /Thinking/ })).toHaveAttribute(
    'aria-expanded',
    'false',
  );
  emit({ stream: 's1', type: 'content', text: 'Run **this**:\n\n```bash\ncurl ' });
  emit({ stream: 's1', type: 'content', text: '$BASE/models\n```\nThen `read` it.' });
  emit({
    stream: 's1',
    type: 'done',
    finish_reason: 'stop',
    usage: { prompt_tokens: 12, completion_tokens: 30 },
  });
  // Its newest glyphs reach full ink, then it reads as plain text.
  await waitFor(() => expect(document.querySelector(`.${styles.ink}`)).not.toBeInTheDocument());
  const answer = screen.getByRole('article', { name: 'Answer from GPT-OSS 20B' });
  expect(within(answer).getByText('this', { selector: 'strong' })).toBeVisible();
  expect(within(answer).getByRole('region', { name: 'bash code' })).toHaveTextContent(
    'curl $BASE/models',
  );
  expect(within(answer).getByText('read', { selector: 'code' })).toBeVisible();
  const reasoning = within(answer).getByRole('button', { name: /^Thought for \d+\.\d s$/ });
  fireEvent.click(reasoning);
  expect(reasoning).toHaveAttribute('aria-expanded', 'true');
  expect(within(answer).getByText('They want the list.')).toBeVisible();
  fireEvent.click(within(answer).getByRole('button', { name: 'Copy' }));
  await waitFor(() =>
    expect(api.copy).toHaveBeenCalledWith(
      'Run **this**:\n\n```bash\ncurl $BASE/models\n```\nThen `read` it.',
    ),
  );
  expect(await within(answer).findByRole('button', { name: 'Copied' })).toBeVisible();
  fireEvent.click(within(answer).getByRole('button', { name: 'Show details' }));
  expect(within(answer).getByText(/^GPT-OSS 20B · 30 tokens · .* · 12 in$/)).toBeVisible();
  // Its chat is in the list, titled from the first message.
  const chats = screen.getByRole('navigation', { name: 'Chats' });
  expect(within(chats).getByRole('button', { name: 'List the models' })).toHaveAttribute(
    'aria-current',
    'true',
  );
});

it('stops an answer with Stop, keeping what it wrote', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('Write a lot');
  emit({ stream: 's1', type: 'content', text: 'Half of it' });
  await flush();
  fireEvent.click(screen.getByRole('button', { name: 'Stop' }));
  expect(api.chatCancel).toHaveBeenCalledExactlyOnceWith('s1');
  expect(screen.getByText('Stopped')).toBeVisible();
  expect(screen.getByRole('article', { name: 'Answer from GPT-OSS 20B' })).toHaveTextContent(
    'Half of it',
  );
  expect(screen.getByRole('button', { name: 'Send' })).toBeVisible();
});

it('shows the local API’s refusal under the answer', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('Hello');
  emit({ stream: 's1', type: 'error', message: 'This Mac’s memory can’t hold this request now.' });
  expect(await screen.findByRole('alert')).toHaveTextContent(
    'This Mac’s memory can’t hold this request now.',
  );
});

it('lets streamed text settle from faint to full ink, and not with motion reduced', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('Hello');
  emit({
    stream: 's1',
    type: 'content',
    text: 'A reply long enough to have a settled part and a tail.',
  });
  await flush();
  const glyphs = [...document.querySelectorAll<HTMLElement>(`.${styles.ink}`)];
  expect(glyphs).toHaveLength(28);
  const opacity = glyphs.map((glyph) => Number(glyph.style.opacity));
  expect(opacity[27]).toBeCloseTo(0.28 + 0.72 / 28);
  expect(opacity[0]).toBe(1);
  expect([...opacity].sort((a, b) => b - a)).toEqual(opacity);
  emit({ stream: 's1', type: 'done', finish_reason: 'stop' });
  await flush();
  expect(document.querySelector(`.${styles.settle}`)).toBeInTheDocument();
  await waitFor(() => expect(document.querySelector(`.${styles.ink}`)).not.toBeInTheDocument());

  cleanup();
  reduce = true;
  api.chatSend.mockResolvedValue({ stream: 's2' });
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('Again');
  emit({
    stream: 's2',
    type: 'content',
    text: 'A reply long enough to have a settled part and a tail.',
  });
  await flush();
  expect(screen.getByText(/A reply long enough/)).toBeVisible();
  expect(document.querySelector(`.${styles.ink}`)).not.toBeInTheDocument();
});

it('keeps chats in a list: a new chat, and delete after asking', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('First question');
  emit({ stream: 's1', type: 'content', text: 'First answer' });
  emit({ stream: 's1', type: 'done', finish_reason: 'stop' });
  await flush();
  const chats = screen.getByRole('navigation', { name: 'Chats' });
  // New chat is in the top bar once a chat has messages, and atop the list.
  expect(screen.getAllByRole('button', { name: 'New chat' })).toHaveLength(2);
  fireEvent.click(within(chats).getByRole('button', { name: 'New chat' }));
  expect(screen.queryByText('First answer')).not.toBeInTheDocument();
  expect(screen.getByText('GPT-OSS 20B · on this Mac')).toBeVisible();
  expect(screen.getAllByRole('button', { name: 'New chat' })).toHaveLength(1);
  expect(within(chats).getByRole('heading', { name: 'Today' })).toBeVisible();
  fireEvent.click(within(chats).getByRole('button', { name: 'Delete First question' }));
  const dialog = screen.getByRole('dialog', { name: 'Delete this chat?' });
  expect(within(dialog).getByText('First question')).toBeVisible();
  fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  expect(within(chats).queryByRole('button', { name: 'First question' })).not.toBeInTheDocument();
  expect(localStorage.getItem('darkbloom.chat.conversations')).toBeNull();
});

it('opens a saved chat as it is, and moves through chats with the arrow keys', async () => {
  const now = Date.now();
  localStorage.setItem(
    'darkbloom.chat.conversations',
    JSON.stringify({
      conversations: ['One', 'Two'].map((title, index) => ({
        id: title,
        title,
        model: 'gpt-oss-20b',
        created_at: now - index,
        updated_at: now - index,
        messages: [
          { id: `${title}q`, role: 'user', content: `${title} question`, created_at: now },
          {
            id: `${title}a`,
            role: 'assistant',
            content: `${title} answer`,
            model: 'gpt-oss-20b',
            reasoning: 'Because.',
            thinking_ms: 2_400,
            created_at: now,
            finish: 'stop',
          },
        ],
      })),
    }),
  );
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  const chats = screen.getByRole('navigation', { name: 'Chats' });
  const one = within(chats).getByRole('button', { name: 'One' });
  fireEvent.click(one);
  expect(screen.getByText('One question')).not.toHaveClass(styles.enter);
  expect(screen.getByRole('article', { name: 'Answer from GPT-OSS 20B' })).not.toHaveClass(
    styles.enter,
  );
  expect(screen.getByRole('button', { name: 'Thought for 2.4 s' })).toBeVisible();
  one.focus();
  fireEvent.keyDown(one, { key: 'ArrowDown' });
  expect(within(chats).getByRole('button', { name: 'Two' })).toHaveFocus();
  fireEvent.keyDown(within(chats).getByRole('button', { name: 'Two' }), { key: 'Delete' });
  expect(screen.getByRole('dialog', { name: 'Delete this chat?' })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(within(chats).getByRole('button', { name: 'Two' })).toBeVisible();
});

it('sends the chosen effort to a model that reasons, and remembers it', async () => {
  await mount();
  fireEvent.click(await screen.findByRole('button', { name: 'Reasoning effort: Default' }));
  fireEvent.click(screen.getByRole('option', { name: 'High' }));
  expect(localStorage.getItem('darkbloom.chat.effort')).toBe('high');
  await send('Think hard');
  expect(api.chatSend).toHaveBeenCalledWith({
    model: 'gpt-oss-20b',
    messages: [{ role: 'user', content: 'Think hard' }],
    reasoning_effort: 'high',
  });
});

it('shows tokens a second while answering, when asked', async () => {
  await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  const speed = screen.getByRole('button', { name: 'Show speed' });
  fireEvent.click(speed);
  expect(speed).toHaveAttribute('aria-pressed', 'true');
  expect(localStorage.getItem('darkbloom.chat.speed')).toBe('1');
  await send('Hello');
  emit({ stream: 's1', type: 'content', text: 'Hi' });
  emit({ stream: 's1', type: 'content', text: ' there' });
  await flush();
  expect(screen.getByText('2 tokens')).toBeVisible();
  expect(screen.getByText(/tok\/s$/)).toBeVisible();
  expect(screen.getByText('on this Mac')).toBeVisible();
});

it('hides and shows the chat list, and remembers it', async () => {
  await mount();
  const toggle = await screen.findByRole('button', { name: 'Hide chats' });
  expect(toggle).toHaveAttribute('aria-expanded', 'true');
  fireEvent.click(toggle);
  expect(screen.getByRole('button', { name: 'Show chats' })).toHaveAttribute(
    'aria-expanded',
    'false',
  );
  expect(localStorage.getItem('darkbloom.chat.list')).toBe('0');
});

it('lets new messages settle in once, not again when you come back to the page', async () => {
  const { view, again } = await mount();
  await screen.findByRole('button', { name: 'Model: GPT-OSS 20B' });
  await send('Hello');
  expect(screen.getByText('Hello', { selector: 'p' })).toHaveClass(styles.enter);
  view.unmount();
  const later = Date.now() + 5_000;
  const clock = vi.spyOn(Date, 'now').mockReturnValue(later);
  try {
    again();
    expect(await screen.findByText('Hello', { selector: 'p' })).not.toHaveClass(styles.enter);
    // The answer is still streaming: Stop is where Send was.
    expect(screen.getByRole('button', { name: 'Stop' })).toBeVisible();
  } finally {
    clock.mockRestore();
  }
});
