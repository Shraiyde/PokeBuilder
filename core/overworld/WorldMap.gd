## WorldMap
## Root controller for an overworld map scene.
##
## Structure:
##   Layers/Layer0_Ground   — terrain, ground tiles (grass, water, paths)
##   Layers/Layer1_Objects  — objects on the ground (buildings, trees, ledges)
##   Layers/Layer2_Overhead — tiles drawn above the player (overhangs, rooftops)
##   Entities               — NPCs, items, events (y-sorted with the player)
##
## Each TileMap node must have its tile_set property set to one of the
## TileSet resources in res://assets/graphics/tilesets/tilesets/ before
## the map can be painted.  All three layers should share the same TileSet.
##
## Usage:
##   var map = preload("res://scenes/overworld/WorldMap.tscn").instantiate()
##   map.load_map("pallet_town")    # loads from database
##   add_child(map)
extends Node2D

# ── Node references ───────────────────────────────────────────────────────────
@onready var _layer_ground:   TileMap  = $Layers/Layer0_Ground
@onready var _layer_objects:  TileMap  = $Layers/Layer1_Objects
@onready var _layer_overhead: TileMap  = $Layers/Layer2_Overhead
@onready var _entities:       Node2D   = $Entities
@onready var _camera:         Camera2D = $Camera2D

# ── Map metadata ──────────────────────────────────────────────────────────────
var map_id:   String = ""
var map_name: String = ""

# Tile size in pixels (must match the TileSet tile_size).
const TILE_SIZE := Vector2i(32, 32)


# ── Public API ────────────────────────────────────────────────────────────────

## Loads map data from the database and populates the three TileMap layers.
## Call this after adding the scene to the tree.
func load_map(p_map_id: String) -> void:
	map_id = p_map_id
	# TODO: query map tile data from RPGDatabase and fill the TileMap layers.
	pass


## Sets the TileSet used by all three layers at once.
## Call this before load_map() when the tileset is known up-front.
func set_tileset(tileset: TileSet) -> void:
	_layer_ground.tile_set   = tileset
	_layer_objects.tile_set  = tileset
	_layer_overhead.tile_set = tileset


## Moves the camera to follow a target node (e.g. the player character).
func follow(target: Node2D) -> void:
	_camera.reparent(target)
	_camera.position = Vector2.ZERO


## Returns the tile coordinates at a given world position.
func world_to_tile(world_pos: Vector2) -> Vector2i:
	return _layer_ground.local_to_map(world_pos)


## Returns the world position of the centre of a tile.
func tile_to_world(tile_pos: Vector2i) -> Vector2:
	return _layer_ground.map_to_local(tile_pos)
