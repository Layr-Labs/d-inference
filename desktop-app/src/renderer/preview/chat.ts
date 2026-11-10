import {
  reasoningEfforts,
  validateChatRequest,
  type ChatAPI,
  type ChatEvent,
  type ChatModel,
  type ChatModels,
} from '../../shared/chat';
import { effectiveRoute, type RequestRoute } from '../../shared/localServing';
import { networkChatModels, readPublic, type NetworkChatModel } from '../previewNetwork';
import { previewParam, type FeaturePreview, type PreviewStore } from './types';

// Development preview of chat: a simulated local API that streams canned answers, with
// reasoning and a code block, at about the pace a Mac writes them. It lists models as the local
// API does for the route that applies (Studio, or `&route=`): this Mac's, then your other Macs'
// once requests may go to them, then, with My Macs first, the Darkbloom network's, read from the
// production catalog when the dev server reaches it. Development data only, apart from the
// network's list.
//
// `&chat=no_endpoint`: this Mac runs no local API. `&chat=unavailable`: the local API doesn't
// answer. `&chat=fail`: it refuses each answer as a busy Mac does (503, in its own words).
//
// Nothing here runs or is built when the module loads (data comes from functions, state is made
// on first use), so a production build, which never uses the preview, leaves it all out.
const mode = () => previewParam('chat');

export const chatPreview: FeaturePreview = {
  // Without a local API the snapshot has no endpoint either, as the runtime reports it.
  snapshot: (snapshot) =>
    mode() === 'no_endpoint' ? { ...snapshot, endpoint: undefined } : snapshot,
};

export const previewChatModels = (): ChatModel[] => [
  {
    id: 'gpt-oss-20b',
    name: 'GPT-OSS 20B',
    owned_by: 'this-mac',
    reasoning: true,
    reasoning_efforts: reasoningEfforts.slice(),
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
    reasoning_efforts: reasoningEfforts.slice(),
    context_length: 131_072,
    max_output_length: null,
    input_modalities: ['text', 'image'],
  },
];

// The network's models when the dev server can't read the catalog: some that the production
// catalog listed on 2026-11-09, in its own format.
export const previewNetworkModels = (): NetworkChatModel[] =>
  networkChatModels({
    models: [
      {
        id: 'gemma-4-26b-qat-4bit',
        display_name: 'Gemma 4 26B',
        supported_features: ['json_mode', 'reasoning', 'tools'],
        max_context_length: 131_072,
        max_output_length: 32_768,
        input_modalities: ['text', 'image', 'video'],
      },
      {
        id: 'EigenLabs/Qwen3.8-27B-4bit-mtp',
        display_name: 'Qwen 3.8 27B',
        supported_features: ['tools'],
        max_context_length: 262_144,
        max_output_length: 65_536,
        input_modalities: ['text', 'image'],
      },
      {
        id: 'glm-5.3-flash',
        display_name: 'Z.ai: GLM-5.3-Flash',
        supported_features: ['logprobs', 'reasoning', 'tools'],
        max_context_length: 262_144,
        max_output_length: 65_536,
        input_modalities: ['text', 'image', 'video'],
      },
      {
        id: 'mimo-v2.6-flash-mopd',
        display_name: 'Xiaomi: MiMo-V2.6-Flash',
        supported_features: ['reasoning', 'tools'],
        max_context_length: 1_048_576,
        max_output_length: 131_072,
        input_modalities: ['text'],
      },
    ],
    aliases: [
      {
        id: 'gemma-4-26b',
        display_name: 'Gemma 4 26B',
        desired_build: 'gemma-4-26b-qat-4bit',
        primary_build: 'gemma-4-26b-qat-4bit',
      },
    ],
  });

// The network's models, from the production catalog and the builds Macs serve now; the
// fallback above when either read fails.
async function networkModels() {
  const [catalog, capacity] = await Promise.all([
    readPublic('/v1/models/catalog?include_aliases=1'),
    readPublic('/v1/models/capacity'),
  ]);
  try {
    if (catalog !== undefined) return networkChatModels(catalog, capacity);
  } catch {}
  return previewNetworkModels();
}

// The local API's list for a route (LocalRouter.swift): this Mac's models, your other Macs' with
// `my-macs` and `my-macs-first`, and the network's with `my-macs-first` only. Each model is listed
// once, and a network alias of a build this Mac serves is left out (LocalRouterModels.swift).
export function routeModels(route: RequestRoute, network: NetworkChatModel[] = []): ChatModel[] {
  const own = previewChatModels();
  const here = own.filter((model) => model.owned_by === 'this-mac');
  const listed = route === 'this-mac' ? here : own;
  if (route !== 'my-macs-first') return listed;
  const seen = new Set(listed.map((model) => model.id));
  const local = new Set(here.map((model) => model.id));
  for (const { model, builds } of network) {
    if (seen.has(model.id) || builds.some((build) => local.has(build))) continue;
    seen.add(model.id);
    listed.push(model);
  }
  return listed;
}

const answers = () => [
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

let made:
  | {
      listeners: Set<(event: ChatEvent) => void>;
      timers: Map<string, ReturnType<typeof setTimeout>>;
      usage: Map<string, number>;
      asked: number;
      // The models the last list named, so an answer from any of them reasons as it says.
      listed: ChatModel[];
    }
  | undefined;
const state = () =>
  (made ??= { listeners: new Set(), timers: new Map(), usage: new Map(), asked: 0, listed: [] });

const publish = (event: ChatEvent) => state().listeners.forEach((listener) => listener(event));

function end(stream: string, event: ChatEvent) {
  const { timers, usage } = state();
  clearTimeout(timers.get(stream));
  timers.delete(stream);
  usage.delete(stream);
  publish(event);
}

// The chat API over the preview's state, whose `[local]` route decides the list.
export const previewChatAPI = (store: PreviewStore): ChatAPI => ({
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
    const route = effectiveRoute(store.get().local ?? {});
    const models = routeModels(route, route === 'my-macs-first' ? await networkModels() : []);
    state().listed = models;
    return { base_url, models };
  },
  async chatSend(value) {
    const request = validateChatRequest(value);
    const { timers, usage, listed } = state();
    if (mode() === 'no_endpoint') throw new Error('This Mac’s local API isn’t running.');
    if (timers.size >= 2)
      throw new Error('Two answers are already streaming. Wait for one to finish.');
    const stream = crypto.randomUUID();
    const model = [...listed, ...previewChatModels()].find((item) => item.id === request.model);
    const canned = answers();
    const answer = canned[state().asked++ % canned.length];
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
    const { timers, usage } = state();
    if (!timers.has(stream)) return;
    end(stream, {
      stream,
      type: 'done',
      finish_reason: 'cancelled',
      usage: { completion_tokens: usage.get(stream) ?? 0 },
    });
  },
  onChat(callback) {
    const { listeners } = state();
    listeners.add(callback);
    return () => {
      listeners.delete(callback);
    };
  },
});
