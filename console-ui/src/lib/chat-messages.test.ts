import { describe, it, expect } from "vitest";
import { toApiMessages } from "./chat-messages";
import type { Message } from "./store";

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
      msg({ role: "user", content: "what is this", images: ["data:image/png;base64,AAA"] }),
    ]);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          { type: "text", text: "what is this" },
          { type: "image_url", image_url: { url: "data:image/png;base64,AAA" } },
        ],
      },
    ]);
  });

  it("maps a mixed conversation (text turn + image turn) correctly", () => {
    const out = toApiMessages([
      msg({ role: "user", content: "earlier text" }),
      msg({ role: "assistant", content: "reply" }),
      msg({ role: "user", content: "", images: ["data:image/jpeg;base64,BBB"] }),
    ]);
    expect(out[0]).toEqual({ role: "user", content: "earlier text" });
    expect(out[1]).toEqual({ role: "assistant", content: "reply" });
    expect(out[2]).toEqual({
      role: "user",
      content: [{ type: "image_url", image_url: { url: "data:image/jpeg;base64,BBB" } }],
    });
  });
});
