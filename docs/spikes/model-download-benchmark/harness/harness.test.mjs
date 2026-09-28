import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

const harness = dirname(fileURLToPath(import.meta.url));
const sha = data => createHash("sha256").update(data).digest("hex");

function fixture(t) {
  // Quotes/spaces also exercise passing paths as arguments rather than Python source.
  const root = mkdtempSync(join(tmpdir(), "bench 'fixture-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const dir of ["out", "snap", "bin"]) mkdirSync(join(root, dir));
  const pieces = [Buffer.from("first chunk"), Buffer.from("second chunk")];
  const whole = Buffer.concat(pieces);
  const parts = pieces.map((bytes, i) => ({ path: `part-${i}.bin`, sha256: sha(bytes) }));
  const expected = { shards: [{ shard: 1, size_bytes: whole.length, sha256: sha(whole), parts }] };
  writeFileSync(join(root, "out", "expected.json"), JSON.stringify(expected));
  pieces.forEach((bytes, i) => writeFileSync(join(root, "snap", parts[i].path), bytes));
  writeFileSync(join(root, "snap", "shard-01.bin"), whole);
  for (const kind of ["chunked", "large"]) {
    const files = kind === "chunked" ? parts : [{ path: "shard-01.bin" }];
    writeFileSync(join(root, "out", `manifest-bench-${kind}-test.json`), JSON.stringify({ files }));
  }
  // Mock all destructive, cloud, Docker and platform-specific commands. The
  // Docker shim runs the real verifier against the tiny fixture on the host.
  const mock = `#!/usr/bin/env python3
import os, sys, time, subprocess
from pathlib import Path
name = Path(sys.argv[0]).name
root = Path(os.environ['BENCH_ROOT'])
with (root/'calls.log').open('a') as f: f.write(name+' '+repr(sys.argv[1:])+'\\n')
if name == 'route': print('interface: en0')
elif name == 'netstat': print('en0 1500 Link 0 0 0 1048576')
elif name == 'sleep':
    with (root/'sampler-pids').open('a') as f: f.write(str(os.getppid())+'\\n')
    os.execv('/bin/sleep', ['/bin/sleep', *sys.argv[1:]])
elif name == 'provider':
    if sys.argv[2] == 'download':
        print('download output', flush=True)
        time.sleep(0.15)
        sys.exit(int(os.environ.get('TEST_DOWNLOAD_STATUS', '0')))
elif name == 'curl':
    if os.environ.get('TEST_CURL_STATUS'): sys.exit(int(os.environ['TEST_CURL_STATUS']))
    print('HTTP/2 200\\nContent-Length: 11\\nCF-Cache-Status: HIT\\nCF-Ray: test-MIA\\n')
elif name == 'docker':
    if os.environ.get('TEST_DOCKER_STATUS'): sys.exit(int(os.environ['TEST_DOCKER_STATUS']))
    sys.exit(subprocess.run([os.environ['TEST_NODE'], os.environ['TEST_VERIFY'], sys.argv[-2], str(root/'snap')], cwd=root).returncode)
elif name == 'tee':
    data = sys.stdin.read()
    Path(sys.argv[1]).write_text(data)
    print(data, end='')
    sys.exit(int(os.environ.get('TEST_TEE_STATUS', '0')))
elif name == 'rm': pass # Never touch the user's real provider cache.
else: raise Exception('unexpected mock command')
`;
  for (const cmd of ["route", "netstat", "sleep", "provider", "curl", "docker", "tee", "rm"]) {
    writeFileSync(join(root, "bin", cmd), mock, { mode: 0o755 });
  }
  return { root, expected };
}

function run(root, options = {}) {
  const result = spawnSync("bash", [join(harness, "run-bench.sh"), ...(options.args ?? ["chunked", "cold"])], {
    encoding: "utf8", timeout: 10_000,
    env: { ...process.env, PATH: `${join(root, "bin")}:${process.env.PATH}`, BENCH_ROOT: root,
      DARKBLOOM_BIN: join(root, "bin", "provider"), RUN_ID: "test", TEST_NODE: process.execPath,
      TEST_VERIFY: join(harness, "verify.mjs"), ...options.env },
  });
  assert.ifError(result.error);
  // A successful wait/reap is observable: no sampler process remains alive.
  const pids = join(root, "sampler-pids");
  if (existsSync(pids)) for (const pid of new Set(readFileSync(pids, "utf8").trim().split("\n"))) {
    assert.throws(() => process.kill(Number(pid), 0), { code: "ESRCH" }, `sampler ${pid} leaked`);
  }
  return result;
}
const output = (root, file, kind = "chunked") => readFileSync(join(root, "out", `${kind}-cold`, file), "utf8");

for (const kind of ["chunked", "large"]) test(`${kind} valid bytes complete successfully`, t => {
  const { root } = fixture(t);
  const result = run(root, { args: [kind, "cold"] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(output(root, "verify.json", kind)).allMatch, true);
  assert.match(output(root, "status.log", kind), /stage=complete status=0/);
});

for (const failure of ["missing", "corrupt"]) test(`${failure} bytes fail reconstruction and retain diagnostics`, t => {
  const { root } = fixture(t);
  const file = join(root, "snap", "part-0.bin");
  if (failure === "missing") rmSync(file); else writeFileSync(file, "corruption!");
  const result = run(root);
  assert.equal(result.status, 1, result.stderr);
  assert.equal(JSON.parse(output(root, "verify.json")).allMatch, false);
  assert.match(output(root, "timing.log"), /status=0 wall=/);
  assert.match(output(root, "status.log"), /stage=verify status=1/);
});

test("download failure preserves exit status/timing, reaps sampler, and clears stale verification", t => {
  const { root } = fixture(t);
  mkdirSync(join(root, "out", "chunked-cold"));
  writeFileSync(join(root, "out", "chunked-cold", "verify.json"), '{"allMatch":true}');
  const result = run(root, { env: { TEST_DOWNLOAD_STATUS: "42" } });
  assert.equal(result.status, 42, result.stderr);
  assert.match(output(root, "timing.log"), /status=42 wall=/);
  assert.match(output(root, "download.log"), /download output/);
  assert.equal(output(root, "verify.json"), "");
  assert.match(output(root, "status.log"), /stage=download status=42/);
  assert.doesNotMatch(readFileSync(join(root, "calls.log"), "utf8"), /docker|curl/);
});

for (const [env, status, stage] of [
  ["TEST_DOCKER_STATUS", 125, "verify"], ["TEST_TEE_STATUS", 73, "download"], ["TEST_CURL_STATUS", 22, "cache"],
]) test(`${stage} command failures propagate exit ${status}`, t => {
  const { root } = fixture(t);
  const result = run(root, { env: { [env]: String(status) } });
  assert.equal(result.status, status, result.stderr);
  assert.match(output(root, "status.log"), new RegExp(`stage=${stage} status=${status}`));
});

for (const options of [
  { args: [] }, { args: ["../large", "cold"] }, { args: ["chunked", "../cold"] },
  { env: { RUN_ID: "../../danger" } },
]) test(`reject unsafe arguments before cleanup: ${JSON.stringify(options)}`, t => {
  const { root } = fixture(t);
  const result = run(root, options);
  assert.equal(result.status, 2, result.stderr);
  assert.equal(existsSync(join(root, "calls.log")), false);
});

for (const invalid of [{ shards: [] }, { shards: [{}] }, { shards: null }]) test(`verifier rejects invalid expected manifest: ${JSON.stringify(invalid)}`, t => {
  const { root } = fixture(t);
  writeFileSync(join(root, "out", "expected.json"), JSON.stringify(invalid));
  const result = run(root);
  assert.equal(result.status, 1, result.stderr);
  assert.equal(JSON.parse(output(root, "verify.json")).allMatch, false);
});

test("invalid input manifest clears an earlier success before any cache deletion", t => {
  const { root } = fixture(t);
  mkdirSync(join(root, "out", "chunked-cold"));
  writeFileSync(join(root, "out", "chunked-cold", "status.log"), "stage=complete status=0\n");
  writeFileSync(join(root, "out", "chunked-cold", "verify.json"), '{"allMatch":true}');
  writeFileSync(join(root, "out", "manifest-bench-chunked-test.json"), '{"files":[]}');
  const result = run(root);
  assert.equal(result.status, 1);
  assert.equal(output(root, "verify.json"), "");
  assert.match(output(root, "status.log"), /stage=setup status=1/);
  assert.equal(existsSync(join(root, "calls.log")), false);
});
