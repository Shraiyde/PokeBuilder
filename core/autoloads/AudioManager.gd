## AudioManager
## Singleton that handles all game audio:
## BGM (background music), SE (sound effects), ME (event jingles)
## and Pokémon cries.
##
## Features:
##   - BGM stack: push / pop tracks (e.g. entering / leaving a cave)
##   - BGM fade in / out with configurable duration
##   - ME pauses BGM while playing and resumes it when finished
##   - Multiple simultaneous SE channels
##   - Independent volume control per category
##   - AudioStream cache to avoid redundant disk reads
##
## Usage:
##   AudioManager.play_bgm("Battle wild")
##   AudioManager.push_bgm("Cave")        # saves the current track and plays the new one
##   AudioManager.pop_bgm()               # restores the previous track
##   AudioManager.play_me("Badge get")    # jingle; BGM resumes afterwards
##   AudioManager.play_se("Battle ball shake")
##   AudioManager.play_cry("PIKACHU")
extends Node

# ---------------------------------------------------------------------------
# Path constants
# ---------------------------------------------------------------------------

const BGM_PATH  := "res://assets/audio/bgm/"
const SE_PATH   := "res://assets/audio/se/"
const ME_PATH   := "res://assets/audio/me/"
const CRY_PATH  := "res://assets/audio/se/cries/"

const SUPPORTED_EXTS := ["ogg", "mp3", "wav"]

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal bgm_changed(track_name: String)
signal me_finished

# ---------------------------------------------------------------------------
# Internal nodes
# ---------------------------------------------------------------------------

var _bgm_player:  AudioStreamPlayer  ## Main BGM player
var _me_player:   AudioStreamPlayer  ## ME (jingle) player
var _se_players:  Array = []         ## SE player pool
var _cry_player:  AudioStreamPlayer  ## Dedicated Pokémon cry player

const SE_POOL_SIZE := 8  ## Number of simultaneous SE channels

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var _bgm_stack:        Array      = []   ## [{name, position, volume_db}]
var _current_bgm_name: String     = ""
var _bgm_paused_by_me: bool       = false
var _cache:            Dictionary = {}   ## path → AudioStream

# ---------------------------------------------------------------------------
# Audio buses
# ---------------------------------------------------------------------------

const BUS_BGM  := "BGM"
const BUS_SE   := "SE"
const BUS_ME   := "ME"

# ---------------------------------------------------------------------------
# Volume (0.0 – 1.0)
# ---------------------------------------------------------------------------

var _vol_master: float = 1.0
var _vol_bgm:    float = 1.0
var _vol_se:     float = 1.0
var _vol_me:     float = 1.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_setup_players()
	process_mode = Node.PROCESS_MODE_ALWAYS  # Audio never pauses with the tree


func _setup_players() -> void:
	# BGM
	_bgm_player = _make_player(BUS_BGM)

	# ME
	_me_player = _make_player(BUS_ME)
	_me_player.finished.connect(_on_me_finished)

	# Cry
	_cry_player = _make_player(BUS_SE)

	# SE pool
	for _i: int in SE_POOL_SIZE:
		_se_players.append(_make_player(BUS_SE))


func _make_player(bus: String) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = bus if AudioServer.get_bus_index(bus) >= 0 else "Master"
	add_child(player)
	return player

# ---------------------------------------------------------------------------
# BGM — Main playback
# ---------------------------------------------------------------------------

## Plays a BGM track with optional fade in.
## If the same track is already playing it is not restarted (unless force=true).
func play_bgm(name: String, volume_db := 0.0, fade_in := 0.0, force := false) -> void:
	if _current_bgm_name == name and not force:
		return

	var stream: AudioStream = _load_audio(BGM_PATH, name)
	if not stream:
		push_warning("AudioManager: BGM not found: '%s'" % name)
		return

	_current_bgm_name = name
	_bgm_player.stream = stream
	_bgm_player.volume_db = -80.0 if fade_in > 0.0 else volume_db
	_bgm_player.play()

	if fade_in > 0.0:
		_fade_bgm_to(volume_db, fade_in)

	bgm_changed.emit(name)


## Stops the BGM with an optional fade out.
func stop_bgm(fade_out := 0.0) -> void:
	if fade_out > 0.0:
		var tween: Tween = create_tween()
		tween.tween_property(_bgm_player, "volume_db", -80.0, fade_out)
		tween.tween_callback(_bgm_player.stop)
	else:
		_bgm_player.stop()
	_current_bgm_name = ""


## Pauses the BGM.
func pause_bgm() -> void:
	_bgm_player.stream_paused = true


## Resumes the BGM.
func resume_bgm() -> void:
	_bgm_player.stream_paused = false


## Changes the BGM volume with a fade of the given duration.
func fade_bgm(target_db: float, time: float) -> void:
	_fade_bgm_to(target_db, time)

# ---------------------------------------------------------------------------
# BGM — Stack (push / pop for caves, events, etc.)
# ---------------------------------------------------------------------------

## Saves the current BGM state and plays a new track.
## Equivalent to entering a dungeon or an event with its own music.
func push_bgm(name: String, volume_db := 0.0, fade_out := 0.3, fade_in := 0.3) -> void:
	if _current_bgm_name != "":
		_bgm_stack.append({
			"name":       _current_bgm_name,
			"position":   _bgm_player.get_playback_position(),
			"volume_db":  _bgm_player.volume_db,
		})

	stop_bgm(fade_out)
	await get_tree().create_timer(fade_out).timeout
	play_bgm(name, volume_db, fade_in)


## Restores the previous BGM from the stack.
## Equivalent to leaving a dungeon or finishing an event.
func pop_bgm(fade_out := 0.3, fade_in := 0.3) -> void:
	if _bgm_stack.is_empty():
		stop_bgm(fade_out)
		return

	var previous: Dictionary = _bgm_stack.pop_back()
	stop_bgm(fade_out)
	await get_tree().create_timer(fade_out).timeout

	var stream: AudioStream = _load_audio(BGM_PATH, previous.name)
	if stream:
		_current_bgm_name = previous.name
		_bgm_player.stream = stream
		_bgm_player.volume_db = -80.0
		_bgm_player.play(previous.position)
		_fade_bgm_to(previous.volume_db, fade_in)
		bgm_changed.emit(previous.name)

# ---------------------------------------------------------------------------
# ME — Event jingles
# ---------------------------------------------------------------------------

## Plays an ME (jingle). Pauses the BGM while it plays and resumes it afterwards.
## Examples: "Badge get", "Item get", "Evolution success".
func play_me(name: String) -> void:
	var stream: AudioStream = _load_audio(ME_PATH, name)
	if not stream:
		push_warning("AudioManager: ME not found: '%s'" % name)
		return

	if _bgm_player.playing:
		pause_bgm()
		_bgm_paused_by_me = true

	_me_player.stream = stream
	_me_player.play()


func _on_me_finished() -> void:
	me_finished.emit()
	if _bgm_paused_by_me:
		_bgm_paused_by_me = false
		resume_bgm()

# ---------------------------------------------------------------------------
# SE — Sound effects
# ---------------------------------------------------------------------------

## Plays a sound effect using the first free channel in the pool.
func play_se(name: String, volume_db := 0.0, pitch_scale := 1.0) -> void:
	var stream: AudioStream = _load_audio(SE_PATH, name)
	if not stream:
		push_warning("AudioManager: SE not found: '%s'" % name)
		return

	var player: AudioStreamPlayer = _get_free_se_player()
	if not player:
		return  # All channels busy, discarded

	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.play()


## Stops all currently playing SE.
func stop_all_se() -> void:
	for p: AudioStreamPlayer in _se_players:
		p.stop()

# ---------------------------------------------------------------------------
# Pokémon cries
# ---------------------------------------------------------------------------

## Plays a Pokémon's cry. Uses the species ID as the filename.
## Allows pitch variation for shinies or alternative forms.
func play_cry(species_id: String, form_index := 0, pitch_scale := 1.0) -> void:
	# Try the form-specific cry first, then fall back to the base form
	var name: String = species_id if form_index == 0 else "%s_%d" % [species_id, form_index]
	var stream: AudioStream = _load_audio(CRY_PATH, name)
	if not stream and form_index != 0:
		stream = _load_audio(CRY_PATH, species_id)
	if not stream:
		push_warning("AudioManager: Cry not found for '%s'" % species_id)
		return

	_cry_player.stream = stream
	_cry_player.pitch_scale = pitch_scale
	_cry_player.play()


## Waits until the current cry has finished playing.
func await_cry() -> void:
	if _cry_player.playing:
		await _cry_player.finished

# ---------------------------------------------------------------------------
# Volume control
# ---------------------------------------------------------------------------

func set_master_volume(value: float) -> void:
	_vol_master = clamp(value, 0.0, 1.0)
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(_vol_master))

func set_bgm_volume(value: float) -> void:
	_vol_bgm = clamp(value, 0.0, 1.0)
	var idx: int = AudioServer.get_bus_index(BUS_BGM)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(_vol_bgm))

func set_se_volume(value: float) -> void:
	_vol_se = clamp(value, 0.0, 1.0)
	var idx: int = AudioServer.get_bus_index(BUS_SE)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(_vol_se))

func get_master_volume() -> float: return _vol_master
func get_bgm_volume()    -> float: return _vol_bgm
func get_se_volume()     -> float: return _vol_se

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Loads an AudioStream from the given base path and filename.
## Tries each supported extension and stores the result in the cache.
func _load_audio(base_path: String, name: String) -> AudioStream:
	for ext: String in SUPPORTED_EXTS:
		var full_path: String = base_path + name + "." + ext
		if _cache.has(full_path):
			return _cache[full_path]
		if ResourceLoader.exists(full_path):
			var stream: AudioStream = load(full_path) as AudioStream
			if stream:
				_cache[full_path] = stream
				return stream
	return null


## Returns the first idle AudioStreamPlayer from the SE pool.
## If all channels are busy, interrupts the one that has been playing the longest.
func _get_free_se_player() -> AudioStreamPlayer:
	for p: AudioStreamPlayer in _se_players:
		if not p.playing:
			return p
	return _se_players[0]


func _fade_bgm_to(target_db: float, duration: float) -> void:
	var tween: Tween = create_tween()
	tween.tween_property(_bgm_player, "volume_db", target_db, duration)
