import { beforeEach, describe, expect, it, vi } from "vitest";
import { captureReferral, clearReferral, normalizeReferral, normalizeRegistrationCode, readReferral, REFERRAL_STORAGE_KEY } from "./attribution";

describe("referral first-touch attribution", () => {
  beforeEach(() => localStorage.clear());

  it("normalizes a referral and preserves it through later links and reloads", () => {
    expect(captureReferral("?ref=alice-123")).toBe("ALICE-123");
    expect(captureReferral("?ref=bob")).toBe("ALICE-123");
    expect(readReferral()).toBe("ALICE-123");
    expect(captureReferral("")).toBe("ALICE-123");
  });

  it("ignores malformed referral and invitation parameters", () => {
    for (const query of ["?ref=a", "?ref=-alice", "?ref=alice-", "?ref=%3Cscript%3E", "?invite=ALICE"]) {
      expect(captureReferral(query)).toBeNull();
    }
    expect(localStorage.getItem(REFERRAL_STORAGE_KEY)).toBeNull();
  });

  it("accepts existing Unicode codes using the server's byte limit and simple uppercase mapping", () => {
    expect(captureReferral("?ref=%C3%A9lodie")).toBe("ÉLODIE");
    expect(normalizeReferral("straße")).toBe("STRAßE");
    expect(normalizeReferral("猫猫猫猫猫猫猫")).toBeNull(); // 21 UTF-8 bytes
    expect(normalizeRegistrationCode("ÉLODIE")).toBeNull();
    expect(normalizeRegistrationCode("ßab")).toBeNull();
    expect(normalizeRegistrationCode("alice-123")).toBe("ALICE-123");
  });

  it("clears only the referral that was successfully applied", () => {
    captureReferral("?ref=alice");
    clearReferral("BOB");
    expect(readReferral()).toBe("ALICE");
    clearReferral("ALICE");
    expect(readReferral()).toBeNull();
  });

  it("can capture the current link when storage is unavailable", () => {
    const get = vi.spyOn(localStorage, "getItem").mockImplementation(() => { throw new Error("disabled"); });
    const set = vi.spyOn(localStorage, "setItem").mockImplementation(() => { throw new Error("disabled"); });
    expect(captureReferral("?ref=alice")).toBe("ALICE");
    get.mockRestore(); set.mockRestore();
  });
});
