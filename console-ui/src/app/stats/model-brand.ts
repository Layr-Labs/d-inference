export type ModelMaker = "openai" | "google" | "unknown";

export interface ModelBrand {
  maker: ModelMaker;
  makerLabel: string;
  logoSrc?: string;
  logoAlt?: string;
}

export function modelBrand(modelId: string, family?: string): ModelBrand {
  const identity = `${modelId} ${family ?? ""}`.toLowerCase();
  if (identity.includes("gpt-oss") || identity.includes("openai")) {
    return {
      maker: "openai",
      makerLabel: "OpenAI",
      logoSrc: "/brand/openai-icon.png",
      logoAlt: "OpenAI logo",
    };
  }
  if (identity.includes("gemma")) {
    return {
      maker: "google",
      makerLabel: "Google",
      logoSrc: "/brand/gemma-logo.png",
      logoAlt: "Gemma by Google",
    };
  }
  return { maker: "unknown", makerLabel: "Model" };
}
