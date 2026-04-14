## SqlConsolePanel
## Raw SQL console for the database editor.
## Useful for advanced operations: renaming columns, complex queries,
## bulk updates, and anything the visual editor doesn't support.
extends VBoxContainer

# ── Constants ─────────────────────────────────────────────────────────────────
const MAX_HISTORY := 20

# ── UI references ─────────────────────────────────────────────────────────────
var _history_opt: OptionButton
var _sql_input: TextEdit
var _btn_run: Button
var _status_label: Label
var _results_tree: Tree

# ── State ─────────────────────────────────────────────────────────────────────
var _history: Array[String] = []


func _ready() -> void:
	_build_ui()


# ── Construction ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical   = SIZE_EXPAND_FILL

	# Toolbar
	var toolbar := HBoxContainer.new()
	toolbar.custom_minimum_size.y = 36
	add_child(toolbar)

	var title_lbl := Label.new()
	title_lbl.text = "SQL Console"
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	toolbar.add_child(title_lbl)

	var history_lbl := Label.new()
	history_lbl.text = "History:"
	toolbar.add_child(history_lbl)

	_history_opt = OptionButton.new()
	_history_opt.custom_minimum_size.x = 200
	_history_opt.add_item("(recent queries)")
	_history_opt.item_selected.connect(_on_history_selected)
	toolbar.add_child(_history_opt)

	var btn_clear := Button.new()
	btn_clear.text = "Clear"
	btn_clear.pressed.connect(func(): _sql_input.text = "")
	toolbar.add_child(btn_clear)

	# SQL input area
	_sql_input = TextEdit.new()
	_sql_input.placeholder_text = "-- Enter SQL here, e.g.:\n-- SELECT * FROM pokemon_species LIMIT 10;\n-- UPDATE game_settings SET value='MyGame' WHERE key='game_title';"
	_sql_input.custom_minimum_size.y = 120
	_sql_input.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_sql_input)

	# Run button + status
	var run_row := HBoxContainer.new()
	add_child(run_row)

	_btn_run = Button.new()
	_btn_run.text = "Run Query  (Ctrl+Enter)"
	_btn_run.pressed.connect(_run_query)
	run_row.add_child(_btn_run)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_status_label.clip_text = true
	run_row.add_child(_status_label)

	var btn_export := Button.new()
	btn_export.text = "Export results as CSV"
	btn_export.pressed.connect(_export_results)
	run_row.add_child(btn_export)

	# Results tree
	var results_lbl := Label.new()
	results_lbl.text = "Results:"
	add_child(results_lbl)

	_results_tree = Tree.new()
	_results_tree.hide_root = true
	_results_tree.select_mode = Tree.SELECT_ROW
	_results_tree.column_titles_visible = true
	_results_tree.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_results_tree)


# ── Input ─────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and key_event.keycode == KEY_ENTER and key_event.ctrl_pressed:
			_run_query()
			get_viewport().set_input_as_handled()


# ── Query execution ───────────────────────────────────────────────────────────

func _run_query() -> void:
	var sql: String = _sql_input.text.strip_edges()
	if sql == "":
		return

	_add_to_history(sql)
	_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_status_label.text = "Running..."

	var first_word: String = sql.split(" ")[0].to_upper()
	var is_select: bool = first_word in ["SELECT", "PRAGMA", "EXPLAIN", "WITH"]

	if is_select:
		var rows: Array = RPGDatabase.query(sql)
		_display_results(rows)
		_status_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		_status_label.text = "%d rows returned." % rows.size()
	else:
		var ok: bool = RPGDatabase.execute(sql)
		_results_tree.columns = 1
		_results_tree.clear()
		if ok:
			_status_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
			_status_label.text = "OK — query executed successfully."
		else:
			_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			_status_label.text = "Error: %s" % RPGDatabase.last_error()


func _display_results(rows: Array) -> void:
	_results_tree.clear()

	if rows.is_empty():
		_results_tree.columns = 1
		return

	# Build column list from first row
	var col_names: Array = rows[0].keys()
	_results_tree.columns = max(1, col_names.size())
	for i: int in col_names.size():
		_results_tree.set_column_title(i, str(col_names[i]))
		_results_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		_results_tree.set_column_custom_minimum_width(i, 80)
		_results_tree.set_column_expand(i, true)

	var root: TreeItem = _results_tree.create_item()
	for row: Dictionary in rows:
		var item: TreeItem = _results_tree.create_item(root)
		for i: int in col_names.size():
			var val: Variant = row.get(col_names[i], null)
			item.set_text(i, "" if val == null else str(val))


# ── History ───────────────────────────────────────────────────────────────────

func _add_to_history(sql: String) -> void:
	if not sql in _history:
		_history.push_front(sql)
		if _history.size() > MAX_HISTORY:
			_history.resize(MAX_HISTORY)

	_history_opt.clear()
	_history_opt.add_item("(recent queries)")
	for entry: String in _history:
		var preview: String = entry.replace("\n", " ").left(60)
		_history_opt.add_item(preview)


func _on_history_selected(idx: int) -> void:
	if idx == 0:
		return
	var entry_idx: int = idx - 1
	if entry_idx < _history.size():
		_sql_input.text = _history[entry_idx]
	_history_opt.selected = 0


# ── CSV export ────────────────────────────────────────────────────────────────

func _export_results() -> void:
	var root := _results_tree.get_root()
	if root == null:
		return

	var col_count := _results_tree.columns
	if col_count == 0:
		return

	var lines: Array[String] = []

	# Header
	var header_cells: PackedStringArray = []
	for i: int in col_count:
		header_cells.append(_results_tree.get_column_title(i))
	lines.append(",".join(header_cells))

	# Rows
	var item := root.get_first_child()
	while item != null:
		var cells: PackedStringArray = []
		for i: int in col_count:
			var val: String = item.get_text(i)
			if val.contains(",") or val.contains("\"") or val.contains("\n"):
				val = "\"" + val.replace("\"", "\"\"") + "\""
			cells.append(val)
		lines.append(",".join(cells))
		item = item.get_next()

	var csv: String = "\n".join(lines)
	DisplayServer.clipboard_set(csv)

	_status_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	_status_label.text = "Results copied to clipboard as CSV (%d rows)." % (lines.size() - 1)
