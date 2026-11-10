// Chat with the models this Mac serves on its local API (Only me, or Both, me first), as the
// iPhone app's chat does on the phone. The Electron main process makes every request: the
// renderer never receives the local API key, and only a loopback base URL is ever called.

// The reasoning efforts the local API takes, least reasoning first. Every model that reasons takes
// all seven, each as its family's nearest level (`none` switches thinking off where the model
// can); a model that doesn't reason ignores them, and anything else is refused with a 400
// (docs/provider/direct-mode.md#reasoning-effort,
// provider-swift/Sources/ProviderCore/Inference/Prompting/ReasoningEffort.swift).
export const reasoningEfforts = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
] as const;
export type ReasoningEffort = (typeof reasoningEfforts)[number];

export const isReasoningEffort = (value: unknown): value is ReasoningEffort =>
  typeof value === 'string' && (reasoningEfforts as readonly string[]).includes(value);

// One model the local API lists (`GET <base_url>/models`: the local router's list,
// provider-swift/Sources/ProviderCore/Server/LocalRouterModels.swift, `LocalRouterModelEntry`).
export interface ChatModel {
  id: string;
  // The list's display name (your other Macs' and the network's models), else this Mac's own
  // name for a model it serves (`Snapshot.models`); null when neither says.
  name?: string | null;
  // Where the model runs (`owned_by`): `this-mac` (this Mac, or its pair), `my-macs` (your other
  // Macs, free) or `darkbloom` (the network, billed to the account). Older local APIs say `local`.
  owned_by?: string | null;
  // The model reasons (`supported_features` lists `reasoning`); null when the list doesn't say.
  reasoning?: boolean | null;
  // The efforts it takes: every one of `reasoningEfforts` for a model that reasons, else null.
  reasoning_efforts?: ReasoningEffort[] | null;
  // Tokens: the context window (`context_length`, or vLLM's `max_model_len`) and the longest
  // answer (`max_output_length`), when the list knows them.
  context_length?: number | null;
  max_output_length?: number | null;
  // What a request may carry (`text`, `image`, `video`). Chat sends text.
  input_modalities?: string[] | null;
}

export interface ChatModels {
  // The local API's base URL, such as `http://127.0.0.1:8001/v1`; absent with no local API.
  base_url?: string;
  models: ChatModel[];
  // Why chat is unavailable: `no_endpoint` (this Mac runs no local API: Darkbloom network only,
  // or stopped), `unavailable` (the local API didn't answer, refused the list, or isn't on this
  // Mac's loopback address). `error` is the local API's own message when it gave one.
  error?: string;
  code?: 'no_endpoint' | 'unavailable';
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  reasoning_effort?: ReasoningEffort;
  max_tokens?: number;
  temperature?: number;
}

// What one request may carry. The main process refuses anything larger; the page sends the
// newest messages that fit.
export const chatLimits = { messages: 200, characters: 400_000, modelID: 256 } as const;

// Streamed answer events for one request, in order, ending with `done` or `error`. A request the
// person stopped ends with `done` and `finish_reason: 'cancelled'`.
export type ChatEvent =
  | { stream: string; type: 'reasoning'; text: string }
  | { stream: string; type: 'content'; text: string }
  | {
      stream: string;
      type: 'done';
      finish_reason?: string | null;
      usage?: { prompt_tokens?: number; completion_tokens?: number } | null;
    }
  | { stream: string; type: 'error'; message: string };

export interface ChatAPI {
  chatModels(): Promise<ChatModels>;
  // Starts one streamed request and returns its stream ID; its events arrive through `onChat`.
  chatSend(request: ChatRequest): Promise<{ stream: string }>;
  chatCancel(stream: string): Promise<void>;
  onChat(callback: (event: ChatEvent) => void): () => void;
}

const controlCharacters = /[\u0000-\u001f\u007f]/;
const tooLong = 'This chat is too long to send. Start a new chat.';

// Checks a request from the renderer and returns a clean copy (unknown fields dropped), or throws
// with the reason in plain words. Shared, so the page can check before it sends.
export function validateChatRequest(value: unknown): ChatRequest {
  const request = value as Partial<Record<keyof ChatRequest, unknown>> | null;
  if (!request || typeof request !== 'object') throw new Error('Invalid chat request.');
  const model = request.model;
  if (
    typeof model !== 'string' ||
    !model.trim() ||
    model.length > chatLimits.modelID ||
    controlCharacters.test(model)
  )
    throw new Error('Choose a model.');
  const messages = request.messages;
  if (!Array.isArray(messages) || messages.length === 0) throw new Error('Write a message first.');
  if (messages.length > chatLimits.messages) throw new Error(tooLong);
  let characters = 0;
  const clean: ChatMessage[] = messages.map((message: unknown) => {
    const item = message as Partial<ChatMessage> | null;
    if (
      !item ||
      (item.role !== 'system' && item.role !== 'user' && item.role !== 'assistant') ||
      typeof item.content !== 'string'
    )
      throw new Error('Invalid chat request.');
    characters += item.content.length;
    return { role: item.role, content: item.content };
  });
  if (characters > chatLimits.characters) throw new Error(tooLong);
  const result: ChatRequest = { model, messages: clean };
  if (request.reasoning_effort !== undefined) {
    if (!isReasoningEffort(request.reasoning_effort))
      throw new Error('Choose a reasoning effort this Mac takes.');
    result.reasoning_effort = request.reasoning_effort;
  }
  if (request.max_tokens !== undefined) {
    const tokens = request.max_tokens;
    if (typeof tokens !== 'number' || !Number.isInteger(tokens) || tokens < 1 || tokens > 4_194_304)
      throw new Error('Invalid chat request.');
    result.max_tokens = tokens;
  }
  if (request.temperature !== undefined) {
    const temperature = request.temperature;
    if (typeof temperature !== 'number' || !(temperature >= 0 && temperature <= 2))
      throw new Error('Invalid chat request.');
    result.temperature = temperature;
  }
  return result;
}
