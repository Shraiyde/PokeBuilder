## regen_terrain.gd
## EditorPlugin — adds "Project > Regen Terrain TileSets" menu item.
##
## HOW TO USE:
##   1. Project Settings → Plugins → enable "Regen Terrain TileSets"
##   2. Click  Project > Regen Terrain TileSets  in the top menu bar
##   3. Wait for "Done!" in the Output panel
##
## Re-run any time you add new autotile PNGs to autotiles_terrain/.
@tool
extends EditorPlugin

# ── Blob bitmasks ─────────────────────────────────────────────────────────────
# 47 canonical 8-neighbor blob patterns.
# Bit assignments: 0=TL diag  1=Top  2=TR diag  3=Left
#                  4=Right    5=BL diag  6=Bottom  7=BR diag
# Diagonals are only set when BOTH adjacent orthogonals are also set.
const BLOB_MASKS: Array[int] = [
	# 0 orthogonal neighbors
	0,
	# 1 orthogonal neighbor
	2, 8, 16, 64,
	# 2 adjacent orthogonals (±diagonal)
	10, 11, 18, 22, 72, 104, 80, 208,
	# 2 opposite orthogonals
	24, 66,
	# 3 orthogonals (±diagonals)
	26, 27, 30,  31,
	74, 75, 106, 107,
	82, 86, 210, 214,
	88, 120, 216, 248,
	# 4 orthogonals (all 16 diagonal combos)
	90,  91,  94,  95,
	218, 219, 222, 223,
	122, 123, 126, 127,
	250, 251, 254, 255,
]

const OUT_COLS  := 8
const TILE_SIZE := 32
const DIR_PATH  := "res://assets/graphics/tilesets/autotiles_terrain/"

const MENU_ITEM := "Regen Terrain TileSets"


func _enter_tree() -> void:
	add_tool_menu_item(MENU_ITEM, _regen)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)


func _regen() -> void:
	var dir := DirAccess.open(DIR_PATH)
	if dir == null:
		push_error("Cannot open: " + DIR_PATH)
		return

	# Ensure newly added PNGs are importable before we load them.
	EditorInterface.get_resource_filesystem().scan()

	var count := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".png"):
			_create_tileset(DIR_PATH + fname)
			count += 1
		fname = dir.get_next()
	dir.list_dir_end()

	EditorInterface.get_resource_filesystem().scan()
	print("Done! Regenerated %d TileSet resources in %s" % [count, DIR_PATH])


func _create_tileset(png_path: String) -> void:
	var stem    := png_path.get_file().get_basename()
	var texture := load(png_path) as Texture2D
	if texture == null:
		push_error("Cannot load texture: " + png_path)
		return

	# ── Atlas source ─────────────────────────────────────────────────────────
	var source := TileSetAtlasSource.new()
	source.texture             = texture
	source.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
	source.use_texture_padding = false

	# ── TileSet with one terrain set ─────────────────────────────────────────
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	tileset.add_terrain_set()
	tileset.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	tileset.add_terrain(0)
	tileset.set_terrain_name(0, 0, stem)
	tileset.set_terrain_color(0, 0, Color(0.37, 0.7, 0.37, 1.0))

	# ── One tile per blob mask ────────────────────────────────────────────────
	for i in BLOB_MASKS.size():
		var coords := Vector2i(i % OUT_COLS, i / OUT_COLS)
		source.create_tile(coords)
		var td := source.get_tile_data(coords, 0)
		td.terrain_set = 0
		_apply_peering_bits(td, BLOB_MASKS[i])

	tileset.add_source(source, 0)

	# ── Save via Godot API (writes correct .tres format) ─────────────────────
	var save_path := png_path.replace(".png", ".tres")
	var err       := ResourceSaver.save(tileset, save_path)
	if err == OK:
		print("  OK   " + stem)
	else:
		push_error("  FAIL (%d)  %s" % [err, stem])


func _apply_peering_bits(td: TileData, mask: int) -> void:
	var T  := bool(mask & (1 << 1))
	var R  := bool(mask & (1 << 4))
	var B  := bool(mask & (1 << 6))
	var L  := bool(mask & (1 << 3))
	var TL := bool(mask & (1 << 0)) and T and L
	var TR := bool(mask & (1 << 2)) and T and R
	var BL := bool(mask & (1 << 5)) and B and L
	var BR := bool(mask & (1 << 7)) and B and R

	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_SIDE,            0 if T  else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,    0 if TR else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE,          0 if R  else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, 0 if BR else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,         0 if B  else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,  0 if BL else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE,           0 if L  else -1)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,     0 if TL else -1)
