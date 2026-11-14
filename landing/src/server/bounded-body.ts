/**
 * Bytes past the limit that are read and discarded before an oversized body
 * is refused. A server that answers while the client is still sending, and
 * then closes the connection with those bytes unread, resets it, and the
 * client can lose the refusal (seen with Node 22 clients on Linux). Draining
 * a bounded amount lets an ordinary oversized upload finish and read its 413;
 * past it, the connection is dropped.
 */
const DRAIN_LIMIT_BYTES = 1 << 20;

/**
 * Reads a request body as UTF-8 text, or returns null when it is larger than
 * `maximumBytes`. The limit is enforced on the bytes actually received, so a
 * body sent without Content-Length (chunked HTTP/1.1, HTTP/2) cannot bypass
 * it, and an oversized body is refused before any of it is parsed: past the
 * limit, bytes are counted and discarded, not kept. A declared Content-Length
 * over the limit only refuses earlier.
 */
export async function readBoundedText(request: Request, maximumBytes: number): Promise<string | null> {
  if (Number(request.headers.get("content-length")) > maximumBytes) return null;
  if (!request.body) return "";

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return received > maximumBytes ? null : text + decoder.decode();
    received += value.byteLength;
    if (received > maximumBytes + DRAIN_LIMIT_BYTES) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    if (received > maximumBytes) text = "";
    else text += decoder.decode(value, { stream: true });
  }
}
