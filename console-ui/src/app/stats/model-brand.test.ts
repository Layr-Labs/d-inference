import { describe, expect, it, vi } from "vitest";
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
    expect(modelBrand("qwen3.6-35b-a3b-vl-mtp-mxfp8")).toMatchObject({
      maker: "qwen",
      makerLabel: "Qwen",
      logoSrc: "/brand/qwen-logo.png",
    });
  });

  it("uses the official Qwen mark when the family identifies Qwen", () => {
    expect(modelBrand("custom-build", "Qwen3.6")).toMatchObject({
      maker: "qwen",
      logoSrc: "/brand/qwen-logo.png",
    });
  });

  it("uses the official NVIDIA mark for Nemotron 3.5 Lightning aliases", () => {
    const nemotronAliases = [
      "nvidia-nemotron-3.5-lightning",
      "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
      "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp",
    ];

    for (const modelId of nemotronAliases) {
      expect(modelBrand(modelId)).toMatchObject({
        maker: "nvidia",
        makerLabel: "NVIDIA",
        logoSrc: "/brand/nvidia-logo.svg",
        logoAlt: "NVIDIA logo",
      });
    }

    expect(modelBrand("custom-build", "nemotron_h")).toMatchObject({
      maker: "nvidia",
      logoSrc: "/brand/nvidia-logo.svg",
    });
  });

  it("falls back safely for unknown model families", () => {
    expect(modelBrand("custom-model")).toMatchObject({ maker: "unknown", makerLabel: "Model" });
  });

  // Every build the coordinator catalog served at the time of writing. A model
  // that falls through to "unknown" renders a generic icon and the label
  // "Model", which is easy to ship without noticing — that is exactly how the
  // Qwen builds regressed. Extend this list when the network adds a maker.
  const CATALOG: Array<[id: string, family: string | undefined, maker: string]> = [
    ["gpt-oss-20b", "gpt-oss", "openai"],
    ["gemma-4-26b", "gemma", "google"],
    ["gemma-4-26b-qat-4bit", undefined, "google"],
    ["gemma-4-26b-8bit", undefined, "google"],
    ["qwen3.6-35b-a3b-vl-mtp-mxfp8", "Qwen3.6", "qwen"],
    ["qwen3.5-35b-a3b", "Qwen3.5", "qwen"],
    ["qwen3-vl-30b-a3b-instruct", "Qwen3-VL", "qwen"],
    ["nvidia-nemotron-3.5-lightning", "nemotron_h", "nvidia"],
    ["mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit", "nemotron_h", "nvidia"],
  ];

  it.each(CATALOG)("brands %s (family %s) as %s", (id, family, maker) => {
    expect(modelBrand(id, family)).toMatchObject({ maker });
  });

  it("leaves no catalog model on the generic fallback", () => {
    const unbranded = CATALOG.filter(([id, family]) => modelBrand(id, family).maker === "unknown");
    expect(unbranded).toEqual([]);
  });

  it("gives every branded maker a logo", () => {
    for (const [id, family] of CATALOG) {
      const brand = modelBrand(id, family);
      expect(brand.logoSrc, `${id} has no logo`).toBeTruthy();
      expect(brand.logoAlt, `${id} has no logo alt text`).toBeTruthy();
    }
  });

  it("warns once in dev when a maker has no branding", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    modelBrand("brand-new-maker-9b", "BrandNew");
    modelBrand("brand-new-maker-9b", "BrandNew");
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0][0]).toContain("brand-new-maker-9b");
    warn.mockRestore();
  });
});
