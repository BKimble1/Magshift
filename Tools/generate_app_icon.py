#!/usr/bin/env python3
"""Render WallField's 1024x1024 app icon.

Pure Python -- no image libraries -- so the icon is reproducible from source in
any environment. Run ``python3 Tools/generate_app_icon.py`` to rewrite
``WallField/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png``.

The design is a dark wall plane crossed by a faint stud-spacing grid, with three
concentric field contours in the app's own strength palette (blue -> amber ->
red) radiating from a measurement point. It deliberately shows *contours of a
measured field*, not an X-ray view or a picture of an object inside a wall.
"""

from __future__ import annotations

import math
import os
import struct
import zlib

SIZE = 1024


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def clamp01(value: float) -> float:
    return 0.0 if value < 0 else (1.0 if value > 1 else value)


def over(base, layer, alpha):
    """Alpha-composite `layer` over `base`."""
    return tuple(lerp(base[i], layer[i], alpha) for i in range(3))


BACKGROUND_INNER = (0.09, 0.13, 0.22)
BACKGROUND_OUTER = (0.03, 0.045, 0.08)
GRID = (1.0, 1.0, 1.0)
RINGS = [
    (0.150, (0.36, 0.66, 0.94)),   # low     -- cool blue
    (0.265, (0.96, 0.70, 0.20)),   # moderate -- amber
    (0.380, (0.92, 0.30, 0.26)),   # strong   -- red
]
CORE = (0.97, 0.97, 1.00)


def render() -> bytes:
    rows = []
    cx, cy = 0.5, 0.52
    for y in range(SIZE):
        row = bytearray()
        v = (y + 0.5) / SIZE
        for x in range(SIZE):
            u = (x + 0.5) / SIZE
            dx, dy = u - cx, v - cy
            distance = math.hypot(dx, dy)

            # Radial background falloff.
            shade = clamp01(distance / 0.75)
            colour = tuple(lerp(BACKGROUND_INNER[i], BACKGROUND_OUTER[i], shade) for i in range(3))

            # Faint wall grid: vertical lines at stud-like spacing, horizontal
            # lines half as often, fading out towards the edges.
            grid_fade = 0.10 * (1.0 - clamp01(distance / 0.68))
            for spacing, weight in ((1 / 6, 1.0), (1 / 3, 0.6)):
                for axis in (u, v):
                    offset = abs((axis % spacing) - spacing / 2)
                    if offset > spacing / 2 - 0.0016:
                        colour = over(colour, GRID, grid_fade * weight)

            # Field contours.
            for radius, ring_colour in RINGS:
                thickness = 0.020
                edge = abs(distance - radius)
                if edge < thickness:
                    alpha = (1.0 - edge / thickness) ** 1.6
                    colour = over(colour, ring_colour, alpha * 0.92)
                # Soft glow just inside each contour.
                elif distance < radius:
                    glow = clamp01(1.0 - (radius - distance) / 0.09)
                    colour = over(colour, ring_colour, glow * 0.06)

            # Measurement point.
            if distance < 0.052:
                alpha = clamp01(1.0 - distance / 0.052) ** 0.8
                colour = over(colour, CORE, alpha)

            row += bytes(int(clamp01(c) * 255 + 0.5) for c in colour)
        rows.append(bytes(row))
    return b"".join(b"\x00" + r for r in rows)


def write_png(path: str, raw: bytes) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB, no alpha
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    destination = os.path.join(
        root, "WallField", "Resources", "Assets.xcassets",
        "AppIcon.appiconset", "AppIcon-1024.png"
    )
    write_png(destination, render())
    print(f"Wrote {destination} ({os.path.getsize(destination)} bytes)")


if __name__ == "__main__":
    main()
