## TableListPanel
## Left sidebar for the database editor. Shows all tables grouped by category.
## Fangame creators use this to navigate between tables.
extends VBoxContainer

const _C  = preload("res://tools/database_editor/DatabaseEditorConstants.gd")
const _DB = preload("res://tools/database_editor/DatabaseEditorDB.gd")

const _CTX_MANAGE_COLUMNS := 0
const _CTX_DROP_TABLE      := 1

# ── Signals ───────────────────────────────────────────────────────────────────
## Emitted when the user clicks a table in the list.
signal table_selected(table_name: String, is_readonly: bool)
## Emitted when the user requests to create a new custom table.
signal create_table_requested()
## Emitted via right-click menu on a custom table.
signal manage_columns_requested(table_name: String)
## Emitted when the user clicks "Import CSV".
signal import_csv_requested()
## Emitted when the user clicks "Import PBS".
signal import_pbs_requested()

# ── UI references ─────────────────────────────────────────────────────────────
var _search_input: LineEdit
var _tree: Tree
var _ctx_menu: PopupMenu
var _ctx_table_name: String = ""

# ── Tree item colours ─────────────────────────────────────────────────────────
const _COL_READONLY := Color(0.75, 0.75, 0.75)
const _COL_CUSTOM   := Color(0.55, 0.85, 1.0)
const _COL_VIEW     := Color(0.8, 0.75, 1.0)


func _ready() -> void:
	_build_ui()


# ── Construction ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical   = SIZE_EXPAND_FILL
	custom_minimum_size.x = 210

	# Header row
	var header := HBoxContainer.new()
	add_child(header)

	var lbl := Label.new()
	lbl.text = "Tables"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(lbl)

	var btn_new := Button.new()
	btn_new.text = "+ New"
	btn_new.tooltip_text = "Create a new custom table"
	btn_new.pressed.connect(func(): create_table_requested.emit())
	header.add_child(btn_new)

	# Search box
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Filter tables..."
	_search_input.text_changed.connect(_on_search_changed)
	add_child(_search_input)

	# Tree
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_tree.allow_reselect = true
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_mouse_selected.connect(_on_item_mouse_selected)
	add_child(_tree)

	# Right-click context menu
	_ctx_menu = PopupMenu.new()
	_ctx_menu.add_item("Manage Columns", _CTX_MANAGE_COLUMNS)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Drop Table", _CTX_DROP_TABLE)
	_ctx_menu.id_pressed.connect(_on_ctx_menu_pressed)
	add_child(_ctx_menu)

	# Legend
	var legend := HBoxContainer.new()
	legend.custom_minimum_size.y = 20
	add_child(legend)
	_add_legend_dot(legend, _COL_CUSTOM,   "Custom")
	_add_legend_dot(legend, _COL_VIEW,     "View")
	_add_legend_dot(legend, _COL_READONLY, "Read-only")

	add_child(HSeparator.new())

	# Import buttons footer
	var import_bar := HBoxContainer.new()
	import_bar.custom_minimum_size.y = 30
	add_child(import_bar)

	var btn_csv := Button.new()
	btn_csv.text         = "↓ CSV"
	btn_csv.tooltip_text = "Import data from a CSV file"
	btn_csv.size_flags_horizontal = SIZE_EXPAND_FILL
	btn_csv.pressed.connect(func(): import_csv_requested.emit())
	import_bar.add_child(btn_csv)

	var btn_pbs := Button.new()
	btn_pbs.text         = "↓ PBS"
	btn_pbs.tooltip_text = "Import from Pokemon Essentials PBS files (requires Python)"
	btn_pbs.size_flags_horizontal = SIZE_EXPAND_FILL
	btn_pbs.pressed.connect(func(): import_pbs_requested.emit())
	import_bar.add_child(btn_pbs)


func _add_legend_dot(parent: HBoxContainer, color: Color, text: String) -> void:
	var dot := ColorRect.new()
	dot.color = color
	dot.custom_minimum_size = Vector2(8, 8)
	parent.add_child(dot)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(lbl)


# ── Public API ────────────────────────────────────────────────────────────────

## Rebuilds the tree from the current database state.
func refresh() -> void:
	_build_tree(_search_input.text.to_lower())


## Selects a table in the tree by name (used after table creation).
func select_table(table_name: String) -> void:
	var root := _tree.get_root()
	if root == null:
		return
	var cat := root.get_first_child()
	while cat != null:
		var item := cat.get_first_child()
		while item != null:
			if item.get_metadata(0).get("table", "") == table_name:
				item.select(0)
				_tree.scroll_to_item(item)
				return
			item = item.get_next()
		cat = cat.get_next()


# ── Tree building ─────────────────────────────────────────────────────────────

func _build_tree(filter: String = "") -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()

	var all_tables := _DB.get_all_tables()
	var custom_tables := _DB.get_custom_tables()
	var all_views := _DB.get_all_views()

	# Built-in categories
	for category: String in _C.TABLE_CATEGORIES:
		var table_list: Array = _C.TABLE_CATEGORIES[category]
		var visible: Array = table_list.filter(func(t: String) -> bool:
			return filter == "" or _C.get_display_name(t).to_lower().contains(filter)
		)
		if visible.is_empty():
			continue

		var cat_item := _tree.create_item(root)
		cat_item.set_text(0, category)
		cat_item.set_selectable(0, false)
		cat_item.collapsed = false

		for table_name: String in visible:
			_add_table_item(cat_item, table_name, false, false)

	# Custom tables
	var visible_custom: Array = custom_tables.filter(func(t: String) -> bool:
		return filter == "" or t.to_lower().contains(filter)
	)
	var custom_cat := _tree.create_item(root)
	custom_cat.set_text(0, "Custom Tables")
	custom_cat.set_selectable(0, false)
	custom_cat.collapsed = false

	if visible_custom.is_empty() and filter == "":
		var hint := _tree.create_item(custom_cat)
		hint.set_text(0, "  (none yet)")
		hint.set_selectable(0, false)
		hint.set_custom_color(0, Color(0.6, 0.6, 0.6))
	else:
		for table_name: String in visible_custom:
			_add_table_item(custom_cat, table_name, false, true)

	# Views
	var visible_views: Array = all_views.filter(func(t: String) -> bool:
		return filter == "" or _C.get_display_name(t).to_lower().contains(filter)
	)
	if not visible_views.is_empty():
		var view_cat := _tree.create_item(root)
		view_cat.set_text(0, "Views (read-only)")
		view_cat.set_selectable(0, false)
		view_cat.collapsed = true
		for view_name: String in visible_views:
			_add_table_item(view_cat, view_name, true, false)


func _add_table_item(
		parent: TreeItem,
		table_name: String,
		is_readonly: bool,
		is_custom: bool) -> void:
	var item := _tree.create_item(parent)
	var display := _C.get_display_name(table_name)

	# Row count badge (lazy — no query for views to keep it fast)
	if not is_readonly:
		var cnt: int = _DB.get_row_count(table_name)
		display += "  (%d)" % cnt

	item.set_text(0, display)
	item.set_metadata(0, {"table": table_name, "readonly": is_readonly})

	# Colour coding
	if is_custom:
		item.set_custom_color(0, _COL_CUSTOM)
	elif is_readonly:
		item.set_custom_color(0, _COL_VIEW)


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null or not item.is_selectable(0):
		return
	var meta: Dictionary = item.get_metadata(0)
	table_selected.emit(meta["table"] as String, meta["readonly"] as bool)


func _on_item_mouse_selected(pos: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var table_name: String = item.get_metadata(0).get("table", "")
	if not _C.is_custom(table_name):
		return
	_ctx_table_name = table_name
	_ctx_menu.popup(Rect2(get_global_mouse_position(), Vector2.ZERO))


func _on_ctx_menu_pressed(id: int) -> void:
	match id:
		_CTX_MANAGE_COLUMNS: manage_columns_requested.emit(_ctx_table_name)
		_CTX_DROP_TABLE:     _request_drop(_ctx_table_name)


func _request_drop(table_name: String) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Drop Table"
	dlg.dialog_text = "Permanently drop '%s'?\nAll data will be lost!" % table_name
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(func():
		var result := _DB.drop_custom_table(table_name)
		if result["ok"]:
			refresh()
		else:
			_show_error("Drop failed: %s" % result["error"])
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)


func _on_search_changed(text: String) -> void:
	_build_tree(text.to_lower())


func _show_error(msg: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Error"
	dlg.dialog_text = msg
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)
