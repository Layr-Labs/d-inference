import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";

let site;
let origin;
before(async () => {
  site = await startSiteServer();
  origin = site.origin;
});
after(async () => site?.close());

for (const [path, heading] of [
  ["/", "AI, powered by"],
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
  for (const path of ["/fonts/PPTelegraf-Regular.woff2", "/media/hero-film-r7-mobile.mp4", "/media/hero-film-r7-1080.mp4", "/og.png"]) {
    const response = await fetch(`${origin}${path}`, { method: "HEAD" });
    assert.equal(response.status, 200, path);
    assert.ok(Number(response.headers.get("content-length")) > 0, path);
    if (path === "/og.png") assert.equal(response.headers.get("cross-origin-resource-policy"), "cross-origin");
    if (path.startsWith("/media/")) assert.match(response.headers.get("cache-control") ?? "", /max-age=86400/, path);
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
