import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";

// ---------------------------------------------------------------------------
// PrivyClientProvider — production misconfiguration guard
//
// IS_PRIVY_CONFIGURED is evaluated at module scope, so we use
// vi.resetModules() + dynamic import to get a fresh evaluation of the
// NEXT_PUBLIC_PRIVY_APP_ID env var.  The production check itself (isProductionEnv)
// reads process.env.NODE_ENV at render time, so vi.stubEnv works for it even
// without a module reload.
// ---------------------------------------------------------------------------

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.unstubAllEnvs();
});

// ---------------------------------------------------------------------------
// Case A: production build + missing/placeholder app ID → config-error screen
// ---------------------------------------------------------------------------

const CONFIG_ERROR_PATTERN = /Authentication is not configured/i;

async function renderProviderProd(appId: string) {
  vi.stubEnv("NEXT_PUBLIC_PRIVY_APP_ID", appId);
  vi.stubEnv("NODE_ENV", "production");
  const { PrivyClientProvider } = await import(
    "@/components/providers/PrivyClientProvider"
  );
  render(
    <PrivyClientProvider>
      <span data-testid="child-probe">should not appear</span>
    </PrivyClientProvider>
  );
}

describe("PrivyClientProvider — production with unconfigured app ID", () => {
  it("shows config-error UI and does NOT render children when NODE_ENV=production and app ID is absent", async () => {
    // Ensure NEXT_PUBLIC_PRIVY_APP_ID is absent (force module re-evaluation).
    await renderProviderProd("");

    // Config-error message must be visible.
    expect(screen.getByText(CONFIG_ERROR_PATTERN)).toBeInTheDocument();
    expect(
      screen.getByText(/NEXT_PUBLIC_PRIVY_APP_ID/i)
    ).toBeInTheDocument();
    expect(screen.getByText(/misconfigured/i)).toBeInTheDocument();

    // Children must NOT be rendered.
    expect(screen.queryByTestId("child-probe")).not.toBeInTheDocument();
  });

  it("shows config-error UI when app ID is the literal 'placeholder' string in production", async () => {
    await renderProviderProd("placeholder");

    expect(screen.getByText(CONFIG_ERROR_PATTERN)).toBeInTheDocument();
    expect(screen.queryByTestId("child-probe")).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Case B: non-production (test/dev) + missing app ID → mock fallback renders children
// ---------------------------------------------------------------------------

describe("PrivyClientProvider — non-production with unconfigured app ID", () => {
  it("renders children via mock-auth fallback when NODE_ENV is not production", async () => {
    // Default vitest NODE_ENV is "test"; NEXT_PUBLIC_PRIVY_APP_ID unset.
    vi.stubEnv("NEXT_PUBLIC_PRIVY_APP_ID", "");
    // Do NOT stub NODE_ENV — vitest default is "test", which is non-production.

    const { PrivyClientProvider } = await import(
      "@/components/providers/PrivyClientProvider"
    );

    render(
      <PrivyClientProvider>
        <span data-testid="child-probe">hello</span>
      </PrivyClientProvider>
    );

    // Children must render.
    expect(screen.getByTestId("child-probe")).toBeInTheDocument();
    expect(screen.getByText("hello")).toBeInTheDocument();

    // Config-error message must NOT be present.
    expect(
      screen.queryByText(/Authentication is not configured/i)
    ).not.toBeInTheDocument();
  });
});
