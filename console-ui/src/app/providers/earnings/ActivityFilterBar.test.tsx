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
        rangeDays={0}
        onSelectRange={noop}
      />,
    );
    fireEvent.change(screen.getByLabelText("Filter by model"), {
      target: { value: "b/big" },
    });
    expect(onModel).toHaveBeenCalledWith("b/big");
  });

  it("reports time-range selections as numbers", () => {
    const onRange = vi.fn();
    render(
      <ActivityFilterBar
        models={["a/small", "b/big"]}
        selectedModel=""
        onSelectModel={noop}
        rangeDays={0}
        onSelectRange={onRange}
      />,
    );
    fireEvent.change(screen.getByLabelText("Filter by time range"), {
      target: { value: "7" },
    });
    expect(onRange).toHaveBeenCalledWith(7);
  });

  it("hides the model dropdown with at most one model, keeps the range", () => {
    render(
      <ActivityFilterBar
        models={["a/small"]}
        selectedModel=""
        onSelectModel={noop}
        rangeDays={0}
        onSelectRange={noop}
      />,
    );
    expect(screen.queryByLabelText("Filter by model")).toBeNull();
    expect(screen.getByLabelText("Filter by time range")).toBeInTheDocument();
    expect(screen.getByText("Recent activity")).toBeInTheDocument();
  });
});
