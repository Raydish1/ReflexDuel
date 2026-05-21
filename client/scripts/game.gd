extends Control
# scripts/game.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

enum State { WAITING, STIMULUS, AFTER_CLICK, READY_UP, MATCH_END }
var state: State = State.WAITING

var t_stimulus_us: int = 0
var my_score: int = 0
var opp_score: int = 0
var my_username: String = "?"
var opponent_username: String = "?"
var _countdown: int = 5
var _readied: bool = false
var current_mode: String = "ranked"
var is_auditory: bool = false
var _beep_player: AudioStreamPlayer = null

# Anti-cheat instrumentation
var _mouse_pos_history: Array = []   # Array of [timestamp_us: int, pos: Vector2]
var _last_mouse_move_us: int = 0
var _mouse_down_us: int = 0
var _click_duration_ms: float = 0.0
var _window_focused_at_stimulus: bool = true

const COL_WAITING := Color(0.55, 0.12, 0.12)
const COL_GO      := Color(0.18, 0.82, 0.28)
const COL_WIN     := Color(0.18, 0.72, 0.28)
const COL_LOSE    := Color(0.62, 0.13, 0.13)
const COL_SENT    := Color(0.18, 0.55, 0.72)

# Layout nodes (built in _build_ui)
var my_box: ColorRect
var opp_box: ColorRect
var my_name_lbl: Label
var opp_name_lbl: Label
var my_score_lbl: Label
var opp_score_lbl: Label
var my_rt_lbl: Label
var opp_rt_lbl: Label
var ready_lbl: Label
var countdown_lbl: Label
var mode_lbl: Label
var intro_overlay: ColorRect
var intro_lbl: Label
var end_overlay: Control
var _end_left_dim: ColorRect
var _end_right_dim: ColorRect
var _end_left_lbl: Label
var _end_right_lbl: Label

@onready var countdown_timer: Timer = $CountdownTimer
@onready var end_timer: Timer = $EndTimer


func _ready() -> void:
	_build_ui()

	var md: Dictionary = Net.last_match_start
	current_mode = md.get("mode", "ranked")
	is_auditory = md.get("is_auditory", false)
	my_username = Net.username
	opponent_username = md.get("opponent_username", "?")
	_refresh_names()
	_refresh_scores()
	_set_mode_label()

	if is_auditory:
		_beep_player = AudioStreamPlayer.new()
		_beep_player.stream = _make_beep()
		add_child(_beep_player)

	countdown_timer.timeout.connect(_on_countdown_tick)
	end_timer.timeout.connect(_go_to_results)

	Net.round_prepare.connect(_on_round_prepare)
	Net.stimulus.connect(_on_stimulus)
	Net.round_result.connect(_on_round_result)
	Net.match_end.connect(_on_match_end)
	Net.opponent_clicked.connect(_on_opponent_clicked)

	# Replay round_prepare if it arrived before this scene loaded
	var buffered := Net.last_round_prepare
	Net.last_round_prepare = -1
	if buffered >= 1:
		_on_round_prepare(buffered)


func _exit_tree() -> void:
	for pair in [
		[Net.round_prepare,    _on_round_prepare],
		[Net.stimulus,         _on_stimulus],
		[Net.round_result,     _on_round_result],
		[Net.match_end,        _on_match_end],
		[Net.opponent_clicked, _on_opponent_clicked],
	]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


# ── Layout ────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	const TOP: float = 72.0

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.97, 0.68, 0.05)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.anchor_right = 1.0
	top_bar.offset_bottom = TOP
	top_bar.color = Color(0.20, 0.20, 0.20)
	add_child(top_bar)

	var div := ColorRect.new()
	div.anchor_left = 0.5;  div.anchor_right  = 0.5
	div.anchor_top  = 0.0;  div.anchor_bottom = 1.0
	div.offset_left = -2;   div.offset_right  = 2
	div.color = Color(0.10, 0.10, 0.10, 1)
	add_child(div)

	# Reaction boxes start red (WAITING state) — 7 px amber border on all sides
	my_box = ColorRect.new()
	my_box.anchor_right = 0.5;  my_box.anchor_bottom = 1.0
	my_box.offset_left = 7;     my_box.offset_top    = TOP + 7
	my_box.offset_right = -7;   my_box.offset_bottom = -7
	my_box.color = COL_WAITING
	add_child(my_box)

	opp_box = ColorRect.new()
	opp_box.anchor_left = 0.5;   opp_box.anchor_right  = 1.0
	opp_box.anchor_bottom = 1.0
	opp_box.offset_left = 7;    opp_box.offset_top   = TOP + 7
	opp_box.offset_right = -7;  opp_box.offset_bottom = -7
	opp_box.color = COL_WAITING
	add_child(opp_box)

	# YOU / OPPONENT side labels (inside the box area, near top, decorative)
	var you_lbl := _lbl(32)
	you_lbl.text = "YOU"
	you_lbl.anchor_right = 0.5
	you_lbl.offset_top = TOP + 14;  you_lbl.offset_bottom = TOP + 56
	you_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	you_lbl.modulate = Color(1.0, 1.0, 1.0, 0.35)
	you_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(you_lbl)

	var opp_side_lbl := _lbl(32)
	opp_side_lbl.text = "OPPONENT"
	opp_side_lbl.anchor_left = 0.5;  opp_side_lbl.anchor_right = 1.0
	opp_side_lbl.offset_top = TOP + 14;  opp_side_lbl.offset_bottom = TOP + 56
	opp_side_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opp_side_lbl.modulate = Color(1.0, 1.0, 1.0, 0.35)
	opp_side_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(opp_side_lbl)

	# Names in top bar
	my_name_lbl = _lbl(44)
	my_name_lbl.anchor_right = 0.42
	my_name_lbl.offset_top = 0;  my_name_lbl.offset_bottom = TOP
	my_name_lbl.offset_left = 14
	my_name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(my_name_lbl)

	opp_name_lbl = _lbl(44)
	opp_name_lbl.anchor_left = 0.58;  opp_name_lbl.anchor_right = 1.0
	opp_name_lbl.offset_top = 0;  opp_name_lbl.offset_bottom = TOP
	opp_name_lbl.offset_right = -14
	opp_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	opp_name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(opp_name_lbl)

	# Scores (big, near center of top bar)
	my_score_lbl = _lbl(40)
	my_score_lbl.anchor_right = 0.5
	my_score_lbl.offset_top = 0;  my_score_lbl.offset_bottom = TOP
	my_score_lbl.offset_right = -24
	my_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	my_score_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(my_score_lbl)

	opp_score_lbl = _lbl(40)
	opp_score_lbl.anchor_left = 0.5;  opp_score_lbl.anchor_right = 1.0
	opp_score_lbl.offset_top = 0;  opp_score_lbl.offset_bottom = TOP
	opp_score_lbl.offset_left = 24
	opp_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	opp_score_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(opp_score_lbl)

	# Mode badge (top-right, tiny)
	mode_lbl = _lbl(13)
	mode_lbl.anchor_left = 1.0;  mode_lbl.anchor_right = 1.0
	mode_lbl.offset_left = -110; mode_lbl.offset_right = -8
	mode_lbl.offset_top = 4;     mode_lbl.offset_bottom = 26
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(mode_lbl)

	# RT labels at the bottom of each side
	my_rt_lbl = _lbl(20)
	my_rt_lbl.anchor_right = 0.5
	my_rt_lbl.anchor_top = 1.0;  my_rt_lbl.anchor_bottom = 1.0
	my_rt_lbl.offset_top = -60;  my_rt_lbl.offset_bottom = -10
	my_rt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	my_rt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(my_rt_lbl)

	opp_rt_lbl = _lbl(20)
	opp_rt_lbl.anchor_left = 0.5;  opp_rt_lbl.anchor_right = 1.0
	opp_rt_lbl.anchor_top = 1.0;   opp_rt_lbl.anchor_bottom = 1.0
	opp_rt_lbl.offset_top = -60;   opp_rt_lbl.offset_bottom = -10
	opp_rt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opp_rt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(opp_rt_lbl)

	# Ready-up labels (our side only, vertically centered in lower half)
	ready_lbl = _lbl(22)
	ready_lbl.anchor_right = 0.5
	ready_lbl.anchor_top = 0.72;  ready_lbl.anchor_bottom = 0.72
	ready_lbl.offset_top = 0;     ready_lbl.offset_bottom = 34
	ready_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_lbl.modulate = Color(0.85, 0.85, 0.85)
	ready_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ready_lbl.visible = false
	add_child(ready_lbl)

	countdown_lbl = _lbl(56)
	countdown_lbl.anchor_right = 0.5
	countdown_lbl.anchor_top = 0.5;    countdown_lbl.anchor_bottom = 0.5
	countdown_lbl.offset_top = -36;    countdown_lbl.offset_bottom = 36
	countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_lbl.visible = false
	add_child(countdown_lbl)

	# Intro overlay (full-screen, blocks input, hidden initially)
	intro_overlay = ColorRect.new()
	intro_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	intro_overlay.color = Color(0.12, 0.12, 0.12, 0.95)
	intro_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	intro_overlay.visible = false
	add_child(intro_overlay)

	intro_lbl = _lbl(60)
	intro_lbl.set_anchors_preset(Control.PRESET_CENTER)
	intro_lbl.offset_left = -480;  intro_lbl.offset_right  = 480
	intro_lbl.offset_top  = -60;   intro_lbl.offset_bottom = 60
	intro_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intro_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	intro_overlay.add_child(intro_lbl)

	# Match-end overlay (full-screen, hidden until match ends)
	end_overlay = Control.new()
	end_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_overlay.visible = false
	add_child(end_overlay)

	_end_left_dim = ColorRect.new()
	_end_left_dim.anchor_right = 0.5;  _end_left_dim.anchor_bottom = 1.0
	_end_left_dim.color = Color(0, 0, 0, 0)
	end_overlay.add_child(_end_left_dim)

	_end_right_dim = ColorRect.new()
	_end_right_dim.anchor_left = 0.5;   _end_right_dim.anchor_right  = 1.0
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
		if i > num_samples - 882:  # 20ms fade-out
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


func _lbl(sz: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_font_override("font", FONT)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	return l


# ── UI helpers ────────────────────────────────────────────────────────────────

func _refresh_names() -> void:
	my_name_lbl.text  = my_username
	opp_name_lbl.text = opponent_username

func _refresh_scores() -> void:
	my_score_lbl.text  = str(my_score)
	opp_score_lbl.text = str(opp_score)

func _set_mode_label() -> void:
	if is_auditory:
		mode_lbl.text = "AUDITORY"
		mode_lbl.add_theme_color_override("font_color", Color(0.72, 0.45, 1.0))
	elif current_mode == "practice":
		mode_lbl.text = "PRACTICE"
		mode_lbl.add_theme_color_override("font_color", Color(0.97, 0.68, 0.05))
	else:
		mode_lbl.text = "RANKED"
		mode_lbl.add_theme_color_override("font_color", Color(0.55, 0.82, 1.0))

func _fmt(v) -> String:
	return "%.1f ms" % float(v) if v != null else "—"

func _dismiss_intro() -> void:
	if is_instance_valid(intro_overlay):
		intro_overlay.visible = false


# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_round_prepare(round_num: int) -> void:
	Net.send_client_info()  # refresh Hz and hardware info every round
	state = State.WAITING
	countdown_timer.stop()
	ready_lbl.add_theme_font_size_override("font_size", 22)
	ready_lbl.visible     = false
	countdown_lbl.visible = false
	my_rt_lbl.text  = ""
	opp_rt_lbl.text = ""
	my_box.color  = COL_WAITING
	opp_box.color = COL_WAITING
	# Show "Name vs Name" intro before round 1 of every match (fresh and rematch)
	if round_num == 1:
		await _show_vs_intro()
		# extra 2s buffer so the boxes don't go live the instant the intro fades
		await get_tree().create_timer(2.0).timeout


func _show_vs_intro() -> void:
	intro_overlay.visible = true
	intro_lbl.text = "%s  VS  %s" % [my_username, opponent_username]
	await get_tree().create_timer(2.0).timeout
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
		my_box.color  = COL_GO
		opp_box.color = COL_GO


func _on_opponent_clicked(pre_click: bool) -> void:
	if state in [State.STIMULUS, State.AFTER_CLICK, State.WAITING]:
		if pre_click:
			opp_box.color   = COL_LOSE
			opp_rt_lbl.text = "Too early!"
		else:
			opp_box.color = COL_SENT


func _on_round_result(data: Dictionary) -> void:
	my_score  = data.get("your_score", my_score)
	opp_score = data.get("opponent_score", opp_score)
	var i_won: bool       = data.get("you_won_round", false)
	var opp_pre: bool     = data.get("opponent_pre_click", false)
	var i_cheated: bool   = data.get("you_cheated", false)
	var opp_cheated: bool = data.get("opponent_cheated", false)

	if i_cheated:
		my_box.color   = COL_LOSE
		my_rt_lbl.text = "CHEATER!"
	else:
		my_box.color = COL_WIN if i_won else COL_LOSE

	if opp_cheated:
		opp_box.color   = COL_LOSE
		opp_rt_lbl.text = "CHEATER!"
	elif opp_pre:
		opp_box.color   = COL_LOSE
		opp_rt_lbl.text = "Too early!"
	else:
		opp_box.color   = COL_LOSE if i_won else COL_WIN
		opp_rt_lbl.text = _fmt(data.get("opponent_rt_ms"))

	_refresh_scores()
	_enter_ready_up()


func _on_match_end(data: Dictionary) -> void:
	state = State.MATCH_END
	Net.last_match_result = {
		"won":         data.get("you_won", false),
		"final_score": data.get("final_score", ""),
		"opponent":    opponent_username,
		"my_score":    my_score,
		"opp_score":   opp_score,
		"mode":        data.get("mode", current_mode),
	}
	_show_end_overlay(data.get("you_won", false))
	end_timer.start()


func _go_to_results() -> void:
	get_tree().change_scene_to_file("res://scenes/results.tscn")


# ── Ready-up ──────────────────────────────────────────────────────────────────

func _enter_ready_up() -> void:
	state = State.READY_UP
	_readied  = false
	_countdown = 5
	ready_lbl.text     = "Click to ready up"
	ready_lbl.modulate = Color(0.85, 0.85, 0.85)
	ready_lbl.visible  = true
	countdown_lbl.text    = "5"
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


# ── Match-end overlay ─────────────────────────────────────────────────────────

func _show_end_overlay(i_won: bool) -> void:
	countdown_timer.stop()
	ready_lbl.visible     = false
	countdown_lbl.visible = false
	end_overlay.visible   = true
	if i_won:
		_end_left_dim.color  = Color(0, 0, 0, 0)
		_end_right_dim.color = Color(0, 0, 0, 0.65)
		_end_left_lbl.text      = "WINNER!"
		_end_left_lbl.modulate  = Color(0.3, 0.95, 0.45)
		_end_right_lbl.text     = "ELIMINATED"
		_end_right_lbl.modulate = Color(0.55, 0.55, 0.55)
	else:
		_end_left_dim.color  = Color(0, 0, 0, 0.65)
		_end_right_dim.color = Color(0, 0, 0, 0)
		_end_left_lbl.text      = "ELIMINATED"
		_end_left_lbl.modulate  = Color(0.55, 0.55, 0.55)
		_end_right_lbl.text     = "WINNER!"
		_end_right_lbl.modulate = Color(0.3, 0.95, 0.45)


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
		# Trim entries outside the 5s window when the buffer grows large
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
		# mouseup — compute click duration and report to server
		if _mouse_down_us > 0:
			_click_duration_ms = (Time.get_ticks_usec() - _mouse_down_us) / 1000.0
			Net.send_click_info(_click_duration_ms)
			_mouse_down_us = 0
		return

	# Ignore clicks while the intro overlay is showing
	if intro_overlay.visible:
		return

	# mousedown — record time for duration tracking
	_mouse_down_us = Time.get_ticks_usec()

	match state:
		State.STIMULUS:
			state = State.AFTER_CLICK
			var rt := (Time.get_ticks_usec() - t_stimulus_us) / 1000.0
			my_rt_lbl.text = "%.1f ms" % rt
			var _mpos := (event as InputEventMouseButton).position
			Net.send_click(rt, false, _mouse_dist_5s(), _time_since_move_ms(), _window_focused_at_stimulus, _mpos.x, _mpos.y, _pre_click_displacement_px())
			my_box.color = COL_SENT
		State.WAITING:
			var _mpos_pre := (event as InputEventMouseButton).position
			Net.send_click(0.0, true, _mouse_dist_5s(), _time_since_move_ms(), get_window().has_focus(), _mpos_pre.x, _mpos_pre.y, _pre_click_displacement_px())
			my_box.color = COL_LOSE
			ready_lbl.add_theme_font_size_override("font_size", 40)
			ready_lbl.text = "FAIL!"
			ready_lbl.modulate = Color(1.0, 0.35, 0.35)
			ready_lbl.visible = true
		State.READY_UP:
			if not _readied and my_box.get_global_rect().has_point(event.position):
				_readied = true
				Net.send_ready_up()
				ready_lbl.text     = "Ready!"
				ready_lbl.modulate = Color(0.3, 0.9, 0.4)
