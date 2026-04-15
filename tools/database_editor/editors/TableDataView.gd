## TableDataView
## Main data panel for the database editor.
## Shows a column-preview grid (Tree) on top and an embedded record editor at the bottom.
## Handles row browsing, sorting, pagination, searching, and inline editing.
extends VBoxContainer

const _C  = preload("res://tools/database_editor/DatabaseEditorConstants.gd")
const _DB = preload("res://tools/database_editor/DatabaseEditorDB.gd")

# ── Signals ───────────────────────────────────────────────────────────────────
## Emitted when the user requests to manage custom table columns.
signal manage_columns_requested(table_name: String)
## Emitted after a custom table is dropped (so the sidebar can refresh).
signal table_dropped(table_name: String)

# ── Constants ─────────────────────────────────────────────────────────────────
const MAX_PREVIEW_COLS := 6   # Max columns shown in the preview tree

# ── State ─────────────────────────────────────────────────────────────────────
var _current_table: String      = ""
var _is_readonly: bool          = false
var _columns: Array[Dictionary] = []
var _col_type_map: Dictionary   = {}  # col_name -> type string (upper), built in _load_schema
var _pk_col: String             = ""
var _pk_is_int: bool            = false
var _page: int                  = 0
var _page_count: int            = 1
var _total_rows: int            = 0
var _sort_col: String           = ""
var _sort_asc: bool             = true
var _search_col: String         = ""
var _search_val: String         = ""

# ── Record editor state ───────────────────────────────────────────────────────
var _is_insert_mode: bool       = false
var _editing_pk: Variant        = null
var _original_values: Dictionary = {}
var _field_inputs: Dictionary   = {}   # col_name -> Control (LineEdit | TextEdit)
var _is_dirty: bool             = false

# ── UI references ─────────────────────────────────────────────────────────────
var _lbl_table_name: Label
var _btn_add: Button
var _btn_duplicate: Button
var _btn_delete: Button
var _btn_columns: Button
var _btn_drop: Button
var _btn_export: Button
var _search_input: LineEdit
var _lbl_row_count: Label
var _data_tree: Tree
var _resize_overlay: Control        # Transparent overlay for drag handles
var _resize_handles: Array[Control] # One per column gap, positioned via get_column_width()
var _resize_col: int       = -1     # Column being dragged (-1 = none)
var _resize_start_x: float = 0.0
var _resize_start_w: int   = 0
var _resize_col_count: int = -1     # Column count handles were last built for
var _btn_prev: Button
var _btn_next: Button
var _lbl_page: Label
var _editor_panel: PanelContainer
var _editor_title: Label
var _editor_error: Label
var _btn_save: Button
var _btn_cancel: Button
var _lbl_placeholder: Label
var _editor_scroll: ScrollContainer
var _field_grid: GridContainer


func _ready() -> void:
	_build_ui()
	clear()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical   = SIZE_EXPAND_FILL
	_build_toolbar()

	# VSplitContainer lets the user drag the divider between the data grid and
	# the record editor. split_offset < 0 means "measured from the bottom".
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = SIZE_EXPAND_FILL
	vsplit.split_offset = -240
	add_child(vsplit)

	var top_area := VBoxContainer.new()
	top_area.size_flags_vertical = SIZE_EXPAND_FILL
	vsplit.add_child(top_area)

	_build_data_tree(top_area)
	_build_pagination(top_area)
	_build_record_editor(vsplit)


func _build_toolbar() -> void:
	var toolbar := HBoxContainer.new()
	toolbar.custom_minimum_size.y = 36
	add_child(toolbar)

	_lbl_table_name = Label.new()
	_lbl_table_name.text = "No table selected"
	_lbl_table_name.add_theme_font_size_override("font_size", 14)
	_lbl_table_name.size_flags_horizontal = SIZE_EXPAND_FILL
	toolbar.add_child(_lbl_table_name)

	_btn_add       = _btn("+ Add Row",    _on_add_row)
	_btn_duplicate = _btn("Duplicate",    _on_duplicate_row)
	_btn_delete    = _btn("Delete",       _on_delete_row)
	_btn_columns   = _btn("Columns",      _on_manage_columns)
	_btn_drop      = _btn("Drop Table",   _on_drop_table)
	_btn_export    = _btn("Export CSV",   _on_export_csv)

	for b: Button in [_btn_add, _btn_duplicate, _btn_delete,
					  _btn_columns, _btn_drop, _btn_export]:
		toolbar.add_child(b)

	toolbar.add_child(VSeparator.new())

	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search..."
	_search_input.custom_minimum_size.x = 180
	_search_input.text_changed.connect(_on_search_changed)
	toolbar.add_child(_search_input)

	_lbl_row_count = Label.new()
	_lbl_row_count.custom_minimum_size.x = 70
	toolbar.add_child(_lbl_row_count)

	_set_toolbar_state(false)


func _build_data_tree(parent: Container) -> void:
	# Wrapper Control so the transparent resize overlay can sit on top of the Tree.
	var wrapper := Control.new()
	wrapper.size_flags_vertical   = SIZE_EXPAND_FILL
	wrapper.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(wrapper)

	_data_tree = Tree.new()
	_data_tree.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_data_tree.select_mode           = Tree.SELECT_ROW
	_data_tree.column_titles_visible = true
	_data_tree.hide_root             = true
	_data_tree.item_selected.connect(_on_item_selected)
	_data_tree.column_title_clicked.connect(_on_column_title_clicked)
	_style_tree_headers()
	wrapper.add_child(_data_tree)

	# Overlay: covers the header area only. mouse_filter=IGNORE passes all events
	# through to the Tree below, except on the drag handles themselves.
	_resize_overlay = Control.new()
	_resize_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_resize_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(_resize_overlay)

	_data_tree.resized.connect(_update_resize_handle_positions)


const _HEADER_BG       := Color(0.15, 0.15, 0.17)
const _HEADER_BG_HOVER := Color(0.22, 0.22, 0.25)

func _style_tree_headers() -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = _HEADER_BG
	normal.set_content_margin_all(4.0)
	var hover := StyleBoxFlat.new()
	hover.bg_color = _HEADER_BG_HOVER
	hover.set_content_margin_all(4.0)
	_data_tree.add_theme_stylebox_override("title_button_normal",  normal)
	_data_tree.add_theme_stylebox_override("title_button_hover",   hover)
	_data_tree.add_theme_stylebox_override("title_button_pressed", hover)
	_data_tree.add_theme_color_override("title_button_color", Color(0.85, 0.85, 0.85))


func _build_pagination(parent: Container) -> void:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 28
	parent.add_child(bar)

	_btn_prev = _btn("< Prev", _on_prev_page)
	bar.add_child(_btn_prev)

	_lbl_page = Label.new()
	_lbl_page.size_flags_horizontal  = SIZE_EXPAND_FILL
	_lbl_page.horizontal_alignment   = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_page.text = "Page 1 / 1"
	bar.add_child(_lbl_page)

	_btn_next = _btn("Next >", _on_next_page)
	bar.add_child(_btn_next)


func _build_record_editor(parent: Container) -> void:
	_editor_panel = PanelContainer.new()
	_editor_panel.custom_minimum_size.y = 200
	parent.add_child(_editor_panel)

	var outer := VBoxContainer.new()
	_editor_panel.add_child(outer)

	# ── Header row ────────────────────────────────────────────────────────────
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 30
	outer.add_child(header)

	_editor_title = Label.new()
	_editor_title.text = "Record Editor"
	_editor_title.add_theme_font_size_override("font_size", 13)
	_editor_title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(_editor_title)

	_btn_save   = _btn("Save",   _on_save_record)
	_btn_cancel = _btn("Cancel", _on_cancel_edit)
	header.add_child(_btn_save)
	header.add_child(_btn_cancel)

	# ── Error label ───────────────────────────────────────────────────────────
	_editor_error = Label.new()
	_editor_error.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_editor_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editor_error.hide()
	outer.add_child(_editor_error)

	# ── Placeholder (shown when nothing selected) ─────────────────────────────
	_lbl_placeholder = Label.new()
	_lbl_placeholder.text = "Select a row to edit."
	_lbl_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_placeholder.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_lbl_placeholder.size_flags_vertical  = SIZE_EXPAND_FILL
	outer.add_child(_lbl_placeholder)

	# ── Scrollable form (shown when a row is selected) ────────────────────────
	_editor_scroll = ScrollContainer.new()
	_editor_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_editor_scroll.hide()
	outer.add_child(_editor_scroll)

	_field_grid = GridContainer.new()
	_field_grid.columns = 2
	_field_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_editor_scroll.add_child(_field_grid)


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


# ── Public API ────────────────────────────────────────────────────────────────

## Loads a table and displays it.
func load_table(table_name: String, is_readonly: bool = false) -> void:
	if _is_dirty:
		_confirm_discard(func(): _do_load(table_name, is_readonly))
	else:
		_do_load(table_name, is_readonly)


## Reloads the current table schema (after columns are added).
func reload_schema() -> void:
	if _current_table == "":
		return
	_load_schema()
	_load_data()


## Reloads the current page without changing the selected table.
func refresh() -> void:
	if _current_table != "":
		_load_data()


## Resets to the empty state.
func clear() -> void:
	_current_table    = ""
	_resize_col       = -1
	_resize_col_count = -1
	for h: Control in _resize_handles:
		h.queue_free()
	_resize_handles.clear()
	_data_tree.columns = 1
	_data_tree.clear()
	_lbl_table_name.text = "No table selected"
	_lbl_row_count.text  = ""
	_lbl_page.text       = "Page 1 / 1"
	_reset_editor()
	_set_toolbar_state(false)
	_lbl_placeholder.text = "Select a table from the sidebar."


# ── Internal loading ──────────────────────────────────────────────────────────

func _do_load(table_name: String, is_readonly: bool) -> void:
	_current_table    = table_name
	_is_readonly      = is_readonly
	_page      = 0
	_sort_col  = ""
	_sort_asc  = true
	_search_val = ""
	_search_input.text = ""

	_lbl_table_name.text = _C.get_display_name(table_name)
	if is_readonly:
		_lbl_table_name.text += "  [read-only]"

	_load_schema()
	_load_data()
	_set_toolbar_state(true)
	_reset_editor()

	var placeholder: String = "This table is read-only." \
		if is_readonly else "Select a row to edit."
	_lbl_placeholder.text = placeholder


func _load_schema() -> void:
	_columns   = _DB.get_columns(_current_table)
	_pk_col    = _DB.get_effective_pk(_current_table)
	_pk_is_int = _DB.has_integer_pk(_current_table)

	# Build col_type_map for O(1) type lookups in _collect_form_data.
	_col_type_map.clear()
	for col: Dictionary in _columns:
		_col_type_map[col["name"]] = col.get("type", "TEXT").to_upper()

	# Default search column: first TEXT/VARCHAR column
	_search_col = ""
	for col: Dictionary in _columns:
		var t: String = _col_type_map[col["name"]]
		if t in ["TEXT", "VARCHAR", "CHAR"]:
			_search_col = col["name"]
			break


func _load_data() -> void:
	_total_rows = _DB.get_row_count(_current_table, _search_col, _search_val)
	_page_count = max(1, int(ceil(float(_total_rows) / float(_DB.PAGE_SIZE))))
	_page       = clampi(_page, 0, _page_count - 1)

	var rows := _DB.get_rows(_current_table, _page,
							 _search_col, _search_val,
							 _sort_col, _sort_asc)
	_build_tree(rows)

	_lbl_row_count.text  = "%d rows" % _total_rows
	_lbl_page.text       = "Page %d / %d" % [_page + 1, _page_count]
	_btn_prev.disabled   = _page <= 0
	_btn_next.disabled   = _page >= _page_count - 1


func _build_tree(rows: Array[Dictionary]) -> void:
	var preview_count: int = mini(_columns.size(), MAX_PREVIEW_COLS)
	if preview_count == 0:
		_data_tree.columns = 1
		_data_tree.clear()
		return

	_data_tree.columns = preview_count
	for i: int in preview_count:
		_data_tree.set_column_expand(i, true)

	_rebuild_header(preview_count)

	_data_tree.clear()
	var root: TreeItem = _data_tree.create_item()

	for row: Dictionary in rows:
		var item: TreeItem = _data_tree.create_item(root)
		item.set_metadata(0, row)  # Full row stored for record editor
		for i: int in preview_count:
			var col_name: String = _columns[i]["name"]
			var val: Variant = row.get(col_name, null)
			item.set_text(i, "" if val == null else str(val))


func _set_toolbar_state(enabled: bool) -> void:
	var is_custom := enabled and _C.is_custom(_current_table)
	_btn_add.visible       = enabled and not _is_readonly
	_btn_duplicate.visible = enabled and not _is_readonly
	_btn_delete.visible    = enabled and not _is_readonly
	_btn_columns.visible   = is_custom
	_btn_drop.visible      = is_custom
	_btn_export.visible    = enabled


# ── Record editor ─────────────────────────────────────────────────────────────

func _show_row(row_data: Dictionary) -> void:
	_is_insert_mode    = false
	_editing_pk        = row_data.get(_pk_col, null)
	_original_values   = row_data.duplicate(true)
	_is_dirty          = false
	_editor_title.text = "Editing: %s" % str(_editing_pk)
	_editor_error.hide()
	_build_form(row_data)
	_btn_save.show()
	_btn_cancel.show()
	_lbl_placeholder.hide()
	_editor_scroll.show()


func _show_insert_form() -> void:
	_is_insert_mode    = true
	_editing_pk        = null
	_original_values   = {}
	_is_dirty          = false
	_editor_title.text = "New Row"
	_editor_error.hide()
	_build_form({})
	_btn_save.show()
	_btn_cancel.show()
	_lbl_placeholder.hide()
	_editor_scroll.show()


func _reset_editor() -> void:
	_is_insert_mode  = false
	_editing_pk      = null
	_original_values = {}
	_is_dirty        = false
	_field_inputs.clear()
	_editor_title.text = "Record Editor"
	_editor_error.hide()
	_btn_save.hide()
	_btn_cancel.hide()
	_lbl_placeholder.show()
	_editor_scroll.hide()
	for child in _field_grid.get_children():
		child.queue_free()


func _build_form(row_data: Dictionary) -> void:
	for child in _field_grid.get_children():
		child.queue_free()
	_field_inputs.clear()

	var long_hints := ["description", "text", "notes", "sql", "summary", "flavor", "script"]

	for col: Dictionary in _columns:
		var col_name: String = col["name"]
		var col_type: String = col.get("type", "TEXT").to_upper()
		var is_pk: bool      = col.get("pk", 0) == 1

		# Skip INTEGER PK in insert mode (autoincrement)
		if _is_insert_mode and is_pk and col_type in ["INTEGER", "INT"]:
			continue

		# Skip the rowid alias — it's internal
		if col_name == "__rowid__":
			continue

		# ── Label ────────────────────────────────────────────────────────────
		var lbl := Label.new()
		var lbl_text: String = col_name
		if is_pk:
			lbl_text += " (PK)"
		if col.get("notnull", 0) == 1:
			lbl_text += "*"
		lbl.text = lbl_text
		lbl.custom_minimum_size.x = 130
		lbl.clip_text = true
		lbl.tooltip_text = "type: %s" % col.get("type", "TEXT")
		_field_grid.add_child(lbl)

		# ── Input widget ──────────────────────────────────────────────────────
		var val: Variant = row_data.get(col_name, null)
		var val_str: String = "" if val == null else str(val)

		var is_long: bool = false
		for hint: String in long_hints:
			if col_name.to_lower().contains(hint):
				is_long = true
				break

		var input: Control
		if is_long:
			var te := TextEdit.new()
			te.text = val_str
			te.custom_minimum_size = Vector2(0, 55)
			te.size_flags_horizontal = SIZE_EXPAND_FILL
			te.text_changed.connect(func(): _mark_dirty(col_name))
			input = te
		else:
			var le := LineEdit.new()
			le.text = val_str
			le.size_flags_horizontal = SIZE_EXPAND_FILL
			# PK is read-only in edit mode (can't change the key)
			if not _is_insert_mode and is_pk:
				le.editable = false
				le.modulate = Color(1, 1, 1, 0.55)
			le.text_changed.connect(func(_v: String): _mark_dirty(col_name))
			input = le

		_field_inputs[col_name] = input
		_field_grid.add_child(input)


func _mark_dirty(_col: String) -> void:
	if _is_insert_mode:
		_is_dirty = true
		_editor_title.text = "New Row *"
		return

	# Compare all inputs against originals
	var dirty := false
	for col_name: String in _field_inputs:
		var inp: Control = _field_inputs[col_name]
		var cur: String = _get_input_text(inp)
		var orig: String = "" if _original_values.get(col_name, null) == null \
							  else str(_original_values[col_name])
		if cur != orig:
			dirty = true
			break

	_is_dirty = dirty
	_editor_title.text = ("Editing: %s *" if dirty else "Editing: %s") % str(_editing_pk)


func _get_input_text(inp: Control) -> String:
	if inp is LineEdit:
		return (inp as LineEdit).text
	if inp is TextEdit:
		return (inp as TextEdit).text
	return ""


func _collect_form_data() -> Dictionary:
	var data: Dictionary = {}
	for col_name: String in _field_inputs:
		var inp: Control = _field_inputs[col_name]
		var val_str: String = _get_input_text(inp)
		var col_type: String = _col_type_map.get(col_name, "TEXT")

		if col_type in ["INTEGER", "INT"]:
			data[col_name] = int(val_str) if val_str != "" else null
		elif col_type in ["REAL", "FLOAT", "DOUBLE", "NUMERIC"]:
			data[col_name] = float(val_str) if val_str != "" else null
		else:
			data[col_name] = val_str

	return data


# ── Toolbar events ────────────────────────────────────────────────────────────

func _on_add_row() -> void:
	if _is_dirty:
		_confirm_discard(_show_insert_form)
	else:
		_show_insert_form()
	# Deselect current row so the UI doesn't look ambiguous
	var sel := _data_tree.get_selected()
	if sel:
		sel.deselect(0)


func _on_duplicate_row() -> void:
	var sel := _data_tree.get_selected()
	if sel == null:
		_error_popup("Select a row to duplicate first.")
		return
	var row: Dictionary = sel.get_metadata(0)
	var pk_val: Variant = row.get(_pk_col, null)
	if pk_val == null:
		_error_popup("Cannot duplicate: row has no primary key.")
		return
	var result := _DB.duplicate_row(_current_table, _pk_col, pk_val)
	if not result["ok"]:
		_error_popup("Duplicate failed:\n%s" % result["error"])
		return
	_page = _page_count - 1  # Jump to last page where the copy appeared
	_load_data()


func _on_delete_row() -> void:
	var sel := _data_tree.get_selected()
	if sel == null:
		_error_popup("Select a row to delete first.")
		return
	var row: Dictionary = sel.get_metadata(0)
	var pk_val: Variant = row.get(_pk_col, null)

	var dlg := ConfirmationDialog.new()
	dlg.title = "Confirm Delete"
	dlg.dialog_text = "Delete this row (pk = %s)?\nThis cannot be undone." % str(pk_val)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(func():
		var result := _DB.delete_rows(_current_table, _pk_col, [pk_val])
		if not result["ok"]:
			_error_popup("Delete failed:\n%s" % result["error"])
		else:
			_reset_editor()
			_load_data()
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)


func _on_manage_columns() -> void:
	manage_columns_requested.emit(_current_table)


func _on_drop_table() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Drop Table"
	dlg.dialog_text = "Permanently drop table '%s'?\nAll data will be lost!" % _current_table
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(func():
		var result := _DB.drop_custom_table(_current_table)
		if not result["ok"]:
			_error_popup("Drop failed:\n%s" % result["error"])
		else:
			table_dropped.emit(_current_table)
			clear()
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)


func _on_export_csv() -> void:
	var csv: String = _DB.export_to_csv(_current_table)
	if csv == "":
		_error_popup("Nothing to export.")
		return
	DisplayServer.clipboard_set(csv)
	var dlg := AcceptDialog.new()
	dlg.title = "Export"
	dlg.dialog_text = "CSV copied to clipboard.\nPaste into a spreadsheet app."
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)


func _on_search_changed(val: String) -> void:
	_search_val = val
	_page = 0
	_load_data()


# ── Tree events ───────────────────────────────────────────────────────────────

func _on_item_selected() -> void:
	var item := _data_tree.get_selected()
	if item == null:
		return
	if _is_readonly:
		return
	var row: Dictionary = item.get_metadata(0)
	if _is_dirty:
		_confirm_discard(func(): _show_row(row))
	else:
		_show_row(row)


func _sort_by_column(col_name: String) -> void:
	if _sort_col == col_name:
		_sort_asc = not _sort_asc
	else:
		_sort_col = col_name
		_sort_asc = true
	_load_data()


# ── Record editor events ──────────────────────────────────────────────────────

func _on_save_record() -> void:
	_editor_error.hide()
	var data := _collect_form_data()
	var result: Dictionary

	if _is_insert_mode:
		result = _DB.insert_row(_current_table, data)
	else:
		# Only send fields that actually changed
		var changes: Dictionary = {}
		for col_name: String in data:
			var new_str: String = "" if data[col_name] == null else str(data[col_name])
			var old_str: String = "" if _original_values.get(col_name, null) == null \
									  else str(_original_values[col_name])
			if new_str != old_str:
				changes[col_name] = data[col_name]
		result = _DB.update_row(_current_table, _pk_col, _editing_pk, changes)

	if not result["ok"]:
		_editor_error.text = "Error: %s" % result.get("error", "Unknown error.")
		_editor_error.show()
		return

	_is_dirty = false
	# Determine the PK of the saved row so we can re-select it after refresh.
	# For INTEGER PK (autoincrement): use last_insert_id from the result.
	# For TEXT PK: the value came from the form (data[_pk_col]).
	var saved_pk: Variant
	if _is_insert_mode:
		saved_pk = data.get(_pk_col, result.get("pk_val"))
	else:
		saved_pk = _editing_pk
	_is_insert_mode = false

	_load_data()

	# Attempt to re-select the saved row
	if saved_pk != null:
		_select_by_pk(saved_pk)


func _on_cancel_edit() -> void:
	if _is_dirty:
		_confirm_discard(_reset_editor)
	else:
		_reset_editor()


# ── Pagination events ─────────────────────────────────────────────────────────

func _on_prev_page() -> void:
	if _page > 0:
		_page -= 1
		_load_data()


func _on_next_page() -> void:
	if _page < _page_count - 1:
		_page += 1
		_load_data()


# ── Column header ─────────────────────────────────────────────────────────────

## Updates the Tree's built-in column titles with the current sort indicator,
## and (re)builds the transparent resize handles if the column count changed.
func _rebuild_header(col_count: int) -> void:
	for i: int in col_count:
		var col_name: String = _columns[i]["name"]
		var title: String    = col_name
		if col_name == _sort_col:
			title += "  " + ("▲" if _sort_asc else "▼")
		_data_tree.set_column_title(i, title)
		_data_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)

	if col_count != _resize_col_count:
		_resize_col_count = col_count
		_rebuild_resize_handles(col_count)
	else:
		_update_resize_handle_positions()


func _on_column_title_clicked(column: int, _mouse_button: int) -> void:
	if column < _columns.size():
		_sort_by_column(_columns[column]["name"])


# ── Column resize ─────────────────────────────────────────────────────────────

const _HEADER_H := 26  # Approximate Tree header row height in pixels.

## Creates one drag handle per column gap, positioned over the header area.
func _rebuild_resize_handles(col_count: int) -> void:
	for h: Control in _resize_handles:
		h.queue_free()
	_resize_handles.clear()

	for i: int in col_count - 1:
		var handle := Control.new()
		handle.size                       = Vector2(8, _HEADER_H)
		handle.mouse_filter               = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		var captured_idx := i
		handle.gui_input.connect(func(ev: InputEvent) -> void:
			_on_handle_input(ev, captured_idx))
		_resize_overlay.add_child(handle)
		_resize_handles.append(handle)

	_update_resize_handle_positions()


## Repositions handles to sit on each column boundary using the Tree's own widths.
func _update_resize_handle_positions() -> void:
	if _resize_handles.is_empty() or _data_tree.columns == 0:
		return
	var x: float = 0.0
	for i: int in _resize_handles.size():
		x += _data_tree.get_column_width(i)
		_resize_handles[i].position = Vector2(x - 4.0, 0.0)


func _on_handle_input(event: InputEvent, col_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_resize_col     = col_idx
			_resize_start_x = mb.global_position.x
			_resize_start_w = _data_tree.get_column_width(col_idx)


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
		_data_tree.set_column_expand(_resize_col, false)
		_data_tree.set_column_custom_minimum_width(_resize_col, new_w)
		_update_resize_handle_positions()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _select_by_pk(pk_val: Variant) -> void:
	var root := _data_tree.get_root()
	if root == null:
		return
	var item := root.get_first_child()
	while item != null:
		var row: Dictionary = item.get_metadata(0)
		if str(row.get(_pk_col, "")) == str(pk_val):
			item.select(0)
			_data_tree.scroll_to_item(item)
			_show_row(row)
			return
		item = item.get_next()


func _confirm_discard(callback: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Unsaved Changes"
	dlg.dialog_text = "You have unsaved changes.\nDiscard them?"
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(func():
		_is_dirty = false
		callback.call()
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)


func _error_popup(msg: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Error"
	dlg.dialog_text = msg
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)
