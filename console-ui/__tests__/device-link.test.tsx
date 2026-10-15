import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import LinkPage from "@/app/link/page";

const session = vi.hoisted(() => ({
  query: "",
  authenticated: true,
  getAccessToken: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams(session.query),
}));
vi.mock("@/components/app-providers/PrivyClientProvider", () => ({
  useAuthContext: () => ({
    ready: true,
    authenticated: session.authenticated,
    getAccessToken: session.getAccessToken,
    login: vi.fn(),
    user: null,
  }),
}));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const fetchMock = vi.fn();

beforeEach(() => {
  session.query = "";
  session.authenticated = true;
  session.getAccessToken.mockReset().mockResolvedValue("test-session");
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function submit(name: string) {
  fireEvent.change(screen.getByPlaceholderText("XXXX-XXXX"), { target: { value: "abcd1234" } });
  fireEvent.click(screen.getByRole("button", { name }));
}

describe("device approval purpose", () => {
  const desktopQuery = "purpose=desktop_account";
  const authorizeDesktopLabel = "Authorize Desktop";
  const desktopApprovedHeading = "Desktop Access Approved";

  it("preserves provider linking as the default", async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ status: "approved" })));
    render(<LinkPage />);
    submit("Link Device");
    await screen.findByText("Device Linked!");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      user_code: "ABCD-1234", purpose: "provider",
    });
  });

  it("explains and submits read-only desktop consent without claiming provider linkage", async () => {
    session.query = desktopQuery;
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ status: "approved", purpose: "desktop_account" })));
    render(<LinkPage />);
    expect(screen.getByText(/cannot start providers, manage API keys, or withdraw funds/)).toBeInTheDocument();
    submit(authorizeDesktopLabel);
    await screen.findByText(desktopApprovedHeading);
    expect(fetchMock).toHaveBeenCalledWith("/api/device/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer test-session" },
      body: JSON.stringify({ user_code: "ABCD-1234", purpose: "desktop_account" }),
    });
    expect(screen.queryByText("Device Linked!")).not.toBeInTheDocument();
    expect(screen.getByText(/provider configuration has not changed/)).toBeInTheDocument();
  });

  it("does not announce read-only approval when the server did not acknowledge the scope", async () => {
    session.query = desktopQuery;
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ status: "approved" })));
    render(<LinkPage />);
    submit(authorizeDesktopLabel);
    await screen.findByText(/did not confirm read-only desktop access/);
    expect(screen.queryByText(desktopApprovedHeading)).not.toBeInTheDocument();
  });

  it("retains the scoped purpose when approval fails and the user retries", async () => {
    session.query = desktopQuery;
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: "Code expired" } }), { status: 410 }));
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ status: "approved", purpose: "desktop_account" })));
    render(<LinkPage />);
    submit(authorizeDesktopLabel);
    await screen.findByText("Code expired");
    submit(authorizeDesktopLabel);
    await screen.findByText(desktopApprovedHeading);
    expect(fetchMock.mock.calls.map(([, options]) => JSON.parse(options.body).purpose)).toEqual([
      "desktop_account", "desktop_account",
    ]);
  });

  it("does not submit consent without an authenticated session", async () => {
    session.query = desktopQuery;
    session.getAccessToken.mockResolvedValue(null);
    render(<LinkPage />);
    submit(authorizeDesktopLabel);
    await waitFor(() => expect(screen.getByText(/Failed to get auth token/)).toBeInTheDocument());
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
