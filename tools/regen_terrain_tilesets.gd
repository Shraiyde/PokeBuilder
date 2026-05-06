## regen_terrain_tilesets.gd
## EditorScript — regenerates all autotile TileSet .tres files using
## Godot's own API so terrain peering bits are written in the correct format.
##
## HOW TO RUN:
##   1. Open this file in the Godot Script editor
##   2. Click  File > Run  (or the ▶ button in the script editor toolbar)
##   3. Wait for "Done!" in the Output panel
##   4. The .tres files in autotiles_terrain/ are now valid terrain TileSets
##
## You only need to run this once (or again after adding new autotile PNGs).
@tool
extends EditorScript

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


func _run() -> void:
	var dir := DirAccess.open(DIR_PATH)
	if dir == null:
		push_error("Cannot open: " + DIR_PATH)
		return

	# Scan so newly added PNGs are importable
	EditorInterface.get_resource_filesystem().scan()
	await EditorInterface.get_resource_filesystem().filesystem_changed

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
	source.texture               = texture
	source.texture_region_size   = Vector2i(TILE_SIZE, TILE_SIZE)
	source.use_texture_padding   = false

	# ── TileSet with one terrain set ─────────────────────────────────────────
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	tileset.add_terrain_set()    # terrain set 0
	tileset.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	tileset.add_terrain(0)       # terrain 0 inside set 0
	tileset.set_terrain_name(0, 0, stem)
	tileset.set_terrain_color(0, 0, Color(0.37, 0.7, 0.37, 1.0))

	# ── Create one tile per blob mask ─────────────────────────────────────────
	for i in BLOB_MASKS.size():
		var mask  : int      = BLOB_MASKS[i]
		var col   : int      = i % OUT_COLS
		var row   : int      = i / OUT_COLS
		var coords := Vector2i(col, row)

		source.create_tile(coords)
		var td := source.get_tile_data(coords, 0)
		td.terrain_set = 0
		_apply_peering_bits(td, mask)

	tileset.add_source(source, 0)

	# ── Save (Godot writes the correct .tres format) ──────────────────────────
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

	const YES := 0    # terrain index 0
	const NO  := -1   # not this terrain

	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_SIDE,            YES if T  else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,    YES if TR else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE,          YES if R  else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, YES if BR else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,         YES if B  else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,  YES if BL else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE,           YES if L  else NO)
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,     YES if TL else NO)
