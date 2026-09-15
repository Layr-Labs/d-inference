import { createReadStream } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const baseUrl = process.argv[2]?.replace(/\/$/, "");
const runId = process.argv[3];
if (baseUrl == null || runId == null) {
  throw new Error("usage: node benchmark-client.mjs <worker-base-url> <run-id>");
}

async function json(path, options) {
  const response = await fetch(`${baseUrl}${path}`, options);
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}: ${await response.text()}`);
  return response.json();
}

function sha256(path) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const input = createReadStream(path);
    input.on("data", (chunk) => hash.update(chunk));
    input.on("error", reject);
    input.on("end", () => resolve(hash.digest("hex")));
  });
}

function curl(url, outputPath, headersPath) {
  return new Promise((resolve, reject) => {
    const args = [
      "--http2", "--silent", "--show-error", "--fail", "--location",
      "--connect-timeout", "30", "--header", "Accept-Encoding: identity",
      "--output", outputPath, "--dump-header", headersPath,
      "--write-out", "%{http_code}\t%{size_download}\t%{speed_download}\t%{time_total}\t%{remote_ip}\n",
      url,
    ];
    const child = spawn("/usr/bin/curl", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error(`curl exited ${code}: ${stderr.trim()}`));
      const [httpCode, bytes, bytesPerSecond, seconds, remoteIp] = stdout.trim().split("\t");
      resolve({ httpCode: Number(httpCode), bytes: Number(bytes), bytesPerSecond: Number(bytesPerSecond), seconds: Number(seconds), remoteIp });
    });
  });
}

function headerValue(raw, name) {
  const prefix = `${name.toLowerCase()}:`;
  return raw.split(/\r?\n/).find((line) => line.toLowerCase().startsWith(prefix))?.slice(prefix.length).trim() ?? null;
}

async function runPass(label, identity, referenceHashes = null) {
  const directory = await mkdtemp(join(tmpdir(), `darkbloom-${label}-`));
  const started = performance.now();
  try {
    const downloads = await Promise.all(Array.from({ length: identity.shardCount }, async (_, index) => {
      const shard = index + 1;
      const outputPath = join(directory, `shard-${shard}.safetensors`);
      const headersPath = join(directory, `shard-${shard}.headers`);
      const stats = await curl(`${baseUrl}/${identity.runId}/shard-${shard}.safetensors`, outputPath, headersPath);
      const [hash, rawHeaders] = await Promise.all([sha256(outputPath), readFile(headersPath, "utf8")]);
      if (stats.bytes !== identity.logicalShardBytes) throw new Error(`shard ${shard} received ${stats.bytes} bytes`);
      if (referenceHashes != null && hash !== referenceHashes[index]) throw new Error(`shard ${shard} hash differs between cold and warm passes`);
      return {
        shard,
        sha256: hash,
        ...stats,
        mebibytesPerSecond: stats.bytesPerSecond / 1024 / 1024,
        cfRay: headerValue(rawHeaders, "cf-ray"),
        contentLength: Number(headerValue(rawHeaders, "content-length")),
      };
    }));
    const wallSeconds = (performance.now() - started) / 1000;
    const totalBytes = downloads.reduce((sum, item) => sum + item.bytes, 0);
    return {
      label,
      wallSeconds,
      totalBytes,
      aggregateMebibytesPerSecond: totalBytes / wallSeconds / 1024 / 1024,
      downloads,
    };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function waitForWarmCache(identity) {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const status = await json(`/__benchmark/${identity.runId}/cache-status`);
    if (status.hits === status.total) return status;
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error("backing chunks did not all enter the edge cache within 120 seconds");
}

const identity = await json(`/__benchmark/${runId}/identity`);

const before = await json(`/__benchmark/${identity.runId}/cache-status`);
if (before.hits !== 0) throw new Error(`cold precondition failed: ${before.hits}/${before.total} chunks are already cached`);
const cold = await runPass("cold", identity);
const afterCold = await waitForWarmCache(identity);
const warm = await runPass("warm", identity, cold.downloads.map((item) => item.sha256));
const afterWarm = await json(`/__benchmark/${identity.runId}/cache-status`);

console.log(JSON.stringify({
  measuredAt: new Date().toISOString(),
  endpoint: baseUrl,
  identity,
  cache: { before, afterCold, afterWarm },
  cold,
  warm,
  speedup: warm.aggregateMebibytesPerSecond / cold.aggregateMebibytesPerSecond,
}, null, 2));
