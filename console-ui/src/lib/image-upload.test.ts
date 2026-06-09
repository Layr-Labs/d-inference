// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import {
  validateImageFile,
  fileToDataURL,
  modelSupportsImages,
  buildApiContent,
  ALLOWED_IMAGE_TYPES,
  MAX_IMAGE_BYTES,
  MAX_IMAGES_PER_MESSAGE,
} from "./image-upload";

function makeFile(type: string, sizeBytes = 8, name = "x"): File {
  const file = new File([new Uint8Array(Math.min(sizeBytes, 1024))], name, { type });
  // Override the derived size so we can test the cap without allocating big buffers.
  Object.defineProperty(file, "size", { value: sizeBytes });
  return file;
}

describe("validateImageFile", () => {
  it("accepts every allowed image type under the size limit", () => {
    for (const type of ALLOWED_IMAGE_TYPES) {
      expect(validateImageFile(makeFile(type, 1024))).toBeNull();
    }
  });

  it("rejects a non-image / disallowed type with a helpful message", () => {
    const err = validateImageFile(makeFile("application/pdf", 1024, "doc.pdf"));
    expect(err).toMatch(/unsupported image type/i);
    expect(err).toContain("application/pdf");
  });

  it("rejects an empty/unknown type", () => {
    expect(validateImageFile(makeFile("", 1024))).toMatch(/unsupported/i);
  });

  it("rejects an image over the size cap", () => {
    const err = validateImageFile(makeFile("image/png", MAX_IMAGE_BYTES + 1));
    expect(err).toMatch(/too large/i);
  });

  it("accepts an image exactly at the cap", () => {
    expect(validateImageFile(makeFile("image/png", MAX_IMAGE_BYTES))).toBeNull();
  });
});

describe("fileToDataURL", () => {
  it("reads a file into a base64 data: URI with the right mime", async () => {
    const file = new File([new Uint8Array([1, 2, 3, 4])], "p.png", { type: "image/png" });
    const url = await fileToDataURL(file);
    expect(url.startsWith("data:image/png;base64,")).toBe(true);
  });
});

describe("modelSupportsImages", () => {
  it("is true when input_modalities includes image", () => {
    expect(modelSupportsImages({ input_modalities: ["text", "image"] })).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(modelSupportsImages({ input_modalities: ["Text", "Image"] })).toBe(true);
  });

  it("is false for text-only models", () => {
    expect(modelSupportsImages({ input_modalities: ["text"] })).toBe(false);
  });

  it("falls back to capabilities (vision/multimodal)", () => {
    expect(modelSupportsImages({ capabilities: ["vision"] })).toBe(true);
    expect(modelSupportsImages({ capabilities: ["multimodal"] })).toBe(true);
    expect(modelSupportsImages({ capabilities: ["tools"] })).toBe(false);
  });

  it("is false for null/undefined or empty model", () => {
    expect(modelSupportsImages(null)).toBe(false);
    expect(modelSupportsImages(undefined)).toBe(false);
    expect(modelSupportsImages({})).toBe(false);
  });

  it("bridges known vision families by id/architecture/family", () => {
    expect(modelSupportsImages({ id: "mlx-community/gemma-4-26b-a4b-it-4bit" })).toBe(true);
    expect(modelSupportsImages({ architecture: "gemma4" })).toBe(true);
    expect(modelSupportsImages({ family: "gemma-4" })).toBe(true);
  });

  it("does not match non-vision models via the bridge", () => {
    expect(modelSupportsImages({ id: "qwen/qwen3-8b" })).toBe(false);
    expect(modelSupportsImages({ id: "openai/gpt-oss-20b", architecture: "gptoss" })).toBe(false);
  });

  it("honors an explicit image modality regardless of family", () => {
    expect(
      modelSupportsImages({ id: "some-future-vlm", input_modalities: ["text", "image"] })
    ).toBe(true);
  });
});

describe("buildApiContent", () => {
  it("returns a plain string for text-only turns (unchanged wire shape)", () => {
    expect(buildApiContent("hello")).toBe("hello");
    expect(buildApiContent("hello", [])).toBe("hello");
  });

  it("returns text-first parts when images are present (OpenAI/OpenRouter shape)", () => {
    const out = buildApiContent("describe this", ["data:image/png;base64,AAA"]);
    expect(out).toEqual([
      { type: "text", text: "describe this" },
      { type: "image_url", image_url: { url: "data:image/png;base64,AAA" } },
    ]);
  });

  it("omits the text part for an image-only message", () => {
    const out = buildApiContent("", ["data:image/jpeg;base64,BBB"]);
    expect(out).toEqual([
      { type: "image_url", image_url: { url: "data:image/jpeg;base64,BBB" } },
    ]);
  });

  it("emits one image_url part per image, in order", () => {
    const out = buildApiContent("x", ["data:1", "data:2", "data:3"]);
    expect(Array.isArray(out)).toBe(true);
    const parts = out as { type: string }[];
    expect(parts).toHaveLength(4); // 1 text + 3 images
    expect(parts.filter((p) => p.type === "image_url")).toHaveLength(3);
  });
});

describe("constants", () => {
  it("caps images per message at a sane number", () => {
    expect(MAX_IMAGES_PER_MESSAGE).toBeGreaterThan(0);
    expect(MAX_IMAGES_PER_MESSAGE).toBeLessThanOrEqual(10);
  });
});
