"""Generates the 1024x1024 app icon (no alpha, as App Store requires). Stdlib only."""
import struct
import sys
import zlib

out = sys.argv[1]
W = H = 1024
bars = [180, 320, 440, 320, 180]
rows = []
for y in range(H):
    t = y / H
    base = (int(217 * (1 - t) + 120 * t), int(119 * (1 - t) + 60 * t), int(87 * (1 - t) + 140 * t))
    row = bytearray([0])
    for x in range(W):
        cx = x - 512
        px = base
        for i, h in enumerate(bars):
            if abs(cx - (-260 + i * 130)) < 38 and abs(y - 512) < h / 2:
                px = (255, 255, 255)
                break
        row += bytes(px)
    rows.append(bytes(row))


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
       + chunk(b"IEND", b""))
with open(out, "wb") as f:
    f.write(png)
