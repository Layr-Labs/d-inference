// Summarises every <arm>-<pass> directory under a results root into a Markdown table.
// usage: node summarize.mjs <results-root>
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
const root = process.argv[2] ?? "results";
const rows = [];
for (const dir of readdirSync(root).filter((d) => /^(chunked|large)-/.test(d)).sort()) {
  const p = join(root, dir);
  if (!["timing.log", "cache-status.log", "verify.json", "throughput-MiBps.log"].every((f) => existsSync(join(p, f)))) continue; // pass still running or incomplete
  const timing = readFileSync(join(p, "timing.log"), "utf8");
  const wall = Number(/wall=([0-9.]+)/.exec(timing)?.[1] ?? NaN);
  const status = /status=(\d+)/.exec(timing)?.[1];
  const cache = readFileSync(join(p, "cache-status.log"), "utf8").trim().split("\n").map((l) => l.split(/\s+/));
  const counts = {}; const colos = new Set(); let bytes = 0;
  for (const c of cache) { counts[c[2]] = (counts[c[2]] ?? 0) + 1; colos.add(c[3]?.split("-").pop()); bytes += Number(c[1]); }
  const verify = JSON.parse(readFileSync(join(p, "verify.json"), "utf8"));
  const samples = readFileSync(join(p, "throughput-MiBps.log"), "utf8").trim().split("\n").map((l) => Number(l.split(" ")[1])).filter((n) => n > 0);
  const median = samples.length ? [...samples].sort((a, b) => a - b)[Math.floor(samples.length / 2)] : NaN;
  rows.push({
    pass: dir, objects: cache.length, gib: (bytes / 2 ** 30).toFixed(0), wall: wall.toFixed(1),
    aggregate: (bytes / wall / 2 ** 20).toFixed(1), median, min: Math.min(...samples), max: Math.max(...samples),
    cache: Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", "), colo: [...colos].join(","),
    verified: verify.allMatch ? "yes" : "NO", exit: status,
  });
}
const header = "| Pass | Objects | GiB | Wall s | Aggregate MiB/s | Per-second MiB/s median (min–max) | CF-Cache-Status after pass | Colo | Byte-identical |";
const sep = "|---|---|---|---|---|---|---|---|---|";
const lines = rows.map((r) => `| ${r.pass} | ${r.objects} | ${r.gib} | ${r.wall} | ${r.aggregate} | ${r.median} (${r.min}–${r.max}) | ${r.cache} | ${r.colo} | ${r.verified} |`);
console.log([header, sep, ...lines].join("\n"));
