import type { Message } from "./store";
import type { ChatMessage } from "./api";
import { buildApiContent } from "./image-upload";

/**
 * Convert stored chat messages into the OpenAI/OpenRouter wire shape, inlining
 * attached images from the most recent image-bearing turn as `image_url`
 * content parts (text-only turns stay plain strings). Shared by the send and
 * retry paths so the transformation lives in one place.
 *
 * The coordinator caps plaintext inference bodies at 64 MiB. One UI turn may
 * carry four 10 MB images (~53 MiB after base64), so resending multiple image
 * turns from live chat history would breach that cap. Older images remain in
 * the visible chat state, but only the newest image turn is sent upstream.
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
  let index = messages.length;
  for (const message of [...messages].reverse()) {
    index -= 1;
    if (message.images && message.images.length > 0) {
      return index;
    }
  }
  return -1;
}
