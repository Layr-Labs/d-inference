import {
  reasoningEfforts,
  validateChatRequest,
  type ChatAPI,
  type ChatEvent,
  type ChatModel,
  type ChatModels,
} from '../../shared/chat';
import { previewParam, type FeaturePreview } from './types';

// Development preview of chat: a simulated local API that streams canned answers, with
// reasoning and a code block, at about the pace a Mac writes them. Development data only.
//
// `&chat=no_endpoint`: this Mac runs no local API. `&chat=unavailable`: the local API doesn't
// answer. `&chat=fail`: it refuses each answer as a busy Mac does (503, in its own words).
const mode = () => previewParam('chat');

export const chatPreview: FeaturePreview = {
  // Without a local API the snapshot has no endpoint either, as the runtime reports it.
  snapshot: (snapshot) =>
    mode() === 'no_endpoint' ? { ...snapshot, endpoint: undefined } : snapshot,
};

export const previewChatModels: ChatModel[] = [
  {
    id: 'gpt-oss-20b',
    name: 'GPT-OSS 20B',
    owned_by: 'this-mac',
    reasoning: true,
    reasoning_efforts: [...reasoningEfforts],
    context_length: 131_072,
    max_output_length: 131_072,
    input_modalities: ['text'],
  },
  {
    id: 'qwen3-vl-30b',
    name: 'Qwen3-VL 30B',
    owned_by: 'this-mac',
    reasoning: false,
    reasoning_efforts: null,
    context_length: 262_144,
    max_output_length: 262_144,
    input_modalities: ['text', 'image'],
  },
  {
    id: 'gemma-4-26b',
    name: 'Gemma 4 26B',
    owned_by: 'my-macs',
    reasoning: true,
    reasoning_efforts: [...reasoningEfforts],
    context_length: 131_072,
    max_output_length: null,
    input_modalities: ['text', 'image'],
  },
];

const answers = [
  {
    reasoning:
      'They want to see which models this Mac serves. The local API lists them at /v1/models, so a short script that reads that list and prints each model with its context window answers it. The standard library is enough.\n\nI’ll keep it to a few lines and say where the key comes from.',
    content:
      'Here’s a small Python script that asks this Mac’s local API which models it serves:\n\n```python\nimport json, os, urllib.request\n\nbase = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:8000/v1")\nkey = os.environ["OPENAI_API_KEY"]\nrequest = urllib.request.Request(f"{base}/models", headers={"Authorization": f"Bearer {key}"})\nwith urllib.request.urlopen(request) as response:\n    for model in json.load(response)["data"]:\n        print(model["id"], model.get("context_length", "?"))\n```\n\nRun it with your local API key in `OPENAI_API_KEY`. Each line is one model and its **context window** in tokens.',
  },
  {
    reasoning:
      'A shell function is the quickest way to time one answer. curl with time around it, the model and the message in the body, and the key from the environment.',
    content:
      'Sure. This shell function times one answer from the local API:\n\n```bash\nask() {\n  time curl -s "$OPENAI_BASE_URL/chat/completions" \\\n    -H "Authorization: Bearer $OPENAI_API_KEY" \\\n    -H "Content-Type: application/json" \\\n    -d "{\\"model\\": \\"gpt-oss-20b\\", \\"messages\\": [{\\"role\\": \\"user\\", \\"content\\": \\"$1\\"}]}"\n}\n```\n\nThen `ask "Hello"` prints the answer and how long it took.',
  },
];

const memory =
  "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.";

// About one token each: a word with its leading space, long words in pieces.
export const pieces = (text: string) => text.match(/\s*[^\s]{1,5}|\s+/g) ?? [];

const listeners = new Set<(event: ChatEvent) => void>();
const timers = new Map<string, ReturnType<typeof setTimeout>>();
const usage = new Map<string, number>();
let asked = 0;

const publish = (event: ChatEvent) => listeners.forEach((listener) => listener(event));

function end(stream: string, event: ChatEvent) {
  clearTimeout(timers.get(stream));
  timers.delete(stream);
  usage.delete(stream);
  publish(event);
}

export const previewChatAPI: ChatAPI = {
  async chatModels(): Promise<ChatModels> {
    if (mode() === 'no_endpoint')
      return { models: [], code: 'no_endpoint', error: 'This Mac’s local API isn’t running.' };
    const base_url = 'http://127.0.0.1:8000/v1';
    if (mode() === 'unavailable')
      return {
        base_url,
        models: [],
        code: 'unavailable',
        error: 'This Mac’s local API didn’t answer.',
      };
    return { base_url, models: structuredClone(previewChatModels) };
  },
  async chatSend(value) {
    const request = validateChatRequest(value);
    if (mode() === 'no_endpoint') throw new Error('This Mac’s local API isn’t running.');
    if (timers.size >= 2)
      throw new Error('Two answers are already streaming. Wait for one to finish.');
    const stream = crypto.randomUUID();
    const model = previewChatModels.find((item) => item.id === request.model);
    const answer = answers[asked++ % answers.length];
    const reasoning = !model?.reasoning
      ? []
      : pieces(
          request.reasoning_effort === 'none' || request.reasoning_effort === 'minimal'
            ? answer.reasoning.split('\n')[0]
            : answer.reasoning,
        );
    const content = pieces(answer.content);
    const prompt = Math.ceil(
      request.messages.reduce((total, message) => total + message.content.length, 0) / 4,
    );
    const queue: Extract<ChatEvent, { text: string }>[] = [
      ...reasoning.map((text) => ({ stream, type: 'reasoning' as const, text })),
      ...content.map((text) => ({ stream, type: 'content' as const, text })),
    ];
    let written = 0;
    // Reading the prompt first, then about 55 tokens a second while it reasons and 42 after.
    const next = (delay: number) =>
      timers.set(
        stream,
        setTimeout(() => {
          if (mode() === 'fail') return end(stream, { stream, type: 'error', message: memory });
          const event = queue.shift();
          if (!event)
            return end(stream, {
              stream,
              type: 'done',
              finish_reason: 'stop',
              usage: { prompt_tokens: prompt, completion_tokens: written },
            });
          written++;
          usage.set(stream, written);
          publish(event);
          const following = queue[0];
          // A breath at each new paragraph, and a longer one where thinking turns to answering.
          const pause =
            following && following.type !== event.type
              ? 320
              : following?.text.startsWith('\n')
                ? 140
                : 0;
          next((event.type === 'reasoning' ? 18 : 24) + Math.round(Math.random() * 10) + pause);
        }, delay),
      );
    next(700);
    return { stream };
  },
  async chatCancel(stream) {
    if (!timers.has(stream)) return;
    end(stream, {
      stream,
      type: 'done',
      finish_reason: 'cancelled',
      usage: { completion_tokens: usage.get(stream) ?? 0 },
    });
  },
  onChat(callback) {
    listeners.add(callback);
    return () => {
      listeners.delete(callback);
    };
  },
};
