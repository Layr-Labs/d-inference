import Image from "next/image";
import { Layers } from "lucide-react";
import { modelBrand } from "./model-brand";

export function ModelMakerMark({
  modelId,
  family,
  compact = false,
}: {
  modelId: string;
  family?: string;
  compact?: boolean;
}) {
  const brand = modelBrand(modelId, family);
  const tileSize = compact ? "h-9 w-9 rounded-lg" : "h-12 w-12 rounded-xl";
  if (!brand.logoSrc || !brand.logoAlt) {
    return (
      <div className={`flex shrink-0 items-center justify-center border border-accent-brand/20 bg-accent-brand/10 text-accent-brand ${tileSize}`}>
        <Layers size={compact ? 15 : 18} />
      </div>
    );
  }

  let imageClass = compact ? "h-7 w-7 object-contain" : "h-9 w-9 object-contain";
  if (brand.maker === "openai") {
    imageClass = compact ? "h-auto w-7" : "h-auto w-10";
  }
  return (
    <div className={`flex shrink-0 items-center justify-center overflow-hidden border border-border-dim bg-white ${tileSize}`} title={brand.logoAlt}>
      <Image
        src={brand.logoSrc}
        alt={brand.logoAlt}
        width={brand.maker === "openai" ? 84 : 52}
        height={brand.maker === "openai" ? 42 : 47}
        className={imageClass}
        unoptimized={brand.maker === "openai"}
      />
    </div>
  );
}
