### Nemotron Super takes WebP, GIF and BMP images

- Nemotron 3.5 Super now decodes WebP, GIF (the first frame) and BMP images as well as PNG and JPEG, under the `data:image/webp`, `data:image/gif` and `data:image/bmp` labels. The coordinator already fetched and inlined these formats; every Super Mac refused them.
- ImageIO decodes them to the same RGB input as PNG and JPEG, under the same byte, pixel and resize limits, checked from the header before any pixel is decoded. A WebP's EXIF orientation is applied as for PNG and JPEG. Alpha is dropped; a fully transparent pixel reads as black.
- Other formats (TIFF, HEIC and the rest) are still refused, now as `unsupported_media`.
