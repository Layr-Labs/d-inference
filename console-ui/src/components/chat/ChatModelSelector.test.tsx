import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AuthState } from "@/components/app-providers/PrivyClientProvider";
import { ModelTokenPromotionsProvider, PROMOTION_USAGE_EVENT, useModelTokenPromotions } from "@/components/app-providers/ModelTokenPromotionsProvider";
import type { ModelTokenGrant, ModelTokenOffer } from "@/lib/api/model-token-promotions";
import { useStore } from "@/lib/store";
import { ChatModelSelector } from "./ChatModelSelector";
import { ModelTokenClaims } from "./ModelTokenClaims";

const auth = vi.hoisted(() => ({ current: null as unknown as AuthState }));
vi.mock("@/components/app-providers/PrivyClientProvider", () => ({ useAuthContext: () => auth.current }));

const BONSAI_ID = "prism-bonsai-2-27b";
const BONSAI_NAME = "PrismML Bonsai 2 27B";
const CHOOSE_MODEL = `Choose model: ${BONSAI_NAME}`;
const CLAIM_TOKENS = "Claim 150M tokens";
const grant: ModelTokenGrant = {
  model_id: BONSAI_ID, total_tokens: 150_000_000, used_tokens: 0,
  reserved_tokens: 0, remaining_tokens: 150_000_000, claimed_at: "2026-09-18T00:00:00Z",
};
const offer: ModelTokenOffer = {
  model_id: BONSAI_ID, tokens: grant.total_tokens, remaining_claims: 250, max_claims: 250,
  signup_cutoff_at: "2026-09-19T07:00:00Z", claim_ends_at: null, status: "available",
};
const response = (grants: ModelTokenGrant[] = [], offers: ModelTokenOffer[] = [offer]) => ({
  ok: true, status: 200, json: async () => ({ grants, offers }),
});
function Preview() {
  const { ready, error } = useModelTokenPromotions();
  let status = ready ? "ready" : "loading";
  if (error) status = "error";
  return <>
    <output data-testid="promotion-state">{status}</output>
    <ChatModelSelector /><ModelTokenClaims />
  </>;
}
const tree = () => <ModelTokenPromotionsProvider><Preview /></ModelTokenPromotionsProvider>;
function openMenu() {
  fireEvent.click(screen.getByRole("button", { name: CHOOSE_MODEL }));
}

beforeEach(() => {
  auth.current = {
    ready: true, authenticated: true, user: { id: "account-a" }, login: vi.fn(),
    logout: vi.fn(async () => {}), getAccessToken: vi.fn(async () => "test-token"),
  };
  useStore.setState({ selectedModel: BONSAI_ID, models: [
    { id: "gemma", object: "model", display_name: "Gemma" },
    { id: BONSAI_ID, object: "model", display_name: BONSAI_NAME },
    { id: "other-bonsai", object: "model", display_name: "Other Bonsai" },
    { id: "qwen", object: "model", display_name: "Qwen" },
  ] });
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("claimed Bonsai Free badge", () => {
  it("keeps Bonsai first but waits for a successful claim before showing Free", async () => {
    let finishClaim!: (value: ReturnType<typeof response>) => void;
    const fetch = vi.fn().mockResolvedValueOnce(response())
      .mockImplementationOnce(() => new Promise((resolve) => { finishClaim = resolve; }));
    vi.stubGlobal("fetch", fetch);
    render(tree());
    const claimButton = await screen.findByRole("button", { name: CLAIM_TOKENS });
    openMenu();
    const options = within(screen.getByRole("dialog")).getAllByRole("button");
    expect(options.map((button) => button.textContent)).toEqual([
      `${BONSAI_NAME}Text`, "Other BonsaiText", "GemmaText", "QwenText",
    ]);
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
    fireEvent.click(claimButton);
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
    await act(async () => { finishClaim(response([grant], [{ ...offer, status: "claimed" }])); });
    expect(screen.getAllByText("Free", { exact: true })).toHaveLength(1);
    expect(screen.getByRole("button", { name: `${BONSAI_NAME} Free Text` })).toBeInTheDocument();
    expect(fetch).toHaveBeenLastCalledWith("/api/me/token-promotions/claim", expect.objectContaining({
      method: "POST", body: JSON.stringify({ model_id: BONSAI_ID }),
    }));
  });

  it.each([
    ["unclaimed offer", []],
    ["exhausted grant", [{ ...grant, used_tokens: grant.total_tokens, remaining_tokens: 0 }]],
    ["fully reserved grant", [{ ...grant, reserved_tokens: grant.total_tokens, remaining_tokens: 0 }]],
    ["different model grant", [{ ...grant, model_id: `${BONSAI_ID}-other-build` }]],
    ["unconfirmed grant", [{ ...grant, claimed_at: "" }]],
  ] satisfies [string, ModelTokenGrant[]][])("hides Free for an %s", async (_, grants) => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(response(grants)));
    render(tree());
    await waitFor(() => expect(screen.getByTestId("promotion-state")).toHaveTextContent("ready"));
    openMenu();
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
  });

  it("hides Free while loading and after a failed claim", async () => {
    let finishLoad!: (value: ReturnType<typeof response>) => void;
    vi.stubGlobal("fetch", vi.fn()
      .mockImplementationOnce(() => new Promise((resolve) => { finishLoad = resolve; }))
      .mockRejectedValueOnce(new Error("Claim failed")));
    render(tree());
    openMenu();
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
    await waitFor(() => expect(finishLoad).toBeDefined());
    await act(async () => { finishLoad(response()); });
    fireEvent.click(screen.getByRole("button", { name: CLAIM_TOKENS }));
    await waitFor(() => expect(screen.getByTestId("promotion-state")).toHaveTextContent("error"));
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
  });

  it.each(["account switch", "logout"])("removes the old account's badge immediately on %s", async (action) => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(response([grant]))
      .mockImplementation(() => new Promise(() => {})));
    const view = render(tree());
    openMenu();
    await screen.findByText("Free", { exact: true });
    auth.current = { ...auth.current, authenticated: action !== "logout", user: { id: "account-b" } };
    view.rerender(tree());
    expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument();
  });

  it.each(["exhausted", "lookup error"])("removes a previously shown badge when refreshed state is %s", async (status) => {
    const fetch = vi.fn().mockResolvedValueOnce(response([grant]));
    if (status === "exhausted") fetch.mockResolvedValueOnce(response([{ ...grant, used_tokens: grant.total_tokens, remaining_tokens: 0 }]));
    else fetch.mockRejectedValueOnce(new Error("Lookup failed"));
    vi.stubGlobal("fetch", fetch);
    render(tree());
    openMenu();
    await screen.findByText("Free", { exact: true });
    fireEvent(window, new Event(PROMOTION_USAGE_EVENT));
    await waitFor(() => expect(screen.queryByText("Free", { exact: true })).not.toBeInTheDocument());
  });
});
