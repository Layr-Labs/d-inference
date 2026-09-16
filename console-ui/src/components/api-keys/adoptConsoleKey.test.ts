// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { adoptCreatedKeyIfUntracked } from "./adoptConsoleKey";
import { STORAGE_KEYS } from "@/lib/storage-keys";
import type { CreatedKey } from "@/lib/api";

const created: CreatedKey = {
  key: "sk-db-machine",
  data: {
    id: "key_machine",
    name: "my-machine",
    label: "sk-db-mach...hine",
    disabled: false,
    limit_reset: "none",
    usage_usd: 0,
    self_route_only: true,
    created_at: new Date().toISOString(),
  },
};

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("adoptCreatedKeyIfUntracked", () => {
  it("adopts when this browser has no console key", () => {
    const point = vi.fn();
    expect(adoptCreatedKeyIfUntracked(created, "privy-token", point)).toBe(true);
    expect(point).toHaveBeenCalledWith(created);
  });

  it("replaces an untracked auto-provisioned secret and revokes it", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "sk-db-untitled");
    const fetchMock = vi.fn(async () => ({ ok: true, json: async () => ({ status: "revoked" }) }));
    vi.stubGlobal("fetch", fetchMock);
    const point = vi.fn((next: CreatedKey) => {
      localStorage.setItem(STORAGE_KEYS.apiKey, next.key);
      localStorage.setItem(STORAGE_KEYS.consoleKeyId, next.data.id);
    });

    expect(adoptCreatedKeyIfUntracked(created, "privy-token", point)).toBe(true);
    expect(point).toHaveBeenCalledWith(created);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/auth/keys",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({ key: "sk-db-untitled" }),
      }),
    );
  });

  it("adopts when only a leftover console key id remains", () => {
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key_from_previous_session");
    const point = vi.fn();
    expect(adoptCreatedKeyIfUntracked(created, "privy-token", point)).toBe(true);
    expect(point).toHaveBeenCalledWith(created);
  });

  it("does not replace a tracked console key", () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "sk-db-existing");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key_existing");
    const point = vi.fn();
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    expect(adoptCreatedKeyIfUntracked(created, "privy-token", point)).toBe(false);
    expect(point).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
