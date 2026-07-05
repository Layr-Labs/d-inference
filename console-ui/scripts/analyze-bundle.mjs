#!/usr/bin/env node
/**
 * Reconstruct per-route "First Load JS" from the Next.js build output.
 *
 * Turbopack does not print Size / First Load JS columns (see the perf report),
 * so this script recovers them from the prerendered route HTML in
 * `.next/server/app/**.html` (ground truth for the chunks an initial navigation
 * pulls) plus the on-disk `.next/static/chunks/*.js` byte sizes (raw + gzip).
 *
 * Usage:
 *   node scripts/analyze-bundle.mjs            # human-readable table
 *   node scripts/analyze-bundle.mjs --json     # machine-readable JSON
 *   node scripts/analyze-bundle.mjs --budget   # enforce budgets, exit 1 on breach
 *
 * Budgets (gzip): shared baseline <= SHARED_BUDGET_KB, any route <= ROUTE_BUDGET_KB.
 */
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const APP_DIR = join(ROOT, ".next", "server", "app");
const STATIC_DIR = join(ROOT, ".next", "static");

// Gzip budgets, in KB. Generous vs. a "healthy" Next baseline (~130 KB) because
// the Privy auth SDK is a hard product requirement; the goal is to prevent
// silent regression, not to hit an aspirational number in one pass.
const SHARED_BUDGET_KB = Number(process.env.SHARED_BUDGET_KB ?? 450);
const ROUTE_BUDGET_KB = Number(process.env.ROUTE_BUDGET_KB ?? 650);

const args = new Set(process.argv.slice(2));
const asJson = args.has("--json");
const enforceBudget = args.has("--budget");

function walk(dir, test) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, test));
    else if (test(full)) out.push(full);
  }
  return out;
}

// Map chunk basename -> { raw, gz } measured once from disk.
const chunkSizes = new Map();
function chunkSize(name) {
  if (chunkSizes.has(name)) return chunkSizes.get(name);
  const path = join(STATIC_DIR, name);
  let size = { raw: 0, gz: 0 };
  if (existsSync(path)) {
    const buf = readFileSync(path);
    size = { raw: buf.length, gz: gzipSync(buf).length };
  }
  chunkSizes.set(name, size);
  return size;
}

const CHUNK_RE = /\/_next\/static\/([^"']+\.js)/g;

const htmlFiles = walk(APP_DIR, (f) => f.endsWith(".html"));
if (htmlFiles.length === 0) {
  console.error("No prerendered HTML found. Run `npm run build` first.");
  process.exit(2);
}

// route name -> Set(chunk basenames under static/chunks)
const routeChunks = new Map();
for (const file of htmlFiles) {
  const route =
    "/" +
    relative(APP_DIR, file)
      .replace(/\.html$/, "")
      .replace(/(^|\/)index$/, "");
  const html = readFileSync(file, "utf8");
  const chunks = new Set();
  for (const m of html.matchAll(CHUNK_RE)) chunks.add(m[1]);
  routeChunks.set(route === "/" ? "/" : route, chunks);
}

// Shared baseline: chunks present on >= ceil(80%) of routes.
const routeCount = routeChunks.size;
const sharedThreshold = Math.max(2, Math.floor(routeCount * 0.8));
const chunkFreq = new Map();
for (const chunks of routeChunks.values())
  for (const c of chunks) chunkFreq.set(c, (chunkFreq.get(c) ?? 0) + 1);
const sharedChunks = new Set(
  [...chunkFreq].filter(([, n]) => n >= sharedThreshold).map(([c]) => c),
);

let sharedRaw = 0;
let sharedGz = 0;
for (const c of sharedChunks) {
  const s = chunkSize(c);
  sharedRaw += s.raw;
  sharedGz += s.gz;
}

const rows = [];
for (const [route, chunks] of routeChunks) {
  let raw = 0;
  let gz = 0;
  let specRaw = 0;
  let specGz = 0;
  for (const c of chunks) {
    const s = chunkSize(c);
    raw += s.raw;
    gz += s.gz;
    if (!sharedChunks.has(c)) {
      specRaw += s.raw;
      specGz += s.gz;
    }
  }
  rows.push({ route, gz, raw, specGz, specRaw });
}
rows.sort((a, b) => b.gz - a.gz);

const kb = (n) => (n / 1024).toFixed(1);
const result = {
  shared: { gz: sharedGz, raw: sharedRaw, chunks: sharedChunks.size },
  routes: rows,
  budgets: { sharedKb: SHARED_BUDGET_KB, routeKb: ROUTE_BUDGET_KB },
};

if (asJson) {
  console.log(JSON.stringify(result, null, 2));
} else {
  console.log(
    `\nShared baseline: ${kb(sharedGz)} KB gz / ${kb(sharedRaw)} KB raw (${sharedChunks.size} chunks, on >= ${sharedThreshold}/${routeCount} routes)\n`,
  );
  console.log("Route                          First Load (gz)   Route-specific (gz)");
  console.log("-".repeat(72));
  for (const r of rows) {
    console.log(
      `${r.route.padEnd(30)} ${(kb(r.gz) + " KB").padStart(13)} ${(kb(r.specGz) + " KB").padStart(20)}`,
    );
  }
  console.log("");
}

if (enforceBudget) {
  const breaches = [];
  if (sharedGz / 1024 > SHARED_BUDGET_KB)
    breaches.push(
      `shared baseline ${kb(sharedGz)} KB > ${SHARED_BUDGET_KB} KB budget`,
    );
  for (const r of rows)
    if (r.gz / 1024 > ROUTE_BUDGET_KB)
      breaches.push(`route ${r.route} ${kb(r.gz)} KB > ${ROUTE_BUDGET_KB} KB budget`);
  if (breaches.length) {
    console.error("\nBundle budget FAILED:");
    for (const b of breaches) console.error("  - " + b);
    process.exit(1);
  }
  console.log("Bundle budget OK.");
}
