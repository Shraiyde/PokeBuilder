# PokeBuilder — Project Documentation

> Last updated: 2026-04-13 (rev 6 — GameData: badges, town map, Z-moves, contest data + runtime queries)
> Engine: **Godot 4.6** · Renderer: **Mobile** · Graphics API: **D3D12** (Windows) · Language: **GDScript**

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Repository Structure](#2-repository-structure)
3. [Godot Project Setup](#3-godot-project-setup)
4. [Folder Structure — poke-builder](#4-folder-structure--poke-builder)
5. [Autoloads (Singletons)](#5-autoloads-singletons)
   - 5.1 [RPGDatabase](#51-rpgdatabase)
   - 5.2 [GameData](#52-gamedata)
   - 5.3 [GameManager](#53-gamemanager)
   - 5.4 [PlayerData](#54-playerdata)
   - 5.5 [AudioManager](#55-audiomanager)
   - 5.6 [SaveSystem](#56-savesystem)
   - 5.7 [SceneManager](#57-scenemanager)
   - 5.8 [BattleManager](#58-battlemanager)
   - 5.9 [TextManager](#59-textmanager)
6. [Runtime Data Classes](#6-runtime-data-classes)
   - 6.1 [Pokemon](#61-pokemon)
   - 6.2 [PokemonFactory](#62-pokemonfactory)
   - 6.3 [Trainer](#63-trainer)
   - 6.4 [BattlePokemon](#64-battlepokemon)
   - 6.5 [Combatant](#65-combatant)
   - 6.6 [BattleField](#66-battlefield)
7. [Feature Flags Reference](#7-feature-flags-reference)
8. [Database Design Principles & Schema](#8-database-design-principles--schema)
9. [PBS → SQLite Migration Tool](#9-pbs--sqlite-migration-tool)
10. [Save File Format](#10-save-file-format)
11. [Audio System](#11-audio-system)
12. [Text & Translation System](#12-text--translation-system)
13. [Coding Conventions](#13-coding-conventions)
14. [Planned Tools](#14-planned-tools)
15. [Reference: Pokémon Essentials Equivalences](#15-reference-pokémon-essentials-equivalences)

---

## 1. Project Overview

**PokeBuilder** is a Godot 4.6 framework that lets fangame creators build Pokémon-style RPGs without writing engine-level code. It is inspired by [Pokémon Essentials v21.1](https://github.com/Maruno17/pokemon-essentials) but replaces its RMXP/Ruby stack and PBS text-file data format with:

- **Godot 4.6** (GDScript) as the engine.
- **SQLite** (via the [`gdsqlite` addon by 2shady4u](https://github.com/2shady4u/godot-sqlite)) as the single source of truth for all static game data.
- **Toggleable feature flags** so each fangame project can enable only the mechanics it needs (Mega Evolution, Z-Moves, Dynamax, Terastallization, etc.).
- **Visual tools** built into the project: a database editor mini-app and a move animation creator.
- A **translation system** built on Godot's native `TranslationServer`.

### Goals

| Goal | Approach |
|------|----------|
| Easy data editing for non-programmers | SQLite database editor tool |
| All PE mechanics available | GDScript reimplementation |
| Only pay for what you use | Feature flags dictionary |
| Exportable to desktop and mobile | Godot Mobile renderer |
| Translation-ready from day one | `TranslationServer` + `TextManager` |

---

## 2. Godot Project Setup

### project.godot highlights

| Setting | Value |
|---------|-------|
| `config/name` | `PokeBuilder` |
| `config/features` | `4.6`, `Mobile` |
| `rendering_device/driver.windows` | `d3d12` |
| `renderer/rendering_method` | `mobile` |
| `3d/physics_engine` | `Jolt Physics` |

### Addons

| Addon | Purpose | Path |
|-------|---------|------|
| `godot-sqlite` (2shady4u) | SQLite database access | `res://addons/godot-sqlite/` |

Enable in: **Project → Project Settings → Plugins → godot-sqlite → Enable**.

### Autoload registration order

The order matters — each singleton depends on the ones above it.

```ini
[autoload]
RPGDatabase = "*res://core/database/RPGDatabase.gd"
GameData    = "*res://core/game_data/GameData.gd"
GameManager = "*res://core/autoloads/GameManager.gd"
PlayerData  = "*res://core/autoloads/PlayerData.gd"
AudioManager= "*res://core/autoloads/AudioManager.gd"
SaveSystem  = "*res://core/autoloads/SaveSystem.gd"
SceneManager= "*res://core/autoloads/SceneManager.gd"
BattleManager="*res://core/autoloads/BattleManager.gd"
TextManager = "*res://core/autoloads/TextManager.gd"
```

---

## 3. Folder Structure — poke-builder

```
poke-builder/
├── addons/
│   └── godot-sqlite/
├── assets/
│   ├── audio/
│   │   ├── bgm/            # Background music (.ogg / .mp3)
│   │   ├── me/             # Jingles: badges, items, evolution
│   │   └── se/
│   │       └── cries/      # Pokémon cries (named by species ID)
│   ├── fonts/
│   └── graphics/
│       ├── battle_animations/
│       ├── battlebacks/
│       ├── characters/
│       │   ├── followers/
│       │   └── followers_shiny/
│       ├── items/
│       ├── pokemon/
│       │   ├── front/  front_shiny/  back/  back_shiny/
│       │   ├── icons/  icons_shiny/  eggs/
│       │   ├── footprints/  shadow/
│       ├── tilesets/
│       ├── trainers/
│       ├── transitions/
│       ├── ui/
│       │   ├── battle/  bag/  party/  summary/
│       │   ├── pokedex/  storage/  town_map/
│       └── weather/
├── core/
│   ├── autoloads/          # All singletons (see §5)
│   ├── database/           # RPGDatabase singleton
│   ├── game_data/          # GameData singleton
│   ├── overworld/
│   ├── battle/             # Battle-state classes (see §6.4–6.6)
│   │   ├── BattleField.gd      # Shared arena: weather, terrain, screens, hazards, Combatant grid
│   │   ├── BattlePokemon.gd    # Volatile battle-state wrapper
│   │   ├── Combatant.gd        # Field slot: battler + queued action
│   │   ├── ai/
│   │   ├── effects/
│   │   └── mechanics/
│   │       ├── mega_evolution/
│   │       ├── z_moves/
│   │       ├── dynamax/
│   │       └── terastallization/
│   ├── pokemon/            # Pokémon data classes (see §6.1–6.2)
│   │   ├── Pokemon.gd          # Runtime Pokémon data structure
│   │   └── PokemonFactory.gd   # Pokémon creation helpers
│   ├── trainer/            # Trainer runtime class (see §6.3)
│   │   └── Trainer.gd          # Runtime trainer assembled from DB
│   ├── save/
│   └── utils/
├── data/
│   ├── db/
│   │   └── pokebuilder.sqlite   # Main game database
│   └── translations/            # .po / .translation files
├── scenes/
│   ├── battle/
│   ├── menus/
│   ├── overworld/
│   └── ui/
│       ├── bag/  party/  pokedex/  storage/  summary/  town_map/
└── tools/
    ├── animation_creator/       # Move animation editor tool
    └── database_editor/         # SQLite database mini-app
        └── editors/
```

> Empty directories contain a `.gdkeep` placeholder file so Git tracks them.

---

## 4. Autoloads (Singletons)

The dependency chain at startup:

```
RPGDatabase.database_ready
    └─► GameData._load_all()
            └─► GameData.data_loaded
                    └─► (rest of the game can start)
```

---

### 5.1 RPGDatabase

**File:** `core/database/RPGDatabase.gd`

The only access point to the SQLite database. All other systems query through this singleton.

#### Key constants

| Constant | Value |
|----------|-------|
| `DB_PATH_DEV` | `res://data/db/pokebuilder.sqlite` |
| `DB_PATH_USER` | `user://pokebuilder.sqlite` |

On first run of an exported build, the database is copied from `res://` to `user://` so it can be written to.

#### Signals

| Signal | Description |
|--------|-------------|
| `database_ready` | Emitted when the connection is open and pragmas applied |
| `database_error(message)` | Emitted on a critical failure |

#### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `query(sql, params)` | `Array[Dictionary]` | SELECT — returns all rows |
| `query_one(sql, params)` | `Dictionary` | SELECT — returns first row or `{}` |
| `execute(sql, params)` | `bool` | INSERT / UPDATE / DELETE |
| `transaction(operations)` | `bool` | Runs multiple statements atomically |
| `last_insert_id()` | `int` | rowid of the last INSERT |
| `is_ready()` | `bool` | True when the connection is open |
| `close()` | `void` | Closes the connection (called on WM_CLOSE) |

#### Applied SQLite pragmas

```sql
PRAGMA journal_mode = WAL;     -- Better concurrent write performance
PRAGMA foreign_keys = ON;      -- Enforce referential integrity
PRAGMA synchronous = NORMAL;   -- Balance between safety and speed
```

#### Usage example

```gdscript
var rows: Array = RPGDatabase.query(
    "SELECT * FROM moves WHERE type_id = ?", ["FIRE"]
)
RPGDatabase.execute(
    "UPDATE items SET price = ? WHERE id = ?", [500, "POTION"]
)
```

---

### 4.2 GameData

**File:** `core/game_data/GameData.gd`

Loads all static game data from SQLite into memory dictionaries on startup. After `data_loaded` is emitted, no further queries are made for static data.

#### Signals

| Signal | Description |
|--------|-------------|
| `data_loaded` | All registries filled and ready |
| `load_error(table, message)` | Error while loading a table |

#### In-memory registries (cached at startup)

| Registry | Key → Value |
|----------|-------------|
| `_species` | `species_id: String → Dictionary` |
| `_forms` | `[species_id, form_index] → Dictionary` |
| `_metrics` | `species_id → Dictionary` |
| `_moves` | `move_id: String → Dictionary` |
| `_abilities` | `ability_id: String → Dictionary` |
| `_natures` | `nature_id: String → Dictionary` |
| `_items` | `item_id: String → Dictionary` |
| `_berry_plants` | `item_id: String → Dictionary` |
| `_types` | `type_id: String → Dictionary` |
| `_type_chart` | `[attacker_id, defender_id] → float` |
| `_trainer_types` | `trainer_type_id: String → Dictionary` |
| `_ribbons` | `ribbon_id: String → Dictionary` |
| `_maps` | `map_id: int → Dictionary` |
| `_map_connections` | `map_id: int → Array[Dictionary]` |
| `_regional_dexes` | `region_index: int → Array[String]` |
| `_badges` | `badge_id: String → Dictionary` |
| `_town_map_points` | `map_id: int → Array[Dictionary]` |
| `_z_moves` | `base_move_id: String → Dictionary` |
| `_move_contest` | `move_id: String → Dictionary` |

Species dictionaries include nested arrays: `level_moves`, `tutor_moves`, `egg_moves`, `evolutions`.

#### Type chart multipliers

| Value | Meaning |
|-------|---------|
| `0.0` | Immune |
| `0.5` | Not very effective |
| `1.0` | Normal (default when key absent) |
| `2.0` | Super effective |

#### Static accessor methods

```gdscript
# Pokémon
GameData.species("BULBASAUR")                    # → Dictionary (+ nested learnset arrays)
GameData.form("ROTOM", 1)                        # → Dictionary (Heat form override)
GameData.metrics("PIKACHU")                      # → Dictionary (sprite offsets)
GameData.all_species()                           # → Array[Dictionary]
GameData.regional_dex(0)                         # → Array[String] (National Dex order)

# Moves / Abilities / Natures
GameData.move("TACKLE")                          # → Dictionary
GameData.ability("OVERGROW")                     # → Dictionary
GameData.nature("ADAMANT")                       # → Dictionary {stat_up, stat_down, …}
GameData.all_natures()                           # → Array[Dictionary]

# Items / Berries
GameData.item("POTION")                          # → Dictionary
GameData.items_in_pocket(3)                      # → Array[Dictionary] (Poké Balls)
GameData.berry_plant("CHERIBERRY")               # → Dictionary

# Types
GameData.type("FIRE")                            # → Dictionary
GameData.type_effectiveness("FIRE", "GRASS")     # → 2.0
GameData.calc_type_multiplier("FIRE", ["GRASS", "POISON"])  # → 1.0

# Maps
GameData.map(5)                                  # → Dictionary
GameData.map_connections(5)                      # → Array[Dictionary]

# Trainers / Ribbons
GameData.trainer_type("YOUNGSTER")               # → Dictionary
GameData.ribbon("CHAMPION")                      # → Dictionary

# Badges
GameData.badge("BOULDERBADGE")                   # → Dictionary
GameData.badges_for_region("KANTO")              # → Array[Dictionary]
GameData.all_badges()                            # → Array[Dictionary]

# Town Map
GameData.town_map_points_for(5)                  # → Array[Dictionary]
GameData.all_town_map_points()                   # → Array[Dictionary]

# Z-Moves (feat_z_moves)
GameData.z_move("TACKLE")                        # → {z_move_id, z_crystal_id, …} or {}
GameData.all_z_moves()                           # → Array[Dictionary]

# Contest move data (feat_contests)
GameData.move_contest("TACKLE")                  # → {category, appeal, jam} or {}
GameData.all_move_contest_data()                 # → Array[Dictionary]
```

#### Runtime query helpers (DB queries executed on demand)

These methods query the database each time they are called and are not cached. Use them when loading dynamic data during gameplay, not during startup.

```gdscript
# Trainer
GameData.trainer_row("YOUNGSTER", "Ben", 0)      # → Dictionary (trainers row)
GameData.trainer_team("LEADER_Brock", "Brock", 0) # → Array of trainer_pokemon rows with "moves" nested
GameData.trainers_of_type("YOUNGSTER")            # → Array[Dictionary] (all versions/names)

# Phone system (feat_phone_system)
GameData.trainer_phone_data(trainer_db_id)        # → {greeting_text, call_text, rematch_text,
                                                  #    item_id, rematch_switch_id, call_rate}

# Shadow Pokémon (feat_shadow_pokemon)
GameData.shadow_pokemon_for_trainer(trainer_db_id) # → Array[Dictionary] ordered by position

# Battle Frontier (feat_battle_frontier)
GameData.battle_facility("BATTLE_TOWER")           # → Dictionary

# Encounter table for a map and encounter type
GameData.encounters_for_map(5, "Land")             # → Array[Dictionary]

# Weighted random wild Pokémon species from the encounter table
GameData.random_encounter_species(5, "LandNight")  # → "RATTATA"
GameData.random_encounter_species(5, "Water", my_rng) # → "TENTACOOL"

# Evolution chains
GameData.evolutions_for("EEVEE")                  # → Array[Dictionary] (evolution paths out)
GameData.pre_evolutions_of("VAPOREON")            # → Array[Dictionary] (what evolves into it)
```

---

### 4.3 GameManager

**File:** `core/autoloads/GameManager.gd`

Central singleton for global game state, feature flags, and player settings. Never pauses (`PROCESS_MODE_ALWAYS`).

#### Enums

**`State`**
```
BOOT · TITLE · OVERWORLD · BATTLE · MENU · CUTSCENE · DIALOGUE · TRANSITION · GAME_OVER
```

**`TextSpeed`** — `SLOW=1 · NORMAL=2 · FAST=3 · INSTANT=4`

**`BattleStyle`** — `SHIFT · SET`

#### Signals

| Signal | Description |
|--------|-------------|
| `state_changed(old, new)` | Global state changed |
| `settings_changed` | A setting was modified |
| `feature_changed(flag, enabled)` | A feature flag toggled |

#### Key properties

| Property | Type | Description |
|----------|------|-------------|
| `current_state` | `State` | Active game state |
| `features` | `Dictionary` | Feature flags (see §6) |
| `settings` | `Dictionary` | Player preferences |
| `game_meta` | `Dictionary` | Fangame metadata (title, start position…) |

#### Default settings

| Key | Default | Description |
|-----|---------|-------------|
| `text_speed` | `TextSpeed.NORMAL` | Dialogue speed |
| `battle_animations` | `true` | Show move animations |
| `battle_style` | `BattleStyle.SHIFT` | Switch warning on/off |
| `sound_mono` | `false` | Mono audio |
| `show_enemy_hp_bar` | `true` | Enemy HP bar visible |
| `show_exp_bar` | `true` | EXP bar visible |
| `nickname_prompt` | `true` | Ask for nickname on catch |
| `language` | `"es"` | Active locale |

#### Database-driven configuration

`GameManager._load_game_settings()` is called automatically once `RPGDatabase` is ready. It reads every row from the `game_settings` table and populates `game_meta` and `features` accordingly, so the fangame creator configures the game by editing that table rather than editing GDScript.

| `game_settings` key | Destination |
|---|---|
| `game_title` | `game_meta["title"]` |
| `game_version` | `game_meta["version"]` |
| `game_author` | `game_meta["author"]` |
| `start_map_id` | `game_meta["start_map"]` |
| `start_x` / `start_y` / `start_direction` | `game_meta["start_x/y/dir"]` |
| `start_money` | `game_meta["start_money"]` |
| `feat_*` | `features["*"]` (strips the `feat_` prefix) |

Values are coerced from strings using the `type` column (`"int"`, `"float"`, `"bool"`, `"string"`).

#### Key methods

```gdscript
GameManager.change_state(GameManager.State.BATTLE)
GameManager.is_player_in_control()          # true in OVERWORLD or BATTLE
GameManager.set_feature("mega_evolution", true)
GameManager.has_feature("z_moves")          # → bool
GameManager.load_features(config_dict)      # bulk-load (overrides DB values)
GameManager.set_setting("text_speed", GameManager.TextSpeed.FAST)
GameManager.load_settings(saved_dict)       # used by SaveSystem on load
```

---

### 4.4 PlayerData

**File:** `core/autoloads/PlayerData.gd`

Stores all persistent runtime data for the player's session.

#### Constants

| Constant | Value |
|----------|-------|
| `MAX_PARTY_SIZE` | `6` |
| `MAX_BOXES` | `32` |
| `BOX_CAPACITY` | `30` |
| `MAX_MONEY` | `9,999,999` |
| `MAX_PHONE_CONTACTS` | `50` |

#### Trainer

| Property | Type | Notes |
|----------|------|-------|
| `trainer_name` | `String` | |
| `trainer_gender` | `int` | 0=male, 1=female |
| `trainer_id` | `int` | 16-bit |
| `secret_id` | `int` | 16-bit, used for shiny breeding |
| `money` | `int` (property) | Clamped to `[0, MAX_MONEY]`; emits `money_changed` |

#### Party & PC

`PlayerData.party` is typed as `Array[Pokemon]`. All entries are `Pokemon` instances (see §6.1); create them via `PokemonFactory` (see §6.2).

```gdscript
var pk: Pokemon = PokemonFactory.create_wild("RATTATA", 8)
PlayerData.add_to_party(pk)             # → bool; auto-sends to PC if party is full
PlayerData.remove_from_party(index)     # will not leave party empty
PlayerData.swap_party(index_a, index_b)
PlayerData.has_conscious_pokemon()      # → bool; uses pk.is_alive()

PlayerData.send_to_box(pk, box, slot)   # → {box, slot} or {}
PlayerData.take_from_box(box, slot)     # → Pokemon or null
PlayerData.pc_count()                   # → int
```

Serialization (`PlayerData.serialize()`) calls `pk.serialize()` on every slot; deserialization calls `PokemonFactory.restore(dict)` to reconstruct each `Pokemon` instance.

#### Bag

```gdscript
PlayerData.bag_add("POTION", 3)
PlayerData.bag_remove("POTION", 1)          # → bool
PlayerData.bag_count("POTION")              # → int
PlayerData.has_item("POTION")               # → bool
```

#### Pokédex

```gdscript
PlayerData.register_seen("PIKACHU")
PlayerData.register_caught("PIKACHU")
PlayerData.has_seen("PIKACHU")              # → bool
PlayerData.has_caught("PIKACHU")            # → bool
PlayerData.pokedex_seen_count()             # → int
PlayerData.pokedex_caught_count()           # → int
```

#### Event state

```gdscript
PlayerData.switch_on(5)
PlayerData.get_switch(5)                    # → bool
PlayerData.set_variable(10, 42)
PlayerData.get_variable(10)                 # → Variant
PlayerData.set_self_switch(map_id, event_id, "A", true)
PlayerData.get_self_switch(map_id, event_id, "A")   # → bool
```

> Self-switch keys use `Array` keys `[map_id, event_id, key]` internally but are serialised as `"map_id,event_id,key"` strings for JSON compatibility.

#### Play time

```gdscript
PlayerData.play_time()           # → {hours, minutes, seconds}
PlayerData.play_time_string()    # → "H:MM"  (short=true)
PlayerData.play_time_string(false) # → "HH:MM:SS"
```

Time only increments while `GameManager.is_player_in_control()` is true.

---

### 4.5 AudioManager

**File:** `core/autoloads/AudioManager.gd`

Handles all game audio. Never pauses (`PROCESS_MODE_ALWAYS`).

#### Audio buses

| Bus constant | Bus name | Content |
|---|---|---|
| `BUS_BGM` | `"BGM"` | Background music |
| `BUS_SE` | `"SE"` | Sound effects + cries |
| `BUS_ME` | `"ME"` | Event jingles |

Falls back to `"Master"` if a named bus does not exist.

#### Asset paths

| Constant | Path |
|----------|------|
| `BGM_PATH` | `res://assets/audio/bgm/` |
| `SE_PATH` | `res://assets/audio/se/` |
| `ME_PATH` | `res://assets/audio/me/` |
| `CRY_PATH` | `res://assets/audio/se/cries/` |

Supported extensions (tried in order): `.ogg`, `.mp3`, `.wav`.

#### BGM

```gdscript
AudioManager.play_bgm("Battle wild")               # play / fade in
AudioManager.play_bgm("Battle wild", 0.0, 1.5)     # with 1.5 s fade-in
AudioManager.stop_bgm(0.5)                          # fade out over 0.5 s
AudioManager.pause_bgm()
AudioManager.resume_bgm()
AudioManager.fade_bgm(-10.0, 1.0)                  # fade to target dB in 1 s
```

#### BGM stack (push/pop)

```gdscript
AudioManager.push_bgm("Cave")   # save current track, play "Cave"
AudioManager.pop_bgm()          # restore previous track at saved position
```

The stack stores `{name, position, volume_db}` so playback resumes exactly where it left off.

#### ME (event jingles)

```gdscript
AudioManager.play_me("Badge get")   # pauses BGM, plays jingle, resumes BGM
```

BGM resumes automatically via `_on_me_finished()`.

#### SE (sound effects)

```gdscript
AudioManager.play_se("Battle ball shake")
AudioManager.play_se("Click", 0.0, 1.2)   # volume_db, pitch_scale
AudioManager.stop_all_se()
```

Pool of `SE_POOL_SIZE = 8` simultaneous channels.

#### Pokémon cries

```gdscript
AudioManager.play_cry("PIKACHU")
AudioManager.play_cry("ROTOM", 1, 0.9)    # form_index, pitch_scale
await AudioManager.await_cry()            # wait for cry to finish
```

Cry file naming: `SPECIES_ID.ogg` for base form, `SPECIES_ID_N.ogg` for form N.

#### Volume control

```gdscript
AudioManager.set_master_volume(0.8)   # 0.0 – 1.0
AudioManager.set_bgm_volume(0.7)
AudioManager.set_se_volume(1.0)
```

---

### 4.6 SaveSystem

**File:** `core/autoloads/SaveSystem.gd`

#### Save format

- **Location:** `user://saves/slot_N.sav`
- **Encoding:** JSON → Zstd compression (`FileAccess.COMPRESSION_ZSTD`)
- **Slots:** `MAX_SLOTS = 3` (indices 0–2)
- **Version field:** `SAVE_VERSION = 1`

#### Saved data structure

```json
{
  "_version": 1,
  "_slot": 0,
  "_date": "2026-04-12T14:30:00",
  "player": { ...PlayerData.serialize() },
  "settings": { ...GameManager.settings },
  "features": { ...GameManager.features },
  "map_state": {}
}
```

#### Methods

```gdscript
SaveSystem.save(0)                    # → bool
SaveSystem.load_game(0)               # → bool
SaveSystem.slot_info(0)               # → {exists, date, trainer_name, play_time, badge_count, version}
SaveSystem.slot_exists(0)             # → bool
SaveSystem.delete_slot(0)             # → bool
```

#### Migration

`_migrate(data, from_version)` is called automatically when the save version does not match `SAVE_VERSION`. Add migration steps there as the format evolves.

---

### 4.7 SceneManager

**File:** `core/autoloads/SceneManager.gd`

Manages scene transitions and maintains a scene stack for menu overlays.

#### Transition types

| Value | Effect |
|-------|--------|
| `NONE` | Instant, no effect |
| `FADE` | Fade to black and back |
| `FADE_WHITE` | Fade to white (evolution, flash) |
| `SLIDE_LEFT` | Slide left |
| `SLIDE_RIGHT` | Slide right |
| `POKEBALL` | Circular Poké Ball wipe (future implementation) |

#### Overlay

A `ColorRect` on a `CanvasLayer` at layer 100 (above everything). `mouse_filter = IGNORE` so it never captures input.

#### Navigation

```gdscript
# Replace current scene (clears stack)
SceneManager.goto("res://scenes/overworld/map.tscn")
SceneManager.goto("res://scenes/battle/battle_scene.tscn", SceneManager.Transition.FADE, 0.3)
SceneManager.goto_instant("res://scenes/title.tscn")

# Stack (for menus on top of the overworld)
SceneManager.push("res://scenes/ui/party_screen.tscn")
SceneManager.pop()

# Reload
SceneManager.reload()
```

#### State queries

```gdscript
SceneManager.is_transitioning()   # → bool
SceneManager.stack_depth()        # → int
SceneManager.peek_stack()         # → String (path at top of stack)
```

---

### 4.8 BattleManager

**File:** `core/autoloads/BattleManager.gd`

Entry and exit point for all battle types. Uses `await` so the calling code gets the result directly.

#### Battle types

`WILD_SINGLE · WILD_DOUBLE · TRAINER_SINGLE · TRAINER_DOUBLE · TRAINER_MULTI · SAFARI · BUG_CONTEST · FRONTIER`

#### Outcomes

`WIN · LOSE · FLEE · CAUGHT · DRAW · ABORT`

#### Starting battles

```gdscript
# Wild
var result: Dictionary = await BattleManager.start_wild_battle({
    "species_id": "PIDGEY", "level": 12, "shiny": false
})

# Wild double
var result: Dictionary = await BattleManager.start_wild_double_battle(
    {"species_id": "ODDISH", "level": 8},
    {"species_id": "BELLSPROUT", "level": 9}
)

# Trainer
var result: Dictionary = await BattleManager.start_trainer_battle("YOUNGSTER", "Ben", 0)

# Safari
var result: Dictionary = await BattleManager.start_safari_battle({"species_id": "SCYTHER", "level": 25})

# Frontier
var result: Dictionary = await BattleManager.start_frontier_battle(opponent_config)
```

#### Battle flow

1. `_run_battle(config)` — sets state to `BATTLE`, pushes BGM, calls `SceneManager.push()` with the battle scene.
2. The battle scene runs its logic.
3. The battle scene calls `BattleManager.finish_battle(result)` when done.
4. `finish_battle()` applies the outcome, pops BGM, pops scene, restores `OVERWORLD` state, emits `battle_ended`.
5. The `await` in the calling code receives the result dictionary.

#### Result dictionary

```gdscript
{
    "outcome": BattleManager.Outcome.WIN,
    # For CAUGHT — must be a Pokemon instance, not a raw Dictionary:
    "caught_pokemon": pokemon_instance,
}
```

#### BGM auto-selection for trainers

| Trainer flag | BGM |
|---|---|
| `Champion` | `"Battle Champion"` |
| `EliteFour` | `"Battle Elite"` |
| `GymLeader` | `"Battle Gym Leader"` |
| _(other)_ | `"Battle trainer"` |

---

### 4.9 TextManager

**File:** `core/autoloads/TextManager.gd`

Handles variable substitution, translation integration, and formatting helpers.

#### Variable markers

Variables in strings use the `[key]` format (not PE's `\PN`-style codes).

#### Built-in context variables

| Marker | Value source |
|--------|-------------|
| `[player_name]` | `PlayerData.trainer_name` |
| `[money]` | Formatted money (locale-aware separators) |
| `[play_time]` | `"H:MM"` format |
| `[badge_count]` | Region 0 badge count |
| `[seen_count]` | Pokédex seen count |
| `[caught_count]` | Pokédex caught count |
| `[lead_pokemon]` | Party lead nickname / species name |
| `[lead_pokemon_level]` | Level of lead Pokémon |
| `[lead_pokemon_hp]` / `[lead_pokemon_maxhp]` | HP values |
| All keys in `battle_context` | Set by BattleManager |
| All keys in `event_context` | Set by overworld events |

#### Methods

```gdscript
# Translate key + substitute variables
TextManager.t("MSG_CAUGHT", {"species": "Pikachu"})

# Substitute variables in an already-localised string
TextManager.parse("Hello, [player_name]!")

# Formatting
TextManager.format_number(9999999)                 # "9,999,999" or "9.999.999"
TextManager.format_stat(120, 1)                    # "[color=green]120[/color]"
TextManager.format_effectiveness(2.0)              # tr("EFF_DOUBLE")
TextManager.format_pokemon_name(pokemon_dict)      # nickname or species name
TextManager.possessive("Ash", 0)                   # "Ash's"
TextManager.article(0, false)                      # "the" / "el"

# Utilities
TextManager.capitalize_first("hello")              # "Hello"
TextManager.truncate("Long name", 8)               # "Long na…"
TextManager.strip_bbcode("[color=red]text[/color]") # "text"

# Language
TextManager.current_locale = "en"
TextManager.available_locales()                    # Array[String]
```

#### Updating context dictionaries

```gdscript
# Before a battle starts:
TextManager.battle_context["enemy_trainer_name"] = "Brock"
TextManager.battle_context["move_name"] = "Tackle"

# In overworld events:
TextManager.event_context["npc_name"] = "Old Man"
TextManager.event_context["location"] = "Pallet Town"
```

---

## 5. Runtime Data Classes

`class_name` classes (not autoloads). Godot discovers them from the file system automatically — no registration in `project.godot` is required.

| Class | File | Extends | Purpose |
|-------|------|---------|---------|
| `Pokemon` | `core/pokemon/Pokemon.gd` | `RefCounted` | Persistent Pokémon data |
| `PokemonFactory` | `core/pokemon/PokemonFactory.gd` | `RefCounted` | Pokémon creation helpers (all static) |
| `Trainer` | `core/trainer/Trainer.gd` | `RefCounted` | Runtime trainer assembled from DB |
| `BattlePokemon` | `core/battle/BattlePokemon.gd` | `RefCounted` | Volatile battle-state wrapper around a Pokemon |
| `Combatant` | `core/battle/Combatant.gd` | `RefCounted` | Field slot: battler + queued action |
| `BattleField` | `core/battle/BattleField.gd` | `RefCounted` | Shared arena state: weather, terrain, screens, hazards, Combatant grid |

---

### 5.1 Pokemon

**File:** `core/pokemon/Pokemon.gd` · `class_name Pokemon extends RefCounted`

Runtime data structure for a single live Pokémon. Created exclusively via `PokemonFactory`; stored in `PlayerData.party` and `PlayerData.pc_boxes`.

#### Properties

##### Identity
| Property | Type | Description |
|----------|------|-------------|
| `species_id` | `String` | e.g. `"BULBASAUR"` — matches `pokemon_species.id` |
| `form_index` | `int` | `0` = base form; positive = alternate form |
| `nickname` | `String` | `""` = show species name |
| `gender` | `int` | `0` = male · `1` = female · `2` = genderless |
| `is_shiny` | `bool` | |

##### Growth
| Property | Type | Description |
|----------|------|-------------|
| `level` | `int` | 1–100 |
| `exp` | `int` | Total accumulated EXP |

##### Battle
| Property | Type | Description |
|----------|------|-------------|
| `nature_id` | `String` | e.g. `"ADAMANT"` — matches `natures.id` |
| `ability_index` | `int` | `0` = ab1 · `1` = ab2 · `2` = hidden |
| `current_hp` | `int` | Current hit points |
| `iv_hp … iv_spe` | `int` | Individual Values (0–31) |
| `ev_hp … ev_spe` | `int` | Effort Values (0–252; 510 total cap) |
| `moves` | `Array` | Up to 4 slots: `{move_id, current_pp, max_pp, pp_ups}` |
| `status` | `Pokemon.Status` | `NONE / BURN / POISON / BADPOISON / PARALYSIS / FREEZE / SLEEP` |

##### Metadata
| Property | Type | Description |
|----------|------|-------------|
| `held_item_id` | `String` | `""` = no held item |
| `happiness` | `int` | 0–255 |
| `ot_name / ot_id / ot_secret_id / ot_gender` | various | Original trainer |
| `pokeball_id` | `String` | Ball used to catch |
| `met_map_id / met_level / met_date` | various | Where / when met |
| `is_egg` | `bool` | True if not yet hatched |
| `egg_steps` | `int` | Steps remaining to hatch |
| `ribbons` | `Array[String]` | Ribbon IDs earned |
| `pokerus_days` | `int` | `0`=never · `1-4`=active · `-1`=cured |

#### Key methods

```gdscript
# Stat calculation (Gen-III formula)
var stats: Dictionary = pk.calc_stats()   # {hp, atk, def, spa, spd, spe}
var mhp:   int        = pk.max_hp()

# Type and ability (resolves form overrides automatically)
var types:     Array  = pk.type_ids()           # ["GRASS", "POISON"]
var ability:   String = pk.current_ability_id() # "OVERGROW"
var name:      String = pk.full_name()          # nickname or species name

# Battle helpers
pk.is_fainted()                        # → bool
pk.is_alive()                          # → bool
pk.take_damage(30)                     # → int (actual damage dealt)
pk.restore_hp(50)                      # → int (actual HP restored)
pk.full_heal()                         # HP + status + PP

# Move management
pk.has_move("TACKLE")                  # → bool
pk.set_move(-1, "THUNDERBOLT")         # append to first free slot
pk.set_move(2, "THUNDERBOLT")          # overwrite slot 2
pk.remove_move(0)
pk.restore_all_pp()

# EV training
pk.add_ev("atk", 3)                    # → int (actual EVs added)
pk.total_evs()                         # → int (sum of all EVs)

# Serialization
var data: Dictionary = pk.serialize()
var copy: Pokemon    = Pokemon.restore(data)
```

---

### 5.2 PokemonFactory

**File:** `core/pokemon/PokemonFactory.gd` · `class_name PokemonFactory extends RefCounted`

All methods are static. This class is never instantiated.

#### `create_wild(species_id, level, form_index?, rng?)`

Creates a wild Pokémon with randomized IVs, nature, gender, and ability. Assigns the last 4 level-up moves learnable at the given level. Sets the OT to the current player.

```gdscript
var pk: Pokemon = PokemonFactory.create_wild("PIKACHU", 10)
var pk: Pokemon = PokemonFactory.create_wild("ROTOM", 30, 1, my_rng)  # Heat form
```

#### `create_from_trainer_slot(tp_dict)`

Creates a Pokémon from a `trainer_pokemon` DB row (e.g., the output of `GameData.trainer_team()`). NULL DB columns fall back to sensible defaults (IVs → 15, nature → random).

```gdscript
var team:  Array   = GameData.trainer_team("LEADER_Brock", "Brock", 0)
var pk:    Pokemon = PokemonFactory.create_from_trainer_slot(team[0])
```

#### `create_egg(species_id, rng?, parent_nature?)`

Creates an unhatched egg. Level = 1, `is_egg = true`, `egg_steps` set from species data.

```gdscript
var egg: Pokemon = PokemonFactory.create_egg("PICHU")
var egg: Pokemon = PokemonFactory.create_egg("PICHU", rng, "JOLLY")  # Everstone
```

#### `restore(dict)`

Reconstructs a `Pokemon` from a save-file Dictionary. Called automatically by `PlayerData.deserialize()`.

```gdscript
var pk: Pokemon = PokemonFactory.restore(saved_dict)
```

#### Internal randomization rules

| Aspect | Rule |
|--------|------|
| Nature | Random from `GameData.all_natures()` |
| Ability | Slot 0 or 1 at random (wild never start with hidden ability) |
| Gender | Rolled from the species `gender_ratio` field |
| Shiny | 1 / 8192 (Gen II–V base rate) |
| IVs (wild) | 0–31 per stat (uniform random) |
| IVs (trainer) | From DB column; default 15 when NULL |

---

### 5.3 Trainer

**File:** `core/trainer/Trainer.gd` · `class_name Trainer extends RefCounted`

Runtime trainer object assembled from the `trainers`, `trainer_types`, and `trainer_pokemon` tables. The persistent `Pokemon` team is built via `PokemonFactory`.

#### `Trainer.build(type_id, name, version_index?)` → `Trainer`

Static factory. Fetches the trainer row, reads trainer-type data, parses items, and builds the full `Array[Pokemon]` team. Returns `null` if not found in the database.

```gdscript
var trainer: Trainer = Trainer.build("YOUNGSTER", "Ben", 0)
if trainer == null:
    return   # not in DB
```

#### Properties

| Property | Type | Description |
|----------|------|-------------|
| `type_id` | `String` | Trainer class ID (e.g. `"YOUNGSTER"`) |
| `trainer_name` | `String` | Display name (e.g. `"Ben"`) |
| `version_index` | `int` | `0` = initial, `1+` = rematches |
| `db_id` | `int` | Database surrogate key |
| `ai_skill` | `int` | AI level 1–5 (from `trainer_types`) |
| `base_money` | `int` | Prize formula base (from `trainer_types`) |
| `battle_bgm` | `String` | BGM override key; `""` = use global default |
| `flags` | `String` | Trainer type flags (`"GymLeader"`, `"EliteFour"`, …) |
| `items` | `Array[String]` | Items the trainer can use during battle |
| `team` | `Array[Pokemon]` | Live Pokémon team |
| `active_index` | `int` | Index of the currently active Pokémon (`-1` = none) |

#### Key methods

```gdscript
trainer.active_pokemon()        # → Pokemon or null
trainer.switch_to(index)        # → bool; fails if slot is fainted
trainer.next_available_index()  # → int (-1 if all fainted)
trainer.send_next()             # → bool; advances active_index to next live slot
trainer.all_fainted()           # → bool
trainer.prize_money()           # → int (base_money × highest level in team)
trainer.has_flag("GymLeader")   # → bool
```

---

### 5.4 BattlePokemon

**File:** `core/battle/BattlePokemon.gd` · `class_name BattlePokemon extends RefCounted`

Volatile wrapper around a persistent `Pokemon`. Holds all state that exists only for the duration of a battle: stat stages, confusion, volatile effects, and type/ability overrides.

The underlying `Pokemon` is modified only for permanent changes (damage, PP loss, status, EV gain).

#### `BattlePokemon.wrap(pokemon)` → `BattlePokemon`

Static factory. Call once per battle per active Pokémon.

```gdscript
var bp: BattlePokemon = BattlePokemon.wrap(pk)
```

#### Volatile state

| Property | Type | Description |
|----------|------|-------------|
| `stage_atk … stage_spe` | `int` | Stat stages (−6 to +6) |
| `stage_acc` / `stage_eva` | `int` | Accuracy / evasion stages |
| `stage_crit` | `int` | Critical-hit stage (0–3) |
| `confusion_turns` | `int` | `0` = not confused |
| `is_flinched` | `bool` | Cleared at end of turn |
| `is_protected` | `bool` | Protect / Detect active this turn |
| `leech_seed_source` | `int` | Source slot index; `−1` = not seeded |
| `substitute_hp` | `int` | `0` = no substitute |
| `encore_move_id` / `encore_turns` | `String` / `int` | Encore lock |
| `disabled_move_id` / `disable_turns` | `String` / `int` | Disable effect |
| `taunt_turns` | `int` | Taunt duration remaining |
| `type_override` | `Array[String]` | Replaces `pokemon.type_ids()` when non-empty |
| `ability_override` | `String` | Replaces `pokemon.current_ability_id()` when non-empty |
| `has_mega_evolved` / `has_used_z_move` | `bool` | Once-per-battle flags |

#### Key methods

```gdscript
bp.apply_stat_stage("atk", 2)          # → int (actual change applied)
bp.get_stage("spa")                    # → int
bp.reset_volatile()                    # clear all volatile state (on switch-out)
bp.calc_effective_stats()              # → {hp, atk, def, spa, spd, spe} with stages
bp.accuracy_multiplier()               # → float
bp.evasion_multiplier()                # → float
bp.effective_types()                   # → Array[String] (override → pokemon)
bp.effective_ability()                 # → String        (override → pokemon)
bp.is_fainted() / bp.is_alive()        # pass-throughs to pokemon
bp.full_name()                         # pass-through to pokemon
```

---

### 5.5 Combatant

**File:** `core/battle/Combatant.gd` · `class_name Combatant extends RefCounted`

Represents one field slot (player or enemy side). Holds the `BattlePokemon` currently on the field, the action queued for the current turn, and per-slot field effects (Reflect, Light Screen, Mist).

#### Enums

**`Side`** — `PLAYER · ENEMY`

**`ActionType`** — `NONE · MOVE · SWITCH · ITEM · RUN · SKIP`

#### Construction

```gdscript
var slot: Combatant = Combatant.new(Combatant.Side.PLAYER, 0)
slot.set_battler(BattlePokemon.wrap(player_party[0]))
```

#### Key properties

| Property | Type | Description |
|----------|------|-------------|
| `side` | `Side` | `PLAYER` or `ENEMY` |
| `slot_index` | `int` | Position index on the field (`0` = primary) |
| `battler` | `BattlePokemon` | Pokémon in this slot; `null` if empty |
| `action_type` | `ActionType` | Queued action category |
| `queued_move_id` | `String` | Move selected (when `MOVE`) |
| `queued_target` | `Combatant` | Target slot |
| `queued_switch_index` | `int` | Team index to switch to (when `SWITCH`) |
| `effective_speed` | `int` | Cached speed for turn-order sorting |
| `reflect_turns` / `light_screen_turns` / `mist_turns` | `int` | Turns remaining |
| `focus_energy` | `bool` | Focus Energy active |

#### Key methods

```gdscript
slot.set_battler(bp)              # place a BattlePokemon in the slot
slot.clear_battler()              # remove battler + clear action
slot.is_occupied()                # → bool (non-null and not fainted)

slot.queue_move("TACKLE", target)
slot.queue_switch(1)
slot.queue_item("POTION", target)
slot.queue_run()
slot.queue_skip()
slot.clear_action()
slot.has_action()                 # → bool

slot.clear_field_effects()        # clears Focus Energy (called on switch-out)
# Note: Reflect, Light Screen, Mist, Tailwind and entry hazards are side-wide
# and live on BattleField, not on individual Combatant slots.
```

---

### 5.6 BattleField

**File:** `core/battle/BattleField.gd` · `class_name BattleField extends RefCounted`

Shared arena state for an entire battle. All battle-engine code that needs to read or modify weather, terrain, screens, hazards, or the Combatant grid operates through this object.

#### Enums

**`Weather`** — `NONE · SUNNY · RAIN · SANDSTORM · HAIL · HEAVY_RAIN · HARSH_SUN · STRONG_WINDS`

**`Terrain`** — `NONE · ELECTRIC · GRASSY · MISTY · PSYCHIC`

#### Global state

| Property | Type | Description |
|----------|------|-------------|
| `weather` | `Weather` | Active weather condition |
| `weather_turns` | `int` | Turns remaining; `−1` = permanent |
| `terrain` | `Terrain` | Active terrain |
| `terrain_turns` | `int` | Turns remaining; `−1` = permanent |
| `trick_room_turns` | `int` | `0` = inactive |
| `wonder_room_turns` | `int` | `0` = inactive |
| `magic_room_turns` | `int` | `0` = inactive |
| `gravity_turns` | `int` | `0` = inactive |
| `turn_count` | `int` | Turns completed since battle start |

#### Per-side state (index 0 = PLAYER, 1 = ENEMY)

| Property | Type | Description |
|----------|------|-------------|
| `reflect_turns` | `Array[int]` | Turns of Reflect remaining |
| `light_screen_turns` | `Array[int]` | Turns of Light Screen remaining |
| `aurora_veil_turns` | `Array[int]` | Turns of Aurora Veil remaining |
| `mist_turns` | `Array[int]` | Turns of Mist remaining |
| `tailwind_turns` | `Array[int]` | Turns of Tailwind remaining |
| `lucky_chant_turns` | `Array[int]` | Turns of Lucky Chant remaining |
| `stealth_rock` | `Array[bool]` | Stealth Rock present |
| `spikes` | `Array[int]` | Spike layers (0–3) |
| `toxic_spikes` | `Array[int]` | Toxic Spike layers (0–2) |
| `sticky_web` | `Array[bool]` | Sticky Web present |

#### Key methods

```gdscript
# Setup
field.add_combatant(slot)                  # place a Combatant in the grid

# Combatant access
field.combatant(Side.PLAYER, 0)            # → Combatant or null
field.side_combatants(Side.ENEMY)          # → Array[Combatant]
field.opponents_of(c)                      # → Array[Combatant]
field.allies_of(c)                         # → Array[Combatant] (excludes c)
field.all_combatants()                     # → Array[Combatant]

# Weather
field.set_weather(BattleField.Weather.RAIN, 5)
field.clear_weather()
field.has_weather(BattleField.Weather.SUNNY)   # → bool
field.weather_active()                         # → bool

# Terrain
field.set_terrain(BattleField.Terrain.ELECTRIC, 5)
field.has_terrain(BattleField.Terrain.GRASSY)  # → bool

# Screens / side conditions
field.has_reflect(Side.PLAYER)             # → bool
field.has_light_screen(Side.ENEMY)         # → bool
field.has_aurora_veil(Side.PLAYER)         # → bool
field.has_mist(Side.ENEMY)                 # → bool
field.has_tailwind(Side.PLAYER)            # → bool
field.physical_screen_multiplier(Side.ENEMY)  # → 0.5 or 1.0
field.special_screen_multiplier(Side.PLAYER)  # → 0.5 or 1.0

# Entry hazards
field.clear_entry_hazards(Side.ENEMY)      # Rapid Spin / Defog

# Room / gravity
field.trick_room_active()                  # → bool
field.gravity_active()                     # → bool

# End-of-turn tick
field.tick()   # increments turn_count; decrements all non-zero counters;
               # clears weather/terrain when they reach 0
```

#### Design note

Reflect, Light Screen, Mist, Tailwind, and entry hazards are **side-wide conditions** — they protect or affect every Pokémon on a side regardless of which slot they occupy. They live here, not on `Combatant`. `Combatant` retains only truly per-slot state (`focus_energy`, the queued action, and the `BattlePokemon` reference).

---

## 6. Feature Flags Reference

Managed by `GameManager.features`. Set via `GameManager.set_feature(flag, bool)` or bulk-loaded from a fangame config with `GameManager.load_features(config)`.

| Flag | Default | Description |
|------|---------|-------------|
| `core` | `true` | Gen 1–3 base mechanics (cannot be disabled) |
| `mega_evolution` | `false` | Gen 6 Mega Evolution |
| `primal_reversion` | `false` | Gen 6 Primal Reversion |
| `z_moves` | `false` | Gen 7 Z-Moves |
| `alolan_forms` | `false` | Gen 7 Alolan regional forms |
| `dynamax` | `false` | Gen 8 Dynamax / Gigantamax |
| `galarian_forms` | `false` | Gen 8 Galarian regional forms |
| `terastallization` | `false` | Gen 9 Terastallization |
| `paldean_forms` | `false` | Gen 9 Paldean regional forms |
| `shadow_pokemon` | `false` | Shadow Pokémon (Colosseum / XD) |
| `breeding` | `true` | Egg / breeding system |
| `contests` | `false` | Pokémon Contests |
| `mini_games` | `false` | Pokéathlon / mini-games |
| `phone_system` | `true` | Trainer phone / rematches |
| `berry_farming` | `true` | Berry growing |
| `dungeons` | `false` | Procedural dungeon generation |
| `real_time` | `true` | Day/night based on system clock |
| `followers` | `false` | Pokémon follower in overworld |
| `battle_frontier` | `false` | Battle Frontier / facilities |

---

## 7. Database Design Principles & Schema

### Design principles

- **WAL journal mode** — better concurrent write performance.
- **Foreign keys ON** — referential integrity enforced at the DB level.
- **synchronous = NORMAL** — balance between crash safety and speed.
- All static game data lives in SQLite; runtime data lives in `PlayerData`.
- The database is copied from `res://` to `user://` on first export run to enable writes.
- **String IDs** (e.g. `"BULBASAUR"`, `"TACKLE"`, `"FIRE"`) are used as primary keys for readability and compatibility with PE PBS identifiers.
- **Integer surrogate keys** for maps, trainers, and other entities that lack a canonical string ID.

### Schema files

| File | Purpose |
|------|---------|
| `data/db/schema.sql` | Full DDL — tables, indexes, views, seed data |
| `data/db/pokebuilder.sqlite` | Generated database (do not hand-edit; regenerate from schema.sql) |

To regenerate the database from scratch:
```python
import sqlite3, pathlib
sql = pathlib.Path("data/db/schema.sql").read_text(encoding="utf-8")
con = sqlite3.connect("data/db/pokebuilder.sqlite")
con.executescript(sql)
con.close()
```

See §9 for importing real data from Pokémon Essentials PBS files.

### Table inventory (35 tables)

#### Configuration
| Table | Description |
|-------|-------------|
| `db_metadata` | Schema version and build info |
| `game_settings` | Fangame-level configuration key/value pairs (title, start position, feature flags) |

#### Core game data
| Table | PK type | Description |
|-------|---------|-------------|
| `types` | String | Types (FIRE, WATER, …) with display color and icon position |
| `type_effectiveness` | Composite | Type chart — only non-1.0 multipliers stored (0.0 / 0.5 / 2.0) |
| `abilities` | String | Ability data and flags |
| `natures` | String | All 25 natures with stat modifiers and flavour preferences |
| `ribbons` | String | Ribbon data and icon sheet position |

#### Moves
| Table | PK type | Description |
|-------|---------|-------------|
| `moves` | String | Move data: type, category, power, accuracy, PP, target, flags, function code |
| `z_move_data` | FK→moves | Z-Move mapping: base move → Z-Move, required Z-Crystal, optional species lock |
| `move_contest_data` | FK→moves | Contest category, appeal and jam values _(feat_contests)_ |

#### Items
| Table | PK type | Description |
|-------|---------|-------------|
| `items` | String | Items across all 8 bag pockets: price, field/battle use, TM move, fling, Natural Gift |
| `berry_plants` | FK→items | Berry growth data: stages, hours, yield, watering bonus _(feat_berry_farming)_ |

#### Pokémon
| Table | PK type | Description |
|-------|---------|-------------|
| `pokemon_species` | String | Base species: dex number, types, abilities, gender ratio, base stats, EV yield, wild items |
| `pokemon_forms` | Composite | Alternative forms (Mega, regional, Gigantamax, …) — NULL columns inherit from base |
| `pokemon_metrics` | FK→species | Sprite pixel offsets and shadow size for the base form |
| `pokemon_form_metrics` | Composite | Per-form sprite overrides |
| `pokemon_level_moves` | Composite | Level-up learnset (level 0 = on evolution) |
| `pokemon_tutor_moves` | Composite | TM / TR / Tutor / HM compatibility |
| `pokemon_egg_moves` | Composite | Egg moves |
| `pokemon_evolutions` | Auto-int | Evolution paths with method + optional conditions (gender, time, map, …) |

#### Trainers
| Table | PK type | Description |
|-------|---------|-------------|
| `trainer_types` | String | Trainer classes: base money, AI skill level, BGM overrides, flags |
| `trainers` | Auto-int | Individual trainers: type, name, version index (rematch), item list |
| `trainer_pokemon` | Auto-int | Team Pokémon: species, level, IVs, EVs, nature, ability index |
| `trainer_pokemon_moves` | Composite | Explicit move overrides (auto-generated from learnset if absent) |
| `trainer_phone_data` | FK→trainers | Phone call texts, gift items, rematch switch IDs _(feat_phone_system)_ |

#### Maps & world
| Table | PK type | Description |
|-------|---------|-------------|
| `maps` | Integer | Map metadata: name, size, BGM, weather, rates, flags, scene path |
| `map_connections` | Auto-int | Cardinal connections between maps with tile offset |
| `encounters` | Composite | Encounter table headers (map + encounter type + density) |
| `encounter_slots` | Auto-int | Individual wild Pokémon slots with level ranges |
| `regional_dex_entries` | Composite | Pokédex ordering per region (0 = National) |
| `town_map_points` | Auto-int | Points of interest on the Town Map with icon type and Fly availability |
| `badges` | String | Badge data: region, gym map, gym leader, HM/move unlock |

#### Feature-specific
| Table | Description | Feature flag |
|-------|-------------|--------------|
| `shadow_pokemon` | Shadow Pokémon per trainer slot, heart gauge, purification map | `shadow_pokemon` |
| `battle_facilities` | Battle Frontier facility rules and streak tracking | `battle_frontier` |

### Views (4)

| View | Description |
|------|-------------|
| `v_species_full` | Species with resolved type/ability names and BST |
| `v_trainer_full` | Trainers joined with trainer type info |
| `v_encounter_full` | Encounter slots with map and species names resolved |
| `v_moves_full` | Moves with type name resolved |

### Custom indexes (16)

Performance-critical indexes on the most frequently queried columns:
`pokemon_level_moves(species_id)`, `pokemon_level_moves(species_id, level)`,
`pokemon_tutor_moves(species_id)`, `pokemon_egg_moves(species_id)`,
`pokemon_evolutions(species_id)`, `pokemon_evolutions(evolved_species_id)`,
`type_effectiveness(attacker_id)`, `type_effectiveness(defender_id)`,
`moves(type_id)`, `moves(category)`, `items(pocket)`,
`pokemon_species(generation)`, `pokemon_species(national_dex_number)`,
`trainers(type_id, name)`, `trainers(type_id, name, version_index)`,
`trainer_pokemon(trainer_id)`, `encounter_slots(map_id, encounter_type)`,
`regional_dex_entries(region_index)`, `map_connections(map_id)`.

### FK dependency chain (CREATE order)

```
db_metadata / game_settings
  └─► types
        ├─► type_effectiveness
        ├─► abilities
        │     └─► natures / ribbons
        ├─► moves
        │     ├─► z_move_data
        │     └─► move_contest_data
        └─► items
              ├─► berry_plants
              └─► pokemon_species
                    ├─► pokemon_forms
                    ├─► pokemon_metrics / pokemon_form_metrics
                    ├─► pokemon_level_moves / pokemon_tutor_moves / pokemon_egg_moves
                    ├─► pokemon_evolutions
                    └─► badges
                          └─► trainer_types
                                └─► trainers
                                      ├─► trainer_pokemon
                                      │     └─► trainer_pokemon_moves
                                      ├─► trainer_phone_data
                                      └─► shadow_pokemon
maps
  ├─► map_connections
  ├─► encounters → encounter_slots
  ├─► regional_dex_entries
  ├─► town_map_points
  └─► battle_facilities
```

---

---

## 8. PBS → SQLite Migration Tool

**File:** `tools/pbs_to_sqlite.py`

A Python 3 script that parses all Pokémon Essentials v21.1 PBS text files and populates `pokebuilder.sqlite`. It is the primary way to seed the database with real Pokémon data.

### Usage

```bash
python pbs_to_sqlite.py \
    --pbs  path/to/PokemonEssentials/PBS \
    --db   path/to/poke-builder/data/db/pokebuilder.sqlite
```

Both arguments are optional; the defaults resolve automatically relative to the script location.

### Migration result (PE v21.1 full dataset)

| Table | Rows |
|-------|-----:|
| types | 19 |
| type_effectiveness | 120 |
| abilities | 310 |
| moves | 833 |
| items | 745 |
| berry_plants | 67 |
| ribbons | 80 |
| maps | 70 |
| map_connections | 38 |
| trainer_types | 73 |
| pokemon_species | **1 025** |
| pokemon_forms | 419 |
| pokemon_metrics | 1 223 |
| pokemon_level_moves | 15 721 |
| pokemon_tutor_moves | 66 186 |
| pokemon_egg_moves | 2 933 |
| pokemon_evolutions | 471 |
| trainers | 20 |
| trainer_pokemon | 39 |
| trainer_pokemon_moves | 8 |
| encounters | 49 |
| encounter_slots | 211 |
| regional_dex_entries | 1 025 |
| **TOTAL** | **91 685** |

### Key mapping decisions

| Issue | Resolution |
|-------|-----------|
| BaseStats field order in PBS: `HP, Atk, Def, **Speed**, SpAtk, SpDef` | Remapped: index `[3]→spe`, `[4]→spa`, `[5]→spd` |
| Type chart perspective: PBS lists Weaknesses from the **defender's** view | Inverted on import: `Weaknesses=[X]` on type T → `(X, T, 2.0)` |
| `GrowthRate = Parabolic` (PE name) | Stored as `"MediumSlow"` (canonical name) |
| `SkillLevel` can exceed 5 in PBS (e.g. 32) | Clamped to `[1, 5]` to satisfy the schema `CHECK` constraint |
| PBS files use Spanish text (accent characters) | UTF-8 tried first; falls back to Latin-1 automatically |

### Tables NOT populated by the script

These tables require fangame-specific data and must be filled manually or with a dedicated editor:

`badges` · `maps` (name/BGM/scene_path beyond what map_metadata.txt provides) · `town_map_points` · `shadow_pokemon` · `battle_facilities` · `z_move_data` · `move_contest_data`

---

## 9. Save File Format

```
user://saves/slot_0.sav   (Zstd-compressed JSON)
user://saves/slot_1.sav
user://saves/slot_2.sav
```

Top-level keys: `_version`, `_slot`, `_date`, `player`, `settings`, `features`, `map_state`.

### PlayerData serialization keys

`trainer_name`, `trainer_gender`, `trainer_id`, `secret_id`, `money`, `play_time`, `party`, `pc_boxes`, `box_names`, `box_wallpapers`, `current_box`, `bag`, `pokedex_seen`, `pokedex_caught`, `badges`, `switches`, `variables`, `self_switches`, `phone_contacts`, `map_id`, `map_x`, `map_y`, `direction`.

**Party / PC boxes:** each `Pokemon` instance is serialized via `pk.serialize()` into a Dictionary. On load, `PokemonFactory.restore(dict)` reconstructs the `Pokemon` object. PC box slots that are empty are stored as `null`.

**Self-switch serialization:** Array keys `[map_id, event_id, key]` → String `"map_id,event_id,key"` (JSON-compatible).

### Pokemon serialization keys

Each Pokémon slot in `party` and `pc_boxes` serializes to:

```json
{
  "species_id": "PIKACHU",
  "form_index": 0,
  "nickname": "",
  "gender": 0,
  "is_shiny": false,
  "level": 12,
  "exp": 940,
  "nature_id": "JOLLY",
  "ability_index": 0,
  "current_hp": 38,
  "ivs": [31, 28, 22, 15, 20, 31],
  "evs": [0, 0, 0, 0, 0, 0],
  "moves": [
    {"move_id": "THUNDERBOLT", "current_pp": 15, "max_pp": 15, "pp_ups": 0}
  ],
  "status": 0,
  "sleep_turns": 0,
  "poison_turns": 0,
  "held_item_id": "LIGHTBALL",
  "happiness": 120,
  "ot_name": "Ash",
  "ot_id": 12345,
  "ot_secret_id": 54321,
  "ot_gender": 0,
  "pokeball_id": "GREATBALL",
  "met_map_id": 5,
  "met_level": 12,
  "met_date": "2026-04-12",
  "is_egg": false,
  "egg_steps": 0,
  "ribbons": [],
  "pokerus_days": 0
}
```

---

## 10. Audio System

### Bus layout (configure in Godot's Audio panel)

```
Master
├── BGM   (background music)
├── SE    (sound effects + cries)
└── ME    (jingles)
```

### File naming conventions

| Type | File name |
|------|-----------|
| BGM | Any name, e.g. `Battle wild.ogg` |
| ME | Any name, e.g. `Badge get.ogg` |
| SE | Any name, e.g. `Battle ball shake.ogg` |
| Cry (base) | `SPECIES_ID.ogg` (e.g. `PIKACHU.ogg`) |
| Cry (form N) | `SPECIES_ID_N.ogg` (e.g. `ROTOM_1.ogg`) |

---

## 11. Text & Translation System

### Translation files

Place `.po` / `.translation` files in `res://data/translations/`. Godot's `TranslationServer` loads them automatically if registered in **Project Settings → Localization → Translations**.

### Message key convention

Keys follow the pattern `CATEGORY_DESCRIPTION_VARIANT`, e.g.:
- `MSG_BATTLE_WIN`
- `MSG_CAUGHT`
- `EFF_SUPER_EFFECTIVE`
- `UI_BAG_EMPTY`

### Type effectiveness keys (used by TextManager)

`EFF_IMMUNE` · `EFF_QUARTER` · `EFF_HALF` · `EFF_DOUBLE` · `EFF_QUADRUPLE`

---

## 12. Coding Conventions

| Convention | Rule |
|------------|------|
| **Language** | All code, comments, identifiers, and documentation in **English** |
| **Variable types** | Every `var` declaration must have an explicit type annotation: `var x: int = 0` |
| **For loop variables** | Type-annotate when possible: `for item: Dictionary in list:` |
| **Function signatures** | Always annotate parameter types and return type |
| **Constants** | Use `const NAME := value` (type inferred) |
| **Signals** | Always declare parameter types: `signal foo(bar: int)` |
| **Null-safety** | Check nullable returns before use; prefer early returns |
| **No speculative abstractions** | Only abstract when there are 3+ real use cases |
| **String IDs** | Pokémon/move/item/type identifiers are UPPER_SNAKE_CASE strings |
| **File names** | `PascalCase.gd` for singletons/classes, `snake_case.gd` for utility scripts |
| **Scene names** | `PascalCase.tscn` |
| **Comments** | Explain *why*, not *what*; the code should be self-evident |

---

## 13. Planned Tools

### Database Editor (`tools/database_editor/`)

A GUI mini-app (Godot scene) for editing the SQLite database without external tools. Planned editors:

- Species editor (stats, types, learnsets, evolutions)
- Move editor
- Item editor
- Trainer editor
- Map connection editor

### Animation Creator (`tools/animation_creator/`)

Visual tool for creating move animations frame by frame, with support for Pokémon Essentials' `AnimationEditor`-style keyframe system.

---

## 14. Reference: Pokémon Essentials Equivalences

| PE concept | PokeBuilder equivalent |
|---|---|
| PBS text files (`.txt`) | SQLite database tables |
| `compile_pbs.rb` / PBS import | `tools/pbs_to_sqlite.py` |
| `GameData::Species` | `GameData._species` registry |
| `GameData::Move` | `GameData._moves` registry |
| `GameData::Nature` | `GameData._natures` registry |
| `GameData::Item` | `GameData._items` registry |
| `GameData::Map` | `GameData._maps` registry |
| `Pokemon` class (Ruby) | `Pokemon` class (`core/pokemon/Pokemon.gd`) |
| `pbNewPkmn` / `pbNewFakePkmn` | `PokemonFactory.create_wild()` |
| `pbTrainerPokemon` | `PokemonFactory.create_from_trainer_slot()` |
| `Pokemon#calcStats` | `Pokemon.calc_stats()` |
| `Pokemon#pbType` | `Pokemon.type_ids()` |
| `Pokemon#ability` | `Pokemon.current_ability_id()` |
| `Pokemon#name` | `Pokemon.full_name()` |
| `$Trainer` | `PlayerData` (trainer fields) |
| `$PokemonBag` | `PlayerData.bag` |
| `$PokemonStorage` | `PlayerData.pc_boxes` |
| `$PokemonGlobal` | `PlayerData` (position, time, dex…) |
| `$game_switches` | `PlayerData.switches` |
| `$game_variables` | `PlayerData.variables` |
| `$game_self_switches` | `PlayerData.self_switches` |
| `pbClearSelfSwitches` | Clear `PlayerData.self_switches` entries |
| `pbBGMPlay` | `AudioManager.play_bgm()` |
| `pbBGMStop` | `AudioManager.stop_bgm()` |
| `pbMEPlay` | `AudioManager.play_me()` |
| `pbSEPlay` | `AudioManager.play_se()` |
| `pbCrySE` | `AudioManager.play_cry()` |
| `pbWildBattle` | `await BattleManager.start_wild_battle()` |
| `pbTrainerBattle` | `await BattleManager.start_trainer_battle()` |
| Escape codes (`\PN`, `\TN`) | Variable markers (`[player_name]`, `[npc_name]`) |
| `_INTL("text")` | `TextManager.t("KEY")` |
| `pbFadeOutIn` | `SceneManager.goto()` with transition |
| Feature toggles (compile flags) | `GameManager.features` dictionary |
| `MetadataModule` / game_metadata | `game_settings` table → `GameManager.game_meta` |
| `pbEncounter` | `GameData.random_encounter_species()` |
| `pbGetTrainerBattleData` | `GameData.trainer_team()` |
| `Trainer` class (Ruby) | `Trainer` class (`core/trainer/Trainer.gd`) |
| `pbLoadTrainer` | `Trainer.build(type_id, name, version)` |
| `trainer.party` | `Trainer.team` (`Array[Pokemon]`) |
| `trainer.party[i].hp > 0` | `Trainer.team[i].is_alive()` |
| `trainer.party_all_fainted?` | `Trainer.all_fainted()` |
| `trainer.prize_money` | `Trainer.prize_money()` |
| `PokeBattle_Pokemon` (battle-state) | `BattlePokemon` class (`core/battle/BattlePokemon.gd`) |
| `pokemon.stages[:ATTACK]` | `BattlePokemon.stage_atk` |
| `pokemon.pbIncreaseStatWithCause` | `BattlePokemon.apply_stat_stage()` |
| `pokemon.pbResetStatStages` | `BattlePokemon.reset_volatile()` |
| `pokemon.calcType` | `BattlePokemon.effective_types()` |
| `pokemon.ability` (in battle) | `BattlePokemon.effective_ability()` |
| `PokeBattle_Battler` | `Combatant` class (`core/battle/Combatant.gd`) |
| `battler.index` | `Combatant.slot_index` |
| `battler.opposes?` | `Combatant.side != other.side` |
| `PokeBattle_Scene` / `@battle` (arena state) | `BattleField` class (`core/battle/BattleField.gd`) |
| `@battle.weather` | `BattleField.weather` |
| `@battle.field.effects[:EchocedVoice]` | `BattleField` properties (terrain, rooms, gravity) |
| `@battle.sides[i].effects[:Reflect]` | `BattleField.reflect_turns[i]` |
| `@battle.sides[i].effects[:Spikes]` | `BattleField.spikes[i]` |
| `pbClearAllSideConditions` | `BattleField.clear_entry_hazards(side)` |
| `@battle.allBattlers` | `BattleField.all_combatants()` |
| `battler.opponents` | `BattleField.opponents_of(combatant)` |
| `battler.allAllies` | `BattleField.allies_of(combatant)` |
