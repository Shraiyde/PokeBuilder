#!/usr/bin/env python3
"""
pbs_to_sqlite.py — Migra datos de Pokémon Essentials v21.1 (PBS) a pokebuilder.sqlite

Uso:
    python pbs_to_sqlite.py [--pbs <ruta>] [--db <ruta>]

Valores por defecto:
    Directorio PBS : ../../../PokemonEssentials/PBS  (relativo a este script)
    Base de datos  : ../data/db/pokebuilder.sqlite

Tablas que se rellenan (en orden):
    types · type_effectiveness · abilities · moves · items · berry_plants
    · ribbons · maps · map_connections · trainer_types · pokemon_species
    · pokemon_forms · pokemon_metrics · pokemon_level_moves
    · pokemon_tutor_moves · pokemon_egg_moves · pokemon_evolutions
    · trainers · trainer_pokemon · trainer_pokemon_moves
    · encounters · encounter_slots · regional_dex_entries

Notas sobre el formato PBS de PE v21.1:
    - BaseStats (pokemon.txt): HP, Atk, Def, **Speed**, SpAtk, SpDef
      (Speed está en el índice 3, no al final)
    - El gráfico de tipos está en perspectiva del DEFENSOR:
      Weaknesses/Resistances/Immunities → se invierte al insertar
    - GrowthRate "Parabolic" se convierte en "MediumSlow"
    - skill_level se recorta a [1,5] para respetar el CHECK del esquema
"""

import argparse
import re
import sqlite3
import sys
from pathlib import Path

# =============================================================================
# Rutas por defecto
# =============================================================================

SCRIPT_DIR: Path = Path(__file__).parent
DEFAULT_PBS: Path = SCRIPT_DIR / "../../../PokemonEssentials/PBS"
DEFAULT_DB:  Path = SCRIPT_DIR / "../data/db/pokebuilder.sqlite"

# =============================================================================
# Tablas de conversión
# =============================================================================

GROWTH_RATE_MAP: dict[str, str] = {
    "Erratic":     "Erratic",
    "Fast":        "Fast",
    "MediumFast":  "MediumFast",
    "Medium":      "MediumFast",   # alias antiguo
    "Parabolic":   "MediumSlow",   # nombre en PE v21
    "MediumSlow":  "MediumSlow",
    "Slow":        "Slow",
    "Fluctuating": "Fluctuating",
}

SHAPE_MAP: dict[str, int] = {
    "Round":       1,
    "BallTail":    2,
    "Blob":        3,
    "Bipedal":     4,
    "BipedalTail": 5,
    "Humanoid":    6,
    "MultiWing":   7,
    "Wings":       7,
    "Quadruped":   8,
    "MultiBody":   9,
    "Multiple":    9,
    "MultiLimb":   10,
    "Fish":        11,
    "Serpentine":  12,
    "WingedFish":  13,
    "Finned":      14,
}

# EVs en PBS: "HP","ATTACK","DEFENSE","SPEED","SPECIAL_ATTACK","SPECIAL_DEFENSE"
EV_STAT_MAP: dict[str, str] = {
    "HP":               "ev_hp",
    "ATTACK":           "ev_atk",
    "DEFENSE":          "ev_def",
    "SPEED":            "ev_spe",
    "SPECIAL_ATTACK":   "ev_spa",
    "SPECIAL_DEFENSE":  "ev_spd",
}

DIRECTION_MAP: dict[str, str] = {
    "N": "North",
    "S": "South",
    "E": "East",
    "W": "West",
}

GENDER_MAP: dict[str, int] = {
    "male":   0, "Male":   0, "MALE":   0,
    "female": 1, "Female": 1, "FEMALE": 1,
}

# Tipos de encuentro reconocidos en encounters.txt
ENCOUNTER_TYPES: set[str] = {
    "Land", "LandMorning", "LandDay", "LandAfternoon", "LandNight",
    "Cave", "Water", "Waterfall",
    "OldRod", "GoodRod", "SuperRod",
    "RockSmash", "Headbutt", "HeadbuttLow", "HeadbuttHigh",
    "Bug", "PokeRadar",
}

# =============================================================================
# Utilidades de lectura
# =============================================================================

def read_file(path: Path) -> str:
    """Lee un archivo probando UTF-8 y cayendo a Latin-1 si falla."""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="latin-1")


def parse_pbs_sections(text: str) -> list[tuple[str, dict[str, str]]]:
    """
    Parsea un archivo PBS en una lista de (section_id, {campo: valor}).
    Los comentarios (#) y las líneas vacías se ignoran.
    Las cabeceras tienen el formato: [IDENTIFIER]  # comentario opcional
    """
    sections: list[tuple[str, dict[str, str]]] = []
    current_id:     str | None     = None
    current_fields: dict[str, str] = {}

    for raw in text.splitlines():
        line: str = raw.strip()
        if not line:
            continue

        # Cabecera de sección
        header_m = re.match(r'^\[([^\]]+)\]', line)
        if header_m:
            if current_id is not None:
                sections.append((current_id, current_fields))
            current_id     = header_m.group(1).strip()
            current_fields = {}
            continue

        if line.startswith('#'):
            continue

        if '=' in line:
            key: str
            val: str
            key, _, val = line.partition('=')
            val = re.sub(r'\s*#.*$', '', val)   # quita comentarios inline
            key = key.strip()
            val = val.strip()
            if key:
                current_fields[key] = val

    if current_id is not None:
        sections.append((current_id, current_fields))

    return sections


def csv_split(s: str) -> list[str]:
    """Divide una cadena separada por comas, eliminando espacios."""
    return [p.strip() for p in s.split(',') if p.strip()] if s else []


def safe_int(s: str | None, default: int = 0) -> int:
    try:
        return int(str(s).strip())
    except (ValueError, TypeError):
        return default


def safe_float(s: str | None, default: float = 0.0) -> float:
    try:
        return float(str(s).strip())
    except (ValueError, TypeError):
        return default


def clamp(val: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, val))

# =============================================================================
# Migradores por tabla
# =============================================================================

def migrate_types(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "types.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    type_rows: list[tuple] = []
    eff_rows:  list[tuple] = []   # (attacker_id, defender_id, multiplier)

    for tid, fields in sections:
        name:       str = fields.get("Name", tid.capitalize())
        icon_pos:   int = safe_int(fields.get("IconPosition", "0"))
        is_pseudo:  int = 1 if fields.get("IsPseudoType", "false").lower() == "true" else 0
        color_hex:  str = fields.get("ColorHex", "A8A878")
        type_rows.append((tid, name, is_pseudo, icon_pos, color_hex))

        # El PBS lista el chart desde la perspectiva del DEFENSOR.
        # Invertimos: "X es debilidad de T" → (X ataca a T) = 2.0
        for attacker in csv_split(fields.get("Weaknesses",  "")):
            eff_rows.append((attacker, tid, 2.0))
        for attacker in csv_split(fields.get("Resistances", "")):
            eff_rows.append((attacker, tid, 0.5))
        for attacker in csv_split(fields.get("Immunities",  "")):
            eff_rows.append((attacker, tid, 0.0))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM type_effectiveness")
    cur.execute("DELETE FROM types")
    cur.executemany(
        "INSERT OR IGNORE INTO types(id, name, is_pseudo_type, icon_position, color_hex)"
        " VALUES (?,?,?,?,?)",
        type_rows,
    )
    # Solo se almacenan filas que difieren de 1.0 (el valor por defecto en GameData)
    non_normal: list[tuple] = [(a, d, m) for a, d, m in eff_rows if m != 1.0]
    cur.executemany(
        "INSERT OR IGNORE INTO type_effectiveness(attacker_id, defender_id, multiplier)"
        " VALUES (?,?,?)",
        non_normal,
    )
    con.commit()
    print(f"  types: {len(type_rows)} filas | type_effectiveness: {len(non_normal)} filas")


def migrate_abilities(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "abilities.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for aid, fields in sections:
        name:  str = fields.get("Name",        aid)
        desc:  str = fields.get("Description", "")
        flags: str = fields.get("Flags",       "")
        rows.append((aid, name, desc, flags))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM abilities")
    cur.executemany(
        "INSERT OR IGNORE INTO abilities(id, name, description, flags) VALUES (?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  abilities: {len(rows)} filas")


def migrate_moves(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "moves.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for mid, fields in sections:
        name:          str = fields.get("Name",         mid)
        type_id:       str = fields.get("Type",         "NORMAL")
        category:      str = fields.get("Category",     "Physical")
        power:         int = safe_int(fields.get("Power",        "0"))
        accuracy:      int = safe_int(fields.get("Accuracy",     "100"))
        total_pp:      int = safe_int(fields.get("TotalPP",      "5"))
        target:        str = fields.get("Target",       "NearOther")
        priority:      int = safe_int(fields.get("Priority",     "0"))
        func_code:     str = fields.get("FunctionCode", "")
        if func_code == "None":
            func_code = ""
        # Normaliza flags a minúsculas y sin espacios
        raw_flags:     str = fields.get("Flags", "")
        flags:         str = ",".join(f.strip().lower() for f in raw_flags.split(",") if f.strip())
        effect_chance: int = safe_int(fields.get("EffectChance", "0"))
        description:   str = fields.get("Description",  "")
        rows.append((mid, name, type_id, category, power, accuracy, total_pp,
                     target, priority, func_code, flags, effect_chance, description))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM moves")
    cur.executemany(
        "INSERT OR IGNORE INTO moves"
        "(id, name, type_id, category, power, accuracy, total_pp,"
        " target, priority, function_code, flags, effect_chance, description)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  moves: {len(rows)} filas")


def migrate_items(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "items.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for iid, fields in sections:
        name:        str       = fields.get("Name",     iid)
        plural:      str | None = fields.get("NamePlural", None) or None
        pocket:      int       = clamp(safe_int(fields.get("Pocket", "1")), 1, 8)
        price:       int       = safe_int(fields.get("Price",   "0"))
        sell_raw:    str | None = fields.get("SellPrice", None)
        sell_price:  int | None = safe_int(sell_raw) if sell_raw else None
        field_use:   str       = fields.get("FieldUse",  "")
        battle_use:  str       = fields.get("BattleUse", "")
        func_code:   str       = fields.get("FunctionCode", "")
        move_id:     str | None = fields.get("Move", None) or None
        fling_eff:   str       = fields.get("FlingEffect", "")
        ng_power:    int       = safe_int(fields.get("NaturalGiftPower", "0"))
        ng_type:     str | None = fields.get("NaturalGiftType", None) or None

        # Extrae Fling_XX del campo Flags
        fling_power: int = 0
        clean_flags: list[str] = []
        for f in fields.get("Flags", "").split(","):
            f = f.strip()
            if f.startswith("Fling_"):
                fling_power = safe_int(f[6:])
            elif f:
                clean_flags.append(f)
        flags: str = ",".join(clean_flags)

        description: str = fields.get("Description", "")
        rows.append((iid, name, plural, pocket, price, sell_price,
                     field_use, battle_use, func_code, move_id,
                     fling_power, fling_eff, ng_power, ng_type, flags, description))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM items")
    cur.executemany(
        "INSERT OR IGNORE INTO items"
        "(id, name, plural_name, pocket, price, sell_price,"
        " field_use, battle_use, function_code, move_id,"
        " fling_power, fling_effect, natural_gift_power, natural_gift_type_id,"
        " flags, description)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  items: {len(rows)} filas")


def migrate_berry_plants(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "berry_plants.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for bid, fields in sections:
        hours:      int = safe_int(fields.get("HoursPerStage", "4"))
        drying:     int = safe_int(fields.get("DryingPerHour", "15"))
        yield_parts: list[str] = csv_split(fields.get("Yield", "1,6"))
        min_yield:  int = safe_int(yield_parts[0]) if len(yield_parts) > 0 else 1
        max_yield:  int = safe_int(yield_parts[1]) if len(yield_parts) > 1 else min_yield
        # growth_stages=4, watering_bonus=2 son los valores estándar de PE
        rows.append((bid, 4, hours, max_yield, min_yield, 2, drying, 0, 0, 0, 0, 0))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM berry_plants")
    cur.executemany(
        "INSERT OR IGNORE INTO berry_plants"
        "(item_id, growth_stages, hours_per_stage, max_yield, min_yield,"
        " watering_bonus, dryness_rate,"
        " flavor_spicy, flavor_sour, flavor_sweet, flavor_bitter, flavor_dry)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  berry_plants: {len(rows)} filas")


def migrate_ribbons(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "ribbons.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for rid, fields in sections:
        name:     str = fields.get("Name",         rid)
        desc:     str = fields.get("Description",  "")
        icon_pos: int = safe_int(fields.get("IconPosition", "0"))
        rows.append((rid, name, desc, icon_pos))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM ribbons")
    cur.executemany(
        "INSERT OR IGNORE INTO ribbons(id, name, description, icon_position)"
        " VALUES (?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  ribbons: {len(rows)} filas")


def migrate_maps(con: sqlite3.Connection, pbs: Path) -> None:
    """Parsea map_metadata.txt para obtener IDs, nombres y datos básicos de mapa."""
    path: Path = pbs / "map_metadata.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    text: str = read_file(path)
    rows: list[tuple] = []

    current_id:     int | None     = None
    current_name:   str            = ""
    current_fields: dict[str, str] = {}

    for raw in text.splitlines():
        line: str = raw.strip()
        if not line:
            continue

        # Cabecera: [001]  # Nombre del mapa
        header_m = re.match(r'^\[(\d+)\]\s*(?:#\s*(.*))?$', line)
        if header_m:
            if current_id is not None:
                rows.append(_build_map_row(current_id, current_name, current_fields))
            current_id     = safe_int(header_m.group(1))
            current_name   = (header_m.group(2) or "").strip()
            current_fields = {}
            continue

        if line.startswith('#'):
            continue

        if '=' in line:
            key: str
            val: str
            key, _, val = line.partition('=')
            key = re.sub(r'\s*#.*$', '', key).strip()
            val = re.sub(r'\s*#.*$', '', val).strip()
            if key:
                current_fields[key] = val

    if current_id is not None:
        rows.append(_build_map_row(current_id, current_name, current_fields))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM maps")
    cur.executemany(
        "INSERT OR IGNORE INTO maps(id, name, outdoor, town_map_x, town_map_y, town_map_region)"
        " VALUES (?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  maps: {len(rows)} filas")


def _build_map_row(map_id: int, name: str, fields: dict[str, str]) -> tuple:
    outdoor: int = 1 if fields.get("Outdoor", "false").lower() == "true" else 0
    pos_raw: list[str] = csv_split(fields.get("MapPosition", ""))
    region:  int = safe_int(pos_raw[0]) if len(pos_raw) > 0 else 0
    map_x:   int = safe_int(pos_raw[1]) if len(pos_raw) > 1 else 0
    map_y:   int = safe_int(pos_raw[2]) if len(pos_raw) > 2 else 0
    return (map_id, name, outdoor, map_x, map_y, region)


def migrate_map_connections(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "map_connections.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    text: str = read_file(path)
    rows: list[tuple] = []

    for raw in text.splitlines():
        line: str = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts: list[str] = csv_split(line)
        if len(parts) < 6:
            continue
        map_a:   int = safe_int(parts[0])
        dir_a:   str = DIRECTION_MAP.get(parts[1].upper(), parts[1])
        offset_a: int = safe_int(parts[2])
        map_b:   int = safe_int(parts[3])
        dir_b:   str = DIRECTION_MAP.get(parts[4].upper(), parts[4])
        offset_b: int = safe_int(parts[5])
        rows.append((map_a, dir_a, map_b, offset_a))
        rows.append((map_b, dir_b, map_a, offset_b))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM map_connections")
    cur.executemany(
        "INSERT OR IGNORE INTO map_connections(map_id, direction, connected_map_id, offset)"
        " VALUES (?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  map_connections: {len(rows)} filas")


def migrate_trainer_types(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "trainer_types.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for ttid, fields in sections:
        name:        str       = fields.get("Name", ttid)
        base_money:  int       = safe_int(fields.get("BaseMoney",  "30"))
        # Recortar a [1,5] por el CHECK del esquema (PE puede tener valores mayores)
        skill_level: int       = clamp(safe_int(fields.get("SkillLevel", "1")), 1, 5)
        battle_bgm:  str | None = fields.get("BattleBGM",  None) or None
        victory_bgm: str | None = fields.get("VictoryBGM", None) or None
        intro_bgm:   str | None = fields.get("IntroBGM",   None) or None
        flags:       str       = fields.get("Flags", "")
        rows.append((ttid, name, base_money, skill_level, battle_bgm, victory_bgm, intro_bgm, flags))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM trainer_types")
    cur.executemany(
        "INSERT OR IGNORE INTO trainer_types"
        "(id, name, base_money, skill_level, battle_bgm, victory_bgm, intro_bgm, flags)"
        " VALUES (?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  trainer_types: {len(rows)} filas")


def migrate_pokemon(con: sqlite3.Connection, pbs: Path) -> None:
    """
    Parsea pokemon.txt → pokemon_species, pokemon_level_moves,
    pokemon_tutor_moves, pokemon_egg_moves, pokemon_evolutions.

    IMPORTANTE — BaseStats en PBS: HP, Atk, Def, Speed, SpAtk, SpDef
    DB:                             hp, atk, def, spa,   spd,   spe
    Remapeo:  idx[3]→spe · idx[4]→spa · idx[5]→spd
    """
    path: Path = pbs / "pokemon.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))

    species_rows:    list[tuple] = []
    level_move_rows: list[tuple] = []
    tutor_move_rows: list[tuple] = []
    egg_move_rows:   list[tuple] = []
    evolution_rows:  list[tuple] = []

    # El número del Pokédex Nacional se infiere por orden de aparición en el archivo
    dex_number: int = 0

    for sid, fields in sections:
        dex_number += 1
        name: str = fields.get("Name", sid)

        # Tipos
        types: list[str] = csv_split(fields.get("Types", "NORMAL"))
        type1: str       = types[0] if len(types) > 0 else "NORMAL"
        type2: str | None = types[1] if len(types) > 1 else None

        # BaseStats (PBS: HP, Atk, Def, Speed, SpAtk, SpDef)
        stat_parts: list[str] = csv_split(fields.get("BaseStats", "45,45,45,45,45,45"))
        if len(stat_parts) >= 6:
            stat_hp:  int = safe_int(stat_parts[0])
            stat_atk: int = safe_int(stat_parts[1])
            stat_def: int = safe_int(stat_parts[2])
            stat_spe: int = safe_int(stat_parts[3])   # Speed → spe
            stat_spa: int = safe_int(stat_parts[4])   # SpAtk → spa
            stat_spd: int = safe_int(stat_parts[5])   # SpDef → spd
        else:
            stat_hp = stat_atk = stat_def = stat_spa = stat_spd = stat_spe = 45

        # EVs: "STAT,valor,STAT,valor,..."
        ev_hp: int = 0
        ev_atk: int = 0
        ev_def: int = 0
        ev_spa: int = 0
        ev_spd: int = 0
        ev_spe: int = 0
        ev_raw: list[str] = csv_split(fields.get("EVs", ""))
        for i in range(0, len(ev_raw) - 1, 2):
            stat_name: str     = ev_raw[i].upper()
            ev_val:    int     = safe_int(ev_raw[i + 1])
            col:       str | None = EV_STAT_MAP.get(stat_name)
            if   col == "ev_hp":  ev_hp  = ev_val
            elif col == "ev_atk": ev_atk = ev_val
            elif col == "ev_def": ev_def = ev_val
            elif col == "ev_spa": ev_spa = ev_val
            elif col == "ev_spd": ev_spd = ev_val
            elif col == "ev_spe": ev_spe = ev_val

        gender_ratio: str = fields.get("GenderRatio", "Female50Percent")
        catch_rate:   int = safe_int(fields.get("CatchRate",  "45"))
        happiness:    int = safe_int(fields.get("Happiness",  "70"))
        exp_yield:    int = safe_int(fields.get("BaseExp",    "64"))
        exp_growth:   str = GROWTH_RATE_MAP.get(fields.get("GrowthRate", "MediumFast"), "MediumFast")

        # Habilidades
        abilities:  list[str] = csv_split(fields.get("Abilities",       ""))
        hidden_abs: list[str] = csv_split(fields.get("HiddenAbilities", ""))
        ab1: str | None = abilities[0]  if len(abilities)  > 0 else None
        ab2: str | None = abilities[1]  if len(abilities)  > 1 else None
        hab: str | None = hidden_abs[0] if len(hidden_abs) > 0 else None

        # Grupos huevo
        egg_groups: list[str] = csv_split(fields.get("EggGroups", "Undiscovered"))
        egg1: str       = egg_groups[0] if len(egg_groups) > 0 else "Undiscovered"
        egg2: str | None = egg_groups[1] if len(egg_groups) > 1 else None
        egg_steps: int  = safe_int(fields.get("HatchSteps", "5120"))

        height:    float     = safe_float(fields.get("Height",  "0.5"))
        weight:    float     = safe_float(fields.get("Weight",  "6.9"))
        color:     str       = fields.get("Color",   "Red")
        shape:     int       = SHAPE_MAP.get(fields.get("Shape", "Round"), 1)
        habitat:   str | None = fields.get("Habitat", None) or None
        generation: int      = safe_int(fields.get("Generation", "1"))
        category:  str       = fields.get("Category", "")
        pokedex:   str       = fields.get("Pokedex",  "")
        flags:     str       = fields.get("Flags",    "")

        wild_common:    str | None = fields.get("WildItemCommon",    None) or None
        wild_uncommon:  str | None = fields.get("WildItemUncommon",  None) or None
        wild_rare:      str | None = fields.get("WildItemRare",      None) or None

        species_rows.append((
            sid, dex_number, name, category,
            type1, type2, ab1, ab2, hab,
            gender_ratio, catch_rate, happiness, exp_yield, exp_growth,
            egg1, egg2, egg_steps,
            height, weight, color, shape, habitat, generation,
            stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe,
            ev_hp,  ev_atk,  ev_def,  ev_spa,  ev_spd,  ev_spe,
            wild_common, wild_uncommon, wild_rare,
            pokedex, flags,
        ))

        # Movimientos por nivel: "nivel,MOVE_ID,nivel,MOVE_ID,..."
        moves_raw: list[str] = csv_split(fields.get("Moves", ""))
        seen_lm: set[tuple] = set()
        for i in range(0, len(moves_raw) - 1, 2):
            lvl: int = safe_int(moves_raw[i])
            mid: str = moves_raw[i + 1]
            key: tuple = (sid, lvl, mid)
            if key not in seen_lm:
                seen_lm.add(key)
                level_move_rows.append((sid, lvl, mid))

        # Movimientos tutor/MT
        for tmid in csv_split(fields.get("TutorMoves", "")):
            tutor_move_rows.append((sid, tmid, "TM"))

        # Movimientos huevo
        for emid in csv_split(fields.get("EggMoves", "")):
            egg_move_rows.append((sid, emid))

        # Evoluciones: "ESPECIE,MÉTODO,PARÁMETRO,..." (tripletes)
        evo_raw: list[str] = csv_split(fields.get("Evolutions", ""))
        for i in range(0, len(evo_raw) - 2, 3):
            evolved_id:  str      = evo_raw[i]
            method:      str      = evo_raw[i + 1]
            param:       str | None = evo_raw[i + 2] if evo_raw[i + 2] else None
            evolution_rows.append((sid, evolved_id, 0, method, param))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM pokemon_evolutions")
    cur.execute("DELETE FROM pokemon_egg_moves")
    cur.execute("DELETE FROM pokemon_tutor_moves")
    cur.execute("DELETE FROM pokemon_level_moves")
    cur.execute("DELETE FROM pokemon_species")

    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_species"
        "(id, national_dex_number, name, category,"
        " type1_id, type2_id, ability1_id, ability2_id, hidden_ability_id,"
        " gender_ratio, catch_rate, happiness, exp_yield, exp_growth,"
        " egg_group1, egg_group2, egg_steps,"
        " height, weight, color, shape, habitat, generation,"
        " stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe,"
        " ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,"
        " wild_item_common, wild_item_uncommon, wild_item_rare,"
        " pokedex_entry, flags)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        species_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_level_moves(species_id, level, move_id)"
        " VALUES (?,?,?)",
        level_move_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_tutor_moves(species_id, move_id, tutor_type)"
        " VALUES (?,?,?)",
        tutor_move_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_egg_moves(species_id, move_id) VALUES (?,?)",
        egg_move_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_evolutions"
        "(species_id, evolved_species_id, evolved_form_index, method, parameter)"
        " VALUES (?,?,?,?,?)",
        evolution_rows,
    )
    con.commit()
    print(f"  pokemon_species:    {len(species_rows)} filas")
    print(f"  pokemon_level_moves:{len(level_move_rows)} filas")
    print(f"  pokemon_tutor_moves:{len(tutor_move_rows)} filas")
    print(f"  pokemon_egg_moves:  {len(egg_move_rows)} filas")
    print(f"  pokemon_evolutions: {len(evolution_rows)} filas")


def migrate_pokemon_forms(con: sqlite3.Connection, pbs: Path) -> None:
    """
    Parsea pokemon_forms.txt → pokemon_forms.
    Las secciones tienen formato [SPECIES_ID,form_index].
    BaseStats siguen el mismo orden que en pokemon.txt (idx[3]=Speed).
    Los campos NULL heredan el valor de la especie base.
    """
    path: Path = pbs / "pokemon_forms.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []

    for sec_id, fields in sections:
        parts: list[str] = [p.strip() for p in sec_id.split(",")]
        if len(parts) < 2:
            continue
        species_id: str = parts[0]
        form_index: int = safe_int(parts[1])

        form_name:  str       = fields.get("FormName", "")
        mega_stone: str | None = fields.get("MegaStone", None) or None

        types: list[str] = csv_split(fields.get("Types", ""))
        type1: str | None = types[0] if len(types) > 0 else None
        type2: str | None = types[1] if len(types) > 1 else None

        abilities:  list[str] = csv_split(fields.get("Abilities",       ""))
        hidden_abs: list[str] = csv_split(fields.get("HiddenAbilities", ""))
        ab1: str | None = abilities[0]  if len(abilities)  > 0 else None
        ab2: str | None = abilities[1]  if len(abilities)  > 1 else None
        hab: str | None = hidden_abs[0] if len(hidden_abs) > 0 else None

        # BaseStats: igual remapeo que en pokemon.txt
        stat_parts: list[str] = csv_split(fields.get("BaseStats", ""))
        if len(stat_parts) >= 6:
            f_hp:  int | None = safe_int(stat_parts[0])
            f_atk: int | None = safe_int(stat_parts[1])
            f_def: int | None = safe_int(stat_parts[2])
            f_spe: int | None = safe_int(stat_parts[3])
            f_spa: int | None = safe_int(stat_parts[4])
            f_spd: int | None = safe_int(stat_parts[5])
        else:
            f_hp = f_atk = f_def = f_spa = f_spd = f_spe = None

        h_str: str = fields.get("Height", "")
        w_str: str = fields.get("Weight", "")
        height: float | None = safe_float(h_str) if h_str else None
        weight: float | None = safe_float(w_str) if w_str else None

        # Flags: si hay MegaStone y el PBS no proporciona flags, añadimos MegaEvolution
        flags: str = fields.get("Flags", "")
        if not flags and mega_stone:
            flags = "MegaEvolution"

        rows.append((
            species_id, form_index, form_name,
            type1, type2, ab1, ab2, hab,
            f_hp, f_atk, f_def, f_spa, f_spd, f_spe,
            None, None, None, None, None, None,   # ev_* (hereda de la especie base)
            height, weight,
            mega_stone, None, None, None,          # mega_stone, z_crystal, gmax_move, tera_type
            flags,
        ))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM pokemon_forms")
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_forms"
        "(species_id, form_index, form_name,"
        " type1_id, type2_id, ability1_id, ability2_id, hidden_ability_id,"
        " stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe,"
        " ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,"
        " height, weight,"
        " mega_stone_id, z_crystal_id, gigantamax_move_id, tera_type_id,"
        " flags)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  pokemon_forms: {len(rows)} filas")


def migrate_pokemon_metrics(con: sqlite3.Connection, pbs: Path) -> None:
    path: Path = pbs / "pokemon_metrics.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    sections: list[tuple[str, dict[str, str]]] = parse_pbs_sections(read_file(path))
    rows: list[tuple] = []
    for sid, fields in sections:
        back_raw:  list[str] = csv_split(fields.get("BackSprite",  "0,0"))
        front_raw: list[str] = csv_split(fields.get("FrontSprite", "0,0"))
        back_x:    int = safe_int(back_raw[0])  if len(back_raw)  > 0 else 0
        back_y:    int = safe_int(back_raw[1])  if len(back_raw)  > 1 else 0
        front_x:   int = safe_int(front_raw[0]) if len(front_raw) > 0 else 0
        front_y:   int = safe_int(front_raw[1]) if len(front_raw) > 1 else 0
        shadow_x:  int = safe_int(fields.get("ShadowX",   "0"))
        shadow_sz: int = clamp(safe_int(fields.get("ShadowSize", "2")), 0, 3)
        rows.append((sid, back_x, back_y, front_x, front_y, 0, shadow_x, shadow_sz))

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM pokemon_metrics")
    cur.executemany(
        "INSERT OR IGNORE INTO pokemon_metrics"
        "(species_id, back_sprite_x, back_sprite_y, front_sprite_x, front_sprite_y,"
        " front_sprite_altitude, shadow_x, shadow_size)"
        " VALUES (?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    print(f"  pokemon_metrics: {len(rows)} filas")


def migrate_trainers(con: sqlite3.Connection, pbs: Path) -> None:
    """
    Parsea trainers.txt → trainers, trainer_pokemon, trainer_pokemon_moves.

    Formato de sección: [TIPO_ID,Nombre] o [TIPO_ID,Nombre,version]
    Los sub-campos de cada Pokémon están indentados con espacios o tabuladores.
    """
    path: Path = pbs / "trainers.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    text: str = read_file(path)

    # ── Parseo ──────────────────────────────────────────────────────────────
    trainers_data: list[dict] = []
    current_trainer: dict | None = None
    current_pokemon: dict | None = None

    for raw in text.splitlines():
        stripped: str = raw.strip()
        if not stripped or stripped.startswith('#'):
            continue

        header_m = re.match(r'^\[([^\]]+)\]', stripped)
        if header_m:
            # Vuelca el estado anterior
            if current_pokemon is not None and current_trainer is not None:
                current_trainer["pokemon"].append(current_pokemon)
                current_pokemon = None
            if current_trainer is not None:
                trainers_data.append(current_trainer)

            parts: list[str] = [p.strip() for p in header_m.group(1).split(",")]
            current_trainer = {
                "type_id":       parts[0] if len(parts) > 0 else "",
                "name":          parts[1] if len(parts) > 1 else "",
                "version_index": safe_int(parts[2]) if len(parts) > 2 else 0,
                "items":         "",
                "lose_text":     None,
                "pokemon":       [],
            }
            continue

        if '=' not in stripped:
            continue

        key: str
        val: str
        key, _, val = stripped.partition('=')
        key = key.strip()
        val = re.sub(r'\s*#.*$', '', val).strip()

        if current_trainer is None:
            continue

        is_indented: bool = raw[0] in (' ', '\t') if raw else False

        if key == "Pokemon":
            if current_pokemon is not None:
                current_trainer["pokemon"].append(current_pokemon)
            pk_parts: list[str] = csv_split(val)
            current_pokemon = {
                "species_id":    pk_parts[0] if len(pk_parts) > 0 else "",
                "level":         safe_int(pk_parts[1]) if len(pk_parts) > 1 else 5,
                "moves":         [],
                "ability_index": 0,
                "gender":        None,
                "form":          0,
                "iv":            None,
                "item":          None,
                "shiny":         0,
                "nickname":      None,
                "shadow":        0,
            }
        elif is_indented and current_pokemon is not None:
            if   key == "Moves":        current_pokemon["moves"]         = csv_split(val)
            elif key == "AbilityIndex": current_pokemon["ability_index"] = clamp(safe_int(val), 0, 2)
            elif key == "Gender":       current_pokemon["gender"]        = GENDER_MAP.get(val.strip())
            elif key == "Form":         current_pokemon["form"]          = safe_int(val)
            elif key == "IV":           current_pokemon["iv"]            = csv_split(val)
            elif key == "Item":         current_pokemon["item"]          = val
            elif key == "Shiny":        current_pokemon["shiny"]         = 1 if val.lower() == "true" else 0
            elif key == "Name":         current_pokemon["nickname"]      = val
            elif key == "Shadow":       current_pokemon["shadow"]        = 1 if val.lower() == "true" else 0
        else:
            if   key == "LoseText": current_trainer["lose_text"] = val
            elif key == "Items":    current_trainer["items"]     = val

    # Vuelca el último entrenador
    if current_pokemon is not None and current_trainer is not None:
        current_trainer["pokemon"].append(current_pokemon)
    if current_trainer is not None:
        trainers_data.append(current_trainer)

    # ── Inserción ────────────────────────────────────────────────────────────
    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM trainer_pokemon_moves")
    cur.execute("DELETE FROM trainer_pokemon")
    cur.execute("DELETE FROM trainers")

    trainer_count: int = 0
    pokemon_count: int = 0
    move_count:    int = 0

    for td in trainers_data:
        try:
            cur.execute(
                "INSERT OR IGNORE INTO trainers(type_id, name, version_index, items, lose_text)"
                " VALUES (?,?,?,?,?)",
                (td["type_id"], td["name"], td["version_index"], td["items"], td["lose_text"]),
            )
            # Obtener el ID (tanto si se acaba de insertar como si ya existía)
            row = cur.execute(
                "SELECT id FROM trainers WHERE type_id=? AND name=? AND version_index=?",
                (td["type_id"], td["name"], td["version_index"]),
            ).fetchone()
            if row is None:
                continue
            trainer_id: int = row[0]
            trainer_count += 1

            for pos, pk in enumerate(td["pokemon"]):
                ivs:    list[str] = pk["iv"] if pk["iv"] else []
                iv_hp:  int | None = safe_int(ivs[0]) if len(ivs) > 0 else None
                iv_atk: int | None = safe_int(ivs[1]) if len(ivs) > 1 else None
                iv_def: int | None = safe_int(ivs[2]) if len(ivs) > 2 else None
                iv_spa: int | None = safe_int(ivs[3]) if len(ivs) > 3 else None
                iv_spd: int | None = safe_int(ivs[4]) if len(ivs) > 4 else None
                iv_spe: int | None = safe_int(ivs[5]) if len(ivs) > 5 else None

                cur.execute(
                    "INSERT OR IGNORE INTO trainer_pokemon"
                    "(trainer_id, position, species_id, form_index, level,"
                    " gender, shiny, ability_index, held_item_id,"
                    " iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,"
                    " nickname, shadow)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (trainer_id, pos,
                     pk["species_id"], pk["form"], pk["level"],
                     pk["gender"], pk["shiny"], pk["ability_index"], pk["item"],
                     iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
                     pk["nickname"], pk["shadow"]),
                )
                tp_id: int = cur.lastrowid
                pokemon_count += 1

                for mpos, mid in enumerate(pk["moves"][:4]):
                    cur.execute(
                        "INSERT OR IGNORE INTO trainer_pokemon_moves"
                        "(trainer_pokemon_id, position, move_id) VALUES (?,?,?)",
                        (tp_id, mpos, mid),
                    )
                    move_count += 1

            con.commit()

        except Exception as exc:
            print(f"    [WARN] Entrenador {td.get('type_id','?')}/{td.get('name','?')}: {exc}")
            con.rollback()

    print(f"  trainers:               {trainer_count} filas")
    print(f"  trainer_pokemon:        {pokemon_count} filas")
    print(f"  trainer_pokemon_moves:  {move_count} filas")


def migrate_encounters(con: sqlite3.Connection, pbs: Path) -> None:
    """
    Parsea encounters.txt → encounters, encounter_slots.

    Formato:
        [map_id] o [map_id,version]
        TipoEncuentro[,densidad]     ← línea SIN indentación
            peso,ESPECIE,min[,max]   ← línea CON indentación
    """
    path: Path = pbs / "encounters.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    text: str = read_file(path)
    encounter_rows: list[tuple] = []
    slot_rows:      list[tuple] = []

    current_map_id:   int | None = None
    current_enc_type: str | None = None
    slot_index:       int        = 0

    for raw in text.splitlines():
        stripped: str = raw.strip()
        if not stripped or stripped.startswith('#'):
            continue

        # Cabecera de mapa: [map_id] o [map_id,version]
        header_m = re.match(r'^\[(\d+)(?:,\d+)?\]', stripped)
        if header_m:
            current_map_id   = safe_int(header_m.group(1))
            current_enc_type = None
            slot_index       = 0
            continue

        if current_map_id is None:
            continue

        # Línea de tipo de encuentro (sin indentación): "Land,21" / "OldRod"
        first_token: str = stripped.split(",")[0].strip()
        if first_token in ENCOUNTER_TYPES and not raw[0].isspace():
            current_enc_type = first_token
            parts: list[str] = stripped.split(",")
            density: int     = clamp(safe_int(parts[1].strip()) if len(parts) > 1 else 25, 1, 100)
            slot_index = 0
            encounter_rows.append((current_map_id, current_enc_type, density))
            continue

        # Línea de slot (indentada): "peso,ESPECIE,min[,max]"
        if current_enc_type is not None and raw and raw[0].isspace():
            parts = csv_split(stripped)
            if len(parts) < 3:
                continue
            species_id: str = parts[1]
            min_lvl:    int = safe_int(parts[2])
            max_lvl:    int = safe_int(parts[3]) if len(parts) > 3 else min_lvl
            slot_rows.append((current_map_id, current_enc_type, slot_index,
                               species_id, 0, min_lvl, max_lvl))
            slot_index += 1

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM encounter_slots")
    cur.execute("DELETE FROM encounters")
    cur.executemany(
        "INSERT OR IGNORE INTO encounters(map_id, encounter_type, density) VALUES (?,?,?)",
        encounter_rows,
    )
    cur.executemany(
        "INSERT OR IGNORE INTO encounter_slots"
        "(map_id, encounter_type, slot_index, species_id, form_index, min_level, max_level)"
        " VALUES (?,?,?,?,?,?,?)",
        slot_rows,
    )
    con.commit()
    print(f"  encounters:      {len(encounter_rows)} filas")
    print(f"  encounter_slots: {len(slot_rows)} filas")


def migrate_regional_dexes(con: sqlite3.Connection, pbs: Path) -> None:
    """
    Parsea regional_dexes.txt → regional_dex_entries.
    Sección [índice_región] seguida de un ID de especie por línea.
    """
    path: Path = pbs / "regional_dexes.txt"
    if not path.exists():
        print(f"  [SKIP] {path.name} no encontrado")
        return

    text: str = read_file(path)
    rows: list[tuple] = []
    current_region: int = 0
    position:       int = 1

    for raw in text.splitlines():
        stripped: str = raw.strip()
        if not stripped or stripped.startswith('#'):
            continue

        header_m = re.match(r'^\[(\d+)\]', stripped)
        if header_m:
            current_region = safe_int(header_m.group(1))
            position       = 1
            continue

        rows.append((current_region, position, stripped))
        position += 1

    cur: sqlite3.Cursor = con.cursor()
    cur.execute("DELETE FROM regional_dex_entries")
    cur.executemany(
        "INSERT OR IGNORE INTO regional_dex_entries(region_index, position, species_id)"
        " VALUES (?,?,?)",
        rows,
    )
    con.commit()
    print(f"  regional_dex_entries: {len(rows)} filas")

# =============================================================================
# Verificación final
# =============================================================================

VERIFY_TABLES: list[str] = [
    "types", "type_effectiveness", "abilities", "moves", "items",
    "berry_plants", "ribbons", "maps", "map_connections",
    "trainer_types",
    "pokemon_species", "pokemon_forms", "pokemon_metrics",
    "pokemon_level_moves", "pokemon_tutor_moves", "pokemon_egg_moves",
    "pokemon_evolutions",
    "trainers", "trainer_pokemon", "trainer_pokemon_moves",
    "encounters", "encounter_slots", "regional_dex_entries",
]


def print_verification(con: sqlite3.Connection) -> None:
    cur: sqlite3.Cursor = con.cursor()
    print()
    print("─" * 50)
    print("VERIFICACIÓN DE FILAS")
    print("─" * 50)
    total: int = 0
    for table in VERIFY_TABLES:
        count: int = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table:<32} {count:>6} filas")
        total += count
    print("─" * 50)
    print(f"  {'TOTAL':<32} {total:>6} filas")

# =============================================================================
# Main
# =============================================================================

def main() -> None:
    # Forzar UTF-8 en stdout para evitar errores con caracteres especiales en Windows
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")

    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        description="Migra PBS de Pokémon Essentials v21.1 a pokebuilder.sqlite"
    )
    parser.add_argument("--pbs", default=str(DEFAULT_PBS), help="Ruta al directorio PBS")
    parser.add_argument("--db",  default=str(DEFAULT_DB),  help="Ruta a la base de datos SQLite")
    args: argparse.Namespace = parser.parse_args()

    pbs_dir: Path = Path(args.pbs).resolve()
    db_path: Path = Path(args.db).resolve()

    if not pbs_dir.exists():
        print(f"ERROR: Directorio PBS no encontrado: {pbs_dir}", file=sys.stderr)
        sys.exit(1)
    if not db_path.exists():
        print(f"ERROR: Base de datos no encontrada: {db_path}", file=sys.stderr)
        sys.exit(1)

    print(f"PBS : {pbs_dir}")
    print(f"DB  : {db_path}")
    print()

    con: sqlite3.Connection = sqlite3.connect(db_path)
    # Las FKs se desactivan durante la importación masiva para permitir
    # cualquier orden de inserción. Se reactivarán al reconectar en Godot.
    con.execute("PRAGMA foreign_keys  = OFF")
    con.execute("PRAGMA journal_mode  = WAL")
    con.execute("PRAGMA synchronous   = NORMAL")
    con.execute("PRAGMA cache_size    = -32000")  # 32 MB caché

    try:
        print("── Tipos ──────────────────────────────────────────")
        migrate_types(con, pbs_dir)

        print("── Habilidades ────────────────────────────────────")
        migrate_abilities(con, pbs_dir)

        print("── Movimientos ────────────────────────────────────")
        migrate_moves(con, pbs_dir)

        print("── Objetos ────────────────────────────────────────")
        migrate_items(con, pbs_dir)

        print("── Bayas (berry_plants) ───────────────────────────")
        migrate_berry_plants(con, pbs_dir)

        print("── Cintas (ribbons) ───────────────────────────────")
        migrate_ribbons(con, pbs_dir)

        print("── Mapas ──────────────────────────────────────────")
        migrate_maps(con, pbs_dir)

        print("── Conexiones de mapa ─────────────────────────────")
        migrate_map_connections(con, pbs_dir)

        print("── Tipos de entrenador ────────────────────────────")
        migrate_trainer_types(con, pbs_dir)

        print("── Pokémon (especies) ─────────────────────────────")
        migrate_pokemon(con, pbs_dir)

        print("── Formas alternativas ────────────────────────────")
        migrate_pokemon_forms(con, pbs_dir)

        print("── Métricas de sprite ─────────────────────────────")
        migrate_pokemon_metrics(con, pbs_dir)

        print("── Entrenadores ───────────────────────────────────")
        migrate_trainers(con, pbs_dir)

        print("── Encuentros ─────────────────────────────────────")
        migrate_encounters(con, pbs_dir)

        print("── Pokédex regionales ─────────────────────────────")
        migrate_regional_dexes(con, pbs_dir)

        print()
        print("✓ Migración completada.")
        print_verification(con)

    except Exception as exc:
        con.rollback()
        print(f"\nERROR FATAL: {exc}", file=sys.stderr)
        raise
    finally:
        con.close()


if __name__ == "__main__":
    main()
