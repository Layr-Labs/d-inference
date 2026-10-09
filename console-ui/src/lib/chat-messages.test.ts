import { describe, it, expect } from "vitest";
import { toApiMessages } from "./chat-messages";
import type { Message } from "./store";

const PNG_IMAGE = "data:image/png;base64,AAA";
const JPEG_IMAGE = "data:image/jpeg;base64,BBB";
const OLD_ANSWER = "old answer";

function msg(partial: Pick<Message, "role" | "content"> & Partial<Message>): Message {
  return { id: "x", timestamp: 0, ...partial };
}

describe("toApiMessages", () => {
  it("returns [] for an empty list", () => {
    expect(toApiMessages([])).toEqual([]);
  });

  it("preserves roles and keeps text-only turns as plain strings", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "hi" }),
      msg({ role: "assistant", content: "hello" }),
    ]);
    expect(out).toEqual([
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
    ]);
  });

  it("inlines attached images as text-first image_url parts", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "what is this", images: [PNG_IMAGE] }),
    ]);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          { type: "text", text: "what is this" },
          { type: "image_url", image_url: { url: PNG_IMAGE } },
        ],
      },
    ]);
  });

  it("maps a mixed conversation (text turn + image turn) correctly", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "earlier text" }),
      msg({ role: "assistant", content: "reply" }),
      msg({ role: "user", content: "", images: [JPEG_IMAGE] }),
    ]);
    expect(out[0]).toEqual({ role: "user", content: "earlier text" });
    expect(out[1]).toEqual({ role: "assistant", content: "reply" });
    expect(out[2]).toEqual({
      role: "user",
      content: [{ type: "image_url", image_url: { url: JPEG_IMAGE } }],
    });
  });

  it("keeps only the newest image-bearing turn to stay under the coordinator body cap", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "old image", images: [PNG_IMAGE] }),
      msg({ role: "assistant", content: OLD_ANSWER }),
      msg({ role: "user", content: "new image", images: [JPEG_IMAGE] }),
    ]);

    expect(out).toEqual([
      { role: "user", content: "old image" },
      { role: "assistant", content: OLD_ANSWER },
      {
        role: "user",
        content: [
          { type: "text", text: "new image" },
          { type: "image_url", image_url: { url: JPEG_IMAGE } },
        ],
      },
    ]);
  });

  it("drops older image-only turns after pruning their image data", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "", images: [PNG_IMAGE] }),
      msg({ role: "assistant", content: OLD_ANSWER }),
      msg({ role: "user", content: "", images: [JPEG_IMAGE] }),
    ]);

    expect(out).toEqual([
      { role: "assistant", content: OLD_ANSWER },
      {
        role: "user",
        content: [{ type: "image_url", image_url: { url: JPEG_IMAGE } }],
      },
    ]);
  });
});
