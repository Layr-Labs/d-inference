import type { ChatEvent, ChatModels, ChatRequest } from '../shared/chat';
import type { Backend } from './backend';

// Chat with this Mac's local API. The main process holds the local API key and makes every
// request, so the renderer never sees it; only a loopback base URL from the native snapshot is
// ever called. Each streamed answer is published as ChatEvents tagged with its stream ID.
export class ChatRelay {
  constructor(
    private backend: Backend,
    private publish: (event: ChatEvent) => void,
  ) {}

  async models(): Promise<ChatModels> {
    return { models: [], error: 'Chat is not available in this build.', code: 'unavailable' };
  }

  async send(_request: unknown): Promise<{ stream: string }> {
    void this.backend;
    void this.publish;
    throw new Error('Chat is not available in this build.');
  }

  async cancel(_stream: unknown) {}

  // Ends every stream, such as when the window navigates or closes.
  reset() {}
}

export type { ChatRequest };
