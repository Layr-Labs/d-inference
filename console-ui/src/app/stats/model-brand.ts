export type ModelMaker = "openai" | "google" | "qwen" | "unknown";

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
  if (identity.includes("qwen")) {
    return {
      maker: "qwen",
      makerLabel: "Qwen",
      logoSrc: "/brand/qwen-logo.png",
      logoAlt: "Qwen logo",
    };
  }
  warnUnbranded(modelId, family);
  return { maker: "unknown", makerLabel: "Model" };
}

// Models reach the console straight from the coordinator catalog, so a maker we
// have never seen shows up as the generic "Model" label with no logo and
// nothing else flags it. Qwen sat like that across three builds before anyone
// noticed. Warn once per identity in dev so the next new maker is obvious.
const warned = new Set<string>();

function warnUnbranded(modelId: string, family?: string) {
  if (process.env.NODE_ENV === "production") return;
  const key = `${modelId} ${family ?? ""}`;
  if (warned.has(key)) return;
  warned.add(key);
  console.warn(
    `[model-brand] no brand mapping for "${modelId}"${family ? ` (family "${family}")` : ""} — ` +
      `falling back to the generic "Model" label. Add a branch to modelBrand().`,
  );
}
