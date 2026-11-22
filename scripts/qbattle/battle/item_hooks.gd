class_name ItemHooks
extends RefCounted
## ItemHooks — what held items do in battle, keyed by OUR hook names. The ROM stores item ids only;
## res://profiles/quetzal_a9v1_battle.json "items" maps ids to our keys (tools/gen_battle_profile.py matches the
## ROM's own item names to Showdown item ids, so only ids + our keys are stored). Numbers are the public Gen 9
## values with Pokémon Showdown (MIT) as the reference; our own code.
##
## Keys: residual_heal (Leftovers), black_sludge, life_orb, choice{st}, assault_vest, eviolite, focus_sash,
## focus_band, weakness_policy, air_balloon, rocky_helmet, expert_belt, cat_boost{cat}, type_boost{type},
## gem{type}, resist_berry{type}, pinch_heal{frac|hp, at, hates?}, cure_berry{s[]}, pinch_boost{st},
## white_herb, mental_herb, power_herb, flinch_item, quick_claw, evasion_item, wide_lens, zoom_lens,
## crit_item, shell_bell, orb{s}, light_clay, weather_rock{w}, terrain_extender, boots, big_root, lucky_egg,
## loaded_dice, throat_spray, smoke_ball, shed_shell, pads, goggles, cloak, clear_amulet, punch_glove,
## blunder_policy, exp_share, lagging, iron_ball, metronome_item (TODO: consecutive-use boost).
## Berries (pinch_heal, cure_berry, pinch_boost, resist_berry) are eaten and gone after the battle; other
## items used up in battle come back afterwards (Gen 9 rule, see BattleMon.to_party).
## An item does nothing while the holder has Klutz, is under Embargo, or Magic Room is up.
## Depends on: BattleData, BattleMon, AbilityHooks, TypeChart. Used by: DamageCalc, BattleRules, BattleState,
## MoveEffects, BattleAI.

const BERRY_KEYS := ["pinch_heal", "cure_berry", "pinch_boost", "resist_berry"]

## The hook dictionary of m's held item ({} if none or suppressed).
static func hook(st, m: BattleMon) -> Dictionary:
	if m == null or m.item <= 0:
		return {}
	if m.vol.has("embargo") or st.field.has("magic_room") or AbilityHooks.klutz(st, m):
		return {}
	return st.bd.item_hook(m.item)

## Our key for m's held item ("" if none / no effect).
static func key(st, m: BattleMon) -> String:
	return str(hook(st, m).get("k", ""))

## True if the item id is a berry (by our hook key).
static func is_berry(bd: BattleData, item: int) -> bool:
	return str(bd.item_hook(item).get("k", "")) in BERRY_KEYS

## True when the item can be given to a Pokémon as a held item: it is a real item, not a ball and not
## battle medicine (Potions, Ethers, Revives, X items, Dire Hit, Guard Spec. can't be held). The screen
## additionally excludes TMs and key items via the ROM pocket byte; the engine has no pocket data.
static func holdable(bd: BattleData, item: int) -> bool:
	if item <= 0 or bd == null or not bd.ok():
		return false
	if not bd.ball(item).is_empty():
		return false
	return bd.item_kinds.get(str(item), {}).is_empty()

## Removes m's item for good this battle (eaten, popped, knocked off). Sets Unburden's flag.
## used = true when the item was actually USED (berry eaten, gem spent, Focus Sash popped, etc.) as
## opposed to removed by Knock Off / Trick / Thief: only then do Harvest (record the berry), Cheek
## Pouch (heal 1/3 on a berry) and Symbiosis (an ally passes its item over) trigger.
static func consume(st, m: BattleMon, used: bool = false) -> void:
	if m.item <= 0:
		return
	var was := m.item
	if is_berry(st.bd, m.item):
		m.vol["ate_berry"] = true
		if used:
			m.vol["ate_berry_item"] = m.item   # Harvest can restore it at the end of the turn
	m.item = 0
	m.vol["unburden"] = true
	if used:
		if is_berry(st.bd, was) and AbilityHooks.key(st, m) == "cheek_pouch" and m.hp < m.max_hp():
			st.heal(m, maxi(1, m.max_hp() / 3), "%s restored some HP using its %s!" % [m.name, st.bd.item_name(was)])
		if st.is_doubles():
			var al = st.ally_of(m)
			if al != null and AbilityHooks.key(st, al) == "symbiosis" and al.item > 0:
				m.item = al.item
				al.item = 0
				st.log_msg("%s's %s passed its %s to %s!" % [al.name, st.bd.ability_name(al.ability), st.bd.item_name(m.item), m.name])

# ------------------------------------------------------------------ damage modifiers (4096-based)

## Base-power modifiers from the attacker's item (type boosters x1.2, Muscle Band / Wise Glasses x1.1,
## Punching Glove x1.1). Gems are handled by gem_boost() because they are used up.
static func power_mods(st, user: BattleMon, _target: BattleMon, mv: Dictionary) -> Array:
	var out: Array = []
	var h := hook(st, user)
	match str(h.get("k", "")):
		"type_boost": if int(mv.type) == int(h.type): out.append(4915)
		"cat_boost": if int(mv.cat) == int(h.cat): out.append(4505)
		"punch_glove": if mv.get("punch", false): out.append(4506)
	return out

## Gem: x1.3 (5325) for the first damaging move of its type; the gem is used up. Returns the modifier or 0.
static func gem_boost(st, user: BattleMon, mv: Dictionary) -> int:
	var h := hook(st, user)
	if str(h.get("k", "")) == "gem" and int(mv.type) == int(h.type) and int(mv.cat) != 2:
		st.log_msg("The %s strengthened %s's power!" % [st.bd.item_name(user.item), mv.name])
		consume(st, user, true)
		return 5325
	return 0

## Attack-stat modifiers from the attacker's item (Choice Band / Specs x1.5).
static func atk_mods(st, user: BattleMon, special: bool) -> Array:
	var h := hook(st, user)
	if str(h.get("k", "")) == "choice":
		if (str(h.st) == "atk" and not special) or (str(h.st) == "spa" and special):
			return [6144]
	return []

## Defense-stat modifiers from the defender's item (Eviolite x1.5 both, Assault Vest x1.5 Sp. Def).
static func def_mods(st, target: BattleMon, special: bool) -> Array:
	match key(st, target):
		"eviolite": if st.bd.can_evolve(target.species): return [6144]
		"assault_vest": if special: return [6144]
	return []

## Final damage modifiers from items: Expert Belt x1.2 on super-effective hits, Life Orb x1.3 (5324), and the
## target's resist berry x0.5 (Chilan Berry works on any Normal hit). Pure: the berry is eaten by
## MoveEffects.hit when DamageCalc reports "berry" (resist_berry_applies).
static func final_mods(st, user: BattleMon, target: BattleMon, mv: Dictionary, eff: float) -> Array:
	var out: Array = []
	match key(st, user):
		"expert_belt": if eff > 1.0: out.append(4915)
		"life_orb": out.append(5324)
	if resist_berry_applies(st, target, mv, eff):
		out.append(2048)
	return out

## True when the target's resist berry halves this hit.
static func resist_berry_applies(st, target: BattleMon, mv: Dictionary, eff: float) -> bool:
	var th := hook(st, target)
	return str(th.get("k", "")) == "resist_berry" and int(mv.type) == int(th.type) \
		and (eff > 1.0 or int(th.type) == TypeChart.NORMAL) and not AbilityHooks.unnerved(st, target)

## Speed modifiers from items (Choice Scarf x1.5, Iron Ball x0.5).
static func speed_mods(st, m: BattleMon) -> Array:
	var h := hook(st, m)
	match str(h.get("k", "")):
		"choice": if str(h.st) == "spe": return [6144]
		"iron_ball": return [2048]
	return []

## Accuracy modifiers: user's Wide Lens x1.1 / Zoom Lens x1.2 (if the target already moved); target's
## Bright Powder / Lax Incense x0.9.
static func acc_mods(st, user: BattleMon, target: BattleMon) -> Array:
	var out: Array = []
	match key(st, user):
		"wide_lens": out.append(4505)
		"zoom_lens": if target != null and st.has_acted(target): out.append(4915)
	if target != null and key(st, target) == "evasion_item":
		out.append(3686)
	return out

## Extra crit stages (Scope Lens / Razor Claw +1).
static func crit_stage(st, m: BattleMon) -> int:
	return 1 if key(st, m) == "crit_item" else 0

# ------------------------------------------------------------------ simple queries

## Choice item lock: the move index m is locked into, or -1.
static func choice_lock(st, m: BattleMon) -> int:
	if key(st, m) != "choice" or not m.vol.has("choice_lock"):
		return -1
	return int(m.vol.choice_lock)

## True when contact effects don't apply for this attacker (Protective Pads, Punching Glove on punches).
static func no_contact(st, user: BattleMon, mv: Dictionary) -> bool:
	var k := key(st, user)
	return k == "pads" or (k == "punch_glove" and mv.get("punch", false))

## Safety Goggles: immune to powder moves and weather damage.
static func powder_immune(st, m: BattleMon) -> bool:
	return key(st, m) == "goggles"

## Covert Cloak: immune to secondary effects of moves.
static func blocks_secondary(st, m: BattleMon) -> bool:
	return key(st, m) == "cloak"

## Clear Amulet: foes can't lower its stats.
static func blocks_drops(st, m: BattleMon) -> bool:
	return key(st, m) == "clear_amulet"

## Heavy-Duty Boots: no entry hazards.
static func ignores_hazards(st, m: BattleMon) -> bool:
	return key(st, m) == "boots"

## Air Balloon: not grounded until hit.
static func floats(st, m: BattleMon) -> bool:
	return key(st, m) == "air_balloon"

## Iron Ball: always grounded.
static func grounds(st, m: BattleMon) -> bool:
	return key(st, m) == "iron_ball"

## Shed Shell: can always switch out.
static func shed_shell(st, m: BattleMon) -> bool:
	return key(st, m) == "shed_shell"

## Smoke Ball: always escapes from wild battles.
static func smoke_ball(st, m: BattleMon) -> bool:
	return key(st, m) == "smoke_ball"

## Lagging Tail / Full Incense: moves last within its priority bracket.
static func moves_last(st, m: BattleMon) -> bool:
	return key(st, m) == "lagging"

## Loaded Dice: 2-5 hit moves hit 4-5 times.
static func loaded_dice(st, m: BattleMon) -> bool:
	return key(st, m) == "loaded_dice"

## Big Root: draining moves (and Leech Seed, Aqua Ring, Ingrain) heal x1.3 (5324).
static func drain_heal(st, m: BattleMon, n: int) -> int:
	return DamageCalc.modify_i(n, 5324) if key(st, m) == "big_root" else n

## Number of turns for a weather the mon sets (8 with the matching rock, else 5).
static func weather_turns(st, m: BattleMon, w: String) -> int:
	var h := hook(st, m)
	if str(h.get("k", "")) == "weather_rock" and (str(h.w) == w or (str(h.w) == "hail" and w == "snow")):
		return 8
	return 5

## Number of turns for a terrain the mon sets (8 with Terrain Extender).
static func terrain_turns(st, m: BattleMon) -> int:
	return 8 if key(st, m) == "terrain_extender" else 5

## Number of turns for screens (8 with Light Clay).
static func screen_turns(st, m: BattleMon) -> int:
	return 8 if key(st, m) == "light_clay" else 5

## EXP multiplier from the holder's item (Lucky Egg x1.5).
static func exp_mult(bd: BattleData, m: BattleMon) -> float:
	return 1.5 if str(bd.item_hook(m.item).get("k", "")) == "lucky_egg" else 1.0

# ------------------------------------------------------------------ event hooks

## On entry: Air Balloon announces itself.
static func on_entry(st, m: BattleMon) -> void:
	if key(st, m) == "air_balloon":
		st.log_msg("%s floats in the air with its Air Balloon!" % m.name)

## Damage cap from items before it is applied: Focus Sash (full HP), Focus Band (10%). Returns the damage.
static func cap_damage(st, target: BattleMon, dmg: int) -> int:
	if dmg < target.hp:
		return dmg
	match key(st, target):
		"focus_sash":
			if target.hp == target.max_hp() and target.hp > 1:
				st.log_msg("%s hung on using its Focus Sash!" % target.name)
				consume(st, target, true)
				return target.hp - 1
		"focus_band":
			if st.rng.chance(10):
				st.log_msg("%s hung on using its Focus Band!" % target.name)
				return target.hp - 1
	return dmg

## After a damaging hit on target (by user, dealing dmg, effectiveness eff): Air Balloon pops, Weakness
## Policy, Rocky Helmet, then pinch berries. Called by MoveEffects.hit.
static func on_hit_taken(st, user: BattleMon, target: BattleMon, mv: Dictionary, dmg: int, eff: float) -> void:
	var k := key(st, target)
	if dmg > 0 and k == "air_balloon":
		st.log_msg("%s's Air Balloon popped!" % target.name)
		consume(st, target)
		k = ""
	if target.fainted():
		pass
	elif k == "weakness_policy" and eff > 1.0 and not mv.get("fixed", false):
		st.log_msg("The Weakness Policy was activated!")
		consume(st, target, true)
		st.boost(target, "atk", 2, false)
		st.boost(target, "spa", 2, false)
	if k == "rocky_helmet" and mv.get("contact", false) and not user.fainted() and not no_contact(st, user, mv) and not AbilityHooks.no_contact(st, user):
		if not AbilityHooks.magic_guard(st, user):
			st.damage(user, maxi(1, user.max_hp() / 6), "%s was hurt by the Rocky Helmet!" % user.name)
	check_hp_items(st, target)

## After the user's damaging move is done (all targets): Life Orb recoil, Shell Bell, Throat Spray.
## total = damage dealt over all targets.
static func after_move(st, user: BattleMon, mv: Dictionary, total: int) -> void:
	if user.fainted():
		return
	match key(st, user):
		"life_orb":
			if total > 0 and not AbilityHooks.magic_guard(st, user) and not (AbilityHooks.key(st, user) == "sheer_force" and mv.get("has_secondary", false)):
				st.damage(user, maxi(1, user.max_hp() / 10), "%s lost some of its HP!" % user.name)
		"shell_bell":
			if total > 0 and user.hp < user.max_hp():
				st.heal(user, maxi(1, total / 8), "%s restored a little HP using its Shell Bell!" % user.name)
		"throat_spray":
			if mv.get("sound", false):
				st.log_msg("The Throat Spray raised %s's Sp. Atk!" % user.name)
				consume(st, user, true)
				st.boost(user, "spa", 1, false)

## Pinch berries and HP-threshold items; call after any HP loss. at = 2 → at or below 1/2, 4 → 1/4.
static func check_hp_items(st, m: BattleMon) -> void:
	if m.fainted() or m.slot < 0:
		return
	var h := hook(st, m)
	var k := str(h.get("k", ""))
	if not (k in ["pinch_heal", "pinch_boost"]) or AbilityHooks.unnerved(st, m):
		return
	var at := int(h.get("at", 4))
	if at == 4 and AbilityHooks.gluttony(st, m):
		at = 2
	if m.hp * at > m.max_hp():
		return
	var nm: String = st.bd.item_name(m.item)
	if k == "pinch_heal":
		if m.vol.has("heal_block") or m.hp >= m.max_hp():
			return
		var n := int(h.hp) if h.has("hp") else maxi(1, m.max_hp() / int(h.frac))
		if AbilityHooks.key(st, m) == "ripen":
			n *= 2   # Ripen doubles the healing from berries
		consume(st, m, true)
		st.heal(m, n, "%s restored its health using its %s!" % [m.name, nm])
		if h.has("hates") and m.nature_mult(str(h.hates)) < 1.0:
			st.confuse(m, false)
	else:
		consume(st, m, true)
		st.log_msg("%s used its %s!" % [m.name, nm])
		st.boost(m, str(h.st), 2 if AbilityHooks.key(st, m) == "ripen" else 1, false)

## Status-curing berries; call whenever m gets a status or confusion, and at the end of the turn.
static func check_status_items(st, m: BattleMon) -> void:
	if m.fainted() or m.slot < 0:
		return
	var h := hook(st, m)
	match str(h.get("k", "")):
		"cure_berry":
			if AbilityHooks.unnerved(st, m):
				return
			var cures: Array = h.get("s", [])
			var nm: String = st.bd.item_name(m.item)
			if m.status != "" and m.status in cures:
				consume(st, m, true)
				st.cure(m, "%s's %s cured its status!" % [m.name, nm])
			elif m.vol.has("confused") and "confusion" in cures:
				consume(st, m, true)
				m.vol.erase("confused")
				st.log_msg("%s's %s snapped it out of its confusion!" % [m.name, nm])
		"mental_herb":
			var any := false
			for v in ["attract", "taunt", "encore", "torment", "disabled", "heal_block"]:
				if m.vol.has(v):
					m.vol.erase(v)
					any = true
			if any:
				st.log_msg("%s used its Mental Herb to come back to its senses!" % m.name)
				consume(st, m, true)

## White Herb: after one of m's stats was lowered, restores every lowered stat.
static func check_white_herb(st, m: BattleMon) -> void:
	if key(st, m) != "white_herb" or m.fainted():
		return
	var any := false
	for k in m.stages:
		if int(m.stages[k]) < 0:
			m.stages[k] = 0
			any = true
	if any:
		st.log_msg("%s returned its stats to normal using its White Herb!" % m.name)
		consume(st, m, true)

## End of turn (item part, in the Leftovers slot): Leftovers / Black Sludge.
static func on_residual_heal(st, m: BattleMon) -> void:
	if m.fainted():
		return
	match key(st, m):
		"residual_heal":
			if m.hp < m.max_hp() and not m.vol.has("heal_block"):
				st.heal(m, maxi(1, m.max_hp() / 16), "%s restored a little HP using its Leftovers!" % m.name)
		"black_sludge":
			if m.has_type(TypeChart.POISON):
				if m.hp < m.max_hp() and not m.vol.has("heal_block"):
					st.heal(m, maxi(1, m.max_hp() / 16), "%s restored a little HP using its Black Sludge!" % m.name)
			elif not AbilityHooks.magic_guard(st, m):
				st.damage(m, maxi(1, m.max_hp() / 8), "%s was hurt by its Black Sludge!" % m.name)

## End of turn (last): Flame Orb / Toxic Orb.
static func on_turn_end_last(st, m: BattleMon) -> void:
	if m.fainted():
		return
	var h := hook(st, m)
	if str(h.get("k", "")) == "orb" and m.status == "" and BattleRules.can_get_status(st, m, str(h.s)):
		st.set_status(m, str(h.s), "%s's %s" % [m.name, st.bd.item_name(m.item)])

## Quick Claw: 20% to move first in its priority bracket (rolled once per turn by BattleState).
static func quick_claw(st, m: BattleMon) -> bool:
	return key(st, m) == "quick_claw" and st.rng.chance(20)

## King's Rock / Razor Fang: 10% flinch on damaging moves that can't flinch already.
static func flinch_roll(st, user: BattleMon) -> bool:
	return key(st, user) == "flinch_item" and st.rng.chance(10)

## Blunder Policy: +2 Speed after a miss (not OHKO moves).
static func on_miss(st, user: BattleMon) -> void:
	if key(st, user) == "blunder_policy":
		consume(st, user, true)
		st.boost(user, "spe", 2, false)

## Power Herb: skip the charge turn of a two-turn move (used up).
static func power_herb(st, m: BattleMon) -> bool:
	if key(st, m) == "power_herb":
		st.log_msg("%s became fully charged due to its Power Herb!" % m.name)
		consume(st, m, true)
		return true
	return false
