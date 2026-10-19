import { afterEach, describe, expect, it, vi } from "vitest";
import ConsoleHomePage from "./page";

const redirect = vi.hoisted(() => vi.fn((location: string) => { throw new Error(`REDIRECT:${location}`); }));
vi.mock("next/navigation", () => ({ redirect }));

describe("console root referral links", () => {
  afterEach(() => vi.clearAllMocks());

  it("retains the provider destination for ordinary root visits", async () => {
    await expect(ConsoleHomePage({ searchParams: Promise.resolve({}) })).rejects.toThrow("REDIRECT:/providers");
    expect(redirect).toHaveBeenCalledWith("/providers");
  });

  it("preserves legacy root referral links through the server redirect", async () => {
    await expect(ConsoleHomePage({ searchParams: Promise.resolve({ ref: "alice-builds" }) })).rejects.toThrow("REDIRECT:/referrals?ref=ALICE-BUILDS");
    expect(redirect).toHaveBeenCalledWith("/referrals?ref=ALICE-BUILDS");
  });

  it("encodes valid existing Unicode codes in the consumer destination", async () => {
    await expect(ConsoleHomePage({ searchParams: Promise.resolve({ ref: "élodie" }) })).rejects.toThrow("REDIRECT:/referrals?ref=%C3%89LODIE");
    expect(redirect).toHaveBeenCalledWith("/referrals?ref=%C3%89LODIE");
  });

  it("does not forward invalid or ambiguous parameters", async () => {
    for (const ref of ["//attacker.test", "a", ["ALICE", "BOB"]]) {
      await expect(ConsoleHomePage({ searchParams: Promise.resolve({ ref }) })).rejects.toThrow("REDIRECT:/providers");
    }
    expect(redirect).toHaveBeenCalledTimes(3);
  });
});
