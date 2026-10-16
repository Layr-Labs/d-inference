"""Nemotron Super image goldens, stage 1: fixtures and Pillow RGB8 references.

Writes small synthetic PNG/JPEG fixtures plus `reference.json` into the
provider test fixture directory, and the reference RGB8 rasters into a
scratch directory for stage 2 (`generate_tensors.py`). Run with the pinned
venv (Pillow 12.2.0, numpy 2.3.5) in isolated mode:

    python -I generate_fixtures.py --out <fixtures> --rasters <scratch>

The RGB8 reference is transformers 5.7 `image_utils.load_image`: Pillow
`ImageOps.exif_transpose` followed by `convert("RGB")`, then NVIDIA's
`np.asarray(img, dtype=np.uint8)`. PNG fixtures use a local encoder so every
filter type, Adam7, split IDAT and chunk layout is exercised; Pillow decodes
them independently.
"""

import argparse
import hashlib
import io
import json
import struct
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageOps, __version__ as pillow_version, features

ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def pack_rows(samples: np.ndarray, depth: int) -> np.ndarray:
    """HxWxC unsigned samples -> HxN packed big-endian row bytes."""
    h, w, c = samples.shape
    if depth == 16:
        return samples.astype(">u2").reshape(h, w * c).view(np.uint8)
    if depth == 8:
        return samples.astype(np.uint8).reshape(h, w * c)
    per = 8 // depth
    padded = np.zeros((h, -(-w // per) * per), np.uint16)
    padded[:, :w] = samples[:, :, 0]
    groups = padded.reshape(h, -1, per)
    shifts = np.array([8 - depth * (i + 1) for i in range(per)], np.uint16)
    return (groups << shifts).sum(axis=2).astype(np.uint8)


def filter_rows(rows: np.ndarray, bpp: int, counter: list[int], fixed: int | None) -> bytes:
    out = bytearray()
    previous = np.zeros(rows.shape[1], np.int32)
    for raw in rows.astype(np.int32):
        kind = fixed if fixed is not None else counter[0] % 5
        counter[0] += 1
        left = np.concatenate([np.zeros(bpp, np.int32), raw[:-bpp]])[: raw.size]
        upper_left = np.concatenate([np.zeros(bpp, np.int32), previous[:-bpp]])[: raw.size]
        if kind == 0:
            predicted = np.zeros_like(raw)
        elif kind == 1:
            predicted = left
        elif kind == 2:
            predicted = previous
        elif kind == 3:
            predicted = (left + previous) >> 1
        else:
            p = left + previous - upper_left
            pa, pb, pc = abs(p - left), abs(p - previous), abs(p - upper_left)
            predicted = np.where((pa <= pb) & (pa <= pc), left, np.where(pb <= pc, previous, upper_left))
        out.append(kind)
        out += ((raw - predicted) & 255).astype(np.uint8).tobytes()
        previous = raw
    return bytes(out)


def image_stream(samples: np.ndarray, color_type: int, depth: int, interlace: bool, fixed_filter=None) -> bytes:
    bpp = max(1, CHANNELS[color_type] * depth // 8)
    counter = [0]
    if not interlace:
        return filter_rows(pack_rows(samples, depth), bpp, counter, fixed_filter)
    stream = b""
    for x0, y0, dx, dy in ADAM7:
        sub = samples[y0::dy, x0::dx]
        if sub.shape[0] and sub.shape[1]:
            stream += filter_rows(pack_rows(sub, depth), bpp, counter, fixed_filter)
    return stream


def encode_png(samples, color_type, depth, *, interlace=False, plte=None, trns=None, before=(), after=(),
               split=None, empty_idat=False, fixed_filter=None, compressed=None, ihdr_size=None) -> bytes:
    h, w = samples.shape[:2]
    width, height = ihdr_size or (w, h)
    data = compressed if compressed is not None else zlib.compress(
        image_stream(samples, color_type, depth, interlace, fixed_filter), 9)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0,
                                                              int(interlace)))
    for kind, body in before:
        out += chunk(kind, body)
    if plte is not None:
        out += chunk(b"PLTE", bytes(plte))
    if trns is not None:
        out += chunk(b"tRNS", bytes(trns))
    pieces = [data[i:i + split] for i in range(0, len(data), split)] if split else [data]
    if empty_idat:
        pieces.insert(1, b"")
    for piece in pieces:
        out += chunk(b"IDAT", piece)
    for kind, body in after:
        out += chunk(kind, body)
    return out + chunk(b"IEND", b"")


def tiff(entries, endian="<") -> bytes:
    """Minimal TIFF header + IFD0. entries: (tag, type, count, payload bytes)."""
    head = (b"II*\x00" if endian == "<" else b"MM\x00*") + struct.pack(endian + "I", 8)
    base = 8 + 2 + 12 * len(entries) + 4
    ifd, tail = struct.pack(endian + "H", len(entries)), b""
    for tag, kind, count, payload in entries:
        if len(payload) <= 4:
            field = payload.ljust(4, b"\0")
        else:
            field = struct.pack(endian + "I", base + len(tail))
            tail += payload
        ifd += struct.pack(endian + "HHI", tag, kind, count) + field
    return head + ifd + struct.pack(endian + "I", 0) + tail


def orientation_exif(value, endian="<", kind=3, extra=True) -> bytes:
    entries = [(0x010F, 2, 8, b"Fixture\0")] if extra else []
    payload = struct.pack(endian + ("H" if kind == 3 else "I"), value)
    return tiff(entries + [(0x0112, kind, 1, payload)], endian)


def xmp_packet(orientation, element=False) -> bytes:
    field = (f"<tiff:Orientation>{orientation}</tiff:Orientation>" if element
             else f'tiff:Orientation="{orientation}"')
    if element:
        body = f'<rdf:Description rdf:about="">{field}</rdf:Description>'
    else:
        body = f'<rdf:Description rdf:about="" {field}/>'
    return ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
            'xmlns:tiff="http://ns.adobe.com/tiff/1.0/">' + body + "</rdf:RDF></x:xmpmeta>").encode()


def itxt(keyword: bytes, text: bytes, compressed=False) -> tuple[bytes, bytes]:
    payload = zlib.compress(text) if compressed else text
    return b"iTXt", keyword + b"\0" + bytes([int(compressed), 0]) + b"en\0\0" + payload


def stable_profile(kind: str) -> bytearray:
    """LittleCMS profile without its creation time or profile ID, for reproducible fixtures."""
    profile = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile(kind)).tobytes())
    profile[24:36] = bytes(12)
    profile[84:100] = bytes(16)
    return profile


def custom_rgb_profile() -> bytes:
    """sRGB with a shifted red primary, so a colour-managed decode would differ."""
    profile = stable_profile("sRGB")
    count = struct.unpack(">I", profile[128:132])[0]
    for index in range(count):
        signature, offset, _ = struct.unpack(">4sII", profile[132 + 12 * index:144 + 12 * index])
        if signature == b"rXYZ":
            profile[offset + 8:offset + 12] = struct.pack(">i", int(0.30 * 65536))
    return bytes(profile)


def rng(seed):
    return np.random.default_rng(seed)


def noise(h, w, c, high, seed):
    return rng(seed).integers(0, high + 1, (h, w, c), dtype=np.uint32).astype(np.uint16)


def photo(h, w, seed=0) -> np.ndarray:
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    r = 128 + 70 * np.sin(x / 11 + y / 29) + 30 * np.exp(-((x - w * 0.3) ** 2 + (y - h * 0.6) ** 2) / 300)
    g = 120 + 60 * np.cos(x / 17 - y / 13)
    b = 110 + 50 * np.sin((x + 2 * y) / 21) + 40 * np.exp(-((x - w * 0.7) ** 2 + (y - h * 0.3) ** 2) / 500)
    image = np.stack([r, g, b], -1) + rng(seed).normal(0, 2, (h, w, 3))
    return np.clip(np.round(image), 0, 255).astype(np.uint8)


def hard_edges(h, w) -> np.ndarray:
    image = np.full((h, w, 3), 245, np.uint8)
    colours = [(255, 0, 0), (0, 0, 255), (0, 200, 0), (255, 220, 0), (200, 0, 200)]
    for i, colour in enumerate(colours):
        y0, x0 = 5 + i * 17, 3 + i * 23
        image[y0:y0 + 19, x0:x0 + 29] = colour
    image[40:43, :] = (0, 0, 0)
    image[:, 61:63] = (255, 0, 0)
    return image


class Builder:
    def __init__(self, out: Path, rasters: Path):
        self.out, self.rasters, self.cases = out, rasters, []

    def add(self, name, data: bytes, fmt: str, note: str, chroma: str | None = None):
        path = self.out / f"{name}.{fmt}"
        path.write_bytes(data)
        oriented = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")
        reference = np.asarray(oriented, dtype=np.uint8)
        raw = Image.open(io.BytesIO(data))
        raw.load()
        unoriented = np.asarray(raw.convert("RGB"), dtype=np.uint8)
        case = {
            "name": name, "file": path.name, "format": fmt, "note": note,
            "width": int(reference.shape[1]), "height": int(reference.shape[0]),
            "rgb_sha256": hashlib.sha256(reference.tobytes()).hexdigest(),
            "unoriented_width": int(unoriented.shape[1]), "unoriented_height": int(unoriented.shape[0]),
            "unoriented_rgb_sha256": hashlib.sha256(unoriented.tobytes()).hexdigest(),
            "bytes": len(data),
        }
        if fmt == "jpeg":
            # Lossy references are stored raw-deflated for per-pixel error statistics.
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            pillow = compressor.compress(reference.tobytes()) + compressor.flush()
            (self.out / f"{name}.pillow-rgb.deflate").write_bytes(pillow)
            case["pillow_rgb"] = f"{name}.pillow-rgb.deflate"
            # Encoder facts the provider test uses to select its error bound.
            case["chroma"] = chroma
        (self.rasters / f"{name}.rgb").write_bytes(reference.tobytes())
        self.cases.append(case)


def jpeg(image: np.ndarray, mode="RGB", **options) -> bytes:
    buffer = io.BytesIO()
    picture = Image.fromarray(image, "RGB")
    if mode != "RGB":
        picture = picture.convert(mode)
    picture.save(buffer, "JPEG", **options)
    return buffer.getvalue()


def segments(data: bytes):
    """(marker, start, end) of each JPEG segment before the first SOS."""
    position, found = 2, []
    while True:
        marker = data[position + 1]
        length = (data[position + 2] << 8) | data[position + 3]
        found.append((marker, position, position + 2 + length))
        if marker == 0xDA:
            return found
        position += 2 + length


def without_marker(data: bytes, marker: int) -> bytes:
    found = segments(data)
    kept = b"".join(data[s:e] for m, s, e in found if m != marker)
    return data[:2] + kept + data[found[-1][2]:]


def with_segment(data: bytes, segment: bytes) -> bytes:
    return data[:2] + segment + data[2:]


def edit_frame(data: bytes, edit) -> bytes:
    out = bytearray(data)
    for marker, start, end in segments(data):
        if marker in (0xC0, 0xC1, 0xC2):
            edit(out, start)
    return bytes(out)


def build(builder: Builder):
    add = builder.add
    # PNG colour types and bit depths (Pillow rawmode + convert("RGB") semantics).
    add("png-rgb8", encode_png(noise(23, 37, 3, 255, 1), 2, 8), "png", "RGB 8-bit, all five filters")
    add("png-rgb16", encode_png(noise(13, 19, 3, 65535, 2), 2, 16), "png", "RGB 16-bit keeps the high byte")
    rgba = noise(17, 21, 4, 255, 3)
    rgba[::3, ::2, 3] = 0
    add("png-rgba8", encode_png(rgba, 6, 8), "png", "RGBA 8-bit drops alpha, hidden RGB kept")
    add("png-rgba16", encode_png(noise(11, 13, 4, 65535, 4), 6, 16), "png", "RGBA 16-bit")
    for depth, (h, w) in {1: (7, 29), 2: (9, 31), 4: (5, 27), 8: (9, 33)}.items():
        add(f"png-gray{depth}", encode_png(noise(h, w, 1, (1 << depth) - 1, 10 + depth), 0, depth), "png",
            f"gray {depth}-bit")
    gray16 = noise(9, 17, 1, 65535, 20)
    gray16[::2] = noise(5, 17, 1, 255, 21)
    add("png-gray16", encode_png(gray16, 0, 16), "png", "gray 16-bit opens as I;16; RGB clips at 255")
    add("png-graya8", encode_png(noise(11, 23, 2, 255, 22), 4, 8), "png", "gray+alpha 8-bit")
    add("png-graya16", encode_png(noise(7, 15, 2, 65535, 23), 4, 16), "png", "gray+alpha 16-bit high byte")
    for depth, (h, w) in {1: (6, 30), 2: (6, 30), 4: (7, 31), 8: (12, 40)}.items():
        entries = min(1 << depth, 200)
        palette = noise(1, entries, 3, 255, 30 + depth).astype(np.uint8).tobytes()
        indices = noise(h, w, 1, entries - 1, 40 + depth)
        add(f"png-palette{depth}", encode_png(indices, 3, depth, plte=palette), "png", f"palette {depth}-bit")
    palette = noise(1, 10, 3, 255, 50).astype(np.uint8).tobytes()
    add("png-palette8-trns", encode_png(noise(9, 14, 1, 9, 51), 3, 8, plte=palette, trns=[0, 128, 255, 7]),
        "png", "palette with tRNS alpha is ignored")
    add("png-palette4-short", encode_png(noise(8, 11, 1, 9, 52), 3, 4, plte=palette), "png",
        "4-bit palette with 10 entries")
    add("png-gray8-trns", encode_png(noise(5, 9, 1, 255, 53), 0, 8, trns=[0, 17]), "png", "gray tRNS ignored")
    add("png-rgb8-trns", encode_png(noise(5, 9, 3, 255, 54), 2, 8, trns=[0, 1, 0, 2, 0, 3]), "png",
        "RGB tRNS ignored")
    # Adam7, including images whose early passes are empty.
    add("png-rgb8-adam7", encode_png(noise(11, 13, 3, 255, 60), 2, 8, interlace=True), "png", "Adam7 RGB")
    add("png-gray1-adam7", encode_png(noise(9, 9, 1, 1, 61), 0, 1, interlace=True), "png", "Adam7 1-bit")
    add("png-palette4-adam7", encode_png(noise(7, 10, 1, 15, 62), 3, 4, interlace=True,
                                         plte=noise(1, 16, 3, 255, 63).astype(np.uint8).tobytes()), "png",
        "Adam7 palette")
    add("png-rgba16-adam7", encode_png(noise(5, 7, 4, 65535, 64), 6, 16, interlace=True), "png",
        "Adam7 RGBA 16-bit")
    add("png-rgb8-adam7-1x1", encode_png(noise(1, 1, 3, 255, 65), 2, 8, interlace=True), "png", "Adam7 1x1")
    add("png-rgb8-adam7-3x2", encode_png(noise(2, 3, 3, 255, 66), 2, 8, interlace=True), "png",
        "Adam7 with empty passes")
    # Container layout: split and empty IDAT, ignored ancillary/colour-management chunks.
    icc = bytes(stable_profile("sRGB"))
    ancillary = [(b"gAMA", struct.pack(">I", 45455)), (b"cHRM", bytes(32)), (b"sRGB", b"\0"),
                 (b"iCCP", b"fixture\0\0" + zlib.compress(icc)), (b"pHYs", bytes(9)),
                 (b"tEXt", b"Comment\0fixture"), (b"zTXt", b"Title\0\0" + zlib.compress(b"fixture")),
                 itxt(b"Description", b"fixture", compressed=True), (b"prVt", b"private")]
    add("png-rgb8-chunks", encode_png(noise(9, 12, 3, 255, 70), 2, 8, before=ancillary, split=7,
                                      empty_idat=True, after=[(b"tIME", bytes(7)), (b"tEXt", b"Late\0text")]),
        "png", "split/empty IDAT and ignored ancillary chunks")
    # EXIF orientation (eXIf) on a non-square image, both byte orders.
    base = noise(3, 5, 3, 255, 80)
    for value in range(1, 9):
        add(f"png-exif{value}", encode_png(base, 2, 8, before=[(b"eXIf", orientation_exif(value))]), "png",
            f"eXIf orientation {value}")
    add("png-exif6-be", encode_png(base, 2, 8, before=[(b"eXIf", orientation_exif(6, ">"))]), "png",
        "big-endian eXIf orientation 6")
    add("png-exif6-long", encode_png(base, 2, 8, before=[(b"eXIf", orientation_exif(6, kind=4))]), "png",
        "LONG orientation field")
    add("png-exif9", encode_png(base, 2, 8, before=[(b"eXIf", orientation_exif(9))]), "png",
        "out-of-range orientation is ignored")
    add("png-exif8-after-idat", encode_png(base, 2, 8, after=[(b"eXIf", orientation_exif(8))]), "png",
        "eXIf after IDAT is read at load")
    add("png-exif5-prefixed", encode_png(base, 2, 8, before=[(b"eXIf", b"Exif\0\0" + orientation_exif(5))]),
        "png", "Exif header inside eXIf is stripped")
    truncated = orientation_exif(7, extra=False)
    truncated = truncated[:8] + struct.pack("<H", 4) + truncated[10:22]
    add("png-exif7-truncated-ifd", encode_png(base, 2, 8, before=[(b"eXIf", truncated)]), "png",
        "truncated IFD keeps entries read before truncation")
    # XMP orientation fallback (only when the EXIF Orientation tag is absent).
    add("png-xmp6-itxt", encode_png(base, 2, 8, before=[itxt(b"XML:com.adobe.xmp", xmp_packet(6))]), "png",
        "iTXt XMP attribute orientation")
    add("png-xmp3-itxt-compressed", encode_png(base, 2, 8, before=[
        itxt(b"XML:com.adobe.xmp", xmp_packet(3, element=True), compressed=True)]), "png",
        "compressed iTXt XMP element orientation")
    add("png-xmp5-text", encode_png(base, 2, 8, before=[(b"tEXt", b"XML:com.adobe.xmp\0" + xmp_packet(5))]),
        "png", "tEXt XMP orientation")
    add("png-xmp7-ztxt", encode_png(base, 2, 8, before=[
        (b"zTXt", b"XML:com.adobe.xmp\0\0" + zlib.compress(xmp_packet(7)))]), "png", "zTXt XMP orientation")
    add("png-exif1-xmp6", encode_png(base, 2, 8, before=[
        (b"eXIf", orientation_exif(1)), itxt(b"XML:com.adobe.xmp", xmp_packet(6))]), "png",
        "EXIF orientation 1 overrides XMP")
    no_orientation = tiff([(0x010F, 2, 8, b"Fixture\0")])
    add("png-exif-none-xmp8", encode_png(base, 2, 8, before=[
        (b"eXIf", no_orientation), itxt(b"XML:com.adobe.xmp", xmp_packet(8))]), "png",
        "EXIF without Orientation falls back to XMP")
    # APNG: Pillow's frame 0 is the IDAT image in both layouts.
    first, second = noise(4, 6, 3, 255, 90), noise(4, 6, 3, 255, 91)
    second_stream = zlib.compress(image_stream(second, 2, 8, False), 9)
    def fctl(sequence):
        return b"fcTL", struct.pack(">IIIIIHHBB", sequence, 6, 4, 0, 0, 1, 10, 0, 0)
    add("png-apng", encode_png(first, 2, 8, before=[(b"acTL", struct.pack(">II", 2, 0)), fctl(0)],
                               after=[fctl(1), (b"fdAT", struct.pack(">I", 2) + second_stream)]), "png",
        "APNG first frame from IDAT")
    add("png-apng-default-image", encode_png(first, 2, 8, before=[(b"acTL", struct.pack(">II", 1, 0))],
                                             after=[fctl(0), (b"fdAT", struct.pack(">I", 1) + second_stream)]),
        "png", "APNG default image is frame 0")
    # Resize coverage: 1x1 upscale and a downscale beyond 13312 patches.
    add("png-rgb8-1x1", encode_png(noise(1, 1, 3, 255, 100), 2, 8), "png", "1x1 upscales to the minimum grid")
    y, x = np.mgrid[0:1440, 0:2560]
    gradient = np.stack([x % 256, (y // 6) % 256, ((x + y) // 10) % 256], -1).astype(np.uint16)
    add("png-rgb8-2560x1440", encode_png(gradient, 2, 8, fixed_filter=1), "png", "downscale path")

    # JPEG (ImageIO-decoded on the provider; compared with Pillow by error bounds).
    smooth, edges = photo(48, 64), hard_edges(96, 128)
    add("jpeg-420", jpeg(smooth, quality=90), "jpeg", "baseline 4:2:0", chroma="420")
    add("jpeg-422", jpeg(smooth, quality=90, subsampling=1), "jpeg", "baseline 4:2:2", chroma="422")
    add("jpeg-444", jpeg(smooth, quality=90, subsampling=0), "jpeg", "baseline 4:4:4", chroma="444")
    add("jpeg-420-progressive", jpeg(smooth, quality=90, progressive=True), "jpeg", "progressive 4:2:0", chroma="420")
    add("jpeg-444-progressive", jpeg(smooth, quality=90, subsampling=0, progressive=True), "jpeg",
        "progressive 4:4:4", chroma="444")
    add("jpeg-420-restart", jpeg(smooth, quality=85, restart_marker_rows=1), "jpeg", "restart intervals", chroma="420")
    add("jpeg-420-odd", jpeg(photo(23, 37, 1), quality=90), "jpeg", "odd size, partial MCUs", chroma="420")
    add("jpeg-gray", jpeg(smooth, "L", quality=90), "jpeg", "grayscale", chroma="gray")
    gray = jpeg(smooth, "L", quality=90)
    add("jpeg-gray-2x2", edit_frame(gray, lambda out, s: out.__setitem__(s + 11, 0x22)), "jpeg",
        "grayscale with 2x2 sampling factors", chroma="gray")
    cmyk = jpeg(smooth, "CMYK", quality=90)
    add("jpeg-cmyk", cmyk, "jpeg", "Adobe CMYK (transform 0)", chroma="cmyk")
    add("jpeg-cmyk-no-adobe", without_marker(cmyk, 0xEE), "jpeg", "CMYK without APP14", chroma="cmyk")
    add("jpeg-rgb", jpeg(smooth, quality=90, keep_rgb=True), "jpeg", "Adobe RGB (transform 0)", chroma="444")
    ycc = without_marker(jpeg(smooth, quality=90, subsampling=0), 0xE0)
    add("jpeg-ycc-no-jfif", ycc, "jpeg", "YCbCr without JFIF/Adobe", chroma="444")
    add("jpeg-ycc-adobe1", with_segment(ycc, b"\xff\xee\x00\x0eAdobe\x00\x64\x00\x00\x00\x00\x01"), "jpeg",
        "Adobe YCbCr (transform 1)", chroma="444")
    add("jpeg-icc-rgb", jpeg(smooth, quality=90, icc_profile=custom_rgb_profile()), "jpeg",
        "embedded non-sRGB RGB ICC is not applied", chroma="420")
    add("jpeg-icc-lab", jpeg(smooth, quality=90,
                             icc_profile=bytes(stable_profile("LAB"))),
        "jpeg", "embedded LAB ICC is not applied", chroma="420")
    second_frame = Image.fromarray(photo(48, 64, 7), "RGB")
    buffer = io.BytesIO()
    Image.fromarray(smooth, "RGB").save(buffer, "MPO", save_all=True, append_images=[second_frame], quality=90)
    add("jpeg-mpo", buffer.getvalue(), "jpeg", "MPO primary frame", chroma="420")
    add("jpeg-edges-420", jpeg(edges, quality=95), "jpeg", "hard chroma edges, 4:2:0 worst case", chroma="420-edges")
    add("jpeg-edges-444", jpeg(edges, quality=95, subsampling=0), "jpeg", "hard chroma edges, 4:4:4", chroma="444")
    small = photo(24, 32, 2)
    for value in range(1, 9):
        add(f"jpeg-exif{value}", jpeg(small, quality=95, subsampling=0,
                                      exif=b"Exif\0\0" + orientation_exif(value)), "jpeg",
            f"APP1 EXIF orientation {value}", chroma="444")
    add("jpeg-xmp6", jpeg(small, quality=95, subsampling=0, xmp=xmp_packet(6)), "jpeg", "XMP-only orientation",
        chroma="444")
    add("jpeg-exif1-xmp8", jpeg(small, quality=95, subsampling=0, exif=b"Exif\0\0" + orientation_exif(1),
                                xmp=xmp_packet(8)), "jpeg", "EXIF orientation overrides XMP", chroma="444")
    split_exif = jpeg(small, quality=95, subsampling=0, exif=b"Exif\0\0" + orientation_exif(3))
    end = next(e for m, s, e in segments(split_exif) if m == 0xE1)
    trailer = b"Exif\0\0" + bytes(16)
    split_exif = split_exif[:end] + b"\xff\xe1" + struct.pack(">H", len(trailer) + 2) + trailer + split_exif[end:]
    add("jpeg-exif3-two-segments", split_exif, "jpeg", "Pillow concatenates Exif APP1 segments", chroma="444")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rasters", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    args.rasters.mkdir(parents=True, exist_ok=True)
    builder = Builder(args.out, args.rasters)
    build(builder)
    receipt = {
        "generator": "scripts/nemotron-qualification/image-goldens/generate_fixtures.py",
        "pillow": pillow_version, "numpy": np.__version__,
        "libjpeg_turbo": features.version("libjpeg_turbo"), "zlib": features.version("zlib"),
        "reference": "transformers 5.7 load_image: ImageOps.exif_transpose then convert('RGB')",
        "cases": builder.cases,
    }
    (args.out / "reference.json").write_text(json.dumps(receipt, indent=1) + "\n")


if __name__ == "__main__":
    main()
