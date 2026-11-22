class_name BattleMon
extends RefCounted
## BattleMon — one Pokémon while it is in a battle: stats, HP, moves with PP, status, stat stages and
## short-lived "volatile" effects (confusion, flinch, protect, ...). Built from a party record and written
## back to one when the battle ends, so HP/PP/status/level/exp carry over to the overworld.
##
## Party record format (core/party_mon.gd, shared with the other systems; extra keys are additive):
##   {species, name, level, ivs[6], stats{hp,atk,def,spe,spa,spd}, hp, moves[[id, name], ...], types[2]}
##   + optional keys this file adds/reads: pp[4], exp, status, nature, ability, evs[6], item
## Stat formulas (public Gen 3+ formulas):
##   HP    = floor((2*Base + IV + floor(EV/4)) * L / 100) + L + 10
##   other = floor((floor((2*Base + IV + floor(EV/4)) * L / 100) + 5) * nature)   nature = 1.1 / 0.9 / 1.0
## Nature id n (0-24): raises stat NATURE_ORDER[n / 5], lowers NATURE_ORDER[n % 5] (same stat = neutral).
## Depends on: BattleData. Used by: BattleState, DamageCalc, MoveEffects, AbilityHooks, BattleAI, battle UI.

const STAT_KEYS := ["hp", "atk", "def", "spe", "spa", "spd"]
const NATURE_ORDER := ["atk", "def", "spe", "spa", "spd"]
const STAGE_KEYS := ["atk", "def", "spa", "spd", "spe", "acc", "eva"]

var species := 0
var name := ""
var level := 1
var ivs: Array = [0, 0, 0, 0, 0, 0]
var evs: Array = [0, 0, 0, 0, 0, 0]
var nature := 0
var ability := 0
var item := 0
var item_at_start := 0   # held item when the battle began (Gen 9: non-berry items come back afterwards)
var types: Array = [0, 0]
var stats := {}          # computed stats (hp = max HP)
var hp := 1
var moves: Array = []    # [{id, pp, max_pp}]
var status := ""         # "", "psn", "tox", "brn", "par", "slp", "frz"
var status_turns := 0    # sleep turns left, or the toxic counter
var stages := {}         # atk, def, spa, spd, spe, acc, eva: -6..+6
var vol := {}            # volatile effects, cleared on switch-out (see clear_volatiles)
var exp := 0
var growth := 0
var owner := 0           # player id (pid) who controls this mon; 0 = AI / wild
var party_index := -1    # index in the owner's party array (for writing results back)
var fought := false      # was active at some point this battle (gets EXP)
var side_id := -1        # which BattleState side this mon belongs to
var slot := -1           # active slot on that side, or -1 when on the bench
var friendship := 70     # used by friendship-powered moves (TODO: real friendship tracking)
var pid := 0              # personality value (0.1.7; 0 = unknown). Only used for shininess so far.
var shiny := false        # shown with the ROM's shiny palette (core/shiny.gd)
var gender := -1         # 0 male, 1 female, 2 genderless, -1 unknown (gender_of; shown in the healthbox)
var gender_ratio := -1   # species gender ratio byte from the ROM (0.1.9; for re-deriving gender after a PID stamp)

## Builds a battler from a party record (see header). Missing fields are filled in from the ROM data.
static func from_party(bd: BattleData, p: Dictionary, rng: BattleRng = null) -> BattleMon:
	var m := BattleMon.new()
	m.species = int(p.get("species", 0))
	var sp := bd.species(m.species)
	m.name = str(p.get("name", bd.species_name(m.species)))
	m.level = clampi(int(p.get("level", 1)), 1, 100)
	m.ivs = p.get("ivs", [31, 31, 31, 31, 31, 31]).duplicate()
	m.evs = p.get("evs", [0, 0, 0, 0, 0, 0]).duplicate()
	m.nature = int(p.get("nature", -1))
	if m.nature < 0:
		m.nature = rng.below(25) if rng else 0
	m.types = sp.get("types", p.get("types", [0, 0])).duplicate()
	m.growth = int(sp.get("growth", 0))
	m.ability = int(p.get("ability", -1))
	if m.ability < 0:
		var ab: Array = sp.get("abilities", [0, 0, 0])
		var slot := 0
		if rng and int(ab[1]) != 0:
			slot = rng.below(2)
		m.ability = int(ab[slot])
	m.item = int(p.get("item", 0))
	m.item_at_start = m.item
	m.recalc_stats(bd)
	m.hp = clampi(int(p.get("hp", m.stats.hp)), 0, int(m.stats.hp))
	var pp: Array = p.get("pp", [])
	var mv: Array = p.get("moves", [])
	for i in mv.size():
		var e = mv[i]
		var id := int(e[0]) if e is Array else int(e)
		var md := bd.move(id)
		if md.is_empty():
			continue
		var mx := max_pp(bd, p, i)   # 0.1.14: base PP x (5 + PP Ups) / 5, never wrapped
		m.moves.append({"id": id, "pp": clampi(int(pp[i]) if i < pp.size() else mx, 0, mx), "max_pp": mx})
	m.status = str(p.get("status", ""))
	m.status_turns = int(p.get("status_turns", 0))
	m.exp = int(p.get("exp", bd.exp_at(m.growth, m.level)))
	m.friendship = int(p.get("friendship", sp.get("friendship", 70)))
	m.pid = int(p.get("pid", 0))
	m.shiny = bool(p.get("shiny", false))
	m.gender_ratio = int(sp.get("gender", -1))
	m.gender = gender_of(m.gender_ratio, m.pid)
	m.reset_stages()
	return m

## Gender (0 male, 1 female, 2 genderless, -1 unknown) from the species' gender ratio byte and the personality
## value, Gen-3 rule: 255 = genderless, 254 = always female, 0 = always male, otherwise female when the low byte
## of the personality is below the ratio. pid 0 (not stamped yet) only gives an answer for fixed ratios.
## Shown in the battle healthbox (0.1.9).
static func gender_of(ratio: int, personality: int) -> int:
	if ratio < 0:
		return -1
	if ratio == 255:
		return 2
	if ratio == 254:
		return 1
	if ratio == 0:
		return 0
	if personality == 0:
		return -1
	return 1 if (personality & 0xFF) < ratio else 0

## Builds a wild Pokémon: random IVs/nature/ability, the last 4 level-up moves known at that level.
static func wild(bd: BattleData, species_id: int, lv: int, rng: BattleRng) -> BattleMon:
	var ivs: Array = []
	for i in 6:
		ivs.append(rng.below(32))
	return from_party(bd, {"species": species_id, "level": lv, "ivs": ivs, "moves": learned_moves(bd, species_id, lv)}, rng)

## Builds a trainer's Pokémon from a ROM trainer-party member.
static func from_trainer(bd: BattleData, t: Dictionary, rng: BattleRng) -> BattleMon:
	var iv := int(t.get("iv", 0))
	var sp := bd.species(int(t.sp))
	var ab := -1
	var slot := int(t.get("abs", -1))
	if slot >= 0 and slot < 3 and int(sp.abilities[slot]) != 0:
		ab = int(sp.abilities[slot])
	var mv = t.get("moves")
	var p := {"species": int(t.sp), "level": int(t.lv), "ivs": [iv, iv, iv, iv, iv, iv],
		"evs": t.get("evs") if t.get("evs") != null else [0, 0, 0, 0, 0, 0],
		"nature": int(t.get("nat", -1)) if int(t.get("nat", -1)) < 25 else -1, "ability": ab,
		"item": int(t.get("item", 0)),
		"moves": mv if mv != null and not mv.is_empty() else learned_moves(bd, int(t.sp), int(t.lv))}
	return from_party(bd, p, rng)

## The last 4 distinct level-up moves learnable at or below `lv` (how wild and default trainer moves work).
static func learned_moves(bd: BattleData, species_id: int, lv: int) -> Array:
	var out: Array = []
	for e in bd.learnset(species_id):
		if int(e[1]) <= lv and not out.has(int(e[0])) and int(e[0]) > 0:
			out.append(int(e[0]))
	while out.size() > 4:
		out.pop_front()
	return out

## Nature multiplier for one stat key (1.1, 0.9 or 1.0).
func nature_mult(key: String) -> float:
	var up: String = NATURE_ORDER[nature / 5 % 5]
	var dn: String = NATURE_ORDER[nature % 5]
	if up == dn:
		return 1.0
	return 1.1 if key == up else 0.9 if key == dn else 1.0

## Recomputes stats from base stats, IVs, EVs, level and nature. Keeps the HP lost (used on level-up).
func recalc_stats(bd: BattleData) -> void:
	var sp := bd.species(species)
	var base: Dictionary = sp.get("base", {"hp": 1, "atk": 1, "def": 1, "spe": 1, "spa": 1, "spd": 1})
	var old_max := int(stats.get("hp", 0))
	for i in 6:
		var k: String = STAT_KEYS[i]
		var core := (2 * int(base[k]) + int(ivs[i]) + int(evs[i]) / 4) * level / 100
		if k == "hp":
			# A species whose base HP is 1 always has exactly 1 max HP (public mechanic).
			stats[k] = 1 if int(base[k]) == 1 else core + level + 10
		else:
			stats[k] = int(floor((core + 5) * nature_mult(k)))
	if old_max > 0:
		hp = clampi(hp + int(stats.hp) - old_max, 1 if hp > 0 else 0, int(stats.hp))

## Sets all stat stages to 0.
func reset_stages() -> void:
	for k in STAGE_KEYS:
		stages[k] = 0

## Clears switch-out effects (stages and volatiles). Status stays (it is permanent until cured).
func clear_volatiles() -> void:
	reset_stages()
	# Type and ability changes made in battle (Soak, Protean, Skill Swap, Trace...) end on switch-out.
	if vol.has("orig_types"):
		types = vol.orig_types.duplicate()
	if vol.has("orig_ability"):
		ability = int(vol.orig_ability)
	vol.clear()
	if status == "tox":
		status_turns = 0

## True when HP is 0.
func fainted() -> bool:
	return hp <= 0

## Max HP.
func max_hp() -> int:
	return int(stats.hp)

## True if the mon has the given type.
func has_type(t: int) -> bool:
	return int(types[0]) == t or int(types[1]) == t

## Index of a move id in the move list, or -1.
func move_index(id: int) -> int:
	for i in moves.size():
		if int(moves[i].id) == id:
			return i
	return -1

## True when no move has PP left (the mon must use the struggle move).
func out_of_pp() -> bool:
	for m in moves:
		if int(m.pp) > 0:
			return false
	return true

## Writes the battle result back into a copy of the party record and returns it (HP, PP, status, level,
## exp, stats, EVs, moves). Extra keys are additive so older code reading the record keeps working.
func to_party(bd: BattleData, base_rec: Dictionary) -> Dictionary:
	var p := base_rec.duplicate(true)
	p["species"] = species
	p["level"] = level
	p["hp"] = maxi(0, hp)
	p["stats"] = stats.duplicate()
	p["status"] = status if status != "tox" else "tox"
	p["status_turns"] = status_turns if status == "slp" else 0
	p["exp"] = exp
	p["evs"] = evs.duplicate()
	p["nature"] = nature
	p["ability"] = ability
	p["friendship"] = friendship   # Gen 3 friendship is tracked in battle (level-up +5/+3/+2, faint -1,
		# battle items +1) and written back here so Return / Frustration use the real value.
	# Gen 9 rule (expansion B_RESTORE_HELD_BATTLE_ITEMS): items used up or knocked off in battle come back
	# afterwards, eaten berries don't. An item gained in battle (Thief/Trick) is kept.
	var keep := item
	if keep == 0 and item_at_start > 0 and not ItemHooks.is_berry(bd, item_at_start):
		keep = item_at_start
	p["item"] = keep
	p["ivs"] = ivs.duplicate()
	p["types"] = types.duplicate()
	if pid != 0:
		p["pid"] = pid
		p["shiny"] = shiny
	if not p.has("name"):
		p["name"] = name
	var mv: Array = []
	var pp: Array = []
	for m in moves:
		mv.append([int(m.id), bd.move_name(int(m.id))])
		pp.append(int(m.pp))
	p["moves"] = mv
	p["pp"] = pp
	return p

## 0.1.14: true max PP of move slot i of a party record: base PP * (5 + PP Ups) / 5 (Gen 3: each PP Up adds a
## fifth of the base, 0-3 ups), as a plain int (no byte storage, no wrap-around). rec.pp_ups = [0-3 per slot].
static func max_pp(bd: BattleData, rec: Dictionary, i: int) -> int:
	var mv: Array = rec.get("moves", [])
	if i < 0 or i >= mv.size():
		return 0
	var e = mv[i]
	var id := int(e[0]) if e is Array else int(e.get("id", 0)) if e is Dictionary else int(e)
	var base := maxi(1, int(bd.move(id).get("pp", 1))) if bd != null else 1
	var ups_a: Array = rec.get("pp_ups", [])
	var ups := clampi(int(ups_a[i]) if i < ups_a.size() else 0, 0, 3)
	return base * (5 + ups) / 5

## Sets every move's PP of a party record to its true max (Pokémon Center, Max Elixir on all, new mons).
static func restore_all_pp(bd: BattleData, rec: Dictionary) -> void:
	var pp: Array = []
	for i in rec.get("moves", []).size():
		pp.append(max_pp(bd, rec, i))
	rec["pp"] = pp

## Adds move_id to a party record if it has fewer than 4 moves (PP = the move's max). Returns false when
## the record already knows 4 moves (the caller then needs a "forget a move" choice, see replace_move).
static func learn_into(bd: BattleData, rec: Dictionary, move_id: int) -> bool:
	var mv: Array = rec.get("moves", []).duplicate(true)
	if mv.size() >= 4:
		return false
	var md := bd.move(move_id)
	if md.is_empty():
		return false
	mv.append([move_id, bd.move_name(move_id)])
	var pp: Array = rec.get("pp", []).duplicate()
	while pp.size() < mv.size() - 1:
		pp.append(int(bd.move(int(mv[pp.size()][0] if mv[pp.size()] is Array else mv[pp.size()])).get("pp", 1)))
	pp.append(int(md.pp))
	rec["moves"] = mv
	rec["pp"] = pp
	return true

## Replaces move slot `slot` (0-3) of a party record with move_id (full PP). For the UI's "forget a move"
## prompt after a level-up or evolution ("learn_full" events / BattleController result "learn_pending").
static func replace_move(bd: BattleData, rec: Dictionary, slot: int, move_id: int) -> bool:
	var mv: Array = rec.get("moves", []).duplicate(true)
	var md := bd.move(move_id)
	if slot < 0 or slot >= mv.size() or md.is_empty():
		return false
	mv[slot] = [move_id, bd.move_name(move_id)]
	var pp: Array = rec.get("pp", []).duplicate()
	while pp.size() < mv.size():
		pp.append(1)
	pp[slot] = int(md.pp)
	rec["moves"] = mv
	rec["pp"] = pp
	return true

## Small summary for the UI.
func snapshot() -> Dictionary:
	var mv: Array = []
	for m in moves:
		mv.append({"id": int(m.id), "pp": int(m.pp), "max_pp": int(m.max_pp)})
	return {"species": species, "name": name, "level": level, "hp": hp, "max_hp": max_hp(), "status": status,
		"types": types.duplicate(), "moves": mv, "owner": owner, "stages": stages.duplicate(), "shiny": shiny,
		"gender": gender, "exp": exp, "growth": growth}   # 0.1.9: healthbox gender symbol + EXP bar (additive keys)
