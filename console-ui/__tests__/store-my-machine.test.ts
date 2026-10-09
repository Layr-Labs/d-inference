import { describe, it, expect } from "vitest";
import { useStore } from "@/lib/store";

// Store: useMyMachine toggle (persisted preference).

describe("store useMyMachine", () => {
  it("defaults to false and toggles", () => {
    expect(useStore.getState().useMyMachine).toBe(false);
    useStore.getState().setUseMyMachine(true);
    expect(useStore.getState().useMyMachine).toBe(true);
    useStore.getState().setUseMyMachine(false);
    expect(useStore.getState().useMyMachine).toBe(false);
  });
});
