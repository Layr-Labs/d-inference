import { createHash } from "node:crypto";

import { createTransparentReconstructor } from "./reconstructor.mjs";

function deterministicBytes(size) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 131 + Math.floor(i / 97)) % 256);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

const original = deterministicBytes(256_111);
const requestedSizes = [4_093, 8_191, 16_381, 32_749, 65_519];
const chunks = [];
const objects = new Map();
let offset = 0;
let index = 0;
while (offset < original.length) {
  const size = Math.min(requestedSizes[index % requestedSizes.length], original.length - offset);
  const key = `chunks/part-${String(index).padStart(4, "0")}`;
  const bytes = original.slice(offset, offset + size);
  chunks.push({ key, offset, size, sha256: sha256(bytes) });
  objects.set(key, bytes);
  offset += size;
  index += 1;
}

const manifest = {
  totalSize: original.length,
  sha256: sha256(original),
  etag: `"sha256-${sha256(original)}"`,
  contentType: "application/octet-stream",
  chunks,
};

function makeChunkFetcher(failAtOriginalOffset = null) {
  return async function fetchChunk(chunk, request) {
    const source = objects.get(chunk.key);
    if (source == null) return new Response(null, { status: 404 });
    const selected = source.slice(request.start, request.end + 1);
    const headers = new Headers({ "Content-Length": String(selected.length) });
    if (!request.wholeChunk) {
      headers.set("Content-Range", `bytes ${request.start}-${request.end}/${chunk.size}`);
    }

    const selectedOriginalStart = chunk.offset + request.start;
    const selectedOriginalEnd = chunk.offset + request.end;
    if (
      failAtOriginalOffset != null &&
      failAtOriginalOffset >= selectedOriginalStart &&
      failAtOriginalOffset <= selectedOriginalEnd
    ) {
      const prefixLength = failAtOriginalOffset - selectedOriginalStart;
      const body = new ReadableStream({
        start(controller) {
          if (prefixLength > 0) controller.enqueue(selected.slice(0, prefixLength));
          controller.error(new Error(`synthetic transport failure at ${failAtOriginalOffset}`));
        },
      });
      return new Response(body, {
        status: request.wholeChunk ? 200 : 206,
        headers,
      });
    }

    return new Response(selected, {
      status: request.wholeChunk ? 200 : 206,
      headers,
    });
  };
}

const reconstruct = createTransparentReconstructor({
  manifest,
  fetchChunk: makeChunkFetcher(),
  fixedLengthStreamFactory: (length) => new FixedLengthStream(length),
});

function lifecycleFor(ctx) {
  return {
    waitUntil(promise) {
      ctx.waitUntil(promise.catch((error) => {
        console.error(JSON.stringify({
          message: "reconstruction stream failed",
          error: error instanceof Error ? error.message : String(error),
        }));
      }));
    },
  };
}

export default {
  async fetch(request, _env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/__test/identity") {
      return Response.json({
        totalSize: manifest.totalSize,
        sha256: manifest.sha256,
        chunkCount: manifest.chunks.length,
      });
    }
    if (url.pathname !== "/original.safetensors") return new Response("not found", { status: 404 });
    const failAtRaw = request.headers.get("X-Test-Fail-At")
      ?? (url.searchParams.has("failAt") ? url.searchParams.get("failAt") : null);
    const failAt = failAtRaw == null ? null : Number(failAtRaw);
    if (failAt != null && (!Number.isSafeInteger(failAt) || failAt < 0 || failAt >= manifest.totalSize)) {
      return new Response("invalid failAt", { status: 400 });
    }
    if (failAt != null) {
      const failingReconstructor = createTransparentReconstructor({
        manifest,
        fetchChunk: makeChunkFetcher(failAt),
        fixedLengthStreamFactory: (length) => new FixedLengthStream(length),
      });
      return failingReconstructor(request, lifecycleFor(ctx));
    }
    return reconstruct(request, lifecycleFor(ctx));
  },
};
