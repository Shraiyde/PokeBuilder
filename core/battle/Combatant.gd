## Combatant
## Represents one field slot in a battle (either the player's side or the enemy's).
## Holds the BattlePokemon currently occupying the slot, the queued action
## for the current turn, and any per-slot field effects (Reflect, Mist, etc.).
##
## The battle engine works with Combatant references, not raw Pokemon references,
## so all field-position logic (targeting, priority, order) operates here.
##
## Usage:
##   var slot: Combatant = Combatant.new(Combatant.Side.PLAYER, 0)
##   slot.set_battler(BattlePokemon.wrap(player_party[0]))
##   slot.queue_move("TACKLE", enemy_slot)
##   slot.queue_switch(1)
class_name Combatant
extends RefCounted

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Which side of the field this slot belongs to.
enum Side { PLAYER, ENEMY }

## The category of action queued for this turn.
enum ActionType {
	NONE,     ## No action selected yet
	MOVE,     ## Use a move
	SWITCH,   ## Switch to another team member
	ITEM,     ## Use a bag item (player-side only)
	RUN,      ## Attempt to flee (wild battles, player-side only)
	SKIP,     ## Forced pass (recharge, flinch, sleep, etc.)
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

## Which side of the field this slot belongs to.
var side: Side = Side.PLAYER

## Slot index on the field (0 = left / primary; 1 = right in double battles).
var slot_index: int = 0

# ---------------------------------------------------------------------------
# Battler
# ---------------------------------------------------------------------------

## The BattlePokemon currently occupying this slot.
## null when the slot is empty (between switches, or not yet filled).
var battler: BattlePokemon = null

# ---------------------------------------------------------------------------
# Queued action for the current turn
# ---------------------------------------------------------------------------

## Action type chosen for this turn.
var action_type: ActionType = ActionType.NONE

## Move ID selected (when action_type == MOVE).
var queued_move_id: String = ""

## Combatant targeted by the move (may be null for self-targeting moves).
var queued_target: Combatant = null

## Team index to switch to (when action_type == SWITCH).
var queued_switch_index: int = -1

## Item ID to use (when action_type == ITEM).
var queued_item_id: String = ""

## Item target (when action_type == ITEM; may be null).
var queued_item_target: Combatant = null

# ---------------------------------------------------------------------------
# Effective speed cache
# ---------------------------------------------------------------------------

## Cached turn-order value.  Filled by the battle engine at the start of
## each turn's sorting step; do not set manually.
var effective_speed: int = 0

# ---------------------------------------------------------------------------
# Per-slot field effects
# ---------------------------------------------------------------------------

## True while this slot has a Focus Energy boost active.
## Reflect, Light Screen, Mist, Tailwind, and entry hazards are side-wide
## and live on BattleField, not here.
var focus_energy: bool = false

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

func _init(p_side: Side = Side.PLAYER, p_slot_index: int = 0) -> void:
	side       = p_side
	slot_index = p_slot_index

# ---------------------------------------------------------------------------
# Battler management
# ---------------------------------------------------------------------------

## Places a BattlePokemon into this slot.
func set_battler(bp: BattlePokemon) -> void:
	battler = bp


## Removes the current battler and clears the queued action.
func clear_battler() -> void:
	battler = null
	clear_action()


## Returns true when a live (non-fainted) Pokémon occupies this slot.
func is_occupied() -> bool:
	return battler != null and not battler.is_fainted()

# ---------------------------------------------------------------------------
# Action queueing
# ---------------------------------------------------------------------------

## Queues a move action.
func queue_move(move_id: String, target: Combatant) -> void:
	action_type       = ActionType.MOVE
	queued_move_id    = move_id
	queued_target     = target
	queued_switch_index = -1
	queued_item_id    = ""


## Queues a switch action.
func queue_switch(team_index: int) -> void:
	action_type         = ActionType.SWITCH
	queued_switch_index = team_index
	queued_move_id      = ""
	queued_target       = null
	queued_item_id      = ""


## Queues an item use.
func queue_item(item_id: String, target: Combatant) -> void:
	action_type       = ActionType.ITEM
	queued_item_id    = item_id
	queued_item_target = target
	queued_move_id    = ""
	queued_target     = null
	queued_switch_index = -1


## Queues a flee attempt.
func queue_run() -> void:
	action_type         = ActionType.RUN
	queued_move_id      = ""
	queued_target       = null
	queued_switch_index = -1
	queued_item_id      = ""


## Marks this slot as skipping its action this turn.
func queue_skip() -> void:
	action_type         = ActionType.SKIP
	queued_move_id      = ""
	queued_target       = null
	queued_switch_index = -1
	queued_item_id      = ""


## Clears the queued action.
func clear_action() -> void:
	action_type         = ActionType.NONE
	queued_move_id      = ""
	queued_target       = null
	queued_switch_index = -1
	queued_item_id      = ""
	queued_item_target  = null


## Returns true when an action has been selected for this turn.
func has_action() -> bool:
	return action_type != ActionType.NONE

# ---------------------------------------------------------------------------
# Per-slot field effect helpers
# ---------------------------------------------------------------------------

## Clears per-slot effects that reset when the Pokémon switches out.
func clear_field_effects() -> void:
	focus_energy = false
