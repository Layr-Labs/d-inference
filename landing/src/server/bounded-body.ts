/**
 * Reads a request body as UTF-8 text, or returns null when it is larger than
 * `maximumBytes`. The limit is enforced on the bytes actually received, so a
 * body sent without Content-Length (chunked HTTP/1.1, HTTP/2) cannot bypass
 * it, and an oversized body is refused before any of it is parsed. A declared
 * Content-Length over the limit only refuses earlier.
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
    if (done) return text + decoder.decode();
    received += value.byteLength;
    if (received > maximumBytes) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
}
