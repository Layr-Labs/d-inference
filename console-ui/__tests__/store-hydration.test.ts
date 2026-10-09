import { describe, it, expect, beforeEach, vi } from "vitest";

// Regression coverage for the "nav buttons unclickable after login" bug.
//
// Root cause: the store computed its initial `sidebarOpen` from
// `window.innerWidth` and let zustand's `persist` middleware rehydrate
// synchronously on load. Both make the FIRST client render diverge from the
// server HTML, which triggers a React hydration mismatch (#418). React then
// regenerates the whole tree, re-mounting the freshly-SSR'd sidebar and
// stranding it (via its slide-in transform) so its nav links can't be clicked.
//
// The fix: a deterministic SSR-safe default (`sidebarOpen: true`) plus
// `skipHydration: true`, with AppShell calling `persist.rehydrate()` after mount.

const STORE_KEY = "darkbloom-store";

describe("store SSR-safe hydration (regression: nav unclickable / #418)", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.resetModules();
  });

  it("initializes sidebarOpen to a deterministic true, independent of window.innerWidth", async () => {
    // The old code returned `window.innerWidth >= 640`. Force a small viewport to
    // prove the initial value no longer depends on it (otherwise the server,
    // which has no window, would render a different sidebar than the client).
    Object.defineProperty(window, "innerWidth", {
      value: 320,
      configurable: true,
      writable: true,
    });

    const { useStore } = await import("@/lib/store");
    expect(useStore.getState().sidebarOpen).toBe(true);
  });

  it("does not apply persisted state until rehydrate() runs (skipHydration)", async () => {
    // Persist values that differ from the SSR defaults. With synchronous
    // rehydration (the bug), these would be applied during module init so the
    // first client render diverges from the server HTML.
    localStorage.setItem(
      STORE_KEY,
      JSON.stringify({
        state: {
          sidebarOpen: false,
          chats: [{ id: "c1", title: "Saved chat", messages: [], createdAt: 0 }],
          activeChatId: "c1",
          selectedModel: "saved-model",
          useMyMachine: true,
        },
        version: 0,
      })
    );

    const { useStore } = await import("@/lib/store");

    // First-render state MUST equal the in-code defaults so it matches the
    // server render. (Pre-fix this fails: persist applies the stored values now.)
    expect(useStore.getState().sidebarOpen).toBe(true);
    expect(useStore.getState().chats).toEqual([]);
    expect(useStore.getState().selectedModel).toBe("");

    // AppShell triggers this on mount — only then is persisted state applied.
    await useStore.persist.rehydrate();
    expect(useStore.getState().sidebarOpen).toBe(false);
    expect(useStore.getState().chats).toHaveLength(1);
    expect(useStore.getState().selectedModel).toBe("saved-model");
  });

  it("still writes state changes back to localStorage after the fix", async () => {
    const { useStore } = await import("@/lib/store");
    useStore.getState().setSidebarOpen(false);

    const raw = localStorage.getItem(STORE_KEY);
    expect(raw).toBeTruthy();
    expect(JSON.parse(raw as string).state.sidebarOpen).toBe(false);
  });
});
