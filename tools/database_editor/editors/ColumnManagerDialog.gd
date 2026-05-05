## ColumnManagerDialog
## Dialog for managing columns on user-created custom tables.
## SQLite only supports ADD COLUMN, so removing columns is not available here.
## To restructure a table the creator must use the SQL console.
extends AcceptDialog

const _DB = preload("res://tools/database_editor/DatabaseEditorDB.gd")

# ── Signals ───────────────────────────────────────────────────────────────────
signal columns_changed(table_name: String)

# ── Constants ─────────────────────────────────────────────────────────────────
const COL_TYPES := ["TEXT", "INTEGER", "REAL", "BLOB"]

# ── State ─────────────────────────────────────────────────────────────────────
var _current_table: String = ""

# ── UI references ─────────────────────────────────────────────────────────────
var _title_label: Label
var _existing_tree: Tree
var _new_name_input: LineEdit
var _new_type_opt: OptionButton
var _new_nn_chk: CheckBox
var _new_default_input: LineEdit
var _add_error_label: Label


func _ready() -> void:
	title    = "Manage Columns"
	min_size = Vector2(540, 440)
	_build_ui()
	# Override OK button to "Close" (no automatic action on confirm)
	get_ok_button().text = "Close"


# ── Construction ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(500, 380)
	add_child(vbox)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_title_label)

	vbox.add_child(HSeparator.new())

	# Existing columns
	var sect_lbl := Label.new()
	sect_lbl.text = "Existing columns (read-only):"
	vbox.add_child(sect_lbl)

	_existing_tree = Tree.new()
	_existing_tree.hide_root = true
	_existing_tree.columns = 5
	_existing_tree.column_titles_visible = true
	_existing_tree.custom_minimum_size.y = 140
	for i: int in 5:
		_existing_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
	_existing_tree.set_column_title(0, "Name")
	_existing_tree.set_column_title(1, "Type")
	_existing_tree.set_column_title(2, "PK")
	_existing_tree.set_column_title(3, "NOT NULL")
	_existing_tree.set_column_title(4, "Default")
	_existing_tree.set_column_custom_minimum_width(0, 140)
	_existing_tree.set_column_custom_minimum_width(1, 80)
	_existing_tree.set_column_custom_minimum_width(2, 35)
	_existing_tree.set_column_custom_minimum_width(3, 65)
	_existing_tree.set_column_custom_minimum_width(4, 100)
	vbox.add_child(_existing_tree)

	vbox.add_child(HSeparator.new())

	# Add column section
	var add_lbl := Label.new()
	add_lbl.text = "Add new column:"
	vbox.add_child(add_lbl)

	var add_row := HBoxContainer.new()
	vbox.add_child(add_row)

	_new_name_input = LineEdit.new()
	_new_name_input.placeholder_text = "column_name"
	_new_name_input.custom_minimum_size.x = 150
	add_row.add_child(_new_name_input)

	_new_type_opt = OptionButton.new()
	_new_type_opt.custom_minimum_size.x = 90
	for t: String in COL_TYPES:
		_new_type_opt.add_item(t)
	add_row.add_child(_new_type_opt)

	var nn_lbl := Label.new()
	nn_lbl.text = "NOT NULL"
	add_row.add_child(nn_lbl)
	_new_nn_chk = CheckBox.new()
	add_row.add_child(_new_nn_chk)

	var dflt_lbl := Label.new()
	dflt_lbl.text = "Default:"
	add_row.add_child(dflt_lbl)

	_new_default_input = LineEdit.new()
	_new_default_input.placeholder_text = "(optional)"
	_new_default_input.custom_minimum_size.x = 110
	add_row.add_child(_new_default_input)

	var add_btn := Button.new()
	add_btn.text = "Add Column"
	add_btn.pressed.connect(_on_add_column)
	add_row.add_child(add_btn)

	# Error label
	_add_error_label = Label.new()
	_add_error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_add_error_label.hide()
	vbox.add_child(_add_error_label)

	# Limitation note
	var note := Label.new()
	note.text = "Note: SQLite does not support removing columns directly.\nUse the SQL console to rebuild a table if needed."
	note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	note.add_theme_font_size_override("font_size", 11)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(note)


# ── Public API ────────────────────────────────────────────────────────────────

func open_for(table_name: String) -> void:
	_current_table = table_name
	_title_label.text = "Columns in: %s" % table_name
	_refresh_existing_cols()
	_new_name_input.text = ""
	_new_type_opt.selected = 0
	_new_nn_chk.button_pressed = false
	_new_default_input.text = ""
	_add_error_label.hide()


# ── Internal ──────────────────────────────────────────────────────────────────

func _refresh_existing_cols() -> void:
	_existing_tree.clear()
	var root := _existing_tree.create_item()
	for col: Dictionary in _DB.get_columns(_current_table):
		var item := _existing_tree.create_item(root)
		item.set_text(0, col.get("name", ""))
		item.set_text(1, col.get("type", "TEXT"))
		item.set_text(2, "YES" if col.get("pk", 0) == 1 else "")
		item.set_text(3, "YES" if col.get("notnull", 0) == 1 else "")
		item.set_text(4, str(col.get("dflt_value", "")))
		for i: int in 5:
			item.set_selectable(i, false)


func _on_add_column() -> void:
	_add_error_label.hide()
	var col_name: String = _new_name_input.text.strip_edges()
	var col_type: String = COL_TYPES[_new_type_opt.selected]
	var not_null: bool   = _new_nn_chk.button_pressed
	var default_val: String = _new_default_input.text.strip_edges()

	if col_name == "":
		_add_error_label.text = "Column name cannot be empty."
		_add_error_label.show()
		return

	if not _is_valid_identifier(col_name):
		_add_error_label.text = "Column name '%s' is not a valid identifier." % col_name
		_add_error_label.show()
		return

	# Check for duplicate
	for col: Dictionary in _DB.get_columns(_current_table):
		if col.get("name", "") == col_name:
			_add_error_label.text = "Column '%s' already exists." % col_name
			_add_error_label.show()
			return

	if not_null and default_val == "":
		_add_error_label.text = "A NOT NULL column requires a DEFAULT value (SQLite limitation for ADD COLUMN)."
		_add_error_label.show()
		return

	var result := _DB.add_column(_current_table, col_name, col_type, not_null, default_val)
	if not result["ok"]:
		_add_error_label.text = "Error: %s" % result["error"]
		_add_error_label.show()
		return

	_new_name_input.text = ""
	_new_default_input.text = ""
	_new_nn_chk.button_pressed = false
	_refresh_existing_cols()
	columns_changed.emit(_current_table)


func _is_valid_identifier(s: String) -> bool:
	if s.is_empty():
		return false
	var first: String = s[0]
	if not (first >= "a" and first <= "z") and not (first >= "A" and first <= "Z") and first != "_":
		return false
	for c: String in s:
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
					or (c >= "0" and c <= "9") or c == "_"
		if not ok:
			return false
	return true
