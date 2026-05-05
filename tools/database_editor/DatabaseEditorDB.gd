## DatabaseEditorDB
## Static schema-level helpers for the PokeBuilder database editor.
## All DB access goes through the RPGDatabase autoload.
## Access via: const DB = preload("res://tools/database_editor/DatabaseEditorDB.gd")

const _C = preload("res://tools/database_editor/DatabaseEditorConstants.gd")

const PAGE_SIZE := 100


# ── Table / view discovery ────────────────────────────────────────────────────

## Returns all user-visible table names (excludes sqlite_* and protected tables).
static func get_all_tables() -> Array[String]:
	var rows: Array = RPGDatabase.query(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
	)
	var tables: Array[String] = []
	for row: Dictionary in rows:
		var n: String = row["name"]
		if not _C.is_protected(n):
			tables.append(n)
	return tables


## Returns all view names.
static func get_all_views() -> Array[String]:
	var rows: Array = RPGDatabase.query(
		"SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name"
	)
	var views: Array[String] = []
	for row: Dictionary in rows:
		views.append(row["name"])
	return views


## Returns names of user-created custom tables (from the registry).
static func get_custom_tables() -> Array[String]:
	if not table_exists("custom_tables"):
		return []
	var rows: Array = RPGDatabase.query("SELECT name FROM custom_tables ORDER BY name")
	var tables: Array[String] = []
	for row: Dictionary in rows:
		tables.append(row["name"])
	return tables


## True if the given table exists in sqlite_master.
static func table_exists(table_name: String) -> bool:
	return not RPGDatabase.query_one(
		"SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table_name]
	).is_empty()


# ── Schema introspection ──────────────────────────────────────────────────────

## Returns PRAGMA table_info rows: [{cid, name, type, notnull, dflt_value, pk}]
static func get_columns(table_name: String) -> Array[Dictionary]:
	var rows: Array = RPGDatabase.query("PRAGMA table_info(\"%s\")" % table_name)
	var result: Array[Dictionary] = []
	for row: Dictionary in rows:
		result.append(row)
	return result


## Returns the single-column PK name, or "" if composite or none.
static func get_pk_column(table_name: String) -> String:
	var pk_cols: Array[String] = []
	for col: Dictionary in get_columns(table_name):
		if col.get("pk", 0) >= 1:
			pk_cols.append(col["name"])
	return pk_cols[0] if pk_cols.size() == 1 else ""


## Returns effective PK column: explicit PK name, or "__rowid__" as fallback.
static func get_effective_pk(table_name: String) -> String:
	var pk := get_pk_column(table_name)
	return pk if pk != "" else "__rowid__"


## True if the table has an INTEGER PRIMARY KEY (autoincrement).
static func has_integer_pk(table_name: String) -> bool:
	for col: Dictionary in get_columns(table_name):
		if col.get("pk", 0) == 1:
			var t: String = col.get("type", "TEXT").to_upper()
			return t in ["INTEGER", "INT"]
	return false


## Returns PRAGMA foreign_key_list rows for FK-aware dropdowns.
static func get_fk_list(table_name: String) -> Array[Dictionary]:
	var rows: Array = RPGDatabase.query("PRAGMA foreign_key_list(\"%s\")" % table_name)
	var result: Array[Dictionary] = []
	for row: Dictionary in rows:
		result.append(row)
	return result


# ── Row count ─────────────────────────────────────────────────────────────────

static func get_row_count(
		table_name: String,
		search_col: String = "",
		search_val: String = "") -> int:
	var sql: String
	var params: Array = []
	if search_col != "" and search_val != "":
		sql = "SELECT COUNT(*) AS cnt FROM \"%s\" WHERE CAST(\"%s\" AS TEXT) LIKE ?" \
			  % [table_name, search_col]
		params = ["%" + search_val + "%"]
	else:
		sql = "SELECT COUNT(*) AS cnt FROM \"%s\"" % table_name
	return RPGDatabase.query_one(sql, params).get("cnt", 0)


# ── Row fetching ──────────────────────────────────────────────────────────────

## Returns a page of rows. Falls back to rowid for tables with no explicit PK.
static func get_rows(
		table_name: String,
		page: int = 0,
		search_col: String = "",
		search_val: String = "",
		sort_col: String = "",
		sort_asc: bool = true) -> Array[Dictionary]:

	var pk_explicit := get_pk_column(table_name)
	var select_prefix: String = "rowid AS __rowid__, " if pk_explicit == "" else ""

	var order_clause: String = ""
	if sort_col != "":
		order_clause = " ORDER BY \"%s\" %s" % [sort_col, "ASC" if sort_asc else "DESC"]

	var offset := page * PAGE_SIZE
	var sql: String
	var params: Array = []

	if search_col != "" and search_val != "":
		sql = "SELECT %s* FROM \"%s\" WHERE CAST(\"%s\" AS TEXT) LIKE ?%s LIMIT ? OFFSET ?" % [
			select_prefix, table_name, search_col, order_clause
		]
		params = ["%" + search_val + "%", PAGE_SIZE, offset]
	else:
		sql = "SELECT %s* FROM \"%s\"%s LIMIT ? OFFSET ?" % [
			select_prefix, table_name, order_clause
		]
		params = [PAGE_SIZE, offset]

	var rows: Array = RPGDatabase.query(sql, params)
	var result: Array[Dictionary] = []
	for row: Dictionary in rows:
		result.append(row)
	return result


## Fetches a single row by its PK value (for post-save reselection).
static func get_row_by_pk(
		table_name: String,
		pk_col: String,
		pk_val: Variant) -> Dictionary:
	if pk_col == "__rowid__":
		return RPGDatabase.query_one(
			"SELECT rowid AS __rowid__, * FROM \"%s\" WHERE rowid = ?" % table_name,
			[pk_val]
		)
	return RPGDatabase.query_one(
		"SELECT * FROM \"%s\" WHERE \"%s\" = ?" % [table_name, pk_col],
		[pk_val]
	)


# ── Row CRUD ──────────────────────────────────────────────────────────────────

## Inserts a row with the given data. Returns {ok, pk_val, error}.
static func insert_row(table_name: String, data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {"ok": false, "pk_val": null, "error": "No data provided."}

	var col_names: PackedStringArray = []
	var placeholders: PackedStringArray = []
	var values: Array = []

	for col_name: String in data:
		col_names.append("\"%s\"" % col_name)
		placeholders.append("?")
		values.append(data[col_name])

	var sql: String = "INSERT INTO \"%s\" (%s) VALUES (%s)" % [
		table_name,
		", ".join(col_names),
		", ".join(placeholders),
	]
	if not RPGDatabase.execute(sql, values):
		return {"ok": false, "pk_val": null, "error": RPGDatabase.last_error()}
	return {"ok": true, "pk_val": RPGDatabase.last_insert_id(), "error": ""}


## Updates a row identified by its PK column. data = {col_name: new_val}.
static func update_row(
		table_name: String,
		pk_col: String,
		pk_val: Variant,
		data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {"ok": true, "error": ""}

	var sets: PackedStringArray = []
	var values: Array = []
	for col: String in data:
		sets.append("\"%s\" = ?" % col)
		values.append(data[col])
	values.append(pk_val)

	var where_col: String = "rowid" if pk_col == "__rowid__" else pk_col
	var sql: String = "UPDATE \"%s\" SET %s WHERE \"%s\" = ?" % [
		table_name, ", ".join(sets), where_col
	]
	var ok := RPGDatabase.execute(sql, values)
	return {"ok": ok, "error": "" if ok else RPGDatabase.last_error()}


## Deletes rows by their PK values. Returns {ok, error}.
static func delete_rows(
		table_name: String,
		pk_col: String,
		pk_vals: Array) -> Dictionary:
	if pk_vals.is_empty():
		return {"ok": false, "error": "No rows selected."}

	var placeholders: PackedStringArray = []
	for _v: Variant in pk_vals:
		placeholders.append("?")

	var where_col: String = "rowid" if pk_col == "__rowid__" else pk_col
	var sql: String = "DELETE FROM \"%s\" WHERE \"%s\" IN (%s)" % [
		table_name, where_col, ", ".join(placeholders)
	]
	var ok := RPGDatabase.execute(sql, pk_vals)
	return {"ok": ok, "error": "" if ok else RPGDatabase.last_error()}


## Duplicates a row (copies all non-PK columns).
static func duplicate_row(
		table_name: String,
		pk_col: String,
		pk_val: Variant) -> Dictionary:
	var cols := get_columns(table_name)
	var col_names: PackedStringArray = []
	for col: Dictionary in cols:
		if col.get("pk", 0) == 0:
			col_names.append("\"%s\"" % col["name"])
	if col_names.is_empty():
		return {"ok": false, "error": "No non-PK columns to duplicate."}

	var pk_col_real: String = "rowid" if pk_col == "__rowid__" else pk_col
	var list: String = ", ".join(col_names)
	var sql: String = "INSERT INTO \"%s\" (%s) SELECT %s FROM \"%s\" WHERE \"%s\" = ?" % [
		table_name, list, list, table_name, pk_col_real
	]
	var ok := RPGDatabase.execute(sql, [pk_val])
	if not ok:
		return {"ok": false, "error": RPGDatabase.last_error()}
	return {"ok": true, "pk_val": RPGDatabase.last_insert_id(), "error": ""}


# ── DDL — Custom tables only ──────────────────────────────────────────────────

## Creates a new custom table and registers it in the custom_tables registry.
## columns: Array[Dictionary{name, type, pk, not_null, default}]
static func create_custom_table(table_name: String, columns: Array) -> Dictionary:
	if columns.is_empty():
		return {"ok": false, "error": "Table must have at least one column."}

	var defs: PackedStringArray = []
	for col: Dictionary in columns:
		var d: String = "\"%s\" %s" % [col.get("name", "col"), col.get("type", "TEXT")]
		if col.get("pk", false):
			d += " PRIMARY KEY"
		if col.get("not_null", false) and not col.get("pk", false):
			d += " NOT NULL"
		var dflt: String = str(col.get("default", "")).strip_edges()
		if dflt != "":
			d += " DEFAULT '%s'" % dflt.replace("'", "''")
		defs.append(d)

	var create_sql: String = "CREATE TABLE IF NOT EXISTS \"%s\" (%s)" % [
		table_name, ", ".join(defs)
	]
	if not RPGDatabase.execute(create_sql):
		return {"ok": false, "error": RPGDatabase.last_error()}

	RPGDatabase.execute(
		"INSERT OR IGNORE INTO custom_tables (name, created_at) VALUES (?, datetime('now'))",
		[table_name]
	)
	return {"ok": true, "error": ""}


## Adds a column to an existing table (SQLite only supports ADD COLUMN).
static func add_column(
		table_name: String,
		col_name: String,
		col_type: String,
		not_null: bool = false,
		default_val: String = "") -> Dictionary:
	var sql: String = "ALTER TABLE \"%s\" ADD COLUMN \"%s\" %s" % [table_name, col_name, col_type]
	if not_null and default_val != "":
		sql += " NOT NULL DEFAULT '%s'" % default_val.replace("'", "''")
	elif default_val != "":
		sql += " DEFAULT '%s'" % default_val.replace("'", "''")
	var ok := RPGDatabase.execute(sql)
	return {"ok": ok, "error": "" if ok else RPGDatabase.last_error()}


## Drops a custom table and removes it from the registry.
static func drop_custom_table(table_name: String) -> Dictionary:
	if not RPGDatabase.execute("DROP TABLE IF EXISTS \"%s\"" % table_name):
		return {"ok": false, "error": RPGDatabase.last_error()}
	RPGDatabase.execute("DELETE FROM custom_tables WHERE name = ?", [table_name])
	return {"ok": true, "error": ""}


## Renames a custom table and updates the registry.
static func rename_custom_table(old_name: String, new_name: String) -> Dictionary:
	if not RPGDatabase.execute("ALTER TABLE \"%s\" RENAME TO \"%s\"" % [old_name, new_name]):
		return {"ok": false, "error": RPGDatabase.last_error()}
	RPGDatabase.execute(
		"UPDATE custom_tables SET name = ? WHERE name = ?", [new_name, old_name]
	)
	return {"ok": true, "error": ""}


# ── CSV export ────────────────────────────────────────────────────────────────

## Exports an entire table to a CSV string. Returns "" on error.
static func export_to_csv(table_name: String) -> String:
	var cols := get_columns(table_name)
	if cols.is_empty():
		return ""

	var col_names: Array = []
	for col: Dictionary in cols:
		col_names.append(col["name"])

	var lines: Array = [_csv_row(col_names)]
	var rows: Array = RPGDatabase.query("SELECT * FROM \"%s\"" % table_name)
	for row: Dictionary in rows:
		var cells: Array = []
		for col_name: String in col_names:
			cells.append(_csv_cell(str(row.get(col_name, ""))))
		lines.append(_csv_row(cells))

	return "\n".join(lines)


static func _csv_row(cells: Array) -> String:
	var parts: PackedStringArray = []
	for c in cells:
		parts.append(str(c))
	return ",".join(parts)


static func _csv_cell(val: String) -> String:
	if val.contains(",") or val.contains("\"") or val.contains("\n"):
		return "\"" + val.replace("\"", "\"\"") + "\""
	return val
