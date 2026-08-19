import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import AppLinkPage, {
  APP_CALLBACK_URL,
  buildAppCallbackURL,
} from "@/app/auth/app-link/page";

// Tests for the /auth/app-link Privy handoff page: the macOS app opens this
// route inside ASWebAuthenticationSession and expects to be called back on
// darkbloom://auth/callback#token=<jwt> once the user authenticates.

const auth = vi.hoisted(() => ({
  ready: true,
  authenticated: false,
  login: vi.fn(),
  getAccessToken: vi.fn(),
}));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => auth }));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const replace = vi.fn();

beforeEach(() => {
  vi.clearAllMocks();
  auth.ready = true;
  auth.authenticated = false;
  auth.getAccessToken.mockResolvedValue("privy-jwt-123");
  // jsdom's Location is not configurable on modern Node; swap the object.
  delete (window as never as { location?: Location }).location;
  (window as never as { location: unknown }).location = {
    ...Object.create(null),
    replace,
    href: "https://console.darkbloom.dev/auth/app-link",
  };
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("buildAppCallbackURL", () => {
  it("transports the token in the URL fragment, never the query", () => {
    const url = buildAppCallbackURL("eyJhbGciOiJFUzI1NiJ9.payload.sig");
    expect(url.startsWith(`${APP_CALLBACK_URL}#token=`)).toBe(true);
    expect(url).toContain("darkbloom://auth/callback#token=eyJhbGciOiJFUzI1NiJ9.payload.sig");
    expect(url).not.toContain("?token=");
    expect(url).not.toContain("token=privy"); // no raw leakage outside fragment
  });

  it("encodes reserved characters", () => {
    expect(buildAppCallbackURL("a/b+c=d")).toBe(
      `${APP_CALLBACK_URL}#token=${encodeURIComponent("a/b+c=d")}`
    );
  });
});

describe("/auth/app-link page", () => {
  it("gates the sign-in CTA until Privy is ready (no dead clicks)", () => {
    auth.ready = false;
    render(<AppLinkPage />);
    const btn = screen.getByRole("button", { name: /loading/i });
    expect(btn).toBeDisabled();
    fireEvent.click(btn);
    expect(auth.login).not.toHaveBeenCalled();
  });

  it("starts the Privy login from the sign-in CTA", () => {
    render(<AppLinkPage />);
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));
    expect(auth.login).toHaveBeenCalledTimes(1);
  });

  it("does not hand off while unauthenticated", () => {
    render(<AppLinkPage />);
    expect(replace).not.toHaveBeenCalled();
    expect(auth.getAccessToken).not.toHaveBeenCalled();
  });

  it("hands the Privy token to the app callback when authenticated", async () => {
    auth.authenticated = true;
    render(<AppLinkPage />);
    await waitFor(() => expect(replace).toHaveBeenCalledTimes(1));
    expect(replace).toHaveBeenCalledWith("darkbloom://auth/callback#token=privy-jwt-123");
    await screen.findByText(/you can close this window/i);
    expect(screen.getByRole("button", { name: /re-open darkbloom/i })).toBeInTheDocument();
  });

  it("offers a retry when no token can be minted", async () => {
    auth.authenticated = true;
    auth.getAccessToken.mockResolvedValue(null);
    render(<AppLinkPage />);
    await screen.findByRole("button", { name: /try again/i });
    expect(replace).not.toHaveBeenCalled();

    auth.getAccessToken.mockResolvedValue("privy-jwt-456");
    fireEvent.click(screen.getByRole("button", { name: /try again/i }));
    await waitFor(() =>
      expect(replace).toHaveBeenCalledWith("darkbloom://auth/callback#token=privy-jwt-456")
    );
  });
});
