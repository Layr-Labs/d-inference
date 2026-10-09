// Exercises the real GET handler against a throwaway in-process HTTP server
// standing in for the coordinator (live-isolated: no mocks of the route, no
// network beyond loopback).
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { NextRequest } from "next/server";
import { GET } from "./route";

const QWEN_BUILD = "EigenLabs/Qwen3.8-27B-4bit-mtp";
const QWEN_ALIAS = "qwen3.8-27b";

const catalogFixture = {
  models: [
    {
      id: QWEN_BUILD,
      display_name: "Qwen 3.8 27B (4-bit, MTP)",
      model_type: "text",
      size_gb: 27,
      required_provider_capabilities: ["apple_m5", "mlx_nax"],
      metadata: {},
    },
    {
      id: "gemma-4-26b",
      display_name: "Gemma 4 26B",
      model_type: "text",
      size_gb: 26,
      required_provider_capabilities: [],
      metadata: {},
    },
    {
      // Malformed upstream value: only the string entries may reach the UI.
      id: "vendor/odd",
      display_name: "Odd",
      model_type: "text",
      size_gb: 1,
      required_provider_capabilities: ["apple_m5", 7, null],
      metadata: {},
    },
    {
      // Legacy row without the field at all.
      id: "vendor/legacy",
      display_name: "Legacy",
      model_type: "text",
      size_gb: 1,
      metadata: {},
    },
  ],
  aliases: [
    {
      id: QWEN_ALIAS,
      display_name: "Qwen 3.8 27B",
      desired_build: QWEN_BUILD,
      primary_build: QWEN_BUILD,
    },
  ],
};

let server: Server;
let previousCoordinatorUrl: string | undefined;

beforeAll(async () => {
  server = createServer((req, res) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
    if (path === "/v1/models/catalog") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(catalogFixture));
      return;
    }
    if (path === "/v1/models/capacity") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ models: [] }));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  previousCoordinatorUrl = process.env.NEXT_PUBLIC_COORDINATOR_URL;
  process.env.NEXT_PUBLIC_COORDINATOR_URL = `http://127.0.0.1:${port}`;
});

afterAll(async () => {
  if (previousCoordinatorUrl === undefined) {
    delete process.env.NEXT_PUBLIC_COORDINATOR_URL;
  } else {
    process.env.NEXT_PUBLIC_COORDINATOR_URL = previousCoordinatorUrl;
  }
  await new Promise<void>((resolve, reject) =>
    server.close((err) => (err ? reject(err) : resolve())),
  );
});

async function fetchPublicCatalog() {
  const res = await GET(new NextRequest("http://localhost/api/models"));
  expect(res.status).toBe(200);
  const body = (await res.json()) as { data: Array<Record<string, unknown>> };
  return new Map(body.data.map((row) => [row.id as string, row]));
}

describe("GET /api/models (public catalog)", () => {
  it("passes required_provider_capabilities through to the public alias row", async () => {
    const rows = await fetchPublicCatalog();
    // The concrete build is hidden behind its alias; the alias inherits the gate.
    expect(rows.has(QWEN_BUILD)).toBe(false);
    expect(rows.get(QWEN_ALIAS)?.required_provider_capabilities).toEqual(["apple_m5", "mlx_nax"]);
  });

  it("emits an empty array for ungated and legacy rows", async () => {
    const rows = await fetchPublicCatalog();
    expect(rows.get("gemma-4-26b")?.required_provider_capabilities).toEqual([]);
    expect(rows.get("vendor/legacy")?.required_provider_capabilities).toEqual([]);
  });

  it("drops non-string entries from a malformed upstream value", async () => {
    const rows = await fetchPublicCatalog();
    expect(rows.get("vendor/odd")?.required_provider_capabilities).toEqual(["apple_m5"]);
  });
});
