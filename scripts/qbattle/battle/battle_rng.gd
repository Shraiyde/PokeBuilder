class_name BattleRng
extends RefCounted
## BattleRng — the only source of randomness inside a battle. Seeded, so the same seed plus the same list of
## player actions always gives the same battle. Offline battles and tests pick their own seed.
## Depends on: nothing. Used by: BattleState, BattleRules, DamageCalc, MoveEffects, BattleAI.

var _r := RandomNumberGenerator.new()
var seed_value := 0
var calls := 0   # how many numbers were drawn (debug aid when comparing client/server)

func _init(seed: int = 0) -> void:
	seed_value = seed
	_r.seed = seed

## Integer in [0, n-1]. n <= 1 returns 0.
func below(n: int) -> int:
	calls += 1
	if n <= 1:
		return 0
	return _r.randi() % n

## Integer in [lo, hi] (inclusive).
func range_i(lo: int, hi: int) -> int:
	return lo + below(hi - lo + 1)

## True with probability pct/100.
func chance(pct: int) -> bool:
	return below(100) < pct

## True with probability num/den.
func ratio(num: int, den: int) -> bool:
	return below(den) < num
