// Image-upload helpers for the chat composer (Gemma 4-style vision input).
//
// Our endpoint matches the OpenAI/OpenRouter `image_url` wire format, with one
// constraint: the image must be an inline base64 `data:` URI (the provider is
// end-to-end-encrypted and rejects remote URLs). So the browser reads the file,
// validates it, and base64-encodes it client-side before it enters the
// (sender→coordinator sealed) request body.

import type { ChatContentPart, Model } from "./api";

/** Content types the Gemma 4 vision tower / Core Image decode accepts. */
export const ALLOWED_IMAGE_TYPES = [
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
] as const;

/** Max size per image. base64 inflates ~33%, and the whole request is sealed
 *  and sent inside the encrypted prompt, so keep this conservative. */
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024; // 10 MB

/** Max images attached to a single message. */
export const MAX_IMAGES_PER_MESSAGE = 4;

function mb(bytes: number): string {
  return (bytes / (1024 * 1024)).toFixed(1);
}

/**
 * Validate a picked/pasted file. Returns a human-readable error string, or
 * `null` if the file is acceptable.
 */
export function validateImageFile(file: File): string | null {
  if (!(ALLOWED_IMAGE_TYPES as readonly string[]).includes(file.type)) {
    return `Unsupported image type "${file.type || "unknown"}". Use PNG, JPEG, WebP, or GIF.`;
  }
  if (file.size > MAX_IMAGE_BYTES) {
    return `Image is too large (${mb(file.size)} MB). Max ${mb(MAX_IMAGE_BYTES)} MB.`;
  }
  return null;
}

/** Read a File into a base64 `data:` URI (e.g. `data:image/png;base64,...`). */
export function fileToDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () =>
      reject(reader.error ?? new Error("Failed to read image file"));
    reader.onload = () => {
      const result = reader.result;
      if (typeof result === "string") {
        resolve(result);
      } else {
        reject(new Error("Unexpected file read result (not a data URL)"));
      }
    };
    reader.readAsDataURL(file);
  });
}

/**
 * Whether a model accepts image input — used to gate the upload control so we
 * only offer it for vision models. Driven SOLELY by catalog metadata: the
 * OpenRouter-style `input_modalities` (the coordinator's `deriveModalities` adds
 * "image" once an operator sets the model's vision capability) or an explicit
 * `vision`/`image`/`multimodal` capability.
 *
 * The old `/gemma-?4/i` family bridge was removed deliberately: it lit the upload
 * button the moment the console deployed, regardless of whether the serving fleet
 * could actually do vision. Gating on catalog modality makes the operator's
 * capability flip — done last, after the fleet is on 0.6.0 — the single switch
 * that turns image input on, matching the coordinator's vision routing gate.
 */
export function modelSupportsImages(
  model?: Partial<
    Pick<Model, "input_modalities" | "capabilities" | "id" | "architecture" | "family">
  > | null
): boolean {
  if (!model) return false;
  const modalities = model.input_modalities?.map((m) => m.toLowerCase()) ?? [];
  if (modalities.includes("image")) return true;
  const caps = model.capabilities?.map((c) => c.toLowerCase()) ?? [];
  return caps.some((c) => c === "vision" || c === "image" || c === "multimodal");
}

/**
 * Build an OpenAI/OpenRouter-compatible message `content` from text + images.
 * Text-only turns stay a plain string (unchanged wire shape). When images are
 * present, returns a parts array with the text FIRST (OpenRouter recommends
 * text-before-images), followed by one `image_url` part per data: URI.
 */
export function buildApiContent(
  text: string,
  images?: string[]
): string | ChatContentPart[] {
  if (!images || images.length === 0) {
    return text;
  }
  const parts: ChatContentPart[] = [];
  if (text) {
    parts.push({ type: "text", text });
  }
  for (const url of images) {
    parts.push({ type: "image_url", image_url: { url } });
  }
  return parts;
}
