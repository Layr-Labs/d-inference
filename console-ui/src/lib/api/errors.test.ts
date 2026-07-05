import { describe, it, expect } from "vitest";
import { ApiError, apiErrorFromBody, parseApiErrorBody } from "./errors";

// The coordinator's OpenAI-style envelope, as written by errorResponse in
// coordinator/api/httputil.go (code mirrors type by default).
const envelope = (type: string, message: string) => ({
  error: { type, message, code: type },
});

describe("parseApiErrorBody", () => {
  it("parses a direct coordinator envelope", () => {
    expect(parseApiErrorBody(envelope("stripe_account_gone", "account no longer exists"))).toEqual({
      code: "stripe_account_gone",
      message: "account no longer exists",
    });
  });

  it("unwraps the proxy's string-wrapped envelope", () => {
    // Next.js proxy routes re-wrap non-OK coordinator bodies as
    // { error: "<raw JSON text>" } - see app/api/payments/*/route.ts.
    const wrapped = { error: JSON.stringify(envelope("instant_unavailable", "need a debit card")) + "\n" };
    expect(parseApiErrorBody(wrapped)).toEqual({
      code: "instant_unavailable",
      message: "need a debit card",
    });
  });

  it("falls back to type when code is missing", () => {
    expect(parseApiErrorBody({ error: { type: "stripe_error", message: "boom" } })).toEqual({
      code: "stripe_error",
      message: "boom",
    });
  });

  it("treats a non-JSON string error as a plain message", () => {
    expect(parseApiErrorBody({ error: "upstream timed out" })).toEqual({
      code: "",
      message: "upstream timed out",
    });
  });

  it("returns null for empty or unusable bodies", () => {
    expect(parseApiErrorBody({})).toBeNull();
    expect(parseApiErrorBody(null)).toBeNull();
    expect(parseApiErrorBody({ error: "" })).toBeNull();
    expect(parseApiErrorBody({ error: {} })).toBeNull();
    expect(parseApiErrorBody("nope")).toBeNull();
  });
});

describe("apiErrorFromBody", () => {
  it("builds an ApiError carrying code, message, and status", () => {
    const err = apiErrorFromBody(envelope("insufficient_withdrawable", "only earned funds"), 400, "fallback");
    expect(err).toBeInstanceOf(ApiError);
    expect(err.code).toBe("insufficient_withdrawable");
    expect(err.message).toBe("only earned funds");
    expect(err.status).toBe(400);
  });

  it("uses the fallback message when the body is empty", () => {
    const err = apiErrorFromBody({}, 502, "Withdrawal failed (502)");
    expect(err.code).toBe("");
    expect(err.message).toBe("Withdrawal failed (502)");
    expect(err.status).toBe(502);
  });
});
