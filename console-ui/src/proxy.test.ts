import { describe, expect, it } from "vitest";
import { NextRequest } from "next/server";
import proxy from "./proxy";

// There is no /login page; this redirect is the only thing keeping old
// /login links from landing on a 404.
describe("proxy", () => {
  it("redirects legacy /login links to the app root", () => {
    const res = proxy(new NextRequest("https://console.darkbloom.dev/login?next=%2Fbilling"));
    expect(res.status).toBe(307);
    expect(new URL(res.headers.get("location")!).pathname).toBe("/");
  });

  it("passes every other path through", () => {
    const res = proxy(new NextRequest("https://console.darkbloom.dev/providers"));
    expect(res.headers.get("location")).toBeNull();
    expect(res.headers.get("x-middleware-next")).toBe("1");
  });
});
