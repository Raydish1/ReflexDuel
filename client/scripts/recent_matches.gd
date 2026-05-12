extends Control

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

const COL_WIN   := Color(0.15, 0.62, 0.25, 1)
const COL_LOSE  := Color(0.60, 0.12, 0.12, 1)
const COL_EMPTY := Color(0.28, 0.28, 0.28, 1)

var _global_list: VBoxContainer
var _player_list: VBoxContainer
var _global_status: Label
var _player_status: Label


func _ready() -> void:
	_build_ui()
	Net.recent_matches_data.connect(_on_data)
	if Net.connected:
		_request_both()
	else:
		Net.hello_received.connect(func(_id): _request_both(), CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	if Net.recent_matches_data.is_connected(_on_data):
		Net.recent_matches_data.disconnect(_on_data)


func _request_both() -> void:
	Net.request_recent_matches()                # global (player_id = "")
	Net.request_recent_matches(Net.player_id)   # user-specific


func _build_ui() -> void:
	const TOP: float = 68.0

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.97, 0.68, 0.05, 1)
	add_child(bg)

	var header := Polygon2D.new()
	header.color = Color(0.20, 0.20, 0.20, 1)
	header.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(1280, 0), Vector2(1280, 42), Vector2(0, 65)
	])
	add_child(header)

	var title_lbl := _lbl("RECENT MATCHES", 36, Color(1, 1, 1, 1))
	title_lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_lbl.offset_bottom = TOP
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(title_lbl)

	var back_btn := Button.new()
	back_btn.text = "< BACK"
	back_btn.flat = true
	back_btn.offset_right = 150.0
	back_btn.offset_bottom = TOP
	back_btn.add_theme_font_override("font", FONT)
	back_btn.add_theme_font_size_override("font_size", 24)
	back_btn.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75, 1))
	back_btn.add_theme_color_override("font_color_hover", Color(1, 1, 1, 1))
	var empty_style := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		back_btn.add_theme_stylebox_override(s, empty_style)
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	add_child(back_btn)

	# ── Two-column content area ────────────────────────────────────────────────
	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_top    = TOP + 12.0
	content.offset_left   = 28.0
	content.offset_right  = -28.0
	content.offset_bottom = -14.0
	content.add_theme_constant_override("separation", 16)
	add_child(content)

	# Left: global
	var left_col := _make_column("GLOBAL")
	_global_list   = left_col[0]
	_global_status = left_col[1]
	content.add_child(left_col[2])

	# Vertical divider
	var div := ColorRect.new()
	div.custom_minimum_size = Vector2(2, 0)
	div.size_flags_vertical = Control.SIZE_EXPAND_FILL
	div.color = Color(0.30, 0.30, 0.30, 0.70)
	content.add_child(div)

	# Right: user
	var right_col := _make_column("YOUR MATCHES")
	_player_list   = right_col[0]
	_player_status = right_col[1]
	content.add_child(right_col[2])


# Returns [VBoxContainer list, Label status, Control panel]
func _make_column(heading: String) -> Array:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var heading_lbl := _lbl(heading, 20, Color(0.65, 0.65, 0.65, 1))
	heading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(heading_lbl)

	var status_lbl := _lbl("Loading...", 28, Color(0.35, 0.35, 0.35, 1))
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(status_lbl)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.visible = false
	panel.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	# Store scroll ref on the status label so we can show/hide it
	status_lbl.set_meta("scroll", scroll)

	return [list, status_lbl, panel]


func _on_data(player_id: String, matches: Array) -> void:
	if player_id == "":
		_populate(_global_list, _global_status, matches)
	else:
		_populate(_player_list, _player_status, matches)


func _populate(list: VBoxContainer, status_lbl: Label, matches: Array) -> void:
	var scroll: ScrollContainer = status_lbl.get_meta("scroll")

	for child in list.get_children():
		child.queue_free()

	if matches.is_empty():
		status_lbl.text = "No matches yet"
		status_lbl.visible = true
		scroll.visible = false
		return

	status_lbl.visible = false
	scroll.visible = true
	for m in matches:
		list.add_child(_build_card(m))


func _build_card(m: Dictionary) -> Control:
	var p1_name: String = m.get("p1_username", "?")
	var p2_name: String = m.get("p2_username", "?")
	var p1_score: int   = m.get("p1_score", 0)
	var p2_score: int   = m.get("p2_score", 0)
	var p1_id: String   = m.get("p1_id", "")
	var p2_id: String   = m.get("p2_id", "")
	var rounds: Array   = m.get("rounds", [])

	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.20, 0.20, 0.20, 1)
	card_style.corner_radius_top_left     = 6
	card_style.corner_radius_top_right    = 6
	card_style.corner_radius_bottom_right = 6
	card_style.corner_radius_bottom_left  = 6
	card_style.content_margin_left   = 16.0
	card_style.content_margin_right  = 16.0
	card_style.content_margin_top    = 12.0
	card_style.content_margin_bottom = 12.0

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", card_style)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# Name row
	var name_row := HBoxContainer.new()
	var p1_lbl := _lbl(p1_name, 22, Color(1, 1, 1, 1))
	p1_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vs_lbl := _lbl("VS", 15, Color(0.55, 0.55, 0.55, 1))
	vs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs_lbl.custom_minimum_size = Vector2(36, 0)
	var p2_lbl := _lbl(p2_name, 22, Color(1, 1, 1, 1))
	p2_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p2_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_row.add_child(p1_lbl)
	name_row.add_child(vs_lbl)
	name_row.add_child(p2_lbl)
	vbox.add_child(name_row)

	# Score
	var score_lbl := _lbl("%d  —  %d" % [p1_score, p2_score], 19, Color(0.97, 0.68, 0.05, 1))
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(score_lbl)

	# Separator
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.35, 0.35, 0.35, 1)
	sep_style.content_margin_top = 1.0; sep_style.content_margin_bottom = 1.0
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Round rows — p1 then p2
	for row in [0, 1]:
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 4)

		var name_tag := _lbl(p1_name if row == 0 else p2_name, 13, Color(0.65, 0.65, 0.65, 1))
		name_tag.custom_minimum_size = Vector2(100, 0)
		name_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_tag.clip_text = true
		row_hbox.add_child(name_tag)

		for col in range(5):
			var round_num := col + 1
			var rd = _find_round(rounds, round_num)

			var bg: Color
			var rt_text: String

			if rd == null:
				bg = COL_EMPTY
				rt_text = "—"
			else:
				var pre: bool = rd.get("p1_pre_click" if row == 0 else "p2_pre_click", false)
				var rw_id = rd.get("winner_id")
				var my_id := p1_id if row == 0 else p2_id
				var rt = rd.get("p1_rt_ms" if row == 0 else "p2_rt_ms")

				if pre:
					bg = COL_LOSE
					rt_text = "FAIL"
				elif rw_id == null or rw_id == "":
					bg = COL_EMPTY
					rt_text = "—"
				elif rw_id == my_id:
					bg = COL_WIN
					rt_text = "%d ms" % int(float(rt)) if rt != null else "—"
				else:
					bg = COL_LOSE
					rt_text = "%d ms" % int(float(rt)) if rt != null else "—"

			row_hbox.add_child(_round_cell(rt_text, bg))

		vbox.add_child(row_hbox)

	return card


func _find_round(rounds: Array, num: int) -> Variant:
	for r in rounds:
		if r.get("round_num") == num:
			return r
	return null


func _round_cell(label_text: String, bg: Color) -> Control:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.corner_radius_top_left     = 3
	style.corner_radius_top_right    = 3
	style.corner_radius_bottom_right = 3
	style.corner_radius_bottom_left  = 3
	style.content_margin_left   = 3.0
	style.content_margin_right  = 3.0
	style.content_margin_top    = 8.0
	style.content_margin_bottom = 8.0

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = label_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_override("font", FONT)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.90))
	panel.add_child(lbl)

	return panel


func _lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
