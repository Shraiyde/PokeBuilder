class_name BattleController
extends Node
## BattleController — THE entry point for starting a battle from the game (tall grass, trainer scripts,
## dowildbattle). It runs one battle, shows the battle screen, and returns the result when it is over.
##
##   var r: Dictionary = await BattleController.start_wild(host, party, species_id, level, opts)
##   var r: Dictionary = await BattleController.start_trainer(host, party, trainer_id, opts)
##
##   host   any Node in the scene tree (the battle screen is added under it and freed afterwards)
##   party  the player's party: Array of party records (core/party_mon.gd format). Not modified in place.
##   opts   {cache_dir: String (default DATA_DIR), seed: int (default random),
##           table: int (trainer table 0/1/2, default 0),
##           auto: bool (AI plays the player's side; tests/demos), ui: bool (default true; false = headless),
##           ball_ctx: Dictionary (overworld ball conditions: night, cave, water, fishing, caught_before,
##           dex_caught — for ball multipliers and critical captures; default {})}
##   result {outcome: "win"|"lose"|"run"|"caught"|"forfeit"|"no_party"|"no_data",
##           party: Array (updated records: HP, PP, status, level, exp, moves, EVs), caught: Dictionary ({} if none),
##           turns: int, online: false}
##
## Offline only (port note): the Quetzal source also ran server-authoritative online / co-op battles
## (join / server-message / auto-online / co-op-slot helpers). All of that was removed in this port —
## BattleState runs right here on the phone with a local seed, and the result always reports
## online:false. The port's separate network-link file is NOT referenced from this file.
## Depends on: BattleData, BattleState, BattleAI, Evolution, Shiny, BattleMon, the battle screen at
## BATTLE_SCREEN_PATH. Used by: the game's start_battle() swap point.

## Battle data location in the port (res://data). Override per battle with opts "cache_dir".
const DATA_DIR := "res://data"
## Where the battle screen lives in the port.
const BATTLE_SCREEN_PATH := "res://scripts/qbattle/ui/battle_screen.gd"

signal finished(result: Dictionary)
## Emitted with every batch of events to play back (begin, each turn). state = BattleState.snapshot().
signal events_ready(events: Array, state: Dictionary)

var bd: BattleData
var st: BattleState              # offline only
var party_in: Array = []
var pid := 1
var auto := false
var state := {}                  # latest snapshot
var _result := {}
var ot_id := 0                   # player's trainer id for the wild shiny check (opts "ot_id")
var force_shiny := false         # tests/screenshots: make wild foes shiny (opts "force_shiny")
var ball_ctx := {}               # ball conditions from the overworld (opts "ball_ctx"; see _run)
var foe_party: Array = []       # port: explicit trainer foe party from opts "foe_party" (see _begin_offline)
var foe2: Array = []            # port: second wild foe from opts "foe2" = [species, level] (double wild battle)
var _trainer_name := ""         # port: trainer display name from opts "trainer_name"
var what := {}                   # how this battle was started: {kind:"wild", species, level} or {kind:"trainer", trainer, table}
                                 # (read by BattleScreen for the trainer picture)

## Starts a wild battle (see header). Awaitable: returns the result dictionary.
static func start_wild(host: Node, party: Array, species_id: int, level: int, opts: Dictionary = {}) -> Dictionary:
	return await _run(host, party, {"kind": "wild", "species": species_id, "level": level}, opts)

## Starts a trainer battle against ROM trainer `trainer_id` (opts.table picks the region table, default 0).
static func start_trainer(host: Node, party: Array, trainer_id: int, opts: Dictionary = {}) -> Dictionary:
	return await _run(host, party, {"kind": "trainer", "trainer": trainer_id, "table": int(opts.get("table", 0))}, opts)

static func _run(host: Node, party: Array, what: Dictionary, opts: Dictionary) -> Dictionary:
	var dir: String = opts.get("cache_dir", DATA_DIR)
	var data := BattleData.load_from(dir)
	if not data.ok():
		return {"outcome": "no_data", "party": party, "caught": {}, "turns": 0, "online": false}
	if not party.any(func(p): return int(p.get("hp", 1)) > 0 and int(p.get("species", 0)) > 0):
		return {"outcome": "no_party", "party": party, "caught": {}, "turns": 0, "online": false}
	var c := BattleController.new()
	c.name = "BattleController"
	c.bd = data
	c.party_in = party.duplicate(true)
	c.auto = opts.get("auto", false)
	c.ot_id = int(opts.get("ot_id", 0))
	c.force_shiny = bool(opts.get("force_shiny", false))
	host.add_child(c)
	var screen = null
	if opts.get("ui", true):
		screen = load(BATTLE_SCREEN_PATH).new()
		screen.setup(c)
		host.add_child(screen)
	var seed := int(opts.get("seed", randi()))
	# 0.1.65 (battle parity): ball conditions from the overworld — {night, cave, water, fishing,
	# caught_before, dex_caught}. The overworld passes them in opts; the engine reads them
	# for Dusk/Nest/Timer/Repeat/Lure balls and for critical captures (dex_caught = species registered).
	c.ball_ctx = opts.get("ball_ctx", {})
	# Port: explicit foe data (the port has no trainer table, so trainer battles
	# are started with an explicit foe party; wild doubles with a second foe).
	c.foe_party = opts.get("foe_party", [])
	c.foe2 = opts.get("foe2", [])
	c._trainer_name = str(opts.get("trainer_name", ""))
	c._begin(what, seed)
	var r: Dictionary = await c.finished
	if screen != null:
		await screen.closed_after_end()
		screen.queue_free()
	c.queue_free()
	return r

## The player-side slot this client controls. Offline only: there is a single player side, so this is
## always slot 0. (Port note: the source derived this from the co-op pid / snapshot needs; simplified.)
func my_slot() -> int:
	return 0

func _begin(w: Dictionary, seed: int) -> void:
	what = w
	_begin_offline(what, seed)

func _begin_offline(w: Dictionary, seed: int) -> void:
	var players := [{"pid": pid, "party": party_in}]
	if w.kind == "trainer":
		if not foe_party.is_empty():
			# Port: the port has no trainer table, so the caller supplies the
			# foe party directly (opts "foe_party"). The trainer name comes
			# from opts "trainer_name" (default "Trainer").
			st = BattleState.trainer_party(bd, players, foe_party, str(_opts_name()), seed)
		else:
			st = BattleState.trainer(bd, players, int(w.trainer), int(w.get("table", 0)), seed)
	else:
		var foes := [[int(w.get("species", 0)), int(w.get("level", 1))]]
		if not foe2.is_empty():
			foes.append([int(foe2[0]), int(foe2[1])])
		st = BattleState.wild(bd, players, foes, seed)
		_stamp_wild_foes()
	st.ball_ctx = ball_ctx
	var ev := st.begin()
	_publish(ev, st.snapshot())

## The trainer's display name for a foe-party battle (opts "trainer_name").
func _opts_name() -> String:
	return str(_trainer_name) if _trainer_name != "" else "Trainer"

## 0.1.7: wild foes get a PID and shininess against the player's trainer id (opts "ot_id"), before begin()
## so the first snapshot already carries "shiny". Done here (not in BattleState) to keep the engine untouched.
## opts "force_shiny" = tests.
func _stamp_wild_foes() -> void:
	if st == null or st.sides.size() < 2:
		return
	for m in st.sides[1].mons:
		m.pid = Shiny.random_u32()
		m.shiny = force_shiny or Shiny.is_shiny(ot_id, m.pid)
		m.gender = BattleMon.gender_of(m.gender_ratio, m.pid)   # 0.1.9: gender follows the new PID

## What the local player must choose now: [{side, slot, pid, kind: "action"|"switch"}] (from the snapshot).
func needed() -> Array:
	return state.get("need", [])

## Sends the player's choice for a slot. Returns "" if accepted, else a reason.
func submit(slot: int, action: Dictionary) -> String:
	var why := st.submit(0, slot, action)
	if why == "" and st.ready():
		var ev := st.resolve()
		_publish(ev, st.snapshot())
	return why

## Gives up (offline: ends at once).
func forfeit() -> void:
	_publish(st.forfeit(), st.snapshot())

## True once the battle has a result (the screen keeps showing the last events until the player taps).
func is_over() -> bool:
	return not _result.is_empty()

## The finished result (empty until over).
func result() -> Dictionary:
	return _result

func _publish(ev: Array, snap: Dictionary) -> void:
	state = snap
	events_ready.emit(ev, snap)
	if st != null and st.over and _result.is_empty():
		var res := st.results({pid: party_in})
		var party: Array = res.get(pid, party_in).duplicate(true)
		var pending := st.learn_pending.duplicate()
		# Evolution after battle: every mon that levelled up may evolve (level, item-hold, trade, ...).
		# Evolution.apply() returns the evolved record plus any moves that still need a "forget a move?"
		# choice (BattleMon.replace_move). UI for the prompt belongs to the UI worker; we just surface it.
		var ctx := {"party": party, "weather": ""}
		for idx in st.leveled_up.keys():
			var i := int(idx)
			if i < 0 or i >= party.size():
				continue
			var rec: Dictionary = party[i]
			var to := Evolution.after_level_up(bd, rec, ctx)
			if to >= 0:
				var evo := Evolution.apply(bd, rec, to)
				party[i] = evo.rec
				for mv in evo.full:
					pending.append({"idx": i, "owner": rec.get("owner", pid), "move": int(mv)})
		_result = {"outcome": st.outcome, "party": party, "caught": st.caught_record(), "turns": st.turn,
			"online": false, "unknown_effects": st.unknown_effects, "learn_pending": pending}
		finished.emit(_result)
	elif auto and not snap.get("over", false):
		_auto_play.call_deferred()

# Auto mode (tests/demos): the AI chooses for the player too.
func _auto_play() -> void:
	if st == null or st.over:
		return
	for n in st.needed():
		if n.kind == "switch":
			st.submit(0, int(n.slot), {"kind": "switch", "to": int(st._bench(0, int(n.pid))[0])})
		else:
			st.submit(0, int(n.slot), BattleAI.choose(st, 0, int(n.slot), true))
	if st.ready():
		_publish(st.resolve(), st.snapshot())
