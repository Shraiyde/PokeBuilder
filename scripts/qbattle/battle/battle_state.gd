class_name BattleState
extends RefCounted
## BattleState — the whole battle: sides, active Pokémon, turn resolution and the event stream.
## It is pure logic (no nodes, no UI, no network), deterministic for a given seed + action list, so the SAME
## code runs for offline battles and tests.
##
## Shape (offline only; the co-op doubles path that needed a second human pid was dropped in the
## port — see _setup. Singles and solo doubles, one owner with two slots, are supported):
##   sides[0] = players. sides[1] = foes (wild or trainer).
##   side = {id, kind: "player"|"wild"|"trainer", mons: [BattleMon], active: [mon index | -1 per slot],
##           cond: {reflect: turns, lightscreen: turns}, name, trainer_id, table}
##   Each player mon has .owner = the player's pid (0 in single-player); in solo doubles one owner fills both slots.
## Flow:
##   var st := BattleState.wild(bd, [{pid, party}], [[species, level]], seed)   (or .trainer(...))
##   var ev := st.begin()                 # send-out events
##   loop: st.needed() → [{side, slot, pid, kind: "action"|"switch"}]; st.submit(side, slot, action) for
##         each; when st.ready(): ev = st.resolve()  (AI actions are chosen inside resolve)
##   until st.over; then st.outcome ("win"|"lose"|"run"|"caught"|"forfeit") and st.results().
## Actions (from players or BattleAI):
##   {kind: "move", move: 0-3, target: {side, slot}}  target optional in singles
##   {kind: "switch", to: mon index in side.mons}       (also used to answer a "switch" need)
##   {kind: "run"}  wild only        {kind: "ball", item: item id}  wild only, catches on success
##   {kind: "item", item: item id, to: party index (default: the active mon), move: 0-3 (Ether)}
## Events (what the UI plays back; all plain dictionaries):
##   {e:"turn", n} {e:"msg", text} {e:"send", side, slot, mon: snapshot} {e:"move", side, slot, move, name}
##   {e:"hp", side, slot, hp, max} {e:"status", side, slot, status} {e:"stage", side, slot, stat, n}
##   {e:"faint", side, slot} {e:"exp", side, idx, gained, exp} {e:"level", side, idx, level, mon}
##   {e:"weather", w} {e:"shake", n} {e:"end", outcome}
##   (battle parity, additive) {e:"terrain", t} {e:"field", f, on} {e:"item", side, slot, item}
##   {e:"learn_full", side, idx, move}
## Doubles rules (0.1.8; behaviour reference Pokémon Showdown, MIT; our own code, checked by
## tests/battle_tests.gd "doubles" cases and the box-only doubles oracle tools/showdown_doubles_oracle.js):
##   - Targets come from the ROM move record's target bits (move_targets()): 0x10 user, 0x08 both foes,
##     0x20 foes + ally, 0x04 random foe, 0/1/2 = the chosen target. A move is a SPREAD move when it has
##     more than one target at the moment it executes (counted before accuracy/protect, like Showdown's
##     trySpreadMoveHit): each target then takes x0.75 damage (DamageCalc "spread" step).
##   - Retargeting: a chosen foe that has fainted → a random living foe; a chosen ally that has fainted →
##     the move fails ("no target"), as in Showdown's getTarget.
##   - Order: priority bracket, then current Speed across ALL active mons, random tie-break; after each
##     action the remaining actions are re-sorted with current Speed (Gen 8+ dynamic speed, Showdown).
##   - Reflect/Light Screen are x2732/4096 in doubles (DamageCalc).
##   - Solo doubles: side 0 has one owner filling both slots. A slot with no healthy mon left stays
##     empty; the side loses only when every mon on it has fainted. (TODO(port): co-op doubles with
##     two human pids is not ported.)
## Battle parity (batch 1, see docs/HANDOFF.md "Battle parity"):
##   - Field: weather (sun/rain/sand/hail/snow, 5 turns or 8 with a rock), terrain (electric/grassy/misty/
##     psychic), Trick Room, Gravity, Magic Room, Wonder Room (field{}); side conditions (side.cond: reflect,
##     lightscreen, aurora_veil, safeguard, mist, tailwind, lucky_chant — counted down) and hazards
##     (side.hazards: spikes 1-3, toxic_spikes 1-2, stealth_rock, sticky_web — permanent until removed);
##     slot effects (side.slot_fx[slot]: wish, healing_wish, future sight).
##   - Turn order: priority (+ Prankster/Gale Wings/Triage, Grassy Glide), then Quick Claw / Lagging Tail /
##     Stall inside the bracket, then Speed (Trick Room reverses it), then a random tie-break.
##   - Pivoting (U-turn, Volt Switch, Flip Turn, Parting Shot, Baton Pass, Shed Tail, Teleport, Chilly
##     Reception): a player mon that pivots pauses the turn: phase "switch" + a need {kind:"switch",
##     pivot:true}; after the choice, resolve() carries on with the rest of the turn. AI mons pick at once.
##   - Bag items in battle: {kind:"item", item, to (party index), move (for Ether)} for Potions, status
##     heals, Revives, Ethers, X items, Dire Hit, Guard Spec. (ROM item ids → our keys in profile "bag").
##   - End of turn follows the Gen 8/9 residual order (see _end_of_turn).
## Depends on: BattleData, BattleMon, BattleRng, BattleRules, DamageCalc, MoveEffects, AbilityHooks, ItemHooks,
## BattleAI. Used by: BattleController (offline), tests/battle_tests.gd,
## tests/battle_parity_tests.gd.

const PLAYER := 0
const FOE := 1

var bd: BattleData

var rng: BattleRng
var sides: Array = []
var format := "singles"        # "singles" | "doubles"
var kind := "wild"             # "wild" | "trainer"
var turn := 0
var weather := ""              # "", "rain", "sun", "sand", "hail", "snow"
var weather_turns := 0
var phase := "turn"            # "turn" (choose actions) | "switch" (replace fainted mons) | "pivot" (U-turn replacement) | "over"
var over := false
var outcome := ""
var events: Array = []         # events produced by the current begin()/resolve() call
var history: Array = []        # every event of the battle (debug)
var pending := {}              # "side:slot" -> action
var run_attempts := 0
var caught: BattleMon = null
var unknown_effects := {}      # ROM effect id -> count (moves that fell back to plain damage)
var todos := {}                # partial-effect notes from the profile -> count
var _order: Array = []         # this turn's acting mons, in order (for "moved last" checks)
var _acted: Array = []
var _struggle_id := -1
var caught_by := -1            # pid of the player whose ball caught the wild mon (single-player: the thrower)
var _cur_spread := false       # set while a move executes: true when it hits more than one target
var _faint_seq := {}           # mon instance id -> order in which its HP reached 0 (see _check_faints)
var _faint_counter := 0
var owner_names := {}          # pid -> display name (send-out messages)
# --- battle parity (field state, see header) ---
var terrain := ""              # "", "electric", "grassy", "misty", "psychic"
var terrain_turns := 0
var field := {}                # "trick_room" | "gravity" | "magic_room" | "wonder_room" -> turns left
var exp_share_all := false     # Gen 6+ Exp. Share for the whole party (benched mons get half EXP)
var ball_ctx := {}             # ball conditions from the overworld: {night, cave, water, fishing, caught_before, dex_caught}
var caught_ball := 0           # item id of the ball that caught the wild mon (0 = none)
var last_move_any := -1        # last move used by anyone (Copycat-style effects)
var leveled_up := {}           # player party index -> true when it gained a level (evolution checks after battle)
var learn_pending: Array = []  # [{idx, owner, move}] moves that need a "forget a move" choice after the battle
var _queue: Array = []         # this turn's remaining actions (kept while paused for a pivot switch)
var _pivot := {}               # {side, slot, pid, baton?, shed_tail?} of a player mon waiting to pivot out
var _in_hit := false           # MoveEffects.hit is applying damage: berries wait for its own check
var _in_opportunist := false   # Opportunist is copying a stat boost: don't recurse into itself

# ------------------------------------------------------------------ construction

## A wild battle. players = [{pid, party: [party records], name?}] (one player; extra players are dropped — see _setup).
## foes = [[species, level], ...] (1 for singles; 2 for a double wild battle; 1 foe in doubles = 2 vs 1).
static func wild(data: BattleData, players: Array, foes: Array, seed: int) -> BattleState:
	var st := BattleState.new()
	st._setup(data, players, seed)
	st.kind = "wild"
	var side := {"id": FOE, "kind": "wild", "mons": [], "active": [], "cond": {}, "name": ""}
	for f in foes:
		var m := BattleMon.wild(data, int(f[0]), int(f[1]), st.rng)
		m.side_id = FOE
		m.party_index = side.mons.size()
		side.mons.append(m)
	st.sides.append(side)
	if foes.size() >= 2:
		st.format = "doubles"
	st._fill_active()
	return st

## A trainer battle against an explicit foe party (port addition: the port has
## no trainer table, so the caller supplies the foe party directly instead of a
## trainer id). party = [{sp: species int id, lv: int, iv: int, moves: [move int
## ids], nat: int, abs: int, item: int, evs: [6 ints]}] (see BattleMon.from_trainer).
## name is the trainer's display name. Two or more foes = a doubles battle.
static func trainer_party(data: BattleData, players: Array, party: Array, trainer_name: String, seed: int) -> BattleState:
	var st := BattleState.new()
	st._setup(data, players, seed)
	st.kind = "trainer"
	var side := {"id": FOE, "kind": "trainer", "mons": [], "active": [], "cond": {}, "name": trainer_name,
		"trainer_id": -1, "table": 0, "ai": 0, "items": [], "items_left": {}}
	for pm in party:
		var m := BattleMon.from_trainer(data, pm, st.rng)
		m.side_id = FOE
		m.party_index = side.mons.size()
		side.mons.append(m)
	if side.mons.is_empty():
		var m := BattleMon.wild(data, 1, 5, st.rng)
		m.side_id = FOE
		side.mons.append(m)
	st.sides.append(side)
	if side.mons.size() >= 2:
		st.format = "doubles"
	st._fill_active()
	return st

## A trainer battle against ROM trainer `trainer_id` from trainer table `table` (0, 1 or 2).
static func trainer(data: BattleData, players: Array, trainer_id: int, table: int, seed: int) -> BattleState:
	var st := BattleState.new()
	st._setup(data, players, seed)
	st.kind = "trainer"
	var t := data.trainer(trainer_id, table)
	var side := {"id": FOE, "kind": "trainer", "mons": [], "active": [], "cond": {}, "name": str(t.get("name", "Trainer")),
		"trainer_id": trainer_id, "table": table, "ai": int(t.get("ai", 0)),
		"items": (t.get("items", []) as Array).duplicate(), "items_left": _trainer_items_left(t.get("items", []))}
	for pm in t.get("party", []):
		var m := BattleMon.from_trainer(data, pm, st.rng)
		m.side_id = FOE
		m.party_index = side.mons.size()
		side.mons.append(m)
	if side.mons.is_empty():
		# A broken/empty trainer entry should not crash the game: give it one placeholder-strength mon.
		var m := BattleMon.wild(data, 1, 5, st.rng)
		m.side_id = FOE
		side.mons.append(m)
	st.sides.append(side)
	# TODO(port): co-op doubles (two human players) is not ported — see _setup. The trainer fields two mons if it has two, else one (2 vs 1).
	# SOLO double battles (0.1.65, battle parity): a solo player against a trainer whose ROM record is a
	# double battle plays a doubles battle too — the player side gets two slots for one owner (the first
	# two healthy party members), the trainer fields two mons if it has two. Wild doubles never happen.
	if bool(t.get("double", false)):
		st.format = "doubles"
	st._fill_active()
	return st

## Remaining uses of a trainer's items: {str(item id): count} from the ROM record's 4 item slots
## (0 = empty). Each slot is usable once per battle (Gen 3: a trainer uses each of its items at most once).
static func _trainer_items_left(items: Array) -> Dictionary:
	var left := {}
	for it in items:
		var id := int(it)
		if id > 0:
			left[str(id)] = int(left.get(str(id), 0)) + 1
	return left

func _setup(data: BattleData, players: Array, seed: int) -> void:
	bd = data
	rng = BattleRng.new(seed)
	# TODO(port): co-op doubles (a second human player / pid) is not ported — offline only.
	# Extra players are dropped and the battle falls back to singles. Solo doubles (one owner
	# with two slots, e.g. a double trainer battle or a wild battle with two foes) is unaffected.
	if players.size() > 1:
		players = [players[0]]
	format = "singles"
	var side := {"id": PLAYER, "kind": "player", "mons": [], "active": [], "cond": {}, "name": "", "owners": []}
	for pl in players:
		var pid := int(pl.get("pid", 0))
		side.owners.append(pid)
		if str(pl.get("name", "")) != "":
			owner_names[pid] = str(pl.name)
		var party: Array = pl.get("party", [])
		for i in party.size():
			var m := BattleMon.from_party(bd, party[i], rng)
			m.owner = pid
			m.party_index = i
			m.side_id = PLAYER
			side.mons.append(m)
	sides.append(side)
	for i in bd.move_count():
		if str(bd.effect_of(bd.move(i)).get("k", "")) == "struggle":
			_struggle_id = i
			break

# Puts the first healthy mon(s) into the active slots (one per owner in doubles).
# Slot counts: singles 1/1. Doubles: the player side 2 (one owner, two slots, in solo doubles); the foe
# side 2 when it has at least two mons, else 1 (a single wild mon or a one-mon trainer = 2 vs 1).
func _fill_active() -> void:
	for side in sides:
		var slots := 1
		if format == "doubles":
			slots = 2 if (side.kind == "player" or side.mons.size() >= 2) else 1
		side.active = []
		var used := []
		for s in slots:
			var owner := -1
			if side.kind == "player" and side.owners.size() > s and format == "doubles":
				owner = int(side.owners[s])
			var pick := -1
			for i in side.mons.size():
				var m: BattleMon = side.mons[i]
				if m.fainted() or used.has(i):
					continue
				if owner >= 0 and m.owner != owner:
					continue
				pick = i
				break
			side.active.append(pick)
			if pick >= 0:
				used.append(pick)
				side.mons[pick].slot = s

## Starts the battle: send-out events and entry abilities. Returns the events.
func begin() -> Array:
	events = []
	if kind == "wild":
		var names := []
		for i in sides[FOE].active:
			if i >= 0:
				names.append(sides[FOE].mons[i].name)
		log_msg("A wild %s %s out!" % [" and ".join(names), "jump" if names.size() > 1 else "jumps"])
	else:
		log_msg("%s challenges you!" % sides[FOE].name)
	for side in [sides[FOE], sides[PLAYER]]:
		for s in side.active.size():
			if side.active[s] >= 0:
				_emit_send(side, s)
	for m in _speed_sorted(all_active()):
		AbilityHooks.on_entry(self, m)
	for m in _speed_sorted(all_active()):
		ItemHooks.on_entry(self, m)
		ItemHooks.check_hp_items(self, m)
	return _flush()

# ------------------------------------------------------------------ queries

## Active (non-fainted) mons on all sides.
func all_active() -> Array:
	var out: Array = []
	for side in sides:
		for i in side.active:
			if i >= 0 and not side.mons[i].fainted():
				out.append(side.mons[i])
	return out

## The active mon in a slot, or null.
func active(side_id: int, slot: int) -> BattleMon:
	if side_id < 0 or side_id >= sides.size() or slot < 0 or slot >= sides[side_id].active.size():
		return null
	var i: int = sides[side_id].active[slot]
	return sides[side_id].mons[i] if i >= 0 else null

## The side dictionary a mon belongs to.
func side_of(m: BattleMon) -> Dictionary:
	return sides[m.side_id]

## Living active foes of a mon.
func foes_of(m: BattleMon) -> Array:
	var out: Array = []
	var other: Dictionary = sides[1 - m.side_id]
	for i in other.active:
		if i >= 0 and not other.mons[i].fainted():
			out.append(other.mons[i])
	return out

## True in a doubles battle.
func is_doubles() -> bool:
	return format == "doubles"

## True if this move hits several targets at once (damage x0.75). While a move executes this is the
## value fixed by use_move() (number of targets at execution time, Showdown rule); outside a move (AI
## scoring, tests) it is predicted from the target bits and the current field. Always false in singles.
func is_spread(user: BattleMon, mv: Dictionary) -> bool:
	if not is_doubles():
		return false
	if _executing == user:
		return _cur_spread
	return move_targets(user, mv, {}, true).size() > 1

## The mon currently executing a move (null between moves); makes is_spread() return the fixed value.
var _executing: BattleMon = null

## Target bits of the ROM move record (Gen 3 layout, same facts as HMA's move table / Showdown's target
## names): 0 selected, 1 depends (Counter-style), 2 user-or-selected, 4 random foe, 8 both foes (Showdown
## "allAdjacentFoes"), 16 user, 32 foes and ally ("allAdjacent"), 64 foes' field, 128 ally.
const TGT_RANDOM := 0x04
const TGT_BOTH := 0x08
const TGT_USER := 0x10
const TGT_FOES_AND_ALLY := 0x20

## The living ally of a mon in doubles (the other active mon on its side), or null.
func ally_of(m: BattleMon) -> BattleMon:
	var side: Dictionary = sides[m.side_id]
	for i in side.active:
		if i >= 0 and side.mons[i] != m and not side.mons[i].fainted():
			return side.mons[i]
	return null

## The mons a move hits, at execution time, in hit order (foes-and-ally moves: the ally first, then foes).
## a.target = {side, slot} for single-target moves. predict = true: no RNG (random-target moves return
## one placeholder foe), used by is_spread() outside execution.
## Showdown rules: chosen foe fainted → random living foe; chosen ally fainted → [] (the move fails);
## no/invalid choice → random living foe (singles: the foe).
func move_targets(user: BattleMon, mv: Dictionary, a: Dictionary, predict: bool = false) -> Array:
	var bits := int(mv.get("target", 0))
	if (bits & TGT_USER) != 0:
		return [user]
	var foes := foes_of(user)
	if (bits & TGT_BOTH) != 0:
		return foes
	if (bits & TGT_FOES_AND_ALLY) != 0:
		# Showdown order (getMoveTargets "allAdjacent"): the ally first, then the foes in slot order.
		var out: Array = []
		var al := ally_of(user)
		if al != null:
			out.append(al)
		out.append_array(foes)
		return out
	if foes.is_empty() and ally_of(user) == null:
		return []
	# Struggle hits a random foe in doubles (Showdown "randomNormal"), whatever the ROM target bits say.
	if _struggle_id > 0 and int(mv.get("id", -1)) == _struggle_id:
		bits |= TGT_RANDOM
	if (bits & TGT_RANDOM) == 0:
		var t: Dictionary = a.get("target", {})
		if t.has("side") and t.has("slot"):
			var tside := int(t.side)
			var tslot := int(t.slot)
			var x := active(tside, tslot)
			if x != null and x != user:
				if not x.fainted():
					return [x]
				if tside == user.side_id:
					return []        # fainted ally: Showdown doesn't retarget, the move fails
			elif x == null and tside == user.side_id and tslot != user.slot and tslot >= 0 and tslot < sides[tside].active.size():
				return []            # empty ally slot: fails like a fainted ally
	if foes.is_empty():
		return []
	if predict or foes.size() == 1:
		return [foes[0]]
	return [foes[rng.below(foes.size())]]

## True if the mon is the last one still to act this turn (protect-style moves fail then).
func is_last_to_act(m: BattleMon) -> bool:
	for x in _order:
		if x != m and not _acted.has(x) and not x.fainted():
			return false
	return true

## True if m already acted this turn.
func has_acted(m: BattleMon) -> bool:
	return _acted.has(m) and m != _acted.back()

## Ends the battle with an outcome (used by effects such as teleport).
func end_as(o: String) -> void:
	_finish(o)

## True if `side` still has a healthy mon (active or benched).
func side_alive(side_id: int) -> bool:
	for m in sides[side_id].mons:
		if not m.fainted():
			return true
	return false

## What the players must send before the next resolve(). [{side, slot, pid, kind: "action"|"switch"}]
func needed() -> Array:
	var out: Array = []
	if over:
		return out
	var side: Dictionary = sides[PLAYER]
	for s in side.active.size():
		var key := "%d:%d" % [PLAYER, s]
		if pending.has(key):
			continue
		var m := active(PLAYER, s)
		var pid := int(side.owners[s]) if s < side.owners.size() else (int(side.owners[0]) if side.owners.size() > 0 else 0)
		if phase == "pivot":
			if not _pivot.is_empty() and int(_pivot.side) == PLAYER and int(_pivot.slot) == s:
				out.append({"side": PLAYER, "slot": s, "pid": pid, "kind": "switch", "pivot": true})
		elif phase == "switch":
			if (m == null or m.fainted()) and _bench(PLAYER, pid).size() > 0:
				out.append({"side": PLAYER, "slot": s, "pid": pid, "kind": "switch"})
		elif m != null and not m.fainted() and _forced_action(m).is_empty():
			out.append({"side": PLAYER, "slot": s, "pid": pid, "kind": "action"})
	return out

## True when every needed action has been submitted.
func ready() -> bool:
	return needed().is_empty()

## Healthy benched mon indexes a player (pid) may switch to. pid < 0 = anyone on the side.
func _bench(side_id: int, pid: int) -> Array:
	var out: Array = []
	var side: Dictionary = sides[side_id]
	for i in side.mons.size():
		var m: BattleMon = side.mons[i]
		if m.fainted() or side.active.has(i):
			continue
		if pid >= 0 and side.kind == "player" and is_doubles() and m.owner != pid:
			continue
		out.append(i)
	return out

## Checks an action without applying it. Returns "" if legal, else a short reason code.
func validate(side_id: int, slot: int, a: Dictionary) -> String:
	if over:
		return "battle_over"
	var m := active(side_id, slot)
	var k := str(a.get("kind", ""))
	if phase == "switch" or phase == "pivot":
		if k != "switch":
			return "need_switch"
		if phase == "pivot" and (_pivot.is_empty() or int(_pivot.side) != side_id or int(_pivot.slot) != slot):
			return "not_your_switch"
	match k:
		"move":
			if m == null or m.fainted():
				return "no_mon"
			if m.out_of_pp() or usable_moves(m).is_empty():
				return ""   # any move index → struggle
			var i := int(a.get("move", -1))
			return move_blocked(m, i)
		"switch":
			var to := int(a.get("to", -1))
			var pid := m.owner if m != null else (int(sides[side_id].owners[slot]) if sides[side_id].has("owners") and slot < sides[side_id].owners.size() else -1)
			if not _bench(side_id, pid).has(to):
				return "bad_switch"
			if phase == "turn" and m != null and not m.has_type(TypeChart.GHOST) and not ItemHooks.shed_shell(self, m):
				if m.vol.has("trapped") or m.vol.has("cant_flee") or AbilityHooks.trapped_by(self, m) != "":
					return "trapped"
			return ""
		"run":
			return "" if kind == "wild" else "no_run_trainer"
		"item":
			var ik: Dictionary = bd.item_kinds.get(str(int(a.get("item", 0))), {})
			if ik.is_empty():
				return "bad_item"
			var side_mons: Array = sides[side_id].mons
			var to := int(a.get("to", -1))
			if to >= side_mons.size() or (to >= 0 and side_id == PLAYER and is_doubles() and m != null and side_mons[to].owner != m.owner):
				return "bad_target"
			return ""
		"ball":
			if kind != "wild":
				return "no_ball_trainer"
			var foes := foes_of(m)
			if foes.size() != 1:
				return "two_targets"
			return ""
		"give_item":
			if side_id != PLAYER:
				return "bad_target"
			if not ItemHooks.holdable(bd, int(a.get("item", 0))):
				return "bad_item"
			var gto := int(a.get("to", -1))
			if gto < 0 or gto >= sides[side_id].mons.size():
				return "bad_target"
			return ""
		"take_item":
			if side_id != PLAYER:
				return "bad_target"
			var tto := int(a.get("to", -1))
			if tto < 0 or tto >= sides[side_id].mons.size():
				return "bad_target"
			if int(sides[side_id].mons[tto].item) <= 0:
				return "no_item"
			return ""
	return "bad_kind"

## Queues a player's action. Returns "" when accepted, else the reason (see validate).
func submit(side_id: int, slot: int, a: Dictionary) -> String:
	var why := validate(side_id, slot, a)
	if why == "":
		pending["%d:%d" % [side_id, slot]] = a.duplicate(true)
	return why

# Actions a mon is locked into (recharge, second turn of a charge move). {} if free to choose.
func _forced_action(m: BattleMon) -> Dictionary:
	if m.vol.has("recharge"):
		return {"kind": "recharge"}
	if m.vol.has("charging"):
		return {"kind": "move", "move": int(m.vol.charging.idx), "target": m.vol.charging.get("target", {}), "charged": true}
	if m.vol.has("rampage") and int(m.vol.rampage.idx) >= 0:
		return {"kind": "move", "move": int(m.vol.rampage.idx), "target": {}}
	if m.vol.has("locked_move") and int(m.vol.locked_move.idx) >= 0:   # Rollout / Ice Ball
		return {"kind": "move", "move": int(m.vol.locked_move.idx), "target": {}}
	return {}

# ------------------------------------------------------------------ turn resolution

## Resolves the turn (or the replacement / pivot phase) with all submitted actions. Returns the events.
func resolve() -> Array:
	events = []
	if over:
		return _flush()
	if phase == "pivot":
		# A player mon pivoted mid-turn (U-turn...): send in the chosen mon, then carry on with the turn.
		var key := "%d:%d" % [int(_pivot.side), int(_pivot.slot)]
		var to := int(pending.get(key, {}).get("to", -1))
		var pv := _pivot.duplicate()
		_pivot = {}
		pending.clear()
		phase = "turn"
		if to < 0:
			var b := _bench(int(pv.side), int(pv.get("pid", -1)))
			to = int(b[0]) if not b.is_empty() else -1
		if to >= 0:
			_pivot_switch(pv, to)
		_run_queue()
		return _flush()
	if phase == "switch":
		for key in pending:
			var p: PackedStringArray = key.split(":")
			_do_switch(sides[int(p[0])], int(p[1]), int(pending[key].to))
		pending.clear()
		phase = "turn"
		_check_faints()   # hazards can knock out the replacement
		if not over:
			_auto_replace_ai()
			phase = "switch" if not needed_switch_empty() else "turn"
		return _flush()
	turn += 1
	emit({"e": "turn", "n": turn})
	var acts: Array = []   # [{m, a, pri, sub, spe, tie}]
	for side in sides:
		for s in side.active.size():
			var m := active(side.id, s)
			if m == null or m.fainted():
				continue
			var a := _forced_action(m)
			if a.is_empty():
				var key := "%d:%d" % [side.id, s]
				a = pending.get(key, {}) if side.kind == "player" else BattleAI.choose(self, side.id, s)
			if a.is_empty():
				a = BattleAI.choose(self, side.id, s)   # safety net: never stall a turn
			acts.append({"m": m, "a": a, "pri": _priority(m, a), "sub": _sub_priority(m, a),
				"spe": BattleRules.speed_of(self, m), "tie": rng.below(1 << 16)})
	pending.clear()
	acts.sort_custom(_action_before)
	_order = acts.map(func(x): return x.m)
	_acted = []
	# Focus Punch tightens its focus before anyone moves (Showdown beforeTurnCallback).
	for x in acts:
		if str(x.a.get("kind", "")) == "move" and str(bd.effect_of(_move_for(x.m, x.a)).get("k", "")) == "focus_punch":
			x.m.vol["focusing"] = true
			log_msg("%s is tightening its focus!" % x.m.name)
	_queue = acts.duplicate()
	_run_queue()
	return _flush()

# Runs the queued actions of this turn; pauses (phase "pivot") when a player mon pivots and needs a choice.
func _run_queue() -> void:
	while not _queue.is_empty():
		if over:
			break
		var x: Dictionary = _queue.pop_front()
		var m: BattleMon = x.m
		_acted.append(m)
		if m.fainted() or m.slot < 0:
			continue
		_do_action(m, x.a)
		_check_faints()
		if not _pivot.is_empty() and not over:
			phase = "pivot"
			return
		# Gen 8+ dynamic speed (Showdown runAction): re-read every waiting mon's current Speed after each
		# action and re-sort, so e.g. an Icy Wind or a paralysis mid-turn changes who moves next. The
		# priority bracket and the per-action tie value rolled at the start of the turn are kept.
		if _queue.size() > 1:
			for q in _queue:
				q.spe = BattleRules.speed_of(self, q.m)
			_queue.sort_custom(_action_before)
	if not over:
		_end_of_turn()
		_check_faints()
	if not over:
		_auto_replace_ai()
		phase = "switch" if not needed_switch_empty() else "turn"

## Moves the acting mon right after the current one (Instruct / After You style; also used by tests).
func move_next(m: BattleMon) -> bool:
	for i in _queue.size():
		if _queue[i].m == m:
			var x = _queue[i]
			_queue.remove_at(i)
			_queue.push_front(x)
			return true
	return false

## True if `m` still has an action queued this turn that is a move (Sucker Punch / Focus Punch checks).
func queued_move(m: BattleMon) -> Dictionary:
	for q in _queue:
		if q.m == m and str(q.a.get("kind", "")) == "move":
			return _move_for(m, q.a)
	return {}

# Turn order comparator: higher priority bracket first, then the in-bracket order (Quick Claw +1, Lagging
# Tail / Stall -1), then Speed (higher first; reversed under Trick Room), then the random tie value.
func _action_before(x: Dictionary, y: Dictionary) -> bool:
	if x.pri != y.pri:
		return x.pri > y.pri
	if int(x.get("sub", 0)) != int(y.get("sub", 0)):
		return int(x.sub) > int(y.sub)
	if x.spe != y.spe:
		# Showdown: under Trick Room speed = 10000 - speed (and speed is capped at 10000).
		return (x.spe < y.spe) if field.has("trick_room") else (x.spe > y.spe)
	return x.tie < y.tie

# True when no player slot needs a replacement.
func needed_switch_empty() -> bool:
	var save := phase
	phase = "switch"
	var n := needed()
	phase = save
	return n.is_empty()

# Order bracket: run first, then switching, then ball/item, then move priority (with Prankster, Gale
# Wings, Triage, Grassy Glide).
func _priority(m: BattleMon, a: Dictionary) -> int:
	match str(a.get("kind", "")):
		"run": return 8
		"switch": return 7
		"ball", "item", "give_item", "take_item": return 6
		"recharge": return 0
		"move":
			return move_priority(m, _move_for(m, a))
	return 0

## A move's priority for this user right now (ROM priority + ability bonus + Grassy Glide).
func move_priority(m: BattleMon, mv: Dictionary) -> int:
	if mv.is_empty():
		return 0
	var p := int(mv.get("pri", 0)) + AbilityHooks.priority_bonus(self, m, mv)
	if str(mv.get("name", "")) == "Grassy Glide" and terrain == "grassy" and is_grounded(m):
		p += 1
	return p

# In-bracket order for moves: Quick Claw (20%) first, Lagging Tail / Full Incense / Stall last.
func _sub_priority(m: BattleMon, a: Dictionary) -> int:
	if str(a.get("kind", "")) != "move":
		return 0
	if ItemHooks.moves_last(self, m) or AbilityHooks.moves_last(self, m):
		return -1
	if ItemHooks.quick_claw(self, m):
		log_msg("%s's Quick Claw let it move first!" % m.name)
		return 1
	if AbilityHooks.quick_draw(self, m):
		log_msg("%s's Quick Draw let it move first!" % m.name)
		return 1
	return 0

func _move_for(m: BattleMon, a: Dictionary) -> Dictionary:
	if (m.out_of_pp() or usable_moves(m).is_empty()) and _struggle_id > 0:
		return bd.move(_struggle_id)
	var i := int(a.get("move", 0))
	if m.vol.has("encore") and int(m.vol.encore.idx) < m.moves.size():
		i = int(m.vol.encore.idx)   # Encore overrides the choice
	if i < 0 or i >= m.moves.size():
		return bd.move(_struggle_id) if _struggle_id > 0 else {}
	return bd.move(int(m.moves[i].id))

## Why move slot i can't be chosen right now ("" = it can): no PP, Disable, Choice lock, Taunt, Encore,
## Torment, Assault Vest, Gravity, Heal Block, Throat Chop. Shared by validate(), use_move() and the AI.
func move_blocked(m: BattleMon, i: int) -> String:
	if i < 0 or i >= m.moves.size():
		return "bad_move"
	if int(m.moves[i].pp) <= 0:
		return "bad_move"
	var mv := bd.move(int(m.moves[i].id))
	if m.vol.has("disabled") and int(m.vol.disabled.idx) == i:
		return "disabled"
	var lock := ItemHooks.choice_lock(self, m)
	if lock < 0:
		lock = AbilityHooks.choice_lock(self, m)   # Gorilla Tactics locks the same way
	if lock >= 0 and lock != i and lock < m.moves.size():
		return "choice_locked"
	if m.vol.has("encore") and int(m.vol.encore.idx) != i:
		return "encored"
	if int(mv.get("cat", 0)) == 2:
		if m.vol.has("taunt"):
			return "taunted"
		if ItemHooks.key(self, m) == "assault_vest":
			return "assault_vest"
	if m.vol.has("torment") and int(m.vol.get("last_move", -1)) == int(mv.get("id", -2)):
		return "tormented"
	if field.has("gravity") and mv.get("gravity_ban", false):
		return "gravity"
	if m.vol.has("heal_block") and mv.get("healing", false):
		return "heal_block"
	if m.vol.has("throat_chop") and mv.get("sound", false):
		return "throat_chop"
	return ""

## Move slots the mon may choose (empty = it has to Struggle).
func usable_moves(m: BattleMon) -> Array:
	var out: Array = []
	for i in m.moves.size():
		if move_blocked(m, i) == "":
			out.append(i)
	return out

## A per-use copy of a move with everything that depends on the user and the field resolved: type changes
## (-ate abilities, Normalize, Weather Ball, Terrain Pulse, Hidden Power is done by its effect), weather
## accuracy (Thunder / Hurricane / Blizzard), Solar Beam's weak-weather halving, and the flags DamageCalc /
## BattleRules read (facade, recoil_move, ohko, hits_airborne, freeze_dry, flying_press, hydro_steam,
## grassy_halved, ignore_def_stages, never_miss, eff_pri, pm = extra base-power modifiers).
func prepare_move(m: BattleMon, mv0: Dictionary) -> Dictionary:
	var mv := mv0.duplicate()
	var k := str(bd.effect_of(mv0).get("k", ""))
	var nm := str(mv.get("name", ""))
	var ws := AbilityHooks.weather_suppressed(self)
	var w := "" if ws else weather
	var pm: Array = []
	match k:
		"weather_ball":
			var wt: int = {"sun": TypeChart.FIRE, "rain": TypeChart.WATER, "sand": TypeChart.ROCK, "hail": TypeChart.ICE, "snow": TypeChart.ICE}.get(w, -1)
			if wt >= 0:
				mv["type"] = wt
				mv["power"] = int(mv.power) * 2
		"terrain_pulse":
			if terrain != "" and is_grounded(m):
				mv["type"] = {"electric": TypeChart.ELECTRIC, "grassy": TypeChart.GRASS, "misty": TypeChart.FAIRY, "psychic": TypeChart.PSYCHIC}[terrain]
				mv["power"] = int(mv.power) * 2
		"facade": mv["facade"] = true
		"recoil", "crash_on_miss": mv["recoil_move"] = true
		"ohko": mv["ohko"] = true
		"flying_press": mv["flying_press"] = true
		"two_turn":
			if int(mv.type) == TypeChart.GRASS and w in ["rain", "sand", "hail", "snow"]:
				pm.append(2048)   # Solar Beam / Solar Blade are halved in other weathers
	var ov := AbilityHooks.move_type_override(self, m, mv)
	if ov >= 0 and not (k in ["weather_ball", "terrain_pulse", "hidden_power", "struggle"]):
		if ov != int(mv.type) or AbilityHooks.key(self, m) == "normalize":
			mv["ate_boost"] = true
		mv["type"] = ov
	if m.vol.has("electrified"):
		mv["type"] = TypeChart.ELECTRIC
	match nm:
		"Thunder", "Hurricane", "Bleakwind Storm", "Wildbolt Storm", "Sandsear Storm":
			if w == "rain":
				mv["never_miss"] = true
			elif w == "sun" and nm in ["Thunder", "Hurricane"]:
				mv["acc"] = 50
		"Blizzard":
			if w in ["hail", "snow"]:
				mv["never_miss"] = true
		"Toxic":
			if m.has_type(TypeChart.POISON):
				mv["never_miss"] = true
		"Thousand Arrows": mv["hits_airborne"] = true
		"Freeze-Dry": mv["freeze_dry"] = true
		"Hydro Steam": mv["hydro_steam"] = true
		"Earthquake", "Bulldoze", "Magnitude": mv["grassy_halved"] = true
		"Chip Away", "Sacred Sword", "Darkest Lariat": mv["ignore_def_stages"] = true
		"Expanding Force":
			if terrain == "psychic" and is_grounded(m):
				pm.append(6144)
		"Rising Voltage", "Misty Explosion", "Psyblade":
			pass   # handled by their terrain_power effect when mapped
	if k in ["fixed_damage", "level_damage", "half_hp", "psywave", "endeavor", "counter", "final_gambit", "super_fang"]:
		mv["fixed"] = true
	mv["eff_pri"] = move_priority(m, mv0)
	if not pm.is_empty():
		mv["pm"] = pm
	return mv

func _do_action(m: BattleMon, a: Dictionary) -> void:
	match str(a.get("kind", "")):
		"switch":
			log_msg("%s, return." % m.name if m.side_id == PLAYER else "%s recalls %s." % [side_of(m).name, m.name])
			_do_switch(side_of(m), m.slot, int(a.to))
		"run":
			run_attempts += 1
			var foe: BattleMon = foes_of(m)[0] if foes_of(m).size() > 0 else m
			# Gen 3: no Ghost-type auto-escape (Gen 6+); Smoke Ball / Run Away still always escape.
			var free := ItemHooks.smoke_ball(self, m) or AbilityHooks.always_run(self, m)
			var trap_ab := AbilityHooks.trapped_by(self, m)
			if not free and (m.vol.has("trapped") or m.vol.has("cant_flee") or trap_ab != ""):
				log_msg("%s is trapped and can't flee!" % m.name)
			elif BattleRules.run_succeeds(self, m, foe, run_attempts):
				if ItemHooks.smoke_ball(self, m):
					log_msg("You got away using the Smoke Ball!")
				log_msg("You got away.")
				_finish("run")
			else:
				log_msg("Couldn't get away!")
		"ball":
			_throw_ball(m, int(a.get("item", 0)))
			if caught != null and caught_by < 0:
				caught_by = m.owner   # the caught mon goes to the thrower
		"item":
			use_bag_item(m, a)
		"give_item":
			_give_held_item(m, a)
		"take_item":
			_take_held_item(m, a)
		"recharge":
			m.vol.erase("recharge")
			log_msg("%s must recharge!" % m.name)
		"move":
			use_move(m, a)

## Uses a bag item in battle ({kind:"item", item, to: party index (default the user), move: slot for an
## Ether}). The item is NOT removed from the bag here: the caller (BattleController) does that
## when it sees the "item" event. Effects (Gen 7+ amounts): Potions, status heals, Revives (benched
## fainted mons), Ethers/Elixirs, X items (+2 stages Gen 7+), Dire Hit (+2 crit), Guard Spec (Mist 5 turns).
func use_bag_item(m: BattleMon, a: Dictionary) -> bool:
	var item := int(a.get("item", 0))
	var ik: Dictionary = bd.item_kinds.get(str(item), {})
	var side := side_of(m)
	var ti := int(a.get("to", m.party_index if side.mons.find(m) < 0 else side.mons.find(m)))
	var t: BattleMon = side.mons[ti] if ti >= 0 and ti < side.mons.size() else m
	var nm := bd.item_name(item)
	emit({"e": "item", "side": m.side_id, "slot": m.slot, "item": item, "to": ti})
	log_msg("%s used the %s." % [owner_names.get(m.owner, "You") if m.side_id == PLAYER else side.name, nm])
	match str(ik.get("k", "")):
		"heal":
			if t.fainted() or (t.hp >= t.max_hp() and not (ik.get("cure", false) and t.status != "")):
				log_msg("It won't have any effect.")
				return false
			if t.hp < t.max_hp():
				_heal_any(t, int(ik.hp))
				log_msg("%s's HP was restored." % t.name)
			if ik.get("cure", false):
				t.vol.erase("confused")
				if t.status != "":
					_cure_any(t)
			return true
		"revive":
			if not t.fainted():
				log_msg("It won't have any effect.")
				return false
			t.hp = maxi(1, t.max_hp() / int(ik.get("frac", 2)))
			t.vol.clear()
			t.status = ""
			if t.slot >= 0:
				emit_hp(t)
			log_msg("%s was revived!" % t.name)
			return true
		"cure":
			var cures: Array = ik.get("s", [])
			var did := false
			if t.status != "" and t.status in cures:
				_cure_any(t)
				did = true
			if "confusion" in cures and t.vol.has("confused"):
				t.vol.erase("confused")
				did = true
			if not did:
				log_msg("It won't have any effect.")
			else:
				log_msg("%s was cured." % t.name)
			return did
		"pp":
			var did := false
			var slots: Array = range(t.moves.size()) if ik.get("all", false) else [int(a.get("move", 0))]
			for i in slots:
				if i < t.moves.size() and int(t.moves[i].pp) < int(t.moves[i].max_pp):
					t.moves[i].pp = mini(int(t.moves[i].max_pp), int(t.moves[i].pp) + int(ik.n))
					did = true
			log_msg("PP was restored." if did else "It won't have any effect.")
			return did
		"x":
			if t.slot < 0:
				return false
			boost(t, str(ik.st), 2, false)
			# Gen 3 friendship: using a battle item on a Pokémon raises its friendship by 1.
			t.friendship = mini(255, t.friendship + 1)
			return true
		"dire_hit":
			if t.vol.has("focus_energy"):
				log_msg("It won't have any effect.")
				return false
			t.vol["focus_energy"] = true
			t.friendship = mini(255, t.friendship + 1)
			log_msg("%s is getting pumped!" % t.name)
			return true
		"guard_spec":
			if side.cond.has("mist"):
				log_msg("It won't have any effect.")
				return false
			side.cond["mist"] = 5
			t.friendship = mini(255, t.friendship + 1)
			log_msg("Your team became shrouded in mist!")
			return true
	log_msg("It won't have any effect.")
	return false

## Gives a held item from the bag to one of the player's Pokémon ({kind:"give_item", item, to: party
## index}). The old held item, if any, goes back to the bag (the screen adds it on the "give_item"
## event); the new item leaves the bag when the action is submitted. The item becomes the mon's held item
## for the rest of the battle and is kept afterwards (BattleMon.to_party, via item_at_start).
func _give_held_item(m: BattleMon, a: Dictionary) -> void:
	var side := side_of(m)
	var to := int(a.get("to", -1))
	var item := int(a.get("item", 0))
	if to < 0 or to >= side.mons.size():
		return
	var t: BattleMon = side.mons[to]
	var old := t.item
	t.item = item
	t.item_at_start = item
	t.vol.erase("choice_lock")
	emit({"e": "give_item", "side": m.side_id, "slot": m.slot, "item": item, "to": to, "old": old})
	log_msg("%s was given the %s." % [t.name, bd.item_name(item)])
	if old > 0:
		log_msg("The %s was returned to the bag." % bd.item_name(old))
	if t.slot >= 0:
		ItemHooks.check_hp_items(self, t)   # a pinch berry given to a hurt mon triggers at once

## Takes the held item off one of the player's Pokémon ({kind:"take_item", to: party index}). The item
## goes back to the bag (the screen adds it on the "take_item" event).
func _take_held_item(m: BattleMon, a: Dictionary) -> void:
	var side := side_of(m)
	var to := int(a.get("to", -1))
	if to < 0 or to >= side.mons.size():
		return
	var t: BattleMon = side.mons[to]
	if t.item <= 0:
		log_msg("But it failed!")
		return
	var old := t.item
	t.item = 0
	t.item_at_start = 0
	t.vol.erase("choice_lock")
	t.vol["unburden"] = true   # losing its item triggers Unburden, like Knock Off / Trick
	emit({"e": "take_item", "side": m.side_id, "slot": m.slot, "item": old, "to": to})
	log_msg("%s's %s was taken." % [t.name, bd.item_name(old)])

# HP / status changes on a possibly benched mon (bag items): events only when it is on the field.
func _heal_any(t: BattleMon, n: int) -> void:
	t.hp = mini(t.max_hp(), t.hp + n)
	if t.slot >= 0:
		emit_hp(t)

func _cure_any(t: BattleMon) -> void:
	t.status = ""
	t.status_turns = 0
	if t.slot >= 0:
		emit_status(t)

const SEMI_HITS := {"air": ["Thunder", "Hurricane", "Sky Uppercut", "Gust", "Twister", "Smack Down", "Thousand Arrows"],
	"underground": ["Earthquake", "Magnitude", "Fissure"], "underwater": ["Surf", "Whirlpool"], "phantom": []}
const SEMI_KIND := {"Fly": "air", "Bounce": "air", "Sky Drop": "air", "Dig": "underground", "Dive": "underwater",
	"Phantom Force": "phantom", "Shadow Force": "phantom"}
## Effect keys whose move acts on the user / its side / the field (no target accuracy or protection).
const SELF_KEYS := ["boost_self", "focus_energy", "protect", "endure", "rest", "heal", "screen", "aurora_veil",
	"weather", "haze", "nothing", "room", "terrain", "tailwind", "lucky_chant", "side_cond", "wish",
	"healing_wish", "aqua_ring", "ingrain", "stockpile", "swallow", "charge", "magnet_rise", "substitute",
	"shed_tail", "chilly_reception", "baton_pass", "perish_song", "follow_me", "tidy_up", "court_change",
	"belly_drum", "shore_up", "weather_heal", "destiny_bond", "sleep_talk", "hazard", "take_heart",
	"refresh", "heal_bell", "teleport", "acupressure", "helping_hand"]

## Uses a move: the "can it move" checks in Showdown's beforeMove order (Truant? sleep/freeze, Truant,
## flinch, Disable/Taunt/Gravity/Heal Block/Throat Chop, confusion, attraction, paralysis), PP (Pressure),
## announcement, charge turns, then per-target protection, immunity and accuracy (see _hit_one) and
## MoveEffects. Public so tests can drive single moves.
func use_move(m: BattleMon, a: Dictionary) -> void:
	var mv0 := _move_for(m, a)
	var k0 := str(bd.effect_of(mv0).get("k", "")) if not mv0.is_empty() else ""
	var charged: bool = a.get("charged", false)
	if m.vol.has("destiny_bond") and k0 != "destiny_bond":
		m.vol.erase("destiny_bond")
	# --- sleep / freeze ---
	if m.status == "slp":
		m.status_turns -= 2 if AbilityHooks.early_bird(self, m) else 1
		if m.status_turns <= 0:
			cure(m, "%s woke up!" % m.name)
		elif not (k0 == "sleep_talk" or str(mv0.get("name", "")) == "Snore"):
			log_msg("%s is fast asleep." % m.name)
			_interrupt(m)
			return
	elif m.status == "frz":
		if mv0.get("thaws", false) or rng.ratio(1, 5):
			cure(m, "%s thawed out!" % m.name)
		else:
			log_msg("%s is frozen solid!" % m.name)
			_interrupt(m)
			return
	# --- Truant ---
	if AbilityHooks.truant(self, m):
		if m.vol.has("truant_loaf"):
			m.vol.erase("truant_loaf")
			log_msg("%s is loafing around!" % m.name)
			_interrupt(m)
			return
		m.vol["truant_loaf"] = true
	if m.vol.has("flinch"):
		log_msg("%s flinched and couldn't move!" % m.name)
		AbilityHooks.on_flinch(self, m)
		_interrupt(m)
		return
	# --- move restrictions that apply at execution (the move was chosen before they began) ---
	var idx := int(a.get("move", 0))
	if m.vol.has("encore"):
		idx = int(m.vol.encore.idx)
	var struggle := m.out_of_pp() or usable_moves(m).is_empty() or int(mv0.get("id", -1)) == _struggle_id
	if not struggle and not charged and not m.vol.has("rampage") and idx >= 0 and idx < m.moves.size():
		var why := move_blocked(m, idx)
		if why != "" and why != "bad_move" and why != "choice_locked":
			log_msg({"disabled": "%s's %s is disabled!", "taunted": "%s can't use %s after the taunt!",
				"gravity": "%s can't use %s because of gravity!", "heal_block": "%s can't use %s because of Heal Block!",
				"throat_chop": "%s can't use %s because of Throat Chop!", "tormented": "%s can't use %s twice in a row!",
				"assault_vest": "%s can't use %s with an Assault Vest!", "encored": "%s must use its encored move! (%s)"}.get(why, "%s can't use %s!") % [m.name, mv0.get("name", "")])
			_interrupt(m)
			return
	# --- confusion / attraction / paralysis ---
	if m.vol.has("confused"):
		m.vol.confused -= 1
		if int(m.vol.confused) <= 0:
			m.vol.erase("confused")
			log_msg("%s snapped out of its confusion!" % m.name)
		else:
			log_msg("%s is confused!" % m.name)
			if rng.ratio(1, 2):   # Gen 3: a confused Pokémon hurts itself half the time (1/3 is Gen 7+)
				var self_hit := {"power": 40, "type": TypeChart.MYSTERY, "cat": 0, "eff": 0, "acc": 0, "pri": 0,
					"contact": false, "high_crit": false, "target": 0, "name": "", "chance": 0}
				var r := DamageCalc.compute(self, m, m, self_hit, {"typeless": true, "no_items": true})
				damage(m, mini(int(r.damage), m.hp), "It hurt itself in its confusion!")
				_interrupt(m)
				return
	if m.vol.has("attract"):
		var src := active(int(m.vol.attract.side), int(m.vol.attract.slot))
		if src == null or src.fainted():
			m.vol.erase("attract")
		else:
			log_msg("%s is in love with %s!" % [m.name, src.name])
			if rng.ratio(1, 2):
				log_msg("%s is immobilized by love!" % m.name)
				_interrupt(m)
				return
	if m.status == "par" and rng.ratio(1, 4):
		log_msg("%s is paralyzed! It can't move!" % m.name)
		_interrupt(m)
		return
	# --- pick the move, pay PP ---
	var mv := mv0
	if mv.is_empty():
		log_msg("%s has no moves left!" % m.name)
		return
	if struggle:
		log_msg("%s has no moves left!" % m.name)
	var eff := bd.effect_of(mv)
	if not struggle and not charged and not m.vol.has("rampage") and idx >= 0 and idx < m.moves.size():
		var cost := 1
		if (int(mv.target) & TGT_USER) == 0:
			for f in foes_of(m):
				if AbilityHooks.pressure(self, f):
					cost += 1
		m.moves[idx].pp = maxi(0, int(m.moves[idx].pp) - cost)
	# Sleep Talk picks one of the user's other moves and uses it (the called move costs no PP).
	if str(eff.get("k", "")) == "sleep_talk":
		emit({"e": "move", "side": m.side_id, "slot": m.slot, "move": int(mv.id), "name": str(mv.name)})
		log_msg("%s used %s!" % [m.name, mv.name])
		if m.status != "slp":
			log_msg("But it failed!")
			return
		var pool: Array = []
		for i in m.moves.size():
			var cm := bd.move(int(m.moves[i].id))
			var ck := str(bd.effect_of(cm).get("k", ""))
			if i != idx and not (ck in ["sleep_talk", "two_turn", "semi_invuln", "skull_bash", "focus_punch", "rampage"]) and int(cm.get("id", -1)) != _struggle_id:
				pool.append(i)
		if pool.is_empty():
			log_msg("But it failed!")
			return
		var pick: int = pool[rng.below(pool.size())]
		mv = bd.move(int(m.moves[pick].id))
		eff = bd.effect_of(mv)
		a = a.duplicate()
		a["charged"] = true   # a called charge move would fail anyway; Sleep Talk never charges
	mv = prepare_move(m, mv)
	emit({"e": "move", "side": m.side_id, "slot": m.slot, "move": int(mv.id), "name": str(mv.name)})
	log_msg("%s used %s!" % [m.name, mv.name])
	if not struggle and m.vol.get("last_move", -1) != int(mv.id):
		m.vol.erase("metronome_count")
	m.vol["metronome_count"] = int(m.vol.get("metronome_count", -1)) + 1
	m.vol["last_move"] = int(mv.id)
	m.vol["moved_this_turn"] = true
	m.vol["failed_last"] = m.vol.has("move_failed")   # Stomping Tantrum / Temper Flare
	m.vol.erase("move_failed")
	last_move_any = int(mv.id)
	if not struggle and idx >= 0 and idx < m.moves.size() and (ItemHooks.key(self, m) == "choice" or AbilityHooks.key(self, m) == "gorilla_tactics") and not m.vol.has("choice_lock"):
		m.vol["choice_lock"] = idx
	AbilityHooks.protean(self, m, mv)
	var k := str(eff.get("k", ""))
	# --- Focus Punch loses focus when hit earlier this turn ---
	if k == "focus_punch":
		m.vol.erase("focusing")
		if m.vol.has("hurt_this_turn"):
			log_msg("%s lost its focus and couldn't move!" % m.name)
			m.vol["move_failed"] = true
			return
	# --- two-turn moves: first turn only charges (Power Herb / sun skip it) ---
	if k in ["two_turn", "skull_bash", "semi_invuln"] and not charged:
		var skip := k == "two_turn" and int(mv.type) == TypeChart.GRASS and weather == "sun" and not AbilityHooks.weather_suppressed(self)
		if k == "skull_bash":
			log_msg("%s tucked in its head!" % m.name)
			boost(m, "def", 1, false)
		if not skip and not ItemHooks.power_herb(self, m):
			m.vol["charging"] = {"idx": idx, "target": a.get("target", {})}
			if k == "semi_invuln":
				m.vol["semi_invuln"] = SEMI_KIND.get(str(mv.name), "air")
			if k != "skull_bash":
				log_msg("%s is charging up!" % m.name)
			return
	m.vol.erase("charging")
	m.vol.erase("semi_invuln")
	# --- explosion moves fail while a Damp mon is on the field ---
	if k in ["explode", "misty_explosion"] or str(mv.name) in ["Self-Destruct", "Explosion", "Mind Blown", "Misty Explosion"]:
		var damp := AbilityHooks.damp_on_field(self, m)
		if damp != null:
			log_msg("%s's %s prevents %s from using %s!" % [damp.name, bd.ability_name(damp.ability), m.name, mv.name])
			return
	# --- targets (doubles: spread / retarget rules, see header) ---
	var self_move := (int(mv.target) & TGT_USER) != 0 or k in SELF_KEYS or (int(mv.target) & 0x40) != 0
	if k == "curse" and m.has_type(TypeChart.GHOST):
		self_move = false
	if self_move:
		var tl := move_targets(m, mv, a, true) if (int(mv.target) & TGT_USER) == 0 else [m]
		var t0: BattleMon = m if tl.is_empty() else tl[0]
		if k == "helping_hand":
			t0 = ally_of(m)
			if t0 == null:
				log_msg("But it failed!")
				return
		_executing = m
		MoveEffects.run(self, m, t0, mv, eff)
		_executing = null
		_after_move(m, mv, eff, 0)
		return
	var targets := move_targets(m, mv, a)
	# Follow Me / Rage Powder / Spotlight: single-target moves aimed at the other side are redirected
	# (Stalwart / Propeller Tail ignore the redirection).
	if is_doubles() and targets.size() == 1 and targets[0].side_id != m.side_id and not AbilityHooks.ignores_redirect(self, m):
		var foe_side: Dictionary = sides[targets[0].side_id]
		if foe_side.has("center") and (int(mv.target) & (TGT_BOTH | TGT_FOES_AND_ALLY)) == 0:
			var c := active(targets[0].side_id, int(foe_side.center))
			if c != null and not c.fainted():
				targets = [c]
	if targets.is_empty():
		log_msg("But there was no target...")
		m.vol["move_failed"] = true
		return
	# Spread is decided HERE, from the number of targets before protect/accuracy/immunity (Showdown).
	_executing = m
	_cur_spread = is_doubles() and targets.size() > 1
	var hit_any := false
	var total := 0
	var hp0 := {}
	for t in targets:
		hp0[t] = t.hp
	for target in targets:
		if over:
			break
		if target.fainted():
			continue
		if _hit_one(m, target, mv, eff):
			hit_any = true
			total += maxi(0, int(hp0[target]) - target.hp)
	_executing = null
	_cur_spread = false
	if not hit_any:
		m.vol["move_failed"] = true
		m.vol.erase("locked_move")   # Rollout / Ice Ball stop on a miss
	if k in ["explode", "memento", "final_gambit", "misty_explosion"] and not m.fainted():
		damage(m, m.hp, "")
	_after_move(m, mv, eff, total)

# After a move finished on all its targets: Life Orb / Shell Bell / Throat Spray, rampage lock, Truant.
func _after_move(m: BattleMon, mv: Dictionary, eff: Dictionary, total: int) -> void:
	# Wind Power / Electromorphosis charge is spent when the mon uses an Electric move.
	if int(mv.type) == TypeChart.ELECTRIC:
		m.vol.erase("wind_charged")
		m.vol.erase("electro_charged")
	if int(mv.cat) != 2 and total > 0:
		ItemHooks.after_move(self, m, mv, total)
	elif mv.get("sound", false):
		ItemHooks.after_move(self, m, mv, 0)
	if str(eff.get("k", "")) == "rampage" and not m.fainted():
		if not m.vol.has("rampage"):
			m.vol["rampage"] = {"idx": int(m.move_index(int(mv.id))), "turns": rng.range_i(2, 3) - 1}
		else:
			m.vol.rampage.turns = int(m.vol.rampage.turns) - 1
			if int(m.vol.rampage.turns) <= 0 or m.vol.has("move_failed"):
				m.vol.erase("rampage")
				log_msg("%s became confused due to fatigue!" % m.name)
				confuse(m, false)

# The mon was stopped before moving: charge, rampage and the like are cancelled (Showdown clears
# two-turn moves; rampage ends without confusion).
func _interrupt(m: BattleMon) -> void:
	m.vol.erase("charging")
	m.vol.erase("semi_invuln")
	m.vol.erase("rampage")
	m.vol.erase("focusing")
	m.vol["move_failed"] = true

# One target of a move: semi-invulnerability, protection, Psychic Terrain, type/ability immunity, Prankster
# vs Dark, powder, Magic Bounce, accuracy, then the effect. Returns true if it hit.
func _hit_one(m: BattleMon, target: BattleMon, mv: Dictionary, eff: Dictionary) -> bool:
	var k := str(eff.get("k", ""))
	var foe := target.side_id != m.side_id
	if target.vol.has("semi_invuln") and target != m and not AbilityHooks.no_guard(self, m, target) and not m.vol.has("lock_on"):
		if not (str(mv.name) in SEMI_HITS.get(str(target.vol.semi_invuln), [])):
			log_msg("%s avoided the attack!" % target.name)
			return false
	if target.vol.has("protect") and target != m and not (k in ["feint"]) and not AbilityHooks.unseen_fist(self, m) and not (str(mv.name) in ["Feint", "Hyperspace Fury", "Hyperspace Hole", "Phantom Force", "Shadow Force"]):
		log_msg("%s protected itself!" % target.name)
		var pk := str(target.vol.get("protect_kind", ""))
		if mv.get("contact", false) and not ItemHooks.no_contact(self, m, mv) and not AbilityHooks.no_contact(self, m):
			match pk:
				"spiky_shield": damage(m, maxi(1, m.max_hp() / 8), "%s was hurt!" % m.name)
				"kings_shield": boost(m, "atk", -1, true)
				"baneful_bunker": if BattleRules.can_get_status(self, m, "psn"): try_status(m, "psn", false)
				"silk_trap": boost(m, "spe", -1, true)
				"burning_bulwark": if BattleRules.can_get_status(self, m, "brn"): try_status(m, "brn", false)
				"obstruct": boost(m, "def", -2, true)
		return false
	if foe and terrain == "psychic" and is_grounded(target) and int(mv.get("eff_pri", 0)) > 0:
		log_msg("%s is protected by the Psychic Terrain!" % target.name)
		return false
	if foe and int(mv.cat) == 2 and target.has_type(TypeChart.DARK) and AbilityHooks.key(self, m) == "prankster" and int(mv.get("eff_pri", 0)) > int(mv.get("pri", 0)):
		log_msg("It doesn't affect %s..." % target.name)
		return false
	# Substitute blocks status moves from others (sound moves and Infiltrator go through).
	if int(mv.cat) == 2 and target != m and target.vol.has("substitute") and not mv.get("sound", false) \
			and not mv.get("bypass_sub", false) and not AbilityHooks.infiltrates(self, m) and not (k in ["roar", "haze", "perish_song", "transform"]):
		log_msg("But it failed!")
		return false
	if mv.get("powder", false) and target != m and (target.has_type(TypeChart.GRASS) or AbilityHooks.key(self, target) == "overcoat" or ItemHooks.powder_immune(self, target)):
		log_msg("It doesn't affect %s..." % target.name)
		return false
	var absorbed := AbilityHooks.absorb_check(self, m, target, mv)
	if absorbed != "":
		if absorbed.strip_edges() != "":
			log_msg(absorbed)
		return false
	# Magic Bounce: reflectable status moves bounce back to the user.
	if foe and int(mv.cat) == 2 and mv.get("reflectable", false) and AbilityHooks.magic_bounce(self, target) and not m.vol.has("bounced"):
		log_msg("%s bounced the %s back!" % [target.name, mv.name])
		m.vol["bounced"] = true
		var ex := _executing
		_executing = target
		MoveEffects.run(self, target, m, mv, eff)
		_executing = ex
		m.vol.erase("bounced")
		return false
	if k != "ohko" and not BattleRules.hits(self, m, target, mv):
		log_msg("%s's attack missed!" % m.name if not _cur_spread else "%s avoided the attack!" % target.name)
		ItemHooks.on_miss(self, m)
		if k == "crash_on_miss" and not AbilityHooks.magic_guard(self, m):
			damage(m, maxi(1, m.max_hp() / 2), "%s kept going and crashed!" % m.name)
		return false
	if k == "ohko":
		# OHKO moves (Gen 7+): fail against higher-level targets; accuracy 30 + level gap (Sheer Cold is
		# 20 for non-Ice users and never hits Ice types).
		var base := 30
		if str(mv.name) == "Sheer Cold":
			if target.has_type(TypeChart.ICE):
				log_msg("It doesn't affect %s..." % target.name)
				return false
			if not m.has_type(TypeChart.ICE):
				base = 20
		var acc := base + m.level - target.level
		if not AbilityHooks.no_guard(self, m, target) and rng.below(100) >= acc:
			log_msg("%s's attack missed!" % m.name)
			return false
	MoveEffects.run(self, m, target, mv, eff)
	return true

func _throw_ball(m: BattleMon, item: int) -> void:
	var foes := foes_of(m)
	if foes.is_empty():
		return
	var t: BattleMon = foes[0]
	log_msg("You threw a %s!" % (bd.item_name(item) if item > 0 else "ball"))
	var bk := str(bd.ball(item).get("k", "basic"))
	var rate := int(bd.species(t.species).get("catch", 45))
	var mult := 4096
	if bk == "master":
		mult = -1
	elif bk == "heavy":
		# Heavy Metal doubles the target's weight, Light Metal halves it (for the Heavy Ball rate).
		var w := int(bd.species(t.species).get("weight", 0))
		if AbilityHooks.key(self, t) == "heavy_metal":
			w *= 2
		elif AbilityHooks.key(self, t) == "light_metal":
			w /= 2
		rate = BattleRules.heavy_ball_rate(rate, w)
	elif bk == "moon":
		mult = 4096   # TODO(parity): Moon Ball needs the "evolves with a Moon Stone" list
	else:
		var ctx := {"turn": turn, "user": m}
		ctx.merge(ball_ctx)
		mult = BattleRules.ball_mult(self, bk, t, ctx)
	# Critical capture (Gen 5+): a single shake check when the Pokédex count is known (ball_ctx
	# "dex_caught", passed by the overworld; 0 = unknown, no critical captures). a >= 255 already
	# catches outright, so a critical capture only matters below that.
	var a := BattleRules.catch_a(t, rate, mult)
	if mult >= 0 and a < 255.0 and BattleRules.crit_capture(self, a, int(ball_ctx.get("dex_caught", 0))):
		log_msg("A critical catch!")
		var b := BattleRules.catch_b(a)
		if rng.below(65536) < b:
			emit({"e": "shake", "n": 4, "crit": true})
			log_msg("Gotcha! %s was caught!" % t.name)
			caught = t
			caught_ball = item
			_finish("caught")
		else:
			emit({"e": "shake", "n": 1, "crit": true})
			log_msg("Oh no! The Pokémon broke free!")
		return
	var shakes := BattleRules.catch_shakes(self, t, rate, mult)
	emit({"e": "shake", "n": shakes})
	if shakes >= 4:
		log_msg("Gotcha! %s was caught!" % t.name)
		caught = t
		caught_ball = item
		_finish("caught")
	else:
		log_msg(["Oh no! The Pokémon broke free!", "Aww! It appeared to be caught!", "Aargh! Almost had it!", "Gah! It was so close, too!"][mini(shakes, 3)])

# ------------------------------------------------------------------ effects API (used by MoveEffects / hooks)

## Appends an event.
func emit(ev: Dictionary) -> void:
	events.append(ev)

## Appends a text line (our own wording).
func log_msg(text: String) -> void:
	if text != "":
		emit({"e": "msg", "text": text})

## Emits the current HP of a mon.
func emit_hp(m: BattleMon) -> void:
	emit({"e": "hp", "side": m.side_id, "slot": m.slot, "hp": m.hp, "max": m.max_hp()})

## Emits the current status of a mon.
func emit_status(m: BattleMon) -> void:
	emit({"e": "status", "side": m.side_id, "slot": m.slot, "status": m.status})

## Lowers HP by n (clamped) and logs an optional line.
func damage(m: BattleMon, n: int, text: String) -> void:
	if n <= 0 or m.fainted():
		return
	m.hp = maxi(0, m.hp - n)
	if m.hp == 0:
		_faint_seq[m.get_instance_id()] = _faint_counter   # faint messages follow the order HP hit 0 (Showdown faintQueue)
		_faint_counter += 1
	m.vol["hurt_this_turn"] = true
	emit_hp(m)
	log_msg(text)
	if not _in_hit and m.slot >= 0 and not m.fainted():
		ItemHooks.check_hp_items(self, m)   # pinch berries right after indirect damage

## Raises HP by n (clamped) and logs an optional line. Heal Block stops it.
func heal(m: BattleMon, n: int, text: String) -> void:
	if n <= 0 or m.fainted() or m.hp >= m.max_hp():
		return
	if m.vol.has("heal_block"):
		log_msg("%s can't restore HP because of Heal Block!" % m.name)
		return
	m.hp = mini(m.max_hp(), m.hp + n)
	emit_hp(m)
	log_msg(text)

## Tries to give a major status. `loud` = say why it failed (status moves) vs. stay silent (secondary effects).
## source = the mon causing it (Corrosion, Synchronize, Infiltrator vs Safeguard), may be null; when null,
## the mon currently executing a move is used.
func try_status(m: BattleMon, s: String, loud: bool, source: BattleMon = null) -> bool:
	if m.fainted():
		return false
	if source == null:
		source = _executing
	if m.status != "":
		if loud:
			log_msg("But it failed!" if m.status != s else "%s is already %s!" % [m.name, _status_word(s)])
		return false
	if not BattleRules.can_get_status(self, m, s, source):
		if loud:
			log_msg("It doesn't affect %s..." % m.name)
		return false
	if source != m and side_of(m).cond.has("safeguard") and not (source != null and AbilityHooks.infiltrates(self, source)):
		if loud:
			log_msg("%s is protected by Safeguard!" % m.name)
		return false
	if m.vol.has("substitute") and source != null and source != m and not loud:
		return false   # secondary effects don't go through a Substitute
	set_status(m, s, "")
	if source != null and source != m and source.side_id != m.side_id:
		AbilityHooks.on_status_from(self, m, source, s)
	ItemHooks.check_status_items(self, m)
	return true

## Sets a status without checks (callers check first) and logs it.
func set_status(m: BattleMon, s: String, source: String) -> void:
	m.status = s
	# Gen 3 sleep lasts 2-5 turns asleep: the counter is decremented in use_move before acting and the
	# mon wakes (and moves) when it reaches 0, so the counter is 3-6 (asleep for 2-5 of its own turns).
	m.status_turns = rng.range_i(3, 6) if s == "slp" else 0
	emit_status(m)
	var line := "%s was %s!" % [m.name, _status_word(s)] if s != "slp" else "%s fell asleep!" % m.name
	log_msg(line if source == "" else "%s: %s" % [source, line])
	if s == "slp":
		m.vol.erase("rampage")
	if m.slot >= 0:
		ItemHooks.check_status_items(self, m)

## Removes a major status.
func cure(m: BattleMon, text: String) -> void:
	m.status = ""
	m.status_turns = 0
	m.vol.erase("nightmare")
	emit_status(m)
	log_msg(text)

func _status_word(s: String) -> String:
	return {"psn": "poisoned", "tox": "badly poisoned", "brn": "burned", "par": "paralyzed", "frz": "frozen solid", "slp": "asleep"}.get(s, s)

## Confuses a mon for 2-5 turns (counting down when it tries to move). loud = report failures.
## Misty Terrain protects grounded mons; Safeguard protects from foes.
func confuse(m: BattleMon, loud: bool) -> void:
	if m.fainted():
		return
	var blocked := m.vol.has("confused") or not AbilityHooks.allows_confusion(self, m)
	if terrain == "misty" and is_grounded(m) and _executing != m:
		blocked = true
	if _executing != null and _executing != m and side_of(m).cond.has("safeguard") and not AbilityHooks.infiltrates(self, _executing):
		blocked = true
	if blocked:
		if loud:
			log_msg("But it failed!")
		return
	m.vol["confused"] = rng.range_i(3, 6)   # Gen 3 confusion lasts 2-5 turns (counter ticks when it tries to move)
	log_msg("%s became confused!" % m.name)
	ItemHooks.check_status_items(self, m)

## Makes a mon flinch if it has not acted yet this turn.
func flinch(m: BattleMon) -> void:
	if not _acted.has(m) and AbilityHooks.allows_flinch(self, m):
		m.vol["flinch"] = true

## Changes a stat stage by n with the ROM-style messages. by_foe = a foe caused it (Clear Body-style
## abilities, Clear Amulet, Mist, Mirror Armor... apply, and Defiant / Competitive trigger). Contrary and
## Simple change n first. White Herb restores lowered stats right after.
func boost(m: BattleMon, stat: String, n: int, by_foe: bool) -> void:
	if m.fainted() or not m.stages.has(stat) or n == 0:
		return
	n = AbilityHooks.stage_delta(self, m, n)
	if n < 0 and by_foe:
		# Mirror Armor: a stat drop from a foe is reflected back onto the foe instead.
		if AbilityHooks.key(self, m) == "mirror_armor" and _executing != null and _executing != m and _executing.side_id != m.side_id:
			log_msg("%s's %s reflected the stat drop!" % [m.name, bd.ability_name(m.ability)])
			boost(_executing, stat, n, false)
			return
		if not AbilityHooks.allows_drop(self, m, stat):
			log_msg("%s's %s prevents its stats from being lowered!" % [m.name, bd.ability_name(m.ability)])
			return
		if ItemHooks.blocks_drops(self, m):
			log_msg("%s's Clear Amulet prevents its stats from being lowered!" % m.name)
			return
		if side_of(m).cond.has("mist") and not (_executing != null and AbilityHooks.infiltrates(self, _executing)):
			log_msg("%s is protected by the mist!" % m.name)
			return
		if m.vol.has("substitute") and _executing != null and _executing != m:
			log_msg("But it failed!")
			return
	var old := int(m.stages[stat])
	var nv := clampi(old + n, -6, 6)
	var word: String = MoveEffects.STAT_TEXT.get(stat, stat)
	if nv == old:
		log_msg("%s's %s won't go any %s!" % [m.name, word, "higher" if n > 0 else "lower"])
		return
	m.stages[stat] = nv
	emit({"e": "stage", "side": m.side_id, "slot": m.slot, "stat": stat, "n": nv - old})
	var d := absi(nv - old)
	if n > 0:
		log_msg("%s's %s %s!" % [m.name, word, "rose" if d == 1 else "rose sharply" if d == 2 else "rose drastically"])
	else:
		log_msg("%s's %s %s!" % [m.name, word, "fell" if d == 1 else "harshly fell" if d == 2 else "severely fell"])
		m.vol["stat_dropped"] = true   # Lash Out
		if by_foe:
			AbilityHooks.on_stat_dropped_by_foe(self, m)
		ItemHooks.check_white_herb(self, m)
	# Opportunist: when a foe's stat rises, an Opportunist on the other side copies the rise.
	if n > 0 and not _in_opportunist:
		_in_opportunist = true
		for x in all_active():
			if x != m and x.side_id != m.side_id and AbilityHooks.key(self, x) == "opportunist":
				log_msg("%s's %s copied the stat boost!" % [x.name, bd.ability_name(x.ability)])
				boost(x, stat, nv - old, false)
		_in_opportunist = false

## Starts a weather for `turns` turns (5, or 8 with the matching rock). Returns false when it is already up.
## from_ability = set by Drizzle-style abilities (no "But it failed!" line).
func set_weather(w: String, turns: int, from_ability: bool = false) -> bool:
	if weather == w:
		if not from_ability:
			log_msg("But it failed!")
		return false
	weather = w
	weather_turns = turns
	emit({"e": "weather", "w": w})
	log_msg({"rain": "It started to rain!", "sun": "The sunlight turned harsh!", "sand": "A sandstorm kicked up!",
		"hail": "It started to hail!", "snow": "It started to snow!"}.get(w, ""))
	for m in _speed_sorted(all_active()):
		AbilityHooks.on_weather_change(self, m)
	return true

## Starts a terrain for `turns` turns (5, or 8 with Terrain Extender). Returns false when it is already up.
func set_terrain(t: String, turns: int, from_ability: bool = false) -> bool:
	if terrain == t:
		if not from_ability:
			log_msg("But it failed!")
		return false
	terrain = t
	terrain_turns = turns
	emit({"e": "terrain", "t": t})
	log_msg({"electric": "An electric current ran across the battlefield!", "grassy": "Grass grew to cover the battlefield!",
		"misty": "Mist swirled around the battlefield!", "psychic": "The battlefield got weird!"}.get(t, ""))
	if t == "electric":
		for m in all_active():
			if m.status == "slp" and is_grounded(m):
				cure(m, "%s woke up!" % m.name)
	for m in _speed_sorted(all_active()):
		AbilityHooks.on_terrain_change(self, m)
	return true

## Ends the terrain (Steel Roller, Ice Spinner, Defog, timeout).
func clear_terrain() -> void:
	if terrain == "":
		return
	log_msg({"electric": "The electricity disappeared from the battlefield.", "grassy": "The grass disappeared from the battlefield.",
		"misty": "The mist disappeared from the battlefield.", "psychic": "The weirdness disappeared from the battlefield!"}.get(terrain, ""))
	terrain = ""
	terrain_turns = 0
	emit({"e": "terrain", "t": ""})
	for m in _speed_sorted(all_active()):
		AbilityHooks.on_terrain_change(self, m)

## Toggles a field effect (trick_room, gravity, magic_room, wonder_room) for 5 turns; using it again ends
## Trick Room / Magic Room / Wonder Room early (Gravity fails instead).
func toggle_field(f: String, turns: int = 5) -> void:
	var names := {"trick_room": "Trick Room", "gravity": "Gravity", "magic_room": "Magic Room", "wonder_room": "Wonder Room"}
	if field.has(f):
		if f == "gravity":
			log_msg("But it failed!")
			return
		field.erase(f)
		emit({"e": "field", "f": f, "on": false})
		log_msg({"trick_room": "The twisted dimensions returned to normal!", "magic_room": "Magic Room wore off, and held items' effects returned to normal!",
			"wonder_room": "Wonder Room wore off, and Defense and Sp. Def stats returned to normal!"}.get(f, "%s ended." % names.get(f, f)))
		return
	field[f] = turns
	emit({"e": "field", "f": f, "on": true})
	log_msg({"trick_room": "The dimensions were twisted!", "gravity": "Gravity intensified!",
		"magic_room": "It created a bizarre area in which Pokémon's held items lose their effects!",
		"wonder_room": "It created a bizarre area in which Defense and Sp. Def stats are swapped!"}.get(f, ""))
	if f == "gravity":
		for m in all_active():
			for v in ["magnet_rise", "telekinesis", "semi_invuln"]:
				m.vol.erase(v)
			if m.vol.has("charging") and str(bd.move(int(m.moves[int(m.vol.charging.idx)].id)).get("name", "")) in ["Fly", "Bounce", "Sky Drop"]:
				m.vol.erase("charging")

## Grounded? (Gen 4+ rules): Iron Ball, Gravity, Ingrain, Smack Down ground it; otherwise Flying types,
## Levitate, Air Balloon, Magnet Rise and Telekinesis lift it.
func is_grounded(m: BattleMon) -> bool:
	if ItemHooks.grounds(self, m) or field.has("gravity") or m.vol.has("ingrain") or m.vol.has("smacked_down"):
		return true
	if m.has_type(TypeChart.FLYING) and not m.vol.has("roosted"):
		return false
	var h := AbilityHooks.hook(self, m)
	if str(h.get("k", "")) == "type_immune" and int(h.get("type", -1)) == TypeChart.GROUND:
		return false
	if ItemHooks.floats(self, m) or m.vol.has("magnet_rise") or m.vol.has("telekinesis"):
		return false
	return true

## Roar-style: in a wild battle the battle ends; against a trainer the target is swapped for a random
## bench mon. Suction Cups and Ingrain hold it in place.
func force_out(user: BattleMon, target: BattleMon) -> void:
	if target.fainted():
		return
	if AbilityHooks.suction_cups(self, target):
		log_msg("%s anchors itself with %s!" % [target.name, bd.ability_name(target.ability)])
		return
	if target.vol.has("ingrain"):
		log_msg("%s anchored itself with its roots!" % target.name)
		return
	if kind == "wild" and not is_doubles():
		log_msg("%s fled!" % target.name if target.side_id == FOE else "%s was blown away!" % target.name)
		_finish("run")
		return
	var bench := _bench(target.side_id, target.owner if target.side_id == PLAYER else -1)
	if bench.is_empty():
		log_msg("But it failed!")
		return
	_do_switch(side_of(target), target.slot, int(bench[rng.below(bench.size())]))
	user.vol.erase("noop")

## A mon pivots out after its move (U-turn, Volt Switch, Flip Turn, Parting Shot, Baton Pass, Shed Tail,
## Teleport, Chilly Reception). opts: {baton: true (keep stages + some volatiles), shed_tail: true (pass a
## Substitute)}. AI mons switch at once; a player mon pauses the turn for the choice (phase "pivot").
## Returns false when there is nobody to switch in.
func request_pivot(m: BattleMon, opts: Dictionary = {}) -> bool:
	if m.fainted() or m.slot < 0 or over:
		return false
	var side := side_of(m)
	var pid := m.owner if side.kind == "player" and is_doubles() else -1
	var bench := _bench(m.side_id, pid)
	if bench.is_empty():
		return false
	var pv := {"side": m.side_id, "slot": m.slot, "pid": m.owner if side.kind == "player" else -1}
	pv.merge(opts)
	if side.kind == "player":
		_pivot = pv
	else:
		_pivot_switch(pv, BattleAI.pick_replacement(self, m.side_id, bench))
	return true

# Does the pivot switch: Baton Pass carries stat stages and some volatiles; Shed Tail carries a Substitute.
func _pivot_switch(pv: Dictionary, to: int) -> void:
	var side: Dictionary = sides[int(pv.side)]
	var old := active(int(pv.side), int(pv.slot))
	var keep_stages := {}
	var keep_vol := {}
	if old != null:
		if pv.get("baton", false):
			keep_stages = old.stages.duplicate()
			for v in ["confused", "focus_energy", "seeded", "substitute", "cursed", "aqua_ring", "ingrain", "magnet_rise", "perish", "embargo", "heal_block", "cant_flee", "laser_focus"]:
				if old.vol.has(v):
					keep_vol[v] = old.vol[v]
		elif pv.get("shed_tail", false) and old.vol.has("shed_sub"):
			keep_vol["substitute"] = old.vol.shed_sub
		log_msg("%s went back to %s!" % [old.name, owner_names.get(old.owner, "its trainer") if side.kind == "player" else side.name])
	_do_switch(side, int(pv.slot), to, keep_stages, keep_vol)

## Records a ROM effect id that has no implementation yet.
func note_unknown(eff_id: int) -> void:
	unknown_effects[eff_id] = int(unknown_effects.get(eff_id, 0)) + 1

## Records a partially implemented effect (profile "todo" note).
func note_todo(t: String) -> void:
	todos[t] = int(todos.get(t, 0)) + 1

# ------------------------------------------------------------------ switching, fainting, end of turn

func _emit_send(side: Dictionary, s: int) -> void:
	var m: BattleMon = side.mons[side.active[s]]
	m.slot = s
	m.fought = m.fought or side.kind == "player"
	emit({"e": "send", "side": side.id, "slot": s, "mon": m.snapshot()})
	if side.kind == "player":
		if owner_names.has(m.owner) and side.owners.size() > 1:
			log_msg("%s sent out %s!" % [owner_names[m.owner], m.name])
		else:
			log_msg("Go! %s!" % m.name)
	elif side.kind == "trainer":
		log_msg("%s sent out %s!" % [side.name, m.name])

## Switches slot s of `side` to party index `to`: switch-out abilities (Regenerator, Natural Cure), the
## outgoing mon's volatiles end, then the newcomer arrives: slot effects (Healing Wish), entry hazards,
## entry abilities and items. keep_stages / keep_vol = what Baton Pass / Shed Tail pass on.
func _do_switch(side: Dictionary, s: int, to: int, keep_stages: Dictionary = {}, keep_vol: Dictionary = {}) -> void:
	# Two AI slots switching in the same turn can claim the same bench mon (their choices are made
	# before either switch runs): send the second one to the next healthy bench mon instead, or stay
	# put when there is none.
	if side.active.has(to):
		var alt := -1
		for i in side.mons.size():
			if not side.mons[i].fainted() and not side.active.has(i):
				alt = i
				break
		if alt < 0:
			return
		to = alt
	var cur: int = side.active[s]
	if cur >= 0:
		var old: BattleMon = side.mons[cur]
		if not old.fainted():
			AbilityHooks.on_switch_out(self, old)
		old.clear_volatiles()
		old.slot = -1
		if int(side.get("center", -1)) == s:
			side.erase("center")
		# Anyone trapped / seeded / attracted by the outgoing mon is freed.
		for x in all_active():
			for v in ["cant_flee", "attract", "trapped"]:
				if x.vol.has(v) and x.vol[v] is Dictionary and int(x.vol[v].get("side", -1)) == side.id and int(x.vol[v].get("slot", -1)) == s:
					x.vol.erase(v)
	side.active[s] = to
	var m: BattleMon = side.mons[to]
	m.vol.clear()
	m.reset_stages()
	for k in keep_stages:
		m.stages[k] = keep_stages[k]
	for k in keep_vol:
		m.vol[k] = keep_vol[k]
	_emit_send(side, s)
	_on_arrive(side, s, m)

# Everything that happens when a mon lands on the field (switch-in or replacement).
func _on_arrive(side: Dictionary, s: int, m: BattleMon) -> void:
	var fx: Dictionary = _slot_fx(side, s)
	if fx.has("healing_wish"):
		fx.erase("healing_wish")
		if m.hp < m.max_hp() or m.status != "":
			m.hp = m.max_hp()
			m.status = ""
			m.status_turns = 0
			emit_hp(m)
			emit_status(m)
			log_msg("The healing wish came true for %s!" % m.name)
	_apply_hazards(side, m)
	if m.fainted():
		return
	AbilityHooks.on_entry(self, m)
	ItemHooks.on_entry(self, m)
	ItemHooks.check_hp_items(self, m)
	ItemHooks.check_status_items(self, m)

## The slot-effect dictionary of a side's slot (wish, healing_wish, future sight), created on demand.
func _slot_fx(side: Dictionary, s: int) -> Dictionary:
	if not side.has("slot_fx"):
		side["slot_fx"] = {}
	var k := str(s)
	if not side.slot_fx.has(k):
		side.slot_fx[k] = {}
	return side.slot_fx[k]

## Entry hazards on the side (spikes 1-3, toxic_spikes 1-2, stealth_rock, sticky_web). Created on demand.
func hazards(side: Dictionary) -> Dictionary:
	if not side.has("hazards"):
		side["hazards"] = {}
	return side.hazards

func _apply_hazards(side: Dictionary, m: BattleMon) -> void:
	var hz: Dictionary = side.get("hazards", {})
	if hz.is_empty() or ItemHooks.ignores_hazards(self, m):
		return
	var mg := AbilityHooks.magic_guard(self, m)
	if hz.has("stealth_rock") and not mg:
		var e := TypeChart.effectiveness(bd, TypeChart.ROCK, m)
		damage(m, maxi(1, int(m.max_hp() * e / 8.0)), "Pointed stones dug into %s!" % m.name)
	var grounded := is_grounded(m)
	if hz.has("spikes") and grounded and not mg and not m.fainted():
		var den: int = {1: 8, 2: 6, 3: 4}.get(int(hz.spikes), 8)
		damage(m, maxi(1, m.max_hp() / den), "%s was hurt by the spikes!" % m.name)
	if hz.has("toxic_spikes") and grounded and not m.fainted():
		if m.has_type(TypeChart.POISON):
			hz.erase("toxic_spikes")
			log_msg("The poison spikes disappeared from the ground around %s's team!" % ("your" if side.id == PLAYER else "the opposing"))
		elif m.status == "" and BattleRules.can_get_status(self, m, "psn") and not side.cond.has("safeguard"):
			set_status(m, "tox" if int(hz.toxic_spikes) >= 2 else "psn", "")
	if hz.has("sticky_web") and grounded and not m.fainted():
		log_msg("%s was caught in a sticky web!" % m.name)
		boost(m, "spe", -1, true)

func _check_faints() -> void:
	# Fainted active mons are reported in the order their HP reached 0 (a spread move that knocks out its
	# user's ally and a foe reports the ally first, as Showdown does); mons with no recorded order (set to
	# 0 HP directly, e.g. tests) come last in side/slot order.
	var down: Array = []
	for side in sides:
		for s in side.active.size():
			var i: int = side.active[s]
			if i < 0:
				continue
			var m: BattleMon = side.mons[i]
			if m.fainted() and not m.vol.has("fainted_reported"):
				down.append([int(_faint_seq.get(m.get_instance_id(), 1 << 30)), down.size(), side, s, m])
	down.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	for d in down:
		var side: Dictionary = d[2]
		var s: int = d[3]
		var m: BattleMon = d[4]
		m.vol["fainted_reported"] = true
		emit({"e": "faint", "side": side.id, "slot": s})
		log_msg("%s fainted!" % m.name)
		side["fainted_turn"] = turn
		side["faints"] = int(side.get("faints", 0)) + 1
		# Gen 3 friendship: fainting in battle lowers friendship by 1 (player mons only — foe records
		# are discarded when the battle ends).
		if side.id == PLAYER:
			m.friendship = maxi(0, m.friendship - 1)
		AbilityHooks.on_faint(self, m)
		if side.id == FOE:
			_award_exp(m)
	if not side_alive(PLAYER):
		log_msg("You are out of usable Pokémon!")
		_finish("lose")
	elif not side_alive(FOE):
		if kind == "trainer":
			log_msg("You defeated %s!" % sides[FOE].name)
		_finish("win")

# EXP and EVs (Gen 3): the foe's total EXP (floor(base * level / 7), x1.5 for a trainer's Pokémon) is
# divided equally among the participants — the player mons that were sent out and are still standing and
# below level 100. When any party member holds an Exp. Share, the total is split in half: one half divided
# equally among the participants, the other half divided equally among the Exp. Share holders (a
# participant that also holds one gets both shares). Lucky Egg x1.5 applies to each mon's own share, after
# the split (BattleRules.exp_gain). Every mon that gains EXP also gains the foe's EV yield. (The Gen 6+
# exp_share_all key-item flag is kept for callers that set it: with no held Exp. Shares, benched mons
# then get half of a participant's share each.)
func _award_exp(foe: BattleMon) -> void:
	var side: Dictionary = sides[PLAYER]
	if not side_alive(PLAYER):
		return   # the battle is lost: no EXP, even for Exp. Share holders
	var ev: Dictionary = bd.species(foe.species).get("ev_yield", {})
	var fighters: Array = []
	var holders: Array = []
	for i in side.mons.size():
		var m: BattleMon = side.mons[i]
		if m.fainted() or m.level >= 100:
			continue
		if m.fought:
			fighters.append(i)
		if ItemHooks.key(self, m) == "exp_share":
			holders.append(i)
	if fighters.is_empty() and holders.is_empty():
		return
	var gains := {}
	if not holders.is_empty():
		for i in fighters:
			gains[i] = int(gains.get(i, 0)) + BattleRules.exp_gain(bd, foe, side.mons[i], kind == "trainer", 1, fighters.size() * 2)
		for i in holders:
			gains[i] = int(gains.get(i, 0)) + BattleRules.exp_gain(bd, foe, side.mons[i], kind == "trainer", 1, holders.size() * 2)
	else:
		for i in fighters:
			gains[i] = BattleRules.exp_gain(bd, foe, side.mons[i], kind == "trainer", 1, fighters.size())
		if exp_share_all and not fighters.is_empty():
			for i in side.mons.size():
				if gains.has(i) or side.mons[i].fainted() or side.mons[i].level >= 100:
					continue
				gains[i] = BattleRules.exp_gain(bd, foe, side.mons[i], kind == "trainer", 1, fighters.size() * 2)
	for i in gains.keys():
		var m: BattleMon = side.mons[i]
		var g := int(gains[i])
		m.exp += g
		emit({"e": "exp", "side": PLAYER, "idx": i, "gained": g, "exp": m.exp})
		log_msg("%s gained %d Exp. Points!" % [m.name, g])
		var total := 0
		for v in m.evs:
			total += int(v)
		for k in ev:
			var si := BattleMon.STAT_KEYS.find(k)
			var add := mini(int(ev[k]), maxi(0, 510 - total))
			if si >= 0 and add > 0:
				m.evs[si] = mini(252, int(m.evs[si]) + add)
				total += add
		while m.level < 100 and m.exp >= bd.exp_at(m.growth, m.level + 1):
			_level_up(m, i)

func _level_up(m: BattleMon, idx: int) -> void:
	m.level += 1
	m.recalc_stats(bd)
	# Gen 3 friendship: levelling up raises friendship by +5 (0-99), +3 (100-199) or +2 (200-255).
	m.friendship = mini(255, m.friendship + (5 if m.friendship < 100 else 3 if m.friendship < 200 else 2))
	leveled_up[idx] = true
	emit({"e": "level", "side": PLAYER, "idx": idx, "level": m.level, "mon": m.snapshot()})
	if m.slot >= 0:
		emit_hp(m)
	log_msg("%s grew to Lv. %d!" % [m.name, m.level])
	for e in bd.learnset(m.species):
		if int(e[1]) != m.level or m.move_index(int(e[0])) >= 0 or int(e[0]) <= 0:
			continue
		var md := bd.move(int(e[0]))
		if md.is_empty():
			continue
		if m.moves.size() < 4:
			m.moves.append({"id": int(e[0]), "pp": int(md.pp), "max_pp": int(md.pp)})
			log_msg("%s learned %s!" % [m.name, md.name])
		else:
			# The forget-a-move choice is made after the battle (BattleController "learn_pending" +
			# BattleMon.replace_move) so the turn flow stays unchanged.
			emit({"e": "learn_full", "side": PLAYER, "idx": idx, "move": int(e[0])})
			learn_pending.append({"idx": idx, "owner": m.owner, "move": int(e[0])})
			log_msg("%s wants to learn %s, but it already knows four moves." % [m.name, md.name])

## End of turn, in the Gen 8/9 residual order (Showdown onResidualOrder): weather and its abilities,
## Future Sight, Wish, Grassy Terrain, Leftovers / Black Sludge, Aqua Ring, Ingrain, Leech Seed, poison /
## burn (Poison Heal, Magic Guard), Nightmare, Curse, binding, Salt Cure, volatile countdowns (Taunt,
## Encore, Disable, Heal Block, Embargo, Magnet Rise, Throat Chop), Yawn, Perish Song, end-of-turn
## abilities (Speed Boost, Moody, Shed Skin, Hydration), Flame / Toxic Orb, then side conditions, field
## effects and terrain count down.
func _end_of_turn() -> void:
	var ws := AbilityHooks.weather_suppressed(self)
	# 1. Weather countdown, chip damage and weather abilities.
	if weather != "":
		weather_turns -= 1
		if weather_turns <= 0:
			log_msg({"rain": "The rain stopped.", "sun": "The harsh sunlight faded.", "sand": "The sandstorm subsided.",
				"hail": "The hail stopped.", "snow": "The snow stopped."}.get(weather, ""))
			weather = ""
			emit({"e": "weather", "w": ""})
		else:
			log_msg({"rain": "Rain continues to fall.", "sun": "The sunlight is strong.", "sand": "The sandstorm is raging.",
				"hail": "Hail continues to fall.", "snow": "Snow continues to fall."}.get(weather, ""))
			for m in _speed_sorted(all_active()):
				if ws or m.fainted():
					continue
				if weather == "sand" or weather == "hail":
					var safe: bool = (m.has_type(TypeChart.ROCK) or m.has_type(TypeChart.GROUND) or m.has_type(TypeChart.STEEL)) if weather == "sand" else m.has_type(TypeChart.ICE)
					if not safe and not AbilityHooks.weather_immune(self, m, weather) and not ItemHooks.powder_immune(self, m) and not m.vol.has("semi_invuln"):
						damage(m, maxi(1, m.max_hp() / 16), "%s is buffeted by the %s!" % [m.name, "sandstorm" if weather == "sand" else "hail"])
				AbilityHooks.on_weather(self, m)
	_check_faints()
	if over:
		return
	# 2. Future Sight and Wish (slot effects).
	for side in sides:
		for sk in side.get("slot_fx", {}).keys():
			var fx: Dictionary = side.slot_fx[sk]
			var t := active(side.id, int(sk))
			if fx.has("future"):
				fx.future.turns = int(fx.future.turns) - 1
				if int(fx.future.turns) <= 0:
					var f: Dictionary = fx.future
					fx.erase("future")
					if t != null and not t.fainted():
						log_msg("%s took the %s attack!" % [t.name, str(f.mv.name)])
						MoveEffects.hit(self, f.src, t, f.mv, {"future": true})
			if fx.has("wish"):
				fx.wish.turns = int(fx.wish.turns) - 1
				if int(fx.wish.turns) <= 0:
					var w: Dictionary = fx.wish
					fx.erase("wish")
					if t != null and not t.fainted() and t.hp < t.max_hp():
						heal(t, int(w.hp), "%s's wish came true!" % str(w.name))
	_check_faints()
	if over:
		return
	for m in _speed_sorted(all_active()):
		if m.fainted():
			continue
		# 3. Grassy Terrain heals grounded mons 1/16.
		if terrain == "grassy" and is_grounded(m) and m.hp < m.max_hp():
			heal(m, maxi(1, m.max_hp() / 16), "%s's HP was restored." % m.name)
		# 4. Leftovers / Black Sludge.
		ItemHooks.on_residual_heal(self, m)
		# 5. Aqua Ring, Ingrain (Big Root x1.3).
		if m.vol.has("aqua_ring") and m.hp < m.max_hp():
			heal(m, ItemHooks.drain_heal(self, m, maxi(1, m.max_hp() / 16)), "A veil of water restored %s's HP!" % m.name)
		if m.vol.has("ingrain") and m.hp < m.max_hp():
			heal(m, ItemHooks.drain_heal(self, m, maxi(1, m.max_hp() / 16)), "%s absorbed nutrients with its roots!" % m.name)
		# 6. Leech Seed: 1/8 to the seeder's slot (Liquid Ooze hurts it instead).
		if m.vol.has("seeded") and not m.fainted() and not AbilityHooks.magic_guard(self, m):
			var src := active(int(m.vol.seeded.side), int(m.vol.seeded.slot))
			if src != null and not src.fainted():
				var d := mini(m.hp, maxi(1, m.max_hp() / 8))
				damage(m, d, "%s's health is sapped by Leech Seed!" % m.name)
				if AbilityHooks.liquid_ooze(self, m):
					damage(src, ItemHooks.drain_heal(self, src, d), "%s sucked up the liquid ooze!" % src.name)
				else:
					heal(src, ItemHooks.drain_heal(self, src, d), "")
		# 7. Poison / burn (Poison Heal heals 1/8 instead; Magic Guard blocks the damage).
		if m.status in ["psn", "tox"] and AbilityHooks.poison_heal(self, m):
			if m.status == "tox":
				m.status_turns = mini(15, m.status_turns + 1)
			if m.hp < m.max_hp():
				heal(m, maxi(1, m.max_hp() / 8), "%s is healed by poison!" % m.name)
		elif not m.fainted():
			var chip := BattleRules.status_chip(m, self)
			if chip > 0 and not AbilityHooks.magic_guard(self, m):
				damage(m, chip, "%s was hurt by its %s!" % [m.name, "burn" if m.status == "brn" else "poisoning"])
		# 8. Nightmare, Curse.
		if m.vol.has("nightmare") and m.status == "slp" and not m.fainted() and not AbilityHooks.magic_guard(self, m):
			damage(m, maxi(1, m.max_hp() / 4), "%s is locked in a nightmare!" % m.name)
		if m.vol.has("cursed") and not m.fainted() and not AbilityHooks.magic_guard(self, m):
			damage(m, maxi(1, m.max_hp() / 4), "%s is afflicted by the curse!" % m.name)
		# 9. Binding moves (Gen 6+: 1/8 for 4-5 turns, Binding Band 1/6).
		if m.vol.has("trapped") and not m.fainted():
			m.vol.trapped.turns = int(m.vol.trapped.turns) - 1
			if int(m.vol.trapped.turns) <= 0:
				m.vol.erase("trapped")
				log_msg("%s was freed!" % m.name)
			elif not AbilityHooks.magic_guard(self, m):
				damage(m, maxi(1, m.max_hp() / int(m.vol.trapped.get("den", 8))), "%s is hurt by the trap!" % m.name)
		# 10. Salt Cure (1/8, 1/4 for Water / Steel).
		if m.vol.has("salt_cure") and not m.fainted() and not AbilityHooks.magic_guard(self, m):
			var den := 4 if (m.has_type(TypeChart.WATER) or m.has_type(TypeChart.STEEL)) else 8
			damage(m, maxi(1, m.max_hp() / den), "%s is being salt cured!" % m.name)
		if m.fainted():
			continue
		# 11. Volatile countdowns.
		for v in ["taunt", "encore", "disabled", "heal_block", "embargo", "magnet_rise", "throat_chop", "telekinesis", "laser_focus_t"]:
			if not m.vol.has(v):
				continue
			var left := 0
			if m.vol[v] is Dictionary:
				m.vol[v].turns = int(m.vol[v].turns) - 1
				left = int(m.vol[v].turns)
			else:
				m.vol[v] = int(m.vol[v]) - 1
				left = int(m.vol[v])
			if v == "encore" and m.vol.has("encore") and int(m.vol.encore.idx) < m.moves.size() and int(m.moves[int(m.vol.encore.idx)].pp) <= 0:
				left = 0
			if left <= 0:
				m.vol.erase(v)
				var end_text: String = {"taunt": "%s's taunt wore off!", "encore": "%s's encore ended!", "disabled": "%s's move is no longer disabled!",
					"heal_block": "%s's Heal Block wore off!", "embargo": "%s can use items again!", "magnet_rise": "%s's electromagnetism wore off!",
					"telekinesis": "%s was freed from the telekinesis!"}.get(v, "")
				if end_text != "":
					log_msg(end_text % m.name)
				if v == "laser_focus_t":
					m.vol.erase("laser_focus")
		# 12. Yawn, Perish Song.
		if m.vol.has("yawn"):
			m.vol.yawn = int(m.vol.yawn) - 1
			if int(m.vol.yawn) <= 0:
				m.vol.erase("yawn")
				try_status(m, "slp", false, m)
		if m.vol.has("perish"):
			m.vol.perish = int(m.vol.perish) - 1
			log_msg("%s's perish count fell to %d." % [m.name, int(m.vol.perish)])
			if int(m.vol.perish) <= 0:
				damage(m, m.hp, "")
		if m.fainted():
			continue
		# 13. Abilities, then Flame / Toxic Orb; berries after residual damage.
		AbilityHooks.on_turn_end(self, m)
		ItemHooks.on_turn_end_last(self, m)
		ItemHooks.check_hp_items(self, m)
		ItemHooks.check_status_items(self, m)
	# Per-turn volatiles.
	for m in all_active():
		for v in ["hurt_this_turn", "last_hit", "flinch", "protect", "protect_kind", "endure", "helping_hand", "moved_this_turn", "stat_dropped", "focusing", "roosted", "electrified", "charge_used"]:
			m.vol.erase(v)
		if not m.vol.has("protect_used_this_turn"):
			m.vol.erase("protect_chain")
		m.vol.erase("protect_used_this_turn")
		m.vol["turns_in"] = int(m.vol.get("turns_in", 0)) + 1
	# 14. Side conditions, field effects and terrain count down.
	var cond_names := {"reflect": "Reflect", "lightscreen": "Light Screen", "aurora_veil": "Aurora Veil", "safeguard": "Safeguard",
		"mist": "Mist", "tailwind": "Tailwind", "lucky_chant": "Lucky Chant"}
	for side in sides:
		side.erase("center")
		for c in side.cond.keys():
			side.cond[c] = int(side.cond[c]) - 1
			if int(side.cond[c]) <= 0:
				side.cond.erase(c)
				var who := "Your" if side.id == PLAYER else "The opposing"
				log_msg("%s team's %s wore off!" % [who, cond_names.get(c, c)] if c != "tailwind" else "%s team's tailwind petered out!" % who)
	for f in field.keys():
		field[f] = int(field[f]) - 1
		if int(field[f]) <= 0:
			if f == "gravity":
				_end_gravity()
			else:
				field[f] = 1
				toggle_field(f)   # the second call ends it
	if terrain != "":
		terrain_turns -= 1
		if terrain_turns <= 0:
			clear_terrain()

func _end_gravity() -> void:
	field.erase("gravity")
	emit({"e": "field", "f": "gravity", "on": false})
	log_msg("Gravity returned to normal!")

func _auto_replace_ai() -> void:
	var side: Dictionary = sides[FOE]
	for s in side.active.size():
		var m := active(FOE, s)
		if m != null and not m.fainted():
			continue
		var bench := _bench(FOE, -1)
		if bench.is_empty():
			continue
		_do_switch(side, s, BattleAI.pick_replacement(self, FOE, bench))

## Mons sorted for residual effects: faster first (slower first under Trick Room), ties by side/slot.
func _speed_sorted(arr: Array) -> Array:
	var a := arr.duplicate()
	var tr := field.has("trick_room")
	a.sort_custom(func(x, y):
		var sx := BattleRules.speed_of(self, x)
		var sy := BattleRules.speed_of(self, y)
		return (sx < sy) if tr else (sx > sy))
	return a

func _finish(o: String) -> void:
	if over:
		return
	over = true
	outcome = o
	phase = "over"
	emit({"e": "end", "outcome": o})

## Ends the battle at once (player quit).
func forfeit() -> Array:
	events = []
	_finish("forfeit")
	return _flush()

func _flush() -> Array:
	var out := events
	history.append_array(out)
	events = []
	return out

# ------------------------------------------------------------------ results / snapshots

## Updated party records per player pid: {pid: [party records]}. `originals` = {pid: original party array}.
func results(originals: Dictionary) -> Dictionary:
	var out := {}
	for pid in originals:
		var orig: Array = originals[pid]
		var arr: Array = []
		for i in orig.size():
			arr.append(orig[i])
		for m in sides[PLAYER].mons:
			if m.owner == int(pid) and m.party_index >= 0 and m.party_index < arr.size():
				arr[m.party_index] = m.to_party(bd, orig[m.party_index])
		out[pid] = arr
	return out

## The caught mon as a new party record ({} if none).
func caught_record() -> Dictionary:
	if caught == null:
		return {}
	caught.clear_volatiles()
	return caught.to_party(bd, {"species": caught.species, "name": caught.name})

## Everything the UI needs to draw the battle (both sides, active slots, phase, whose input is needed).
func snapshot() -> Dictionary:
	var ss: Array = []
	for side in sides:
		var mons: Array = []
		for m in side.mons:
			mons.append(m.snapshot())
		ss.append({"id": side.id, "kind": side.kind, "name": side.get("name", ""), "active": side.active.duplicate(), "mons": mons,
			"owners": side.get("owners", []).duplicate(), "cond": side.cond.keys(), "hazards": side.get("hazards", {}).duplicate()})   # owners: player side only
	return {"turn": turn, "format": format, "kind": kind, "phase": phase, "weather": weather, "over": over,
		"outcome": outcome, "sides": ss, "need": needed(),
		"terrain": terrain, "field": field.keys()}   # battle parity, additive
