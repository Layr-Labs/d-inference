import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { Sidebar } from "@/components/Sidebar";
import { TopBar } from "@/components/TopBar";
import { AppShell } from "@/components/AppShell";
import { useStore } from "@/lib/store";

const environment = vi.hoisted(() => ({ mobile: false, pathname: "/", push: vi.fn() }));
vi.mock("next/navigation", () => ({ usePathname: () => environment.pathname, useRouter: () => ({ push: environment.push }) }));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ ready: true, authenticated: false, login: vi.fn(), logout: vi.fn() }) }));
vi.mock("@/components/providers/ThemeProvider", () => ({ useTheme: () => ({ theme: "light", toggleTheme: vi.fn() }) }));
vi.mock("@/components/Toasts", () => ({ Toasts: () => null }));

beforeEach(() => {
  localStorage.clear();
  environment.mobile = false;
  environment.pathname = "/";
  environment.push.mockClear();
  vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: environment.mobile, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
  useStore.setState({ chats: [], activeChatId: null, sidebarOpen: true });
});

describe("Console navigation", () => {
  it("keeps page destinations available in the collapsed rail", () => {
    useStore.setState({ sidebarOpen: false });
    render(<Sidebar />);
    expect(screen.getByRole("link", { name: "Models" })).toHaveAttribute("href", "/models");
    fireEvent.click(screen.getByRole("button", { name: "Expand navigation" }));
    expect(screen.getByRole("button", { name: "New conversation" })).toBeVisible();
  });

  it("creates a conversation and opens the chat workspace from another page", () => {
    environment.pathname = "/models";
    render(<Sidebar />);
    fireEvent.click(screen.getByRole("button", { name: "New conversation" }));
    expect(useStore.getState().chats).toHaveLength(1);
    expect(environment.push).toHaveBeenCalledWith("/");
  });

  it("traps keyboard focus in the mobile drawer and supports Escape", () => {
    environment.mobile = true;
    render(<Sidebar />);
    expect(screen.getByRole("dialog", { name: "Console navigation" })).toBeVisible();
    const brand = screen.getByRole("link", { name: "Darkbloom" });
    const signIn = screen.getByRole("button", { name: "Sign in" });
    signIn.focus();
    fireEvent.keyDown(signIn, { key: "Tab" });
    expect(brand).toHaveFocus();
    fireEvent.keyDown(brand, { key: "Tab", shiftKey: true });
    expect(signIn).toHaveFocus();
    fireEvent.keyDown(signIn, { key: "Escape" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("returns focus to the mobile opener after dismissing navigation", () => {
    environment.mobile = true;
    useStore.setState({ sidebarOpen: false });
    render(<AppShell><TopBar /></AppShell>);
    const opener = screen.getByRole("button", { name: "Open navigation" });
    opener.focus();
    fireEvent.click(opener);
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
    expect(opener).toHaveFocus();
  });

  it("filters history and deletes a conversation without changing to it", () => {
    useStore.setState({ chats: ["Research", "Draft", "Code", "Ideas"].map((title) => ({ id: title, title, messages: [], createdAt: 0 })), activeChatId: "Draft" });
    render(<Sidebar />);
    fireEvent.change(screen.getByRole("textbox", { name: "Search conversations" }), { target: { value: "research" } });
    expect(screen.queryByRole("button", { name: "Ideas" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Delete Research" }));
    expect(useStore.getState().activeChatId).toBe("Draft");
    expect(useStore.getState().chats).toHaveLength(3);
  });

  it("offers a keyboard shortcut to collapse and reopen navigation", () => {
    render(<AppShell><p>Content</p></AppShell>);
    fireEvent.keyDown(document, { key: "b", ctrlKey: true });
    expect(screen.getByRole("button", { name: "Expand navigation" })).toBeVisible();
    fireEvent.keyDown(document, { key: "b", ctrlKey: true });
    expect(screen.getByRole("button", { name: "Collapse navigation" })).toBeVisible();
  });
});
