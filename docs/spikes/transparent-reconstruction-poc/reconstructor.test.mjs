import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  createTransparentReconstructor,
  parseSingleRange,
  validateReconstructionManifest,
} from "./reconstructor.mjs";

function deterministicBytes(size) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 131 + Math.floor(i / 97)) % 256);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function makeFixture() {
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
  return {
    original,
    objects,
    manifest: {
      totalSize: original.length,
      sha256: sha256(original),
      etag: `"sha256-${sha256(original)}"`,
      contentType: "application/octet-stream",
      chunks,
    },
  };
}

function inMemoryChunkFetcher(objects, options = {}) {
  const requests = [];
  const failuresRemaining = new Map(Object.entries(options.failOnce ?? {}));

  async function fetchChunk(chunk, request) {
    const source = objects.get(chunk.key);
    if (source == null) return new Response(null, { status: 404 });
    requests.push({ key: chunk.key, ...request });

    const selected = source.slice(request.start, request.end + 1);
    const headers = new Headers({
      "Content-Length": String(selected.length),
      ETag: `"${chunk.sha256}"`,
    });
    if (!request.wholeChunk) {
      headers.set("Content-Range", `bytes ${request.start}-${request.end}/${chunk.size}`);
    }

    const remaining = failuresRemaining.get(chunk.key) ?? 0;
    if (remaining > 0) {
      failuresRemaining.set(chunk.key, remaining - 1);
      const prefixLength = Math.min(options.failAfterBytes ?? 997, selected.length);
      const body = new ReadableStream({
        start(controller) {
          controller.enqueue(selected.slice(0, prefixLength));
          controller.error(new Error(`synthetic transport failure for ${chunk.key}`));
        },
      });
      return new Response(body, { status: request.wholeChunk ? 200 : 206, headers });
    }

    return new Response(selected, { status: request.wholeChunk ? 200 : 206, headers });
  }

  return { fetchChunk, requests };
}

async function bytesOf(response) {
  return new Uint8Array(await response.arrayBuffer());
}

test("full GET reconstructs the exact original object", async () => {
  const fixture = makeFixture();
  const source = inMemoryChunkFetcher(fixture.objects);
  const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });
  const response = await handle(new Request("https://models.example/original.safetensors"));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Length"), String(fixture.original.length));
  assert.equal(response.headers.get("Accept-Ranges"), "bytes");
  assert.equal(response.headers.get("ETag"), fixture.manifest.etag);
  const reconstructed = await bytesOf(response);
  assert.deepEqual(reconstructed, fixture.original);
  assert.equal(sha256(reconstructed), fixture.manifest.sha256);
});

test("HEAD preserves the original identity without fetching chunks", async () => {
  const fixture = makeFixture();
  const source = inMemoryChunkFetcher(fixture.objects);
  const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });
  const response = await handle(new Request("https://models.example/original.safetensors", { method: "HEAD" }));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Length"), String(fixture.original.length));
  assert.equal(response.headers.get("ETag"), fixture.manifest.etag);
  assert.equal((await response.arrayBuffer()).byteLength, 0);
  assert.equal(source.requests.length, 0);
});

test("single ranges, suffix ranges, and chunk-boundary ranges are exact", async () => {
  const fixture = makeFixture();
  const ranges = [
    { header: "bytes=0-0", start: 0, end: 0 },
    { header: "bytes=4090-4100", start: 4090, end: 4100 },
    { header: "bytes=12000-90000", start: 12000, end: 90000 },
    { header: "bytes=255000-", start: 255000, end: fixture.original.length - 1 },
    { header: "bytes=-777", start: fixture.original.length - 777, end: fixture.original.length - 1 },
    { header: `bytes=${fixture.original.length - 1}-999999`, start: fixture.original.length - 1, end: fixture.original.length - 1 },
  ];

  await Promise.all(ranges.map(async ({ header, start, end }) => {
    const source = inMemoryChunkFetcher(fixture.objects);
    const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });
    const response = await handle(new Request("https://models.example/original.safetensors", {
      headers: { Range: header },
    }));
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("Content-Range"), `bytes ${start}-${end}/${fixture.original.length}`);
    assert.equal(response.headers.get("Content-Length"), String(end - start + 1));
    assert.deepEqual(await bytesOf(response), fixture.original.slice(start, end + 1));
  }));
});

test("unsatisfiable and multi-range requests return a resumable 416 contract", async () => {
  const fixture = makeFixture();
  const source = inMemoryChunkFetcher(fixture.objects);
  const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });
  for (const header of [`bytes=${fixture.original.length}-`, "bytes=0-1,4-5", "items=0-1"] ) {
    const response = await handle(new Request("https://models.example/original.safetensors", {
      headers: { Range: header },
    }));
    assert.equal(response.status, 416);
    assert.equal(response.headers.get("Content-Range"), `bytes */${fixture.original.length}`);
  }
});

test("a mid-chunk transport failure resumes from the exact received byte", async () => {
  const fixture = makeFixture();
  const failingKey = fixture.manifest.chunks[3].key;
  const source = inMemoryChunkFetcher(fixture.objects, {
    failOnce: { [failingKey]: 1 },
    failAfterBytes: 1_337,
  });
  const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });

  const received = [];
  let offset = 0;
  let attempts = 0;
  while (offset < fixture.original.length && attempts < 4) {
    attempts += 1;
    const headers = offset === 0 ? {} : { Range: `bytes=${offset}-` };
    const response = await handle(new Request("https://models.example/original.safetensors", { headers }));
    assert.equal(response.status, offset === 0 ? 200 : 206);
    if (offset > 0) {
      assert.equal(response.headers.get("Content-Range"), `bytes ${offset}-${fixture.original.length - 1}/${fixture.original.length}`);
    }
    const reader = response.body.getReader();
    try {
      while (true) {
        const item = await reader.read();
        if (item.done) break;
        received.push(item.value);
        offset += item.value.byteLength;
      }
    } catch {
      // Mirrors the Swift client: keep the durable prefix and retry with bytes=N-.
    }
  }

  const reconstructed = Buffer.concat(received.map((part) => Buffer.from(part)));
  assert.equal(attempts, 2);
  assert.equal(reconstructed.length, fixture.original.length);
  assert.deepEqual(reconstructed, Buffer.from(fixture.original));
  assert.equal(sha256(reconstructed), fixture.manifest.sha256);
});

test("random concurrent ranges reconstruct exactly", async () => {
  const fixture = makeFixture();
  const source = inMemoryChunkFetcher(fixture.objects);
  const handle = createTransparentReconstructor({ manifest: fixture.manifest, fetchChunk: source.fetchChunk });
  const cases = Array.from({ length: 64 }, (_, i) => {
    const start = (i * 7_919) % fixture.original.length;
    const width = 1 + ((i * 3_571) % 40_000);
    return { start, end: Math.min(fixture.original.length - 1, start + width - 1) };
  });
  await Promise.all(cases.map(async ({ start, end }) => {
    const response = await handle(new Request("https://models.example/original.safetensors", {
      headers: { Range: `bytes=${start}-${end}` },
    }));
    assert.deepEqual(await bytesOf(response), fixture.original.slice(start, end + 1));
  }));
});

test("manifest validation rejects gaps and coverage mismatches", () => {
  const fixture = makeFixture();
  const gap = structuredClone(fixture.manifest);
  gap.chunks[1].offset += 1;
  assert.throws(() => validateReconstructionManifest(gap), /expected/);

  const short = structuredClone(fixture.manifest);
  short.totalSize += 1;
  assert.throws(() => validateReconstructionManifest(short), /expected/);
});

test("range parser supports offsets larger than 32 bits", () => {
  const total = 5_368_328_247;
  assert.deepEqual(parseSingleRange("bytes=5000000000-", total), {
    start: 5_000_000_000,
    end: total - 1,
    partial: true,
  });
});
