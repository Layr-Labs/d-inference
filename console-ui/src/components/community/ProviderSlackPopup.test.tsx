// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent, act } from "@testing-library/react";
import { ProviderSlackPopup } from "./ProviderSlackPopup";
import { PROVIDER_SLACK_DISMISSED_KEY } from "./constants";
import {
  INVITE_DISMISSED_EVENT,
  INVITE_DISMISSED_KEY,
} from "@/components/InviteCodeBanner";

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const authState = { authenticated: true };
const getAccessToken = vi.fn(async () => "test-token");
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ authenticated: authState.authenticated, getAccessToken }),
}));

const navState = { pathname: "/providers" };
vi.mock("next/navigation", () => ({
  usePathname: () => navState.pathname,
}));

function mockProvidersFetch(providers: Array<{ online: boolean }>) {
  const fetchMock = vi.fn(async () => ({
    ok: true,
    json: async () => ({ providers }),
  }));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

const flush = () => act(async () => {});

beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
  authState.authenticated = true;
  navState.pathname = "/providers";
});

describe("ProviderSlackPopup", () => {
  it("shows for a user with a connected provider", async () => {
    mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await waitFor(() =>
      expect(screen.getByText(/You're a provider/i)).toBeDefined()
    );
    const link = screen.getByText(/Join the provider channel/i) as HTMLAnchorElement;
    expect(link.href).toContain("join.slack.com/t/darkbloom");
  });

  it("stays hidden when no provider is online", async () => {
    const fetchMock = mockProvidersFetch([{ online: false }]);
    render(<ProviderSlackPopup />);
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    await flush();
    expect(screen.queryByText(/You're a provider/i)).toBeNull();
  });

  it("stays hidden when not authenticated, without fetching", async () => {
    authState.authenticated = false;
    const fetchMock = mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await flush();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(screen.queryByText(/You're a provider/i)).toBeNull();
  });

  it("dismiss persists to localStorage", async () => {
    mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await waitFor(() =>
      expect(screen.getByText(/You're a provider/i)).toBeDefined()
    );
    fireEvent.click(screen.getByLabelText("Dismiss"));
    expect(screen.queryByText(/You're a provider/i)).toBeNull();
    expect(localStorage.getItem(PROVIDER_SLACK_DISMISSED_KEY)).toBe("1");
  });

  it("does not fetch at all once dismissed", async () => {
    localStorage.setItem(PROVIDER_SLACK_DISMISSED_KEY, "1");
    const fetchMock = mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await flush();
    expect(screen.queryByText(/You're a provider/i)).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("yields the corner to the invite banner on the chat page", async () => {
    navState.pathname = "/";
    const fetchMock = mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    await flush();
    expect(screen.queryByText(/You're a provider/i)).toBeNull();

    // Appears once the invite banner is dismissed.
    act(() => {
      localStorage.setItem(INVITE_DISMISSED_KEY, "1");
      window.dispatchEvent(new Event(INVITE_DISMISSED_EVENT));
    });
    await waitFor(() =>
      expect(screen.getByText(/You're a provider/i)).toBeDefined()
    );
  });

  it("shows on the chat page when the invite banner was already dismissed", async () => {
    navState.pathname = "/";
    localStorage.setItem(INVITE_DISMISSED_KEY, "1");
    mockProvidersFetch([{ online: true }]);
    render(<ProviderSlackPopup />);
    await waitFor(() =>
      expect(screen.getByText(/You're a provider/i)).toBeDefined()
    );
  });
});
