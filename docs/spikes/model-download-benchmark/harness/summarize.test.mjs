import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const script = fileURLToPath(new URL("./summarize.mjs", import.meta.url));
const successful = {
  "timing.log": "start 2026-09-01\nend 2026-09-01 status=0 wall=4.25\n",
  "cache-status.log": "a.bin 1073741824 HIT abc-IAD\nb.bin 1073741824 HIT def-IAD\n",
  "verify.json": '{"allMatch":true}',
  "throughput-MiBps.log": "1 300\n2 100\n3 200\n4 400\n",
};

function summarize(t, overrides = {}) {
  const root = mkdtempSync(join(tmpdir(), "benchmark-summary-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const pass = join(root, "chunked-cold");
  mkdirSync(pass);
  for (const [name, content] of Object.entries({ ...successful, ...overrides })) {
    if (content !== null) writeFileSync(join(pass, name), content);
  }
  const result = spawnSync(process.execPath, [script, root], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout, /NaN|Infinity|undefined/);
  const [header, , row] = result.stdout.trim().split("\n").map((line) => line.split("|").slice(1, -1).map((cell) => cell.trim()));
  assert.ok(row, "incomplete and failed passes must remain visible");
  return Object.fromEntries(header.map((name, i) => [name, row[i]]));
}

test("legacy successful results retain their measurements", (t) => {
  assert.deepEqual(summarize(t), {
    Pass: "chunked-cold", Objects: "2", GiB: "2", "Wall s": "4.3",
    "Aggregate MiB/s": "481.9", "Per-second MiB/s median (min–max)": "300 (100–400)",
    "CF-Cache-Status after pass": "2 HIT", Colo: "IAD", "Byte-identical": "yes",
    Download: "success", Outcome: "success",
  });
});

test("completed new runs display successful outcome", (t) => {
  const row = summarize(t, { "status.log": "stage=complete status=0\n" });
  assert.equal(row.Outcome, "success");
  assert.equal(row["Aggregate MiB/s"], "481.9");
});

test("failed downloader cannot present remote object sizes as successful throughput", (t) => {
  const row = summarize(t, { "timing.log": "status=7 wall=4.25\n" });
  assert.equal(row.Download, "failed (exit 7)");
  assert.equal(row.Outcome, "failed");
  assert.equal(row["Aggregate MiB/s"], "N/A");
  assert.equal(row["Per-second MiB/s median (min–max)"], "N/A");
});

test("verification mismatch suppresses successful throughput", (t) => {
  const row = summarize(t, { "verify.json": '{"allMatch":false}' });
  assert.equal(row.Download, "success");
  assert.equal(row["Byte-identical"], "NO");
  assert.equal(row.Outcome, "failed");
  assert.equal(row["Aggregate MiB/s"], "N/A");
  assert.equal(row["Per-second MiB/s median (min–max)"], "N/A");
});

test("pass-stage failure remains visible even if verification output says true", (t) => {
  const row = summarize(t, { "status.log": "stage=verify status=2\n" });
  assert.equal(row.Outcome, "failed (verify, exit 2)");
  assert.equal(row["Aggregate MiB/s"], "N/A");
});

test("running pass cannot reuse apparently successful artifacts", (t) => {
  const row = summarize(t, { "status.log": "stage=setup status=running\n" });
  assert.equal(row.Outcome, "incomplete");
  assert.equal(row["Aggregate MiB/s"], "N/A");
});

test("missing artifacts remain visible as incomplete", (t) => {
  const row = summarize(t, { "verify.json": null });
  assert.equal(row["Byte-identical"], "incomplete");
  assert.equal(row.Outcome, "incomplete");
  assert.equal(row["Aggregate MiB/s"], "N/A");
});

test("empty and partial verifier output does not abort summary", async (t) => {
  for (const content of ["", '{"allMatch":', "null"]) {
    await t.test(JSON.stringify(content), (t) => {
      const row = summarize(t, { "verify.json": content });
      assert.equal(row["Byte-identical"], "incomplete");
      assert.equal(row["Aggregate MiB/s"], "N/A");
    });
  }
});

test("empty or invalid samples display N/A", async (t) => {
  for (const content of ["", "1 0\n2 NaN\n3 Infinity\n"]) {
    await t.test(JSON.stringify(content), (t) => {
      const row = summarize(t, { "throughput-MiBps.log": content });
      assert.equal(row["Per-second MiB/s median (min–max)"], "N/A");
      assert.equal(row["Aggregate MiB/s"], "481.9");
    });
  }
});

test("empty cache observations cannot produce a valid rate", (t) => {
  const row = summarize(t, { "cache-status.log": "" });
  assert.equal(row.Objects, "0");
  assert.equal(row["Aggregate MiB/s"], "N/A");
  assert.equal(row.GiB, "N/A");
});

test("zero wall duration cannot produce an infinite rate", (t) => {
  const row = summarize(t, { "timing.log": "status=0 wall=0\n" });
  assert.equal(row["Aggregate MiB/s"], "N/A");
});
