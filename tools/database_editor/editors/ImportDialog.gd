## ImportDialog
## Import data from CSV or PBS (Pokemon Essentials) files into the database.
## Open with popup_centered() after calling set_available_tables().
extends Window

signal import_completed(table_name: String)

const _DB         = preload("res://tools/database_editor/DatabaseEditorDB.gd")
const CsvImporter = preload("res://tools/database_editor/importers/CsvImporter.gd")
const PbsImporter = preload("res://tools/database_editor/importers/PbsImporter.gd")

const _DEFAULT_DB_PATH  := "res://data/db/pokebuilder.sqlite"
const _PBS_SCRIPT_PATH  := "res://tools/pbs_to_sqlite.py"
const _CSV_INSERT_MODES := ["INSERT OR REPLACE", "INSERT OR IGNORE", "INSERT"]

# ── CSV state ─────────────────────────────────────────────────────────────────
var _csv_headers: Array                = []
var _csv_rows: Array                   = []
var _csv_map_opts: Array[OptionButton] = []

# ── UI — CSV ──────────────────────────────────────────────────────────────────
var _csv_path_edit: LineEdit
var _csv_table_opt: OptionButton
var _csv_mode_opt: OptionButton
var _csv_preview_tree: Tree
var _csv_map_grid: GridContainer
var _csv_status: Label
var _csv_file_dlg: FileDialog

# ── UI — PBS single-file (GDScript importer) ──────────────────────────────────
var _pbs_single_type_opt: OptionButton
var _pbs_single_path_edit: LineEdit
var _pbs_single_status: Label
var _pbs_single_file_dlg: FileDialog

# ── UI — PBS bulk migration (Python script) ────────────────────────────────────
var _pbs_dir_edit: LineEdit
var _pbs_db_edit: LineEdit
var _pbs_py_edit: LineEdit
var _pbs_output: RichTextLabel
var _pbs_status: Label
var _pbs_dir_dlg: FileDialog

# ── Shared ────────────────────────────────────────────────────────────────────
var _tabs: TabContainer


func _ready() -> void:
	title    = "Import Data"
	min_size = Vector2i(820, 580)
	size     = Vector2i(880, 640)
	close_requested.connect(hide)
	_build_ui()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_tabs)

	_build_csv_tab(_tabs)
	_build_pbs_tab(_tabs)

	# Footer
	var sep := HSeparator.new()
	root.add_child(sep)

	var footer := HBoxContainer.new()
	footer.custom_minimum_size.y = 40
	footer.add_theme_constant_override("separation", 8)
	root.add_child(footer)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var btn_close := Button.new()
	btn_close.text = "Close"
	btn_close.custom_minimum_size.x = 90
	btn_close.pressed.connect(hide)
	footer.add_child(btn_close)

	# File dialogs
	_csv_file_dlg = _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.csv"], _on_csv_file_selected)
	add_child(_csv_file_dlg)

	_pbs_single_file_dlg = _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.txt"], _on_pbs_single_file_selected)
	add_child(_pbs_single_file_dlg)

	_pbs_dir_dlg = _make_file_dialog(FileDialog.FILE_MODE_OPEN_DIR, [], _on_pbs_dir_selected)
	add_child(_pbs_dir_dlg)


func _build_csv_tab(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "CSV Import"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# ── File path ──────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Source file"))
	var file_row := HBoxContainer.new()
	vbox.add_child(file_row)
	_csv_path_edit = _path_edit("Select a .csv file…")
	file_row.add_child(_csv_path_edit)
	var btn_browse := Button.new()
	btn_browse.text = "Browse…"
	btn_browse.pressed.connect(func(): _csv_file_dlg.popup_centered(Vector2i(700, 500)))
	file_row.add_child(btn_browse)

	# ── Options ────────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Import options"))
	var opts_grid := GridContainer.new()
	opts_grid.columns = 2
	opts_grid.add_theme_constant_override("h_separation", 12)
	vbox.add_child(opts_grid)

	opts_grid.add_child(_label("Target table:"))
	var table_row := HBoxContainer.new()
	table_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts_grid.add_child(table_row)
	_csv_table_opt = OptionButton.new()
	_csv_table_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table_row.add_child(_csv_table_opt)
	var btn_csv_tpl := Button.new()
	btn_csv_tpl.text         = "↓ Template"
	btn_csv_tpl.tooltip_text = "Download an empty CSV with the column headers of the selected table"
	btn_csv_tpl.pressed.connect(_on_csv_download_template)
	table_row.add_child(btn_csv_tpl)

	opts_grid.add_child(_label("On conflict:"))
	_csv_mode_opt = OptionButton.new()
	_csv_mode_opt.add_item("INSERT OR REPLACE  (overwrite duplicates)")
	_csv_mode_opt.add_item("INSERT OR IGNORE   (skip duplicates)")
	_csv_mode_opt.add_item("INSERT             (fail on duplicates)")
	opts_grid.add_child(_csv_mode_opt)

	# ── Preview ────────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Preview  (first 5 rows)"))
	_csv_preview_tree = Tree.new()
	_csv_preview_tree.hide_root             = true
	_csv_preview_tree.column_titles_visible = true
	_csv_preview_tree.custom_minimum_size.y = 110
	vbox.add_child(_csv_preview_tree)

	# ── Column mapping ─────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Column mapping  (CSV header → database column)"))
	var lbl_hint := Label.new()
	lbl_hint.text = "Columns are auto-matched by name. Set to  —  to skip a column."
	lbl_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl_hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(lbl_hint)

	var map_scroll := ScrollContainer.new()
	map_scroll.custom_minimum_size.y = 130
	vbox.add_child(map_scroll)
	_csv_map_grid = GridContainer.new()
	_csv_map_grid.columns = 4
	_csv_map_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_csv_map_grid.add_theme_constant_override("h_separation", 8)
	map_scroll.add_child(_csv_map_grid)

	# ── Import ─────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var import_row := HBoxContainer.new()
	vbox.add_child(import_row)
	var btn_import := Button.new()
	btn_import.text = "  Import CSV  "
	btn_import.pressed.connect(_on_csv_import)
	import_row.add_child(btn_import)
	_csv_status = _status_label()
	import_row.add_child(_csv_status)


func _build_pbs_tab(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "PBS Import"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# ── Single file import (GDScript — no Python needed) ──────────────────────
	vbox.add_child(_section_label("Import single PBS file  (no Python needed)"))

	var single_grid := GridContainer.new()
	single_grid.columns = 2
	single_grid.add_theme_constant_override("h_separation", 8)
	vbox.add_child(single_grid)

	single_grid.add_child(_label("PBS type:"))
	var type_row := HBoxContainer.new()
	type_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	single_grid.add_child(type_row)
	_pbs_single_type_opt = OptionButton.new()
	_pbs_single_type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for pbs_type: String in PbsImporter.get_supported_types():
		var table: String = PbsImporter.get_target_table(pbs_type)
		_pbs_single_type_opt.add_item("%s  →  %s" % [pbs_type, table])
		_pbs_single_type_opt.set_item_metadata(_pbs_single_type_opt.item_count - 1, pbs_type)
	type_row.add_child(_pbs_single_type_opt)
	var btn_pbs_tpl := Button.new()
	btn_pbs_tpl.text         = "↓ Template"
	btn_pbs_tpl.tooltip_text = "Download an empty PBS template for the selected type"
	btn_pbs_tpl.pressed.connect(_on_pbs_download_template)
	type_row.add_child(btn_pbs_tpl)

	single_grid.add_child(_label("PBS file (.txt):"))
	var single_file_row := HBoxContainer.new()
	single_file_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	single_grid.add_child(single_file_row)
	_pbs_single_path_edit = _path_edit("Select a PBS .txt file…")
	single_file_row.add_child(_pbs_single_path_edit)
	var btn_single_browse := Button.new()
	btn_single_browse.text = "Browse…"
	btn_single_browse.pressed.connect(func(): _pbs_single_file_dlg.popup_centered(Vector2i(700, 500)))
	single_file_row.add_child(btn_single_browse)

	var single_import_row := HBoxContainer.new()
	vbox.add_child(single_import_row)
	var btn_single_import := Button.new()
	btn_single_import.text = "  Import PBS File  "
	btn_single_import.pressed.connect(_on_pbs_single_import)
	single_import_row.add_child(btn_single_import)
	_pbs_single_status = _status_label()
	single_import_row.add_child(_pbs_single_status)

	vbox.add_child(HSeparator.new())

	# ── Bulk migration via Python script ─────────────────────────────────────
	vbox.add_child(_section_label("Bulk migration  (Python — all tables at once)"))
	var info := Label.new()
	info.text = (
		"Runs the project's pbs_to_sqlite.py script via Python.\n"
		+ "Migrates all PBS tables at once: species, moves, items, abilities, trainers,\n"
		+ "encounters, maps, evolutions, and more. Requires Python 3 installed."
	)
	info.add_theme_color_override("font_color", Color(0.70, 0.80, 0.70))
	info.add_theme_font_size_override("font_size", 11)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(info)

	vbox.add_child(HSeparator.new())

	# ── Paths grid ────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Paths"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	vbox.add_child(grid)

	# PBS directory
	grid.add_child(_label("PBS folder:"))
	_pbs_dir_edit = _path_edit("Path to Pokemon Essentials PBS folder…")
	grid.add_child(_pbs_dir_edit)
	var btn_dir := Button.new()
	btn_dir.text = "Browse…"
	btn_dir.pressed.connect(func(): _pbs_dir_dlg.popup_centered(Vector2i(700, 500)))
	grid.add_child(btn_dir)

	# DB path (auto-filled)
	grid.add_child(_label("Database (.sqlite):"))
	_pbs_db_edit = LineEdit.new()
	_pbs_db_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pbs_db_edit.text = ProjectSettings.globalize_path(_DEFAULT_DB_PATH)
	grid.add_child(_pbs_db_edit)
	var btn_db := Button.new()
	btn_db.text = "Auto"
	btn_db.tooltip_text = "Reset to the project default"
	btn_db.pressed.connect(func():
		_pbs_db_edit.text = ProjectSettings.globalize_path(_DEFAULT_DB_PATH)
	)
	grid.add_child(btn_db)

	# Python executable (detection deferred to first popup via open_on_tab)
	grid.add_child(_label("Python:"))
	_pbs_py_edit = LineEdit.new()
	_pbs_py_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_pbs_py_edit)
	var btn_py := Button.new()
	btn_py.text = "Detect"
	btn_py.tooltip_text = "Auto-detect the Python executable"
	btn_py.pressed.connect(func():
		var found := _find_python()
		_pbs_py_edit.text = found
		if found.is_empty():
			_set_status(_pbs_status, "Python not found in PATH.", false)
		else:
			_set_status(_pbs_status, "Found: %s" % found, true)
	)
	grid.add_child(btn_py)

	# ── Script path display ────────────────────────────────────────────────────
	var script_row := HBoxContainer.new()
	vbox.add_child(script_row)
	var lbl_script := Label.new()
	lbl_script.text = "Script: "
	lbl_script.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	script_row.add_child(lbl_script)
	var lbl_script_path := Label.new()
	lbl_script_path.text = ProjectSettings.globalize_path(_PBS_SCRIPT_PATH)
	lbl_script_path.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	lbl_script_path.add_theme_font_size_override("font_size", 11)
	lbl_script_path.clip_text = true
	lbl_script_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	script_row.add_child(lbl_script_path)

	vbox.add_child(HSeparator.new())

	# ── Output ────────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("Output"))
	var out_scroll := ScrollContainer.new()
	out_scroll.custom_minimum_size.y = 220
	out_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(out_scroll)
	_pbs_output = RichTextLabel.new()
	_pbs_output.bbcode_enabled        = true
	_pbs_output.fit_content           = true
	_pbs_output.scroll_active         = false
	_pbs_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pbs_output.text = "[color=gray](output will appear here after running)[/color]"
	out_scroll.add_child(_pbs_output)

	# ── Run button ─────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var run_row := HBoxContainer.new()
	vbox.add_child(run_row)
	var btn_run := Button.new()
	btn_run.text = "  Run Migration  "
	btn_run.pressed.connect(_on_pbs_run)
	run_row.add_child(btn_run)
	_pbs_status = _status_label()
	run_row.add_child(_pbs_status)


# ── CSV handlers ──────────────────────────────────────────────────────────────

func _on_csv_file_selected(path: String) -> void:
	_csv_path_edit.text = path
	_csv_status.text    = ""

	var result: Dictionary = CsvImporter.parse_file(path)
	if not result["ok"]:
		_set_status(_csv_status, result["error"], false)
		return

	_csv_headers = result["headers"]
	_csv_rows    = result["rows"]

	_build_csv_preview()
	_build_csv_mapping()
	_set_status(_csv_status,
		"Loaded %d rows, %d columns." % [_csv_rows.size(), _csv_headers.size()], true)


func _build_csv_preview() -> void:
	var col_count: int = _csv_headers.size()
	_csv_preview_tree.columns = max(1, col_count)
	for i: int in col_count:
		_csv_preview_tree.set_column_title(i, str(_csv_headers[i]))
		_csv_preview_tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)

	_csv_preview_tree.clear()
	var root: TreeItem = _csv_preview_tree.create_item()
	for ri: int in mini(5, _csv_rows.size()):
		var row: Array = _csv_rows[ri]
		var item: TreeItem = _csv_preview_tree.create_item(root)
		for ci: int in col_count:
			item.set_text(ci, str(row[ci]) if ci < row.size() else "")


func _build_csv_mapping() -> void:
	for child in _csv_map_grid.get_children():
		child.queue_free()
	_csv_map_opts.clear()

	# Get DB columns for the selected table
	var db_cols := _get_selected_csv_table_cols()

	# Header row
	for h: String in ["CSV column", "→  DB column", "CSV column", "→  DB column"]:
		var lbl := Label.new()
		lbl.text = h
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_csv_map_grid.add_child(lbl)

	for i: int in _csv_headers.size():
		var csv_col: String = str(_csv_headers[i])

		var name_lbl := Label.new()
		name_lbl.text = csv_col
		name_lbl.clip_text = true
		name_lbl.custom_minimum_size.x = 140
		_csv_map_grid.add_child(name_lbl)

		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.add_item("—  (skip)")
		for dc: String in db_cols:
			opt.add_item(dc)

		# Auto-select if names match (case-insensitive)
		var lower_csv := csv_col.to_lower()
		var auto_idx := 0
		for j: int in db_cols.size():
			if db_cols[j].to_lower() == lower_csv:
				auto_idx = j + 1
				break
		opt.selected = auto_idx
		_csv_map_grid.add_child(opt)
		_csv_map_opts.append(opt)


func _on_csv_import() -> void:
	if _csv_headers.is_empty():
		_set_status(_csv_status, "Load a CSV file first.", false)
		return

	var table: String = _csv_table_opt.get_item_text(_csv_table_opt.selected)
	if table.is_empty():
		_set_status(_csv_status, "Select a target table.", false)
		return

	# Build col_map from the mapping OptionButtons
	var db_cols := _get_selected_csv_table_cols()
	var col_map: Dictionary = {}
	for i: int in _csv_headers.size():
		var csv_col: String = str(_csv_headers[i])
		var opt: OptionButton = _csv_map_opts[i]
		var sel: int = opt.selected
		col_map[csv_col] = "" if sel == 0 else db_cols[sel - 1]

	var mode: String = _CSV_INSERT_MODES[_csv_mode_opt.selected]

	var result := CsvImporter.import_rows(table, _csv_headers, _csv_rows, col_map, mode)
	if result["ok"]:
		_set_status(_csv_status,
			"Done. %d imported, %d skipped." % [result["imported"], result["skipped"]], true)
		import_completed.emit(table)
	else:
		_set_status(_csv_status,
			"Errors: %d imported, %d failed.\n%s" % [
				result["imported"], result["skipped"], result["error"]
			], false)


func _get_selected_csv_table_cols() -> Array[String]:
	var table: String = _csv_table_opt.get_item_text(_csv_table_opt.selected)
	if table.is_empty():
		return []
	var cols: Array[String] = []
	for col: Dictionary in _DB.get_columns(table):
		cols.append(col["name"])
	return cols


# ── PBS handlers ──────────────────────────────────────────────────────────────

func _on_pbs_single_file_selected(path: String) -> void:
	_pbs_single_path_edit.text = path
	_pbs_single_status.text    = ""


func _on_pbs_single_import() -> void:
	var path: String = _pbs_single_path_edit.text.strip_edges()
	if path.is_empty():
		_set_status(_pbs_single_status, "Select a PBS file first.", false)
		return

	var idx: int    = _pbs_single_type_opt.selected
	var pbs_type: String = _pbs_single_type_opt.get_item_metadata(idx)

	_set_status(_pbs_single_status, "Importing…", true)
	var result: Dictionary = PbsImporter.import_file(path, pbs_type)

	if result["ok"]:
		_set_status(_pbs_single_status,
			"Done. %d imported, %d skipped." % [result["imported"], result["skipped"]], true)
		import_completed.emit(PbsImporter.get_target_table(pbs_type))
	else:
		_set_status(_pbs_single_status,
			"%d imported, %d failed: %s" % [result["imported"], result["skipped"], result["error"]], false)


func _on_pbs_dir_selected(dir: String) -> void:
	_pbs_dir_edit.text = dir
	_set_status(_pbs_status, "PBS folder set. Press  Run Migration  to start.", true)


func _on_pbs_run() -> void:
	var pbs_dir: String = _pbs_dir_edit.text.strip_edges()
	var db_path: String = _pbs_db_edit.text.strip_edges()
	var python: String  = _pbs_py_edit.text.strip_edges()

	if pbs_dir.is_empty():
		_set_status(_pbs_status, "Select the PBS folder first.", false)
		return
	if python.is_empty():
		_set_status(_pbs_status, "Python executable not set. Click Detect or enter the path manually.", false)
		return

	var script: String = ProjectSettings.globalize_path(_PBS_SCRIPT_PATH)

	_pbs_output.text = "[color=gray]Running…[/color]"
	_set_status(_pbs_status, "Running migration, please wait…", true)

	var out: Array[String] = []
	var exit_code: int = OS.execute(python, [script, "--pbs", pbs_dir, "--db", db_path], out, true)

	# Format output with colour
	var lines: Array[String] = []
	if not out.is_empty():
		for raw_line: String in out[0].split("\n"):
			var stripped: String = raw_line.strip_edges()
			if stripped.is_empty():
				continue
			if "ERROR" in stripped or "Error" in stripped:
				lines.append("[color=tomato]%s[/color]" % stripped.xml_escape())
			elif stripped.begins_with("✓") or stripped.begins_with("OK"):
				lines.append("[color=lime]%s[/color]" % stripped.xml_escape())
			elif stripped.begins_with("──") or stripped.begins_with("=="):
				lines.append("[color=cyan]%s[/color]" % stripped.xml_escape())
			else:
				lines.append(stripped.xml_escape())
	_pbs_output.text = "\n".join(lines) if not lines.is_empty() \
					   else "[color=gray](no output)[/color]"

	if exit_code == 0:
		_set_status(_pbs_status, "Migration completed successfully.", true)
		import_completed.emit("")   # signal sidebar to refresh all tables
	else:
		_set_status(_pbs_status, "Script exited with code %d. See output above." % exit_code, false)


# ── Public API ────────────────────────────────────────────────────────────────

## Opens the dialog on the given tab (0 = CSV, 1 = PBS).
func open_on_tab(tab_idx: int) -> void:
	_csv_table_opt.clear()
	for t: String in _DB.get_all_tables():
		_csv_table_opt.add_item(t)

	# Detect Python lazily on first open (avoids subprocess at ready time).
	if _pbs_py_edit.text.is_empty():
		_pbs_py_edit.text = _find_python()

	_tabs.current_tab = tab_idx
	popup_centered(Vector2i(920, 680))


# ── Helpers ───────────────────────────────────────────────────────────────────

## Tries to find the Python executable in PATH. Returns "" if not found.
func _find_python() -> String:
	for candidate: String in ["python3", "python", "py"]:
		var test_out: Array[String] = []
		var code: int = OS.execute(candidate, ["--version"], test_out, true)
		if code == 0:
			return candidate
	return ""


# ── Widget helpers ────────────────────────────────────────────────────────────

func _on_csv_download_template() -> void:
	var table: String = _csv_table_opt.get_item_text(_csv_table_opt.selected)
	if table.is_empty():
		_set_status(_csv_status, "Select a target table first.", false)
		return
	var cols := _DB.get_columns(table)
	if cols.is_empty():
		_set_status(_csv_status, "Table has no columns.", false)
		return
	var names: PackedStringArray = []
	for col: Dictionary in cols:
		names.append(col["name"])
	var content: String = ",".join(names) + "\n"
	_open_save_dialog("%s_template.csv" % table, "*.csv", content)


func _on_pbs_download_template() -> void:
	var idx: int        = _pbs_single_type_opt.selected
	var pbs_type: String = _pbs_single_type_opt.get_item_metadata(idx)
	var content: String  = PbsImporter.get_template(pbs_type)
	_open_save_dialog("%s_template.txt" % pbs_type, "*.txt", content)


## Opens a native save-file dialog. Writes content to the chosen path on confirm.
func _open_save_dialog(suggested_name: String, filter: String, content: String) -> void:
	var dlg := FileDialog.new()
	dlg.access            = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode         = FileDialog.FILE_MODE_SAVE_FILE
	dlg.use_native_dialog = true
	dlg.add_filter(filter)
	dlg.current_file = suggested_name
	add_child(dlg)
	dlg.file_selected.connect(func(path: String) -> void:
		var fa := FileAccess.open(path, FileAccess.WRITE)
		if fa != null:
			fa.store_string(content)
			fa.close()
		dlg.queue_free()
	)
	dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered(Vector2i(700, 500))


func _make_file_dialog(mode: FileDialog.FileMode, filters: Array, callback: Callable) -> FileDialog:
	var dlg := FileDialog.new()
	dlg.access            = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode         = mode
	dlg.use_native_dialog = true
	for f: String in filters:
		dlg.add_filter(f)
	# FILE_MODE_OPEN_DIR uses dir_selected; FILE_MODE_OPEN_FILE uses file_selected
	if mode == FileDialog.FILE_MODE_OPEN_DIR:
		dlg.dir_selected.connect(callback)
	else:
		dlg.file_selected.connect(callback)
	return dlg


func _path_edit(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.editable              = false
	le.placeholder_text      = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return le


func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	return lbl


func _label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size.x = 110
	return lbl


func _status_label() -> Label:
	var lbl := Label.new()
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode         = TextServer.AUTOWRAP_WORD_SMART
	return lbl


func _set_status(lbl: Label, msg: String, ok: bool) -> void:
	lbl.text = msg
	lbl.add_theme_color_override("font_color",
		Color(0.4, 1.0, 0.5) if ok else Color(1.0, 0.35, 0.35))
