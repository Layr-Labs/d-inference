// Chat with the models this Mac serves on its local API (Only me, or Both, me first), as the
// iPhone app's chat does on the phone. The Electron main process makes every request: the
// renderer never receives the local API key, and only a loopback base URL is ever called.

// One model the local API lists (`GET <base_url>/models`).
export interface ChatModel {
  id: string;
  name?: string | null;
  // The model reasons before it answers, and the reasoning efforts it takes (`low`, `medium`,
  // `high`, …) when the local API says so.
  reasoning?: boolean;
  reasoning_efforts?: string[] | null;
  context_length?: number | null;
}

export interface ChatModels {
  // The local API's base URL, such as `http://127.0.0.1:8001/v1`; absent with no local API.
  base_url?: string;
  models: ChatModel[];
  // Why chat is unavailable: `no_endpoint` (this Mac runs no local API: Darkbloom network only,
  // or stopped), `unavailable` (the local API didn't answer).
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
  reasoning_effort?: string;
  max_tokens?: number;
  temperature?: number;
}

// Streamed answer events for one request, in order, ending with `done` or `error`.
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
