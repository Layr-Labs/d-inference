// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { SlackJoinPopup } from "./SlackJoinPopup";
import { SLACK_INVITE_URL, SLACK_JOIN_DISMISSED_KEY } from "./constants";
import {
  INVITE_DISMISSED_EVENT,
  INVITE_DISMISSED_KEY,
} from "@/components/InviteCodeBanner";

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const authState = { authenticated: true };
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ authenticated: authState.authenticated }),
}));

const navState = { pathname: "/providers" };
vi.mock("next/navigation", () => ({
  usePathname: () => navState.pathname,
}));

beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
  authState.authenticated = true;
  navState.pathname = "/providers";
});

describe("SlackJoinPopup", () => {
  it("shows for a signed-in user and uses the current Slack invite", async () => {
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(screen.getByText(/Join the Darkbloom Slack/i)).toBeDefined()
    );
    const link = screen.getByRole("link", { name: /Join Slack/i }) as HTMLAnchorElement;
    expect(link.href).toBe(SLACK_INVITE_URL);
    expect(link.href).toContain("zt-47hf6xy0n");
  });

  it("stays hidden when not signed in", async () => {
    authState.authenticated = false;
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(localStorage.getItem(SLACK_JOIN_DISMISSED_KEY)).toBeNull()
    );
    expect(screen.queryByText(/Join the Darkbloom Slack/i)).toBeNull();
  });

  it("dismiss persists to localStorage", async () => {
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(screen.getByText(/Join the Darkbloom Slack/i)).toBeDefined()
    );
    fireEvent.click(screen.getByLabelText("Dismiss"));
    expect(screen.queryByText(/Join the Darkbloom Slack/i)).toBeNull();
    expect(localStorage.getItem(SLACK_JOIN_DISMISSED_KEY)).toBe("1");
  });

  it("does not show once dismissed", async () => {
    localStorage.setItem(SLACK_JOIN_DISMISSED_KEY, "1");
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(localStorage.getItem(SLACK_JOIN_DISMISSED_KEY)).toBe("1")
    );
    expect(screen.queryByText(/Join the Darkbloom Slack/i)).toBeNull();
  });

  it("still shows if the old provider Slack popup was dismissed", async () => {
    localStorage.setItem("darkbloom_provider_slack_dismissed", "1");
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(screen.getByText(/Join the Darkbloom Slack/i)).toBeDefined()
    );
  });

  it("yields the corner to the invite banner on the chat page", async () => {
    navState.pathname = "/";
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(screen.queryByText(/Join the Darkbloom Slack/i)).toBeNull()
    );

    localStorage.setItem(INVITE_DISMISSED_KEY, "1");
    window.dispatchEvent(new Event(INVITE_DISMISSED_EVENT));
    await waitFor(() =>
      expect(screen.getByText(/Join the Darkbloom Slack/i)).toBeDefined()
    );
  });

  it("shows on the chat page when the invite banner was already dismissed", async () => {
    navState.pathname = "/";
    localStorage.setItem(INVITE_DISMISSED_KEY, "1");
    render(<SlackJoinPopup />);
    await waitFor(() =>
      expect(screen.getByText(/Join the Darkbloom Slack/i)).toBeDefined()
    );
  });
});
