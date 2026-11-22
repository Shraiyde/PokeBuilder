class_name BattleNetLink
extends RefCounted
## BattleNetLink — INTENTIONALLY STUBBED in the PokeBuilder port.
## The PokeBuilder port is single-player only; its co-op is a separate system and must not be touched.
## The original Quetzal Coop file was a WebSocket adapter between BattleController (online mode) and the
## networking client. That online/co-op path does not exist here, so this file only answers "offline".
## Any code that used to call BattleNetLink.new(...) / send() / deliver() / my_pid() / want_coop() must
## not be ported; battles in this port always run offline.

## Always false: there is no online battle link in this port.
static func is_online() -> bool:
	return false
