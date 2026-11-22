class_name MoveEffects
extends RefCounted
## MoveEffects — what each move does after it has been chosen, passed its accuracy check and been announced.
## The ROM gives every move a numeric effect id (move record +0). Our profile maps those ids to OUR effect keys
## (res://profiles/quetzal_a9v1_battle.json "effects"); parameters like the stat and stages come from the
## profile and the secondary-effect chance comes from the move record itself (+6).
## Mechanics follow public descriptions, with Pokémon Showdown (MIT) as the behaviour reference; our own code.
##
## Implemented keys: hit, status, status_hit, drain, explode, dream_eater, boost_self, boost_target,
## hit_boost_target, hit_boost_self, hit_self_drop, haze, roar, multi_hit, flinch_hit, heal, screen,
## tri_attack, rest, ohko, half_hp, fixed_damage, level_damage, trap_hit, crash_on_miss (miss side is in
## BattleState), focus_energy, recoil, confuse, confuse_hit, two_turn (charge handled in BattleState),
## recharge, nothing, flail, false_swipe, always_crit, protect, weather, swagger, flatter, return_power,
## frustration_power, fake_out, memento, facade, eruption, psyshock, fang_hit, struggle, leech_seed,
## mean_look, stored_power, heal_bell, hit_force_out, heal_target, double_if{cond}, psywave, pain_split,
## lock_on, magnitude, present, belly_drum, psych_up, endeavor, refresh, wring_out, acrobatics, electro_ball,
## gyro_ball, foul_play, body_press, hidden_power, aqua_ring, ingrain, yawn, side_cond{side}, curse, teleport.
## Any other id → "unknown": damaging moves deal plain damage, status moves do nothing; both log a TODO line
## and are counted in BattleState.unknown_effects so they can be prioritised.
## Depends on: BattleState (passed as `st`), BattleMon, DamageCalc, BattleRules, AbilityHooks, TypeChart.
## Used by: BattleState.use_move().

const STAT_TEXT := {"atk": "Attack", "def": "Defense", "spa": "Sp. Atk", "spd": "Sp. Def", "spe": "Speed",
	"acc": "accuracy", "eva": "evasiveness"}

## Runs a move's effect on one target. `eff` is the profile entry ({k, ...}). Returns the damage dealt (for
## the caller's bookkeeping, e.g. counters later).
static func run(st, user: BattleMon, target: BattleMon, mv: Dictionary, eff: Dictionary) -> int:
	var k := str(eff.get("k", "unknown"))
	var chance := AbilityHooks.secondary_chance(st, user, int(mv.chance) if int(mv.chance) > 0 else 100)
	var ext := MoveEffectsExt.run(st, user, target, mv, eff, k, chance)
	if ext >= 0:
		return ext
	match k:
		"hit", "two_turn", "trap_hit", "crash_on_miss", "recharge", "struggle":
			var d := hit(st, user, target, mv)
			if d > 0:
				match k:
					"trap_hit":
						if not target.fainted() and not target.vol.has("trapped"):
							target.vol["trapped"] = {"turns": st.rng.range_i(4, 5), "by": user.side_id}
							st.log_msg("%s is trapped." % target.name)
					"recharge":
						user.vol["recharge"] = true
					"struggle":
						st.damage(user, maxi(1, int(round(user.max_hp() / 4.0))), "%s took recoil damage." % user.name)
			_todo(st, eff)
			return d
		"psyshock":
			return hit(st, user, target, mv, {"def_stat": "def"})
		"always_crit":
			return hit(st, user, target, mv, {"force_crit": true})
		"false_swipe":
			return hit(st, user, target, mv, {"leave_one": true})
		"facade":
			var p := int(mv.power) * (2 if user.status in ["psn", "tox", "brn", "par"] else 1)
			return hit(st, user, target, mv, {"power": p})
		"flail":
			var r := 48 * user.hp / maxi(1, user.max_hp())
			var fp := 200 if r <= 1 else 150 if r <= 4 else 100 if r <= 9 else 80 if r <= 16 else 40 if r <= 32 else 20
			return hit(st, user, target, mv, {"power": fp})
		"eruption":
			return hit(st, user, target, mv, {"power": maxi(1, int(mv.power) * user.hp / maxi(1, user.max_hp()))})
		"return_power":
			return hit(st, user, target, mv, {"power": maxi(1, user.friendship * 10 / 25)})
		"frustration_power":
			return hit(st, user, target, mv, {"power": maxi(1, (255 - user.friendship) * 10 / 25)})
		"status_hit":
			var d := hit(st, user, target, mv)
			if d > 0 and _secondary_ok(st, user, target) and st.rng.chance(chance):
				st.try_status(target, str(eff.s), false)
			return d
		"fang_hit":
			var d := hit(st, user, target, mv)
			if d > 0 and _secondary_ok(st, user, target):
				var s: String = {TypeChart.FIRE: "brn", TypeChart.ICE: "frz", TypeChart.ELECTRIC: "par"}.get(int(mv.type), "")
				if s != "" and st.rng.chance(10):
					st.try_status(target, s, false)
				if st.rng.chance(10):
					st.flinch(target)
			return d
		"tri_attack":
			var d := hit(st, user, target, mv)
			if d > 0 and _secondary_ok(st, user, target) and st.rng.chance(chance):
				st.try_status(target, ["brn", "par", "frz"][st.rng.below(3)], false)
			return d
		"flinch_hit":
			var d := hit(st, user, target, mv, {"no_flinch_item": true})
			if d > 0 and _secondary_ok(st, user, target) and st.rng.chance(chance):
				st.flinch(target)
			return d
		"fake_out":
			if int(user.vol.get("turns_in", 0)) > 0:
				st.log_msg("But it failed!")
				return 0
			var d := hit(st, user, target, mv, {"no_flinch_item": true})
			if d > 0 and _secondary_ok(st, user, target):
				st.flinch(target)
			return d
		"confuse_hit":
			var d := hit(st, user, target, mv)
			if d > 0 and _secondary_ok(st, user, target) and st.rng.chance(chance):
				st.confuse(target, false)
			return d
		"hit_boost_target":
			var d := hit(st, user, target, mv)
			if d > 0 and _secondary_ok(st, user, target) and st.rng.chance(chance):
				for s in eff.st:
					st.boost(target, s, int(eff.st[s]), true)
			return d
		"hit_boost_self":
			var d := hit(st, user, target, mv)
			if d > 0 and not user.fainted() and (eff.get("always", false) or st.rng.chance(chance)):
				for s in eff.st:
					st.boost(user, s, int(eff.st[s]), false)
			_todo(st, eff)
			return d
		"hit_self_drop":
			var d := hit(st, user, target, mv)
			if d > 0 and not user.fainted():
				for s in eff.st:
					st.boost(user, s, int(eff.st[s]), false)
			return d
		"drain", "dream_eater":
			if k == "dream_eater" and target.status != "slp":
				st.log_msg("%s isn't affected." % target.name)
				return 0
			var d := hit(st, user, target, mv)
			if d > 0 and not user.fainted():
				var num := int(eff.get("num", 1))
				var den := int(eff.get("den", 2))
				var h := ItemHooks.drain_heal(st, user, maxi(1, int(round(d * num / float(den)))))
				if AbilityHooks.liquid_ooze(st, target):
					st.damage(user, h, "%s sucked up the liquid ooze!" % user.name)
				else:
					st.heal(user, h, "%s had its energy drained!" % target.name)
			return d
		"recoil":
			var d := hit(st, user, target, mv)
			if d > 0 and not AbilityHooks.no_recoil(st, user) and not user.fainted():
				var r := maxi(1, int(round(d * int(eff.num) / float(eff.den))))
				st.damage(user, r, "%s took recoil damage." % user.name)
			_todo(st, eff)
			return d
		"multi_hit":
			var lo := int(eff.get("lo", 2))
			var hi := int(eff.get("hi", 5))
			var n := lo
			if lo == 2 and hi == 5:
				n = AbilityHooks.forced_hits(st, user)
				if n < 0 and ItemHooks.loaded_dice(st, user):
					n = st.rng.range_i(4, 5)
				if n < 0:
					n = [2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5][st.rng.below(20)]
			elif hi > lo:
				n = st.rng.range_i(lo, hi)
			var total := 0
			var landed := 0
			for i in n:
				if target.fainted() or user.fainted():
					break
				var d := hit(st, user, target, mv, {"quiet_eff": i > 0})
				if d <= 0:
					break
				total += d
				landed += 1
			if landed > 0:
				st.log_msg("The Pokémon was hit %d time%s!" % [landed, "" if landed == 1 else "s"])
			_todo(st, eff)
			return total
		"explode":
			var d := hit(st, user, target, mv)
			return d   # the user fainting is handled by BattleState (it happens even on a miss)
		"memento":
			for s in ["atk", "spa"]:
				st.boost(target, s, -2, true)
			return 0
		"ohko":
			if AbilityHooks.blocks_ohko(st, target) or target.level > user.level:
				st.log_msg("%s is unaffected." % target.name)
				return 0
			if TypeChart.effectiveness(st.bd, int(mv.type), target) == 0.0:
				st.log_msg("No effect on %s." % target.name)
				return 0
			var dmg := target.hp
			st.damage(target, dmg, "")
			st.log_msg("One-hit knockout!")
			return dmg
		"half_hp", "fixed_damage", "level_damage":
			if TypeChart.effectiveness(st.bd, int(mv.type), target) == 0.0:
				st.log_msg("No effect on %s." % target.name)
				return 0
			var dmg := maxi(1, target.hp / 2) if k == "half_hp" else int(eff.get("d", 1)) if k == "fixed_damage" else user.level
			dmg = mini(dmg, target.hp)
			st.damage(target, dmg, "")
			AbilityHooks.on_contact(st, user, target, mv)
			return dmg
		"status":
			var s := str(eff.s)
			if s == "par" and int(mv.type) == TypeChart.ELECTRIC and TypeChart.effectiveness(st.bd, int(mv.type), target) == 0.0:
				st.log_msg("No effect on %s." % target.name)
				return 0
			st.try_status(target, s, true)
			_todo(st, eff)
			return 0
		"rest":
			if user.hp >= user.max_hp() or not BattleRules.can_get_status(st, user, "slp"):
				st.log_msg("But it failed!")
				return 0
			user.status = "slp"
			user.status_turns = 3
			st.emit_status(user)
			st.heal(user, user.max_hp() - user.hp, "%s rests and recovers fully." % user.name)
			return 0
		"boost_self":
			for s in eff.st:
				st.boost(user, s, int(eff.st[s]), false)
			_todo(st, eff)
			return 0
		"boost_target":
			for s in eff.st:
				st.boost(target, s, int(eff.st[s]), true)
			_todo(st, eff)
			return 0
		"swagger", "flatter":
			st.boost(target, "atk" if k == "swagger" else "spa", 2 if k == "swagger" else 1, true)
			st.confuse(target, true)
			return 0
		"confuse":
			st.confuse(target, true)
			return 0
		"haze":
			for m in st.all_active():
				m.reset_stages()
			st.log_msg("All stat changes were reset.")
			return 0
		"heal":
			if str(mv.name) == "Roost" and user.has_type(TypeChart.FLYING):
				user.vol["roosted"] = true
			if user.hp >= user.max_hp():
				st.log_msg("%s's HP is already full." % user.name)
				return 0
			st.heal(user, int(round(user.max_hp() * int(eff.num) / float(eff.den))), "%s recovered HP." % user.name)
			_todo(st, eff)
			return 0
		"screen":
			var side: Dictionary = st.side_of(user)
			var c := str(eff.side)
			if side.cond.has(c):
				st.log_msg("But it failed!")
				return 0
			side.cond[c] = ItemHooks.screen_turns(st, user)
			st.log_msg("%s made %s team stronger against %s moves!" % [mv.name, "your" if user.side_id == 0 else "the opposing", "physical" if c == "reflect" else "special"])
			return 0
		"focus_energy":
			if user.vol.has("focus_energy"):
				st.log_msg("But it failed!")
				return 0
			user.vol["focus_energy"] = true
			st.log_msg("%s is focusing." % user.name)
			return 0
		"protect":
			var n := int(user.vol.get("protect_chain", 0))
			if st.is_last_to_act(user) or st.rng.below(int(pow(3, mini(n, 6)))) != 0:
				user.vol.erase("protect_chain")
				st.log_msg("But it failed!")
				return 0
			user.vol["protect"] = true
			user.vol["protect_kind"] = {"Spiky Shield": "spiky_shield", "King's Shield": "kings_shield", "Baneful Bunker": "baneful_bunker",
				"Silk Trap": "silk_trap", "Burning Bulwark": "burning_bulwark", "Obstruct": "obstruct"}.get(str(mv.name), "")
			user.vol["protect_chain"] = n + 1
			user.vol["protect_used_this_turn"] = true
			st.log_msg("%s is protecting itself." % user.name)
			return 0
		"weather":
			var wk := str(eff.w)
			st.set_weather(wk, ItemHooks.weather_turns(st, user, wk))
			_todo(st, eff)
			return 0
		"roar":
			st.force_out(user, target)
			return 0
		"leech_seed":
			if target.has_type(TypeChart.GRASS) or target.vol.has("seeded"):
				st.log_msg("%s is immune." % target.name if target.has_type(TypeChart.GRASS) else "It failed.")
				return 0
			target.vol["seeded"] = {"side": user.side_id, "slot": user.slot}
			st.log_msg("%s got seeded." % target.name)
			return 0
		"nothing":
			st.log_msg("Nothing happened.")
			return 0
		"mean_look":
			if target.vol.has("cant_flee"):
				st.log_msg("But it failed!")
				return 0
			target.vol["cant_flee"] = true
			st.log_msg("%s can't get away now." % target.name)
			return 0
		"stored_power":
			var ups := 0
			for s in user.stages:
				ups += maxi(0, int(user.stages[s]))
			return hit(st, user, target, mv, {"power": int(mv.power) + 20 * ups})
		"hit_force_out":
			var d := hit(st, user, target, mv)
			if d > 0 and not target.fainted():
				st.force_out(user, target)
			return d
		"double_if":
			var c := str(eff.cond)
			var yes := false
			match c:
				"poisoned": yes = target.status in ["psn", "tox"]
				"half_hp": yes = target.hp * 2 <= target.max_hp()
				"status": yes = target.status != ""
				"asleep": yes = target.status == "slp"
				"paralyzed": yes = target.status == "par"
				"target_moved": yes = st.has_acted(target)
				"target_hurt": yes = target.vol.has("hurt_this_turn")
				"user_hurt": yes = user.vol.has("hurt_this_turn")
			var d := hit(st, user, target, mv, {"power": int(mv.power) * (2 if yes else 1)})
			if yes and eff.has("cure") and target.status == str(eff.cure) and not target.fainted():
				st.cure(target, "%s is cured." % target.name)
			return d
		"psywave":
			if TypeChart.effectiveness(st.bd, int(mv.type), target) == 0.0:
				st.log_msg("No effect on %s." % target.name)
				return 0
			var pd: int = mini(target.hp, maxi(1, user.level * st.rng.range_i(50, 150) / 100))
			st.damage(target, pd, "")
			return pd
		"pain_split":
			var avg := (user.hp + target.hp) / 2
			user.hp = mini(avg, user.max_hp())
			target.hp = mini(avg, target.max_hp())
			st.emit_hp(user)
			st.emit_hp(target)
			st.log_msg("The battlers shared their pain.")
			return 0
		"lock_on":
			user.vol["lock_on"] = true
			st.log_msg("%s took aim at %s." % [user.name, target.name])
			return 0
		"magnitude":
			var roll: int = st.rng.below(100)
			var mags := [[5, 4, 10], [15, 5, 30], [35, 6, 50], [65, 7, 70], [85, 8, 90], [95, 9, 110], [100, 10, 150]]
			for x in mags:
				if roll < int(x[0]):
					st.log_msg("Magnitude %d!" % int(x[1]))
					return hit(st, user, target, mv, {"power": int(x[2])})
			return hit(st, user, target, mv)
		"present":
			var pr: int = st.rng.below(10)
			if pr < 2:
				st.heal(target, target.max_hp() / 4, "%s was healed a bit." % target.name)
				return 0
			return hit(st, user, target, mv, {"power": 40 if pr < 6 else 80 if pr < 9 else 120})
		"belly_drum":
			if user.hp * 2 <= user.max_hp() or int(user.stages.atk) >= 6:
				st.log_msg("But it failed!")
				return 0
			st.damage(user, user.max_hp() / 2, "%s cut its own HP to max out its Attack!" % user.name)
			st.boost(user, "atk", 12, false)
			return 0
		"psych_up":
			for s in target.stages:
				user.stages[s] = target.stages[s]
			st.log_msg("%s copied %s's stat changes." % [user.name, target.name])
			return 0
		"endeavor":
			if target.hp <= user.hp or TypeChart.effectiveness(st.bd, int(mv.type), target) == 0.0:
				st.log_msg("But it failed!")
				return 0
			var ed := target.hp - user.hp
			st.damage(target, ed, "")
			return ed
		"refresh":
			if user.status in ["psn", "tox", "brn", "par"]:
				st.cure(user, "%s's status returned to normal." % user.name)
			else:
				st.log_msg("But it failed!")
			return 0
		"heal_bell":
			for m in st.side_of(user).mons:
				if not m.fainted():
					m.status = ""
					m.status_turns = 0
					if m.slot >= 0:
						st.emit_status(m)
			st.log_msg("The team's status problems were healed.")
			return 0
		"heal_target":
			if target.hp >= target.max_hp():
				st.log_msg("But it failed!")
				return 0
			st.heal(target, int(round(target.max_hp() / 2.0)), "%s recovered HP." % target.name)
			return 0
		"wring_out":
			return hit(st, user, target, mv, {"power": maxi(1, 120 * target.hp / maxi(1, target.max_hp()))})
		"acrobatics":
			return hit(st, user, target, mv, {"power": int(mv.power) * (2 if user.item == 0 else 1)})
		"electro_ball":
			var ratio := BattleRules.speed_of(st, user) / maxi(1, BattleRules.speed_of(st, target))
			return hit(st, user, target, mv, {"power": 150 if ratio >= 4 else 120 if ratio >= 3 else 80 if ratio >= 2 else 60 if ratio >= 1 else 40})
		"gyro_ball":
			return hit(st, user, target, mv, {"power": mini(150, 25 * BattleRules.speed_of(st, target) / maxi(1, BattleRules.speed_of(st, user)) + 1)})
		"foul_play":
			return hit(st, user, target, mv, {"atk_source": target})
		"body_press":
			return hit(st, user, target, mv, {"atk_stat": "def"})
		"hidden_power":
			var idx := 0
			for i in 6:
				idx += (int(user.ivs[i]) & 1) << i
			var hp_types := [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17]
			var typed := mv.duplicate()
			typed["type"] = hp_types[idx * 15 / 63]
			return hit(st, user, target, typed)
		"aqua_ring", "ingrain":
			if user.vol.has(k):
				st.log_msg("But it failed!")
				return 0
			user.vol[k] = true
			if k == "ingrain":
				user.vol["cant_flee"] = true
			st.log_msg("%s surrounded itself with a healing aura." % user.name if k == "aqua_ring" else "%s planted its roots." % user.name)
			return 0
		"yawn":
			if target.status != "" or target.vol.has("yawn") or not BattleRules.can_get_status(st, target, "slp"):
				st.log_msg("But it failed!")
				return 0
			target.vol["yawn"] = 2
			st.log_msg("%s is getting drowsy." % target.name)
			return 0
		"side_cond":
			var sd: Dictionary = st.side_of(user)
			if sd.cond.has(str(eff.side)):
				st.log_msg("But it failed!")
				return 0
			sd.cond[str(eff.side)] = 5
			st.log_msg("%s's team is shielded." % user.name)
			return 0
		"curse":
			if user.has_type(TypeChart.GHOST):
				if target.vol.has("cursed"):
					st.log_msg("But it failed!")
					return 0
				st.damage(user, maxi(1, user.max_hp() / 2), "%s cut its HP to lay a curse on %s." % [user.name, target.name])
				target.vol["cursed"] = true
				return 0
			st.boost(user, "spe", -1, false)
			st.boost(user, "atk", 1, false)
			st.boost(user, "def", 1, false)
			return 0
		"teleport":
			if st.kind == "wild":
				st.log_msg("%s teleported away." % user.name)
				st.end_as("run")
			else:
				if not st.request_pivot(user):
					st.log_msg("But it failed!")
			return 0
	# Not implemented yet: plain damage for attacking moves, nothing for status moves.
	st.note_unknown(int(mv.eff))
	if int(mv.cat) != 2 and int(mv.power) > 0:
		var d := hit(st, user, target, mv)
		st.log_msg("(TODO: the extra effect of %s isn't in yet.)" % mv.name)
		return d
	st.log_msg("Nothing happened. (TODO: %s isn't in yet.)" % mv.name)
	return 0

## One damaging hit, with messages, immunity, gems, resist berries, Substitute, Endure / Sturdy / Focus
## Sash, faint and contact hooks, then on-hit abilities and items. opts: power, def_stat, atk_stat,
## atk_source, force_crit, leave_one, quiet_eff (no "super effective" line, later hits of multi-hit moves),
## pm (extra 4096-based base-power modifiers), no_flinch_item (the move flinches by itself), future (Future
## Sight: no gem / contact). Returns damage dealt (0 = no effect/immune).
static func hit(st, user: BattleMon, target: BattleMon, mv: Dictionary, opts: Dictionary = {}) -> int:
	target.vol.erase("sub_hit")
	var o := {"spread": st.is_spread(user, mv)}
	for key in ["power", "def_stat", "atk_source", "atk_stat"]:
		if opts.has(key):
			o[key] = opts[key]
	var pm: Array = mv.get("pm", []).duplicate()
	pm.append_array(opts.get("pm", []))
	if not pm.is_empty():
		o["power_mods"] = pm
	if int(mv.eff) >= 0 and str(st.bd.effect_of(mv).get("k", "")) == "struggle":
		o["typeless"] = true
	# Immunity first: a move that doesn't affect the target uses no gem and rolls no crit.
	if not o.get("typeless", false) and DamageCalc.type_eff(st, user, target, mv) == 0.0:
		st.log_msg("It doesn't affect %s..." % target.name)
		return 0
	if AbilityHooks.disguise_blocks(st, target, mv):
		return 0
	if AbilityHooks.ice_face_blocks(st, target, mv):
		return 0
	o["crit"] = BattleRules.crit_roll(st, user, target, mv, opts.get("force_crit", false))
	if not opts.get("future", false):
		var gem := ItemHooks.gem_boost(st, user, mv)
		if gem > 0:
			o["gem"] = gem
	var r := DamageCalc.compute(st, user, target, mv, o)
	if float(r.eff) == 0.0:
		st.log_msg("It doesn't affect %s..." % target.name)
		return 0
	if user.vol.has("charge") and int(mv.type) == TypeChart.ELECTRIC:
		user.vol.erase("charge")
	var dmg := int(r.damage)
	if opts.get("leave_one", false):
		dmg = mini(dmg, target.hp - 1)
	if r.berry:
		st.log_msg("The %s weakened the damage to %s!" % [st.bd.item_name(target.item), target.name])
		ItemHooks.consume(st, target, true)
	# Substitute takes the hit (sound moves and Infiltrator go through).
	if target.vol.has("substitute") and target != user and not mv.get("sound", false) and not mv.get("bypass_sub", false) \
			and not AbilityHooks.infiltrates(st, user):
		var sub := int(target.vol.substitute)
		var d := mini(dmg, sub)
		if r.crit:
			st.log_msg("A critical hit!")
		st.log_msg("The substitute took damage for %s!" % target.name)
		if not opts.get("quiet_eff", false):
			st.log_msg(_eff_text(float(r.eff)))
		if sub - d <= 0:
			target.vol.erase("substitute")
			st.log_msg("%s's substitute faded!" % target.name)
			st.emit({"e": "sub", "side": target.side_id, "slot": target.slot, "on": false})
		else:
			target.vol["substitute"] = sub - d
		target.vol["sub_hit"] = true
		return maxi(d, 1)
	# Survive the hit: Endure, Sturdy, Focus Sash / Focus Band.
	if dmg >= target.hp:
		if target.vol.has("endure"):
			dmg = target.hp - 1
			target.vol["endured_hit"] = true
		else:
			dmg = AbilityHooks.cap_damage(st, target, dmg)
			if dmg >= target.hp:
				dmg = ItemHooks.cap_damage(st, target, dmg)
	dmg = mini(dmg, target.hp)
	if r.crit:
		st.log_msg("A critical hit!")
	var hp_before := target.hp
	st._in_hit = true
	st.damage(target, dmg, "")
	st._in_hit = false
	if not opts.get("quiet_eff", false):
		st.log_msg(_eff_text(float(r.eff)))
	if target.vol.has("endured_hit"):
		target.vol.erase("endured_hit")
		st.log_msg("%s endured the hit!" % target.name)
	if target.vol.has("sturdy_hit"):
		target.vol.erase("sturdy_hit")
		st.log_msg("%s endured the hit!" % target.name)
	if (int(mv.type) == TypeChart.FIRE or mv.get("thaws", false)) and target.status == "frz" and not target.fainted() and int(mv.cat) != 2:
		st.cure(target, "%s thawed out!" % target.name)
	# What Counter / Mirror Coat / Metal Burst answer, and Rage Fist's count.
	target.vol["last_hit"] = {"dmg": dmg, "cat": int(mv.cat), "side": user.side_id, "slot": user.slot}
	if dmg > 0:
		target.set_meta("times_hit", int(target.get_meta("times_hit", 0)) + 1)
	if target.fainted():
		if target.vol.has("destiny_bond") and user.side_id != target.side_id and not user.fainted():
			st.damage(user, user.hp, "%s took its attacker down with it!" % target.name)
		AbilityHooks.on_ko(st, user)
	if not opts.get("future", false):
		AbilityHooks.on_contact(st, user, target, mv)
	AbilityHooks.on_hit_taken(st, user, target, mv, bool(r.crit), hp_before)
	ItemHooks.on_hit_taken(st, user, target, mv, dmg, float(r.eff))
	if not target.fainted() and not opts.get("no_flinch_item", false) and ItemHooks.flinch_roll(st, user):
		st.flinch(target)
	return maxi(dmg, 1) if dmg >= 0 else 0

static func _eff_text(eff: float) -> String:
	if eff > 1.0:
		return "It's super effective!"
	if eff > 0.0 and eff < 1.0:
		return "It's not very effective..."
	return ""

# Secondary effects need a living target that took the hit itself (not a Substitute), without Shield Dust /
# Covert Cloak, and a user without Sheer Force.
static func _secondary_ok(st, user: BattleMon, target: BattleMon) -> bool:
	if target.fainted() or target.vol.has("sub_hit"):
		return false
	if not AbilityHooks.allows_secondary(st, target) or ItemHooks.blocks_secondary(st, target):
		return false
	return AbilityHooks.key(st, user) != "sheer_force"

# Profile entries can carry a "todo" note: a part of the effect that isn't implemented yet.
static func _todo(st, eff: Dictionary) -> void:
	if eff.has("todo"):
		st.note_todo(str(eff.todo))
