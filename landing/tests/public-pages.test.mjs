import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { after, before, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";
let site;
let upstream;
let priceResponse = { prices: [{ model: "fixture/model", input_price: 50000, output_price: 250000, cache_read_price: 12500 }], fallback_input_price: 500000, fallback_output_price: 1500000, fallback_cache_read_price: 125000 };
let priceStatus = 200;
before(async () => {
  upstream = createServer((request, response) => {
    assert.equal(request.url, "/v1/pricing");
    assert.equal(request.headers.authorization, undefined);
    response.writeHead(priceStatus, { "content-type": "application/json" });
    response.end(JSON.stringify(priceResponse));
  });
  upstream.listen(0, "127.0.0.1");
  await once(upstream, "listening");
  site = await startSiteServer({ env: { DARKBLOOM_API_BASE_URL: `http://127.0.0.1:${upstream.address().port}/v1` } });
});
after(async () => { await site?.close(); await new Promise(resolve => upstream?.close(resolve)); });
test("pricing displays public rates in USD per million tokens with source and retrieval time", async () => {
  const response = await fetch(`${site.origin}/pricing`);
  assert.equal(response.status, 200);
  const html = await response.text();
  for (const expected of ["fixture/model", "$0.05", "$0.25", "$0.0125", "USD per million tokens", "Retrieved at", "https://api.darkbloom.dev/v1/pricing", "Fallback rates"]) assert.ok(html.includes(expected), expected);
});

test("pricing reports unavailable data instead of stale or malformed prices", async () => {
  for (const [status, body] of [[503, {}], [200, { prices: [{ model: "bad", input_price: -1 }] }]]) {
    priceStatus = status;
    priceResponse = body;
    const response = await fetch(`${site.origin}/pricing`);
    assert.equal(response.status, 200);
    const html = await response.text();
    assert.ok(html.includes("Current rates are unavailable"));
    assert.ok(!html.includes("fixture/model"));
    assert.ok(!html.includes("Retrieved at"));
  }
});

test("developers distinguishes consumer authentication from the provider CLI", async () => {
  const response = await fetch(`${site.origin}/developers`);
  assert.equal(response.status, 200);
  const html = await response.text();
  for (const expected of ["Authorization: Bearer", "DARKBLOOM_API_KEY", "https://api.darkbloom.dev/v1/models", "https://console.darkbloom.dev/api-console", "darkbloom doctor", "provider software", "funded account", "/openapi.json"]) assert.ok(html.includes(expected), expected);
});

test("contact provides the verified legal notice address and official product channels", async () => {
  const response = await fetch(`${site.origin}/contact`);
  assert.equal(response.status, 200);
  const html = await response.text();
  for (const expected of ["mailto:darkbloomnotices@eigenlabs.org", "legal notices", "https://console.darkbloom.dev/", "https://docs.darkbloom.dev/introduction", "https://x.com/darkbloomai", "/terms"]) assert.ok(html.includes(expected), expected);
});

test("public pages describe the real privacy boundary and expose developer discovery", async () => {
  const home = await (await fetch(`${site.origin}/`)).text();
  for (const expected of ["decentralized private inference network", "OpenAI-compatible API", 'href="/developers"', 'href="/pricing"', 'href="/contact"']) assert.ok(home.includes(expected), expected);
  const about = await (await fetch(`${site.origin}/about`)).text();
  assert.ok(about.includes('id="pricing"'));
  assert.ok(about.includes("provider is the plaintext endpoint"));
  for (const inaccurate of ["neither can get a usable view", "Prompts stay hidden", "E2E Encryption", "every path inward is eliminated", "50% lower cost"]) assert.ok(!about.includes(inaccurate), inaccurate);
});
