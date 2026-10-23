# Nemotron Super image formats

> Last updated: 2026-10-23

Reference for the inline image encodings that the unregistered Nemotron Super
image owner decodes, how each becomes RGB8, and how that compares with the
reference loader. The owner, its admission and its HTTP hook are described in
[provider inference](../architecture/inference.md); measurements are in the
[2026-10-15 image ingress report](../reports/2026-10-15-nemotron-super-image-ingress.md).

## Reference pipeline

The reference is transformers 5.7 `load_image` followed by NVIDIA's processor
at model revision `7d4bc747b6bdc2cff64c58d65da0d08dd9caa25c`.

| Step | Reference behaviour | Provider behaviour | Source |
|---|---|---|---|
| Format | `PIL.Image.open` sniffs content; the data-URI media type is not used | Content is sniffed. PNG and JPEG, the model card's input formats, are decoded; every other signature fails with `unsupportedEncoding`. The route admits only the `data:image/png;base64,` and `data:image/jpeg;base64,` labels, and either label carries either format | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperImageDecode.swift` (`NemotronSuperImageDecode`) |
| Orientation | `ImageOps.exif_transpose`: IFD0 Orientation; only when that tag is absent, the first XMP `tiff:Orientation` match. Values 2–8 transpose; other values are ignored | Same rules for `.applyEXIF`, which the image owner uses; `.preserveRaster` ignores both | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperImageOrientation.swift` (`NemotronSuperImageOrientation`) |
| Mode conversion | `Image.convert("RGB")` | The PNG and JPEG tables below | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperPNGRaster.swift` (`NemotronSuperPNGRaster`), `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGRaster.swift` (`NemotronSuperJPEGRaster`) |
| Colour management | None: ICC profiles, `gAMA`, `cHRM` and `sRGB` do not change samples | None. ImageIO samples are read without drawing | as above |
| Frames | Frame 0 | APNG: the IDAT image. MPO: the primary JPEG. Bytes after the primary JPEG's EOI are ignored and never reach ImageIO | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperPNGContainer.swift` (`NemotronSuperPNGContainer`), `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGContainer.swift` (`NemotronSuperJPEGContainer`) |
| Resize and normalization | Float32 `interpolate(bicubic, align_corners=False, antialias=True)`, then `(t / 255 - mean) / std` | SDK `normalizeRGB`, which reproduces CPU PyTorch 2.12.0 rounding and is bitwise equal on the golden fixtures | `libs/mlx-swift-lm/Libraries/MLXVLM/NemotronSuperImagePreprocessing.swift` (`NemotronSuperImagePreprocessing`) |

## PNG

PNG is decoded in-process (zlib inflate, all five filters, Adam7) and matches
Pillow 12.2.0 byte for byte. Pillow's rawmode, then `convert("RGB")`, decides
each sample:

| Colour type | Bit depth | Pillow mode | RGB8 result |
|---|---|---|---|
| 0 gray | 1, 2, 4 | `1`, `L` | Sample scaled by 255, 85 or 17, replicated |
| 0 gray | 8 | `L` | Sample replicated |
| 0 gray | 16 | `I;16` | `min(sample, 255)` replicated: Pillow's `I;16` conversion clips rather than scales |
| 2 RGB | 8, 16 | `RGB` | Samples; 16-bit keeps the most significant byte |
| 3 palette | 1, 2, 4, 8 | `P` | PLTE entry. tRNS is ignored |
| 4 gray + alpha | 8, 16 | `LA`, `RGBA` | Gray (most significant byte) replicated; alpha dropped |
| 6 RGBA | 8, 16 | `RGBA` | RGB (most significant byte); alpha dropped, not composited |

Every chunk CRC is checked. Ancillary chunks other than `eXIf`, XMP text and
the APNG frame chunks do not affect pixels, as in Pillow; compressed text and
ICC chunks are inflated only to apply Pillow's size limits. As hardening, one
image inflates at most 64 such chunks and 16 MiB from them in all
(`maximumCompressedChunks`, `maximumInflatedBytes`), whatever their keyword or
validity; Pillow counts only text it stores. Text and ICC rules are in
`provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperPNGText.swift`
(`NemotronSuperPNGText`).

## JPEG

ImageIO decodes the primary frame after the container check, given only the
bytes through its EOI; its metadata properties are not requested. Its IDCT and
chroma upsampling are not libjpeg-turbo's, so samples differ from Pillow.

| Property | Admitted | Source |
|---|---|---|
| Process | SOF0, SOF1 and SOF2 with 8-bit precision and Huffman coding | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGContainer.swift` (`parseFrame`) |
| 1 component | Gray, replicated | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGRaster.swift` (`decode`) |
| 3 components | YCbCr (JFIF, Adobe transform 1, or no marker without `R`,`G`,`B` component IDs) or RGB (Adobe transform 0 without JFIF). Luma sampling 1x1, 2x1 or 2x2 with 1x1 chroma | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGContainer.swift` (`colorModel`) |
| 4 components | CMYK (Adobe transform 0 or no Adobe marker, 1x1 sampling), read as Adobe-inverted (`CMYK;I`) and converted with Pillow's `cmyk2rgb` | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGRaster.swift` (`decode`) |
| Metadata | EXIF and XMP before the first SOS. Later `Exif` APP1 payloads are appended to the first, as in Pillow 12 | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGContainer.swift` (`parse`) |
| Scans | At most 500. Sequential: every component in exactly one scan with Ss = 0, Se = 63, Ah = Al = 0. Progressive: DC scans have Ss = Se = 0, AC scans one component and 1 ≤ Ss ≤ Se ≤ 63; a coefficient's first scan has Ah = 0 and Al ≤ 13, and each later one Ah = the previous Al and Al = Ah − 1, so no coefficient is decoded more than 14 times | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperJPEGContainer.swift` (`ScanProgression`, `maximumScans`) |

The test-enforced bounds on |ImageIO − Pillow| per RGB8 sample are:

| Chroma | Maximum | Mean | Notes |
|---|---|---|---|
| Gray, CMYK | 2 | 0.1 | No chroma upsampling |
| 4:4:4, RGB | 4 | 0.5 | IDCT rounding only |
| 4:2:2 | 5 | 0.6 | |
| 4:2:0 | 12 | 0.75 | At most 4 away from 16-pixel MCU edges |
| 4:2:0, saturated colour edges | 64 | 0.75 | ImageIO replicates chroma at MCU edges where libjpeg-turbo interpolates |

Source: `provider-swift/Tests/ProviderCoreTests/Inference/Vision/NemotronSuperImageGoldenTests.swift` (`jpegBound`).

## Refused inputs

| Input | Failure |
|---|---|
| GIF, WebP, BMP, TIFF, HEIF or any other signature | `unsupportedEncoding` |
| PNG with an unknown critical chunk (for example `CgBI`), a raw-profile EXIF text chunk without `eXIf`, a text chunk keyed `exif` or `xmp`, two XMP packets, a non-SHORT/LONG Orientation, a non-TIFF or BigTIFF EXIF header, or an APNG whose first frame is smaller than the canvas | `unsupportedEncoding` |
| PNG with a CRC mismatch, invalid IHDR, misplaced PLTE/tRNS, non-consecutive IDAT, data after IEND, an APNG sequence error, a non-zlib `zTXt`/`iCCP` method, or a second `iCCP` (hardening: Pillow reads every copy) | `invalidHeader` |
| PNG whose zlib stream is truncated, longer than the raster or has an Adler-32 mismatch, or with an invalid filter type or palette index | `invalidRaster` |
| JPEG with 12-bit precision, a lossless, hierarchical or arithmetic process, DNL, 2 components, YCCK, JFIF combined with Adobe transform 0, `R`,`G`,`B` component IDs without Adobe transform 0, other sampling, or more than 500 scans (hardening beyond the reference: ImageIO's decode cannot be cancelled) | `unsupportedEncoding` |
| JPEG without a frame or EOI, with a reserved marker, or with scans outside the scan rules above (hardening: libjpeg-turbo decodes some of them with a warning) | `invalidHeader` |
| Any `zTXt`, compressed `iTXt` or `iCCP` chunk that inflates past 1 MiB (Pillow's `MAX_TEXT_CHUNK`), or text totalling more than 64 MiB in decoded characters (`MAX_TEXT_MEMORY`); more than 64 compressed chunks, or more than 16 MiB inflated from them, in one image, unkeyed, corrupt and non-UTF-8 chunks included (hardening: Pillow accepts these) | `sizeLimit` |
| An image whose resize workspace exceeds the SDK's limit (below) | `NemotronSuperImagePreprocessing.Failure.workspaceLimit` |

## Limits and admission

| Limit | Value | Source |
|---|---|---|
| Encoded bytes | `min(MediaIngest.maxMediaDecodedBytes, 64 MiB)`; the owner's whole request body is at most `NemotronSuperServingPolicy.maximumEncodedBodyBytes` (40 MiB), and a larger one is refused as `media_too_large` | `NemotronSuperImageDecode.swift` (`parse`); `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/NemotronSuperLocalImageBinding.swift` (`encodedHeaderQuote`) |
| Declared pixels | `min(MediaIngest.maxImagePixels, 64 Mi)`, each axis at most 131072, JPEG axes at most 65500. Checked from the container before any raster buffer exists | `NemotronSuperImageDecode.swift` (`parse`) |
| Resize workspace | SDK limit of 256 MiB for the oriented source and its grid, checked as each image is planned: before the media reservation and before any raster buffer exists. The largest admitted square is 5751x5751; 5752x5752, 8064x6048 and 8192x8192 are refused | `NemotronSuperImageDecode.swift` (`plan`); `NemotronSuperImagePreprocessing.validateWorkspace` |
| Largest grid | 13312 patches (3328 tokens) per image, for example a 2048x1664 target; a 5751x5751 source resizes to 1856x1824 | `NemotronSuperImagePreprocessing.grid` |
| Decoder quote | `data.count * 2 + pixels * 14` (PNG) or `* 16` (JPEG) `+ height * 128 + 8 MiB`; `normalizationWorkspaceBytes` adds 256 MiB. Images decode one at a time, so the media reservation charges the largest image's `normalizationWorkspaceBytes` once, beside every image's two normalized Float32 copies (24 bytes per grid pixel) and features | `NemotronSuperImageDecode.swift` (`Quote`); `NemotronSuperLocalImageBinding.swift` (`encodedPlan`) |
| Tower working memory | The media reservation adds the pinned composition's derived bound for the request's largest image, 2,095,272,960 bytes at 13312 patches. The global activation reserve is unchanged | `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/NemotronSuperLocalImageBinding.swift` (`towerActivationBytes`); `libs/mlx-swift-lm/Libraries/MLXVLM/Models/NemotronSuperImageActivation.swift` (`pinnedActivationBytes`) |
| Route | The binding admits only `data:image/png;base64,` and `data:image/jpeg;base64,` URIs (`admittedDataURIPrefixes`); the decoder sniffs their content | `NemotronSuperLocalImageBinding.swift` (`parseEncodedBody`) |

## Related

- [Provider inference](../architecture/inference.md)
- [Testing](../developer/test.md)
- [Image ingress measurements, 2026-10-15](../reports/2026-10-15-nemotron-super-image-ingress.md)
