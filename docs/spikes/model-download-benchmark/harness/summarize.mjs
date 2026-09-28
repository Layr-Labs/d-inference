// Summarises every <arm>-<pass> directory under a results root into a Markdown table.
// usage: node summarize.mjs <results-root>
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
const root = process.argv[2] ?? "results";
const rows = [];
for (const dir of readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory() && /^(chunked|large)-/.test(d.name)).map((d) => d.name).sort()) {
  const p = join(root, dir);
  const read = (name) => existsSync(join(p, name)) ? readFileSync(join(p, name), "utf8") : "";
  const complete = ["timing.log", "cache-status.log", "verify.json", "throughput-MiBps.log"].every((f) => existsSync(join(p, f)));
  const timing = read("timing.log");
  const wall = Number(/wall=([0-9.]+)/.exec(timing)?.[1] ?? NaN);
  const status = /status=(\d+)/.exec(timing)?.[1];
  const passStatus = read("status.log");
  const stage = /stage=(\w+)/.exec(passStatus)?.[1];
  const passExit = /status=(\d+)/.exec(passStatus)?.[1];
  // Historical runs predate status.log; their timing and verification are authoritative.
  const passComplete = !existsSync(join(p, "status.log")) || (stage === "complete" && passExit === "0");
  const cache = read("cache-status.log").trim().split("\n").filter(Boolean).map((l) => l.split(/\s+/));
  const counts = {}; const colos = new Set(); let bytes = 0;
  for (const c of cache) {
    const cacheStatus = c[2] ?? "unknown";
    counts[cacheStatus] = (counts[cacheStatus] ?? 0) + 1;
    if (c[3]) colos.add(c[3].split("-").pop());
    bytes += Number(c[1]);
  }
  let verify;
  try { verify = JSON.parse(read("verify.json")); } catch { /* A failed or running verifier may leave an empty/partial file. */ }
  const samples = read("throughput-MiBps.log").trim().split("\n").map((l) => Number(l.trim().split(/\s+/)[1])).filter((n) => Number.isFinite(n) && n > 0);
  const validBytes = cache.length > 0 && cache.every((c) => Number.isFinite(Number(c[1])) && Number(c[1]) > 0);
  const success = complete && passComplete && status === "0" && verify?.allMatch === true && validBytes && Number.isFinite(wall) && wall > 0;
  const failed = (status && status !== "0") || verify?.allMatch === false;
  const median = samples.length ? [...samples].sort((a, b) => a - b)[Math.floor(samples.length / 2)] : undefined;
  rows.push({
    pass: dir, objects: cache.length, gib: validBytes ? (bytes / 2 ** 30).toFixed(0) : "N/A", wall: Number.isFinite(wall) ? wall.toFixed(1) : "N/A",
    aggregate: success ? (bytes / wall / 2 ** 20).toFixed(1) : "N/A",
    samples: success && samples.length ? `${median} (${Math.min(...samples)}–${Math.max(...samples)})` : "N/A",
    cache: Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", ") || "N/A", colo: [...colos].join(",") || "N/A",
    verified: verify?.allMatch === true ? "yes" : verify?.allMatch === false ? "NO" : "incomplete",
    download: status === "0" ? "success" : status ? `failed (exit ${status})` : "incomplete",
    outcome: success ? "success" : passExit && passExit !== "0" ? `failed (${stage ?? "unknown"}, exit ${passExit})` : failed ? "failed" : "incomplete",
  });
}
const header = "| Pass | Objects | GiB | Wall s | Aggregate MiB/s | Per-second MiB/s median (min–max) | CF-Cache-Status after pass | Colo | Byte-identical | Download | Outcome |";
const sep = "|---|---|---|---|---|---|---|---|---|---|---|";
const lines = rows.map((r) => `| ${r.pass} | ${r.objects} | ${r.gib} | ${r.wall} | ${r.aggregate} | ${r.samples} | ${r.cache} | ${r.colo} | ${r.verified} | ${r.download} | ${r.outcome} |`);
console.log([header, sep, ...lines].join("\n"));
