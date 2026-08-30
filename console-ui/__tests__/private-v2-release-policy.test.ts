import { describe, expect, it } from "vitest";
import {
  parsePrivateV2ReleaseAllowlist,
  validatePrivateV2ReleasePin,
} from "@/lib/private-v2-release-policy";

const RELEASE_A = "ab".repeat(32);
const RELEASE_B = "cd".repeat(32);

describe("private-v2 compile-time release allowlist", () => {
  it("accepts only a signed process hash pinned by the console build", () => {
    expect(() => validatePrivateV2ReleasePin(
      RELEASE_A,
      `${RELEASE_A},${RELEASE_B}`,
    )).not.toThrow();
    expect(() => validatePrivateV2ReleasePin(
      "33".repeat(32),
      `${RELEASE_A},${RELEASE_B}`,
    )).toThrow("not pinned");
  });

  it("fails closed when configuration is missing, malformed, uppercase, or duplicated", () => {
    expect(() => validatePrivateV2ReleasePin(RELEASE_A, undefined)).toThrow("not configured");
    expect(parsePrivateV2ReleaseAllowlist(`${RELEASE_A}, ${RELEASE_B}`).error).toContain("invalid");
    expect(parsePrivateV2ReleaseAllowlist(RELEASE_A.toUpperCase()).error).toContain("invalid");
    expect(parsePrivateV2ReleaseAllowlist(`${RELEASE_A},${RELEASE_A}`).error).toContain("duplicate");
  });

  it("rejects a non-canonical signed process hash even if configuration is invalid", () => {
    expect(() => validatePrivateV2ReleasePin(RELEASE_A.toUpperCase(), undefined)).toThrow(
      "canonical lowercase SHA-256",
    );
  });
});
