import type { Message } from "./store";
import type { ChatMessage } from "./api";
import { buildApiContent } from "./image-upload";

/**
 * Convert stored chat messages into the OpenAI/OpenRouter wire shape, inlining
 * any attached images as `image_url` content parts (text-only turns stay plain
 * strings). Shared by the send and retry paths so the transformation lives in
 * one place.
 *
 * NOTE: `m.images` is undefined for turns restored from persistence (images are
 * stripped from localStorage to protect the quota — see store.ts `partialize`),
 * so earlier-turn image context isn't re-sent after a page reload. Follow-up:
 * durable image storage (IndexedDB).
 */
export function toApiMessages(
  messages: Pick<Message, "role" | "content" | "images">[]
): ChatMessage[] {
  return messages.map((m) => ({
    role: m.role,
    content: buildApiContent(m.content, m.images),
  }));
}
