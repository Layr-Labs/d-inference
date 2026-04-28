import { describe, it, expect, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ChatInput } from "@/components/ChatInput";

vi.mock("@/lib/store", () => ({
  useStore: () => ({
    selectedModel: "model-a",
    models: [{ id: "model-a", display_name: "Model A" }],
    setSelectedModel: vi.fn(),
  }),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

describe("ChatInput routing selector", () => {
  it("emits cost preference when Lowest cost is selected", () => {
    const onRoutingPreferenceChange = vi.fn();
    render(
      <ChatInput
        onSend={vi.fn()}
        onStop={vi.fn()}
        isStreaming={false}
        routingPreference="performance"
        onRoutingPreferenceChange={onRoutingPreferenceChange}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: /Lowest cost/i }));

    expect(onRoutingPreferenceChange).toHaveBeenCalledWith("cost");
  });
});
