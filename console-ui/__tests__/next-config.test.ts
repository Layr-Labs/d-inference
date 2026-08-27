import { describe, expect, it } from "vitest";
import {
  contentSecurityPolicy,
  coordinatorConnectOrigin,
} from "../next.config";

describe("coordinator Content Security Policy", () => {
  it.each([
    "https://api.darkbloom.dev",
    "https://api.dev.darkbloom.xyz",
    "http://127.0.0.1:8080",
  ])("allows the configured coordinator origin: %s", (coordinatorUrl) => {
    expect(contentSecurityPolicy(coordinatorUrl)).toContain(
      `connect-src 'self' ${new URL(coordinatorUrl).origin} `
    );
  });

  it("drops paths while preserving the configured origin", () => {
    expect(
      coordinatorConnectOrigin("https://api.dev.darkbloom.xyz/proxy/path")
    ).toBe("https://api.dev.darkbloom.xyz");
  });

  it("rejects non-HTTP coordinator schemes", () => {
    expect(() => coordinatorConnectOrigin("file:///tmp/coordinator")).toThrow(
      "must use http or https"
    );
  });
});
