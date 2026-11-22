class_name BattleAI
extends RefCounted
## BattleAI — picks actions for wild Pokémon and trainers. Deliberately simple and our own design:
##   wild:    a random move that has PP.
##   trainer: scores every move and picks the best, with a little randomness so it isn't fully predictable:
##            damaging move → expected % of the target's current HP (average roll x accuracy, KO bonus),
##            status move   → a fixed small score when it would do something (target has no status, stat
##                            not maxed), 0 when it would fail. Never switches voluntarily (TODO).
##            Battle parity: moves the target is immune to score 0, status moves into a Substitute score 0,
##            and only legal moves are considered (Choice lock, Taunt, Encore, Disable... via usable_moves).
## The ROM trainer record carries AI flags (side.ai); they are read from the ROM's own trainer tables and
## the low bits are the public Gen 3 AI flags (verified against the ROM: 2,615 of 2,616 trainers use only
## bits 0-4; the one exception, table 1 id 895 "BILL", also sets bit 8 and higher expansion bits):
##   0x001 CHECK_BAD_MOVE:      don't pick a move that would fail / do nothing when another exists.
##   0x002 TRY_TO_FAINT:        prefer moves that KO (bigger KO bonus).
##   0x004 CHECK_VIABILITY:     prefer super-effective moves, avoid resisted ones; switch out of a bad
##                              matchup when a benched mon is much better.
##   0x008 SETUP_FIRST_TURN:    prefer a setup move on the mon's first turn out.
##   0x010 RISKY:               don't shy away from two-turn / recharge / recoil / explosion moves.
##   0x020 PREFER_STRONGEST_MOVE: pick the highest-power damaging move, ignore utility.
##   0x040 PREFER_BATON_PASS:   prefer Baton Pass once set up.
##   0x080 DOUBLE_BATTLE:       the trainer is a double battle (carried in t.double, not used here).
##   0x100 HP_AWARE:            heal (moves) sooner when HP is low; only BILL sets it in this ROM.
##   bits 9+: expansion-only flags (only BILL sets any) — not decoded, ignored.
## Trainers also switch voluntarily (Gen 3 AI switches out of a bad matchup when it has a much better
## benched mon) and use their ROM items (Full Restore / Potions / Full Heal, each slot once per battle)
## when the active mon's HP is low. A trainer item is claimed when the action is chosen (BattleState runs
## the chosen action in the same resolve, so the claim is never speculative).
## Doubles (0.1.8): wild mons pick a random living foe; trainers aim each move at the foe it scores best
## against (spread moves are scored per target with the x0.75 spread factor via DamageCalc opts).
## All randomness goes through st.rng so server and client agree.
## Depends on: BattleState (st), BattleMon, DamageCalc, TypeChart, BattleRules. Used by: BattleState.

## Chooses an action for the mon in (side_id, slot).
## smart = use the trainer scoring even for a wild/player side (tests, a future "auto battle" option).
static func choose(st, side_id: int, slot: int, smart: bool = false) -> Dictionary:
	var m: BattleMon = st.active(side_id, slot)
	if m == null:
		return {}
	var foes: Array = st.foes_of(m)
	var target := {"side": 1 - side_id, "slot": foes[0].slot if foes.size() > 0 else 0}
	# Same legality rules as a player's choice (PP, Disable, Choice lock, Taunt, Encore, Torment, Assault
	# Vest, Gravity, Heal Block, Throat Chop): BattleState.usable_moves.
	var usable: Array = st.usable_moves(m)
	if usable.is_empty():
		return {"kind": "move", "move": 0, "target": target}   # → struggle
	if (st.sides[side_id].kind != "trainer" and not smart) or foes.is_empty():
		var pick: int = usable[st.rng.below(usable.size())]
		if foes.size() > 1:
			# Doubles: a wild mon aims at a random foe (Showdown's random AI does the same). Only rolled
			# when there is a real choice, so singles battles consume the RNG exactly as before.
			var f: BattleMon = foes[st.rng.below(foes.size())]
			target = {"side": f.side_id, "slot": f.slot}
		return {"kind": "move", "move": pick, "target": target}
	var flags := int(st.sides[side_id].get("ai", 0))
	# 1. Trainer items: a healing item when the active mon is hurt (each ROM item slot once per battle).
	var item_action := _trainer_item(st, side_id, m)
	if not item_action.is_empty():
		return item_action
	# 2. Voluntary switch out of a bad matchup (CHECK_VIABILITY / TRY_TO_FAINT trainers only).
	if st.sides[side_id].kind == "trainer":
		var switch_to := _switch_pick(st, side_id, m, foes, flags, usable)
		if switch_to >= 0:
			return {"kind": "switch", "to": switch_to}
	# 3. PREFER_STRONGEST_MOVE: the highest-power damaging move, utility ignored.
	if (flags & 0x20) != 0:
		var best_power := -1
		var best_i := -1
		for i in usable:
			var mv0: Dictionary = st.bd.move(int(m.moves[i].id))
			if int(mv0.get("cat", 2)) == 2 or int(mv0.get("power", 0)) <= 0:
				continue
			var p := int(st.prepare_move(m, mv0).get("power", 0))
			if p > best_power:
				best_power = p
				best_i = i
		if best_i >= 0:
			var tgt: BattleMon = foes[0]
			for f in foes:
				if _score(st, m, f, st.bd.move(int(m.moves[best_i].id)), flags) > _score(st, m, tgt, st.bd.move(int(m.moves[best_i].id)), flags):
					tgt = f
			return {"kind": "move", "move": best_i, "target": {"side": tgt.side_id, "slot": tgt.slot}}
	var best: int = usable[0]
	var best_score := -1.0
	for i in usable:
		var mv: Dictionary = st.bd.move(int(m.moves[i].id))
		var tgt: BattleMon = foes[0]
		for f in foes:   # doubles: aim at the foe this move hurts most
			if _score(st, m, f, mv, flags) > _score(st, m, tgt, mv, flags):
				tgt = f
		var raw: float = _score(st, m, tgt, mv, flags)
		# CHECK_BAD_MOVE: a move that would fail scores 0 — skip it when another move does something.
		if (flags & 0x01) != 0 and raw <= 0.0:
			continue
		var sc: float = raw + st.rng.below(10)   # 0-9 points of noise
		if sc > best_score:
			best_score = sc
			best = i
			target = {"side": tgt.side_id, "slot": tgt.slot}
	if best_score < 0.0:
		# Every move scored 0 (CHECK_BAD_MOVE filtered them all): fall back to the first usable move.
		best = usable[0]
		var tgt2: BattleMon = foes[0]
		target = {"side": tgt2.side_id, "slot": tgt2.slot}
	return {"kind": "move", "move": best, "target": target}

## A trainer's item use (Gen 3: trainers use their ROM items when the active mon is low — Full Restore /
## Potions at 25% HP or less, Full Heal for a status). Each item slot is usable once per battle
## (side.items_left, {str(id): count}); the item is claimed here, when the action is chosen. Returns {}
## when there is nothing to use. The 25% threshold is our choice: the ROM's exact item-use threshold is
## not in the decoded data (no trainer sets HP_AWARE except BILL), but 385 trainers carry these items.
static func _trainer_item(st, side_id: int, m: BattleMon) -> Dictionary:
	if st.sides[side_id].kind != "trainer":
		return {}
	var left: Dictionary = st.sides[side_id].get("items_left", {})
	if left.is_empty():
		return {}
	var hp_frac := float(m.hp) / maxf(1.0, float(m.max_hp()))
	var want_heal := hp_frac <= 0.25
	var want_cure := m.status != ""
	if not want_heal and not want_cure:
		return {}
	# Full Restore first (heals HP and status), then the smallest Potion that covers the missing HP
	# (don't waste a Hyper Potion on 10 HP), then the biggest partial Potion, then Full Heal for a
	# status alone (it never outranks a healing item when HP is low).
	var best := -1
	var best_sc := -1.0
	for k in left.keys():
		var id := int(k)
		if int(left[k]) <= 0:
			continue
		var ik: Dictionary = st.bd.item_kinds.get(str(id), {})
		var sc := -1.0
		match str(ik.get("k", "")):
			"heal":
				if not want_heal:
					continue
				var heal_n := int(ik.get("hp", 0))
				if heal_n >= 9999:
					sc = 1000.0   # Full Restore: heals all HP and cures status
				elif heal_n >= m.max_hp() - m.hp:
					sc = 500.0 - heal_n   # covers the missing HP: smallest such potion wins
				else:
					sc = float(heal_n)   # partial heal: biggest potion wins
			"cure":
				if want_cure and m.status in ik.get("s", []):
					sc = 10.0
		if sc > best_sc:
			best_sc = sc
			best = id
	if best < 0:
		return {}
	var key := str(best)
	left[key] = int(left[key]) - 1
	if int(left[key]) <= 0:
		left.erase(key)
	return {"kind": "item", "item": best, "to": m.party_index}

## Voluntary switching (Gen 3 AI): when the active mon's best move is nearly useless against the current
## foe (score < 20 — resisted / immune / status that would fail) and a benched mon's best move against
## the same foe is much better (>= 50 and at least twice the active's), send the benched mon in. Only for
## CHECK_VIABILITY / TRY_TO_FAINT trainers, never when trapped, never in the turn the mon just arrived
## (turns_in 0 — the trainer just chose this lead). Returns the bench index or -1.
static func _switch_pick(st, side_id: int, m: BattleMon, foes: Array, flags: int, usable: Array) -> int:
	if (flags & 0x06) == 0:
		return -1
	if int(m.vol.get("turns_in", 0)) <= 0:
		return -1
	if m.vol.has("trapped") or m.vol.has("cant_flee") or AbilityHooks.trapped_by(st, m) != "":
		return -1
	var side: Dictionary = st.sides[side_id]
	var bench: Array = st._bench(side_id, -1)
	if bench.is_empty():
		return -1
	var cur := 0.0
	for f in foes:
		cur = maxf(cur, _best_score(st, m, f, flags, usable))
	if cur >= 20.0:
		return -1
	var best_i := -1
	var best_sc := 0.0
	for i in bench:
		var b: BattleMon = side.mons[i]
		var sc := 0.0
		for f in foes:
			sc = maxf(sc, _best_score(st, b, f, flags, st.usable_moves(b)))
		if sc > best_sc:
			best_sc = sc
			best_i = i
	if best_sc >= 50.0 and best_sc > cur * 2.0:
		return best_i
	return -1

## Best move score for `m` against foe `f` (noiseless, no RNG), over the given usable move slots.
static func _best_score(st, m: BattleMon, f: BattleMon, flags: int, usable: Array) -> float:
	var best := 0.0
	for i in usable:
		var mv: Dictionary = st.bd.move(int(m.moves[i].id))
		best = maxf(best, _score(st, m, f, mv, flags))
	return best

# Score for using mv on t (higher is better). Pure (no RNG) so it can be called repeatedly.
static func _score(st, m: BattleMon, t: BattleMon, mv: Dictionary, flags: int = 0) -> float:
	var eff: Dictionary = st.bd.effect_of(mv)
	var k := str(eff.get("k", "unknown"))
	mv = st.prepare_move(m, mv)   # the type / power it will really have (-ate, Weather Ball...)
	# Never pick a move the target is immune to (type chart or an absorbing ability).
	if t != m and t.side_id != m.side_id and int(mv.cat) != 2 and DamageCalc.type_eff(st, m, t, mv) == 0.0:
		return 0.0
	if int(mv.cat) == 2 and t.side_id != m.side_id and t.vol.has("substitute") and not mv.get("sound", false):
		if not (k in ["boost_self", "protect", "heal", "screen", "weather", "hazard", "room", "terrain", "substitute"]):
			return 0.0
	if int(mv.cat) == 2 or int(mv.power) == 0:
		match k:
			"status":
				return 30.0 if t.status == "" and BattleRules.can_get_status(st, t, str(eff.s)) else 0.0
			"confuse", "swagger", "flatter":
				return 20.0 if not t.vol.has("confused") else 0.0
			"boost_self":
				# SETUP_FIRST_TURN: a setup move on the first turn out is the plan, not a fallback.
				if (flags & 0x08) != 0 and m.vol.get("turns_in", 0) == 0:
					return 60.0
				return 25.0 if m.vol.get("turns_in", 0) == 0 and m.hp * 2 > m.max_hp() else 5.0
			"baton_pass":
				if (flags & 0x40) != 0:
					for s in m.stages:
						if int(m.stages[s]) > 0:
							return 80.0
				return 3.0
			"boost_target":
				return 15.0
			"heal", "rest":
				# HP_AWARE trainers heal sooner (below 2/3); the base rule is below 1/3.
				var low := m.hp * 3 < m.max_hp() * (2 if (flags & 0x100) != 0 else 1)
				return 60.0 if low else 0.0
			"leech_seed":
				return 25.0 if not t.vol.has("seeded") and not t.has_type(TypeChart.GRASS) else 0.0
			"protect":
				return 5.0
			"hazard":
				return 20.0 if int(st.hazards(st.sides[t.side_id]).get(str(eff.h), 0)) == 0 else 0.0
			"screen", "aurora_veil", "tailwind":
				return 18.0 if not st.side_of(m).cond.has(str(eff.get("side", k))) else 0.0
			"substitute":
				return 15.0 if not m.vol.has("substitute") and m.hp * 4 > m.max_hp() else 0.0
			"taunt", "encore", "torment", "disable":
				return 10.0 if not t.vol.has({"disable": "disabled"}.get(k, k)) else 0.0
			"weather":
				return 15.0 if st.weather != str(eff.w) else 0.0
			"terrain":
				return 15.0 if st.terrain != str(eff.t) else 0.0
		return 3.0
	var power := int(mv.power)
	if k in ["fixed_damage", "level_damage", "half_hp", "ohko", "flail", "eruption", "return_power", "frustration_power"]:
		power = 60   # rough guess for variable-power moves
	var avg := 0
	var probe := mv.duplicate()
	probe["power"] = maxi(1, power)
	var spread: bool = st.is_spread(m, mv)
	var r: Dictionary = DamageCalc.compute(st, m, t, probe, {"roll": 7, "crit": false, "spread": spread})
	avg = int(r.damage)
	var acc := float(mv.acc) / 100.0 if int(mv.acc) > 0 and int(mv.acc) <= 100 else 1.0
	var pct := 100.0 * mini(avg, t.hp) / maxf(1.0, t.hp)
	var sc := pct * acc
	# CHECK_VIABILITY: super-effective moves are worth more, resisted ones less.
	if (flags & 0x04) != 0:
		if float(r.eff) > 1.0:
			sc *= 1.25
		elif float(r.eff) < 1.0:
			sc *= 0.6
	if avg >= t.hp:
		sc += 100.0 if (flags & 0x02) != 0 else 40.0   # TRY_TO_FAINT: KO moves are the point
	# RISKY trainers don't shy away from two-turn / recharge / explosion moves.
	if (flags & 0x10) == 0:
		if k == "two_turn" or k == "recharge":
			sc *= 0.6
		if k == "explode":
			sc *= 0.3
	if spread:
		sc *= 1.5    # hits both foes (each for full damage in Gen 3 — no spread reduction)
		if (int(mv.get("target", 0)) & 0x20) != 0 and st.ally_of(m) != null:
			sc *= 0.4   # also hits our own ally (Earthquake-style): avoid unless much better
	return sc

## Which benched mon a trainer sends in after a faint: the one with the best move score vs. the first foe.
static func pick_replacement(st, side_id: int, bench: Array) -> int:
	var foes: Array = []
	for s in st.sides[1 - side_id].active:
		if s >= 0 and not st.sides[1 - side_id].mons[s].fainted():
			foes.append(st.sides[1 - side_id].mons[s])
	if foes.is_empty() or st.sides[side_id].kind != "trainer":
		return int(bench[0])
	# Trainers in the games mostly send their party in order; keep that (simple, predictable).
	return int(bench[0])
