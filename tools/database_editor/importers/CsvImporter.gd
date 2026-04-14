## CsvImporter
## Parses CSV files and imports rows into a database table.
## First row is treated as column headers.
## All methods are static — no instantiation needed.

# ── Parsing ───────────────────────────────────────────────────────────────────

## Reads a CSV file from disk and returns {ok, headers, rows, error}.
static func parse_file(path: String) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return {"ok": false, "error": "Cannot open file.", "headers": [], "rows": []}
	var content := fa.get_as_text()
	fa.close()
	return parse_string(content)


## Parses a CSV string. Returns {ok, headers: Array, rows: Array[Array], error}.
static func parse_string(content: String) -> Dictionary:
	var lines: Array[String] = []
	for raw: String in content.split("\n"):
		lines.append(raw.strip_edges(false, true))  # strip trailing \r only

	# Skip leading blank lines
	while not lines.is_empty() and lines[0].strip_edges() == "":
		lines.remove_at(0)

	if lines.is_empty():
		return {"ok": false, "error": "File is empty.", "headers": [], "rows": []}

	var headers: Array = _parse_row(lines[0])
	var rows: Array    = []
	for i: int in range(1, lines.size()):
		if lines[i].strip_edges() == "":
			continue
		rows.append(_parse_row(lines[i]))

	return {"ok": true, "headers": headers, "rows": rows, "error": ""}


# ── Import ────────────────────────────────────────────────────────────────────

## Inserts rows into table_name using the provided column mapping.
## col_map: { csv_header -> db_column }  —  empty db_column = skip that column.
## mode: "INSERT OR REPLACE" | "INSERT OR IGNORE" | "INSERT"
## Returns {ok, imported, skipped, error}.
static func import_rows(
		table_name: String,
		headers: Array,
		rows: Array,
		col_map: Dictionary,
		mode: String = "INSERT OR REPLACE") -> Dictionary:

	var imported   := 0
	var skipped    := 0
	var first_err  := ""

	for row: Array in rows:
		var data: Dictionary = {}
		for i: int in headers.size():
			if i >= row.size():
				continue
			var csv_col: String = str(headers[i])
			var db_col: String  = col_map.get(csv_col, csv_col)
			if db_col.strip_edges() == "":
				continue
			data[db_col] = row[i]

		if data.is_empty():
			skipped += 1
			continue

		var cols := PackedStringArray()
		var ph   := PackedStringArray()
		var vals: Array = []
		for col: String in data:
			cols.append('"%s"' % col)
			ph.append("?")
			vals.append(data[col])

		var sql := '%s INTO "%s" (%s) VALUES (%s)' % [
			mode, table_name, ", ".join(cols), ", ".join(ph)
		]
		if RPGDatabase.execute(sql, vals):
			imported += 1
		else:
			if first_err == "":
				first_err = RPGDatabase.last_error()
			skipped += 1

	return {"ok": first_err == "", "imported": imported, "skipped": skipped, "error": first_err}


# ── Internal CSV parser ────────────────────────────────────────────────────────

static func _parse_row(line: String) -> Array:
	var cells: Array = []
	var i := 0
	var n := line.length()

	while i < n:
		if line[i] == '"':
			# Quoted field — handles "" escape inside quotes
			i += 1
			var cell := ""
			while i < n:
				if line[i] == '"':
					if i + 1 < n and line[i + 1] == '"':
						cell += '"'
						i += 2
					else:
						i += 1
						break
				else:
					cell += line[i]
					i += 1
			cells.append(cell)
			if i < n and line[i] == ',':
				i += 1
		else:
			# Unquoted field
			var start := i
			while i < n and line[i] != ',':
				i += 1
			cells.append(line.substr(start, i - start))
			if i < n:
				i += 1  # skip comma

	return cells
