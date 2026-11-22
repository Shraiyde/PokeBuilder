class_name DamageCalc
extends RefCounted
## DamageCalc — the damage formula. Gen 3 rules (Bulbapedia "Damage", Generation III), which is what
## this ROM's battles use: every rounding step is integer floor division, and the modifiers apply in
## this order:
##
##   type   = the move's type after -ate abilities etc. (BattleState.prepare_move did that already)
##   power  = modify(power, chain(all base-power modifiers))            abilities, items, gems, terrain,
##                                                                      Helping Hand, Charge, Knock Off...
##   atk    = stage(atk) → Hustle x1.5 (direct) → modify(chain(attack modifiers)) → burn halves the
##            PHYSICAL Attack stat (Gen 3: burn halves Attack, not the final damage; not with Guts,
##            and Facade ignores the burn drop)
##   def    = stage(def) → modify(chain(defense modifiers))
##            (Gen 3 has no sandstorm Rock Sp. Def boost and no snow Ice Defense boost — those are
##            Gen 4+ / Gen 9 and are NOT applied here)
##   base   = floor(floor(floor(2*L/5 + 2) * Power * A / D) / 50) + 2
##   then, in this order: screens (Reflect / Light Screen / Aurora Veil halve damage, singles AND
##   doubles — Gen 3 has no 2/3 doubles reduction) → weather (x1.5 / x0.5) → critical (x2, Gen 3) →
##   random roll (85..100 %) → STAB (x1.5, x2 Adaptability) → type effectiveness (x2 per weakness, halve
##   per resistance) → final modifiers chained (ROM abilities, Life Orb, Expert Belt, resist berries...).
##   Gen 3 has NO spread reduction: a move that hits several targets deals full damage to each (the
##   x0.75 spread factor is Gen 5+ and is not applied here, even though is_spread() still reports it
##   for the AI's scoring).
## "modify" is the games' 4096-based fixed-point multiply (rounded half down), "chain" combines several
## 4096-based modifiers with rounding (Showdown chainModify). A critical hit ignores the attacker's negative
## attack stages, the defender's positive defense stages and screens. Unaware ignores the other side's stages.
## Depends on: BattleData, BattleMon, BattleRules, TypeChart, AbilityHooks, ItemHooks.
## Used by: MoveEffects, BattleAI, tests.

## Fixed-point multiply with the games' rounding: value * mult, mult in 1/4096 steps, rounded half down.
static func modify(value: int, mult: float) -> int:
	var m := int(mult * 4096.0)
	return (value * m + 2048 - 1) / 4096

## Same as modify() with the modifier already given in 4096ths.
static func modify_i(value: int, m4096: int) -> int:
	return (value * m4096 + 2048 - 1) / 4096

## Combines two 4096-based modifiers the way chained modifiers are combined (rounded).
static func chain(a: int, b: int) -> int:
	return (a * b + 2048) >> 12

## Chains a list of 4096-based modifiers, starting at 4096 (x1.0).
static func chain_all(mods: Array) -> int:
	var m := 4096
	for x in mods:
		m = chain(m, int(x))
	return m

## Number of x2 steps for an effectiveness multiplier (2 → 1, 4 → 2, 0.5 → -1, 0.25 → -2).
static func eff_steps(mult: float) -> int:
	if mult <= 0.0:
		return 0
	return int(round(log(mult) / log(2.0)))

## Type effectiveness of mv on target with every battle rule that changes it: grounding (Gravity, Smack
## Down, Iron Ball, Ingrain vs Flying/Levitate; Air Balloon, Magnet Rise make a mon ungrounded), Scrappy /
## Foresight (Normal+Fighting hit Ghost), Miracle Eye (Psychic hits Dark), Freeze-Dry (super effective on
## Water), Flying Press (adds Flying), Tar Shot (Fire x2), Thousand Arrows, abilities (Levitate, absorbs,
## Wonder Guard, Soundproof...). 1.0 for typeless/MYSTERY moves.
static func type_eff(st, user: BattleMon, target: BattleMon, mv: Dictionary) -> float:
	var bd: BattleData = st.bd
	var t := int(mv.type)
	if t == TypeChart.MYSTERY or mv.get("typeless", false):
		return 1.0
	var eff := 1.0
	var types: Array = target.types
	var seen := {}
	for dt in types:
		if seen.has(int(dt)):
			continue
		seen[int(dt)] = true
		var x := bd.type_mult1(t, int(dt))
		if x == 0.0:
			if int(dt) == TypeChart.GHOST and t in [TypeChart.NORMAL, TypeChart.FIGHTING] and (AbilityHooks.scrappy(st, user) or target.vol.has("identified")):
				x = 1.0
			elif int(dt) == TypeChart.DARK and t == TypeChart.PSYCHIC and target.vol.has("miracle_eye"):
				x = 1.0
			elif int(dt) == TypeChart.FLYING and t == TypeChart.GROUND and (st.is_grounded(target) or mv.get("hits_airborne", false)):
				x = 1.0
		if mv.get("freeze_dry", false) and int(dt) == TypeChart.WATER:
			x = 2.0
		if mv.get("flying_press", false):
			x *= bd.type_mult1(TypeChart.FLYING, int(dt))
		eff *= x
	if t == TypeChart.GROUND and eff > 0.0 and not st.is_grounded(target) and not mv.get("hits_airborne", false) and not target.has_type(TypeChart.FLYING):
		if AbilityHooks.key(st, target) != "type_immune":   # Levitate is reported by its ability below
			eff = 0.0
	if t == TypeChart.FIRE and target.vol.has("tar_shot"):
		eff *= 2.0
	if eff > 0.0:
		eff *= AbilityHooks.type_eff_mod(st, user, target, mv, eff)
	return eff

## Full damage for one hit. opts: {crit: bool, roll: 0..15 (15 = lowest, 0 = highest) or -1 = random,
## spread: bool, power: int override, def_stat: "def"/"spd" override, atk_stat: "atk"/"def"/"spa" override,
## atk_source: BattleMon whose attack is used (default the user), ignore_screens: bool, typeless: bool,
## power_mods: extra 4096-based base-power modifiers from the move itself (Knock Off, terrain moves...),
## gem: 4096-based gem modifier (0 = none), no_items: true to skip item modifiers (oracle vs no-item sets)}.
## Returns {damage, eff, crit, berry} (berry = the target's resist berry halved it). Pure (no RNG unless
## roll = -1, no state changes), so the AI and tests can call it freely.
static func compute(st, user: BattleMon, target: BattleMon, mv: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var typeless: bool = opts.get("typeless", false)   # struggle / confusion self-hit
	var eff := 1.0 if typeless else type_eff(st, user, target, mv)
	var crit: bool = opts.get("crit", false)
	if eff == 0.0:
		return {"damage": 0, "eff": 0.0, "crit": false, "berry": false}
	var items: bool = not opts.get("no_items", false)
	# --- base power ---
	var power := int(opts.get("power", mv.power))
	var pm: Array = AbilityHooks.power_mods(st, user, target, mv, power)
	if items:
		pm.append_array(ItemHooks.power_mods(st, user, target, mv))
		if int(opts.get("gem", 0)) > 0:
			pm.append(int(opts.gem))
	pm.append_array(opts.get("power_mods", []))
	pm.append_array(field_power_mods(st, user, target, mv))
	if pm.size() > 0:
		power = modify_i(power, chain_all(pm))
	if power <= 0:
		return {"damage": 0, "eff": eff, "crit": false, "berry": false}
	# --- attack / defense ---
	var special := int(mv.cat) == 1
	var a_key: String = opts.get("atk_stat", "spa" if special else "atk")
	var a_mon: BattleMon = opts.get("atk_source", user)   # foul-play style moves use the target's attack
	var d_key: String = opts.get("def_stat", "spd" if special else "def")
	if st.field.has("wonder_room") and d_key in ["def", "spd"]:
		d_key = "spd" if d_key == "def" else "def"   # Wonder Room swaps the raw Defense and Sp. Def
	var a_stage := int(a_mon.stages[a_key])
	var d_stage := int(target.stages[d_key])
	if AbilityHooks.unaware(st, target):
		a_stage = 0
	if AbilityHooks.unaware(st, user) or mv.get("ignore_def_stages", false):
		d_stage = 0
	if crit:
		a_stage = maxi(a_stage, 0)
		d_stage = mini(d_stage, 0)
	var atk := BattleRules.apply_stage(int(a_mon.stats[a_key]), a_stage)
	if AbilityHooks.hustle(st, user, special):
		atk = modify(atk, 1.5)
	var am: Array = AbilityHooks.atk_mods(st, user, target, mv, special)
	if items:
		am.append_array(ItemHooks.atk_mods(st, user, special))
	if am.size() > 0:
		atk = modify_i(atk, chain_all(am))
	# Gen 3 burn: the Attack stat itself is halved for physical moves (not the final damage), so the
	# +2 in the base formula is not halved and Foul Play uses the halved Attack too. Guts ignores it
	# (its x1.5 is in atk_mods instead) and Facade ignores it.
	if not special and user.status == "brn" and not AbilityHooks.ignores_burn(st, user) and not mv.get("facade", false):
		atk = atk / 2
	var def := BattleRules.apply_stage(int(target.stats[d_key]), d_stage)
	# Gen 3: no sandstorm Rock Sp. Def boost (Gen 4+) and no snow Ice Defense boost (Gen 9).
	var dm: Array = AbilityHooks.def_mods(st, user, target, mv, special)
	if items:
		dm.append_array(ItemHooks.def_mods(st, target, special))
	if dm.size() > 0:
		def = modify_i(def, chain_all(dm))
	def = maxi(1, def)
	atk = maxi(1, atk)
	# --- base damage and the fixed-order steps (Gen 3) ---
	var base := (((2 * user.level / 5 + 2) * power * atk) / def) / 50 + 2
	# Gen 3: Reflect / Light Screen / Aurora Veil halve the damage right after the base formula,
	# in singles AND in doubles (the 2/3 doubles reduction is Gen 5+). Critical hits ignore screens.
	if not crit and not opts.get("ignore_screens", false) and not AbilityHooks.infiltrates(st, user) and user.side_id != target.side_id:
		var cond: Dictionary = st.side_of(target).get("cond", {})
		var screen := "lightscreen" if special else "reflect"
		if cond.has(screen) or cond.has("aurora_veil"):
			base = base / 2
	# Gen 3: no spread reduction (multi-target moves deal full damage to each target).
	var ws: bool = AbilityHooks.weather_suppressed(st)
	if not ws:
		base = modify(base, weather_mult(st, int(mv.type), mv))
	if crit:
		base = base * 2   # Gen 3 critical hits deal double damage (x1.5 is Gen 6+)
	var roll := int(opts.get("roll", -1))
	if roll < 0:
		roll = st.rng.below(16)
	base = base * (100 - roll) / 100
	if not typeless and user.has_type(int(mv.type)) and int(mv.type) != TypeChart.MYSTERY:
		base = modify(base, AbilityHooks.stab_mult(st, user))
	var steps := eff_steps(eff)
	if steps > 0:
		for i in steps:
			base *= 2
	elif steps < 0:
		for i in -steps:
			base = base / 2
	# --- final modifiers (ROM abilities / items: Life Orb, Expert Belt, resist berries, ...) ---
	var fm: Array = []
	fm.append_array(AbilityHooks.final_mods(st, user, target, mv, eff, crit))
	var berry := false
	if items:
		fm.append_array(ItemHooks.final_mods(st, user, target, mv, eff))
		berry = ItemHooks.resist_berry_applies(st, target, mv, eff)
	fm.append_array(opts.get("final_mods", []))
	if target.vol.has("minimized") and mv.get("minimize", false):
		fm.append(8192)
	if fm.size() > 0:
		var fin := chain_all(fm)
		if fin != 4096:
			base = modify_i(base, fin)
	if base <= 0:
		base = 1
	return {"damage": base & 0xFFFF, "eff": eff, "crit": crit, "berry": berry}

## Base-power modifiers from the field: terrain x1.3 (5325) for a grounded user's matching move, Grassy
## Terrain halves Earthquake-style moves on a grounded target, Misty Terrain halves Dragon moves on a
## grounded target, Charge doubles the next Electric move, Helping Hand x1.5.
static func field_power_mods(st, user: BattleMon, target: BattleMon, mv: Dictionary) -> Array:
	var out: Array = []
	var t := int(mv.type)
	match st.terrain:
		"electric": if t == TypeChart.ELECTRIC and st.is_grounded(user): out.append(5325)
		"grassy":
			if t == TypeChart.GRASS and st.is_grounded(user): out.append(5325)
			if mv.get("grassy_halved", false) and st.is_grounded(target): out.append(2048)
		"psychic": if t == TypeChart.PSYCHIC and st.is_grounded(user): out.append(5325)
		"misty": if t == TypeChart.DRAGON and st.is_grounded(target): out.append(2048)
	if user.vol.has("charge") and t == TypeChart.ELECTRIC:
		out.append(8192)
	if user.vol.has("helping_hand"):
		out.append(6144)
	return out

## Weather damage multiplier for a move type (rain: water x1.5 / fire x0.5; sun: the opposite; Hydro Steam
## is boosted in sun).
static func weather_mult(st, t: int, mv: Dictionary = {}) -> float:
	match st.weather:
		"rain":
			if t == TypeChart.WATER: return 1.5
			if t == TypeChart.FIRE: return 0.5
		"sun":
			if t == TypeChart.FIRE: return 1.5
			if t == TypeChart.WATER: return 1.5 if mv.get("hydro_steam", false) else 0.5
	return 1.0

## All 16 possible non-crit damage values (lowest roll first), for tests, the oracle and the AI.
static func range_all(st, user: BattleMon, target: BattleMon, mv: Dictionary, opts: Dictionary = {}) -> Array:
	var out: Array = []
	for r in range(15, -1, -1):
		var o := opts.duplicate()
		o["roll"] = r
		out.append(int(compute(st, user, target, mv, o).damage))
	return out
