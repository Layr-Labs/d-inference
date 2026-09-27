// Reconstruct original shard hashes from ordered chunks or large-arm files.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [,, kind, dir] = process.argv;
function validateExpected(expected) {
  if (!Array.isArray(expected?.shards) || expected.shards.length === 0) {
    throw new Error("expected manifest must contain at least one shard");
  }
  const ids = new Set(), paths = new Set();
  for (const shard of expected.shards) {
    if (!Number.isSafeInteger(shard.shard) || shard.shard <= 0 || ids.has(shard.shard) ||
        !Number.isSafeInteger(shard.size_bytes) || shard.size_bytes <= 0 ||
        !/^[a-f0-9]{64}$/.test(shard.sha256) || !Array.isArray(shard.parts) || shard.parts.length === 0) {
      throw new Error("invalid or duplicate expected shard");
    }
    ids.add(shard.shard);
    for (const part of shard.parts) {
      if (typeof part?.path !== "string" || !/^[A-Za-z0-9_-]+\.bin$/.test(part.path) || paths.has(part.path) ||
          !/^[a-f0-9]{64}$/.test(part.sha256)) {
        throw new Error("invalid or duplicate expected chunk");
      }
      paths.add(part.path);
    }
  }
}
async function feed(hash, path) {
  let bytes = 0;
  for await (const chunk of createReadStream(path)) { hash.update(chunk); bytes += chunk.length; }
  return bytes;
}
try {
  if (!["chunked", "large"].includes(kind) || !dir) throw new Error("usage: verify.mjs <chunked|large> <snapshot>");
  const expected = JSON.parse(readFileSync("out/expected.json", "utf8"));
  validateExpected(expected);
  const results = [];
  for (const shard of expected.shards) {
    const hash = createHash("sha256");
    const files = kind === "chunked" ? shard.parts.map(part => join(dir, part.path)) :
      [join(dir, `shard-${String(shard.shard).padStart(2, "0")}.bin`)];
    if (files.some(file => !existsSync(file))) {
      results.push({ shard: shard.shard, ok: false, error: "missing file" });
      continue;
    }
    let bytes = 0;
    for (const file of files) bytes += await feed(hash, file);
    const reconstructed = hash.digest("hex");
    results.push({ shard: shard.shard, expected: shard.sha256, reconstructed,
      ok: reconstructed === shard.sha256 && bytes === shard.size_bytes, files: files.length });
  }
  const allMatch = results.every(result => result.ok);
  console.log(JSON.stringify({ kind, allMatch, results }, null, 2));
  process.exitCode = allMatch ? 0 : 1;
} catch (error) {
  console.log(JSON.stringify({ kind, allMatch: false, error: error.message, results: [] }, null, 2));
  process.exitCode = 1;
}
