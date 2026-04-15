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
var _resize_overlay: Control
var _resize_handles: Array[Control] = []

# ── State ─────────────────────────────────────────────────────────────────────
var _history: Array[String] = []
var _resize_col: int       = -1
var _resize_start_x: float = 0.0
var _resize_start_w: int   = 0
var _resize_col_count: int = -1


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

	# VSplitContainer separates the input area from the results area,
	# guaranteeing both sections have visible space.
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = SIZE_EXPAND_FILL
	vsplit.split_offset = -280
	add_child(vsplit)

	# ── Top: SQL input ────────────────────────────────────────────────────────
	var top := VBoxContainer.new()
	top.size_flags_vertical = SIZE_EXPAND_FILL
	vsplit.add_child(top)

	_sql_input = TextEdit.new()
	_sql_input.placeholder_text = "-- Enter SQL here, e.g.:\n-- SELECT * FROM pokemon_species LIMIT 10;\n-- UPDATE game_settings SET value='MyGame' WHERE key='game_title';"
	_sql_input.size_flags_vertical = SIZE_EXPAND_FILL
	top.add_child(_sql_input)

	var run_row := HBoxContainer.new()
	top.add_child(run_row)

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

	# ── Bottom: Results ───────────────────────────────────────────────────────
	var bottom := VBoxContainer.new()
	bottom.size_flags_vertical = SIZE_EXPAND_FILL
	vsplit.add_child(bottom)

	var results_lbl := Label.new()
	results_lbl.text = "Results:"
	bottom.add_child(results_lbl)

	# Wrapper so the transparent resize overlay can sit on top of the Tree.
	var tree_wrapper := Control.new()
	tree_wrapper.size_flags_vertical   = SIZE_EXPAND_FILL
	tree_wrapper.size_flags_horizontal = SIZE_EXPAND_FILL
	bottom.add_child(tree_wrapper)

	_results_tree = Tree.new()
	_results_tree.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_results_tree.hide_root             = true
	_results_tree.select_mode           = Tree.SELECT_ROW
	_results_tree.column_titles_visible = true
	tree_wrapper.add_child(_results_tree)

	_resize_overlay = Control.new()
	_resize_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_resize_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree_wrapper.add_child(_resize_overlay)

	_results_tree.resized.connect(_update_resize_handle_positions)


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

	# Strip comments and find the first SQL keyword.
	var sql_stripped: String = sql
	while sql_stripped.begins_with("--"):
		var nl: int = sql_stripped.find("\n")
		sql_stripped = sql_stripped.substr(nl + 1 if nl >= 0 else sql_stripped.length()).strip_edges()
	var first_word: String = sql_stripped.split(" ", true, 1)[0].to_upper()
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
		_rebuild_resize_handles(0)
		return

	# Build column list from first row
	var col_names: Array = rows[0].keys()
	var col_count: int   = max(1, col_names.size())
	_results_tree.columns = col_count
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

	_rebuild_resize_handles(col_count)


# ── Column resizing ───────────────────────────────────────────────────────────

const _HEADER_H := 26

func _rebuild_resize_handles(col_count: int) -> void:
	for h: Control in _resize_handles:
		h.queue_free()
	_resize_handles.clear()
	_resize_col_count = col_count
	for i: int in col_count - 1:
		var handle := Control.new()
		handle.size = Vector2(8, _HEADER_H)
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		var captured_idx := i
		handle.gui_input.connect(func(ev): _on_handle_input(ev, captured_idx))
		_resize_overlay.add_child(handle)
		_resize_handles.append(handle)
	_update_resize_handle_positions()


func _update_resize_handle_positions() -> void:
	if _resize_handles.is_empty() or _results_tree.columns == 0:
		return
	var x: float = 0.0
	for i: int in _resize_handles.size():
		x += _results_tree.get_column_width(i)
		_resize_handles[i].position = Vector2(x - 4.0, 0.0)


func _on_handle_input(event: InputEvent, col_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_resize_col     = col_idx
				_resize_start_x = mb.global_position.x
				_resize_start_w = _results_tree.get_column_width(col_idx)
			else:
				_resize_col = -1
				_update_resize_handle_positions()


func _input(event: InputEvent) -> void:
	if _resize_col < 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_resize_col = -1
			_update_resize_handle_positions()
	elif event is InputEventMouseMotion:
		var dx: int = int((event as InputEventMouseMotion).global_position.x - _resize_start_x)
		var new_w: int = maxi(40, _resize_start_w + dx)
		_results_tree.set_column_expand(_resize_col, false)
		_results_tree.set_column_custom_minimum_width(_resize_col, new_w)
		_update_resize_handle_positions()


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
