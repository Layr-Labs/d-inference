import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { after, before, test } from "node:test";

let server;
let stopped;
let origin;

before(async () => {
  // Use localhost consistently: Next normalizes loopback IPs in request URLs.
  server = spawn(process.execPath, [
    "node_modules/next/dist/bin/next", "start", "--hostname", "localhost", "--port", "0",
  ], {
    cwd: fileURLToPath(new URL("../", import.meta.url)),
    env: {
      ...process.env,
      NODE_ENV: "production",
      NEXT_TELEMETRY_DISABLED: "1",
      DARKBLOOM_API_BASE_URL: "http://127.0.0.1:9/v1",
      DARKBLOOM_CONSOLE_STATS_URL: "http://127.0.0.1:9/api/stats",
      DARKBLOOM_API_KEY: "",
      DARKBLOOM_STORY_WEBHOOK_URL: "",
      DARKBLOOM_STORY_WEBHOOK_TOKEN: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  stopped = once(server, "exit");
  await new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(() => reject(new Error(`Server did not start. Run npm run build first.\n${output}`)), 20_000);
    const fail = (error) => { clearTimeout(timeout); reject(error); };
    server.once("error", fail);
    server.once("exit", (code) => fail(new Error(`Server exited (${code})\n${output}`)));
    const read = (chunk) => {
      output += chunk;
      const url = output.match(/http:\/\/localhost:\d+/)?.[0];
      if (url && output.includes("Ready in")) {
        clearTimeout(timeout);
        origin = url;
        resolve();
      }
    };
    server.stdout.on("data", read);
    server.stderr.on("data", read);
  });
});

after(async () => {
  if (!server || server.exitCode !== null) return;
  server.kill("SIGTERM");
  const timeout = setTimeout(() => server.kill("SIGKILL"), 5_000);
  await stopped;
  clearTimeout(timeout);
});

for (const [path, heading] of [
  ["/", "The compute grid"],
  ["/about", "A new topology for private inference"],
  ["/terms", "Terms of Service"],
  ["/privacy", "Privacy Policy"],
]) {
  test(`${path} serves the migrated page`, async () => {
    const response = await fetch(`${origin}${path}`);
    assert.equal(response.status, 200);
    assert.ok((await response.text()).includes(heading));
    assert.equal(response.headers.get("x-frame-options"), "DENY");
  });
}

for (const [legacy, destination] of [["/index.html", "/"], ["/terms.html", "/terms"], ["/privacy.html", "/privacy"]]) {
  test(`${legacy} permanently redirects without losing query parameters`, async () => {
    const response = await fetch(`${origin}${legacy}?ref=migration`, { redirect: "manual" });
    assert.equal(response.status, 308);
    const url = new URL(response.headers.get("location"), origin);
    assert.equal(url.pathname, destination);
    assert.equal(url.searchParams.get("ref"), "migration");
  });
}

test("docs link keeps its external destination", async () => {
  const response = await fetch(`${origin}/docs`, { redirect: "manual" });
  assert.equal(response.status, 307);
  assert.equal(response.headers.get("location"), "https://docs.darkbloom.dev/introduction");
});

test("fonts, videos and the social image are served locally", async () => {
  for (const path of ["/fonts/PPTelegraf-Regular.woff2", "/media/hero-film-r7.mp4", "/og.png"]) {
    const response = await fetch(`${origin}${path}`, { method: "HEAD" });
    assert.equal(response.status, 200, path);
    assert.ok(Number(response.headers.get("content-length")) > 0, path);
    if (path === "/og.png") assert.equal(response.headers.get("cross-origin-resource-policy"), "cross-origin");
  }
});

test("unconfigured chat fails safely and rejects cross-origin submissions", async () => {
  for (const [requestOrigin, status] of [[origin, 503], ["https://example.invalid", 403]]) {
    const response = await fetch(`${origin}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: requestOrigin },
      body: JSON.stringify({ prompt: "What is Darkbloom?" }),
    });
    assert.equal(response.status, status);
    assert.ok((await response.json()).error);
  }
});

test("unconfigured story delivery does not report success", async () => {
  const response = await fetch(`${origin}/api/provider-stories`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: "Test", city: "Test", providerId: "test-0001", contact: "test@example.invalid", story: "A local migration check with no real delivery destination." }),
  });
  assert.equal(response.status, 503);
});
