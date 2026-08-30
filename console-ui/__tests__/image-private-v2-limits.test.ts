import { describe, expect, it } from "vitest";
import {
  MAX_IMAGE_AGGREGATE_BYTES,
  MAX_IMAGE_BYTES,
  dataUrlDecodedBytes,
  validateImageFile,
} from "@/lib/image-upload";

describe("private-v2 image capacity", () => {
  it("keeps raw attachments below the encrypted plaintext ceiling after base64 expansion", () => {
    expect(MAX_IMAGE_BYTES).toBe(8 * 1024 * 1024);
    expect(MAX_IMAGE_AGGREGATE_BYTES).toBe(8 * 1024 * 1024);
    expect(Math.ceil(MAX_IMAGE_AGGREGATE_BYTES * 4 / 3)).toBeLessThan(16 * 1024 * 1024);
  });

  it("counts decoded data-URL bytes and rejects a file above the per-image cap", () => {
    expect(dataUrlDecodedBytes("data:image/png;base64,AQID")).toBe(3);
    expect(validateImageFile({
      type: "image/png",
      size: MAX_IMAGE_BYTES + 1,
    } as File)).toContain("too large");
  });
});
