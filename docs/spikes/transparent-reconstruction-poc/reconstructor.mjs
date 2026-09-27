const RANGE_UNIT = "bytes=";

export class RangeNotSatisfiable extends Error {}

export function parseSingleRange(value, totalSize) {
  if (!Number.isSafeInteger(totalSize) || totalSize <= 0) {
    throw new TypeError("totalSize must be a positive safe integer");
  }
  if (value == null) {
    return { start: 0, end: totalSize - 1, partial: false };
  }

  const raw = value.trim();
  if (!raw.startsWith(RANGE_UNIT) || raw.includes(",")) {
    throw new RangeNotSatisfiable("only one byte range is supported");
  }
  const spec = raw.slice(RANGE_UNIT.length);
  const match = /^(\d*)-(\d*)$/.exec(spec);
  if (!match || (match[1] === "" && match[2] === "")) {
    throw new RangeNotSatisfiable("invalid byte range");
  }

  let start;
  let end;
  if (match[1] === "") {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) {
      throw new RangeNotSatisfiable("invalid suffix range");
    }
    start = Math.max(0, totalSize - suffixLength);
    end = totalSize - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === "" ? totalSize - 1 : Number(match[2]);
    if (
      !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) ||
      start < 0 ||
      end < start ||
      start >= totalSize
    ) {
      throw new RangeNotSatisfiable("range is outside the object");
    }
    end = Math.min(end, totalSize - 1);
  }

  return { start, end, partial: true };
}

export function validateReconstructionManifest(manifest) {
  if (!manifest || typeof manifest !== "object") {
    throw new TypeError("manifest is required");
  }
  if (!Number.isSafeInteger(manifest.totalSize) || manifest.totalSize <= 0) {
    throw new TypeError("manifest.totalSize must be a positive safe integer");
  }
  if (!Array.isArray(manifest.chunks) || manifest.chunks.length === 0) {
    throw new TypeError("manifest.chunks must not be empty");
  }

  let expectedOffset = 0;
  for (const chunk of manifest.chunks) {
    if (
      typeof chunk.key !== "string" ||
      chunk.key.length === 0 ||
      !Number.isSafeInteger(chunk.offset) ||
      !Number.isSafeInteger(chunk.size) ||
      chunk.size <= 0
    ) {
      throw new TypeError("every chunk needs a key, offset, and positive size");
    }
    if (chunk.offset !== expectedOffset) {
      throw new TypeError(`chunk ${chunk.key} begins at ${chunk.offset}, expected ${expectedOffset}`);
    }
    expectedOffset += chunk.size;
  }
  if (expectedOffset !== manifest.totalSize) {
    throw new TypeError(`chunks cover ${expectedOffset} bytes, expected ${manifest.totalSize}`);
  }
  return manifest;
}

function commonHeaders(manifest) {
  const headers = new Headers({
    "Accept-Ranges": "bytes",
    "Cache-Control": manifest.cacheControl ?? "public, max-age=31536000, immutable",
    "Content-Type": manifest.contentType ?? "application/octet-stream",
  });
  if (manifest.etag) headers.set("ETag", manifest.etag);
  if (manifest.lastModified) headers.set("Last-Modified", manifest.lastModified);
  return headers;
}

export function overlappingChunks(manifest, start, end) {
  return manifest.chunks.flatMap((chunk) => {
    const chunkEnd = chunk.offset + chunk.size - 1;
    if (chunkEnd < start || chunk.offset > end) return [];
    const originalStart = Math.max(start, chunk.offset);
    const originalEnd = Math.min(end, chunkEnd);
    return [{
      chunk,
      localStart: originalStart - chunk.offset,
      localEnd: originalEnd - chunk.offset,
    }];
  });
}

async function checkedChunkBody(fetchChunk, selection, signal) {
  signal.throwIfAborted();
  const { chunk, localStart, localEnd } = selection;
  const wholeChunk = localStart === 0 && localEnd === chunk.size - 1;
  const response = await fetchChunk(chunk, {
    start: localStart,
    end: localEnd,
    wholeChunk,
    signal,
  });
  try {
    // A fetcher may settle after cancellation even when given an aborted signal.
    signal.throwIfAborted();
    const expectedStatus = wholeChunk ? 200 : 206;
    if (response.status !== expectedStatus || response.body == null) {
      throw new Error(`chunk ${chunk.key} returned HTTP ${response.status}, expected ${expectedStatus}`);
    }
    if (!wholeChunk) {
      const expectedRange = `bytes ${localStart}-${localEnd}/${chunk.size}`;
      if (response.headers.get("Content-Range") !== expectedRange) {
        throw new Error(`chunk ${chunk.key} returned an invalid Content-Range`);
      }
    }
    const expectedLength = localEnd - localStart + 1;
    const declaredLength = response.headers.get("Content-Length");
    if (declaredLength != null && Number(declaredLength) !== expectedLength) {
      throw new Error(`chunk ${chunk.key} returned an invalid Content-Length`);
    }
    return { reader: response.body.getReader(), expectedLength, chunk };
  } catch (error) {
    // Invalid responses never transfer ownership to the reconstruction reader.
    // Preserve the validation error even if disposing of the body also fails.
    await response.body?.cancel(error).catch(() => {});
    throw error;
  }
}

async function cancelChunkBody(body, reason) {
  try {
    await body.reader.cancel(reason);
  } catch {
    // Cleanup must not replace the stream's original failure/cancellation.
  } finally {
    body.reader.releaseLock();
  }
}

export function reconstructedBody(selections, fetchChunk, expectedBytes, signal) {
  let selectionIndex = 0;
  let current = null;
  let currentBytes = 0;
  let emittedBytes = 0;
  let cancelled = false;
  const cancellation = new AbortController();
  const chunkSignal = signal == null
    ? cancellation.signal
    : AbortSignal.any([signal, cancellation.signal]);

  async function cancelCurrent(reason) {
    const body = current;
    current = null;
    if (body != null) await cancelChunkBody(body, reason);
  }

  return new ReadableStream({
    async pull(controller) {
      try {
        while (true) {
          if (cancelled) return;
          chunkSignal.throwIfAborted();
          if (current == null) {
            if (selectionIndex >= selections.length) {
              if (emittedBytes !== expectedBytes) {
                throw new Error(`reconstruction emitted ${emittedBytes} bytes, expected ${expectedBytes}`);
              }
              controller.close();
              return;
            }
            const body = await checkedChunkBody(fetchChunk, selections[selectionIndex], chunkSignal);
            if (cancelled) {
              await cancelChunkBody(body, cancellation.signal.reason);
              return;
            }
            current = body;
            currentBytes = 0;
            selectionIndex += 1;
          }

          const item = await current.reader.read();
          if (cancelled) return;
          chunkSignal.throwIfAborted();
          if (item.done) {
            if (currentBytes !== current.expectedLength) {
              throw new Error(
                `chunk ${current.chunk.key} emitted ${currentBytes} bytes, expected ${current.expectedLength}`,
              );
            }
            current.reader.releaseLock();
            current = null;
            continue;
          }

          currentBytes += item.value.byteLength;
          emittedBytes += item.value.byteLength;
          if (currentBytes > current.expectedLength || emittedBytes > expectedBytes) {
            throw new Error("chunk response exceeded its declared reconstruction boundary");
          }
          controller.enqueue(item.value);
          return;
        }
      } catch (error) {
        cancellation.abort(error);
        await cancelCurrent(error);
        if (!cancelled) controller.error(error);
      }
    },
    async cancel(reason) {
      cancelled = true;
      cancellation.abort(reason);
      await cancelCurrent(reason);
    },
  });
}

export function createTransparentReconstructor({ manifest, fetchChunk, fixedLengthStreamFactory = null }) {
  validateReconstructionManifest(manifest);
  if (typeof fetchChunk !== "function") throw new TypeError("fetchChunk is required");

  return async function handle(request, lifecycle = null) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    }

    const headers = commonHeaders(manifest);
    if (request.method === "HEAD") {
      headers.set("Content-Length", String(manifest.totalSize));
      return new Response(null, { status: 200, headers });
    }

    let range;
    try {
      range = parseSingleRange(request.headers.get("Range"), manifest.totalSize);
    } catch (error) {
      if (!(error instanceof RangeNotSatisfiable)) throw error;
      headers.set("Content-Range", `bytes */${manifest.totalSize}`);
      return new Response(null, { status: 416, headers });
    }

    const contentLength = range.end - range.start + 1;
    headers.set("Content-Length", String(contentLength));
    if (range.partial) {
      headers.set("Content-Range", `bytes ${range.start}-${range.end}/${manifest.totalSize}`);
    }
    const selections = overlappingChunks(manifest, range.start, range.end);
    const source = reconstructedBody(selections, fetchChunk, contentLength, request.signal);
    let body = source;
    if (fixedLengthStreamFactory != null) {
      const fixed = fixedLengthStreamFactory(contentLength);
      const completion = source.pipeTo(fixed.writable);
      if (lifecycle?.waitUntil != null) lifecycle.waitUntil(completion);
      else void completion.catch(() => {});
      body = fixed.readable;
    }
    return new Response(body, { status: range.partial ? 206 : 200, headers });
  };
}
