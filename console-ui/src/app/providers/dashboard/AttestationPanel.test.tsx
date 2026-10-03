// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AttestationPanel } from "./AttestationPanel";
import { makeProvider } from "./testFixtures";

describe("AttestationPanel", () => {
  it("does not treat MDA nonce binding as a Secure Enclave requirement", () => {
    const { container } = render(
      <AttestationPanel
        provider={makeProvider({ se_key_bound: false })}
        challengeMaxAgeSeconds={360}
      />,
    );

    expect(screen.queryByText("SE key bound to MDA nonce")).not.toBeInTheDocument();
    expect(screen.getByText("Hardware-bound P-256 identity")).toBeInTheDocument();
    expect(container.querySelector(".text-accent-amber")).toBeNull();
  });
});
