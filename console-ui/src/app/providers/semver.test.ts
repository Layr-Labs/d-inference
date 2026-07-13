import { describe, expect, it } from "vitest";
import { semverLess } from "./semver";

describe("semverLess", () => {
  it("orders beta increments and stable promotion", () => {
    expect(semverLess("0.8.0-beta.1", "0.8.0-beta.2")).toBe(true);
    expect(semverLess("0.8.0-beta.9", "0.8.0")).toBe(true);
    expect(semverLess("0.8.0", "0.8.0-beta.9")).toBe(false);
  });

  it("uses numeric core and prerelease identifiers", () => {
    expect(semverLess("0.9.10", "0.10.0")).toBe(true);
    expect(semverLess("1.0.0-beta.10", "1.0.0-beta.2")).toBe(false);
  });
});
