"""
generate_tilesets.py
Generates Godot 4 TileSet .tres resource files for every PNG inside
  assets/graphics/tilesets/tilesets/    (22 main tilesets, 32x32 tiles, 256 px wide)
  assets/graphics/tilesets/autotiles/   (40 autotiles, 32x32 tiles, varying widths)

Run from the repo root:
  python tools/generate_tilesets.py

Output .tres files are placed alongside the PNGs so they can be opened
and further configured in the Godot editor.
"""

import struct
import pathlib

# ── Config ────────────────────────────────────────────────────────────────────

TILE_SIZE   = 32          # px per tile side
PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSET_ROOT   = PROJECT_ROOT / "assets" / "graphics" / "tilesets"

SOURCES = {
    "tilesets":  "res://assets/graphics/tilesets/tilesets/",
    "autotiles": "res://assets/graphics/tilesets/autotiles/",
}


# ── PNG dimension reader (no external deps) ───────────────────────────────────

def png_size(path: pathlib.Path) -> tuple[int, int]:
    """Return (width, height) by reading the PNG IHDR chunk."""
    with open(path, "rb") as f:
        f.read(8)          # PNG signature
        f.read(4)          # IHDR chunk length
        f.read(4)          # "IHDR"
        w = struct.unpack(">I", f.read(4))[0]
        h = struct.unpack(">I", f.read(4))[0]
    return w, h


# ── .tres generator ───────────────────────────────────────────────────────────

def make_tileset_resource(
    res_path: str,
    base_name: str,
    cols: int,
    rows: int,
) -> str:
    """
    Return the text content of a Godot 4 TileSet .tres file.

    res_path  – Godot resource path to the PNG, e.g. "res://assets/.../Outside.png"
    base_name – Slug used for resource IDs (no spaces, no extension)
    cols/rows – Atlas dimensions in tiles
    """
    ext_id    = f"1_{base_name}"
    sub_id    = f"TileSetAtlasSource_{base_name}"
    # load_steps = 1 (ext_resource) + 1 (sub_resource) + 1 (resource header)
    load_steps = 3

    # One line per tile: "col:row/0 = 0"  — no leading whitespace
    tile_lines = []
    for row in range(rows):
        for col in range(cols):
            tile_lines.append(f"{col}:{row}/0 = 0")
    tiles_block = "\n".join(tile_lines)

    # Build without any leading indentation so Godot's parser accepts the file.
    lines = [
        f'[gd_resource type="TileSet" load_steps={load_steps} format=3]',
        "",
        f'[ext_resource type="Texture2D" path="{res_path}" id="{ext_id}"]',
        "",
        f'[sub_resource type="TileSetAtlasSource" id="{sub_id}"]',
        f'texture = ExtResource("{ext_id}")',
        "margins = Vector2i(0, 0)",
        "separation = Vector2i(0, 0)",
        f"texture_region_size = Vector2i({TILE_SIZE}, {TILE_SIZE})",
        "use_texture_padding = false",
        tiles_block,
        "",
        "[resource]",
        f"tile_size = Vector2i({TILE_SIZE}, {TILE_SIZE})",
        f'sources/0 = SubResource("{sub_id}")',
        "",
    ]
    return "\n".join(lines)


def slugify(name: str) -> str:
    """Convert a filename stem to a safe identifier (no spaces/special chars)."""
    return name.replace(" ", "_").replace("-", "_")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    total = 0

    for folder, res_prefix in SOURCES.items():
        src_dir = ASSET_ROOT / folder
        pngs    = sorted(src_dir.glob("*.png"))

        print(f"\n[ {folder} ] — {len(pngs)} files")
        for png_path in pngs:
            w, h = png_size(png_path)
            cols  = w  // TILE_SIZE
            rows  = h  // TILE_SIZE

            if cols == 0 or rows == 0:
                print(f"  SKIP  {png_path.name}  ({w}x{h} — too small)")
                continue

            stem      = png_path.stem          # e.g. "Outside"
            base_name = slugify(stem)          # e.g. "Outside"
            res_path  = res_prefix + png_path.name

            content  = make_tileset_resource(res_path, base_name, cols, rows)
            out_path = png_path.with_suffix(".tres")
            out_path.write_text(content, encoding="utf-8")

            print(f"  OK    {stem}.tres  ({cols}x{rows} tiles, {cols*rows} total)")
            total += 1

    print(f"\nDone — {total} TileSet resources written.")


if __name__ == "__main__":
    main()
