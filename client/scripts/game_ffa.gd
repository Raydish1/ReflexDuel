extends Control
# scripts/game_ffa.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

enum State { WAITING, STIMULUS, AFTER_CLICK, READY_UP, MATCH_END }
var state: State = State.WAITING

const TOP: float = 72.0
const MID_Y: float = TOP + (720.0 - TOP) / 2.0  # 396.0

var t_stimulus_us: int = 0
var my_server_slot: int = 0
# server_to_visual[server_slot] = visual_slot
# Visual 0 = bottom-left (always me), 1 = top-left, 2 = bottom-right, 3 = top-right
var server_to_visual: Array = [0, 1, 2, 3]
var visual_to_server: Array = [0, 1, 2, 3]
var player_names: Array = ["?", "?", "?", "?"]  # indexed by server slot
var scores: Array = [0, 0, 0, 0]                # indexed by server slot
var player_count: int = 4
var _readied: bool = false
var _countdown: int = 5
var my_box_rect: Rect2

const COL_WAITING := Color(0.55, 0.12, 0.12)
const COL_GO      := Color(0.18, 0.82, 0.28)
const COL_WIN     := Color(0.18, 0.72, 0.28)
const COL_LOSE    := Color(0.62, 0.13, 0.13)
const COL_SENT    := Color(0.18, 0.55, 0.72)

# Indexed by visual slot (0=bottom-left/me, 1=top-left, 2=bottom-right, 3=top-right)
var boxes: Array = []
var rt_labels: Array = []
var name_labels: Array = []
var score_lbls: Array = []  # individual score labels in top bar

var ready_lbl: Label
var countdown_lbl: Label
var intro_overlay: ColorRect
var intro_lbl: Label
var end_overlay: Control
var _end_dims: Array = []
var _end_lbls: Array = []

# Anti-cheat instrumentation
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
	end_timer.timeout.connect(_go_to_ffa_results)

	Net.ffa_match_start.connect(_on_ffa_match_start)
	Net.round_prepare.connect(_on_round_prepare)
	Net.stimulus.connect(_on_stimulus)
	Net.ffa_round_result.connect(_on_ffa_round_result)
	Net.ffa_match_end.connect(_on_ffa_match_end)
	Net.ffa_player_clicked.connect(_on_ffa_player_clicked)

	var bstart := Net.last_ffa_match_start
	Net.last_ffa_match_start = {}
	if not bstart.is_empty():
		_on_ffa_match_start(bstart)

	var brp := Net.last_round_prepare
	Net.last_round_prepare = -1
	if brp >= 1:
		_on_round_prepare(brp)


func _exit_tree() -> void:
	for pair in [
		[Net.ffa_match_start,    _on_ffa_match_start],
		[Net.round_prepare,      _on_round_prepare],
		[Net.stimulus,           _on_stimulus],
		[Net.ffa_round_result,   _on_ffa_round_result],
		[Net.ffa_match_end,      _on_ffa_match_end],
		[Net.ffa_player_clicked, _on_ffa_player_clicked],
	]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


# ── Layout ────────────────────────────────────────────────────────────────────

# Visual slot geometry helpers
# vs = 0 → bottom-left, 1 → top-left, 2 → bottom-right, 3 → top-right
func _is_right(vs: int) -> bool: return vs >= 2
func _is_bottom(vs: int) -> bool: return vs == 0 or vs == 2


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

	# Horizontal dividers at MID_Y (one per column)
	for col in [0, 1]:
		var hdiv := ColorRect.new()
		hdiv.anchor_left   = 0.0 if col == 0 else 0.5
		hdiv.anchor_right  = 0.5 if col == 0 else 1.0
		hdiv.offset_left   = 7;   hdiv.offset_right  = -7
		hdiv.offset_top    = MID_Y - 2
		hdiv.offset_bottom = MID_Y + 2
		hdiv.color = Color(0.10, 0.10, 0.10, 1)
		add_child(hdiv)

	# 4 reaction boxes (visual slots 0-3)
	for vs in range(4):
		var right := _is_right(vs)
		var bottom := _is_bottom(vs)

		var box := ColorRect.new()
		box.anchor_left   = 0.5 if right else 0.0
		box.anchor_right  = 1.0 if right else 0.5
		box.anchor_top    = 0.0
		box.anchor_bottom = 1.0 if bottom else 0.0
		box.offset_left   = 7;  box.offset_right  = -7
		box.offset_top    = MID_Y + 4 if bottom else TOP + 7
		box.offset_bottom = -7 if bottom else MID_Y - 4
		box.color = COL_WAITING
		add_child(box)
		boxes.append(box)

		# Player name label (near top of each box)
		var nlbl := _lbl(20)
		nlbl.anchor_left   = 0.5 if right else 0.0
		nlbl.anchor_right  = 1.0 if right else 0.5
		nlbl.anchor_top    = 0.0
		nlbl.anchor_bottom = 0.0
		nlbl.offset_left   = 14;  nlbl.offset_right = -14
		nlbl.offset_top    = MID_Y + 10 if bottom else TOP + 14
		nlbl.offset_bottom = nlbl.offset_top + 30
		nlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(nlbl)
		name_labels.append(nlbl)

		# RT result label (near bottom of each box)
		var rtlbl := _lbl(22)
		rtlbl.anchor_left   = 0.5 if right else 0.0
		rtlbl.anchor_right  = 1.0 if right else 0.5
		rtlbl.anchor_top    = 1.0 if bottom else 0.0
		rtlbl.anchor_bottom = 1.0 if bottom else 0.0
		rtlbl.offset_left   = 14;  rtlbl.offset_right = -14
		rtlbl.offset_top    = -68 if bottom else MID_Y - 68
		rtlbl.offset_bottom = -14 if bottom else MID_Y - 14
		rtlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rtlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rtlbl)
		rt_labels.append(rtlbl)

	# Top bar: 4 score slots (one per visual slot, left→right: vs1, vs0, vs2, vs3 won't work)
	# Simple layout: split top bar into 4 equal sections
	var section_names := ["", "", "", ""]  # will be set once names are known
	for vs in range(4):
		var slbl := _lbl(26)
		slbl.anchor_left   = vs * 0.25
		slbl.anchor_right  = (vs + 1) * 0.25
		slbl.offset_top    = 0;  slbl.offset_bottom = TOP
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		slbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(slbl)
		score_lbls.append(slbl)

	# Ready / countdown labels
	ready_lbl = _lbl(20)
	ready_lbl.anchor_left = 0.0;  ready_lbl.anchor_right = 0.5
	ready_lbl.anchor_top  = 1.0;  ready_lbl.anchor_bottom = 1.0
	ready_lbl.offset_top  = -48;  ready_lbl.offset_bottom = -14
	ready_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_lbl.modulate = Color(0.85, 0.85, 0.85)
	ready_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ready_lbl.visible = false
	add_child(ready_lbl)

	countdown_lbl = _lbl(80)
	countdown_lbl.anchor_left = 0.0;  countdown_lbl.anchor_right  = 1.0
	countdown_lbl.anchor_top  = 0.0;  countdown_lbl.anchor_bottom = 0.0
	countdown_lbl.offset_top  = MID_Y - 48;  countdown_lbl.offset_bottom = MID_Y + 48
	countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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

	intro_lbl = _lbl(44)
	intro_lbl.set_anchors_preset(Control.PRESET_CENTER)
	intro_lbl.offset_left = -520;  intro_lbl.offset_right  = 520
	intro_lbl.offset_top  = -90;   intro_lbl.offset_bottom = 90
	intro_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intro_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	intro_overlay.add_child(intro_lbl)

	# Match-end overlay: 4 quadrant overlays
	end_overlay = Control.new()
	end_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_overlay.visible = false
	add_child(end_overlay)

	for vs in range(4):
		var right := _is_right(vs)
		var bottom := _is_bottom(vs)

		var dim := ColorRect.new()
		dim.anchor_left   = 0.5 if right else 0.0
		dim.anchor_right  = 1.0 if right else 0.5
		dim.anchor_top    = 0.0
		dim.anchor_bottom = 1.0 if bottom else 0.0
		dim.offset_top    = MID_Y if bottom else TOP
		dim.offset_bottom = 0 if bottom else MID_Y
		dim.color = Color(0, 0, 0, 0)
		end_overlay.add_child(dim)
		_end_dims.append(dim)

		var elbl := _lbl(56)
		elbl.anchor_left   = 0.5 if right else 0.0
		elbl.anchor_right  = 1.0 if right else 0.5
		elbl.anchor_top    = 1.0 if bottom else 0.0
		elbl.anchor_bottom = 1.0 if bottom else 0.0
		elbl.offset_top    = -100 if bottom else MID_Y - TOP + 20
		elbl.offset_bottom = -20 if bottom else MID_Y - TOP + 80
		elbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		elbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		end_overlay.add_child(elbl)
		_end_lbls.append(elbl)

	_refresh_score_bar()


func _lbl(sz: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_font_override("font", FONT)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	return l


# ── Helpers ───────────────────────────────────────────────────────────────────

func _refresh_score_bar() -> void:
	for vs in range(player_count):
		var ss: int = visual_to_server[vs]
		score_lbls[vs].text = "%s  %d" % [player_names[ss], scores[ss]]


func _fmt(v) -> String:
	return "%.1f ms" % float(v) if v != null else "—"


func _dismiss_intro() -> void:
	if is_instance_valid(intro_overlay):
		intro_overlay.visible = false


func _my_box() -> ColorRect:
	return boxes[0]  # visual slot 0 is always me


func _my_rt_lbl() -> Label:
	return rt_labels[0]


func _vs_for_server(ss: int) -> int:
	return server_to_visual[ss]


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


func _on_ffa_match_start(data: Dictionary) -> void:
	my_server_slot = data.get("your_slot", 0)
	is_auditory = data.get("is_auditory", false)
	if is_auditory:
		_beep_player = AudioStreamPlayer.new()
		_beep_player.stream = _make_beep()
		add_child(_beep_player)
	var players_raw: Array = data.get("players", [])
	player_count = clampi(players_raw.size(), 2, 4)

	for i in range(player_count):
		player_names[i] = players_raw[i].get("username", "?")

	server_to_visual[my_server_slot] = 0
	visual_to_server[0] = my_server_slot
	var vslot := 1
	for ss in range(player_count):
		if ss == my_server_slot:
			continue
		server_to_visual[ss] = vslot
		visual_to_server[vslot] = ss
		vslot += 1

	# Hide unused slots when player_count < 4
	for vs in range(4):
		var active := vs < player_count
		boxes[vs].visible = active
		name_labels[vs].visible = active
		rt_labels[vs].visible = active
		score_lbls[vs].visible = active
		_end_dims[vs].visible = active
		_end_lbls[vs].visible = active

	for vs in range(player_count):
		var ss: int = visual_to_server[vs]
		name_labels[vs].text = player_names[ss] + (" (YOU)" if ss == my_server_slot else "")

	_refresh_score_bar()
	my_box_rect = Rect2(7.0, MID_Y + 4.0, 640.0 - 14.0, 720.0 - MID_Y - 11.0)


func _on_round_prepare(round_num: int) -> void:
	Net.send_client_info()
	state = State.WAITING
	countdown_timer.stop()
	ready_lbl.visible = false
	countdown_lbl.visible = false

	for vs in range(player_count):
		boxes[vs].color = COL_WAITING
		rt_labels[vs].text = ""

	if round_num == 1:
		await _show_ffa_intro()
		await get_tree().create_timer(2.0).timeout


func _show_ffa_intro() -> void:
	intro_overlay.visible = true
	var my_name: String = player_names[my_server_slot]
	var other_names: Array = []
	for ss in range(player_count):
		if ss != my_server_slot:
			other_names.append(player_names[ss])
	intro_lbl.text = "%s (YOU)\nVS\n%s" % [my_name, "  /  ".join(PackedStringArray(other_names))]
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
		for vs in range(player_count):
			boxes[vs].color = COL_GO


func _on_ffa_player_clicked(data: Dictionary) -> void:
	if state not in [State.STIMULUS, State.AFTER_CLICK, State.WAITING]:
		return
	var ss: int = data.get("slot", 0)
	var pre: bool = data.get("pre_click", false)
	var vs := _vs_for_server(ss)
	if pre:
		boxes[vs].color = COL_LOSE
		rt_labels[vs].text = "Too early!"
	else:
		boxes[vs].color = COL_SENT


func _on_ffa_round_result(data: Dictionary) -> void:
	var rt_ms: Array    = data.get("rt_ms", [])
	var pre_click: Array = data.get("pre_click", [])
	var winner_slot: int = data.get("winner_slot", -1)
	var new_scores: Array = data.get("scores", scores)
	for i in range(player_count):
		if i < new_scores.size():
			scores[i] = new_scores[i]

	for ss in range(player_count):
		var vs := _vs_for_server(ss)
		var i_won_round := (winner_slot == ss)
		var other_won := (winner_slot >= 0 and winner_slot != ss)
		boxes[vs].color = COL_WIN if i_won_round else (COL_LOSE if other_won else COL_WAITING)
		if ss != my_server_slot:
			if ss < pre_click.size() and pre_click[ss]:
				rt_labels[vs].text = "FAIL"
			elif ss < rt_ms.size() and rt_ms[ss] != null:
				rt_labels[vs].text = _fmt(rt_ms[ss])
			else:
				rt_labels[vs].text = "—"

	_refresh_score_bar()
	_enter_ready_up()


func _on_ffa_match_end(data: Dictionary) -> void:
	state = State.MATCH_END
	var placements: Array = data.get("placements", [])
	var final_scores: Array = data.get("scores", scores)
	var winner_slot: int = data.get("winner_slot", 0)
	for i in range(player_count):
		if i < final_scores.size():
			scores[i] = final_scores[i]
	countdown_timer.stop()
	ready_lbl.visible = false
	countdown_lbl.visible = false

	Net.last_ffa_match_result = {
		"my_server_slot":  my_server_slot,
		"placements":      placements,
		"scores":          final_scores,
		"player_names":    player_names,
		"winner_slot":     winner_slot,
		"server_to_visual": server_to_visual,
	}

	_show_end_overlay(placements, winner_slot)
	end_timer.start(2.0)


func _show_end_overlay(placements: Array, winner_slot: int) -> void:
	end_overlay.visible = true
	for vs in range(player_count):
		var ss: int = visual_to_server[vs]
		var i_won: bool = (ss == winner_slot)
		if i_won:
			_end_dims[vs].color = Color(0, 0, 0, 0)
			_end_lbls[vs].text = "WINNER!"
			_end_lbls[vs].modulate = Color(0.3, 0.95, 0.45)
		else:
			_end_dims[vs].color = Color(0, 0, 0, 0.65)
			_end_lbls[vs].text = "ELIMINATED"
			_end_lbls[vs].modulate = Color(0.55, 0.55, 0.55)


func _go_to_ffa_results() -> void:
	get_tree().change_scene_to_file("res://scenes/results_ffa.tscn")


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
	var cutoff := now_us - 100_000
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

	if intro_overlay.visible:
		return

	_mouse_down_us = Time.get_ticks_usec()

	match state:
		State.STIMULUS:
			state = State.AFTER_CLICK
			var rt := (Time.get_ticks_usec() - t_stimulus_us) / 1000.0
			_my_rt_lbl().text = "%.1f ms" % rt
			var mpos := (event as InputEventMouseButton).position
			Net.send_click(rt, false, _mouse_dist_5s(), _time_since_move_ms(), _window_focused_at_stimulus, mpos.x, mpos.y, _pre_click_displacement_px())
			_my_box().color = COL_SENT
		State.WAITING:
			var mpos := (event as InputEventMouseButton).position
			Net.send_click(0.0, true, _mouse_dist_5s(), _time_since_move_ms(), get_window().has_focus(), mpos.x, mpos.y, _pre_click_displacement_px())
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
