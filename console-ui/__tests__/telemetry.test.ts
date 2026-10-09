import { describe, it, expect } from "vitest";
import { NextRequest } from "next/server";
import { stubUpstreamFetch } from "./helpers/route-harness";

// Privacy regressions for the retired browser telemetry client and proxy.
const upstream = stubUpstreamFetch();

describe("/api/telemetry route", () => {
  it("returns 410 without inspecting or forwarding the request", async () => {
    const { POST } = await import("@/app/api/telemetry/route");
    const poisonedRequest = new Proxy({} as NextRequest, {
      get() {
        throw new Error("disabled telemetry route inspected request data");
      },
    });

    const response = await POST(poisonedRequest);

    expect(response.status).toBe(410);
    expect(upstream.fetch).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "telemetry_ingest_disabled" },
    });
  });

  it("does not reflect an arbitrary request body", async () => {
    const { POST } = await import("@/app/api/telemetry/route");
    const request = new NextRequest("http://localhost:3000/api/telemetry", {
      method: "POST",
      body: "PROMPT_LEAK_SENTINEL",
    });

    const response = await POST(request);
    const body = await response.text();

    expect(response.status).toBe(410);
    expect(body).not.toContain("PROMPT_LEAK_SENTINEL");
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});

describe("telemetry client", () => {
  it("drops free-form events without buffering or sending", async () => {
    const telemetry = await import("@/lib/telemetry");
    telemetry._resetForTest();

    telemetry.emit({
      kind: "http_error",
      severity: "error",
      message: "PROMPT_LEAK_SENTINEL",
      fields: {
        prompt: "SECRET",
        url: "https://attacker.invalid/private",
      },
      stack: "STACK_LEAK_SENTINEL",
      requestId: "REQUEST_LEAK_SENTINEL",
    });

    expect(telemetry._bufferSize()).toBe(0);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });
});
