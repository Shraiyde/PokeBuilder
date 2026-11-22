class_name Shiny
extends RefCounted
## Shininess (0.1.7). Our own implementation of the well-known Generation-3 rule: every Pokémon has a 32-bit
## personality value (PID) and every trainer a 32-bit ID (low 16 bits = trainer ID, high 16 = secret ID). The
## Pokémon is shiny when  TID xor SID xor PID_high xor PID_low  < THRESHOLD.
## THRESHOLD 8 gives the classic 1/8192 odds. The ROM hack may use different odds; they are not read from the
## ROM yet (TODO, KI-41), so this constant is our choice, not ROM data.
## 0.1.31 (user rule): shiny odds are 1 in 50, not 1/8192. 1311/65536 = 1/49.98, so THRESHOLD 1311.
## Existing Pokémon keep the shiny flag they were stamped with; new catches and new party members roll
## at the new odds (stamp() only stamps mons with no PID yet).
## Where it is used: Progress keeps the player's ot_id; party records get "pid" + "shiny" (Progress.stamp_party);
## wild foes get a PID at battle start (BattleController, offline); BattleMon carries shiny into the snapshot;
## BattleScreen passes it to the picture hook → RomSprites front_pic/back_pic(species, shiny), which use the
## ROM's own shiny palette. Trainer-owned foes are never shiny (as in the original games).
## Depends on: nothing. Used by: core/progress.gd, battle/battle_controller.gd, tests.

const THRESHOLD := 1311

## True when a Pokémon with personality `pid` is shiny for a trainer with 32-bit id `ot_id`.
static func is_shiny(ot_id: int, pid: int) -> bool:
	var x := (ot_id & 0xFFFF) ^ ((ot_id >> 16) & 0xFFFF) ^ (pid & 0xFFFF) ^ ((pid >> 16) & 0xFFFF)
	return x < THRESHOLD

## Fresh random 32-bit value (PID or trainer id).
static func random_u32() -> int:
	return (randi() & 0xFFFF) | ((randi() & 0xFFFF) << 16)

## Gives a party record a PID and its shininess for owner `ot_id` if it has none yet. Returns the record.
static func stamp(mon: Dictionary, ot_id: int) -> Dictionary:
	if not mon.has("pid"):
		mon["pid"] = random_u32()
		mon["ot"] = ot_id
	mon["shiny"] = is_shiny(int(mon.get("ot", ot_id)), int(mon.pid))
	return mon
