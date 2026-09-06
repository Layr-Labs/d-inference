import { act, cleanup, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Sidebar } from "@/components/Sidebar";
import { ConsoleExperienceProvider } from "../console-entry/ConsoleExperience";
import { useStore } from "@/lib/store";

const auth = vi.hoisted(() => ({
  ready: false, authenticated: false, user: { id: "account-a" },
  getAccessToken: vi.fn().mockResolvedValue("test-session"),
}));
vi.mock("next/navigation", () => ({ usePathname: () => "/earn", useRouter: () => ({ push: vi.fn() }) }));
vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => auth }));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ ...auth, login: vi.fn(), logout: vi.fn() }) }));
vi.mock("@/components/providers/ThemeProvider", () => ({ useTheme: () => ({ theme: "light", toggleTheme: vi.fn() }) }));

beforeEach(() => {
  auth.ready = false;
  auth.authenticated = false;
  localStorage.clear();
  vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe.each([true, false])("Provider earnings navigation (sidebar open: %s)", (sidebarOpen) => {
  it("never shows earnings while auth loads or after resolving a guest", () => {
    useStore.setState({ sidebarOpen });
    const view = render(<ConsoleExperienceProvider><Sidebar /></ConsoleExperienceProvider>);
    expect(screen.queryByRole("link", { name: "Your earnings" })).not.toBeInTheDocument();
    auth.ready = true;
    view.rerender(<ConsoleExperienceProvider><Sidebar /></ConsoleExperienceProvider>);
    expect(screen.queryByRole("link", { name: "Your earnings" })).not.toBeInTheDocument();
  });

  it.each(["empty", "linked", "error"])("waits for provider discovery before rendering the %s result", async (outcome) => {
    useStore.setState({ sidebarOpen });
    auth.ready = true;
    auth.authenticated = true;
    let respond!: (response: Response) => void;
    vi.stubGlobal("fetch", vi.fn(() => new Promise<Response>((resolve) => { respond = resolve; })));
    render(<ConsoleExperienceProvider><Sidebar /></ConsoleExperienceProvider>);
    await act(async () => {});
    expect(screen.queryByRole("link", { name: "Your earnings" })).not.toBeInTheDocument();
    await act(async () => {
      respond(outcome === "error" ? new Response(null, { status: 503 }) : Response.json({
        providers: outcome === "linked" ? [{ id: "mac-a", online: false }] : [],
      }));
    });
    if (outcome === "linked") {
      expect(screen.getByRole("link", { name: "Your earnings" })).toHaveAttribute("href", "/providers/earnings");
    } else {
      expect(screen.queryByRole("link", { name: "Your earnings" })).not.toBeInTheDocument();
    }
    expect(screen.getByRole("link", { name: "Earnings calculator" })).toHaveAttribute("href", "/earn");
  });
});
