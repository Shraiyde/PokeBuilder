"""
convert_autotiles.py
Converts RPG Maker XP standard autotile PNGs (96×128 px) into
Godot 4 terrain-ready atlases and matching .tres TileSet resources.

Input:  assets/graphics/tilesets/autotiles/*.png
Output: assets/graphics/tilesets/autotiles_terrain/
  <name>.png  — 8×6 grid of 32×32 tiles (256×192 px), one tile per blob mask
  <name>.tres — TileSet resource with terrain_set and peering bits configured

Run from the repo root:
  python tools/convert_autotiles.py

Non-standard sizes (animated multi-frame, etc.) are listed but not converted;
they can still be placed manually as regular tiles.

Requires: Pillow  (pip install Pillow)
"""

import struct, pathlib
from PIL import Image

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────

MINI  = 16   # mini-tile side in px
FULL  = 32   # full tile side in px
SRC_W = 96   # standard RPGMXP autotile width
SRC_H = 128  # standard RPGMXP autotile height

# Animated autotiles are N frames of 96×128 laid horizontally.
# We extract frame 0 (first 96 columns) and treat it as static.
ANIMATED_W_MULTIPLE = SRC_W  # each frame is SRC_W wide

OUT_COLS = 8    # output atlas columns
OUT_ROWS = 6    # output atlas rows  (≥ ceil(47/8) = 6)
OUT_W    = OUT_COLS * FULL   # 256
OUT_H    = OUT_ROWS * FULL   # 192

PROJECT  = pathlib.Path(__file__).resolve().parent.parent
SRC_DIR  = PROJECT / "assets" / "graphics" / "tilesets" / "autotiles"
OUT_DIR  = PROJECT / "assets" / "graphics" / "tilesets" / "autotiles_terrain"
RES_SRC  = "res://assets/graphics/tilesets/autotiles/"
RES_OUT  = "res://assets/graphics/tilesets/autotiles_terrain/"


# ─────────────────────────────────────────────────────────────────────────────
# Mini-tile source positions (col, row) in 16 px units from 96×128 source
#
# Each output 32×32 tile has 4 quadrants: TL, TR, BL, BR.
# Each quadrant is a 16×16 mini-tile copied from the source.
# The source position depends on which of the adjacent neighbors are same-terrain:
#
#   State 0 – outer corner   (neither axis-neighbor is same terrain)
#   State 1 – edge axis-1    (first axis-neighbor present, second absent)
#   State 2 – edge axis-2    (second axis-neighbor present, first absent)
#   State 3 – inner corner   (both axis-neighbors present, diagonal absent)
#   State 4 – center         (both axis-neighbors present AND diagonal present)
#
# For TL quadrant: axis-1 = Top, axis-2 = Left,  diagonal = TL
# For TR quadrant: axis-1 = Top, axis-2 = Right, diagonal = TR
# For BL quadrant: axis-1 = Bot, axis-2 = Left,  diagonal = BL
# For BR quadrant: axis-1 = Bot, axis-2 = Right, diagonal = BR
# ─────────────────────────────────────────────────────────────────────────────

#                  state: outer   edge1  edge2  inner  center
MINI_TL = [(0,2), (0,4), (2,2), (2,4), (2,6)]
MINI_TR = [(3,2), (3,4), (1,2), (1,4), (1,6)]
MINI_BL = [(0,3), (0,5), (2,3), (2,5), (2,7)]
MINI_BR = [(3,3), (3,5), (1,3), (1,5), (1,7)]


def quad_state(ax1: bool, ax2: bool, diag: bool) -> int:
    if not ax1 and not ax2:   return 0  # outer
    if ax1  and not ax2:      return 1  # edge axis-1
    if not ax1 and ax2:       return 2  # edge axis-2
    if ax1  and ax2 and not diag: return 3  # inner
    return 4                            # center


# ─────────────────────────────────────────────────────────────────────────────
# The 47 canonical blob bitmasks
#
# 8-bit neighbor bitmask, bit assignments:
#   bit 0 (  1): TL diagonal
#   bit 1 (  2): Top
#   bit 2 (  4): TR diagonal
#   bit 3 (  8): Left
#   bit 4 ( 16): Right
#   bit 5 ( 32): BL diagonal
#   bit 6 ( 64): Bottom
#   bit 7 (128): BR diagonal
#
# Diagonals are normalised: diagonal bit only set when BOTH adjacent
# orthogonal neighbors are also set.
# ─────────────────────────────────────────────────────────────────────────────

BLOB_MASKS = [
    # 0 orthogonal neighbors (1 tile)
    0,
    # 1 orthogonal neighbor (4 tiles)
    2, 8, 16, 64,
    # 2 adjacent orthogonal neighbors (8 tiles)
    10, 11,   # T+L, T+L+TL
    18, 22,   # T+R, T+R+TR
    72, 104,  # L+B, L+B+BL
    80, 208,  # R+B, R+B+BR
    # 2 opposite orthogonal neighbors (2 tiles)
    24, 66,   # L+R, T+B
    # 3 orthogonal neighbors (16 tiles)
    26, 27, 30,  31,   # T+L+R (+TL, +TR, +TL+TR)
    74, 75, 106, 107,  # T+L+B (+TL, +BL, +TL+BL)
    82, 86, 210, 214,  # T+R+B (+TR, +BR, +TR+BR)
    88, 120, 216, 248, # L+R+B (+BL, +BR, +BL+BR)
    # 4 orthogonal neighbors (16 tiles)
    90,  91,  94,  95,   # T+L+R+B (+TL, +TR, +TL+TR)
    218, 219, 222, 223,  # (+BR, +TL+BR, +TR+BR, +TL+TR+BR)
    122, 123, 126, 127,  # (+BL, +TL+BL, +TR+BL, +TL+TR+BL)
    250, 251, 254, 255,  # (+BR+BL, +TL+BR+BL, +TR+BR+BL, all)
]
assert len(BLOB_MASKS) == 47, f"Expected 47 blob masks, got {len(BLOB_MASKS)}"


# ─────────────────────────────────────────────────────────────────────────────
# Core: composite one 32×32 tile from 4 mini-tiles
# ─────────────────────────────────────────────────────────────────────────────

def composite_tile(src: Image.Image, mask: int) -> Image.Image:
    """Return a 32×32 RGBA image for the given blob mask."""
    T  = bool(mask & (1 << 1))
    R  = bool(mask & (1 << 4))
    B  = bool(mask & (1 << 6))
    L  = bool(mask & (1 << 3))
    TL = bool(mask & (1 << 0)) and T and L
    TR = bool(mask & (1 << 2)) and T and R
    BL = bool(mask & (1 << 5)) and B and L
    BR = bool(mask & (1 << 7)) and B and R

    tile = Image.new("RGBA", (FULL, FULL), (0, 0, 0, 0))

    quadrants = [
        # (dest_x, dest_y,  source_table,  ax1, ax2, diag)
        (0,    0,    MINI_TL, T, L, TL),
        (MINI, 0,    MINI_TR, T, R, TR),
        (0,    MINI, MINI_BL, B, L, BL),
        (MINI, MINI, MINI_BR, B, R, BR),
    ]

    for dx, dy, table, ax1, ax2, diag in quadrants:
        state = quad_state(ax1, ax2, diag)
        sc, sr = table[state]
        sx, sy = sc * MINI, sr * MINI
        region = src.crop((sx, sy, sx + MINI, sy + MINI))
        tile.paste(region, (dx, dy))

    return tile


# ─────────────────────────────────────────────────────────────────────────────
# Generate the terrain peering bits for a blob mask
# ─────────────────────────────────────────────────────────────────────────────

# Godot 4 TileSet.CellNeighbor key names (Corners & Sides mode, mode=0)
_GODOT_PEERING_KEYS = [
    "right_side",
    "bottom_right_corner",
    "bottom_side",
    "bottom_left_corner",
    "left_side",
    "top_left_corner",
    "top_side",
    "top_right_corner",
]

def terrain_peering_bits(mask: int) -> dict:
    """Return {peering_key: terrain_id} for Godot 4 Corners & Sides terrain."""
    T  = bool(mask & (1 << 1))
    R  = bool(mask & (1 << 4))
    B  = bool(mask & (1 << 6))
    L  = bool(mask & (1 << 3))
    TL = bool(mask & (1 << 0)) and T and L
    TR = bool(mask & (1 << 2)) and T and R
    BL = bool(mask & (1 << 5)) and B and L
    BR = bool(mask & (1 << 7)) and B and R

    def t(connects: bool) -> int:
        return 0 if connects else -1   # terrain 0 or "no terrain"

    return {
        "right_side":          t(R),
        "bottom_right_corner": t(BR),
        "bottom_side":         t(B),
        "bottom_left_corner":  t(BL),
        "left_side":           t(L),
        "top_left_corner":     t(TL),
        "top_side":            t(T),
        "top_right_corner":    t(TR),
    }


# ─────────────────────────────────────────────────────────────────────────────
# TileSet .tres generator
# ─────────────────────────────────────────────────────────────────────────────

def write_tres(stem: str, png_res: str) -> None:
    slug = stem.replace(" ", "_")
    ext_id = f"1_{slug}"
    sub_id = f"TileSetAtlasSource_{slug}"

    lines = [
        '[gd_resource type="TileSet" load_steps=3 format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{png_res}" id="{ext_id}"]',
        "",
        f'[sub_resource type="TileSetAtlasSource" id="{sub_id}"]',
        f'texture = ExtResource("{ext_id}")',
        "margins = Vector2i(0, 0)",
        "separation = Vector2i(0, 0)",
        f"texture_region_size = Vector2i({FULL}, {FULL})",
        "use_texture_padding = false",
    ]

    for i, mask in enumerate(BLOB_MASKS):
        tc = i % OUT_COLS
        tr = i // OUT_COLS
        bits = terrain_peering_bits(mask)
        lines.append(f"{tc}:{tr}/0 = 0")
        lines.append(f"{tc}:{tr}/0/terrain_set = 0")
        for key, val in bits.items():
            lines.append(f"{tc}:{tr}/0/terrain_peering_bits/{key} = {val}")

    lines += [
        "",
        "[resource]",
        f"tile_size = Vector2i({FULL}, {FULL})",
        "terrain_sets/0/mode = 0",   # TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
        f'terrain_sets/0/terrains/0/name = "{stem}"',
        "terrain_sets/0/terrains/0/color = Color(0.37, 0.7, 0.37, 1)",
        f'sources/0 = SubResource("{sub_id}")',
        "",
    ]

    tres_path = OUT_DIR / (stem + ".tres")
    tres_path.write_text("\n".join(lines), encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    pngs = sorted(SRC_DIR.glob("*.png"))
    converted, skipped = 0, 0

    for png_path in pngs:
        stem = png_path.stem
        src  = Image.open(png_path).convert("RGBA")
        w, h = src.size

        if h != SRC_H or w % SRC_W != 0:
            print(f"  SKIP  {png_path.name:<40}  ({w}x{h} -- not a 96x128-based autotile)")
            skipped += 1
            continue

        # Animated autotiles: crop to first frame
        if w > SRC_W:
            n_frames = w // SRC_W
            src = src.crop((0, 0, SRC_W, SRC_H))
            print(f"  ANIM  {stem:<40}  ({n_frames} frames, using frame 0)")

        # Build 256×192 atlas with 47 blob tiles
        atlas = Image.new("RGBA", (OUT_W, OUT_H), (0, 0, 0, 0))
        for i, mask in enumerate(BLOB_MASKS):
            tile = composite_tile(src, mask)
            col  = i % OUT_COLS
            row  = i // OUT_COLS
            atlas.paste(tile, (col * FULL, row * FULL))

        out_png = OUT_DIR / (stem + ".png")
        atlas.save(out_png)

        png_res = RES_OUT + stem + ".png"
        write_tres(stem, png_res)

        print(f"  OK    {stem}")
        converted += 1

    print(f"\n{converted} autotiles converted -> {OUT_DIR.name}/")
    if skipped:
        print(f"{skipped} skipped (non-standard size — use as regular tiles)")


if __name__ == "__main__":
    main()
