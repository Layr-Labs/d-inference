import { describe, expect, it } from "vitest";
import { macIdentity } from "./mac-hardware";

describe("Mac hardware identity", () => {
  it.each([
    ["Mac13,2", "studio", "Mac Studio"], ["Mac14,13", "studio", "Mac Studio"],
    ["Mac15,14", "studio", "Mac Studio"], ["Mac16,9", "studio", "Mac Studio"],
    ["Macmini9,1", "mini", "Mac mini"], ["Mac14,12", "mini", "Mac mini"], ["Mac16,10", "mini", "Mac mini"],
    ["MacBookPro18,4", "macbook", "MacBook Pro"], ["Mac16,5", "macbook", "MacBook Pro"],
    ["Mac17,9", "macbook", "MacBook Pro"], ["Mac14,2", "macbook", "MacBook Air"],
    ["Mac17,4", "macbook", "MacBook Air"], [" Mac MINI ", "mini", "Mac mini"],
    ["Mac Studio (2025)", "studio", "Mac Studio"], ["MacBook Air", "macbook", "MacBook Air"],
  ])("identifies %s without guessing from the chip", (model, kind, name) => {
    expect(macIdentity(model)).toEqual({ kind, name });
  });
  it("preserves unknown identifiers with a neutral icon", () => {
    expect(macIdentity("Mac99,1")).toEqual({ kind: "unknown", name: "Mac99,1" });
    expect(macIdentity()).toEqual({ kind: "unknown", name: "Mac" });
  });
});
