import { describe, expect, it } from "vitest";
import { sealRawRequest } from "../encryption";
import nacl from "tweetnacl";
import { assertChatRequestBudget, ChatRequestTooLargeError } from "./request-budget";

const LIMIT = 16 * 1024 * 1024;

describe("chat request byte budget", () => {
  it("accepts the exact plaintext cap and refuses one additional UTF-8 byte", () => {
    expect(() => assertChatRequestBudget("a".repeat(LIMIT))).not.toThrow();
    expect(() => assertChatRequestBudget("a".repeat(LIMIT + 1))).toThrow(ChatRequestTooLargeError);
  });

  it("counts multibyte text rather than UTF-16 code units", () => {
    expect(() => assertChatRequestBudget("雪".repeat(Math.floor(LIMIT / 3) + 1))).toThrow(ChatRequestTooLargeError);
  });

  it("uses only a lower bound before sealing, leaving metadata to the final check", () => {
    // This ciphertext alone fits exactly, although its envelope cannot fit.
    const largestCiphertextOnlyBody = 3 * (LIMIT / 4) - 24 - 16;
    expect(() => assertChatRequestBudget("a".repeat(largestCiphertextOnlyBody), true)).not.toThrow();
    expect(() => assertChatRequestBudget("a".repeat(largestCiphertextOnlyBody + 1), true)).toThrow(ChatRequestTooLargeError);
  });

  it.each([0, 1, 2])("matches real NaCl/base64 padding for remainder %i", (remainder) => {
    const body = new TextEncoder().encode("雪".repeat(5) + "a".repeat(remainder));
    const key = nacl.box.keyPair();
    const sealed = sealRawRequest(body, { kid: '"雪\\key', publicKey: key.publicKey });
    const envelope = JSON.parse(sealed.envelopeJson);
    expect(envelope.ciphertext.length).toBe(4 * Math.ceil((body.byteLength + 24 + 16) / 3));
    expect(envelope.ciphertext.length).toBeLessThan(new TextEncoder().encode(sealed.envelopeJson).byteLength);
    expect(() => assertChatRequestBudget(sealed.envelopeJson)).not.toThrow();
  });
});
