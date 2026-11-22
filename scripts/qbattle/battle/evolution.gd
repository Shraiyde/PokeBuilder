class_name Evolution
extends RefCounted
## Evolution — when a Pokémon evolves, from the ROM's evolution table ("evolutions": per species
## [[method, param, target], ...]).
## The method ids are THIS ROM's numbering. Their meanings were worked out from the ROM's own entries
## against well-known evolutions (see docs/HANDOFF.md "Battle parity"; e.g. Bulbasaur→Ivysaur = 4 at 16,
## Kadabra→Alakazam = 5, Pikachu + Thunder Stone = 7, Tyrogue = 8/9/10 by Attack vs Defense, Combee→Vespiquen
## = 16 (female), Kirlia + Dawn Stone = 26 (male), Mantyke with Remoraid = 29, Pancham = 30, Toxel = 33/34,
## Poliwhirl holding King's Rock = 41, Sliggoo = 28 rain / 42 fog). Unknown ids never trigger.
## After a battle the level-up methods are checked for every party member that levelled up (as the games do);
## item methods are for the bag (by_item). Moves "learned on evolution" are the target's level-0 learnset
## entries plus its moves at the current level.
## Depends on: BattleData, BattleMon. Used by: BattleController (after battles), BattleRules (EXP bonus).

const LEVEL := 4
const TRADE := 5
const TRADE_ITEM := 6
const ITEM := 7
const ATK_GT_DEF := 8
const ATK_EQ_DEF := 9
const ATK_LT_DEF := 10
const LEVEL_NINJASK := 13
const LEVEL_SHEDINJA := 14
const BEAUTY := 15
const LEVEL_FEMALE := 16
const LEVEL_MALE := 17
const MOVE := 23
const ITEM_MALE := 26
const ITEM_FEMALE := 27
const LEVEL_RAIN := 28
const MON_IN_PARTY := 29
const LEVEL_DARK_IN_PARTY := 30
const TRADE_SPECIFIC := 31
const NATURE_AMPED := 33
const NATURE_LOW_KEY := 34
const ITEM_HOLD := 41
const LEVEL_FOG := 42
const LEVEL_FAMILY := 43
const MOVE_SEGMENT := 44
const LEVEL_ALT_A := 45
const LEVEL_ALT_B := 46

## Natures that pick Amped Toxtricity (public list: Hardy, Brave, Adamant, Naughty, Docile, Impish, Lax,
## Hasty, Jolly, Naive, Rash, Sassy, Quirky); nature ids are the standard 0-24 order.
const AMPED := [0, 1, 3, 4, 5, 6, 8, 10, 11, 13, 15, 19, 24]

## The species `rec` evolves into after levelling up, or -1. ctx: {party: [records] (for party checks),
## weather: "" | "rain" | "fog", bd item names are not needed}. rec is a party record (BattleMon.to_party).
static func after_level_up(bd: BattleData, rec: Dictionary, ctx: Dictionary = {}) -> int:
	var sp := int(rec.get("species", 0))
	var lv := int(rec.get("level", 1))
	var item := int(rec.get("item", 0))
	if bd.item_hook(item).get("k", "") == "everstone":
		return -1
	for e in bd.evolutions(sp):
		var meth := int(e[0])
		var par := int(e[1])
		var to := int(e[2])
		var ok := false
		match meth:
			LEVEL, LEVEL_NINJASK, LEVEL_FAMILY, LEVEL_ALT_A, LEVEL_ALT_B:
				ok = lv >= par
			ATK_GT_DEF, ATK_EQ_DEF, ATK_LT_DEF:
				var st: Dictionary = rec.get("stats", {})
				var a := int(st.get("atk", 0))
				var d := int(st.get("def", 0))
				ok = lv >= par and ((meth == ATK_GT_DEF and a > d) or (meth == ATK_EQ_DEF and a == d) or (meth == ATK_LT_DEF and a < d))
			LEVEL_FEMALE, LEVEL_MALE:
				var g := BattleMon.gender_of(int(bd.species(sp).get("gender", -1)), int(rec.get("pid", 0)))
				ok = lv >= par and g == (1 if meth == LEVEL_FEMALE else 0)
			MOVE, MOVE_SEGMENT:
				ok = _knows(rec, par)
			LEVEL_RAIN:
				ok = lv >= par and str(ctx.get("weather", "")) == "rain"
			LEVEL_FOG:
				ok = lv >= par and str(ctx.get("weather", "")) == "fog"
			MON_IN_PARTY:
				ok = _party_has(ctx, func(p): return int(p.get("species", 0)) == par)
			LEVEL_DARK_IN_PARTY:
				ok = lv >= par and _party_has(ctx, func(p): return 17 in bd.species(int(p.get("species", 0))).get("types", []))
			NATURE_AMPED, NATURE_LOW_KEY:
				var amped := int(rec.get("nature", 0)) in AMPED
				ok = lv >= par and amped == (meth == NATURE_AMPED)
			ITEM_HOLD:
				ok = item == par
		if ok:
			return to
	return -1

## The species `rec` evolves into when `item` is used on it from the bag, or -1 (stones, gendered stones).
static func by_item(bd: BattleData, rec: Dictionary, item: int) -> int:
	var sp := int(rec.get("species", 0))
	for e in bd.evolutions(sp):
		var meth := int(e[0])
		if int(e[1]) != item or not (meth in [ITEM, ITEM_MALE, ITEM_FEMALE]):
			continue
		if meth != ITEM:
			var g := BattleMon.gender_of(int(bd.species(sp).get("gender", -1)), int(rec.get("pid", 0)))
			if g != (0 if meth == ITEM_MALE else 1):
				continue
		return int(e[2])
	return -1

## True when the species could already have evolved by level (Gen 6+ EXP bonus for unevolved mons).
static func past_level_evo(bd: BattleData, species: int, level: int) -> bool:
	for e in bd.evolutions(species):
		if int(e[0]) == LEVEL and level >= int(e[1]):
			return true
	return false

## Evolves a party record into `to`: new species, name (if it was the species name), stats recomputed with
## the same IVs/EVs/nature/level (HP lost is kept), ability from the same slot, then the target's moves
## learned on evolution. Returns {rec, learned: [move ids], full: [move ids that need a forget prompt]}.
static func apply(bd: BattleData, rec: Dictionary, to: int) -> Dictionary:
	var r := rec.duplicate(true)
	var old_sp := int(r.get("species", 0))
	var old_ab: Array = bd.species(old_sp).get("abilities", [0, 0, 0])
	var slot := old_ab.find(int(r.get("ability", -1)))
	if str(r.get("name", "")) == bd.species_name(old_sp) or not r.has("name"):
		r["name"] = bd.species_name(to)
	r["species"] = to
	var new_ab: Array = bd.species(to).get("abilities", [0, 0, 0])
	if slot >= 0 and slot < new_ab.size() and int(new_ab[slot]) != 0:
		r["ability"] = int(new_ab[slot])
	elif int(new_ab[0]) != 0:
		r["ability"] = int(new_ab[0])
	r["types"] = bd.species(to).get("types", [0, 0]).duplicate()
	var m := BattleMon.from_party(bd, r)
	m.recalc_stats(bd)
	r["stats"] = m.stats.duplicate()
	var old_max := int(rec.get("stats", {}).get("hp", m.max_hp()))
	r["hp"] = clampi(int(rec.get("hp", old_max)) + m.max_hp() - old_max, 0 if int(rec.get("hp", 1)) <= 0 else 1, m.max_hp())
	var learned: Array = []
	var full: Array = []
	var lv := int(r.get("level", 1))
	for e in bd.learnset(to):
		var mid := int(e[0])
		if not (int(e[1]) == 0 or int(e[1]) == lv) or mid <= 0 or _knows(r, mid):
			continue
		if BattleMon.learn_into(bd, r, mid):
			learned.append(mid)
		else:
			full.append(mid)
	return {"rec": r, "learned": learned, "full": full}

static func _knows(rec: Dictionary, move_id: int) -> bool:
	for e in rec.get("moves", []):
		if (int(e[0]) if e is Array else int(e)) == move_id:
			return true
	return false

static func _party_has(ctx: Dictionary, f: Callable) -> bool:
	for p in ctx.get("party", []):
		if p is Dictionary and f.call(p):
			return true
	return false
