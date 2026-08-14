import { describe, expect, it } from "vitest";
import { modelBrand } from "./model-brand";

describe("modelBrand", () => {
  it("uses the standalone OpenAI icon for GPT-OSS aliases", () => {
    expect(modelBrand("gpt-oss-20b")).toMatchObject({
      maker: "openai",
      logoSrc: "/brand/openai-icon.png",
    });
  });

  it("uses the official Gemma mark for Gemma builds", () => {
    expect(modelBrand("gemma-4-26b-qat-4bit")).toMatchObject({
      maker: "google",
      logoSrc: "/brand/gemma-logo.png",
    });
  });

  it("uses the official Qwen mark for Qwen model IDs", () => {
    expect(modelBrand("qwen3.5-9b")).toMatchObject({
      maker: "qwen",
      makerLabel: "Qwen",
      logoSrc: "/brand/qwen-logo.png",
    });
  });

  it("uses the official Qwen mark when the family identifies Qwen", () => {
    expect(modelBrand("custom-build", "qwen3")).toMatchObject({
      maker: "qwen",
      logoSrc: "/brand/qwen-logo.png",
    });
  });

  it("falls back safely for unknown model families", () => {
    expect(modelBrand("custom-model")).toEqual({ maker: "unknown", makerLabel: "Model" });
  });
});
