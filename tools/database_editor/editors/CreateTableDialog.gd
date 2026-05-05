## CreateTableDialog
## Modal dialog for creating a new custom table.
## The creator defines the table name and its columns (name, type, PK, NOT NULL, default).
extends AcceptDialog

const _DB = preload("res://tools/database_editor/DatabaseEditorDB.gd")

# ── Signals ───────────────────────────────────────────────────────────────────
signal table_created(table_name: String)

# ── Constants ─────────────────────────────────────────────────────────────────
const COL_TYPES := ["TEXT", "INTEGER", "REAL", "BLOB"]

# ── UI references ─────────────────────────────────────────────────────────────
var _name_input: LineEdit
var _error_label: Label
var _col_rows: Array = []   # Array of HBoxContainer
var _col_container: VBoxContainer


func _ready() -> void:
	title    = "Create New Table"
	min_size = Vector2(640, 440)
	_build_ui()
	confirmed.connect(_on_confirmed)


# ── Construction ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(600, 380)
	add_child(vbox)

	# Table name
	var name_row := HBoxContainer.new()
	vbox.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = "Table name:"
	name_lbl.custom_minimum_size.x = 100
	name_row.add_child(name_lbl)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "my_custom_table"
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_input)

	# Error label
	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_error_label.hide()
	vbox.add_child(_error_label)

	vbox.add_child(HSeparator.new())

	# Column header row
	var col_header := HBoxContainer.new()
	vbox.add_child(col_header)
	_header_lbl(col_header, "Column name",   200)
	_header_lbl(col_header, "Type",          90)
	_header_lbl(col_header, "PK",            35)
	_header_lbl(col_header, "NOT NULL",      65)
	_header_lbl(col_header, "Default value", 120)
	_header_lbl(col_header, "",              30)

	# Scrollable column list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_col_container = VBoxContainer.new()
	_col_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_col_container)

	# Add initial column row
	_add_col_row("id", 0, true, false, "")

	# Add column button
	var btn_add := Button.new()
	btn_add.text = "+ Add Column"
	btn_add.pressed.connect(_add_col_row.bind("", 0, false, false, ""))
	vbox.add_child(btn_add)


func _header_lbl(parent: HBoxContainer, text: String, min_w: int) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size.x = min_w
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)


func _add_col_row(
		name_text: String,
		type_idx: int,
		is_pk: bool,
		is_nn: bool,
		default_text: String) -> void:
	var row := HBoxContainer.new()
	_col_container.add_child(row)
	_col_rows.append(row)

	var name_edit := LineEdit.new()
	name_edit.text = name_text
	name_edit.placeholder_text = "column_name"
	name_edit.custom_minimum_size.x = 200
	row.add_child(name_edit)

	var type_opt := OptionButton.new()
	type_opt.custom_minimum_size.x = 90
	for t: String in COL_TYPES:
		type_opt.add_item(t)
	type_opt.selected = type_idx
	row.add_child(type_opt)

	var pk_chk := CheckBox.new()
	pk_chk.custom_minimum_size.x = 35
	pk_chk.button_pressed = is_pk
	row.add_child(pk_chk)

	var nn_chk := CheckBox.new()
	nn_chk.custom_minimum_size.x = 65
	nn_chk.button_pressed = is_nn
	row.add_child(nn_chk)

	var dflt_edit := LineEdit.new()
	dflt_edit.text = default_text
	dflt_edit.placeholder_text = "(optional)"
	dflt_edit.custom_minimum_size.x = 120
	row.add_child(dflt_edit)

	var del_btn := Button.new()
	del_btn.text = "x"
	del_btn.custom_minimum_size.x = 30
	del_btn.pressed.connect(func():
		if _col_rows.size() > 1:
			_col_rows.erase(row)
			row.queue_free()
	)
	row.add_child(del_btn)


# ── Validation & creation ─────────────────────────────────────────────────────

func _on_confirmed() -> void:
	_error_label.hide()

	var table_name: String = _name_input.text.strip_edges()

	if table_name == "":
		_fail("Table name cannot be empty.")
		return

	if not _is_valid_identifier(table_name):
		_fail("Table name must use only letters, digits, and underscores, and start with a letter or underscore.")
		return

	if _DB.table_exists(table_name):
		_fail("A table named '%s' already exists." % table_name)
		return

	# Build column definitions
	var columns: Array = []
	var pk_count := 0
	var seen_names: Array[String] = []

	for row: HBoxContainer in _col_rows:
		var col_name: String = (row.get_child(0) as LineEdit).text.strip_edges()
		var type_sel: int    = (row.get_child(1) as OptionButton).selected
		var is_pk: bool      = (row.get_child(2) as CheckBox).button_pressed
		var is_nn: bool      = (row.get_child(3) as CheckBox).button_pressed
		var dflt: String     = (row.get_child(4) as LineEdit).text.strip_edges()

		if col_name == "":
			_fail("All columns must have a name.")
			return
		if not _is_valid_identifier(col_name):
			_fail("Column name '%s' is not valid." % col_name)
			return
		if col_name in seen_names:
			_fail("Duplicate column name: '%s'." % col_name)
			return

		seen_names.append(col_name)
		if is_pk:
			pk_count += 1

		columns.append({
			"name":     col_name,
			"type":     COL_TYPES[type_sel],
			"pk":       is_pk,
			"not_null": is_nn,
			"default":  dflt,
		})

	if columns.is_empty():
		_fail("Table must have at least one column.")
		return
	if pk_count > 1:
		_fail("Only one PRIMARY KEY column is allowed.")
		return

	# Create the table
	var result := _DB.create_custom_table(table_name, columns)
	if not result["ok"]:
		_fail("Failed to create table: %s" % result["error"])
		return

	# Reset form for next use
	_name_input.text = ""
	for row in _col_rows.duplicate():
		_col_rows.erase(row)
		row.queue_free()
	_add_col_row("id", 0, true, false, "")

	table_created.emit(table_name)


func _fail(msg: String) -> void:
	_error_label.text = msg
	_error_label.show()
	# Re-open so the user can see the error and fix it
	popup_centered_ratio(0.5)


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
