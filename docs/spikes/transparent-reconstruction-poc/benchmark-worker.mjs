import { createTransparentReconstructor } from "./reconstructor.mjs";

const SHARD_COUNT = 4;
const CHUNKS_PER_SHARD = 4;
const BLOCK_BYTES = 64 * 1024;

function positiveInteger(value, name) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name} must be a positive integer`);
  return parsed;
}

function objectKey(runId, shard, part) {
  return `runs/${runId}/shard-${shard}/part-${String(part).padStart(2, "0")}.bin`;
}

function cacheKey(runId, key) {
  return new Request(`https://cache.darkbloom-benchmark.invalid/${runId}/${key}`, { method: "GET" });
}

function deterministicBlock(shard, part) {
  const bytes = new Uint8Array(BLOCK_BYTES);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (index * 131 + Math.floor(index / 251) * 17 + shard * 53 + part * 97) & 0xff;
  }
  return bytes;
}

function fixedLengthRepeatedBlock(block, totalBytes) {
  const fixed = new FixedLengthStream(totalBytes);
  const writer = fixed.writable.getWriter();
  const completion = (async () => {
    let remaining = totalBytes;
    try {
      while (remaining > 0) {
        const length = Math.min(remaining, block.byteLength);
        await writer.write(length === block.byteLength ? block : block.slice(0, length));
        remaining -= length;
      }
      await writer.close();
    } catch (error) {
      await writer.abort(error);
      throw error;
    }
  })();
  return { readable: fixed.readable, completion };
}

function manifestFor(env, shard) {
  const chunkBytes = positiveInteger(env.CHUNK_BYTES, "CHUNK_BYTES");
  return {
    totalSize: chunkBytes * CHUNKS_PER_SHARD,
    etag: `"darkbloom-benchmark-${env.BENCH_RUN_ID}-shard-${shard}"`,
    cacheControl: "no-store",
    contentType: "application/octet-stream",
    chunks: Array.from({ length: CHUNKS_PER_SHARD }, (_, index) => ({
      key: objectKey(env.BENCH_RUN_ID, shard, index + 1),
      offset: index * chunkBytes,
      size: chunkBytes,
    })),
  };
}

async function setupObject(request, env, shard, part) {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  if (request.headers.get("X-Setup-Token") !== env.SETUP_TOKEN) return new Response("forbidden", { status: 403 });
  if (shard < 1 || shard > SHARD_COUNT || part < 1 || part > CHUNKS_PER_SHARD) {
    return new Response("invalid shard or part", { status: 400 });
  }

  const chunkBytes = positiveInteger(env.CHUNK_BYTES, "CHUNK_BYTES");
  const key = objectKey(env.BENCH_RUN_ID, shard, part);
  const existing = await env.BENCH_BUCKET.head(key);
  if (existing?.size === chunkBytes) return Response.json({ key, size: existing.size, created: false });
  if (existing != null) return new Response("existing object has the wrong size", { status: 409 });

  const source = fixedLengthRepeatedBlock(deterministicBlock(shard, part), chunkBytes);
  const upload = env.BENCH_BUCKET.put(key, source.readable, {
    httpMetadata: {
      contentType: "application/octet-stream",
      cacheControl: "public, max-age=31536000, immutable",
    },
    customMetadata: { purpose: "darkbloom-transparent-reconstruction-benchmark", runId: env.BENCH_RUN_ID },
  });
  const [stored] = await Promise.all([upload, source.completion]);
  return Response.json({ key, size: stored.size, created: true });
}

async function cacheStatus(env) {
  const cache = caches.default;
  const entries = [];
  for (let shard = 1; shard <= SHARD_COUNT; shard += 1) {
    for (let part = 1; part <= CHUNKS_PER_SHARD; part += 1) {
      const key = objectKey(env.BENCH_RUN_ID, shard, part);
      entries.push({ shard, part, hit: (await cache.match(cacheKey(env.BENCH_RUN_ID, key))) != null });
    }
  }
  return Response.json({
    runId: env.BENCH_RUN_ID,
    hits: entries.filter((entry) => entry.hit).length,
    total: entries.length,
    entries,
  }, { headers: { "Cache-Control": "no-store" } });
}

function chunkFetcher(env, ctx, shard) {
  return async (chunk, selection) => {
    if (selection.wholeChunk) {
      const key = cacheKey(env.BENCH_RUN_ID, chunk.key);
      const cache = caches.default;
      const cached = await cache.match(key);
      if (cached != null) {
        console.log(JSON.stringify({ event: "chunk", runId: env.BENCH_RUN_ID, shard, key: chunk.key, cache: "HIT" }));
        return cached;
      }

      const object = await env.BENCH_BUCKET.get(chunk.key);
      if (object == null) return new Response(null, { status: 404 });
      const headers = new Headers({
        "Cache-Control": "public, max-age=31536000, immutable",
        "Content-Length": String(chunk.size),
        "Content-Type": "application/octet-stream",
        "X-Benchmark-Backing-Cache": "MISS",
      });
      const response = new Response(object.body, { status: 200, headers });
      ctx.waitUntil(cache.put(key, response.clone()));
      console.log(JSON.stringify({ event: "chunk", runId: env.BENCH_RUN_ID, shard, key: chunk.key, cache: "MISS" }));
      return response;
    }

    const length = selection.end - selection.start + 1;
    const object = await env.BENCH_BUCKET.get(chunk.key, {
      range: { offset: selection.start, length },
    });
    if (object == null) return new Response(null, { status: 404 });
    return new Response(object.body, {
      status: 206,
      headers: {
        "Cache-Control": "no-store",
        "Content-Length": String(length),
        "Content-Range": `bytes ${selection.start}-${selection.end}/${chunk.size}`,
        "Content-Type": "application/octet-stream",
      },
    });
  };
}

function lifecycle(ctx) {
  return {
    waitUntil(promise) {
      ctx.waitUntil(promise.catch((error) => console.error(JSON.stringify({
        event: "reconstruction-error",
        error: error instanceof Error ? error.message : String(error),
      }))));
    },
  };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === `/__benchmark/${env.BENCH_RUN_ID}/identity`) {
      const chunkBytes = positiveInteger(env.CHUNK_BYTES, "CHUNK_BYTES");
      return Response.json({
        purpose: "non-production-transparent-reconstruction-benchmark",
        runId: env.BENCH_RUN_ID,
        shardCount: SHARD_COUNT,
        chunksPerShard: CHUNKS_PER_SHARD,
        chunkBytes,
        logicalShardBytes: chunkBytes * CHUNKS_PER_SHARD,
      }, { headers: { "Cache-Control": "no-store" } });
    }
    if (url.pathname === `/__benchmark/${env.BENCH_RUN_ID}/cache-status`) return cacheStatus(env);

    const setup = new RegExp(`^/__benchmark/${env.BENCH_RUN_ID}/setup/(\\d+)/(\\d+)$`).exec(url.pathname);
    if (setup != null) return setupObject(request, env, Number(setup[1]), Number(setup[2]));

    const match = new RegExp(`^/${env.BENCH_RUN_ID}/shard-(\\d+)\\.safetensors$`).exec(url.pathname);
    if (match == null) return new Response("not found", { status: 404 });
    const shard = Number(match[1]);
    if (shard < 1 || shard > SHARD_COUNT) return new Response("not found", { status: 404 });

    const reconstruct = createTransparentReconstructor({
      manifest: manifestFor(env, shard),
      fetchChunk: chunkFetcher(env, ctx, shard),
      fixedLengthStreamFactory: (length) => new FixedLengthStream(length),
    });
    const response = await reconstruct(request, lifecycle(ctx));
    const headers = new Headers(response.headers);
    headers.set("Content-Disposition", `attachment; filename="shard-${shard}.safetensors"`);
    headers.set("X-Benchmark-Run", env.BENCH_RUN_ID);
    headers.set("X-Benchmark-Shard", String(shard));
    return new Response(response.body, { status: response.status, headers });
  },
};
