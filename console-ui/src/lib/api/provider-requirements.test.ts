import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchProviderRequirements } from "./provider-requirements";

describe("fetchProviderRequirements", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("keeps the timeout active while reading the response body", async () => {
    vi.useFakeTimers();
    let bodyAborted = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const signal = init?.signal;
        if (!signal) {
          throw new Error("missing request signal");
        }
        const body = new ReadableStream({
          start(controller) {
            signal.addEventListener(
              "abort",
              () => {
                bodyAborted = true;
                controller.error(new DOMException("Aborted", "AbortError"));
              },
              { once: true }
            );
          },
        });
        return new Response(body, {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      })
    );

    const request = fetchProviderRequirements();
    const rejection = expect(request).rejects.toMatchObject({
      name: "AbortError",
    });
    await vi.advanceTimersByTimeAsync(7_000);

    await rejection;
    expect(bodyAborted).toBe(true);
  });
});
