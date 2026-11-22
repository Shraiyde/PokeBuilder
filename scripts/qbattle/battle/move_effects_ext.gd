class_name MoveEffectsExt
extends RefCounted
## MoveEffectsExt — the battle-parity batch of move effects (Gen 9 / expansion GEN_LATEST behaviour, with
## Pokémon Showdown (MIT) as the numeric reference; our own code). MoveEffects.run() calls run() first;
## it returns the damage dealt, or -1 when the key isn't one of these (MoveEffects then handles it).
##
## Keys: pivot, knock_off, thief, trick, pluck, incinerate, hazard{h}, rapid_spin, defog, court_change,
## tidy_up, substitute, shed_tail, taunt, encore, disable, torment, attract, destiny_bond, perish_song,
## endure, sucker_punch, counter{cat}, room{r}, terrain{t}, terrain_power{t, who, m}, rampage, semi_invuln,
## skull_bash, focus_punch, weather_heal, shore_up, strength_sap, wish, healing_wish, helping_hand,
## follow_me, tailwind, aurora_veil, lucky_chant, charge, magnet_rise, stockpile, spit_up, swallow,
## smack_down, baton_pass, parting_shot, chilly_reception, se_boost, fell_stinger, final_gambit,
## self_half_hp, steel_roller, burn_up, double_shock, bolt_beak, brick_break, clear_smog, dire_claw,
## triple_arrows, echoed_voice, embargo, heal_block, heal_block_hit, entrainment, gastro_acid, role_play,
## skill_swap, set_ability{to}, soak, foresight, psycho_shift, topsy_turvy, acupressure, take_heart,
## toxic_thread, venom_drench, tar_shot, spite, nightmare, salt_cure, mean_look_hit, throat_chop, feint,
## fury_cutter, rollout, retaliate, last_respects, lash_out, stomping_tantrum, poltergeist, punishment,
## rage_fist, trump_card, weight_power{mode}, triple_kick, flying_press, weather_ball, terrain_pulse,
## sleep_talk (the call itself is in BattleState.use_move).
## Depends on: BattleState (st), BattleMon, MoveEffects.hit, DamageCalc, BattleRules, AbilityHooks, ItemHooks,
## TypeChart. Used by: MoveEffects.run.

static func run(st, user: BattleMon, target: BattleMon, mv: Dictionary, eff: Dictionary, k: String, chance: int) -> int:
	match k:
		# ---------------------------------------------------------------- plain hits (prepared by BattleState)
		"semi_invuln", "skull_bash", "focus_punch", "rampage", "flying_press", "weather_ball", "terrain_pulse":
			return MoveEffects.hit(st, user, target, mv)
		# ---------------------------------------------------------------- switching
		"pivot":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not user.fainted():
				st.request_pivot(user)
			return d
		"baton_pass":
			if not st.request_pivot(user, {"baton": true}):
				st.log_msg("But it failed!")
			return 0
		"parting_shot":
			var before := [int(target.stages.atk), int(target.stages.spa)]
			st.boost(target, "atk", -1, true)
			st.boost(target, "spa", -1, true)
			if int(target.stages.atk) != before[0] or int(target.stages.spa) != before[1]:
				st.request_pivot(user)
			return 0
		"chilly_reception":
			st.log_msg("%s is preparing to tell a chillingly bad joke!" % user.name)
			st.set_weather("snow", ItemHooks.weather_turns(st, user, "snow"))
			st.request_pivot(user)
			return 0
		"shed_tail":
			var cost := int(ceil(user.max_hp() / 2.0))
			if user.hp <= cost or st._bench(user.side_id, user.owner if user.side_id == 0 and st.is_doubles() else -1).is_empty():
				st.log_msg("But it failed!")
				return 0
			st.damage(user, cost, "%s shed its tail to create a decoy!" % user.name)
			user.vol["shed_sub"] = maxi(1, user.max_hp() / 4)
			st.request_pivot(user, {"shed_tail": true})
			return 0
		# ---------------------------------------------------------------- items
		"knock_off":
			var removable := target.item > 0 and not AbilityHooks.sticky_hold(st, target)
			var d := MoveEffects.hit(st, user, target, mv, {"pm": [6144] if removable else []})
			if d > 0 and removable and not user.fainted() and not target.vol.has("sub_hit") and target.item > 0:
				st.log_msg("%s knocked off %s's %s!" % [user.name, target.name, st.bd.item_name(target.item)])
				ItemHooks.consume(st, target)
			return d
		"thief":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and user.item == 0 and target.item > 0 and not user.fainted() and not target.vol.has("sub_hit") and not AbilityHooks.sticky_hold(st, target):
				st.log_msg("%s stole %s's %s!" % [user.name, target.name, st.bd.item_name(target.item)])
				user.item = target.item
				ItemHooks.consume(st, target)
			return d
		"trick":
			if (user.item == 0 and target.item == 0) or AbilityHooks.sticky_hold(st, target) or target.vol.has("substitute"):
				st.log_msg("But it failed!")
				return 0
			var a := user.item
			user.item = target.item
			target.item = a
			user.vol.erase("choice_lock")
			target.vol.erase("choice_lock")
			st.log_msg("%s switched items with its target!" % user.name)
			if user.item > 0:
				st.log_msg("%s obtained %s." % [user.name, st.bd.item_name(user.item)])
			if target.item > 0:
				st.log_msg("%s obtained %s." % [target.name, st.bd.item_name(target.item)])
			return 0
		"pluck":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not user.fainted() and ItemHooks.is_berry(st.bd, target.item) and not AbilityHooks.sticky_hold(st, target):
				var h: Dictionary = st.bd.item_hook(target.item)
				st.log_msg("%s stole and ate its target's %s!" % [user.name, st.bd.item_name(target.item)])
				ItemHooks.consume(st, target)
				match str(h.get("k", "")):
					"pinch_heal": st.heal(user, int(h.hp) if h.has("hp") else maxi(1, user.max_hp() / int(h.get("frac", 4))), "")
					"pinch_boost": st.boost(user, str(h.st), 1, false)
					"cure_berry":
						if user.status in h.get("s", []): st.cure(user, "%s was cured." % user.name)
			return d
		"incinerate":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and (ItemHooks.is_berry(st.bd, target.item) or str(st.bd.item_hook(target.item).get("k", "")) == "gem") and not target.vol.has("sub_hit"):
				st.log_msg("%s's %s was burnt up!" % [target.name, st.bd.item_name(target.item)])
				ItemHooks.consume(st, target)
			return d
		"poltergeist":
			if target.item <= 0:
				st.log_msg("But it failed!")
				return 0
			st.log_msg("%s is about to be attacked by its %s!" % [target.name, st.bd.item_name(target.item)])
			return MoveEffects.hit(st, user, target, mv)
		"embargo":
			if target.vol.has("embargo"):
				st.log_msg("But it failed!")
				return 0
			target.vol["embargo"] = 5
			st.log_msg("%s can't use items anymore!" % target.name)
			return 0
		# ---------------------------------------------------------------- hazards and side effects
		"hazard":
			var foe_side: Dictionary = st.sides[1 - user.side_id]
			var hz: Dictionary = st.hazards(foe_side)
			var h := str(eff.h)
			var cap: int = {"spikes": 3, "toxic_spikes": 2}.get(h, 1)
			if int(hz.get(h, 0)) >= cap:
				st.log_msg("But it failed!")
				return 0
			hz[h] = int(hz.get(h, 0)) + 1
			var who := "your" if foe_side.id == 0 else "the opposing"
			st.log_msg({"spikes": "Spikes were scattered on the ground all around %s team!", "toxic_spikes": "Poison spikes were scattered on the ground all around %s team!",
				"stealth_rock": "Pointed stones float in the air around %s team!", "sticky_web": "A sticky web has been laid out on the ground around %s team!"}.get(h, "%s") % who)
			return 0
		"rapid_spin":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not user.fainted():
				_clear_hazards(st, st.side_of(user))
				user.vol.erase("seeded")
				user.vol.erase("trapped")
				st.boost(user, "spe", 1, false)
			return d
		"defog":
			st.boost(target, "eva", -1, true)
			var ts: Dictionary = st.side_of(target)
			for c in ["reflect", "lightscreen", "aurora_veil", "safeguard", "mist"]:
				ts.cond.erase(c)
			_clear_hazards(st, ts)
			_clear_hazards(st, st.side_of(user))
			st.clear_terrain()
			return 0
		"court_change":
			var a: Dictionary = st.sides[0]
			var b: Dictionary = st.sides[1]
			var ca: Dictionary = a.cond
			a.cond = b.cond
			b.cond = ca
			var ha: Dictionary = a.get("hazards", {})
			a["hazards"] = b.get("hazards", {})
			b["hazards"] = ha
			st.log_msg("%s swapped the battle effects affecting each side of the field!" % user.name)
			return 0
		"tidy_up":
			for sd in st.sides:
				_clear_hazards(st, sd)
			for m in st.all_active():
				m.vol.erase("substitute")
			st.log_msg("Tidying up complete!")
			st.boost(user, "atk", 1, false)
			st.boost(user, "spe", 1, false)
			return 0
		"tailwind", "aurora_veil", "lucky_chant":
			var sd: Dictionary = st.side_of(user)
			if sd.cond.has(k) or (k == "aurora_veil" and not (st.weather in ["hail", "snow"]) ):
				st.log_msg("But it failed!")
				return 0
			sd.cond[k] = 4 if k == "tailwind" else (ItemHooks.screen_turns(st, user) if k == "aurora_veil" else 5)
			var who := "your" if user.side_id == 0 else "the opposing"
			st.log_msg({"tailwind": "The Tailwind blew from behind %s team!", "aurora_veil": "Aurora Veil made %s team stronger against physical and special moves!",
				"lucky_chant": "Lucky Chant shielded %s team from critical hits!"}[k] % who)
			return 0
		"wish":
			var fx: Dictionary = st._slot_fx(st.side_of(user), user.slot)
			if fx.has("wish"):
				st.log_msg("But it failed!")
				return 0
			fx["wish"] = {"turns": 2, "hp": maxi(1, user.max_hp() / 2), "name": user.name}
			return 0
		"healing_wish":
			if st._bench(user.side_id, user.owner if user.side_id == 0 and st.is_doubles() else -1).is_empty():
				st.log_msg("But it failed!")
				return 0
			st._slot_fx(st.side_of(user), user.slot)["healing_wish"] = true
			st.damage(user, user.hp, "")
			return 0
		"helping_hand":
			if target == null or target == user or target.fainted():
				st.log_msg("But it failed!")
				return 0
			target.vol["helping_hand"] = true
			st.log_msg("%s is ready to help %s!" % [user.name, target.name])
			return 0
		"follow_me":
			if not st.is_doubles():
				st.log_msg("But it failed!")
				return 0
			st.side_of(user)["center"] = user.slot
			st.log_msg("%s became the center of attention!" % user.name)
			return 0
		# ---------------------------------------------------------------- field
		"room":
			st.toggle_field(str(eff.r))
			return 0
		"terrain":
			st.set_terrain(str(eff.t), ItemHooks.terrain_turns(st, user))
			return 0
		"terrain_power":
			var who: BattleMon = user if str(eff.get("who", "user")) == "user" else target
			var on: bool = st.terrain == str(eff.t) and st.is_grounded(who)
			var d := MoveEffects.hit(st, user, target, mv, {"pm": [int(round(float(eff.get("m", 2.0)) * 4096))] if on else []})
			if str(mv.name) == "Misty Explosion" and not user.fainted():
				st.damage(user, user.hp, "")
			return d
		"steel_roller":
			if st.terrain == "":
				st.log_msg("But it failed!")
				return 0
			var d := MoveEffects.hit(st, user, target, mv)
			st.clear_terrain()
			return d
		# ---------------------------------------------------------------- protection / survival
		"substitute":
			var cost := maxi(1, user.max_hp() / 4)
			if user.vol.has("substitute"):
				st.log_msg("%s already has a substitute!" % user.name)
				return 0
			if user.hp <= cost:
				st.log_msg("But it does not have enough HP left to make a substitute!")
				return 0
			st.damage(user, cost, "%s put in a substitute!" % user.name)
			user.vol["substitute"] = cost
			user.vol.erase("trapped")
			st.emit({"e": "sub", "side": user.side_id, "slot": user.slot, "on": true})
			return 0
		"endure":
			var n := int(user.vol.get("protect_chain", 0))
			if st.is_last_to_act(user) or st.rng.below(int(pow(3, mini(n, 6)))) != 0:
				user.vol.erase("protect_chain")
				st.log_msg("But it failed!")
				return 0
			user.vol["endure"] = true
			user.vol["protect_chain"] = n + 1
			user.vol["protect_used_this_turn"] = true
			st.log_msg("%s braced itself!" % user.name)
			return 0
		"destiny_bond":
			if user.vol.has("destiny_bond_last"):
				user.vol.erase("destiny_bond_last")
				st.log_msg("But it failed!")   # Gen 7+: fails when used twice in a row
				return 0
			user.vol["destiny_bond"] = true
			user.vol["destiny_bond_last"] = true
			st.log_msg("%s is hoping to take its attacker down with it!" % user.name)
			return 0
		"feint":
			if target.vol.has("protect"):
				target.vol.erase("protect")
				st.log_msg("%s fell for the feint!" % target.name)
			return MoveEffects.hit(st, user, target, mv)
		# ---------------------------------------------------------------- move restrictions
		"taunt":
			if target.vol.has("taunt") or AbilityHooks.aroma_veiled(st, target) or AbilityHooks.key(st, target) == "oblivious":
				st.log_msg("But it failed!")
				return 0
			target.vol["taunt"] = 4 if st.has_acted(target) else 3
			st.log_msg("%s fell for the taunt!" % target.name)
			return 0
		"encore":
			var li := target.move_index(int(target.vol.get("last_move", -1)))
			if li < 0 or target.vol.has("encore") or int(target.moves[li].pp) <= 0 or AbilityHooks.aroma_veiled(st, target):
				st.log_msg("But it failed!")
				return 0
			var lk := str(st.bd.effect_of(st.bd.move(int(target.moves[li].id))).get("k", ""))
			if lk in ["encore", "sleep_talk", "struggle"]:
				st.log_msg("But it failed!")
				return 0
			target.vol["encore"] = {"idx": li, "turns": 3}
			st.log_msg("%s received an encore!" % target.name)
			return 0
		"disable":
			var li := target.move_index(int(target.vol.get("last_move", -1)))
			if li < 0 or target.vol.has("disabled") or AbilityHooks.aroma_veiled(st, target):
				st.log_msg("But it failed!")
				return 0
			target.vol["disabled"] = {"idx": li, "turns": 4}
			st.log_msg("%s's %s was disabled!" % [target.name, st.bd.move_name(int(target.moves[li].id))])
			return 0
		"torment":
			if target.vol.has("torment") or AbilityHooks.aroma_veiled(st, target):
				st.log_msg("But it failed!")
				return 0
			target.vol["torment"] = true
			st.log_msg("%s was subjected to torment!" % target.name)
			return 0
		"heal_block":
			for t in [target] + ([st.ally_of(target)] if st.is_doubles() and st.ally_of(target) != null else []):
				if t.vol.has("heal_block") or AbilityHooks.aroma_veiled(st, t):
					continue
				t.vol["heal_block"] = 5
				st.log_msg("%s was prevented from healing!" % t.name)
			return 0
		"heal_block_hit":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and MoveEffects._secondary_ok(st, user, target) and not target.vol.has("heal_block"):
				target.vol["heal_block"] = 2
				st.log_msg("%s was prevented from healing!" % target.name)
			return d
		"throat_chop":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and MoveEffects._secondary_ok(st, user, target):
				target.vol["throat_chop"] = 2
			return d
		"spite":
			var li := target.move_index(int(target.vol.get("last_move", -1)))
			if li < 0 or int(target.moves[li].pp) <= 0:
				st.log_msg("But it failed!")
				return 0
			var cut := mini(4, int(target.moves[li].pp))
			target.moves[li].pp = int(target.moves[li].pp) - cut
			st.log_msg("It reduced the PP of %s's %s by %d!" % [target.name, st.bd.move_name(int(target.moves[li].id)), cut])
			return 0
		# ---------------------------------------------------------------- status-like volatiles
		"attract":
			if not (user.gender in [0, 1] and target.gender in [0, 1] and user.gender != target.gender) or target.vol.has("attract") \
					or AbilityHooks.key(st, target) == "oblivious" or AbilityHooks.aroma_veiled(st, target):
				st.log_msg("But it failed!")
				return 0
			target.vol["attract"] = {"side": user.side_id, "slot": user.slot}
			st.log_msg("%s fell in love!" % target.name)
			ItemHooks.check_status_items(st, target)
			return 0
		"perish_song":
			for m in st.all_active():
				if m.vol.has("perish") or (m != user and AbilityHooks.key(st, m) == "soundproof"):
					continue
				m.vol["perish"] = 4
			st.log_msg("All Pokémon that heard the song will faint in three turns!")
			return 0
		"nightmare":
			if target.status != "slp" or target.vol.has("nightmare"):
				st.log_msg("But it failed!")
				return 0
			target.vol["nightmare"] = true
			st.log_msg("%s began having a nightmare!" % target.name)
			return 0
		"foresight":
			if str(mv.name) == "Miracle Eye":
				target.vol["miracle_eye"] = true
			else:
				target.vol["identified"] = true
			st.log_msg("%s was identified!" % target.name)
			return 0
		"salt_cure":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not target.fainted() and not target.vol.has("salt_cure") and not target.vol.has("sub_hit"):
				target.vol["salt_cure"] = true
				st.log_msg("%s is being salt cured!" % target.name)
			return d
		"mean_look_hit":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and MoveEffects._secondary_ok(st, user, target) and not target.vol.has("cant_flee"):
				target.vol["cant_flee"] = {"side": user.side_id, "slot": user.slot}
				st.log_msg("%s can no longer escape!" % target.name)
			return d
		"smack_down":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not target.fainted() and not target.vol.has("sub_hit"):
				var was_up: bool = not st.is_grounded(target) or target.vol.has("semi_invuln")
				target.vol["smacked_down"] = true
				for v in ["magnet_rise", "telekinesis"]:
					target.vol.erase(v)
				if str(target.vol.get("semi_invuln", "")) == "air":
					target.vol.erase("semi_invuln")
					target.vol.erase("charging")
				if was_up:
					st.log_msg("%s fell straight down!" % target.name)
			return d
		"tar_shot":
			st.boost(target, "spe", -1, true)
			if not target.vol.has("tar_shot"):
				target.vol["tar_shot"] = true
				st.log_msg("%s became weaker to fire!" % target.name)
			return 0
		"magnet_rise":
			if user.vol.has("magnet_rise") or user.vol.has("ingrain") or user.vol.has("smacked_down") or st.field.has("gravity"):
				st.log_msg("But it failed!")
				return 0
			user.vol["magnet_rise"] = 5
			st.log_msg("%s levitated with electromagnetism!" % user.name)
			return 0
		"charge":
			user.vol["charge"] = true
			st.log_msg("%s began charging power!" % user.name)
			st.boost(user, "spd", 1, false)
			return 0
		# ---------------------------------------------------------------- stats and status
		"toxic_thread":
			st.boost(target, "spe", -1, true)
			st.try_status(target, "psn", false, user)
			return 0
		"venom_drench":
			if not (target.status in ["psn", "tox"]):
				st.log_msg("But it failed!")
				return 0
			for s in ["atk", "spa", "spe"]:
				st.boost(target, s, -1, true)
			return 0
		"topsy_turvy":
			var any := false
			for s in target.stages:
				if int(target.stages[s]) != 0:
					target.stages[s] = -int(target.stages[s])
					any = true
			st.log_msg("%s's stat changes were all reversed!" % target.name if any else "But it failed!")
			return 0
		"acupressure":
			var pool: Array = []
			for s in ["atk", "def", "spa", "spd", "spe", "acc", "eva"]:
				if int(target.stages[s]) < 6:
					pool.append(s)
			if pool.is_empty():
				st.log_msg("But it failed!")
				return 0
			st.boost(target, pool[st.rng.below(pool.size())], 2, false)
			return 0
		"take_heart":
			if user.status != "":
				st.cure(user, "%s's status returned to normal!" % user.name)
			st.boost(user, "spa", 1, false)
			st.boost(user, "spd", 1, false)
			return 0
		"psycho_shift":
			if user.status == "" or target.status != "" or not BattleRules.can_get_status(st, target, user.status, user):
				st.log_msg("But it failed!")
				return 0
			var s := user.status
			st.set_status(target, s, "")
			st.cure(user, "%s was cured." % user.name)
			return 0
		"clear_smog":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not target.fainted() and not target.vol.has("sub_hit"):
				target.reset_stages()
				st.log_msg("%s's stat changes were removed!" % target.name)
			return d
		"dire_claw":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and MoveEffects._secondary_ok(st, user, target) and st.rng.chance(chance):
				st.try_status(target, ["psn", "par", "slp"][st.rng.below(3)], false, user)
			return d
		"triple_arrows":
			var d := MoveEffects.hit(st, user, target, mv, {"no_flinch_item": true})
			if d > 0 and MoveEffects._secondary_ok(st, user, target):
				if st.rng.chance(AbilityHooks.secondary_chance(st, user, 50)):
					st.boost(target, "def", -1, true)
				if st.rng.chance(AbilityHooks.secondary_chance(st, user, 30)):
					st.flinch(target)
			return d
		"fell_stinger":
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and target.fainted() and not user.fainted():
				st.boost(user, "atk", 3, false)
			return d
		# ---------------------------------------------------------------- healing
		"weather_heal", "shore_up":
			var w: String = "" if AbilityHooks.weather_suppressed(st) else st.weather
			var m4096 := 2048
			if k == "shore_up":
				m4096 = 2732 if w == "sand" else 2048
			elif w == "sun":
				m4096 = 2732
			elif w in ["rain", "sand", "hail", "snow"]:
				m4096 = 1024
			if user.hp >= user.max_hp():
				st.log_msg("%s's HP is full!" % user.name)
				return 0
			st.heal(user, maxi(1, DamageCalc.modify_i(user.max_hp(), m4096)), "%s's HP was restored." % user.name)
			return 0
		"strength_sap":
			if int(target.stages.atk) <= -6:
				st.log_msg("But it failed!")
				return 0
			var amt := ItemHooks.drain_heal(st, user, BattleRules.staged_stat(target, "atk"))
			st.boost(target, "atk", -1, true)
			if AbilityHooks.liquid_ooze(st, target):
				st.damage(user, amt, "%s sucked up the liquid ooze!" % user.name)
			else:
				st.heal(user, amt, "%s had its energy drained!" % target.name)
			return 0
		"stockpile":
			var n := int(user.vol.get("stockpile", 0))
			if n >= 3:
				st.log_msg("But it failed!")
				return 0
			user.vol["stockpile"] = n + 1
			st.log_msg("%s stockpiled %d!" % [user.name, n + 1])
			st.boost(user, "def", 1, false)
			st.boost(user, "spd", 1, false)
			return 0
		"spit_up", "swallow":
			var n := int(user.vol.get("stockpile", 0))
			if n <= 0 or (k == "swallow" and user.hp >= user.max_hp()):
				st.log_msg("But it failed!")
				return 0
			var d := 0
			if k == "spit_up":
				d = MoveEffects.hit(st, user, target, mv, {"power": 100 * n})
			else:
				st.heal(user, user.max_hp() * [0, 1, 2, 4][n] / 4, "%s's HP was restored." % user.name)
			user.vol.erase("stockpile")
			st.boost(user, "def", -n, false)
			st.boost(user, "spd", -n, false)
			return d
		# ---------------------------------------------------------------- damage that depends on something
		"sucker_punch":
			var q: Dictionary = st.queued_move(target)
			if q.is_empty() or int(q.get("cat", 2)) == 2:
				st.log_msg("But it failed!")
				return 0
			return MoveEffects.hit(st, user, target, mv)
		"counter":
			var lh: Dictionary = user.vol.get("last_hit", {})
			var want := int(eff.get("cat", 0))
			if lh.is_empty() or int(lh.dmg) <= 0 or int(lh.side) == user.side_id or (want >= 0 and int(lh.cat) != want):
				st.log_msg("But it failed!")
				return 0
			var src: BattleMon = st.active(int(lh.side), int(lh.slot))
			if src == null or src.fainted():
				st.log_msg("But it failed!")
				return 0
			if DamageCalc.type_eff(st, user, src, mv) == 0.0:
				st.log_msg("It doesn't affect %s..." % src.name)
				return 0
			var d := mini(src.hp, int(lh.dmg) * 2 if want >= 0 else int(lh.dmg) * 3 / 2)
			st.damage(src, maxi(1, d), "")
			return d
		"final_gambit":
			if DamageCalc.type_eff(st, user, target, mv) == 0.0:
				st.log_msg("It doesn't affect %s..." % target.name)
				return 0
			var d := mini(target.hp, user.hp)
			st.damage(target, d, "")
			return d   # the user faints in BattleState.use_move
		"self_half_hp":
			var d := MoveEffects.hit(st, user, target, mv)
			if not user.fainted() and not AbilityHooks.magic_guard(st, user):
				st.damage(user, int(round(user.max_hp() / 2.0)), "%s cut its own HP to power up its move!" % user.name)
			return d
		"burn_up", "double_shock":
			var t := TypeChart.FIRE if k == "burn_up" else TypeChart.ELECTRIC
			if not user.has_type(t):
				st.log_msg("But it failed!")
				return 0
			var d := MoveEffects.hit(st, user, target, mv)
			if d > 0 and not user.fainted():
				if not user.vol.has("orig_types"):
					user.vol["orig_types"] = user.types.duplicate()
				var nt: Array = []
				for x in user.types:
					nt.append(TypeChart.MYSTERY if int(x) == t else int(x))
				user.types = nt
				st.log_msg("%s burned itself out!" % user.name if k == "burn_up" else "%s used up all its electricity!" % user.name)
			return d
		"se_boost":
			var se: bool = DamageCalc.type_eff(st, user, target, mv) > 1.0
			return MoveEffects.hit(st, user, target, mv, {"pm": [5461] if se else []})
		"bolt_beak":
			return MoveEffects.hit(st, user, target, mv, {"power": int(mv.power) * (1 if st.has_acted(target) else 2)})
		"brick_break":
			if DamageCalc.type_eff(st, user, target, mv) > 0.0:
				var ts: Dictionary = st.side_of(target)
				for c in ["reflect", "lightscreen", "aurora_veil"]:
					if ts.cond.has(c):
						ts.cond.erase(c)
						st.log_msg("The wall shattered!")
			return MoveEffects.hit(st, user, target, mv)
		"echoed_voice":
			var sd: Dictionary = st.side_of(user)
			var ev: Dictionary = sd.get("echoed", {"turn": -9, "n": 0})
			var n := int(ev.n) + 1 if int(ev.turn) == st.turn - 1 or int(ev.turn) == st.turn else 1
			if int(ev.turn) == st.turn:
				n = int(ev.n)
			sd["echoed"] = {"turn": st.turn, "n": n}
			return MoveEffects.hit(st, user, target, mv, {"power": mini(200, int(mv.power) * n)})
		"fury_cutter":
			var c := mini(int(user.vol.get("metronome_count", 0)), 2)
			return MoveEffects.hit(st, user, target, mv, {"power": mini(160, int(mv.power) << c)})
		"rollout":
			var lm: Dictionary = user.vol.get("locked_move", {})
			var n := int(lm.get("n", 0))
			var p := int(mv.power) << n
			if user.vol.has("defense_curl"):
				p *= 2
			var d := MoveEffects.hit(st, user, target, mv, {"power": p})
			if d > 0 and n < 4:
				user.vol["locked_move"] = {"idx": user.move_index(int(mv.id)), "n": n + 1}
			else:
				user.vol.erase("locked_move")
			return d
		"retaliate":
			var yes: bool = int(st.side_of(user).get("fainted_turn", -9)) == st.turn - 1
			return MoveEffects.hit(st, user, target, mv, {"power": int(mv.power) * (2 if yes else 1)})
		"last_respects":
			return MoveEffects.hit(st, user, target, mv, {"power": mini(5050, int(mv.power) + 50 * int(st.side_of(user).get("faints", 0)))})
		"lash_out":
			return MoveEffects.hit(st, user, target, mv, {"power": int(mv.power) * (2 if user.vol.has("stat_dropped") else 1)})
		"stomping_tantrum":
			return MoveEffects.hit(st, user, target, mv, {"power": int(mv.power) * (2 if user.vol.get("failed_last", false) else 1)})
		"punishment":
			var ups := 0
			for s in ["atk", "def", "spa", "spd", "spe", "acc", "eva"]:
				ups += maxi(0, int(target.stages[s]))
			return MoveEffects.hit(st, user, target, mv, {"power": mini(200, 60 + 20 * ups)})
		"rage_fist":
			return MoveEffects.hit(st, user, target, mv, {"power": mini(350, int(mv.power) + 50 * int(user.get_meta("times_hit", 0)))})
		"trump_card":
			var i := user.move_index(int(mv.id))
			var left := int(user.moves[i].pp) if i >= 0 else 0
			return MoveEffects.hit(st, user, target, mv, {"power": [200, 80, 60, 50][left] if left < 4 else 40})
		"weight_power":
			var tw := int(st.bd.species(target.species).get("weight", 0))
			var bp := 0
			if str(eff.get("mode", "target")) == "target":
				bp = 20 if tw < 100 else 40 if tw < 250 else 60 if tw < 500 else 80 if tw < 1000 else 100 if tw < 2000 else 120
			else:
				var uw := int(st.bd.species(user.species).get("weight", 0))
				var ratio := uw / maxi(1, tw)
				bp = 120 if ratio >= 5 else 100 if ratio >= 4 else 80 if ratio >= 3 else 60 if ratio >= 2 else 40
			return MoveEffects.hit(st, user, target, mv, {"power": bp})
		"triple_kick":
			# Each hit checks accuracy (Gen 5+); power grows by the base each hit (10/20/30, 20/40/60).
			var total := 0
			var landed := 0
			for i in 3:
				if target.fainted() or user.fainted():
					break
				if i > 0 and not ItemHooks.loaded_dice(st, user) and not BattleRules.hits(st, user, target, mv):
					break
				var d := MoveEffects.hit(st, user, target, mv, {"power": int(mv.power) * (i + 1), "quiet_eff": i > 0})
				if d <= 0:
					break
				total += d
				landed += 1
			if landed > 0:
				st.log_msg("The Pokémon was hit %d time%s!" % [landed, "" if landed == 1 else "s"])
			return total
		# ---------------------------------------------------------------- abilities and types
		"entrainment", "role_play", "skill_swap", "set_ability", "gastro_acid":
			return _ability_move(st, user, target, mv, eff, k)
		"soak":
			if target.types == [TypeChart.WATER, TypeChart.WATER]:
				st.log_msg("But it failed!")
				return 0
			if not target.vol.has("orig_types"):
				target.vol["orig_types"] = target.types.duplicate()
			target.types = [TypeChart.WATER, TypeChart.WATER]
			st.log_msg("%s transformed into the Water type!" % target.name)
			return 0
		"sleep_talk":
			st.log_msg("But it failed!")
			return 0
	return -1

static func _clear_hazards(st, side: Dictionary) -> void:
	var hz: Dictionary = side.get("hazards", {})
	if hz.is_empty():
		return
	var who := "your" if side.id == 0 else "the opposing"
	for h in hz.keys():
		st.log_msg({"spikes": "The spikes disappeared from the ground around %s team!", "toxic_spikes": "The poison spikes disappeared from the ground around %s team!",
			"stealth_rock": "The pointed stones disappeared from around %s team!", "sticky_web": "The sticky web has disappeared from the ground around %s team!"}.get(h, "%s") % who)
	hz.clear()

# Abilities that can't be copied / replaced (Showdown flags cantsuppress / noentrain / failroleplay, by our
# hook keys and a few names).
const FIXED_ABILITIES := ["Multitype", "Stance Change", "Schooling", "Comatose", "Shields Down", "Disguise", "RKS System",
	"Battle Bond", "Power Construct", "Ice Face", "Gulp Missile", "As One", "Zero to Hero", "Commander", "Tera Shift",
	"Protosynthesis", "Quark Drive", "Trace", "Wonder Guard", "Imposter", "Illusion", "Receiver", "Power of Alchemy", "Neutralizing Gas"]

static func _ability_move(st, user: BattleMon, target: BattleMon, mv: Dictionary, eff: Dictionary, k: String) -> int:
	var un: String = st.bd.ability_name(user.ability)
	var tn: String = st.bd.ability_name(target.ability)
	match k:
		"gastro_acid":
			if target.vol.has("ability_off") or tn in FIXED_ABILITIES:
				st.log_msg("But it failed!")
				return 0
			target.vol["ability_off"] = true
			st.log_msg("%s's Ability was suppressed!" % target.name)
		"entrainment":
			if user.ability == target.ability or un in FIXED_ABILITIES or tn in FIXED_ABILITIES or AbilityHooks.key(st, target) == "truant":
				st.log_msg("But it failed!")
				return 0
			_set_ability(target, user.ability)
			st.log_msg("%s acquired %s!" % [target.name, un])
			AbilityHooks.on_entry(st, target)
		"role_play":
			if user.ability == target.ability or tn in FIXED_ABILITIES or un in FIXED_ABILITIES:
				st.log_msg("But it failed!")
				return 0
			_set_ability(user, target.ability)
			st.log_msg("%s copied %s's %s!" % [user.name, target.name, tn])
			AbilityHooks.on_entry(st, user)
		"skill_swap":
			if tn in FIXED_ABILITIES or un in FIXED_ABILITIES:
				st.log_msg("But it failed!")
				return 0
			var a := user.ability
			_set_ability(user, target.ability)
			_set_ability(target, a)
			st.log_msg("%s swapped Abilities with its target!" % user.name)
			AbilityHooks.on_entry(st, user)
			AbilityHooks.on_entry(st, target)
		"set_ability":
			var want := str(eff.get("to", ""))
			var id := _ability_id(st, want)
			if id <= 0 or target.ability == id or tn in FIXED_ABILITIES or AbilityHooks.key(st, target) == "truant":
				st.log_msg("But it failed!")
				return 0
			_set_ability(target, id)
			st.log_msg("%s acquired %s!" % [target.name, st.bd.ability_name(id)])
			if want == "insomnia" and target.status == "slp":
				st.cure(target, "%s woke up!" % target.name)
	return 0

static func _set_ability(m: BattleMon, id: int) -> void:
	if not m.vol.has("orig_ability"):
		m.vol["orig_ability"] = m.ability
	m.ability = id
	m.vol.erase("ability_off")

# ROM ability id by a Showdown-style id ("insomnia", "simple"), matched against the ROM's own names.
static func _ability_id(st, want: String) -> int:
	for i in range(1, 400):
		var n: String = st.bd.ability_name(i)
		if n == "" or n == "-":
			continue
		if n.to_lower().replace(" ", "").replace("-", "").replace("'", "") == want:
			return i
	return -1
