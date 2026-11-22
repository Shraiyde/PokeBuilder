class_name BattleRules
extends RefCounted
## BattleRules — the generic rules that are not tied to one move: stat stages, accuracy, critical hits,
## Speed for turn order, end-of-turn status damage, running away, catching and experience. Formulas follow
## the GEN 3 rules (Bulbapedia's Generation III pages): critical hits deal x2 damage on the Gen 3 stage
## table (1/16, 1/8, 1/4, 1/3, 1/2), paralysis quarters Speed, Ghost types do NOT auto-escape, EXP is
## floor(base * level / 7) with the trainer x1.5 and a split among participants / Exp. Share holders, and
## the Gen 3 ball multipliers. (The engine used to follow the Gen 7-9 rules; the Gen 3 numbers below are
## the ones this ROM's battles use now. Anything the ROM adds on top — later-gen balls, abilities, items —
## keeps its own value where Gen 3 has none.)
## All randomness goes through BattleRng so a seed replays the same battle.
## Depends on: BattleMon, BattleRng, BattleData, TypeChart, AbilityHooks, ItemHooks, DamageCalc.
## Used by: BattleState, DamageCalc, MoveEffects, BattleAI.

## Multiplier for a stat stage (-6..+6) on atk/def/spa/spd/spe: (2+s)/2 or 2/(2-s).
static func stage_mult(s: int) -> float:
	s = clampi(s, -6, 6)
	return (2.0 + s) / 2.0 if s >= 0 else 2.0 / (2.0 - s)

## Accuracy/evasion stage multiplier: (3+s)/3 or 3/(3-s).
static func acc_stage_mult(s: int) -> float:
	s = clampi(s, -6, 6)
	return (3.0 + s) / 3.0 if s >= 0 else 3.0 / (3.0 - s)

## A stat after its stage, e.g. effective attack. Integer maths on purpose: floats like 2/3 round down
## one point too low on some values (300 * 0.666... = 199.99), which would break exact damage matching.
static func staged_stat(m: BattleMon, key: String, stage_override: int = 99) -> int:
	var s := int(m.stages.get(key, 0)) if stage_override == 99 else stage_override
	return apply_stage(int(m.stats[key]), s)

## value after a stat stage s (-6..+6): value*(2+s)/2 or value*2/(2-s), rounded down.
static func apply_stage(value: int, s: int) -> int:
	s = clampi(s, -6, 6)
	return value * (2 + s) / 2 if s >= 0 else value * 2 / (2 - s)

## Effective Speed (stage, then one chained modifier from abilities (Swift Swim x2...), items (Choice
## Scarf x1.5, Iron Ball x0.5), Tailwind x2 and paralysis x0.25 (Gen 3: paralysis quarters Speed, not
## halves it — the x0.5 is Gen 7+; not with Quick Feet). Trick Room is applied by the turn order, not here.
static func speed_of(st, m: BattleMon) -> int:
	var s := staged_stat(m, "spe")
	var mods: Array = AbilityHooks.speed_mods(st, m)
	mods.append_array(ItemHooks.speed_mods(st, m))
	if st.side_of(m).get("cond", {}).has("tailwind"):
		mods.append(8192)
	if m.status == "par" and not AbilityHooks.ignores_par_speed(st, m):
		mods.append(1024)
	if mods.size() > 0:
		s = DamageCalc.modify_i(s, DamageCalc.chain_all(mods))
	return mini(s, 10000)

## Final accuracy (0-100+) of mv from user on target, or -1 when it can't miss. Showdown hitStepAccuracy
## order: ModifyAccuracy chain (Compound Eyes, Hustle, Sand Veil, Bright Powder, Wide/Zoom Lens, Gravity)
## first, then the accuracy-minus-evasion stage (Unaware / Keen Eye / Foresight ignore evasion).
static func accuracy_of(st, user: BattleMon, target: BattleMon, mv: Dictionary) -> int:
	var acc := int(mv.acc)
	if mv.get("never_miss", false) or acc <= 0 or acc > 100 or AbilityHooks.no_guard(st, user, target):
		return -1
	if user.vol.has("lock_on") or (target.vol.has("minimized") and mv.get("minimize", false)):
		return -1
	if target.vol.has("telekinesis") and not mv.get("ohko", false):
		return -1
	if AbilityHooks.wonder_skin(st, target, mv) and acc > 50:
		acc = 50
	var mods: Array = AbilityHooks.acc_mods(st, user, target, mv)
	mods.append_array(ItemHooks.acc_mods(st, user, target))
	if st.field.has("gravity"):
		mods.append(6840)
	if mods.size() > 0:
		acc = DamageCalc.modify_i(acc, DamageCalc.chain_all(mods))
	var a_st := int(user.stages.acc)
	var e_st := int(target.stages.eva)
	if AbilityHooks.unaware(st, target):
		a_st = 0
	if AbilityHooks.unaware(st, user) or AbilityHooks.key(st, user) in ["no_acc_drop", "scrappy"] or (target.vol.has("identified") and e_st > 0) or target.vol.has("miracle_eye"):
		e_st = 0
	var stg := clampi(a_st - e_st, -6, 6)
	if stg > 0:
		acc = acc * (3 + stg) / 3
	elif stg < 0:
		acc = acc * 3 / (3 - stg)
	return acc

## Does the move hit? (Lock-On is used up by the check.)
static func hits(st, user: BattleMon, target: BattleMon, mv: Dictionary) -> bool:
	var a := accuracy_of(st, user, target, mv)
	if user.vol.has("lock_on"):
		user.vol.erase("lock_on")
	if a < 0:
		return true
	return st.rng.below(100) < a

## Critical-hit chance by stage (Gen 3 table: 0 → 1/16, 1 → 1/8, 2 → 1/4, 3 → 1/3, 4+ → 1/2).
## Stage sources, each +1 in Gen 3: high-crit move, Focus Energy / Dire Hit, Scope Lens, Super Luck.
## (Focus Energy is +2 in Gen 7+, +1 in Gen 3.) Laser Focus, Merciless and always-crit moves crit;
## Battle Armor / Shell Armor and Lucky Chant block.
static func crit_roll(st, user: BattleMon, target: BattleMon, mv: Dictionary, always: bool = false) -> bool:
	if AbilityHooks.no_crit(st, target) or st.side_of(target).get("cond", {}).has("lucky_chant"):
		return false
	if always or user.vol.has("laser_focus") or AbilityHooks.always_crit(st, user, target):
		return true
	var stage := (1 if mv.get("high_crit", false) else 0) + (1 if user.vol.has("focus_energy") else 0)
	stage += AbilityHooks.crit_stage(st, user) + ItemHooks.crit_stage(st, user)
	match stage:
		0: return st.rng.below(16) == 0
		1: return st.rng.below(8) == 0
		2: return st.rng.below(4) == 0
		3: return st.rng.below(3) == 0
		_: return st.rng.below(2) == 0

## Can `m` get `s` at all (type, ability, terrain immunities)? Does not check an existing status or
## Safeguard. source = the mon causing it (Corrosion lets it poison Steel/Poison types), may be null.
static func can_get_status(st, m: BattleMon, s: String, source: BattleMon = null) -> bool:
	match s:
		"brn":
			if m.has_type(TypeChart.FIRE): return false
		"psn", "tox":
			if (m.has_type(TypeChart.POISON) or m.has_type(TypeChart.STEEL)) and not AbilityHooks.corrosion(st, source): return false
		"par":
			if m.has_type(TypeChart.ELECTRIC): return false
		"frz":
			if m.has_type(TypeChart.ICE) or (st.weather == "sun" and not AbilityHooks.weather_suppressed(st)): return false
		"slp":
			if st.terrain == "electric" and st.is_grounded(m): return false
	if st.terrain == "misty" and st.is_grounded(m):
		return false
	return AbilityHooks.allows_status(st, m, s)

## End-of-turn damage from a major status (psn 1/8, tox n/16 rising, brn 1/16, Heatproof halves burn).
## Returns HP lost (>= 1) or 0. Poison Heal / Magic Guard are handled by the caller (BattleState).
static func status_chip(m: BattleMon, st = null) -> int:
	match m.status:
		"psn": return maxi(1, m.max_hp() / 8)
		"brn":
			if st != null and AbilityHooks.key(st, m) == "heatproof":
				return maxi(1, m.max_hp() / 32)
			return maxi(1, m.max_hp() / 16)
		"tox":
			m.status_turns = mini(15, m.status_turns + 1)
			return maxi(1, m.max_hp() * m.status_turns / 16)
	return 0

## Run-away check for wild battles (Gen 3): always escapes when the runner holds a Smoke Ball or has Run
## Away, or when its RAW Speed (no stages) is at least the foe's; otherwise odds = floor(mySpeed * 128 /
## foeSpeed) + 30 * attempts (this attempt counted) and it escapes when odds > 255 or a random 0-255 is
## below odds. (Gen 3 has no Ghost-type auto-escape — that is Gen 6+.)
static func run_succeeds(st, me: BattleMon, foe: BattleMon, attempts: int) -> bool:
	if AbilityHooks.always_run(st, me) or ItemHooks.smoke_ball(st, me):
		return true
	var ms := int(me.stats.spe)
	var fs := maxi(1, int(foe.stats.spe))
	if ms >= fs:
		return true
	var odds := ms * 128 / fs + 30 * attempts
	if odds > 255:
		return true
	return st.rng.below(256) < odds

## Ball multiplier (4096-based) for a ball item on the target. Gen 3 values for the balls that exist in
## Gen 3 (Bulbapedia "Poké Ball", Generation III): Great x1.5, Ultra x2, Net x3 (Bug/Water), Nest
## (41 - level)/10 (min x1), Dive x3.5 (water/fishing), Repeat x3 (caught before), Timer (turns + 10)/10
## (max x4), Level x8/x4/x2, Lure x3 (fishing), Love x8 (same species, opposite gender), Fast x4 (base
## Speed >= 100). Balls that don't exist in Gen 3 (Dusk, Quick, Dream, Beast) keep their newer values —
## the ROM has them and Gen 3 has nothing to say about them.
## ctx: {turn, user (the thrower's active mon), night: bool, cave: bool, water: bool, fishing: bool,
## caught_before: bool}. Unknown conditions (night, caves, surfing, Pokédex) default to "no bonus".
static func ball_mult(st, ball: String, target: BattleMon, ctx: Dictionary) -> int:
	var bd: BattleData = st.bd
	match ball:
		"great": return 6144
		"ultra": return 8192
		"net": return 12288 if target.has_type(TypeChart.BUG) or target.has_type(TypeChart.WATER) else 4096
		"nest": return maxi(4096, (41 - target.level) * 4096 / 10)
		"dive": return 14336 if ctx.get("water", false) or ctx.get("fishing", false) else 4096
		"dusk": return 12288 if ctx.get("night", false) or ctx.get("cave", false) else 4096
		"timer": return mini(16384, (10 + int(ctx.get("turn", 0))) * 4096 / 10)
		"quick": return 20480 if int(ctx.get("turn", 0)) <= 1 else 4096
		"repeat": return 12288 if ctx.get("caught_before", false) else 4096
		"level":
			var u: BattleMon = ctx.get("user")
			if u == null: return 4096
			if u.level >= target.level * 4: return 32768
			if u.level >= target.level * 2: return 16384
			if u.level > target.level: return 8192
			return 4096
		"lure": return 12288 if ctx.get("fishing", false) else 4096
		"love":
			var u2: BattleMon = ctx.get("user")
			if u2 != null and u2.species == target.species and u2.gender in [0, 1] and target.gender in [0, 1] and u2.gender != target.gender:
				return 32768
			return 4096
		"fast": return 16384 if int(bd.species(target.species).get("base", {}).get("spe", 0)) >= 100 else 4096
		"dream": return 16384 if target.status == "slp" else 4096
		"beast": return 410
	return 4096

## Heavy Ball (Gen 3): changes the catch RATE by the target's weight (0.1 kg units): < 102.4 kg: -20,
## 102.4-204.7 kg: +0, 204.8-307.1 kg: +20, >= 307.2 kg: +40. (Gen 7+ uses 100/200/300 kg and +30.)
static func heavy_ball_rate(rate: int, weight: int) -> int:
	if weight >= 3072: return mini(255, rate + 40)
	if weight >= 2048: return mini(255, rate + 20)
	if weight >= 1024: return rate
	return maxi(1, rate - 20)

## The Gen 3 catch value a = floor((3M - 2H) * rate * ball / 3M) * status, before the >= 255 check:
## status x2 asleep/frozen, x1.5 poisoned/paralysed/burned, x1 otherwise. ball_m4096 = ball multiplier
## in 4096ths (4096 = x1, -1 = Master Ball, which always catches).
static func catch_a(target: BattleMon, rate: int, ball_m4096: int = 4096) -> float:
	if ball_m4096 < 0:
		return 255.0
	var mx := maxi(1, target.max_hp())
	var status_mult := 2.0 if target.status in ["slp", "frz"] else 1.5 if target.status != "" else 1.0
	return floorf(floorf((3.0 * mx - 2.0 * target.hp) * rate * (ball_m4096 / 4096.0)) / (3.0 * mx) * status_mult)

## Critical capture (Gen 5+ mechanic, the ROM's Pokédex makes it meaningful): when a ball is thrown, a
## critical capture occurs if a random 0-255 roll is below a * dex_mult, where dex_mult grows with the
## number of species registered in the Pokédex: 0-30: never, 31-150: 0.5%, 151-300: 1%, 301-450: 1.5%,
## 451-600: 2%, 601+: 2.5% (those are the chances at a = 255). A critical capture does a SINGLE shake
## check: it catches on the first shake, or breaks free at once. dex_caught = 0 (unknown — the overworld
## hasn't passed the count yet) means no critical captures.
static func crit_capture(st, a: float, dex_caught: int) -> bool:
	var mult := 0.0
	if dex_caught >= 601: mult = 0.025
	elif dex_caught >= 451: mult = 0.02
	elif dex_caught >= 301: mult = 0.015
	elif dex_caught >= 151: mult = 0.01
	elif dex_caught >= 31: mult = 0.005
	else: return false
	return st.rng.below(256) < a * mult

## Catch check (Gen 3 capture, Stephen: "Gen 3 catch math"): a = floor((3M - 2H) * rate * ball / 3M) *
## status, status x2 asleep/frozen, x1.5 poisoned/paralysed/burned; a >= 255 catches; otherwise four shake
## checks against b = floor(1048560 / floor(sqrt(floor(sqrt(floor(16711680 / a)))))), each a 16-bit random
## < b. Returns the number of checks passed (4 = caught; the screen shows at most 3 shakes before
## "caught"). ball_m4096 = ball multiplier in 4096ths (4096 = x1, -1 = Master Ball).
static func catch_shakes(st, target: BattleMon, rate: int, ball_m4096: int = 4096) -> int:
	# 0.1.14: Gen 3 capture (Stephen: "Gen 3 catch math"): a = floor((3M - 2H) * rate * ball / 3M) * status,
	# status x2 asleep/frozen, x1.5 poisoned/paralysed/burned; a >= 255 catches; otherwise four shake checks
	# against b = floor(1048560 / floor(sqrt(floor(sqrt(floor(16711680 / a)))))), each a 16-bit random < b.
	if ball_m4096 < 0:
		return 4
	var a := catch_a(target, rate, ball_m4096)
	if a >= 255.0:
		return 4
	var b := int(floor(1048560.0 / floorf(sqrt(floorf(sqrt(floorf(16711680.0 / maxf(a, 1.0))))))))
	var shakes := 0
	for i in 4:
		if st.rng.below(65536) >= b:
			break
		shakes += 1
	return shakes

## The shake-check value b for one shake of a critical capture (same b as the normal checks).
static func catch_b(a: float) -> int:
	return int(floor(1048560.0 / floorf(sqrt(floorf(sqrt(floorf(16711680.0 / maxf(a, 1.0))))))))

## EXP for beating `foe` (Gen 3: Bulbapedia "Experience", Generation III). The full amount for the foe
## is exp_total(); this returns one winner's share of it: floor(total * share_num / share_den), then
## x1.5 if the winner holds a Lucky Egg. (Gen 3 has no level scaling and no "could have evolved" bonus —
## those were Gen 7+ / Gen 6+ and are gone.) `winner` may be an int level (old API) or a BattleMon.
## The split itself lives in BattleState._award_exp: the total is divided equally among the participants,
## or — when any party member holds an Exp. Share — half to the participants and half, divided equally,
## among the Exp. Share holders (a participant that also holds one gets both shares).
static func exp_total(bd: BattleData, foe: BattleMon, trainer: bool) -> int:
	var b := int(bd.species(foe.species).get("exp_yield", 50))
	var e := b * foe.level / 7
	if trainer:
		e = e * 3 / 2
	return e

static func exp_gain(bd: BattleData, foe: BattleMon, winner, _trainer: bool, share_num: int = 1, share_den: int = 1) -> int:
	var e := exp_total(bd, foe, _trainer) * share_num / share_den
	if winner is BattleMon:
		e = int(floor(e * ItemHooks.exp_mult(bd, winner)))
	return e
