-- =============================================================================
-- PokeBuilder — SQLite Database Schema
-- Engine : Godot 4.6 (GDScript)
-- Addon  : godot-sqlite by 2shady4u
-- Based on: Pokémon Essentials v21.1 PBS structure
--
-- Conventions:
--   • String IDs  : UPPER_SNAKE_CASE (e.g. "BULBASAUR", "TACKLE", "FIRE")
--   • Integer IDs : auto-increment surrogate keys (maps, trainers, etc.)
--   • Booleans    : INTEGER 0/1 (SQLite has no BOOLEAN type)
--   • Nullable FK : NULL means "none" or "inherit from base form"
--   • flags field : comma-separated flag strings (e.g. "contact,sound,punch")
--
-- Creation order (respects FK dependencies):
--   db_metadata → game_settings → types → type_effectiveness
--   → abilities → natures → ribbons
--   → moves → z_move_data → move_contest_data
--   → items → berry_plants
--   → pokemon_species → pokemon_forms → pokemon_metrics
--   → pokemon_level_moves → pokemon_tutor_moves
--   → pokemon_egg_moves → pokemon_evolutions
--   → badges → trainer_types → trainers → trainer_pokemon
--   → trainer_pokemon_moves → trainer_phone_data
--   → maps → map_connections
--   → encounters → encounter_slots
--   → regional_dex_entries → town_map_points
--   → shadow_pokemon → battle_facilities
--   → indexes → views → seed data
-- =============================================================================

PRAGMA journal_mode  = WAL;
PRAGMA foreign_keys  = ON;
PRAGMA synchronous   = NORMAL;

-- =============================================================================
-- SECTION 1 — Metadata & Configuration
-- =============================================================================

-- Schema versioning and build info.
CREATE TABLE IF NOT EXISTS db_metadata (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO db_metadata VALUES ('schema_version',     '1');
INSERT OR IGNORE INTO db_metadata VALUES ('pokebuilder_version','0.1.0');
INSERT OR IGNORE INTO db_metadata VALUES ('created_at',         datetime('now'));

-- ---------------------------------------------------------------------------
-- Fangame global configuration.
-- The fangame creator writes key/value pairs here; GameManager reads them at
-- startup via RPGDatabase and populates game_meta + features.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS game_settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    -- "string" | "int" | "float" | "bool" | "json"
    type  TEXT NOT NULL DEFAULT 'string'
);

INSERT OR IGNORE INTO game_settings VALUES ('game_title',      'My FanGame',  'string');
INSERT OR IGNORE INTO game_settings VALUES ('game_version',    '1.0.0',       'string');
INSERT OR IGNORE INTO game_settings VALUES ('game_author',     '',            'string');
INSERT OR IGNORE INTO game_settings VALUES ('start_map_id',    '1',           'int');
INSERT OR IGNORE INTO game_settings VALUES ('start_x',         '7',           'int');
INSERT OR IGNORE INTO game_settings VALUES ('start_y',         '5',           'int');
INSERT OR IGNORE INTO game_settings VALUES ('start_direction', '2',           'int');
INSERT OR IGNORE INTO game_settings VALUES ('start_money',     '3000',        'int');
-- Feature flags (mirror GameManager.features defaults)
INSERT OR IGNORE INTO game_settings VALUES ('feat_mega_evolution',   'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_primal_reversion', 'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_z_moves',          'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_alolan_forms',     'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_dynamax',          'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_galarian_forms',   'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_terastallization', 'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_paldean_forms',    'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_shadow_pokemon',   'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_breeding',         'true',  'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_contests',         'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_mini_games',       'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_phone_system',     'true',  'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_berry_farming',    'true',  'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_dungeons',         'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_real_time',        'true',  'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_followers',        'false', 'bool');
INSERT OR IGNORE INTO game_settings VALUES ('feat_battle_frontier',  'false', 'bool');

-- =============================================================================
-- SECTION 2 — Types
-- =============================================================================

CREATE TABLE IF NOT EXISTS types (
    id              TEXT PRIMARY KEY,   -- "NORMAL", "FIRE", "WATER", …
    name            TEXT NOT NULL,      -- Display name (localised via TextManager)
    -- is_pseudo_type: 1 for internal types (???, Shadow) not shown in UI
    is_pseudo_type  INTEGER NOT NULL DEFAULT 0,
    -- icon_position: row index in the type icon sprite sheet
    icon_position   INTEGER NOT NULL DEFAULT 0,
    -- color_hex: 6-digit RGB hex for UI tinting (no #), e.g. "F08030"
    color_hex       TEXT    NOT NULL DEFAULT 'A8A878'
);

-- ---------------------------------------------------------------------------
-- Type effectiveness chart.
-- Only rows that deviate from 1.0 need to be stored (GameData defaults to 1.0
-- for missing combinations).
-- multiplier: 0.0 = immune, 0.5 = not very effective, 2.0 = super effective
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS type_effectiveness (
    attacker_id TEXT NOT NULL REFERENCES types(id) ON DELETE CASCADE,
    defender_id TEXT NOT NULL REFERENCES types(id) ON DELETE CASCADE,
    multiplier  REAL NOT NULL DEFAULT 1.0
        CHECK (multiplier IN (0.0, 0.25, 0.5, 1.0, 2.0, 4.0)),
    PRIMARY KEY (attacker_id, defender_id)
);

-- =============================================================================
-- SECTION 3 — Abilities
-- =============================================================================

CREATE TABLE IF NOT EXISTS abilities (
    id          TEXT PRIMARY KEY,  -- "OVERGROW", "BLAZE", "TORRENT", …
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    -- flags: comma-separated. Common values:
    --   BatonPass     — effect passes through Baton Pass
    --   NoAbilitySwap — cannot be swapped with Skill Swap
    --   CannotSupress — Gastro Acid / Neutralizing Gas cannot suppress this
    flags       TEXT NOT NULL DEFAULT ''
);

-- =============================================================================
-- SECTION 4 — Natures
-- =============================================================================

-- All 25 natures. stat_up / stat_down are NULL for the five neutral natures.
CREATE TABLE IF NOT EXISTS natures (
    id              TEXT PRIMARY KEY,  -- "HARDY", "LONELY", "BRAVE", …
    name            TEXT NOT NULL,
    -- Raised and lowered stats. Values: "atk","def","spa","spd","spe" or NULL
    stat_up         TEXT CHECK (stat_up   IN ('atk','def','spa','spd','spe',NULL)),
    stat_down       TEXT CHECK (stat_down IN ('atk','def','spa','spd','spe',NULL)),
    -- Contest flavour preferences (for Poffin / Pokéblock system)
    flavor_likes    TEXT,  -- "Spicy","Dry","Sweet","Bitter","Sour"
    flavor_dislikes TEXT
);

-- =============================================================================
-- SECTION 5 — Ribbons
-- =============================================================================

CREATE TABLE IF NOT EXISTS ribbons (
    id            TEXT PRIMARY KEY,  -- "CHAMPION", "COOLCONTEST_NORMAL", …
    name          TEXT NOT NULL,
    description   TEXT NOT NULL DEFAULT '',
    -- icon_position: index in the ribbon sprite sheet
    icon_position INTEGER NOT NULL DEFAULT 0
);

-- =============================================================================
-- SECTION 6 — Moves
-- =============================================================================

CREATE TABLE IF NOT EXISTS moves (
    id            TEXT PRIMARY KEY,  -- "TACKLE", "FLAMETHROWER", …
    name          TEXT NOT NULL,
    type_id       TEXT NOT NULL REFERENCES types(id),
    -- category: Physical / Special / Status
    category      TEXT NOT NULL DEFAULT 'Physical'
        CHECK (category IN ('Physical','Special','Status')),
    power         INTEGER NOT NULL DEFAULT 0,    -- 0 for variable or status moves
    accuracy      INTEGER NOT NULL DEFAULT 100,  -- 0 = never misses
    total_pp      INTEGER NOT NULL DEFAULT 5,
    -- target: who the move hits.
    -- Values: NearOther | NearAlly | NearFoe | UserOrNearAlly | UserOrNearFoe
    --         AllNearFoes | AllNearOthers | AllFoes | AllAllies | AllBattlers
    --         User | RandomNearFoe | UserSide | FoeSide | BothSides | None
    target        TEXT NOT NULL DEFAULT 'NearOther',
    priority      INTEGER NOT NULL DEFAULT 0,   -- speed priority bracket (-7…+7)
    -- function_code: battle effect handler name (resolved in GDScript).
    -- Mirrors PE's function codes (e.g. "002" = Struggle, "0AD" = Will-O-Wisp).
    function_code TEXT NOT NULL DEFAULT '',
    -- flags: comma-separated.
    -- Common values: contact, sound, punch, bite, dance, bullet, powder,
    --   magic_coat, snatch, gravity, mirror_move, thaw, wind, high_crit,
    --   no_sky_battles, no_metronome
    flags         TEXT NOT NULL DEFAULT '',
    -- effect_chance: probability (0–100) of the secondary effect triggering
    effect_chance INTEGER NOT NULL DEFAULT 0,
    description   TEXT NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------------------
-- Z-Move data (requires feat_z_moves = true).
-- Maps a base move to its Z-Move counterpart and the required Z-Crystal.
-- For status moves the Z-Effect is described in z_effect; z_move_id is NULL.
-- For species-specific Z-Moves, species_id restricts which Pokémon can use it.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS z_move_data (
    move_id     TEXT PRIMARY KEY REFERENCES moves(id) ON DELETE CASCADE,
    z_move_id   TEXT REFERENCES moves(id),   -- NULL for status Z-Moves
    z_crystal_id TEXT NOT NULL,              -- item ID (FK added after items)
    species_id  TEXT,                        -- NULL = any Pokémon of that type
    z_effect    TEXT NOT NULL DEFAULT ''     -- status Z-Move boost description
);

-- ---------------------------------------------------------------------------
-- Contest move data (requires feat_contests = true).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS move_contest_data (
    move_id     TEXT PRIMARY KEY REFERENCES moves(id) ON DELETE CASCADE,
    category    TEXT NOT NULL
        CHECK (category IN ('Cool','Beautiful','Cute','Clever','Tough')),
    appeal      INTEGER NOT NULL DEFAULT 0,  -- hearts gained
    jam         INTEGER NOT NULL DEFAULT 0,  -- hearts subtracted from others
    description TEXT NOT NULL DEFAULT ''
);

-- =============================================================================
-- SECTION 7 — Items
-- =============================================================================

CREATE TABLE IF NOT EXISTS items (
    id                   TEXT PRIMARY KEY,  -- "POTION", "FIRESTONE", "MASTERBALL"
    name                 TEXT NOT NULL,
    plural_name          TEXT,    -- override plural (NULL = name + "s")
    -- pocket:
    --   1 = Items (general consumables)
    --   2 = Medicine (healing)
    --   3 = Poké Balls
    --   4 = TMs & HMs
    --   5 = Berries
    --   6 = Mail
    --   7 = Battle Items (held items, herbs, vitamins, …)
    --   8 = Key Items
    pocket               INTEGER NOT NULL DEFAULT 1
        CHECK (pocket BETWEEN 1 AND 8),
    price                INTEGER NOT NULL DEFAULT 0,   -- buy price; 0 = not sold
    sell_price           INTEGER,  -- NULL = price / 2
    -- field_use: effect handler when used outside battle.
    -- Examples: HealHP, Antidote, Awakening, EvoItem, Mail, Repel, TM, …
    field_use            TEXT NOT NULL DEFAULT '',
    -- battle_use: effect handler when used in battle.
    battle_use           TEXT NOT NULL DEFAULT '',
    -- function_code: generic item effect code (PE-style, e.g. "014" = TM)
    function_code        TEXT NOT NULL DEFAULT '',
    -- For TMs / HMs: the move this item teaches
    move_id              TEXT REFERENCES moves(id),
    -- Fling (when a held item is flung at an opponent)
    fling_power          INTEGER NOT NULL DEFAULT 0,
    fling_effect         TEXT    NOT NULL DEFAULT '',
    -- Natural Gift (Pokémon move; berry-specific)
    natural_gift_power   INTEGER NOT NULL DEFAULT 0,
    natural_gift_type_id TEXT REFERENCES types(id),
    -- flags: comma-separated.
    -- Common values: HoldItem, KeyItem, Mail, BallItem, MegaStone,
    --   ZCrystal, TeraOrb, DynamaxBand, NeverHeld, QuestItem
    flags                TEXT    NOT NULL DEFAULT '',
    description          TEXT    NOT NULL DEFAULT ''
);

-- Add the Z-Crystal FK now that items exists
-- (SQLite allows forward references in FK definitions only at table creation;
--  we keep z_crystal_id as TEXT and enforce integrity at the application layer.)

-- ---------------------------------------------------------------------------
-- Berry plant data (requires feat_berry_farming = true).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS berry_plants (
    item_id          TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    growth_stages    INTEGER NOT NULL DEFAULT 4,   -- number of growth stages
    hours_per_stage  INTEGER NOT NULL DEFAULT 4,   -- real-world hours per stage
    max_yield        INTEGER NOT NULL DEFAULT 6,   -- max berries per harvest
    min_yield        INTEGER NOT NULL DEFAULT 1,
    watering_bonus   INTEGER NOT NULL DEFAULT 2,   -- extra berry per watering
    dryness_rate     INTEGER NOT NULL DEFAULT 15,  -- soil dryness rate (higher = dries faster)
    -- Contest flavour values (for Poffin / Pokéblock)
    flavor_spicy     INTEGER NOT NULL DEFAULT 0,
    flavor_sour      INTEGER NOT NULL DEFAULT 0,
    flavor_sweet     INTEGER NOT NULL DEFAULT 0,
    flavor_bitter    INTEGER NOT NULL DEFAULT 0,
    flavor_dry       INTEGER NOT NULL DEFAULT 0
);

-- =============================================================================
-- SECTION 8 — Pokémon Species
-- =============================================================================

CREATE TABLE IF NOT EXISTS pokemon_species (
    id                   TEXT PRIMARY KEY,  -- "BULBASAUR", "CHARMANDER", …
    national_dex_number  INTEGER NOT NULL UNIQUE,
    name                 TEXT    NOT NULL,
    -- category: shown in the Pokédex (e.g. "Seed Pokémon")
    category             TEXT    NOT NULL DEFAULT '',
    type1_id             TEXT    NOT NULL REFERENCES types(id),
    type2_id             TEXT    REFERENCES types(id),  -- NULL = single type
    ability1_id          TEXT    REFERENCES abilities(id),
    ability2_id          TEXT    REFERENCES abilities(id),
    hidden_ability_id    TEXT    REFERENCES abilities(id),
    -- gender_ratio: determines wild gender distribution.
    -- Values: AlwaysMale | AlwaysFemale | Genderless
    --         FemaleOneEighth | Female25Percent | Female50Percent
    --         Female75Percent | FemaleSevenEighths
    gender_ratio         TEXT    NOT NULL DEFAULT 'Female50Percent',
    catch_rate           INTEGER NOT NULL DEFAULT 45,   -- 0–255
    happiness            INTEGER NOT NULL DEFAULT 70,   -- base friendship
    exp_yield            INTEGER NOT NULL DEFAULT 64,
    -- exp_growth: Erratic | Fast | MediumFast | MediumSlow | Slow | Fluctuating
    exp_growth           TEXT    NOT NULL DEFAULT 'MediumFast',
    -- Egg groups: Monster|Water1|Bug|Flying|Field|Fairy|Grass|HumanLike
    --             Water3|Mineral|Amorphous|Water2|Ditto|Dragon|Undiscovered
    egg_group1           TEXT    NOT NULL DEFAULT 'Undiscovered',
    egg_group2           TEXT,
    egg_steps            INTEGER NOT NULL DEFAULT 5120,  -- steps to hatch one egg cycle
    -- Physical traits (for Pokédex display)
    height               REAL    NOT NULL DEFAULT 0.5,  -- metres
    weight               REAL    NOT NULL DEFAULT 6.9,  -- kilograms
    -- color: Red|Blue|Yellow|Green|Black|Brown|Purple|Gray|White|Pink
    color                TEXT    NOT NULL DEFAULT 'Red',
    -- shape: 1–14 (PE shape codes; 1=ball, 2=BallTail, … 14=MultiBody)
    shape                INTEGER NOT NULL DEFAULT 1,
    -- habitat: Grassland|Mountain|Waterside|Sea|Cave|Forest|Urban|Rare|None
    habitat              TEXT,
    generation           INTEGER NOT NULL DEFAULT 1,
    -- Base stats
    stat_hp              INTEGER NOT NULL DEFAULT 45,
    stat_atk             INTEGER NOT NULL DEFAULT 49,
    stat_def             INTEGER NOT NULL DEFAULT 49,
    stat_spa             INTEGER NOT NULL DEFAULT 65,
    stat_spd             INTEGER NOT NULL DEFAULT 65,
    stat_spe             INTEGER NOT NULL DEFAULT 45,
    -- EV yield (sum must not exceed 3 normally)
    ev_hp                INTEGER NOT NULL DEFAULT 0,
    ev_atk               INTEGER NOT NULL DEFAULT 0,
    ev_def               INTEGER NOT NULL DEFAULT 0,
    ev_spa               INTEGER NOT NULL DEFAULT 0,
    ev_spd               INTEGER NOT NULL DEFAULT 0,
    ev_spe               INTEGER NOT NULL DEFAULT 0,
    -- Wild held items (NULL = never)
    wild_item_common     TEXT REFERENCES items(id),    -- ~50 % chance
    wild_item_uncommon   TEXT REFERENCES items(id),    -- ~5 %  chance
    wild_item_rare       TEXT REFERENCES items(id),    -- ~1 %  chance
    -- Pokédex entry text
    pokedex_entry        TEXT    NOT NULL DEFAULT '',
    -- flags: comma-separated special behaviour flags.
    -- Common values: StrongRespawn, Gigantamax, Legendary, Mythical,
    --   UltraBeast, Paradox, Fossil, InfiniteExp, CannotBeNicknamed
    flags                TEXT    NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------------------
-- Alternative forms (form_index 1+; base form is pokemon_species itself).
-- NULL columns inherit the value from the base species row.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_forms (
    species_id          TEXT    NOT NULL REFERENCES pokemon_species(id) ON DELETE CASCADE,
    form_index          INTEGER NOT NULL,  -- 1, 2, 3, …
    form_name           TEXT    NOT NULL DEFAULT '',  -- "Alolan", "Mega", "Gmax", …
    type1_id            TEXT    REFERENCES types(id),
    type2_id            TEXT    REFERENCES types(id),
    ability1_id         TEXT    REFERENCES abilities(id),
    ability2_id         TEXT    REFERENCES abilities(id),
    hidden_ability_id   TEXT    REFERENCES abilities(id),
    -- Stats: NULL = inherit from base species
    stat_hp             INTEGER,
    stat_atk            INTEGER,
    stat_def            INTEGER,
    stat_spa            INTEGER,
    stat_spd            INTEGER,
    stat_spe            INTEGER,
    -- EV yield: NULL = inherit
    ev_hp               INTEGER,
    ev_atk              INTEGER,
    ev_def              INTEGER,
    ev_spa              INTEGER,
    ev_spd              INTEGER,
    ev_spe              INTEGER,
    height              REAL,
    weight              REAL,
    -- Mega Evolution (feat_mega_evolution)
    mega_stone_id       TEXT    REFERENCES items(id),
    -- Z-Move (feat_z_moves): species-specific Z-Crystal
    z_crystal_id        TEXT,
    -- Dynamax / Gigantamax (feat_dynamax)
    gigantamax_move_id  TEXT    REFERENCES moves(id),
    -- Terastallization (feat_terastallization)
    -- tera_type_id only set for forms that have a fixed Tera type (e.g. Stellar)
    tera_type_id        TEXT    REFERENCES types(id),
    -- flags: MegaEvolution | PrimalReversion | Gigantamax | AlolanForm
    --        GalarianForm | PaldeanForm | BattleBond | UltraBurst | …
    flags               TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (species_id, form_index)
);

-- ---------------------------------------------------------------------------
-- Sprite metrics — pixel offsets used to position sprites in battle.
-- One row per species (all forms share the base metrics unless overridden).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_metrics (
    species_id              TEXT    PRIMARY KEY REFERENCES pokemon_species(id) ON DELETE CASCADE,
    back_sprite_x           INTEGER NOT NULL DEFAULT 0,
    back_sprite_y           INTEGER NOT NULL DEFAULT 0,
    front_sprite_x          INTEGER NOT NULL DEFAULT 0,
    front_sprite_y          INTEGER NOT NULL DEFAULT 0,
    -- front_sprite_altitude: vertical offset (pixels) from the ground line
    front_sprite_altitude   INTEGER NOT NULL DEFAULT 0,
    -- shadow_x: horizontal offset for the shadow sprite
    shadow_x                INTEGER NOT NULL DEFAULT 0,
    -- shadow_size: 0=none, 1=small, 2=medium, 3=large
    shadow_size             INTEGER NOT NULL DEFAULT 2
        CHECK (shadow_size BETWEEN 0 AND 3)
);

-- ---------------------------------------------------------------------------
-- Form-specific sprite metrics override (optional; one row per form that
-- differs from the base species metrics).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_form_metrics (
    species_id              TEXT    NOT NULL,
    form_index              INTEGER NOT NULL,
    back_sprite_x           INTEGER NOT NULL DEFAULT 0,
    back_sprite_y           INTEGER NOT NULL DEFAULT 0,
    front_sprite_x          INTEGER NOT NULL DEFAULT 0,
    front_sprite_y          INTEGER NOT NULL DEFAULT 0,
    front_sprite_altitude   INTEGER NOT NULL DEFAULT 0,
    shadow_x                INTEGER NOT NULL DEFAULT 0,
    shadow_size             INTEGER NOT NULL DEFAULT 2
        CHECK (shadow_size BETWEEN 0 AND 3),
    PRIMARY KEY (species_id, form_index),
    FOREIGN KEY (species_id, form_index) REFERENCES pokemon_forms(species_id, form_index) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Level-up moveset.
-- level = 0 means the move is learned on evolution.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_level_moves (
    species_id  TEXT    NOT NULL REFERENCES pokemon_species(id) ON DELETE CASCADE,
    level       INTEGER NOT NULL,
    move_id     TEXT    NOT NULL REFERENCES moves(id),
    PRIMARY KEY (species_id, level, move_id)
);

-- ---------------------------------------------------------------------------
-- TM / tutor / HM compatible moves.
-- tutor_type: "TM" | "TR" | "Tutor" | "HM"
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_tutor_moves (
    species_id  TEXT NOT NULL REFERENCES pokemon_species(id) ON DELETE CASCADE,
    move_id     TEXT NOT NULL REFERENCES moves(id),
    tutor_type  TEXT NOT NULL DEFAULT 'TM'
        CHECK (tutor_type IN ('TM','TR','Tutor','HM')),
    PRIMARY KEY (species_id, move_id)
);

-- ---------------------------------------------------------------------------
-- Egg moves (learned only by hatching when a parent knows the move).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_egg_moves (
    species_id  TEXT NOT NULL REFERENCES pokemon_species(id) ON DELETE CASCADE,
    move_id     TEXT NOT NULL REFERENCES moves(id),
    PRIMARY KEY (species_id, move_id)
);

-- ---------------------------------------------------------------------------
-- Evolution table.
-- Each row is one possible evolution path for a species.
--
-- method examples (PE-style, resolved in GDScript):
--   Level             — reach a specific level
--   LevelDay / LevelNight / LevelMorning
--   LevelHappiness / LevelHappinessDay / LevelHappinessNight
--   Item / ItemDay / ItemNight / ItemHappiness
--   Trade / TradeItem / TradeSpecies
--   Move / MoveType
--   Location          — evolve on a specific map
--   Beauty            — high beauty stat (Feebas)
--   HasMove           — know a specific move at level-up
--   EvolvedInParty    — another party member evolved
--   AnyDaytime / AnyNighttime
--   HighAtk / EqualAtkDef / HighDef  — Tyrogue branch
--   ShedSkin / Ninjask                — Nincada split
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pokemon_evolutions (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    species_id          TEXT    NOT NULL REFERENCES pokemon_species(id) ON DELETE CASCADE,
    evolved_species_id  TEXT    NOT NULL REFERENCES pokemon_species(id),
    evolved_form_index  INTEGER NOT NULL DEFAULT 0,
    method              TEXT    NOT NULL,
    -- parameter: the value associated with the method (level number, item ID,
    -- move ID, location name, beauty value, …). NULL if not applicable.
    parameter           TEXT,
    -- Optional extra conditions (all must be met simultaneously)
    gender              INTEGER CHECK (gender IN (0, 1, NULL)),  -- 0=male, 1=female
    time_of_day         TEXT    CHECK (time_of_day IN ('Day','Night','Dusk',NULL)),
    map_id              INTEGER REFERENCES maps(id),  -- must be on this map (FK resolved later)
    party_species_id    TEXT    REFERENCES pokemon_species(id),
    party_type_id       TEXT    REFERENCES types(id),
    trade_species_id    TEXT    REFERENCES pokemon_species(id),
    held_item_id        TEXT    REFERENCES items(id),
    required_move_id    TEXT    REFERENCES moves(id),
    min_level           INTEGER,  -- minimum level (combined conditions)
    min_happiness       INTEGER,
    min_beauty          INTEGER,
    min_affection       INTEGER,
    region              TEXT    -- region name string (e.g. "Alola")
);

-- =============================================================================
-- SECTION 9 — Badges
-- =============================================================================

CREATE TABLE IF NOT EXISTS badges (
    id          TEXT    PRIMARY KEY,  -- "BOULDER", "CASCADE", …
    name        TEXT    NOT NULL,     -- "Boulder Badge"
    region      INTEGER NOT NULL DEFAULT 0,   -- which regional dex this badge belongs to
    position    INTEGER NOT NULL DEFAULT 0,   -- display order within the region
    description TEXT    NOT NULL DEFAULT '',
    map_id      INTEGER,              -- gym map ID (FK added after maps)
    trainer_id  INTEGER,              -- gym leader trainer ID (FK added after trainers)
    -- move_unlock: HM/move that can be used outside battle after obtaining this badge
    move_unlock TEXT    REFERENCES moves(id),
    -- icon_path: res:// path to the badge icon sprite
    icon_path   TEXT    NOT NULL DEFAULT ''
);

-- =============================================================================
-- SECTION 10 — Trainers
-- =============================================================================

CREATE TABLE IF NOT EXISTS trainer_types (
    id           TEXT    PRIMARY KEY,  -- "YOUNGSTER", "LEADER_Brock", …
    name         TEXT    NOT NULL,     -- "Youngster", "Gym Leader"
    -- base_money: multiplied by the highest-level Pokémon to give prize money
    base_money   INTEGER NOT NULL DEFAULT 30,
    -- skill_level: AI difficulty 1–5
    skill_level  INTEGER NOT NULL DEFAULT 1
        CHECK (skill_level BETWEEN 1 AND 5),
    -- BGM overrides (NULL = use map / global default)
    battle_bgm   TEXT,
    victory_bgm  TEXT,
    -- intro_bgm: VS fanfare played before the battle starts
    intro_bgm    TEXT,
    -- flags: comma-separated.
    -- Common values: GymLeader | EliteFour | Champion | Rival | Evil
    --   Frontier | Double | Multi | Safari | BugContest | Ace
    flags        TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS trainers (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    type_id        TEXT    NOT NULL REFERENCES trainer_types(id),
    name           TEXT    NOT NULL,
    -- version_index: 0 = initial battle, 1+ = rematches (higher level teams)
    version_index  INTEGER NOT NULL DEFAULT 0,
    -- items: up to 4 battle items the trainer can use (comma-separated item IDs)
    items          TEXT    NOT NULL DEFAULT '',
    -- Dialogue shown after winning / losing
    lose_text      TEXT,
    win_text       TEXT,
    -- reward_money: NULL = auto-calculated from trainer_type.base_money × highest level
    reward_money   INTEGER,
    UNIQUE (type_id, name, version_index)
);

-- Individual Pokémon on a trainer's team (up to 6).
CREATE TABLE IF NOT EXISTS trainer_pokemon (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    trainer_id     INTEGER NOT NULL REFERENCES trainers(id) ON DELETE CASCADE,
    position       INTEGER NOT NULL,  -- slot 0–5
    species_id     TEXT    NOT NULL REFERENCES pokemon_species(id),
    form_index     INTEGER NOT NULL DEFAULT 0,
    level          INTEGER NOT NULL DEFAULT 5,
    -- gender: NULL = determined by gender ratio
    gender         INTEGER CHECK (gender IN (0, 1, NULL)),
    shiny          INTEGER NOT NULL DEFAULT 0,
    -- ability_index: 0=first ability, 1=second, 2=hidden
    ability_index  INTEGER NOT NULL DEFAULT 0
        CHECK (ability_index IN (0, 1, 2)),
    nature         TEXT    REFERENCES natures(id),  -- NULL = random
    held_item_id   TEXT    REFERENCES items(id),
    -- IVs: NULL = auto from trainer skill_level (skill 1=0, 2=10, 3=20, 4=25, 5=31)
    iv_hp          INTEGER CHECK (iv_hp  BETWEEN 0 AND 31),
    iv_atk         INTEGER CHECK (iv_atk BETWEEN 0 AND 31),
    iv_def         INTEGER CHECK (iv_def BETWEEN 0 AND 31),
    iv_spa         INTEGER CHECK (iv_spa BETWEEN 0 AND 31),
    iv_spd         INTEGER CHECK (iv_spd BETWEEN 0 AND 31),
    iv_spe         INTEGER CHECK (iv_spe BETWEEN 0 AND 31),
    -- EVs: 0–252 per stat, max 510 total
    ev_hp          INTEGER NOT NULL DEFAULT 0 CHECK (ev_hp  BETWEEN 0 AND 252),
    ev_atk         INTEGER NOT NULL DEFAULT 0 CHECK (ev_atk BETWEEN 0 AND 252),
    ev_def         INTEGER NOT NULL DEFAULT 0 CHECK (ev_def BETWEEN 0 AND 252),
    ev_spa         INTEGER NOT NULL DEFAULT 0 CHECK (ev_spa BETWEEN 0 AND 252),
    ev_spd         INTEGER NOT NULL DEFAULT 0 CHECK (ev_spd BETWEEN 0 AND 252),
    ev_spe         INTEGER NOT NULL DEFAULT 0 CHECK (ev_spe BETWEEN 0 AND 252),
    happiness      INTEGER,
    nickname       TEXT,
    -- shadow: 1 if this is a Shadow Pokémon (feat_shadow_pokemon)
    shadow         INTEGER NOT NULL DEFAULT 0,
    UNIQUE (trainer_id, position)
);

-- Explicit move overrides for a trainer's Pokémon.
-- If no rows exist for a trainer_pokemon_id, moves are auto-generated
-- from the species learnset at the given level.
CREATE TABLE IF NOT EXISTS trainer_pokemon_moves (
    trainer_pokemon_id INTEGER NOT NULL REFERENCES trainer_pokemon(id) ON DELETE CASCADE,
    position           INTEGER NOT NULL,  -- slot 0–3
    move_id            TEXT    NOT NULL REFERENCES moves(id),
    PRIMARY KEY (trainer_pokemon_id, position)
);

-- Phone / rematch data for trainers (requires feat_phone_system).
CREATE TABLE IF NOT EXISTS trainer_phone_data (
    trainer_id           INTEGER PRIMARY KEY REFERENCES trainers(id) ON DELETE CASCADE,
    -- Text shown when the player calls and nothing is happening
    call_text_idle       TEXT,
    -- Text shown when the trainer challenges to a rematch
    call_text_battle     TEXT,
    -- Item the trainer gives when called (berry, etc.)
    gift_item_id         TEXT    REFERENCES items(id),
    -- Game switch ID that enables rematch availability
    rematch_enabled_flag INTEGER,
    -- Game switch ID set after the player calls this trainer
    after_call_flag      INTEGER
);

-- =============================================================================
-- SECTION 11 — Maps
-- =============================================================================

CREATE TABLE IF NOT EXISTS maps (
    id                   INTEGER PRIMARY KEY,  -- must match the Godot scene reference
    name                 TEXT    NOT NULL,     -- "Pallet Town"
    -- display_name: text shown on-screen when entering the area.
    -- NULL = use name. "" = show nothing.
    display_name         TEXT,
    width                INTEGER NOT NULL DEFAULT 20,  -- tiles
    height               INTEGER NOT NULL DEFAULT 15,  -- tiles
    -- Music (NULL = inherit from connected area or use global default)
    bgm                  TEXT,
    bgs                  TEXT,   -- background ambient sound (rain, cave rumble, …)
    battle_bgm           TEXT,   -- wild battle BGM override
    trainer_bgm          TEXT,   -- trainer battle BGM override
    -- Encounter rates (avg steps between encounters; 0 = no encounters)
    land_rate            INTEGER NOT NULL DEFAULT 0,
    water_rate           INTEGER NOT NULL DEFAULT 0,
    cave_rate            INTEGER NOT NULL DEFAULT 0,
    -- Environment flags
    outdoor              INTEGER NOT NULL DEFAULT 1,   -- 0 = indoor
    dark_map             INTEGER NOT NULL DEFAULT 0,   -- 1 = needs Flash/Bright Powder
    safari_zone          INTEGER NOT NULL DEFAULT 0,
    -- Weather (None|Sun|Rain|Sandstorm|Hail|Blizzard|SteamyMist|Fog|Storm)
    weather_type         TEXT    NOT NULL DEFAULT 'None',
    weather_strength     INTEGER NOT NULL DEFAULT 0    -- intensity 0–100
        CHECK (weather_strength BETWEEN 0 AND 100),
    -- Gameplay flags
    -- bicycle: 1 = can ride bicycle
    -- teleport: 1 = can use Fly / Teleport to reach this map
    -- escape_rope: 1 = can use Escape Rope / Dig
    -- healing: 1 = there is a healing spot on this map
    -- no_run: 1 = cannot flee from wild battles
    -- underwater: 1 = underwater map (Dive destination)
    -- dungeon: 1 = procedurally generated (feat_dungeons)
    flags                TEXT    NOT NULL DEFAULT '',
    -- Godot scene resource path for this map's .tscn file
    scene_path           TEXT,
    -- Town map data
    town_map_x           INTEGER,
    town_map_y           INTEGER,
    town_map_region      INTEGER NOT NULL DEFAULT 0,
    -- Tileset used (references the Godot tileset resource, informational only)
    tileset_id           INTEGER NOT NULL DEFAULT 0
);

-- Now we can add the FK for pokemon_evolutions.map_id
-- (SQLite does not enforce FK at ALTER TABLE, handled at app layer)

-- Add FK for badges (after maps and trainers are created)
-- badges.map_id → maps.id and badges.trainer_id → trainers.id
-- enforced at application layer since SQLite cannot add FKs via ALTER TABLE.

CREATE TABLE IF NOT EXISTS map_connections (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    map_id            INTEGER NOT NULL REFERENCES maps(id) ON DELETE CASCADE,
    -- direction: North|South|East|West (cardinal) or
    --            NorthWall|SouthWall|EastWall|WestWall (wall-to-wall)
    direction         TEXT    NOT NULL
        CHECK (direction IN ('North','South','East','West',
                             'NorthWall','SouthWall','EastWall','WestWall')),
    connected_map_id  INTEGER NOT NULL REFERENCES maps(id),
    -- offset: tile offset along the connection edge
    --   positive = shifted right/down; negative = shifted left/up
    offset            INTEGER NOT NULL DEFAULT 0
);

-- =============================================================================
-- SECTION 12 — Wild Encounters
-- =============================================================================

-- One row per (map, encounter_type) combination that has encounters.
-- encounter_type values:
--   Land | LandMorning | LandDay | LandAfternoon | LandNight
--   Cave | Water | Waterfall
--   OldRod | GoodRod | SuperRod
--   RockSmash | Headbutt | HeadbuttLow | HeadbuttHigh
--   Bug (Bug-Catching Contest)
CREATE TABLE IF NOT EXISTS encounters (
    map_id          INTEGER NOT NULL REFERENCES maps(id) ON DELETE CASCADE,
    encounter_type  TEXT    NOT NULL,
    -- density: affects step counter speed for this encounter type
    density         INTEGER NOT NULL DEFAULT 25
        CHECK (density BETWEEN 1 AND 100),
    PRIMARY KEY (map_id, encounter_type)
);

-- Individual slots within an encounter table.
-- Slot weights follow PE defaults (slot 0 = most common, slot 11 = rarest).
CREATE TABLE IF NOT EXISTS encounter_slots (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    map_id          INTEGER NOT NULL,
    encounter_type  TEXT    NOT NULL,
    slot_index      INTEGER NOT NULL,   -- 0–11 for Land, 0–4 for Rod, etc.
    species_id      TEXT    NOT NULL REFERENCES pokemon_species(id),
    form_index      INTEGER NOT NULL DEFAULT 0,
    min_level       INTEGER NOT NULL DEFAULT 2,
    max_level       INTEGER NOT NULL DEFAULT 5,
    FOREIGN KEY (map_id, encounter_type) REFERENCES encounters(map_id, encounter_type) ON DELETE CASCADE,
    UNIQUE (map_id, encounter_type, slot_index)
);

-- =============================================================================
-- SECTION 13 — World Data
-- =============================================================================

-- Regional Pokédex ordering.
-- region_index 0 = National Dex; 1+ = regional dexes in fangame order.
CREATE TABLE IF NOT EXISTS regional_dex_entries (
    region_index  INTEGER NOT NULL,
    position      INTEGER NOT NULL,   -- Pokédex number within the region
    species_id    TEXT    NOT NULL REFERENCES pokemon_species(id),
    PRIMARY KEY (region_index, position)
);

-- Points of interest shown on the Town Map.
CREATE TABLE IF NOT EXISTS town_map_points (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    region_index  INTEGER NOT NULL DEFAULT 0,
    name          TEXT    NOT NULL,
    -- icon_type: Town|City|Route|Sea|Cave|Forest|MountainPath|Dungeon|
    --            Airport|Port|PokemonCenter|Gym|Shop|Landmark
    icon_type     TEXT    NOT NULL DEFAULT 'Town',
    -- primary map for this point (clicking it warps/describes this map)
    map_id        INTEGER REFERENCES maps(id),
    position_x    INTEGER NOT NULL,
    position_y    INTEGER NOT NULL,
    visible       INTEGER NOT NULL DEFAULT 1,
    -- fly_destination: 1 if the player can Fly to this point
    fly_destination INTEGER NOT NULL DEFAULT 0
);

-- =============================================================================
-- SECTION 14 — Feature-Specific Tables
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shadow Pokémon (feat_shadow_pokemon)
-- Defines which Pokémon in a trainer's team are Shadow Pokémon and their data.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shadow_pokemon (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    trainer_id          INTEGER NOT NULL REFERENCES trainers(id) ON DELETE CASCADE,
    trainer_position    INTEGER NOT NULL,   -- which slot in trainer's team
    heart_gauge_size    INTEGER NOT NULL DEFAULT 1500,
    -- shadow_moves: comma-separated list of Shadow move IDs (up to 4)
    shadow_moves        TEXT    NOT NULL DEFAULT '',
    -- purification_map_id: map where the Pokémon can be purified (optional)
    purification_map_id INTEGER REFERENCES maps(id),
    UNIQUE (trainer_id, trainer_position)
);

-- ---------------------------------------------------------------------------
-- Battle Frontier / Facilities (feat_battle_frontier)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS battle_facilities (
    id          TEXT    PRIMARY KEY,  -- "TOWER", "FACTORY", "PALACE", "ARENA", …
    name        TEXT    NOT NULL,
    map_id      INTEGER REFERENCES maps(id),
    -- rules: JSON object or comma-separated flags describing facility rules
    -- e.g. "rental,no_items,set_style,level50"
    rules       TEXT    NOT NULL DEFAULT '',
    -- max_streak: highest win streak the game tracks (0 = unlimited)
    max_streak  INTEGER NOT NULL DEFAULT 0
);

-- =============================================================================
-- SECTION 15 — Indexes
-- =============================================================================

-- Pokémon learnsets — the most frequent queries in the game
CREATE INDEX IF NOT EXISTS idx_level_moves_species
    ON pokemon_level_moves (species_id);
CREATE INDEX IF NOT EXISTS idx_level_moves_species_level
    ON pokemon_level_moves (species_id, level);
CREATE INDEX IF NOT EXISTS idx_tutor_moves_species
    ON pokemon_tutor_moves (species_id);
CREATE INDEX IF NOT EXISTS idx_egg_moves_species
    ON pokemon_egg_moves (species_id);
CREATE INDEX IF NOT EXISTS idx_evolutions_species
    ON pokemon_evolutions (species_id);
CREATE INDEX IF NOT EXISTS idx_evolutions_target
    ON pokemon_evolutions (evolved_species_id);

-- Type chart — looked up by both columns
CREATE INDEX IF NOT EXISTS idx_type_chart_attacker
    ON type_effectiveness (attacker_id);
CREATE INDEX IF NOT EXISTS idx_type_chart_defender
    ON type_effectiveness (defender_id);

-- Moves — filtered by type in AI calculations
CREATE INDEX IF NOT EXISTS idx_moves_type
    ON moves (type_id);
CREATE INDEX IF NOT EXISTS idx_moves_category
    ON moves (category);

-- Items — filtered by pocket in bag display
CREATE INDEX IF NOT EXISTS idx_items_pocket
    ON items (pocket);

-- Species — filtered by generation in Pokédex
CREATE INDEX IF NOT EXISTS idx_species_generation
    ON pokemon_species (generation);
CREATE INDEX IF NOT EXISTS idx_species_dex_number
    ON pokemon_species (national_dex_number);

-- Trainers — looked up by type+name (most common trainer query)
CREATE INDEX IF NOT EXISTS idx_trainers_type_name
    ON trainers (type_id, name);
CREATE INDEX IF NOT EXISTS idx_trainers_version
    ON trainers (type_id, name, version_index);

-- Trainer Pokémon — looked up by trainer
CREATE INDEX IF NOT EXISTS idx_trainer_pokemon_trainer
    ON trainer_pokemon (trainer_id);

-- Encounters — looked up by map+type
CREATE INDEX IF NOT EXISTS idx_encounter_slots_map_type
    ON encounter_slots (map_id, encounter_type);

-- Regional dex — looked up by region
CREATE INDEX IF NOT EXISTS idx_regional_dex_region
    ON regional_dex_entries (region_index);

-- Map connections — looked up by source map
CREATE INDEX IF NOT EXISTS idx_map_connections_map
    ON map_connections (map_id);

-- =============================================================================
-- SECTION 16 — Views
-- =============================================================================

-- ---------------------------------------------------------------------------
-- v_species_full: species with all derived names resolved.
-- Useful for the database editor tool.
-- ---------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_species_full AS
SELECT
    s.id,
    s.national_dex_number,
    s.name,
    s.category,
    s.type1_id,
    t1.name         AS type1_name,
    s.type2_id,
    t2.name         AS type2_name,
    s.ability1_id,
    a1.name         AS ability1_name,
    s.ability2_id,
    a2.name         AS ability2_name,
    s.hidden_ability_id,
    ah.name         AS hidden_ability_name,
    s.stat_hp,
    s.stat_atk,
    s.stat_def,
    s.stat_spa,
    s.stat_spd,
    s.stat_spe,
    (s.stat_hp + s.stat_atk + s.stat_def +
     s.stat_spa + s.stat_spd + s.stat_spe) AS bst,
    s.catch_rate,
    s.exp_yield,
    s.exp_growth,
    s.egg_group1,
    s.egg_group2,
    s.gender_ratio,
    s.generation,
    s.flags
FROM pokemon_species s
LEFT JOIN types     t1 ON t1.id = s.type1_id
LEFT JOIN types     t2 ON t2.id = s.type2_id
LEFT JOIN abilities a1 ON a1.id = s.ability1_id
LEFT JOIN abilities a2 ON a2.id = s.ability2_id
LEFT JOIN abilities ah ON ah.id = s.hidden_ability_id;

-- ---------------------------------------------------------------------------
-- v_trainer_full: trainers joined with their type info.
-- ---------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_trainer_full AS
SELECT
    t.id,
    t.type_id,
    tt.name         AS type_name,
    t.name,
    t.version_index,
    tt.skill_level,
    tt.flags        AS type_flags,
    t.items,
    t.lose_text,
    t.win_text,
    t.reward_money
FROM trainers t
JOIN trainer_types tt ON tt.id = t.type_id;

-- ---------------------------------------------------------------------------
-- v_encounter_full: encounter slots with species names resolved.
-- ---------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_encounter_full AS
SELECT
    es.map_id,
    m.name          AS map_name,
    es.encounter_type,
    es.slot_index,
    es.species_id,
    sp.name         AS species_name,
    es.form_index,
    es.min_level,
    es.max_level
FROM encounter_slots es
JOIN maps            m  ON m.id  = es.map_id
JOIN pokemon_species sp ON sp.id = es.species_id;

-- ---------------------------------------------------------------------------
-- v_moves_full: moves with type and category info resolved.
-- ---------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_moves_full AS
SELECT
    mv.id,
    mv.name,
    mv.type_id,
    t.name          AS type_name,
    mv.category,
    mv.power,
    mv.accuracy,
    mv.total_pp,
    mv.priority,
    mv.target,
    mv.function_code,
    mv.flags,
    mv.effect_chance,
    mv.description
FROM moves mv
JOIN types t ON t.id = mv.type_id;

-- =============================================================================
-- SECTION 17 — Seed Data: Natures
-- =============================================================================

INSERT OR IGNORE INTO natures VALUES
-- Neutral natures (no stat change, no flavour preference)
('HARDY',   'Hardy',   NULL,  NULL,  NULL,     NULL),
('DOCILE',  'Docile',  NULL,  NULL,  NULL,     NULL),
('SERIOUS', 'Serious', NULL,  NULL,  NULL,     NULL),
('BASHFUL', 'Bashful', NULL,  NULL,  NULL,     NULL),
('QUIRKY',  'Quirky',  NULL,  NULL,  NULL,     NULL),
-- +atk natures
('LONELY',  'Lonely',  'atk', 'def', 'Spicy',  'Sour'),
('BRAVE',   'Brave',   'atk', 'spe', 'Spicy',  'Sweet'),
('ADAMANT', 'Adamant', 'atk', 'spa', 'Spicy',  'Dry'),
('NAUGHTY', 'Naughty', 'atk', 'spd', 'Spicy',  'Bitter'),
-- +def natures
('BOLD',    'Bold',    'def', 'atk', 'Sour',   'Spicy'),
('RELAXED', 'Relaxed', 'def', 'spe', 'Sour',   'Sweet'),
('IMPISH',  'Impish',  'def', 'spa', 'Sour',   'Dry'),
('LAX',     'Lax',     'def', 'spd', 'Sour',   'Bitter'),
-- +spa natures
('MODEST',  'Modest',  'spa', 'atk', 'Dry',    'Spicy'),
('MILD',    'Mild',    'spa', 'def', 'Dry',    'Sour'),
('QUIET',   'Quiet',   'spa', 'spe', 'Dry',    'Sweet'),
('RASH',    'Rash',    'spa', 'spd', 'Dry',    'Bitter'),
-- +spd natures
('CALM',    'Calm',    'spd', 'atk', 'Bitter', 'Spicy'),
('GENTLE',  'Gentle',  'spd', 'def', 'Bitter', 'Sour'),
('SASSY',   'Sassy',   'spd', 'spe', 'Bitter', 'Sweet'),
('CAREFUL', 'Careful', 'spd', 'spa', 'Bitter', 'Dry'),
-- +spe natures
('TIMID',   'Timid',   'spe', 'atk', 'Sweet',  'Spicy'),
('HASTY',   'Hasty',   'spe', 'def', 'Sweet',  'Sour'),
('JOLLY',   'Jolly',   'spe', 'spa', 'Sweet',  'Dry'),
('NAIVE',   'Naive',   'spe', 'spd', 'Sweet',  'Bitter');
