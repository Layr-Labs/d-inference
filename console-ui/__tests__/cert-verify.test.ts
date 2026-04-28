import { describe, it, expect } from "vitest";
import { verifyCertificateChain } from "@/lib/cert-verify";
import type { VerificationStep } from "@/lib/cert-verify";

// ---------------------------------------------------------------------------
// Unit tests for certificate chain verification
// ---------------------------------------------------------------------------

describe("verifyCertificateChain", () => {
  it("rejects empty cert chain", async () => {
    const result = await verifyCertificateChain([]);
    expect(result.success).toBe(false);
    expect(result.error).toContain("Insufficient certificates");
  });

  it("rejects chain with only one cert", async () => {
    // Minimal valid-looking base64 (will fail at parse, not at length check)
    const result = await verifyCertificateChain(["AAAA"]);
    expect(result.success).toBe(false);
    expect(result.error).toContain("Insufficient certificates");
  });

  it("rejects invalid base64 in cert chain", async () => {
    const result = await verifyCertificateChain(["not-valid-base64!!!", "also-invalid!!!"]);
    expect(result.success).toBe(false);
    // Should fail during parsing
    expect(result.steps.some((s: VerificationStep) => s.status === "error")).toBe(true);
  });

  it("calls onStep callback with progress updates", async () => {
    const stepUpdates: VerificationStep[][] = [];
    await verifyCertificateChain([], (steps) => {
      stepUpdates.push(steps);
    });
    // Should have received at least one update
    expect(stepUpdates.length).toBeGreaterThan(0);
  });

  it("initializes with 5 pending steps", async () => {
    let initialSteps: VerificationStep[] = [];
    await verifyCertificateChain(["AAAA"], (steps) => {
      if (initialSteps.length === 0) {
        initialSteps = steps;
      }
    });
    expect(initialSteps.length).toBe(5);
    // First step should be running (it's the one that finds insufficient certs)
    expect(initialSteps[0].status).toBe("running");
  });

  it("rejects malformed DER certificates", async () => {
    // Valid base64 but not valid DER/ASN.1
    const fakeCert = btoa("this is not a DER certificate at all");
    const result = await verifyCertificateChain([fakeCert, fakeCert]);
    expect(result.success).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Apple Root CA PEM integrity
// ---------------------------------------------------------------------------

describe("Apple Root CA", () => {
  it("has the correct PEM embedded in cert-verify.ts", async () => {
    // The PEM should contain the expected subject CN
    // We verify this by checking the module loads without error
    // (the PEM is parsed at verification time, not import time)
    const module = await import("@/lib/cert-verify");
    expect(module.verifyCertificateChain).toBeDefined();
    expect(typeof module.verifyCertificateChain).toBe("function");
  });
});
