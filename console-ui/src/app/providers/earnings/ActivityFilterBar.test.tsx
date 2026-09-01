// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ActivityFilterBar } from "./ActivityFilterBar";

const noop = () => {};

describe("ActivityFilterBar", () => {
  it("reports model selections", () => {
    const onModel = vi.fn();
    render(
      <ActivityFilterBar
        models={["a/small", "b/big"]}
        selectedModel=""
        onSelectModel={onModel}
      />,
    );
    fireEvent.change(screen.getByLabelText("Filter by model"), {
      target: { value: "b/big" },
    });
    expect(onModel).toHaveBeenCalledWith("b/big");
  });

  it("hides the model dropdown with at most one model", () => {
    render(
      <ActivityFilterBar
        models={["a/small"]}
        selectedModel=""
        onSelectModel={noop}
      />,
    );
    expect(screen.queryByLabelText("Filter by model")).toBeNull();
    expect(screen.getByText("Recent activity")).toBeInTheDocument();
  });
});
