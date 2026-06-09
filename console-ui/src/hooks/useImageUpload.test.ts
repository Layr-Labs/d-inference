// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { renderHook, act, waitFor } from "@testing-library/react";
import { useImageUpload } from "./useImageUpload";
import { MAX_IMAGES_PER_MESSAGE } from "@/lib/image-upload";

// Avoid touching the analytics global (gtag) during tests.
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

function pngFile(name = "a.png"): File {
  return new File([new Uint8Array([1, 2, 3])], name, { type: "image/png" });
}

describe("useImageUpload", () => {
  it("stages valid images via addFiles", async () => {
    const { result } = renderHook(() => useImageUpload(true));
    await act(async () => {
      await result.current.addFiles([pngFile(), pngFile("b.png")]);
    });
    expect(result.current.images).toHaveLength(2);
    expect(result.current.imgError).toBeNull();
  });

  it("rejects an invalid type with an error and stages nothing", async () => {
    const { result } = renderHook(() => useImageUpload(true));
    const bad = new File([new Uint8Array([1])], "x.pdf", { type: "application/pdf" });
    await act(async () => {
      await result.current.addFiles([bad]);
    });
    expect(result.current.images).toHaveLength(0);
    expect(result.current.imgError).toMatch(/unsupported/i);
  });

  it("enforces the per-message cap", async () => {
    const { result } = renderHook(() => useImageUpload(true));
    const many = Array.from({ length: MAX_IMAGES_PER_MESSAGE + 2 }, (_, i) =>
      pngFile(`f${i}.png`)
    );
    await act(async () => {
      await result.current.addFiles(many);
    });
    expect(result.current.images).toHaveLength(MAX_IMAGES_PER_MESSAGE);
    expect(result.current.atLimit).toBe(true);
    expect(result.current.imgError).toMatch(/up to/i);
  });

  it("removes and clears staged images", async () => {
    const { result } = renderHook(() => useImageUpload(true));
    await act(async () => {
      await result.current.addFiles([pngFile(), pngFile("b.png")]);
    });
    act(() => result.current.removeImage(0));
    expect(result.current.images).toHaveLength(1);
    act(() => result.current.clearImages());
    expect(result.current.images).toHaveLength(0);
    expect(result.current.imgError).toBeNull();
  });

  it("ignores intake and clears staged images when disabled", async () => {
    const { result, rerender } = renderHook(({ on }) => useImageUpload(on), {
      initialProps: { on: true },
    });
    await act(async () => {
      await result.current.addFiles([pngFile()]);
    });
    expect(result.current.images).toHaveLength(1);

    rerender({ on: false });
    await waitFor(() => expect(result.current.images).toHaveLength(0));

    // Further intake is a no-op while disabled.
    await act(async () => {
      await result.current.addFiles([pngFile()]);
    });
    expect(result.current.images).toHaveLength(0);
  });
});
