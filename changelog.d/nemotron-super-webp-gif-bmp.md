### Nemotron Super takes WebP, GIF and BMP images, under any image label

- Nemotron 3.5 Super now decodes WebP, GIF (the first frame) and BMP images as well as PNG and JPEG. The coordinator already fetched and inlined these formats; every Super Mac refused them.
- ImageIO decodes them to the same RGB input as PNG and JPEG, under the same byte, pixel and resize limits, checked from the header before any pixel is decoded. A WebP's EXIF orientation is applied as for PNG and JPEG. Alpha is dropped; a fully transparent pixel reads as black.
- Other formats (TIFF, HEIC and the rest) are still refused, now as `unsupported_media`.
- An inline image is taken under any image label, in any case: the format comes from the bytes, so a JPEG sent as `data:image/jpg` (an alias some clients send) or `data:image/JPEG` is served. Before, only `data:image/png` and `data:image/jpeg` were taken, and every other label was refused as `invalid_media` (400). A label that is not an image, percent encoding or a remote URL is refused as `unsupported_media`.
