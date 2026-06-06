import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";
import { render, screen, fireEvent } from "@testing-library/react";
import { KeyForm } from "@/components/api-keys/KeyForm";
import { useStore } from "@/lib/store";
import type { UpdateKeyBody } from "@/lib/api";

// ===========================================================================
// Chat proxy: X-Darkbloom-Route forwarding (the "My Machine" wire signal).
// ===========================================================================

describe("POST /api/chat self-route header forwarding", () => {
  let upstreamFetch: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    upstreamFetch = vi.fn();
    vi.stubGlobal("fetch", upstreamFetch);
  });
  afterEach(() => {
    vi.restoreAllMocks();
    vi.resetModules();
  });

  function streamResponse(): Response {
    return new Response("data: {}\n\n", {
      status: 200,
      headers: { "Content-Type": "text/event-stream" },
    });
  }

  function chatRequest(headers: Record<string, string>): NextRequest {
    return new NextRequest(new URL("/api/chat", "http://localhost:3000"), {
      method: "POST",
      headers,
      body: JSON.stringify({ model: "m", messages: [] }),
    });
  }

  it("forwards X-Darkbloom-Route: self upstream when the client sets it", async () => {
    upstreamFetch.mockResolvedValueOnce(streamResponse());
    const { POST } = await import("@/app/api/chat/route");
    await POST(
      chatRequest({
        "x-api-key": "k1",
        "content-type": "application/json",
        "x-darkbloom-route": "self",
      })
    );
    const opts = upstreamFetch.mock.calls[0][1];
    expect(opts.headers["X-Darkbloom-Route"]).toBe("self");
    expect(opts.headers.Authorization).toBe("Bearer k1");
  });

  it("omits the header when the client does not request self-route", async () => {
    upstreamFetch.mockResolvedValueOnce(streamResponse());
    const { POST } = await import("@/app/api/chat/route");
    await POST(
      chatRequest({ "x-api-key": "k1", "content-type": "application/json" })
    );
    const opts = upstreamFetch.mock.calls[0][1];
    expect(opts.headers["X-Darkbloom-Route"]).toBeUndefined();
  });
});

// ===========================================================================
// Store: useMyMachine toggle (persisted preference).
// ===========================================================================

describe("store useMyMachine", () => {
  it("defaults to false and toggles", () => {
    expect(useStore.getState().useMyMachine).toBe(false);
    useStore.getState().setUseMyMachine(true);
    expect(useStore.getState().useMyMachine).toBe(true);
    useStore.getState().setUseMyMachine(false);
    expect(useStore.getState().useMyMachine).toBe(false);
  });
});

// ===========================================================================
// KeyForm: self_route_only is included in the submit body and reflects initial.
// ===========================================================================

describe("KeyForm self_route_only", () => {
  it("submits self_route_only=true after toggling the option on", () => {
    let submitted: UpdateKeyBody | null = null;
    render(
      <KeyForm
        models={[]}
        mode="create"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    // Name is required before submit is enabled.
    fireEvent.change(screen.getByPlaceholderText("e.g. Production server"), {
      target: { value: "my-machine-key" },
    });
    fireEvent.click(screen.getByText("My Machine only — free"));
    fireEvent.click(screen.getByText("Create key"));

    expect(submitted).not.toBeNull();
    expect(submitted!.self_route_only).toBe(true);
  });

  it("defaults self_route_only=false when never toggled", () => {
    let submitted: UpdateKeyBody | null = null;
    render(
      <KeyForm
        models={[]}
        mode="create"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    fireEvent.change(screen.getByPlaceholderText("e.g. Production server"), {
      target: { value: "normal-key" },
    });
    fireEvent.click(screen.getByText("Create key"));

    expect(submitted!.self_route_only).toBe(false);
  });

  it("reflects an existing key's self_route_only=true as pre-selected", () => {
    let submitted: UpdateKeyBody | null = null;
    render(
      <KeyForm
        initial={{
          id: "key_1",
          name: "existing",
          label: "sk-db-…",
          disabled: false,
          limit_reset: "none",
          usage_usd: 0,
          self_route_only: true,
          created_at: new Date().toISOString(),
        }}
        models={[]}
        mode="edit"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    fireEvent.click(screen.getByText("Save changes"));
    expect(submitted!.self_route_only).toBe(true);
  });
});
