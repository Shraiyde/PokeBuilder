## DatabaseEditor
## Main controller for the PokeBuilder database editor tool.
##
## HOW TO USE: Open this scene (DatabaseEditor.tscn) in Godot and press F6 to run it.
## The tool connects to the game database through the RPGDatabase autoload.
##
## Layout:
##   ┌──────── header ─────────────────────────────────────────────┐
##   │ TableListPanel │ TableDataView  OR  SqlConsolePanel          │
##   └─────────────────────────────────────────────────────────────┘
extends Control

# Preload panel scripts so we can instantiate them programmatically
const _TableListPanel      = preload("res://tools/database_editor/editors/TableListPanel.gd")
const _TableDataView       = preload("res://tools/database_editor/editors/TableDataView.gd")
const _SqlConsolePanel     = preload("res://tools/database_editor/editors/SqlConsolePanel.gd")
const _CreateTableDialog   = preload("res://tools/database_editor/editors/CreateTableDialog.gd")
const _ColumnManagerDialog = preload("res://tools/database_editor/editors/ColumnManagerDialog.gd")
const _ImportDialog        = preload("res://tools/database_editor/editors/ImportDialog.gd")
const _DB                  = preload("res://tools/database_editor/DatabaseEditorDB.gd")

# ── Child references ──────────────────────────────────────────────────────────
var _table_list: VBoxContainer
var _data_view: VBoxContainer
var _sql_console: VBoxContainer
var _create_dlg: AcceptDialog
var _column_dlg: AcceptDialog
var _import_dlg: Window
var _btn_console: Button


func _ready() -> void:
	_setup_window()
	_build_ui()
	_ensure_custom_tables_registry()

	if RPGDatabase.is_ready():
		_on_db_ready()
	else:
		RPGDatabase.database_ready.connect(_on_db_ready, CONNECT_ONE_SHOT)


func _setup_window() -> void:
	# Minimum usable size: half the base resolution.
	DisplayServer.window_set_min_size(Vector2i(960, 540))
	# Start maximised so the tool makes full use of the available screen.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_build_header(root)

	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	split.split_offset        = 230
	root.add_child(split)

	# ── Left panel: table list ─────────────────────────────────────────────
	_table_list = _TableListPanel.new()
	split.add_child(_table_list)

	# ── Right area: data view + sql console stacked ────────────────────────
	var right := Control.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.size_flags_vertical   = SIZE_EXPAND_FILL
	split.add_child(right)

	_data_view = _TableDataView.new()
	_data_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	right.add_child(_data_view)

	_sql_console = _SqlConsolePanel.new()
	_sql_console.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sql_console.hide()
	right.add_child(_sql_console)

	# ── Dialogs ────────────────────────────────────────────────────────────
	_create_dlg = _CreateTableDialog.new()
	add_child(_create_dlg)

	_column_dlg = _ColumnManagerDialog.new()
	add_child(_column_dlg)

	_import_dlg = _ImportDialog.new()
	add_child(_import_dlg)

	_wire_signals()


func _build_header(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	parent.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = 48
	panel.add_child(hbox)

	var title := Label.new()
	title.text = "PokeBuilder — Database Editor"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(title)

	_btn_console = Button.new()
	_btn_console.text        = "SQL Console"
	_btn_console.toggle_mode = true
	_btn_console.tooltip_text = "Toggle the raw SQL console"
	_btn_console.toggled.connect(_on_console_toggled)
	hbox.add_child(_btn_console)

	hbox.add_child(VSeparator.new())

	var btn_import := Button.new()
	btn_import.text         = "Import…"
	btn_import.tooltip_text = "Import data from CSV or PBS (Pokemon Essentials) files"
	btn_import.pressed.connect(_on_import_requested)
	hbox.add_child(btn_import)

	hbox.add_child(VSeparator.new())

	var btn_reload := Button.new()
	btn_reload.text        = "Reload"
	btn_reload.tooltip_text = "Refresh table list and current view"
	btn_reload.pressed.connect(_on_reload)
	hbox.add_child(btn_reload)


# ── Signal wiring ─────────────────────────────────────────────────────────────

func _wire_signals() -> void:
	# Table list → data view
	(_table_list as Object).connect("table_selected",         _on_table_selected)
	(_table_list as Object).connect("create_table_requested", _on_create_table_requested)
	(_table_list as Object).connect("manage_columns_requested", _on_manage_columns_requested)

	# Data view → main controller
	(_data_view as Object).connect("manage_columns_requested", _on_manage_columns_requested)
	(_data_view as Object).connect("table_dropped",            _on_table_dropped)

	# Create dialog → refresh sidebar
	(_create_dlg as Object).connect("table_created", _on_table_created)

	# Column dialog → reload data view schema
	(_column_dlg as Object).connect("columns_changed", _on_columns_changed)

	# Sidebar import buttons
	(_table_list as Object).connect("import_csv_requested", _on_import_csv_requested)
	(_table_list as Object).connect("import_pbs_requested", _on_import_pbs_requested)

	# Import dialog → refresh after a successful import
	(_import_dlg as Object).connect("import_completed", _on_import_completed)


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_db_ready() -> void:
	(_table_list as Object).call("refresh")


func _on_reload() -> void:
	(_table_list as Object).call("refresh")
	(_data_view  as Object).call("refresh")


func _on_console_toggled(pressed: bool) -> void:
	_data_view.visible   = not pressed
	_sql_console.visible = pressed


func _on_table_selected(table_name: String, is_readonly: bool) -> void:
	if _btn_console.button_pressed:
		_btn_console.button_pressed = false
		_data_view.visible   = true
		_sql_console.visible = false
	(_data_view as Object).call("load_table", table_name, is_readonly)


func _on_create_table_requested() -> void:
	(_create_dlg as Object).call("popup_centered_ratio", 0.5)


func _on_table_created(table_name: String) -> void:
	(_table_list as Object).call("refresh")
	(_table_list as Object).call("select_table", table_name)


func _on_manage_columns_requested(table_name: String) -> void:
	(_column_dlg as Object).call("open_for", table_name)
	(_column_dlg as Object).call("popup_centered_ratio", 0.45)


func _on_columns_changed(table_name: String) -> void:
	# If this table is currently displayed, reload its schema
	(_data_view as Object).call("reload_schema")


func _on_table_dropped(table_name: String) -> void:
	(_table_list as Object).call("refresh")
	(_data_view  as Object).call("clear")


func _on_import_requested() -> void:
	(_import_dlg as Object).call("open_on_tab", 0)

func _on_import_csv_requested() -> void:
	(_import_dlg as Object).call("open_on_tab", 0)

func _on_import_pbs_requested() -> void:
	(_import_dlg as Object).call("open_on_tab", 1)


func _on_import_completed(table_name: String) -> void:
	(_table_list as Object).call("refresh")
	if not table_name.is_empty():
		(_table_list as Object).call("select_table", table_name)


# ── Bootstrap ─────────────────────────────────────────────────────────────────

## Creates the custom_tables registry if it doesn't exist yet.
## This table tracks user-created custom tables across sessions.
func _ensure_custom_tables_registry() -> void:
	RPGDatabase.execute(
		"CREATE TABLE IF NOT EXISTS custom_tables (name TEXT PRIMARY KEY, created_at TEXT)"
	)
