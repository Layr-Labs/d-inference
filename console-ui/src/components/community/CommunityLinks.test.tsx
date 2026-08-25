// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { CommunityLinks } from "./CommunityLinks";
import { SLACK_INVITE_URL } from "./constants";

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

describe("CommunityLinks", () => {
  it("points the Slack icon at the current invite", () => {
    render(<CommunityLinks />);
    const link = screen.getByLabelText("Join the Darkbloom Slack") as HTMLAnchorElement;
    expect(link.href).toBe(SLACK_INVITE_URL);
    expect(link.href).toContain("zt-47hf6xy0n");
  });
});
