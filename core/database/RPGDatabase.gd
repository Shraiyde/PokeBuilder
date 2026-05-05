## RPGDatabase
## Singleton that manages the SQLite database connection.
## It is the only access point to the database across the entire project.
##
## Requires the gdsqlite addon (2shady4u):
##   https://github.com/2shady4u/godot-sqlite
##
## Usage:
##   var rows = RPGDatabase.query("SELECT * FROM moves WHERE type_id = ?", ["FIRE"])
##   RPGDatabase.execute("UPDATE items SET price = ? WHERE id = ?", [500, "POTION"])
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when the database is open and ready for queries.
signal database_ready

## Emitted when a critical database error occurs.
signal database_error(message: String)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Main database path.
## In exported builds, user:// is used to allow write access.
const DB_PATH_DEV  := "res://data/db/pokebuilder.sqlite"
const DB_PATH_USER := "user://pokebuilder.sqlite"

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _db: SQLite            ## SQLite object from the gdsqlite addon
var _is_open: bool = false ## True when the connection is active

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_open()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		close()

# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

## Opens the database. Called automatically on _ready().
## Returns true if the connection is established successfully.
func _open() -> bool:
	if _is_open:
		return true

	# Select path depending on whether we are in the editor or an exported build.
	var path: String = DB_PATH_DEV if OS.has_feature("editor") else DB_PATH_USER

	# Copy the DB from res:// to user:// if it does not exist yet (exported builds only).
	if not OS.has_feature("editor") and not FileAccess.file_exists(DB_PATH_USER):
		var err: Error = DirAccess.copy_absolute(DB_PATH_DEV, DB_PATH_USER)
		if err != OK:
			_emit_error("Could not copy database to user://. Error: %d" % err)
			return false

	_db = SQLite.new()
	_db.path = path
	_db.verbosity_level = SQLite.QUIET

	if not _db.open_db():
		_emit_error("Could not open database at '%s'" % path)
		return false

	_is_open = true
	_apply_pragmas()
	database_ready.emit()
	return true


## Closes the database connection.
func close() -> void:
	if _is_open and _db:
		_db.close_db()
		_is_open = false


## Returns true if the database is open and ready.
func is_ready() -> bool:
	return _is_open

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Executes a SELECT query and returns results as an Array of Dictionaries.
## Use positional parameters (?) to prevent SQL injection.
##
## Example:
##   RPGDatabase.query("SELECT * FROM moves WHERE type_id = ?", ["FIRE"])
func query(sql: String, params: Array = []) -> Array:
	if not _check_open():
		return []
	if params.is_empty():
		_db.query(sql)
	else:
		_db.query_with_bindings(sql, params)
	return _db.query_result.duplicate(true)


## Executes a SELECT query and returns only the first row, or {} if no results.
func query_one(sql: String, params: Array = []) -> Dictionary:
	var results := query(sql, params)
	return results[0] if not results.is_empty() else {}


## Executes an INSERT / UPDATE / DELETE statement.
## Returns true if the operation succeeded.
##
## Example:
##   RPGDatabase.execute("INSERT INTO types (id, name) VALUES (?, ?)", ["FIRE", "Fire"])
func execute(sql: String, params: Array = []) -> bool:
	if not _check_open():
		return false
	if params.is_empty():
		return _db.query(sql)
	return _db.query_with_bindings(sql, params)


## Returns the rowid of the last INSERT performed.
func last_insert_id() -> int:
	if not _check_open():
		return -1
	return _db.last_insert_rowid


## Returns the last error message produced by the database driver.
## Useful for displaying meaningful errors in the database editor tool.
func last_error() -> String:
	if _db == null:
		return "Database not open."
	return _db.error_message


## Executes multiple statements inside a single transaction.
## Rolls back and returns false if any statement fails.
##
## Example:
##   RPGDatabase.transaction([
##     ["INSERT INTO moves (id) VALUES (?)", ["TACKLE"]],
##     ["UPDATE stats SET updated = 1 WHERE id = ?", ["TACKLE"]],
##   ])
func transaction(operations: Array) -> bool:
	if not _check_open():
		return false

	execute("BEGIN TRANSACTION")
	for op: Array in operations:
		var sql: String = op[0]
		var params: Array = op[1] if op.size() > 1 else []
		if not execute(sql, params):
			execute("ROLLBACK")
			push_error("RPGDatabase: Transaction aborted at '%s'" % sql)
			return false

	execute("COMMIT")
	return true

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Applies performance and configuration pragmas when the database is opened.
func _apply_pragmas() -> void:
	execute("PRAGMA journal_mode = WAL")    # Write-Ahead Logging: better performance for concurrent writes
	execute("PRAGMA foreign_keys = ON")     # Enable referential integrity
	execute("PRAGMA synchronous = NORMAL")  # Balance between safety and performance


func _check_open() -> bool:
	if not _is_open:
		push_error("RPGDatabase: Query attempted on a closed database.")
		return false
	return true


func _emit_error(message: String) -> void:
	push_error("RPGDatabase: " + message)
	database_error.emit(message)
