// Benchmark SETUP Worker (isolated). Writes deterministic synthetic objects into
// the benchmark bucket so nothing has to be uploaded from the Mac. It is never
// in the download path: downloads go straight to the R2 custom domain.
const BLOCK_BYTES = 64 * 1024;

function int(v, name) { const n = Number(v); if (!Number.isSafeInteger(n) || n <= 0) throw new Error(`${name} must be a positive integer`); return n; }
function chunkKey(run, s, p) { return `runs/${run}/chunked/shard-${String(s).padStart(2, "0")}-part-${String(p).padStart(2, "0")}.bin`; }
function largeKey(run, s) { return `runs/${run}/large/shard-${String(s).padStart(2, "0")}.bin`; }

function block(shard, part) {
  const b = new Uint8Array(BLOCK_BYTES);
  for (let i = 0; i < b.length; i += 1) b[i] = (i * 131 + Math.floor(i / 251) * 17 + shard * 53 + part * 97) & 0xff;
  return b;
}
function repeated(blk, total) {
  const fixed = new FixedLengthStream(total);
  const w = fixed.writable.getWriter();
  const done = (async () => {
    let left = total;
    try { while (left > 0) { const n = Math.min(left, blk.byteLength); await w.write(n === blk.byteLength ? blk : blk.slice(0, n)); left -= n; } await w.close(); }
    catch (e) { await w.abort(e); throw e; }
  })();
  return { readable: fixed.readable, done };
}
const META = { contentType: "application/octet-stream", cacheControl: "public, max-age=31536000, immutable" };

export default {
  async fetch(request, env) {
    if (request.headers.get("X-Setup-Token") !== env.SETUP_TOKEN) return new Response("forbidden", { status: 403 });
    const url = new URL(request.url);
    const run = env.RUN_ID, shards = int(env.SHARD_COUNT, "SHARD_COUNT"), parts = int(env.CHUNKS_PER_SHARD, "CHUNKS_PER_SHARD"), chunkBytes = int(env.CHUNK_BYTES, "CHUNK_BYTES");
    const seg = url.pathname.split("/").filter(Boolean);
    const ok = (s, p) => s >= 1 && s <= shards && (p == null || (p >= 1 && p <= parts));

    if (request.method === "GET" && seg[0] === "status") {
      const out = [];
      for (let s = 1; s <= shards; s += 1) {
        const l = await env.BENCH_BUCKET.head(largeKey(run, s));
        out.push({ key: largeKey(run, s), size: l?.size ?? null, cacheControl: l?.httpMetadata?.cacheControl ?? null });
        for (let p = 1; p <= parts; p += 1) { const c = await env.BENCH_BUCKET.head(chunkKey(run, s, p)); out.push({ key: chunkKey(run, s, p), size: c?.size ?? null, cacheControl: c?.httpMetadata?.cacheControl ?? null }); }
      }
      return Response.json({ run, shards, parts, chunkBytes, objects: out });
    }
    if (request.method !== "POST") return new Response("method", { status: 405 });

    if (seg[0] === "chunk") {
      const s = Number(seg[1]), p = Number(seg[2]);
      if (!ok(s, p)) return new Response("bad shard/part", { status: 400 });
      const key = chunkKey(run, s, p);
      const existing = await env.BENCH_BUCKET.head(key);
      if (existing?.size === chunkBytes) return Response.json({ key, size: existing.size, created: false });
      const src = repeated(block(s, p), chunkBytes);
      const [obj] = await Promise.all([env.BENCH_BUCKET.put(key, src.readable, { httpMetadata: META, customMetadata: { purpose: "model-download-benchmark", run } }), src.done]);
      return Response.json({ key, size: obj.size, created: true });
    }
    if (seg[0] === "large") {
      const s = Number(seg[1]);
      if (!ok(s)) return new Response("bad shard", { status: 400 });
      const key = largeKey(run, s);
      if (seg[2] === "init") {
        const existing = await env.BENCH_BUCKET.head(key);
        if (existing?.size === chunkBytes * parts) return Response.json({ key, created: false });
        const mp = await env.BENCH_BUCKET.createMultipartUpload(key, { httpMetadata: META, customMetadata: { purpose: "model-download-benchmark", run } });
        return Response.json({ key, uploadId: mp.uploadId, created: true });
      }
      if (seg[2] === "part") {
        const p = Number(seg[3]); if (!ok(s, p)) return new Response("bad part", { status: 400 });
        const uploadId = url.searchParams.get("uploadId"); if (!uploadId) return new Response("uploadId", { status: 400 });
        const mp = env.BENCH_BUCKET.resumeMultipartUpload(key, uploadId);
        const src = repeated(block(s, p), chunkBytes);  // part p of the large object == chunk p, byte for byte
        const [part] = await Promise.all([mp.uploadPart(p, src.readable), src.done]);
        return Response.json({ key, partNumber: part.partNumber, etag: part.etag });
      }
      if (seg[2] === "complete") {
        const { uploadId, parts: uploaded } = await request.json();
        const mp = env.BENCH_BUCKET.resumeMultipartUpload(key, uploadId);
        const obj = await mp.complete(uploaded);
        return Response.json({ key, size: obj.size });
      }
    }
    return new Response("not found", { status: 404 });
  },
};
