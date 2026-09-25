// Computes the expected SHA-256 of every synthetic object (same generator as the
// setup Worker) and writes the stub coordinator catalog + Darkbloom manifests.
import { createHash } from "node:crypto";
import { writeFileSync, mkdirSync } from "node:fs";
const RUN = process.env.RUN_ID ?? "2026-09-01-r1";
const SHARDS = Number(process.env.SHARD_COUNT ?? 4), PARTS = Number(process.env.CHUNKS_PER_SHARD ?? 16), CHUNK = Number(process.env.CHUNK_BYTES ?? 67108864);
const BLOCK = 64 * 1024;
function block(shard, part) { const b = Buffer.alloc(BLOCK); for (let i = 0; i < BLOCK; i += 1) b[i] = (i * 131 + Math.floor(i / 251) * 17 + shard * 53 + part * 97) & 0xff; return b; }
function chunkDigest(s, p, into) { const h = createHash("sha256"); const blk = block(s, p); for (let left = CHUNK; left > 0;) { const n = Math.min(left, BLOCK); const piece = n === BLOCK ? blk : blk.subarray(0, n); h.update(piece); into?.update(piece); left -= n; } return h.digest("hex"); }
const pad = (n) => String(n).padStart(2, "0");
const chunkFiles = [], largeFiles = [], expected = { run: RUN, shards: [] };
for (let s = 1; s <= SHARDS; s += 1) {
  const shardHash = createHash("sha256"); const parts = [];
  for (let p = 1; p <= PARTS; p += 1) { const sha = chunkDigest(s, p, shardHash); const path = `shard-${pad(s)}-part-${pad(p)}.bin`; chunkFiles.push({ path, size_bytes: CHUNK, sha256: sha, role: "weight" }); parts.push({ path, sha256: sha }); }
  const shardSha = shardHash.digest("hex");
  largeFiles.push({ path: `shard-${pad(s)}.bin`, size_bytes: CHUNK * PARTS, sha256: shardSha, role: "weight" });
  expected.shards.push({ shard: s, size_bytes: CHUNK * PARTS, sha256: shardSha, parts });
}
function aggregate(files) { const h = createHash("sha256"); for (const f of [...files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) h.update(Buffer.from(f.sha256, "hex")); return h.digest("hex"); }
function model(kind, files) {
  const id = `bench-${kind}-${RUN}`, prefix = `runs/${RUN}/${kind}`, total = files.reduce((a, f) => a + f.size_bytes, 0), agg = aggregate(files);
  const catalog = { id, s3_name: id, display_name: `Benchmark ${kind} ${RUN}`, model_type: "text", size_gb: total / 1e9, active: true, version: RUN, r2_prefix: prefix, aggregate_sha256: agg, total_size_bytes: total, file_count: files.length, capabilities: ["chat"] };
  const manifest = { schema_version: 1, model_id: id, version: RUN, r2_prefix: prefix, aggregate_sha256: agg, total_size_bytes: total, file_count: files.length, files, created_at: "2026-09-01T00:00:00Z" };
  return { catalog, manifest };
}
const chunked = model("chunked", chunkFiles), large = model("large", largeFiles);
mkdirSync("out", { recursive: true });
writeFileSync("out/catalog.json", JSON.stringify({ models: [chunked.catalog, large.catalog], aliases: [] }, null, 2));
writeFileSync(`out/manifest-${chunked.catalog.id}.json`, JSON.stringify(chunked.manifest, null, 2));
writeFileSync(`out/manifest-${large.catalog.id}.json`, JSON.stringify(large.manifest, null, 2));
writeFileSync("out/expected.json", JSON.stringify(expected, null, 2));
console.log(JSON.stringify({ run: RUN, chunked: chunked.catalog.id, large: large.catalog.id, totalBytesPerArm: chunked.catalog.total_size_bytes, chunkFiles: chunkFiles.length, largeFiles: largeFiles.length }));
