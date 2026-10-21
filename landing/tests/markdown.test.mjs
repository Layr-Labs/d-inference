import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";

let site;
before(async () => { site = await startSiteServer(); });
after(async () => { await site?.close(); });

async function request(path, accept) {
  return fetch(`${site.origin}${path}`, { headers: accept ? { Accept: accept } : {} });
}

test("homepage provides real Markdown and a stable explicit twin", async () => {
  const response = await request("/", "text/markdown");
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^text\/markdown/);
  const body = await response.text();
  assert.match(body, /^# Darkbloom/);
  assert.match(body, /Consumers/);
  assert.match(body, /Providers/);
  assert.match(body, /https:\/\/api.darkbloom.dev\/v1/);
  assert.equal(await (await request("/index.md")).text(), body);
  assert.match(response.headers.get("vary"), /Accept/i);
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(response.headers.get("x-frame-options"), "DENY");
});

test("negotiation respects media priorities, exclusions and browser defaults", async () => {
  for (const [accept, expected] of [
    ["*/*", "text/html"],
    ["text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "text/html"],
    ["text/markdown;q=0", "text/html"],
    ["text/markdown;q=0, text/*;q=1", "text/html"],
    ["text/markdown;q=0.4, text/html;q=0.8", "text/html"],
    ["text/markdown;q=0.9, text/html;q=0.1", "text/markdown"],
    ["text/markdown, */*", "text/markdown"],
    ["text/html, text/markdown", "text/html"],
    ["text/markdown, text/html", "text/markdown"],
    ["text/markdown;q=0.5, text/html;q=0, */*;q=1", "text/markdown"],
    ["TEXT/MARKDOWN; Q=0.8, text/html;q=0.2", "text/markdown"],
    ["text/markdown;q=invalid, text/html", "text/html"],
  ]) {
    const response = await request("/", accept);
    assert.equal(response.status, 200, accept);
    assert.ok(response.headers.get("content-type").startsWith(expected), accept);
  }
});

test("agent guidance provides safe consumer auth and provider discovery", async () => {
  const llms = await request("/llms.txt");
  assert.equal(llms.status, 200);
  assert.match(llms.headers.get("content-type"), /^text\/plain/);
  const index = await llms.text();
  assert.match(index, /when to use/i);
  for (const path of ["/auth.md", "/openapi.json", "/developers", "/pricing.md", "/contact"]) {
    assert.ok(index.includes(path), `discovers ${path}`);
  }
  assert.match(index, /provider.*CLI/i);
  const auth = await request("/auth.md");
  assert.equal(auth.status, 200);
  assert.match(auth.headers.get("content-type"), /^text\/markdown/);
  const instructions = await auth.text();
  assert.match(instructions, /https:\/\/console.darkbloom.dev\/api-console/);
  assert.match(instructions, /Authorization: Bearer \$DARKBLOOM_API_KEY/);
  assert.match(instructions, /fund|balance/i);
  assert.match(instructions, /provider.*token.*not.*consumer/i);
  assert.doesNotMatch(instructions, /sk-db-[a-zA-Z0-9]{8}/);
});

test("missing documents return real Markdown 404s with useful recovery", async () => {
  for (const path of ["/not-a-page", "/guides/missing", "/missing.md"]) {
    const response = await request(path, "text/markdown");
    assert.equal(response.status, 404, path);
    assert.match(response.headers.get("content-type"), /^text\/markdown/);
    const body = await response.text();
    assert.match(body, /not found/i);
    for (const link of ["/index.md", "/llms.txt", "https://docs.darkbloom.dev/introduction"]) {
      assert.ok(body.includes(link), link);
    }
  }
  const browser = await request("/not-a-page", "text/html");
  assert.equal(browser.status, 404);
  assert.match(browser.headers.get("content-type"), /^text\/html/);
});

test("Markdown negotiation does not hijack API, assets, internals or well-known routes", async () => {
  for (const path of ["/api/missing", "/api/missing.md", "/_next/missing", "/missing.png", "/assets/missing", "/.well-known/missing", "/.well-known/missing.md"]) {
    const response = await request(path, "text/markdown");
    assert.equal(response.status, 404, path);
    assert.doesNotMatch(response.headers.get("content-type"), /^text\/markdown/, path);
  }
  const asset = await request("/og.png", "text/markdown");
  assert.equal(asset.status, 200);
  assert.match(asset.headers.get("content-type"), /^image\/png/);
});

test("homepage advertises verified machine-readable alternatives", async () => {
  for (const accept of ["text/html", "text/markdown"]) {
    const response = await request("/", accept);
    const link = response.headers.get("link");
    assert.match(link, /<https:\/\/darkbloom.ai\/index.md>; rel="alternate"; type="text\/markdown"/);
    assert.match(link, /<https:\/\/darkbloom.ai\/llms.txt>/);
    assert.match(link, /<https:\/\/darkbloom.ai\/openapi.json>/);
  }
});

test("developer and contact Markdown twins retain shared public facts", async () => {
  for (const [path, phrases] of [
    ["/developers", ["consumer API", "provider", "Authorization: Bearer", "darkbloom doctor"]],
    ["/contact", ["legal", "darkbloomnotices@eigenlabs.org", "https://docs.darkbloom.dev/introduction"]],
  ]) {
    const negotiated = await request(path, "text/markdown");
    assert.equal(negotiated.status, 200);
    assert.match(negotiated.headers.get("content-type"), /^text\/markdown/);
    const body = await negotiated.text();
    for (const phrase of phrases) assert.ok(body.includes(phrase), phrase);
    const explicit = await request(`${path}.md`);
    assert.equal(explicit.status, 200);
    assert.equal(await explicit.text(), body);
  }
  const pricing = await request("/pricing.md");
  assert.equal(pricing.status, 200);
  assert.match(pricing.headers.get("content-type"), /^text\/markdown/);
  const body = await pricing.text();
  assert.match(body, /USD per million tokens/);
  assert.match(body, /rates are unavailable/);
  assert.match(body, /https:\/\/api.darkbloom.dev\/v1\/pricing/);
});


test("representation caches vary by Accept and preserve framework tokens", async () => {
  for (const path of ["/", "/developers", "/contact", "/pricing", "/not-a-page"]) {
    const response = await request(path, "text/html");
    assert.match(response.headers.get("vary"), /(?:^|,\s*)Accept(?:,|$)/i, path);
    for (const token of ["rsc", "next-router-state-tree", "next-router-prefetch"]) {
      assert.ok(response.headers.get("vary").toLowerCase().includes(token), `preserves ${token}`);
    }
  }
});

test("React navigation and non-read requests retain their own protocol", async () => {
  const navigation = await fetch(`${site.origin}/`, { headers: { Accept: "text/markdown", RSC: "1" } });
  assert.equal(navigation.status, 200);
  assert.match(navigation.headers.get("content-type"), /^text\/x-component/);
  const post = await fetch(`${site.origin}/index.md`, { method: "POST", headers: { Accept: "text/markdown" } });
  assert.equal(post.status, 404);
  assert.doesNotMatch(post.headers.get("content-type"), /^text\/markdown/);
  const head = await fetch(`${site.origin}/index.md`, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.match(head.headers.get("content-type"), /^text\/markdown/);
  assert.equal(await head.text(), "");
});
