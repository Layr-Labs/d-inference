import type { Message } from "./store";
import type { ChatMessage } from "./api";
import { buildApiContent } from "./image-upload";

/**
 * Convert stored chat messages into the OpenAI/OpenRouter wire shape, inlining
 * attached images from the most recent image-bearing turn as `image_url`
 * content parts (text-only turns stay plain strings). Shared by the send and
 * retry paths so the transformation lives in one place.
 *
 * Only the newest image turn is sent upstream; older images remain visible
 * in chat state. Even one image turn can exceed the coordinator's 16 MiB body
 * cap after base64 and optional sealing. streamChat checks the complete
 * serialized request and sealed envelope before sending.
 *
 * NOTE: `m.images` is undefined for turns restored from persistence (images are
 * stripped from localStorage to protect the quota — see store.ts `partialize`),
 * so earlier-turn image context isn't re-sent after a page reload. Follow-up:
 * durable image storage (IndexedDB).
 */
export function toApiMessages(
  messages: Pick<Message, "role" | "content" | "images">[]
): ChatMessage[] {
  const newestImageIndex = findNewestImageMessageIndex(messages);

  return messages.flatMap((m, i) => {
    const images = i === newestImageIndex ? m.images : undefined;
    if ((!images || images.length === 0) && m.content.length === 0) {
      return [];
    }
    return [{
      role: m.role,
      content: buildApiContent(m.content, images),
    }];
  });
}

function findNewestImageMessageIndex(
  messages: Pick<Message, "images">[]
): number {
  return messages.findLastIndex((message) => Boolean(message.images?.length));
}
