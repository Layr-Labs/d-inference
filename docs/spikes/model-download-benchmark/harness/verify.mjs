// Reconstructs each original shard from the downloaded chunk files (in order),
// hashes it, and compares against expected.json. Also hashes the large-arm files.
import { createHash } from "node:crypto"; import { createReadStream, existsSync } from "node:fs"; import { join } from "node:path";
const [,, kind, dir] = process.argv; import { readFileSync } from "node:fs"; const expected = JSON.parse(readFileSync("out/expected.json", "utf8"));
async function feed(h, path) { for await (const c of createReadStream(path)) h.update(c); }
const results = [];
for (const sh of expected.shards) {
  const h = createHash("sha256"); const files = kind === "chunked" ? sh.parts.map((p) => join(dir, p.path)) : [join(dir, `shard-${String(sh.shard).padStart(2, "0")}.bin`)];
  if (files.some((f) => !existsSync(f))) { results.push({ shard: sh.shard, ok: false, error: "missing file" }); continue; }
  for (const f of files) await feed(h, f);
  const got = h.digest("hex"); results.push({ shard: sh.shard, expected: sh.sha256, reconstructed: got, ok: got === sh.sha256, files: files.length });
}
console.log(JSON.stringify({ kind, allMatch: results.every((r) => r.ok), results }, null, 2)); process.exit(results.every((r) => r.ok) ? 0 : 1);
