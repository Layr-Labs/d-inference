import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";

let site;
before(async () => { site = await startSiteServer(); });
after(async () => site?.close());

test("public pages advertise production canonical identity independently of request host", async () => {
  for (const path of ["/", "/about", "/privacy", "/terms"]) {
    const response = await fetch(`${site.origin}${path}`, {
      headers: { "x-forwarded-host": "untrusted.example", "x-forwarded-proto": "http" },
    });
    assert.equal(response.status, 200);
    const html = await response.text();
    const canonical = new URL(html.match(/<link rel="canonical" href="([^"]+)"/)?.[1] ?? "https://missing.invalid");
    assert.equal(canonical.origin, "https://darkbloom.ai", path);
    assert.equal(canonical.pathname, path);
    assert.ok(html.includes('content="https://darkbloom.ai/og.png"'), path);
    assert.ok(html.includes('<html lang="en"'), path);
    assert.ok(!html.includes('http://untrusted.example'), path);
  }
});

test("structured data links the public website and service to their real operator", async () => {
  const html = await (await fetch(site.origin)).text();
  const script = html.match(/<script[^>]+type="application\/ld\+json"[^>]*>(.*?)<\/script>/s);
  assert.ok(script, "public JSON-LD is server-rendered");
  const data = JSON.parse(script[1]);
  assert.equal(data["@context"], "https://schema.org");
  const graph = data["@graph"];
  const organization = graph.find((node) => node["@type"] === "Organization");
  const website = graph.find((node) => node["@type"] === "WebSite");
  const service = graph.find((node) => node["@type"] === "SoftwareApplication");
  assert.equal(organization.name, "Eigen Labs, Inc.");
  assert.equal(organization.contactPoint.email, "darkbloomnotices@eigenlabs.org");
  assert.equal(organization.contactPoint.contactType, "legal notices");
  assert.equal(website.url, "https://darkbloom.ai");
  assert.equal(website.publisher["@id"], organization["@id"]);
  assert.equal(service.name, "Darkbloom");
  assert.equal(service.publisher["@id"], organization["@id"]);
  assert.ok(service.sameAs.includes("https://github.com/Layr-Labs/d-inference"));
  assert.ok(!JSON.stringify(data).includes("PostalAddress"));
  assert.ok(!Object.hasOwn(service, "offers"), "no invented free tier or price");
});

test("crawl discovery lists canonical public pages and source-backed freshness dates", async () => {
  const response = await fetch(`${site.origin}/sitemap.xml`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /xml/);
  const xml = await response.text();
  assert.match(xml, /^<\?xml version="1\.0" encoding="UTF-8"\?>/);
  assert.match(xml, /<urlset xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9">/);
  const urls = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => new URL(match[1]));
  assert.equal(new Set(urls.map(String)).size, urls.length);
  assert.deepEqual(urls.map((url) => url.pathname).sort(), ["/", "/about", "/pricing", "/privacy", "/terms"]);
  assert.ok(urls.every((url) => url.origin === "https://darkbloom.ai"));
  for (const entry of xml.matchAll(/<url>(.*?)<\/url>/gs)) {
    const path = new URL(entry[1].match(/<loc>([^<]+)<\/loc>/)[1]).pathname;
    if (["/privacy", "/terms"].includes(path)) {
      assert.ok(entry[1].includes("<lastmod>2026-08-28</lastmod>"), path);
    } else {
      assert.ok(!entry[1].includes("<lastmod>"), "omit unknown content dates");
    }
  }
  const robots = await fetch(`${site.origin}/robots.txt`);
  assert.equal(robots.status, 200);
  assert.match(robots.headers.get("content-type"), /text\/plain/);
  const policy = await robots.text();
  assert.match(policy, /User-Agent: \*/i);
  assert.match(policy, /Allow: \/\s/);
  assert.match(policy, /Sitemap: https:\/\/darkbloom.ai\/sitemap.xml/);
  assert.ok(!policy.includes("Disallow"), "preserve public access");
});
