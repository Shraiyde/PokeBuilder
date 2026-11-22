class_name ItemUse
extends RefCounted
## ItemUse — bag rules shared by the overworld bag and the battle bag, adapted
## from Quetzal (game/core/item_use.gd) to the PokeBuilder port's data.
##
## PORT ADAPTATIONS (see ui-helpers-design.md for the full list):
## - POCKETS is the port's five pockets (Pokewilds ItemData: ITEMS, BALLS,
##   MATERIALS, KEY ITEMS, MEDICINE), not Quetzal's (which had TMs & HMs and
##   BERRIES). pocket_index() passes a port pocket index (0-4) through and
##   folds a legacy ROM pocket byte to the port pockets as a fallback.
## - kind() reads the medicine table from the BattleData member `item_kinds`
##   (a port addition — see the BattleData diff note; the already-ported
##   ai.gd, battle_state.gd and item_hooks.gd read the same member). The
##   table is keyed by the port's item ids; its contents are the port's
##   medicine effects (see the design note for the full table).
## - is_repel() / repel_steps() / is_escape_rope() /
##   is_no_target_field_item() now take `bd` and resolve by item NAME
##   (via bd.item_name), because the port's item ids are integrator-assigned
##   and the Quetzal ROM ids (Repel 114/115/116, Escape Rope 120) are
##   meaningless here. BagScreen's call was updated to pass bd.
## - is_evolution_item() first checks the item NAME against the port's
##   evolution-stone names (EVOLUTION_ITEM_NAMES, from Pokewilds ItemData),
##   then the ROM-table check (which needs the new bd.species_count()
##   accessor). The ROM-table check is inert in the port until the adapter
##   maps EVOLVE_ITEM name params to item ids (see the design note).
## - TM_MOVES is kept verbatim (Quetzal ROM data). It is inert in the port:
##   the port's item ids are 1-124 and TM/HM ids are 582-689, and the port's
##   item data has no TMs/HMs, so is_tm()/is_hm() never fire.
## - The Leppa Berry special case (ROM id 519) is kept verbatim; it is inert
##   in the port (no Leppa Berry in the port's item data).
## Depends on: BattleData (item_kinds, item_hook, item_name, ok, learnset,
## move, move_name, evolutions, species_count), Evolution, BattleMon.
## Used by: ui/bag_screen.gd, ui/battle_screen.gd (is_ball, pocket_index).

## The port's five bag pockets (Pokewilds ItemData pockets 0-4).
const POCKETS := ["ITEMS", "POKé BALLS", "MATERIALS", "KEY ITEMS", "MEDICINE"]

## Gen-3 bag cap: no item stack holds more than 99 (the ROM's bag slots are u8-capped at 99).
const STACK_CAP := 99

## Adds up to `n` of item `id` to a bag dict, never letting the stack pass STACK_CAP.
## Returns the amount actually added (0 when already full). Progress.add_item has no cap yet —
## callers in this workstream use this instead (see the Progress hook in the workstream report).
static func capped_add(items: Dictionary, id: int, n: int) -> int:
	var cur := int(items.get(str(id), 0))
	var room := maxi(0, STACK_CAP - cur)
	var add := mini(room, maxi(0, n))
	if add > 0:
		items[str(id)] = cur + add
	return add

## Repel steps by item NAME (the port's item ids are integrator-assigned, so
## the Quetzal ROM ids 114/115/116 are not used). The port's ItemData has
## REPEL and MAX REPEL only (no SUPER REPEL); the 200-step entry is kept so
## a future SUPER REPEL just works.
const REPEL_STEPS_BY_NAME := {"REPEL": 100, "SUPER REPEL": 200, "MAX REPEL": 250}
const ESCAPE_ROPE_NAME := "ESCAPE ROPE"

## TM/HM → move taught. The ROM's item table does NOT carry a usable move id for these
## (secondaryId +26 reads 150/80/60/10… — TM01 would "teach" Splash), so the assignment is the
## vanilla Gen-3 TM/HM list, verified against the ROM itself: every one of the 58 item
## descriptions in events/items.json is the vanilla move's description (TM01 "makes the user
## flinch if hit" = Focus Punch, TM02 "long, sharp claws" = Dragon Claw, HM07 "climb
## waterfalls" = Waterfall, HM08 "Dives underwater" = Dive, …), and every move name below
## resolves to a ROM move id in events/pokemon.json move_names.
## PORT NOTE: kept verbatim. Inert in the port — the port's item ids are 1-124,
## TM/HM ids are 582-689, and the port's item data has no TMs/HMs, so is_tm() /
## is_hm() never fire and tm_move() never returns a move for a port item.
const TM_MOVES := {
	582: 264, 583: 337, 584: 352, 585: 347, 586: 46, 587: 92, 588: 258, 589: 339, 590: 331,
	591: 237, 592: 241, 593: 269, 594: 58, 595: 59, 596: 63, 597: 113, 598: 182, 599: 240,
	600: 202, 601: 219, 602: 218, 603: 76, 604: 231, 605: 85, 606: 87, 607: 89, 608: 216,
	609: 91, 610: 94, 611: 247, 612: 280, 613: 104, 614: 115, 615: 351, 616: 53, 617: 188,
	618: 201, 619: 126, 620: 317, 621: 332, 622: 259, 623: 263, 624: 290, 625: 156, 626: 213,
	627: 168, 628: 211, 629: 285, 630: 289, 631: 315,
	682: 15, 683: 19, 684: 57, 685: 70, 686: 148, 687: 249, 688: 127, 689: 291,
}

## Evolution-stone / evolution-item NAMES in the port (Pokewilds ItemData
## EVOLUTION_ITEMS). Used by is_evolution_item() so stones are recognised
## by name even though the adapter's evolutions() params are stone names,
## not item ids (see the design note).
const EVOLUTION_ITEM_NAMES := ["SWEET APPLE", "WATER STONE", "FIRE STONE", "LEAF STONE",
	"THUNDERSTONE", "MOON STONE", "SUN STONE", "ICE STONE", "DAWN STONE",
	"DUSK STONE", "SHINY STONE", "UPGRADE", "DUBIOUS DISC"]

## Move id a TM/HM item teaches, or 0 (not a machine).
static func tm_move(id: int) -> int:
	return int(TM_MOVES.get(id, 0))

static func is_tm(id: int) -> bool:
	return id >= 582 and id <= 631

static func is_hm(id: int) -> bool:
	return id >= 682 and id <= 689

static func is_machine(id: int) -> bool:
	return is_tm(id) or is_hm(id)

## Repel items are used with no party target — the bag finishes them with
## to = -1 (like rods) and the caller runs the field effect. Resolved by
## item NAME via bd (the port's item ids are integrator-assigned).
static func is_repel(bd: BattleData, id: int) -> bool:
	if bd == null or not bd.ok():
		return false
	return str(bd.item_name(id)).strip_edges().to_upper() in REPEL_STEPS_BY_NAME

static func repel_steps(bd: BattleData, id: int) -> int:
	if bd == null or not bd.ok():
		return 0
	return int(REPEL_STEPS_BY_NAME.get(str(bd.item_name(id)).strip_edges().to_upper(), 0))

static func is_escape_rope(bd: BattleData, id: int) -> bool:
	if bd == null or not bd.ok():
		return false
	return str(bd.item_name(id)).strip_edges().to_upper() == ESCAPE_ROPE_NAME

static func is_no_target_field_item(bd: BattleData, id: int) -> bool:
	return is_repel(bd, id) or is_escape_rope(bd, id)

## Bag pocket index for a pocket value. A port pocket index (ItemData 0-4:
## ITEMS, BALLS, MATERIALS, KEY ITEMS, MEDICINE) passes through unchanged.
## A legacy ROM pocket byte (from an events object that still returns ROM
## bytes) is folded to the port pockets: 3 balls -> BALLS, 100 TMs -> ITEMS
## (no TM pocket in the port), 4 berries -> MEDICINE (berries live in
## MEDICINE here), 11 key items -> KEY ITEMS, anything else -> ITEMS.
static func pocket_index(pocket: int) -> int:
	if pocket >= 0 and pocket < POCKETS.size():
		return pocket
	match pocket:
		3:
			return 1
		100:
			return 0
		4:
			return 4
		11:
			return 3
	return 0

## [[id, count], ...] of the items in `items` that belong to pocket `pi`, by item id.
## `items` is keyed by str(id) (the battle screen's bag dict); `bd` supplies the
## pocket of each id (BattleData.item_pocket, a port addition — see the diff note).
static func list(items: Dictionary, bd: BattleData, pi: int) -> Array:
	var out: Array = []
	if bd == null:
		return out
	for k in items:
		var n := int(items[k])
		var id := int(k)
		if n > 0 and id > 0 and pocket_index(bd.item_pocket(id)) == pi:
			out.append([id, n])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out

## Effect record of an item ({} = not a medicine), from the BattleData
## `item_kinds` member (the port's medicine table, keyed by port item id —
## see the BattleData diff note and the design note for its contents).
## Berries are not in that table (their effects live in the held-item hooks),
## so their field effects are synthesised here from those hooks — ROM-verified per berry:
##   cure_berry (Cheri 514 par, Chesto 515 slp, Pecha 516 psn/tox, Rawst 517 brn, Aspear 518
##     frz, Persim 521 confusion, Lum 522 all) → cure with the same status list;
##   pinch_heal hp (Oran 520 = 10 HP, Berry Juice 53 = 20 HP) → heal that much;
##   pinch_heal frac (Sitrus 523 = 1/4 max HP; Figy/Wiki/Mago/Aguav/Iapapa 524-528 = 1/3,
##     the "hates" stat only matters for the in-battle confusion) → heal max_hp / frac.
## Leppa Berry (519) has no profile hook at all; its ROM item record (holdEffect 7, param 10,
## description "restores 10 PP") gives the PP effect directly.
## PORT NOTE: bd.item_hook() returns {} in the port (no held-item battle data),
## so the berry synthesis below is inert until the port gains held-item hooks.
## The Leppa special case (ROM id 519) is likewise inert — the port's item
## data has no Leppa Berry. The live path is the `item_kinds` table.
static func kind(bd: BattleData, id: int) -> Dictionary:
	var k: Dictionary = bd.item_kinds.get(str(id), {}) if bd != null else {}
	if not k.is_empty():
		return k
	if bd == null or not bd.ok():
		return {}
	if id == 519:
		return {"k": "pp", "n": 10, "all": false}
	var h: Dictionary = bd.item_hook(id)
	match str(h.get("k", "")):
		"cure_berry":
			return {"k": "cure", "s": h.get("s", [])}
		"pinch_heal":
			if h.has("hp"):
				return {"k": "heal", "hp": int(h.hp)}
			if h.has("frac") and int(h.frac) > 0:
				return {"k": "heal", "frac": int(h.frac)}
	return {}

static func is_ball(bd: BattleData, id: int) -> bool:
	return bd != null and not bd.ball(id).is_empty()

## Medicine usable from the overworld bag on a party member (heal / revive / cure / pp).
## 0.1.29: also evolution stones — any item that is an evolution
## method ITEM/ITEM_MALE/ITEM_FEMALE param for some species. The
## party-target check (has_effect) then filters to mons it actually
## evolves, so a stone is never offered as "usable" on the wrong mon.
## 0.1.49: also fishing rods (no party target — the bag finishes them
## with to = -1 and game.gd fishes instead).
## Field systems: also TMs/HMs (teach a move to a party member), berries (medicine, via kind()),
## and Repel / Escape Rope (no party target — the bag finishes them with to = -1 like rods).
static func field_usable(bd: BattleData, id: int) -> bool:
	if str(kind(bd, id).get("k", "")) in ["heal", "revive", "cure", "pp"]:
		return true
	if is_rod(bd, id):
		return true
	if is_machine(id) or is_no_target_field_item(bd, id):
		return true
	return is_evolution_item(bd, id)

## True when `rec` already knows move `move_id`.
static func knows_move(rec: Dictionary, move_id: int) -> bool:
	for m in rec.get("moves", []):
		var mid := int(m[0]) if m is Array else int(m)
		if mid == move_id:
			return true
	return false

## True when `move_id` is in the species' level-up learnset (ROM battle.json learnsets).
static func move_in_learnset(bd: BattleData, species: int, move_id: int) -> bool:
	if bd == null or not bd.ok():
		return false
	for e in bd.learnset(species):
		if e is Array and int(e[0]) == move_id:
			return true
	return false

## TM/HM teachability of `move_id` (from tm_move) for party record `rec`:
##   0 = cannot (already knows it, or the move id is not a real move);
##   1 = in the species' level-up learnset (ROM-verified);
##   2 = not in the learnset — teachable unless the ROM's TM-compatibility bitfield says
##       otherwise, and that table is UNPINNED (no gTMHMLearnsets-equivalent offset found;
##       the TM field-use task at ROM 0x0822a660 is the lead for finding it). The teach is
##       permissive for case 2 rather than refusing every TM that isn't a level-up move.
static func tm_learnable(bd: BattleData, rec: Dictionary, move_id: int) -> int:
	if move_id <= 0 or bd == null or not bd.ok() or bd.move(move_id).is_empty():
		return 0
	if knows_move(rec, move_id):
		return 0
	if move_in_learnset(bd, int(rec.get("species", 0)), move_id):
		return 1
	return 2

## Teaches the TM/HM move to a party record (in place). `forget_i` >= 0 replaces that move slot
## (the "forget a move" choice when the mon already knows four); otherwise the move is appended
## when there is room. Returns the message ("" = no room and no forget slot given; the caller
## keeps the item). PP is the move's full PP (BattleMon.learn_into / replace_move).
static func teach_tm(bd: BattleData, rec: Dictionary, move_id: int, forget_i: int = -1) -> String:
	if tm_learnable(bd, rec, move_id) == 0:
		return ""
	var nm := str(rec.get("name", "POKéMON"))
	if forget_i >= 0:
		if BattleMon.replace_move(bd, rec, forget_i, move_id):
			return "%s learned %s!" % [nm, bd.move_name(move_id)]
		return ""
	if BattleMon.learn_into(bd, rec, move_id):
		return "%s learned %s!" % [nm, bd.move_name(move_id)]
	return ""

## Fishing rods (ROM items.json: 709 Old Rod, 710 Good Rod, 711 Super Rod).
## Identified by name (ends with "Rod"), not by id, so the check survives
## any item-table shift. "Aerodactylite" contains "rod" as a substring,
## so ends_with — not contains — is the correct test.
## PORT NOTE: the port's rods are OLD ROD / GOOD ROD / SUPER ROD in ItemData
## (KEY_ITEMS pocket). The check is by name via bd.item_name, so it works
## for any port item id once item_name() returns real names.
static func is_rod(bd: BattleData, id: int) -> bool:
	if bd == null or not bd.ok():
		return false
	return str(bd.item_name(id)).ends_with("Rod")

## Encounters.ROD_SLOTS key for a rod ("old" / "good" / "super"), "" if not a rod.
static func rod_kind(bd: BattleData, id: int) -> String:
	var nm := str(bd.item_name(id)) if bd != null and bd.ok() else ""
	if nm == "Old Rod":
		return "old"
	if nm == "Good Rod":
		return "good"
	if nm == "Super Rod":
		return "super"
	return ""

## True when `id` is an evolution-stone item for at least one species.
## PORT: two checks. (1) By NAME: the item's name is in the port's
## evolution-items list (EVOLUTION_ITEM_NAMES) — this is the live path, and
## it works even though the adapter's evolutions() params are stone names,
## not item ids. (2) By ROM TABLE: some species has an ITEM/ITEM_MALE/
## ITEM_FEMALE evolution naming this id — inert in the port until the
## adapter maps EVOLVE_ITEM name params to item ids (see the design note);
## kept for parity with Quetzal. Needs the new bd.species_count() accessor.
static func is_evolution_item(bd: BattleData, id: int) -> bool:
	if bd == null or not bd.ok():
		return false
	if str(bd.item_name(id)).strip_edges().to_upper() in EVOLUTION_ITEM_NAMES:
		return true
	for sp in range(1, bd.species_count() + 1):
		for e in bd.evolutions(sp):
			if e is Array and e.size() >= 2 and int(e[0]) in [Evolution.ITEM, Evolution.ITEM_MALE, Evolution.ITEM_FEMALE] and int(e[1]) == id:
				return true
	return false

## Ether / Max Ether: pick one move.
static func needs_move(bd: BattleData, id: int) -> bool:
	var k := kind(bd, id)
	return str(k.get("k", "")) == "pp" and not bool(k.get("all", false))

static func _max_hp(rec: Dictionary) -> int:
	return int(rec.get("max_hp", rec.get("stats", {}).get("hp", 0)))

## Would the item do anything to this party record / battle snapshot ({hp, max_hp|stats.hp, status, pp})?
static func has_effect(bd: BattleData, id: int, rec: Dictionary, move_i: int = -1) -> bool:
	if bd != null and Evolution.by_item(bd, rec, id) >= 0:
		return true
	# TMs/HMs: teachable when the mon doesn't know the move yet (see tm_learnable for the
	# compatibility caveat). The actual teaching (and the forget-a-move prompt when full)
	# is teach_tm, driven by the game.gd hook — apply() below does not teach.
	if is_machine(id):
		return tm_learnable(bd, rec, tm_move(id)) > 0
	var k := kind(bd, id)
	var hp := int(rec.get("hp", 0))
	var mx := _max_hp(rec)
	var st := str(rec.get("status", ""))
	match str(k.get("k", "")):
		"heal":
			return hp > 0 and (hp < mx or (bool(k.get("cure", false)) and st != ""))
		"revive":
			return hp <= 0
		"cure":
			return hp > 0 and st != "" and st in k.get("s", [])
		"pp":
			var pp: Array = rec.get("pp", [])
			var mv: Array = rec.get("moves", [])
			for i in mv.size():
				if move_i >= 0 and i != move_i:
					continue
				var cur := int(pp[i]) if i < pp.size() else (int(mv[i].get("pp", 0)) if mv[i] is Dictionary else 0)
				var full := int(mv[i].get("max_pp", 0)) if mv[i] is Dictionary and mv[i].has("max_pp") else BattleMon.max_pp(bd, rec, i)
				if cur < full:
					return true
			return false
		"x", "dire_hit", "guard_spec":
			return true
	return false

## Applies an overworld medicine to a party record (in place). Returns the message ("" = no effect, nothing
## changed; the caller keeps the item).
static func apply(bd: BattleData, id: int, rec: Dictionary, move_i: int = -1) -> String:
	if not has_effect(bd, id, rec, move_i):
		return ""
	var k := kind(bd, id)
	var nm := str(rec.get("name", "POKéMON"))
	var mx := _max_hp(rec)
	match str(k.get("k", "")):
		"heal":
			# Heal amount: flat hp (potions, Oran Berry 10) or max_hp / frac (Sitrus 1/4,
			# Figy-family 1/3) — see kind().
			var amount := int(k.get("hp", 0))
			if amount <= 0 and int(k.get("frac", 0)) > 0:
				amount = maxi(1, mx / int(k.get("frac", 0)))
			var before := int(rec.hp)
			rec.hp = mini(mx, int(rec.hp) + amount)
			if bool(k.get("cure", false)):
				rec.status = ""
				rec.status_turns = 0
			return "%s's HP was restored by %d point(s)." % [nm, int(rec.hp) - before] if int(rec.hp) > before else "%s was cured." % nm
		"revive":
			rec.hp = maxi(1, mx / int(k.get("frac", 2)))
			rec.status = ""
			return "%s was revived!" % nm
		"cure":
			rec.status = ""
			rec.status_turns = 0
			return "%s was cured." % nm
		"pp":
			var pp: Array = rec.get("pp", [])
			var mv: Array = rec.get("moves", [])
			while pp.size() < mv.size():
				pp.append(0)
			for i in mv.size():
				if move_i >= 0 and i != move_i:
					continue
				var full := BattleMon.max_pp(bd, rec, i)   # same max as the Pokémon Center
				pp[i] = mini(full, maxi(0, int(pp[i])) + int(k.get("n", 10)))
			rec.pp = pp
			return "PP was restored."
	return ""
