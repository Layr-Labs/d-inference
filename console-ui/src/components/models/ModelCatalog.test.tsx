import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStore } from "@/lib/store";
import { ModelCatalog } from "./ModelCatalog";
import { useModelCatalog } from "./useModelCatalog";

const push = vi.fn();
vi.mock("next/navigation", () => ({ useRouter: () => ({ push }) }));
vi.mock("./useModelCatalog", () => ({ useModelCatalog: vi.fn() }));

describe("model discovery flow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useStore.setState({ chats: [], activeChatId: null, selectedModel: "", models: [] });
    vi.mocked(useModelCatalog).mockReturnValue({
      models: [
        { id: "alpha", object: "model", display_name: "Alpha", capabilities: ["tools"] },
        { id: "beta", object: "model", display_name: "Beta", input_modalities: ["image"] },
      ],
      pricing: null,
      loading: false,
      modelsError: false,
      pricingError: false,
      refresh: vi.fn(),
    });
  });
  afterEach(cleanup);

  it("starts a fresh chat with the chosen catalog model and preserves existing conversations", () => {
    const previousChat = useStore.getState().createChat();
    render(<ModelCatalog />);
    fireEvent.click(screen.getByRole("button", { name: "Start a new chat with Beta" }));
    const state = useStore.getState();
    expect(state.selectedModel).toBe("beta");
    expect(state.models).toHaveLength(2);
    expect(state.chats).toHaveLength(2);
    expect(state.activeChatId).not.toBe(previousChat);
    expect(state.chats.some((chat) => chat.id === previousChat)).toBe(true);
    expect(push).toHaveBeenCalledWith("/chat");
  });

  it("lets a user recover from an empty combination of search and capability filters", () => {
    render(<ModelCatalog />);
    fireEvent.change(screen.getByRole("searchbox", { name: "Search models" }), { target: { value: "Alpha" } });
    fireEvent.click(screen.getByRole("button", { name: "Image input" }));
    expect(screen.getByText("No models match your search")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Clear filters" }));
    expect(within(screen.getByRole("list", { name: "Models" })).getAllByRole("listitem")).toHaveLength(2);
    expect(screen.getByRole("searchbox")).toHaveValue("");
    expect(screen.getByRole("button", { name: "All models" })).toHaveAttribute("aria-pressed", "true");
  });
});
