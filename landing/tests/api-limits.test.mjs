import assert from "node:assert/strict";
import { once } from "node:events";
import { connect } from "node:net";
import { after, before, describe, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";

// Sends only a request head that declares `contentLength` body bytes and
// returns the response status line, or null if none arrives in time.
async function statusLineForDeclaredBody(origin, path, contentLength) {
  const { hostname, port } = new URL(origin);
  const socket = connect(Number(port), hostname);
  await once(socket, "connect");
  socket.write(`POST ${path} HTTP/1.1\r\nHost: ${hostname}\r\nContent-Type: application/json\r\n`
    + `Content-Length: ${contentLength}\r\n\r\n`);
  const timeout = AbortSignal.timeout(5_000);
  try {
    const [chunk] = await once(socket, "data", { signal: timeout });
    return chunk.toString("latin1").split("\r\n")[0];
  } catch {
    return null;
  } finally {
    socket.destroy();
  }
}

// A body sent in pieces without Content-Length, as chunked HTTP/1.1 and
// HTTP/2 clients can.
function streamed(text) {
  const bytes = new TextEncoder().encode(text);
  return new ReadableStream({
    start(controller) {
      for (let offset = 0; offset < bytes.length; offset += 4_096) {
        controller.enqueue(bytes.slice(offset, offset + 4_096));
      }
      controller.close();
    },
  });
}

async function post(origin, path, { body, headers = {} }) {
  const response = await fetch(`${origin}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body,
    ...(body instanceof ReadableStream ? { duplex: "half" } : {}),
  });
  await response.arrayBuffer();
  return response.status;
}

const story = {
  name: "Test",
  city: "Test",
  providerId: "test-0001",
  contact: "test@example.invalid",
  story: "A local limit check with no real delivery destination.",
};

describe("request bodies are bounded while they are read", () => {
  let site;
  before(async () => {
    site = await startSiteServer({ env: { DARKBLOOM_CHAT_RPM: "60" } });
  });
  after(async () => site?.close());

  test("chat refuses an oversized body with or without Content-Length", async () => {
    const body = JSON.stringify({ prompt: "What is Darkbloom?", padding: "x".repeat(64 * 1024) });
    assert.equal(await post(site.origin, "/api/chat", { body }), 413);
    assert.equal(await post(site.origin, "/api/chat", { body: streamed(body) }), 413);
  });

  test("provider stories refuse an oversized body with or without Content-Length", async () => {
    const body = JSON.stringify({ ...story, padding: "x".repeat(64 * 1024) });
    assert.equal(await post(site.origin, "/api/provider-stories", { body }), 413);
    assert.equal(await post(site.origin, "/api/provider-stories", { body: streamed(body) }), 413);
  });

  test("bodies within the limit still reach validation", async () => {
    const chat = JSON.stringify({ prompt: "What is Darkbloom?" });
    assert.equal(await post(site.origin, "/api/chat", { body: streamed(chat) }), 503);
    assert.equal(await post(site.origin, "/api/provider-stories", { body: streamed(JSON.stringify(story)) }), 503);
  });

  test("a declared oversized body is refused before it is sent", async () => {
    // Nothing buffers the body ahead of the route, so the refusal does not
    // wait for bytes the client has not sent.
    for (const path of ["/api/chat", "/api/provider-stories"]) {
      assert.match(await statusLineForDeclaredBody(site.origin, path, 1_000_000) ?? "no response", /^HTTP\/1\.1 413 /, path);
    }
  });
});

describe("chat rate limiting without a trusted client address header", () => {
  let site;
  before(async () => {
    site = await startSiteServer({
      env: { DARKBLOOM_CHAT_RPM: "2", DARKBLOOM_TRUSTED_CLIENT_IP_HEADER: "", VERCEL: "" },
    });
  });
  after(async () => site?.close());

  test("client-chosen forwarding headers do not create fresh buckets", async () => {
    const body = JSON.stringify({ prompt: "What is Darkbloom?" });
    const statuses = [];
    for (const address of ["198.51.100.1", "198.51.100.2", "198.51.100.3"]) {
      statuses.push(await post(site.origin, "/api/chat", {
        body,
        headers: { "x-forwarded-for": address, "x-real-ip": address },
      }));
    }
    assert.deepEqual(statuses, [503, 503, 429]);
  });
});

describe("chat rate limiting behind a proxy that records the client address", () => {
  let site;
  before(async () => {
    site = await startSiteServer({
      env: { DARKBLOOM_CHAT_RPM: "1", DARKBLOOM_TRUSTED_CLIENT_IP_HEADER: "X-Forwarded-For", VERCEL: "" },
    });
  });
  after(async () => site?.close());

  test("buckets follow the proxy-recorded address, IPv6 /64 and IPv4-mapped forms", async () => {
    const body = JSON.stringify({ prompt: "What is Darkbloom?" });
    const statusFor = (forwardedFor) => post(site.origin, "/api/chat", {
      body,
      headers: { "x-forwarded-for": forwardedFor },
    });
    // The proxy appends what it saw; the earlier entry is the client's own.
    assert.equal(await statusFor("203.0.113.9, 198.51.100.7"), 503);
    assert.equal(await statusFor("198.51.100.7"), 429);
    assert.equal(await statusFor("198.51.100.7, 198.51.100.8"), 503);
    assert.equal(await statusFor("::ffff:198.51.100.8"), 429);
    assert.equal(await statusFor("2001:db8:1:2::1"), 503);
    assert.equal(await statusFor("2001:db8:1:2:ffff::9"), 429);
    assert.equal(await statusFor("2001:db8:1:3::1"), 503);
    // Values that are not addresses share one bucket instead of each getting one.
    assert.equal(await statusFor("not-an-address"), 503);
    assert.equal(await statusFor("also-not-an-address"), 429);
  });
});

describe("chat rate limiting with an invalid trusted header name", () => {
  let site;
  before(async () => {
    site = await startSiteServer({
      env: { DARKBLOOM_CHAT_RPM: "1", DARKBLOOM_TRUSTED_CLIENT_IP_HEADER: "X-Forwarded-For:", VERCEL: "" },
    });
  });
  after(async () => site?.close());

  test("the name is ignored: requests are answered and share one bucket", async () => {
    const body = JSON.stringify({ prompt: "What is Darkbloom?" });
    const statuses = [];
    for (const address of ["198.51.100.1", "198.51.100.2"]) {
      statuses.push(await post(site.origin, "/api/chat", { body, headers: { "x-forwarded-for": address } }));
    }
    assert.deepEqual(statuses, [503, 429]);
  });
});
