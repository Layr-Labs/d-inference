import nacl from "tweetnacl";

// Matches the coordinator's plaintext and sender-sealed transport body caps.
// Later coordinator rewrites still have their own authoritative size checks.
export const MAX_CHAT_REQUEST_BYTES = 16 * 1024 * 1024;

export class ChatRequestTooLargeError extends Error {
  constructor() {
    super("This message is too large to send. Use fewer or smaller images, shorten the conversation, or start a new chat.");
    this.name = "ChatRequestTooLargeError";
  }
}

/** Check serialized UTF-8 bytes, including the full history and request options. */
export function assertChatRequestBudget(body: string, willSeal = false): void {
  const bytes = new TextEncoder().encode(body).byteLength;
  if (bytes > MAX_CHAT_REQUEST_BYTES) throw new ChatRequestTooLargeError();

  // A proven lower bound before fetching a key or allocating ciphertext:
  // base64(nonce || authenticated ciphertext), excluding all envelope metadata.
  // A fitting lower bound still requires a check of the actual sealed envelope.
  const ciphertextBytes = bytes + nacl.box.nonceLength + nacl.box.overheadLength;
  if (willSeal && 4 * Math.ceil(ciphertextBytes / 3) > MAX_CHAT_REQUEST_BYTES) {
    throw new ChatRequestTooLargeError();
  }
}
