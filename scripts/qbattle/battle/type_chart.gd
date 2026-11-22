class_name TypeChart
extends RefCounted
## TypeChart — type ids and effectiveness helpers. The multipliers themselves come from the ROM's own type
## chart (BattleData.type_mult, read from the ROM's type chart); this file only names the few type ids the rules
## need for immunities (burned/poisoned/frozen/paralysed checks, weather chip damage, STAB is generic).
## The ids follow the ROM's type-name table order (checked by tests/battle_tests.gd against the ROM).
## Depends on: BattleData. Used by: DamageCalc, BattleRules, MoveEffects, AbilityHooks, BattleAI.

const NORMAL := 0
const FIGHTING := 1
const FLYING := 2
const POISON := 3
const GROUND := 4
const ROCK := 5
const BUG := 6
const GHOST := 7
const STEEL := 8
const MYSTERY := 9    # the "???" type slot; never effective/resisted
const FIRE := 10
const WATER := 11
const GRASS := 12
const ELECTRIC := 13
const PSYCHIC := 14
const ICE := 15
const DRAGON := 16
const DARK := 17
const FAIRY := 18

## Effectiveness of a move type on a battler (product of both defending types). 1.0 for typeless/MYSTERY.
static func effectiveness(bd: BattleData, move_type: int, target: BattleMon) -> float:
	if move_type == MYSTERY:
		return 1.0
	return bd.type_mult(move_type, target.types)

## Short text for an effectiveness value (our own wording), or "" for neutral.
static func describe(mult: float) -> String:
	if mult == 0.0:
		return "No effect."
	if mult > 1.0:
		return "Super effective!"
	if mult < 1.0:
		return "Not very effective..."
	return ""
