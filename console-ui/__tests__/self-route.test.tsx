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

  it("drops other-mode ids from the free-text fallback when the mode list is empty", () => {
    // Existing PUBLIC key with a saved allow-list; the user toggles "My
    // Machine only" while no machine models are available (machine offline or
    // picker fetch failed). The free-text fallback still holds the public id
    // — submitting it would block every local model request on the key, so it
    // must be excluded (null = clear the allow-list on edit).
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
          self_route_only: false,
          allowed_models: ["gpt-oss-20b"],
          created_at: new Date().toISOString(),
        }}
        models={["gpt-oss-20b"]}
        selfRouteModels={[]}
        mode="edit"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    fireEvent.click(screen.getByText("My Machine only — free"));
    fireEvent.click(screen.getByText("Save changes"));
    expect(submitted!.allowed_models).toBeNull();
  });

  it("preserves saved allow-list entries that are in neither mode's list", () => {
    // A saved allow-list can reference models currently in NEITHER list — a
    // machine that is temporarily offline, or a since-delisted public model.
    // An unrelated edit must not silently strip them; only ids that provably
    // belong to the OTHER route mode's list are excluded from submission.
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
          allowed_models: ["ghost/offline-machine-model", "local/llama-3.1-8b"],
          created_at: new Date().toISOString(),
        }}
        models={["gpt-oss-20b"]}
        selfRouteModels={["local/llama-3.1-8b"]}
        mode="edit"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    fireEvent.click(screen.getByText("Save changes"));
    expect(submitted!.allowed_models).toEqual([
      "ghost/offline-machine-model",
      "local/llama-3.1-8b",
    ]);
  });

  it("switches allowed models to machine models for self-route keys", () => {
    render(
      <KeyForm
        models={["gpt-oss-20b"]}
        selfRouteModels={["local/llama-3.1-8b"]}
        mode="create"
        submitting={false}
        onCancel={() => {}}
        onSubmit={() => {}}
      />
    );

    expect(screen.getByText("gpt-oss-20b")).toBeInTheDocument();
    fireEvent.click(screen.getByText("My Machine only — free"));
    expect(screen.getByText("local/llama-3.1-8b")).toBeInTheDocument();
    expect(screen.queryByText("gpt-oss-20b")).toBeNull();
  });

  it("never submits models hidden by the current route mode", () => {
    let submitted: UpdateKeyBody | null = null;
    render(
      <KeyForm
        models={["gpt-oss-20b"]}
        selfRouteModels={["local/llama-3.1-8b"]}
        mode="create"
        submitting={false}
        onCancel={() => {}}
        onSubmit={(b) => {
          submitted = b;
        }}
      />
    );
    fireEvent.change(screen.getByPlaceholderText("e.g. Production server"), {
      target: { value: "mode-switch-key" },
    });

    // Select a public model, then switch to "My Machine only": the hidden
    // public selection must not reach the allow-list, or the self-route key
    // would reject the machine models the picker now shows.
    fireEvent.click(screen.getByText("gpt-oss-20b"));
    fireEvent.click(screen.getByText("My Machine only — free"));
    fireEvent.click(screen.getByText("local/llama-3.1-8b"));
    fireEvent.click(screen.getByText("Create key"));

    expect(submitted).not.toBeNull();
    expect(submitted!.allowed_models).toEqual(["local/llama-3.1-8b"]);

    // Switching back restores the public selection (it was hidden, not lost).
    fireEvent.click(screen.getByText("My Machine only — free"));
    fireEvent.click(screen.getByText("Create key"));
    expect(submitted!.allowed_models).toEqual(["gpt-oss-20b"]);
  });
});
