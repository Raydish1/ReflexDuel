extends Control

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

const COL_WIN   := Color(0.15, 0.62, 0.25, 1)
const COL_LOSE  := Color(0.60, 0.12, 0.12, 1)
const COL_EMPTY := Color(0.28, 0.28, 0.28, 1)

var _global_list: VBoxContainer
var _player_list: VBoxContainer
var _global_status: Label
var _player_status: Label
var _current_filter: String = "all"
var _filter_btns: Array = []


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
	Net.request_recent_matches("", _current_filter)
	Net.request_recent_matches(Net.player_id, _current_filter)


func _build_ui() -> void:
	const TOP: float = 68.0
	const FILTER_H: float = 38.0

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

	# ── Filter bar ──────────────────────────────────────────────────────────
	var filter_bar := HBoxContainer.new()
	filter_bar.anchor_right = 1.0
	filter_bar.offset_top = TOP + 6.0
	filter_bar.offset_bottom = TOP + 6.0 + FILTER_H
	filter_bar.offset_left = 28.0
	filter_bar.offset_right = -28.0
	filter_bar.add_theme_constant_override("separation", 8)
	add_child(filter_bar)

	for pair in [["ALL", "all"], ["1V1", "1v1"], ["2V2", "2v2"], ["FFA", "ffa"]]:
		var fb := Button.new()
		fb.text = pair[0]
		fb.set_meta("filter_value", pair[1])
		fb.add_theme_font_override("font", FONT)
		fb.add_theme_font_size_override("font_size", 22)
		fb.custom_minimum_size = Vector2(80, FILTER_H)
		_style_filter_btn(fb, pair[1] == _current_filter)
		fb.pressed.connect(_on_filter_pressed.bind(fb))
		filter_bar.add_child(fb)
		_filter_btns.append(fb)

	# ── Two-column content area ──────────────────────────────────────────────
	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_top    = TOP + 6.0 + FILTER_H + 8.0
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


func _style_filter_btn(btn: Button, active: bool) -> void:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.22, 0.22, 0.22, 1) if active else Color(0.36, 0.36, 0.36, 0.6)
	st.corner_radius_top_left     = 4
	st.corner_radius_top_right    = 4
	st.corner_radius_bottom_right = 4
	st.corner_radius_bottom_left  = 4
	st.content_margin_left   = 10.0
	st.content_margin_right  = 10.0
	st.content_margin_top    = 4.0
	st.content_margin_bottom = 4.0
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, st)
	var col := Color(1, 1, 1, 1) if active else Color(0.75, 0.75, 0.75, 1)
	btn.add_theme_color_override("font_color", col)
	btn.add_theme_color_override("font_color_hover", Color(1, 1, 1, 1))


func _on_filter_pressed(btn: Button) -> void:
	var fv: String = btn.get_meta("filter_value")
	if fv == _current_filter:
		return
	_current_filter = fv
	for fb in _filter_btns:
		_style_filter_btn(fb, fb.get_meta("filter_value") == _current_filter)
	_set_loading()
	_request_both()


func _set_loading() -> void:
	for child in _global_list.get_children():
		child.queue_free()
	for child in _player_list.get_children():
		child.queue_free()
	_global_status.text = "Loading..."
	_global_status.visible = true
	_global_status.get_meta("scroll").visible = false
	_player_status.text = "Loading..."
	_player_status.visible = true
	_player_status.get_meta("scroll").visible = false


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

	status_lbl.set_meta("scroll", scroll)

	return [list, status_lbl, panel]


func _on_data(pid: String, matches: Array) -> void:
	if pid == "":
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
		var mtype: String = m.get("match_type", "1v1")
		if mtype == "2v2":
			list.add_child(_build_2v2_card(m))
		elif mtype == "ffa":
			list.add_child(_build_ffa_card(m))
		else:
			list.add_child(_build_1v1_card(m))


# ── 1v1 card ─────────────────────────────────────────────────────────────────

func _build_1v1_card(m: Dictionary) -> Control:
	var p1_name: String  = m.get("p1_username", "?")
	var p2_name: String  = m.get("p2_username", "?")
	var p1_score: int    = m.get("p1_score", 0)
	var p2_score: int    = m.get("p2_score", 0)
	var p1_id: String    = m.get("p1_id", "")
	var p2_id: String    = m.get("p2_id", "")
	var rounds: Array    = m.get("rounds", [])
	var is_auditory: bool = m.get("is_auditory", false)
	var mode: String     = m.get("mode", "ranked")

	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# Badge row (only shown for non-standard modes)
	if is_auditory or mode == "private":
		var badge_row := HBoxContainer.new()
		badge_row.add_theme_constant_override("separation", 6)
		if is_auditory:
			badge_row.add_child(_lbl("AUDITORY", 11, Color(0.72, 0.45, 1.0, 1)))
		if mode == "private":
			badge_row.add_child(_lbl("PRIVATE", 11, Color(0.55, 0.82, 1.0, 1)))
		vbox.add_child(badge_row)

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

	var score_lbl := _lbl("%d  —  %d" % [p1_score, p2_score], 19, Color(0.97, 0.68, 0.05, 1))
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(score_lbl)

	vbox.add_child(_separator())

	for row in [0, 1]:
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 4)

		var name_tag := _lbl(p1_name if row == 0 else p2_name, 13, Color(0.65, 0.65, 0.65, 1))
		name_tag.custom_minimum_size = Vector2(100, 0)
		name_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_tag.clip_text = true
		row_hbox.add_child(name_tag)

		var num_rounds: int = 0
		for _rd in rounds:
			num_rounds = max(num_rounds, int(_rd.get("round_num", 0)))
		for col in range(num_rounds):
			var rd = _find_round(rounds, col + 1)
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


# ── 2v2 card ─────────────────────────────────────────────────────────────────

func _build_2v2_card(m: Dictionary) -> Control:
	var t1_names: Array = m.get("t1_names", ["?", "?"])
	var t2_names: Array = m.get("t2_names", ["?", "?"])
	var t1_score: int   = m.get("t1_score", 0)
	var t2_score: int   = m.get("t2_score", 0)
	var winner_team: int = m.get("winner_team", 0)
	var rounds: Array   = m.get("rounds", [])

	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# Mode badge
	var badge := _lbl("2V2", 11, Color(0.97, 0.68, 0.05, 1))
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vbox.add_child(badge)

	# Name row: "P1 & P2"  VS  "P1 & P2"
	var name_row := HBoxContainer.new()
	var t1_lbl := _lbl("%s  &  %s" % [t1_names[0], t1_names[1]], 18, Color(1, 1, 1, 1))
	t1_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vs_lbl := _lbl("VS", 13, Color(0.55, 0.55, 0.55, 1))
	vs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs_lbl.custom_minimum_size = Vector2(32, 0)
	var t2_lbl := _lbl("%s  &  %s" % [t2_names[0], t2_names[1]], 18, Color(1, 1, 1, 1))
	t2_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t2_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_row.add_child(t1_lbl)
	name_row.add_child(vs_lbl)
	name_row.add_child(t2_lbl)
	vbox.add_child(name_row)

	var score_col: Color
	if winner_team == 0:
		score_col = Color(0.7, 0.7, 0.7, 1)
	else:
		score_col = Color(0.97, 0.68, 0.05, 1)
	var score_lbl := _lbl("%d  —  %d" % [t1_score, t2_score], 19, score_col)
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(score_lbl)

	vbox.add_child(_separator())

	# Round rows: Team 1 combined, then Team 2 combined
	for team_row in [0, 1]:
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 4)

		var tag_text := "TEAM 1" if team_row == 0 else "TEAM 2"
		var name_tag := _lbl(tag_text, 12, Color(0.65, 0.65, 0.65, 1))
		name_tag.custom_minimum_size = Vector2(60, 0)
		name_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row_hbox.add_child(name_tag)

		var num_rounds: int = 0
		for _rd in rounds:
			num_rounds = max(num_rounds, int(_rd.get("round_num", 0)))
		for col in range(num_rounds):
			var rd = _find_round(rounds, col + 1)
			var bg: Color
			var total_text: String
			var ind_text: String

			if rd == null:
				bg = COL_EMPTY
				total_text = "—"
				ind_text = ""
			else:
				var rw: int = rd.get("winner_team", 0)
				var team_num: int = team_row + 1
				var pre_arr: Array = rd.get("t1_pre_click" if team_row == 0 else "t2_pre_click", [false, false])
				var rt_arr: Array  = rd.get("t1_rt_ms"    if team_row == 0 else "t2_rt_ms",    [null, null])
				var comb = rd.get("t1_combined_ms" if team_row == 0 else "t2_combined_ms")
				var any_pre := pre_arr.any(func(v): return bool(v))

				if any_pre:
					bg = COL_LOSE
					total_text = "FAIL"
					ind_text = ""
				else:
					bg = COL_WIN if rw == team_num else (COL_EMPTY if rw == 0 else COL_LOSE)
					total_text = "%d ms" % int(float(comb)) if comb != null else "—"
					var p0 := "%d" % int(float(rt_arr[0])) if rt_arr[0] != null else "—"
					var p1 := "%d" % int(float(rt_arr[1])) if rt_arr[1] != null else "—"
					ind_text = "%s+%s" % [p0, p1]

			row_hbox.add_child(_team_round_cell(total_text, ind_text, bg))

		vbox.add_child(row_hbox)

	return card


# ── FFA card ──────────────────────────────────────────────────────────────────

func _build_ffa_card(m: Dictionary) -> Control:
	var usernames: Array  = m.get("usernames", ["?", "?", "?", "?"])
	var ids: Array        = m.get("ids", ["", "", "", ""])
	var scores: Array     = m.get("scores", [0, 0, 0, 0])
	var winner_id: String = str(m.get("winner_id", ""))
	var rounds: Array     = m.get("rounds", [])

	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# Mode badge
	var badge := _lbl("FREE FOR ALL", 11, Color(0.97, 0.68, 0.05, 1))
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vbox.add_child(badge)

	# Name row: 4 names side-by-side, winner in gold
	var name_row := HBoxContainer.new()
	for pi in range(4):
		var is_winner: bool = winner_id != "" and ids[pi] == winner_id
		var nc: Color = Color(0.97, 0.68, 0.05, 1) if is_winner else Color(1, 1, 1, 1)
		var nlbl := _lbl(usernames[pi], 16, nc)
		nlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nlbl.clip_text = true
		name_row.add_child(nlbl)
	vbox.add_child(name_row)

	# Score row: s1 - s2 - s3 - s4
	var parts := PackedStringArray()
	for s in scores:
		parts.append(str(s))
	var score_lbl := _lbl("  —  ".join(parts), 17, Color(0.75, 0.75, 0.75, 1))
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(score_lbl)

	vbox.add_child(_separator())

	# One RT row per player
	var num_rounds: int = 0
	for _rd in rounds:
		num_rounds = max(num_rounds, int(_rd.get("round_num", 0)))

	for pi in range(4):
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 4)

		var is_winner: bool = winner_id != "" and ids[pi] == winner_id
		var nc: Color = Color(0.97, 0.68, 0.05, 1) if is_winner else Color(0.65, 0.65, 0.65, 1)
		var name_tag := _lbl(usernames[pi], 12, nc)
		name_tag.custom_minimum_size = Vector2(80, 0)
		name_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_tag.clip_text = true
		row_hbox.add_child(name_tag)

		for col in range(num_rounds):
			var rd = _find_round(rounds, col + 1)
			var bg: Color
			var rt_text: String

			if rd == null:
				bg = COL_EMPTY
				rt_text = "—"
			else:
				var pre_arr: Array = rd.get("pre_click", [false, false, false, false])
				var rt_arr: Array  = rd.get("rt_ms", [null, null, null, null])
				var ws: int        = rd.get("winner_slot", -1)
				var pre: bool      = bool(pre_arr[pi]) if pi < pre_arr.size() else false
				var rt             = rt_arr[pi] if pi < rt_arr.size() else null

				if pre:
					bg = COL_LOSE
					rt_text = "FAIL"
				elif ws == pi:
					bg = COL_WIN
					rt_text = "%d ms" % int(float(rt)) if rt != null else "WIN"
				elif rt != null:
					bg = COL_LOSE
					rt_text = "%d ms" % int(float(rt))
				else:
					bg = COL_EMPTY
					rt_text = "—"

			row_hbox.add_child(_round_cell(rt_text, bg))

		vbox.add_child(row_hbox)

	return card


# ── Shared helpers ────────────────────────────────────────────────────────────

func _make_card_panel() -> PanelContainer:
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
	return card


func _separator() -> HSeparator:
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.35, 0.35, 0.35, 1)
	sep_style.content_margin_top = 1.0
	sep_style.content_margin_bottom = 1.0
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", sep_style)
	return sep


func _find_round(rounds: Array, num: int) -> Variant:
	for r in rounds:
		if r.get("round_num") == num:
			return r
	return null


func _team_round_cell(total_text: String, ind_text: String, bg: Color) -> Control:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.corner_radius_top_left     = 3
	style.corner_radius_top_right    = 3
	style.corner_radius_bottom_right = 3
	style.corner_radius_bottom_left  = 3
	style.content_margin_left   = 3.0
	style.content_margin_right  = 3.0
	style.content_margin_top    = 5.0
	style.content_margin_bottom = 5.0

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	var total_lbl := Label.new()
	total_lbl.text = total_text
	total_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total_lbl.add_theme_font_override("font", FONT)
	total_lbl.add_theme_font_size_override("font_size", 13)
	total_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.90))
	vbox.add_child(total_lbl)

	if ind_text != "":
		var ind_lbl := Label.new()
		ind_lbl.text = ind_text
		ind_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ind_lbl.add_theme_font_override("font", FONT)
		ind_lbl.add_theme_font_size_override("font_size", 10)
		ind_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.60))
		vbox.add_child(ind_lbl)

	return panel


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


func _lbl(text: String, sz: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", color)
	return l
