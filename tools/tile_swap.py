#!/usr/bin/env python3
"""Swap Pokewilds tiles for PokeBuilder GBA-style art (CI step).

Reads tools/tile_swap_map.json: each entry maps one Pokewilds tile
(16x16 PNG under assets/source_0_8_11/tiles/) to one 32x32 cell
(col,row) of a PokeBuilder atlas PNG. The cell is cropped, downscaled
to 16x16 (2x2 box average, keeps the pixel-art look), and written over
the fetched tile. Tiles with no mapping are left as-is (original art),
so the game always looks right where the mapping is incomplete.

Run from the repo root, after the "Fetch Pokewilds assets" step:
    pip install pillow
    python3 tools/tile_swap.py
"""
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MAP_PATH = ROOT / "tools" / "tile_swap_map.json"
TILE_DIR = ROOT / "assets" / "source_0_8_11" / "tiles"
TILE = 32
OUT = 16


def main() -> int:
    mapping = json.loads(MAP_PATH.read_text())
    atlases = {}
    converted = 0
    skipped = 0
    for name, spec in sorted(mapping.items()):
        target = TILE_DIR / name
        if not target.is_file():
            print(f"skip (no such tile): {name}")
            skipped += 1
            continue
        atlas_path = ROOT / spec["atlas"]
        if atlas_path not in atlases:
            if not atlas_path.is_file():
                print(f"ERROR: atlas missing: {spec['atlas']}", file=sys.stderr)
                return 1
            atlases[atlas_path] = Image.open(atlas_path).convert("RGBA")
        atlas = atlases[atlas_path]
        x, y = spec["col"] * TILE, spec["row"] * TILE
        if x + TILE > atlas.width or y + TILE > atlas.height:
            print(f"ERROR: cell out of bounds: {name} -> {spec}",
                  file=sys.stderr)
            return 1
        cell = atlas.crop((x, y, x + TILE, y + TILE))
        cell.resize((OUT, OUT), Image.BOX).save(target)
        converted += 1
    print(f"tile swap: converted {converted}, skipped {skipped}, "
          f"unmapped tiles left as-is")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
