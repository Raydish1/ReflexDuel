extends Control
# scripts/game_2v2.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

enum State { WAITING, STIMULUS, AFTER_CLICK, READY_UP, MATCH_END }
var state: State = State.WAITING

const TOP: float = 72.0
const MID_Y: float = TOP + (720.0 - TOP) / 2.0  # 396.0

var t_stimulus_us: int = 0
var my_team: int = 1   # 1 or 2
var my_slot: int = 0   # 0 or 1
var team1_names: Array = ["?", "?"]
var team2_names: Array = ["?", "?"]
var t1_score: int = 0
var t2_score: int = 0
var _readied: bool = false
var _countdown: int = 5
var my_box_rect: Rect2

const COL_WAITING := Color(0.55, 0.12, 0.12)
const COL_GO      := Color(0.18, 0.82, 0.28)
const COL_WIN     := Color(0.18, 0.72, 0.28)
const COL_LOSE    := Color(0.62, 0.13, 0.13)
const COL_SENT    := Color(0.18, 0.55, 0.72)

# boxes[ti][si] — ti=0 for team1, ti=1 for team2; si=0 or 1
var boxes: Array = [[], []]
var rt_labels: Array = [[], []]
var name_labels: Array = [[], []]

var t1_score_lbl: Label
var t2_score_lbl: Label
var t1_combined_lbl: Label
var t2_combined_lbl: Label
var ready_lbl: Label
var countdown_lbl: Label
var intro_overlay: ColorRect
var intro_lbl: Label
var end_overlay: Control
var _end_left_dim: ColorRect
var _end_right_dim: ColorRect
var _end_left_lbl: Label
var _end_right_lbl: Label

var _layout_applied: bool = false

# Anti-cheat instrumentation (same as 1v1)
var _mouse_down_us: int = 0
var _last_mouse_move_us: int = 0
var _mouse_pos_history: Array = []
var _window_focused_at_stimulus: bool = true
var is_auditory: bool = false
var _beep_player: AudioStreamPlayer = null

@onready var countdown_timer: Timer = $CountdownTimer
@onready var end_timer: Timer = $EndTimer


func _ready() -> void:
	_build_ui()

	countdown_timer.timeout.connect(_on_countdown_tick)
	end_timer.timeout.connect(_go_to_team_results)

	Net.team_match_start.connect(_on_team_match_start)
	Net.round_prepare.connect(_on_round_prepare)
	Net.stimulus.connect(_on_stimulus)
	Net.team_round_result.connect(_on_team_round_result)
	Net.team_match_end.connect(_on_team_match_end)
	Net.team_player_clicked.connect(_on_team_player_clicked)

	# Consume buffered team_match_start
	var bstart := Net.last_team_match_start
	Net.last_team_match_start = {}
	if not bstart.is_empty():
		_on_team_match_start(bstart)

	# Consume buffered round_prepare
	var brp := Net.last_round_prepare
	Net.last_round_prepare = -1
	if brp >= 1:
		_on_round_prepare(brp)


func _exit_tree() -> void:
	for pair in [
		[Net.team_match_start,    _on_team_match_start],
		[Net.round_prepare,       _on_round_prepare],
		[Net.stimulus,            _on_stimulus],
		[Net.team_round_result,   _on_team_round_result],
		[Net.team_match_end,      _on_team_match_end],
		[Net.team_player_clicked, _on_team_player_clicked],
	]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


# ── Layout ────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.97, 0.68, 0.05)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.anchor_right = 1.0
	top_bar.offset_bottom = TOP
	top_bar.color = Color(0.20, 0.20, 0.20)
	add_child(top_bar)

	# Vertical center divider
	var vdiv := ColorRect.new()
	vdiv.anchor_left = 0.5;  vdiv.anchor_right  = 0.5
	vdiv.anchor_top  = 0.0;  vdiv.anchor_bottom = 1.0
	vdiv.offset_left = -2;   vdiv.offset_right  = 2
	vdiv.offset_top  = TOP
	vdiv.color = Color(0.10, 0.10, 0.10, 1)
	add_child(vdiv)

	# Horizontal dividers (one per half, at MID_Y)
	for side in [0, 1]:
		var hdiv := ColorRect.new()
		hdiv.anchor_left   = 0.0 if side == 0 else 0.5
		hdiv.anchor_right  = 0.5 if side == 0 else 1.0
		hdiv.anchor_top    = 0.0
		hdiv.anchor_bottom = 0.0
		hdiv.offset_left   = 7
		hdiv.offset_right  = -7
		hdiv.offset_top    = MID_Y - 2
		hdiv.offset_bottom = MID_Y + 2
		hdiv.color = Color(0.10, 0.10, 0.10, 1)
		add_child(hdiv)

	# 4 reaction boxes: boxes[team_idx][slot_idx]
	# team_idx 0 = team1 (left), team_idx 1 = team2 (right)
	# slot_idx 0 = top, slot_idx 1 = bottom
	for ti in range(2):
		boxes[ti] = []
		rt_labels[ti] = []
		name_labels[ti] = []
		for si in range(2):
			var box := ColorRect.new()
			box.anchor_left   = 0.0 if ti == 0 else 0.5
			box.anchor_right  = 0.5 if ti == 0 else 1.0
			box.anchor_top    = 0.0
			box.anchor_bottom = 0.0 if si == 0 else 1.0
			box.offset_left   = 7
			box.offset_right  = -7
			box.offset_top    = TOP + 7 if si == 0 else MID_Y + 4
			box.offset_bottom = MID_Y - 4 if si == 0 else -7
			box.color = COL_WAITING
			add_child(box)
			boxes[ti].append(box)

			# Player name (top of box)
			var nlbl := _lbl(20)
			nlbl.anchor_left   = 0.0 if ti == 0 else 0.5
			nlbl.anchor_right  = 0.5 if ti == 0 else 1.0
			nlbl.anchor_top    = 0.0
			nlbl.anchor_bottom = 0.0
			nlbl.offset_left   = 14
			nlbl.offset_right  = -14
			nlbl.offset_top    = (TOP + 14) if si == 0 else (MID_Y + 10)
			nlbl.offset_bottom = nlbl.offset_top + 30
			nlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			nlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(nlbl)
			name_labels[ti].append(nlbl)

			# RT label (bottom of box)
			var rtlbl := _lbl(22)
			rtlbl.anchor_left   = 0.0 if ti == 0 else 0.5
			rtlbl.anchor_right  = 0.5 if ti == 0 else 1.0
			rtlbl.anchor_top    = 0.0 if si == 0 else 1.0
			rtlbl.anchor_bottom = 0.0 if si == 0 else 1.0
			rtlbl.offset_left   = 14
			rtlbl.offset_right  = -14
			rtlbl.offset_top    = (MID_Y - 68) if si == 0 else -68
			rtlbl.offset_bottom = (MID_Y - 14) if si == 0 else -14
			rtlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rtlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(rtlbl)
			rt_labels[ti].append(rtlbl)

	# Top bar: team score area
	t1_score_lbl = _lbl(40)
	t1_score_lbl.anchor_right = 0.5
	t1_score_lbl.offset_top = 0;  t1_score_lbl.offset_bottom = TOP
	t1_score_lbl.offset_right = -28
	t1_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	t1_score_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	add_child(t1_score_lbl)

	var vs_lbl := _lbl(22)
	vs_lbl.anchor_left = 0.5;  vs_lbl.anchor_right = 0.5
	vs_lbl.offset_left = -28;  vs_lbl.offset_right = 28
	vs_lbl.offset_top = 0;     vs_lbl.offset_bottom = TOP
	vs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	vs_lbl.text = "—"
	add_child(vs_lbl)

	t2_score_lbl = _lbl(40)
	t2_score_lbl.anchor_left = 0.5;  t2_score_lbl.anchor_right = 1.0
	t2_score_lbl.offset_top = 0;     t2_score_lbl.offset_bottom = TOP
	t2_score_lbl.offset_left = 28
	t2_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	t2_score_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	add_child(t2_score_lbl)

	# Team name labels in top bar (left and right of scores)
	var t1_names_lbl := _lbl(17)
	t1_names_lbl.anchor_right = 0.42
	t1_names_lbl.offset_top = 0;   t1_names_lbl.offset_bottom = TOP
	t1_names_lbl.offset_left = 14
	t1_names_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	t1_names_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	t1_names_lbl.set_meta("team_header", 1)
	add_child(t1_names_lbl)

	var t2_names_lbl := _lbl(17)
	t2_names_lbl.anchor_left = 0.58;  t2_names_lbl.anchor_right = 1.0
	t2_names_lbl.offset_top = 0;      t2_names_lbl.offset_bottom = TOP
	t2_names_lbl.offset_right = -14
	t2_names_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	t2_names_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	t2_names_lbl.set_meta("team_header", 2)
	add_child(t2_names_lbl)

	# Combined team RT labels at midline
	t1_combined_lbl = _lbl(24)
	t1_combined_lbl.anchor_right = 0.5
	t1_combined_lbl.anchor_top    = 0.0
	t1_combined_lbl.anchor_bottom = 0.0
	t1_combined_lbl.offset_left   = 14
	t1_combined_lbl.offset_right  = -14
	t1_combined_lbl.offset_top    = MID_Y - 28
	t1_combined_lbl.offset_bottom = MID_Y + 4
	t1_combined_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t1_combined_lbl.modulate = Color(1, 1, 1, 0.92)
	t1_combined_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t1_combined_lbl.visible = false
	add_child(t1_combined_lbl)

	t2_combined_lbl = _lbl(24)
	t2_combined_lbl.anchor_left  = 0.5
	t2_combined_lbl.anchor_right = 1.0
	t2_combined_lbl.anchor_top    = 0.0
	t2_combined_lbl.anchor_bottom = 0.0
	t2_combined_lbl.offset_left   = 14
	t2_combined_lbl.offset_right  = -14
	t2_combined_lbl.offset_top    = MID_Y - 28
	t2_combined_lbl.offset_bottom = MID_Y + 4
	t2_combined_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t2_combined_lbl.modulate = Color(1, 1, 1, 0.92)
	t2_combined_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t2_combined_lbl.visible = false
	add_child(t2_combined_lbl)

	# Ready prompt — starts at default position (team1, slot0); repositioned in _on_team_match_start
	ready_lbl = _lbl(20)
	ready_lbl.anchor_right = 0.5
	ready_lbl.anchor_top = 0.325;  ready_lbl.anchor_bottom = 0.325  # top-left box center
	ready_lbl.offset_top = 0;      ready_lbl.offset_bottom = 30
	ready_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_lbl.modulate = Color(0.85, 0.85, 0.85)
	ready_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ready_lbl.visible = false
	add_child(ready_lbl)

	# Countdown — always full-width centered so all players can see it
	countdown_lbl = _lbl(80)
	countdown_lbl.anchor_left = 0.0;   countdown_lbl.anchor_right = 1.0
	countdown_lbl.anchor_top = 0.0;    countdown_lbl.anchor_bottom = 0.0
	countdown_lbl.offset_top = MID_Y - 48;  countdown_lbl.offset_bottom = MID_Y + 48
	countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_lbl.modulate = Color(1, 1, 1, 1.0)
	countdown_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_lbl.visible = false
	add_child(countdown_lbl)

	# Intro overlay
	intro_overlay = ColorRect.new()
	intro_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	intro_overlay.color = Color(0.12, 0.12, 0.12, 0.95)
	intro_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	intro_overlay.visible = false
	add_child(intro_overlay)

	intro_lbl = _lbl(52)
	intro_lbl.set_anchors_preset(Control.PRESET_CENTER)
	intro_lbl.offset_left = -520;  intro_lbl.offset_right  = 520
	intro_lbl.offset_top  = -70;   intro_lbl.offset_bottom = 70
	intro_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intro_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	intro_overlay.add_child(intro_lbl)

	# Match-end overlay (split-screen WINNER / ELIMINATED, mirrors 1v1)
	end_overlay = Control.new()
	end_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_overlay.visible = false
	add_child(end_overlay)

	_end_left_dim = ColorRect.new()
	_end_left_dim.anchor_right = 0.5;  _end_left_dim.anchor_bottom = 1.0
	_end_left_dim.color = Color(0, 0, 0, 0)
	end_overlay.add_child(_end_left_dim)

	_end_right_dim = ColorRect.new()
	_end_right_dim.anchor_left = 0.5;  _end_right_dim.anchor_right  = 1.0
	_end_right_dim.anchor_bottom = 1.0
	_end_right_dim.color = Color(0, 0, 0, 0)
	end_overlay.add_child(_end_right_dim)

	_end_left_lbl = _lbl(64)
	_end_left_lbl.anchor_right  = 0.5
	_end_left_lbl.anchor_top    = 0.5;  _end_left_lbl.anchor_bottom = 0.5
	_end_left_lbl.offset_top    = -48;  _end_left_lbl.offset_bottom = 48
	_end_left_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_left_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	end_overlay.add_child(_end_left_lbl)

	_end_right_lbl = _lbl(64)
	_end_right_lbl.anchor_left  = 0.5;  _end_right_lbl.anchor_right  = 1.0
	_end_right_lbl.anchor_top   = 0.5;  _end_right_lbl.anchor_bottom = 0.5
	_end_right_lbl.offset_top   = -48;  _end_right_lbl.offset_bottom = 48
	_end_right_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_right_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	end_overlay.add_child(_end_right_lbl)

	_refresh_scores()


func _lbl(sz: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_font_override("font", FONT)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	return l


# ── Helpers ───────────────────────────────────────────────────────────────────

func _refresh_scores() -> void:
	if t1_score_lbl:
		t1_score_lbl.text = str(t1_score)
	if t2_score_lbl:
		t2_score_lbl.text = str(t2_score)


func _fmt(v) -> String:
	return "%.1f ms" % float(v) if v != null else "—"


func _fmt_combined(comb: float, rt_arr: Array, pre_arr: Array) -> String:
	var all_missed: bool = rt_arr[0] == null and rt_arr[1] == null and not pre_arr[0] and not pre_arr[1]
	if all_missed:
		return "MISS"
	return "%d ms" % int(comb)


func _dismiss_intro() -> void:
	if is_instance_valid(intro_overlay):
		intro_overlay.visible = false


func _my_box() -> ColorRect:
	return boxes[my_team - 1][my_slot]


func _my_rt_lbl() -> Label:
	return rt_labels[my_team - 1][my_slot]


func _compute_my_box_rect() -> Rect2:
	# After _apply_visual_layout(), my box is always bottom-left.
	return Rect2(7.0, MID_Y + 4.0, 640.0 - 14.0, 720.0 - MID_Y - 11.0)


# ── Visual layout helpers ─────────────────────────────────────────────────────

func _apply_visual_layout() -> void:
	if not _layout_applied:
		_layout_applied = true
		if my_team == 2:
			_swap_lr_anchors()
		if my_slot == 0:
			_swap_tb_in_my_left_col()
	# Always reset anchors and rect (safe to repeat)
	ready_lbl.anchor_left   = 0.0;  ready_lbl.anchor_right  = 0.5
	ready_lbl.anchor_top    = 0.775; ready_lbl.anchor_bottom = 0.775
	my_box_rect = _compute_my_box_rect()


func _swap_lr_anchors() -> void:
	# Move team1 nodes to the right side, team2 nodes to the left side.
	for si in range(2):
		for arr in [boxes, rt_labels, name_labels]:
			(arr[0][si] as Control).anchor_left  = 0.5
			(arr[0][si] as Control).anchor_right = 1.0
			(arr[1][si] as Control).anchor_left  = 0.0
			(arr[1][si] as Control).anchor_right = 0.5
	# Combined labels
	t1_combined_lbl.anchor_left = 0.5;  t1_combined_lbl.anchor_right = 1.0
	t2_combined_lbl.anchor_left = 0.0;  t2_combined_lbl.anchor_right = 0.5
	# Score labels
	t1_score_lbl.anchor_left = 0.5;  t1_score_lbl.anchor_right = 1.0
	t1_score_lbl.offset_left = 28;   t1_score_lbl.offset_right = 0
	t1_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	t2_score_lbl.anchor_left = 0.0;  t2_score_lbl.anchor_right = 0.5
	t2_score_lbl.offset_left = 0;    t2_score_lbl.offset_right = -28
	t2_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Team header labels in top bar
	for child in get_children():
		if not child.has_meta("team_header"):
			continue
		if child.get_meta("team_header") == 1:
			child.anchor_left  = 0.58;  child.anchor_right  = 1.0
			child.offset_left  = 0;     child.offset_right  = -14
			child.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		else:
			child.anchor_left  = 0.0;   child.anchor_right  = 0.42
			child.offset_left  = 14;    child.offset_right  = 0
			child.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT


func _swap_tb_in_my_left_col() -> void:
	# Swap top/bottom visual positions within my team's column so I'm always at bottom.
	var ti := my_team - 1
	var b0 := boxes[ti][0] as ColorRect
	var b1 := boxes[ti][1] as ColorRect
	b0.anchor_bottom = 1.0;  b0.offset_top = MID_Y + 4;  b0.offset_bottom = -7
	b1.anchor_bottom = 0.0;  b1.offset_top = TOP + 7;    b1.offset_bottom = MID_Y - 4
	var nl0 := name_labels[ti][0] as Label
	var nl1 := name_labels[ti][1] as Label
	nl0.offset_top = MID_Y + 10;  nl0.offset_bottom = MID_Y + 40
	nl1.offset_top = TOP + 14;    nl1.offset_bottom = TOP + 44
	var rl0 := rt_labels[ti][0] as Label
	var rl1 := rt_labels[ti][1] as Label
	rl0.anchor_top = 1.0;  rl0.anchor_bottom = 1.0
	rl0.offset_top = -68;  rl0.offset_bottom = -14
	rl1.anchor_top = 0.0;  rl1.anchor_bottom = 0.0
	rl1.offset_top = MID_Y - 68;  rl1.offset_bottom = MID_Y - 14


# ── Signal handlers ───────────────────────────────────────────────────────────

func _make_beep() -> AudioStreamWAV:
	const SAMPLE_RATE := 44100
	const FREQ := 880.0
	const DURATION_S := 0.12
	var num_samples := int(SAMPLE_RATE * DURATION_S)
	var bytes := PackedByteArray()
	bytes.resize(num_samples * 2)
	for i in num_samples:
		var t := float(i) / float(SAMPLE_RATE)
		var fade := 1.0
		if i > num_samples - 882:
			fade = float(num_samples - i) / 882.0
		var sample := int(clampf(sin(TAU * FREQ * t) * fade * 32767.0, -32768.0, 32767.0))
		bytes[i * 2]     = sample & 0xFF
		bytes[i * 2 + 1] = (sample >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.data = bytes
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	return wav


func _on_team_match_start(data: Dictionary) -> void:
	my_team = data.get("your_team", 1)
	my_slot = data.get("your_slot", 0)
	is_auditory = data.get("is_auditory", false)
	if is_auditory:
		_beep_player = AudioStreamPlayer.new()
		_beep_player.stream = _make_beep()
		add_child(_beep_player)
	var t1_raw: Array = data.get("team1", [])
	var t2_raw: Array = data.get("team2", [])
	for i in range(2):
		team1_names[i] = t1_raw[i].get("username", "?") if i < t1_raw.size() else "?"
		team2_names[i] = t2_raw[i].get("username", "?") if i < t2_raw.size() else "?"

	# Fill player name labels, appending (YOU) to the local player's own slot
	for i in range(2):
		var lbl_t1: String = team1_names[i] + (" (YOU)" if my_team == 1 and my_slot == i else "")
		var lbl_t2: String = team2_names[i] + (" (YOU)" if my_team == 2 and my_slot == i else "")
		name_labels[0][i].text = lbl_t1
		name_labels[1][i].text = lbl_t2

	# Update top-bar team headers
	for child in get_children():
		if child.has_meta("team_header"):
			var tn: int = child.get_meta("team_header")
			if tn == 1:
				child.text = "%s  /  %s" % [team1_names[0], team1_names[1]]
			else:
				child.text = "%s  /  %s" % [team2_names[0], team2_names[1]]

	_apply_visual_layout()


func _on_round_prepare(round_num: int) -> void:
	Net.send_client_info()
	state = State.WAITING
	countdown_timer.stop()
	ready_lbl.add_theme_font_size_override("font_size", 20)
	ready_lbl.visible = false
	countdown_lbl.visible = false
	t1_combined_lbl.visible = false
	t2_combined_lbl.visible = false

	for ti in range(2):
		for si in range(2):
			boxes[ti][si].color = COL_WAITING
			rt_labels[ti][si].text = ""

	if round_num == 1:
		await _show_team_intro()
		await get_tree().create_timer(2.0).timeout


func _show_team_intro() -> void:
	intro_overlay.visible = true
	var my_n  := team1_names if my_team == 1 else team2_names
	var opp_n := team2_names if my_team == 1 else team1_names
	intro_lbl.text = "%s  &  %s\nVS\n%s  &  %s" % [my_n[0], my_n[1], opp_n[0], opp_n[1]]
	await get_tree().create_timer(2.5).timeout
	_dismiss_intro()


func _on_stimulus(_t: int) -> void:
	_window_focused_at_stimulus = get_window().has_focus()
	_dismiss_intro()
	state = State.STIMULUS
	t_stimulus_us = Time.get_ticks_usec()
	if is_auditory:
		if _beep_player != null:
			_beep_player.play()
	else:
		for ti in range(2):
			for si in range(2):
				boxes[ti][si].color = COL_GO


func _on_team_player_clicked(data: Dictionary) -> void:
	if state not in [State.STIMULUS, State.AFTER_CLICK, State.WAITING]:
		return
	var team: int = data.get("team", 0)
	var slot: int = data.get("slot", 0)
	var pre: bool = data.get("pre_click", false)
	var ti := team - 1
	if ti < 0 or ti > 1 or slot < 0 or slot > 1:
		return
	if pre:
		boxes[ti][slot].color = COL_LOSE
		rt_labels[ti][slot].text = "Too early!"
	else:
		boxes[ti][slot].color = COL_SENT


func _on_team_round_result(data: Dictionary) -> void:
	t1_score = data.get("t1_score", t1_score)
	t2_score = data.get("t2_score", t2_score)
	var winner_team: int = data.get("winner_team", 0)
	var t1_rt: Array = data.get("team1_rt_ms", [null, null])
	var t2_rt: Array = data.get("team2_rt_ms", [null, null])
	var t1_pre: Array = data.get("team1_pre_click", [false, false])
	var t2_pre: Array = data.get("team2_pre_click", [false, false])
	var t1_comb: float = data.get("team1_combined_ms", 0.0)
	var t2_comb: float = data.get("team2_combined_ms", 0.0)

	# Colour boxes and set RT labels
	for si in range(2):
		var t1_won := winner_team == 1
		var t2_won := winner_team == 2

		boxes[0][si].color = COL_WIN if t1_won else (COL_LOSE if t2_won else COL_WAITING)
		boxes[1][si].color = COL_WIN if t2_won else (COL_LOSE if t1_won else COL_WAITING)

		if not (my_team == 1 and my_slot == si):
			if t1_pre[si]:
				rt_labels[0][si].text = "FAIL"
			elif t1_rt[si] != null:
				rt_labels[0][si].text = _fmt(t1_rt[si])
			else:
				rt_labels[0][si].text = "—"

		if not (my_team == 2 and my_slot == si):
			if t2_pre[si]:
				rt_labels[1][si].text = "FAIL"
			elif t2_rt[si] != null:
				rt_labels[1][si].text = _fmt(t2_rt[si])
			else:
				rt_labels[1][si].text = "—"

	# Show combined RT at midline — left label always = my team, right = opponents
	var my_comb_lbl  := t1_combined_lbl if my_team == 1 else t2_combined_lbl
	var opp_comb_lbl := t2_combined_lbl if my_team == 1 else t1_combined_lbl
	var my_comb  := t1_comb if my_team == 1 else t2_comb
	var opp_comb := t2_comb if my_team == 1 else t1_comb
	var my_rt    := t1_rt   if my_team == 1 else t2_rt
	var opp_rt   := t2_rt   if my_team == 1 else t1_rt
	var my_pre   := t1_pre  if my_team == 1 else t2_pre
	var opp_pre  := t2_pre  if my_team == 1 else t1_pre
	my_comb_lbl.text  = "YOUR TEAM:  " + _fmt_combined(my_comb, my_rt, my_pre)
	opp_comb_lbl.text = "OPP TEAM:  "  + _fmt_combined(opp_comb, opp_rt, opp_pre)
	my_comb_lbl.visible  = true
	opp_comb_lbl.visible = true

	_refresh_scores()
	_enter_ready_up()


func _on_team_match_end(data: Dictionary) -> void:
	state = State.MATCH_END
	var winner_team: int = data.get("winner_team", 0)
	var t1_final: int = data.get("t1_score", t1_score)
	var t2_final: int = data.get("t2_score", t2_score)
	countdown_timer.stop()
	ready_lbl.visible = false
	countdown_lbl.visible = false

	var is_tie := (winner_team == 0)
	var i_won  := (winner_team == my_team)

	Net.last_team_match_result = {
		"won":         i_won,
		"is_tie":      is_tie,
		"winner_team": winner_team,
		"t1_score":    t1_final,
		"t2_score":    t2_final,
		"team1_names": team1_names,
		"team2_names": team2_names,
		"my_team":     my_team,
	}

	_show_end_overlay(i_won, is_tie)
	end_timer.start(2.0)


func _show_end_overlay(i_won: bool, is_tie: bool = false) -> void:
	end_overlay.visible = true
	if is_tie:
		_end_left_dim.color     = Color(0, 0, 0, 0.4)
		_end_right_dim.color    = Color(0, 0, 0, 0.4)
		_end_left_lbl.text      = "TIE"
		_end_left_lbl.modulate  = Color(0.85, 0.85, 0.85)
		_end_right_lbl.text     = "TIE"
		_end_right_lbl.modulate = Color(0.85, 0.85, 0.85)
	elif i_won:
		_end_left_dim.color     = Color(0, 0, 0, 0)
		_end_right_dim.color    = Color(0, 0, 0, 0.65)
		_end_left_lbl.text      = "WINNER!"
		_end_left_lbl.modulate  = Color(0.3, 0.95, 0.45)
		_end_right_lbl.text     = "ELIMINATED"
		_end_right_lbl.modulate = Color(0.55, 0.55, 0.55)
	else:
		_end_left_dim.color     = Color(0, 0, 0, 0.65)
		_end_right_dim.color    = Color(0, 0, 0, 0)
		_end_left_lbl.text      = "ELIMINATED"
		_end_left_lbl.modulate  = Color(0.55, 0.55, 0.55)
		_end_right_lbl.text     = "WINNER!"
		_end_right_lbl.modulate = Color(0.3, 0.95, 0.45)


func _go_to_team_results() -> void:
	get_tree().change_scene_to_file("res://scenes/results_2v2.tscn")


# ── Ready-up ──────────────────────────────────────────────────────────────────

func _enter_ready_up() -> void:
	state = State.READY_UP
	_readied = false
	_countdown = 5
	ready_lbl.text = "Click to ready up"
	ready_lbl.modulate = Color(0.85, 0.85, 0.85)
	ready_lbl.add_theme_font_size_override("font_size", 20)
	ready_lbl.visible = true
	countdown_lbl.text = "5"
	countdown_lbl.visible = true
	countdown_timer.start()


func _on_countdown_tick() -> void:
	_countdown -= 1
	if _countdown <= 0:
		countdown_timer.stop()
		countdown_lbl.text = "0"
		if not _readied:
			ready_lbl.text = "Starting..."
	else:
		countdown_lbl.text = str(_countdown)


# ── Mouse instrumentation ─────────────────────────────────────────────────────

func _mouse_dist_5s() -> float:
	var now_us := Time.get_ticks_usec()
	var cutoff := now_us - 5_000_000
	var dist := 0.0
	var has_prev := false
	var prev := Vector2.ZERO
	for entry in _mouse_pos_history:
		if (entry[0] as int) >= cutoff:
			if has_prev:
				dist += (entry[1] as Vector2).distance_to(prev)
			has_prev = true
			prev = entry[1]
	return dist


func _time_since_move_ms() -> float:
	if _last_mouse_move_us == 0:
		return -1.0
	return (Time.get_ticks_usec() - _last_mouse_move_us) / 1000.0


func _pre_click_displacement_px() -> float:
	var now_us := Time.get_ticks_usec()
	var cutoff := now_us - 100_000  # 100 ms window
	var dist := 0.0
	var has_prev := false
	var prev := Vector2.ZERO
	for entry in _mouse_pos_history:
		if (entry[0] as int) >= cutoff:
			if has_prev:
				dist += (entry[1] as Vector2).distance_to(prev)
			has_prev = true
			prev = entry[1]
	return dist


# ── Input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var now_us := Time.get_ticks_usec()
		_last_mouse_move_us = now_us
		_mouse_pos_history.append([now_us, event.position])
		if _mouse_pos_history.size() > 800:
			var cutoff := now_us - 5_000_000
			var i := 0
			while i < _mouse_pos_history.size() and (_mouse_pos_history[i][0] as int) < cutoff:
				i += 1
			if i > 0:
				_mouse_pos_history = _mouse_pos_history.slice(i)
		return

	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if not event.pressed:
		if _mouse_down_us > 0:
			Net.send_click_info((Time.get_ticks_usec() - _mouse_down_us) / 1000.0)
			_mouse_down_us = 0
		return

	# Ignore clicks while the intro overlay is showing
	if intro_overlay.visible:
		return

	_mouse_down_us = Time.get_ticks_usec()

	match state:
		State.STIMULUS:
			state = State.AFTER_CLICK
			var rt := (Time.get_ticks_usec() - t_stimulus_us) / 1000.0
			_my_rt_lbl().text = "%.1f ms" % rt
			var _mpos := (event as InputEventMouseButton).position
			Net.send_click(rt, false, _mouse_dist_5s(), _time_since_move_ms(), _window_focused_at_stimulus, _mpos.x, _mpos.y, _pre_click_displacement_px())
			_my_box().color = COL_SENT
		State.WAITING:
			var _mpos_pre := (event as InputEventMouseButton).position
			Net.send_click(0.0, true, _mouse_dist_5s(), _time_since_move_ms(), get_window().has_focus(), _mpos_pre.x, _mpos_pre.y, _pre_click_displacement_px())
			_my_box().color = COL_LOSE
			_my_rt_lbl().text = "FAIL!"
			ready_lbl.add_theme_font_size_override("font_size", 36)
			ready_lbl.text = "FAIL!"
			ready_lbl.modulate = Color(1.0, 0.35, 0.35)
			ready_lbl.visible = true
		State.READY_UP:
			if not _readied and my_box_rect.has_point(event.position):
				_readied = true
				Net.send_ready_up()
				ready_lbl.text = "Ready!"
				ready_lbl.modulate = Color(0.3, 0.9, 0.4)
