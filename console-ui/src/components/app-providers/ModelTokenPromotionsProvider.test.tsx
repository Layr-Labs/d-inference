// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AuthState } from "./PrivyClientProvider";
import { ModelTokenPromotionsProvider, useModelTokenPromotions, type ModelTokenOffer, type ModelTokenGrant } from "./ModelTokenPromotionsProvider";
import { ModelTokenAllowance } from "@/components/chat/ModelTokenAllowance";
import { ModelTokenClaims } from "@/components/chat/ModelTokenClaims";
import { useStore } from "@/lib/store";

const h = vi.hoisted(() => ({ auth: null as unknown as AuthState }));
vi.mock("./PrivyClientProvider", () => ({ useAuthContext: () => h.auth }));
const grant: ModelTokenGrant = { model_id: "bonsai", total_tokens: 150_000_000, used_tokens: 0, reserved_tokens: 0, remaining_tokens: 150_000_000, claimed_at: "2026-09-18T00:00:00Z" };
const offer: ModelTokenOffer = { model_id: "bonsai", tokens: 150_000_000, max_claims: 250, remaining_claims: 250, signup_cutoff_at: "2026-09-19T07:00:00Z", claim_ends_at: "2026-09-20T07:00:00Z", status: "available" };
const response = (grants: ModelTokenGrant[] = [], offers: ModelTokenOffer[] = [offer]) => ({ ok: true, status: 200, json: async () => ({ grants, offers }) });
function Viewer() {
  const state = useModelTokenPromotions();
  return <><pre data-testid="state">{JSON.stringify({ ready: state.ready, grants: state.grants })}</pre><ModelTokenClaims /><ModelTokenAllowance /></>;
}
const CLAIM_BUTTON = "Claim 150M tokens";
const tree = () => <ModelTokenPromotionsProvider><Viewer /></ModelTokenPromotionsProvider>;
beforeEach(() => {
  h.auth = { ready: true, authenticated: true, user: { id: "old-user" }, login: vi.fn(), logout: vi.fn(async () => {}), getAccessToken: vi.fn(async () => "privy-token") };
  useStore.setState({ selectedModel: "bonsai", models: [] });
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("explicit model token claims", () => {
  it("only lists offers on login; a click claims the chosen model", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(response()).mockResolvedValueOnce(response([grant], [{ ...offer, status: "claimed", remaining_claims: 249 }]));
    vi.stubGlobal("fetch", fetch);
    render(tree());
    const button = await screen.findByRole("button", { name: CLAIM_BUTTON });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch).toHaveBeenCalledWith("/api/me/token-promotions", expect.objectContaining({ method: "GET" }));
    expect(screen.getByText(/250 of 250 grants left/)).toBeInTheDocument();
    fireEvent.click(button);
    await screen.findByText(/150,000,000 free tokens remaining/);
    expect(fetch).toHaveBeenLastCalledWith("/api/me/token-promotions/claim", expect.objectContaining({ method: "POST", body: '{"model_id":"bonsai"}' }));
    expect(screen.queryByRole("button", { name: CLAIM_BUTTON })).not.toBeInTheDocument();
  });

  it("shows paid fallback for an exhausted, previously claimed grant", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => response([{ ...grant, used_tokens: 150_000_000, remaining_tokens: 0 }], [{ ...offer, status: "claimed" }])));
    render(tree());
    await screen.findByText(/You’ve used all your free tokens/);
    expect(screen.getByRole("link", { name: "Add credits" })).toHaveAttribute("href", "/billing");
  });

  it.each(["sold_out", "ineligible"] as const)("does not let a %s offer be claimed", async (status) => {
    vi.stubGlobal("fetch", vi.fn(async () => response([], [{ ...offer, status, remaining_claims: status === "sold_out" ? 0 : 250 }])));
    render(tree());
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent('"ready":true'));
    expect(screen.queryByRole("button", { name: CLAIM_BUTTON })).not.toBeInTheDocument();
    expect(screen.getByText(status === "sold_out" ? /All 250 grants have been claimed/ : /Your account isn’t eligible/)).toBeInTheDocument();
  });

  it("ignores the old account's delayed grant response after an account switch", async () => {
    let finishOld!: (r: ReturnType<typeof response>) => void;
    const fetch = vi.fn().mockImplementationOnce(() => new Promise((resolve) => { finishOld = resolve; })).mockResolvedValueOnce(response([], []));
    vi.stubGlobal("fetch", fetch);
    const view = render(tree());
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    h.auth = { ...h.auth, user: { id: "new-user" } }; view.rerender(tree());
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    await act(async () => { finishOld(response([grant], [{ ...offer, status: "claimed" }])); });
    expect(screen.getByTestId("state")).toHaveTextContent('"grants":[]');
    expect(screen.queryByText(/150,000,000/)).not.toBeInTheDocument();
  });

  it("shows the server's sold-out response when the last claim loses a race", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(response([], [{ ...offer, remaining_claims: 1 }])).mockResolvedValueOnce({ ok: false, status: 409, json: async () => ({ error: { message: "All grants for this promotion have been claimed." } }) });
    vi.stubGlobal("fetch", fetch); render(tree());
    fireEvent.click(await screen.findByRole("button", { name: CLAIM_BUTTON }));
    await screen.findByRole("alert");
    expect(screen.getByRole("alert")).toHaveTextContent("All grants for this promotion have been claimed.");
    expect(screen.getByTestId("state")).toHaveTextContent('"grants":[]');
  });

  it("confirms a claim even when another model is selected or the claimed model is not registered yet", async () => {
    useStore.setState({ selectedModel: "another-model" });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(response()).mockResolvedValueOnce(response([grant], [{ ...offer, status: "claimed" }])));
    render(tree());
    fireEvent.click(await screen.findByRole("button", { name: CLAIM_BUTTON }));
    await screen.findByText(/Claimed and saved to your account/);
    expect(screen.getByRole("status")).toHaveTextContent("150M free tokens for bonsai");
  });

  it("does not let an older refresh cancel the in-flight claim guard", async () => {
    let finishRefresh!: (r: ReturnType<typeof response>) => void;
    let finishClaim!: (r: ReturnType<typeof response>) => void;
    const fetch = vi.fn().mockResolvedValueOnce(response())
      .mockImplementationOnce(() => new Promise((resolve) => { finishRefresh = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { finishClaim = resolve; }));
    vi.stubGlobal("fetch", fetch); render(tree());
    const button = await screen.findByRole("button", { name: CLAIM_BUTTON });
    fireEvent(window, new Event("focus"));
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    fireEvent.click(button);
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(3));
    await act(async () => { finishRefresh(response()); });
    fireEvent(window, new Event("focus"));
    expect(fetch).toHaveBeenCalledTimes(3);
    await act(async () => { finishClaim(response([grant], [{ ...offer, status: "claimed" }])); });
    await screen.findByText(/150,000,000 free tokens remaining/);
  });
});
