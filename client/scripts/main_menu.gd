extends Control

enum BoxState { RED, GREEN, GRAY }

const STATS: Array[String] = ["avg_rt", "best_match_rt", "wins", "winrate"]
const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

const _BLOCKED := [
	"nigger","nigga","niga","niger","nigg",
	"faggot","fagot","faget","fagg",
	"retard","retarded",
	"kike","chink","spic","spick","wetback","gook","coon","beaner","zipperhead",
	"cunt",
	"fuck","fucker","fucking","fuk","fck",
	"shit","shyt","sht",
	"cock","cok","boner","penis","vagina",
	"pussy","puss",
	"bitch","biatch","btch",
	"asshole","ashole","asshol",
	"whore","slut","hoe",
	"rape","rapist","raping",
	"hitler","nazi","kkk",
	"pedophile","pedo","nonce",
]

@onready var quickplay_btn: Button = $NavArea/QuickPlayBtn
@onready var practice_btn: Button = $NavArea/PracticeBtn
@onready var private_btn: Button = $NavArea/PrivateRoomBtn
@onready var quit_btn: Button = $NavArea/QuitBtn
@onready var username_input: LineEdit = $UsernameDisplay

@onready var top_box: ColorRect = $ReactionArea/BoxRow/TopGroup/TopBox
@onready var top_time_label: Label = $ReactionArea/BoxRow/TopGroup/TopTimeLabel
@onready var bottom_box: ColorRect = $ReactionArea/BoxRow/BottomGroup/BottomBox
@onready var bottom_time_label: Label = $ReactionArea/BoxRow/BottomGroup/BottomTimeLabel
@onready var top_timer: Timer = $TopTimer
@onready var bottom_timer: Timer = $BottomTimer
var top_state: BoxState = BoxState.RED
var top_green_at: int = 0
var bottom_state: BoxState = BoxState.RED
var bottom_green_at: int = 0

@onready var stat_selector: OptionButton = $StatSelector
@onready var leaderboard_list: VBoxContainer = $LeaderboardScroll/LeaderboardList

var _btn_tweens: Dictionary = {}
var _btn_base_pos: Dictionary = {}

var _session_username_set: bool = false
var _pending_mode: String = ""
var _pending_scene: String = ""
var _popup_overlay: ColorRect = null
var _popup_input: LineEdit = null
var _popup_warning_lbl: Label = null


func _is_inappropriate(text: String) -> bool:
	# Normalise to catch basic leet-speak and spacing tricks
	var s := text.to_lower()
	s = s.replace("0", "o").replace("1", "i").replace("3", "e")
	s = s.replace("4", "a").replace("5", "s").replace("@", "a")
	s = s.replace("$", "s").replace("+", "t").replace("!", "i")
	# Strip non-alpha so "f.u.c.k" or "f_u_c_k" are caught
	var stripped := ""
	for ch in s:
		if ch >= "a" and ch <= "z":
			stripped += ch
	for word in _BLOCKED:
		if word in stripped:
			return true
	return false


func _ready() -> void:
	# Only pre-fill if a real username was already set
	if Net.username != "anon" and Net.username != "":
		username_input.text = Net.username
		_session_username_set = true
	else:
		username_input.text = ""
		username_input.placeholder_text = "type here..."

	quickplay_btn.pressed.connect(_on_quickplay)
	practice_btn.pressed.connect(_on_practice)
	private_btn.pressed.connect(_on_private)
	quit_btn.pressed.connect(get_tree().quit)
	username_input.text_submitted.connect(func(_t): username_input.release_focus())
	username_input.focus_exited.connect(_on_username_saved)

	for btn in [quickplay_btn, practice_btn, private_btn, quit_btn]:
		_setup_btn_hover(btn)

	_build_username_popup()

	top_timer.timeout.connect(_on_top_timer)
	bottom_timer.timeout.connect(_on_bottom_timer)
	_box_go_red(top_box, top_timer)
	_box_go_red(bottom_box, bottom_timer)

	stat_selector.add_item("Avg Reaction Time")
	stat_selector.add_item("Best Match Avg")
	stat_selector.add_item("Most Wins")
	stat_selector.add_item("Win Rate (≥2 matches)")
	stat_selector.item_selected.connect(_on_stat_selected)
	Net.leaderboard_data.connect(_on_leaderboard_data)
	if Net.player_id != "":
		_request_leaderboard()
	else:
		Net.hello_received.connect(_on_hello_received, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	if Net.leaderboard_data.is_connected(_on_leaderboard_data):
		Net.leaderboard_data.disconnect(_on_leaderboard_data)
	if Net.hello_received.is_connected(_on_hello_received):
		Net.hello_received.disconnect(_on_hello_received)


# ── Username popup ────────────────────────────────────────────────────────────

func _build_username_popup() -> void:
	_popup_overlay = ColorRect.new()
	_popup_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_overlay.color = Color(0.0, 0.0, 0.0, 0.68)
	_popup_overlay.visible = false
	_popup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_popup_overlay)

	var card := ColorRect.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -240; card.offset_right  = 240
	card.offset_top  = -155; card.offset_bottom = 155
	card.color = Color(0.97, 0.68, 0.05, 1)
	_popup_overlay.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 36; vbox.offset_right  = -36
	vbox.offset_top  = 26; vbox.offset_bottom = -26
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	card.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "PLAY AS:"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_override("font", FONT)
	lbl.add_theme_font_size_override("font_size", 36)
	lbl.add_theme_color_override("font_color", Color(0.14, 0.14, 0.14))
	vbox.add_child(lbl)

	_popup_input = LineEdit.new()
	_popup_input.placeholder_text = "enter name..."
	_popup_input.max_length = 32
	_popup_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup_input.add_theme_font_override("font", FONT)
	_popup_input.add_theme_font_size_override("font_size", 30)
	_popup_input.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color(0.18, 0.18, 0.18, 1)
	input_style.corner_radius_top_left    = 4
	input_style.corner_radius_top_right   = 4
	input_style.corner_radius_bottom_right = 4
	input_style.corner_radius_bottom_left  = 4
	input_style.content_margin_left  = 12.0
	input_style.content_margin_right = 12.0
	input_style.content_margin_top    = 8.0
	input_style.content_margin_bottom = 8.0
	_popup_input.add_theme_stylebox_override("normal", input_style)
	_popup_input.add_theme_stylebox_override("focus",  input_style)
	_popup_input.text_submitted.connect(_on_popup_confirm)
	vbox.add_child(_popup_input)

	var btn := Button.new()
	btn.text = "LET'S GO"
	btn.flat = true
	btn.add_theme_font_override("font", FONT)
	btn.add_theme_font_size_override("font_size", 40)
	btn.add_theme_color_override("font_color", Color(0.14, 0.14, 0.14))
	btn.add_theme_color_override("font_color_hover", Color(0.05, 0.05, 0.05))
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, empty)
	btn.pressed.connect(func(): _on_popup_confirm(_popup_input.text))
	vbox.add_child(btn)

	_popup_warning_lbl = Label.new()
	_popup_warning_lbl.text = "Name not allowed — try another"
	_popup_warning_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup_warning_lbl.add_theme_font_override("font", FONT)
	_popup_warning_lbl.add_theme_font_size_override("font_size", 18)
	_popup_warning_lbl.add_theme_color_override("font_color", Color(0.80, 0.10, 0.10, 1))
	_popup_warning_lbl.visible = false
	vbox.add_child(_popup_warning_lbl)


func _show_popup() -> void:
	_popup_overlay.visible = true
	_popup_input.text = ""
	_popup_input.grab_focus()


func _on_popup_confirm(text: String) -> void:
	var name := text.strip_edges()
	if name.length() < 2:
		return
	if _is_inappropriate(name):
		_popup_warning_lbl.visible = true
		return
	_popup_warning_lbl.visible = false
	Net.set_username(name)
	_session_username_set = true
	username_input.text = name
	_popup_overlay.visible = false
	_do_navigate(_pending_mode, _pending_scene)


# ── Navigation ────────────────────────────────────────────────────────────────

func _request_navigate(mode: String, scene: String) -> void:
	if _session_username_set:
		_do_navigate(mode, scene)
	else:
		_pending_mode = mode
		_pending_scene = scene
		_show_popup()


func _do_navigate(mode: String, scene: String) -> void:
	if mode != "private":
		Net.queue_mode = mode
	get_tree().change_scene_to_file(scene)


func _on_quickplay() -> void:
	_request_navigate("ranked", "res://scenes/matchmaking.tscn")


func _on_practice() -> void:
	_request_navigate("practice", "res://scenes/matchmaking.tscn")


func _on_private() -> void:
	_request_navigate("private", "res://scenes/private_lobby.tscn")


# ── Username header ───────────────────────────────────────────────────────────

func _on_username_saved() -> void:
	var new_name := username_input.text.strip_edges()
	if new_name.length() < 2:
		username_input.text = Net.username if (Net.username != "anon" and Net.username != "") else ""
		return
	if _is_inappropriate(new_name):
		username_input.text = Net.username if (Net.username != "anon" and Net.username != "") else ""
		username_input.placeholder_text = "⚠ Name not allowed"
		get_tree().create_timer(2.5).timeout.connect(
			func(): username_input.placeholder_text = "type here..."
		)
		return
	if new_name != Net.username:
		Net.set_username(new_name)
		_session_username_set = true


# ── Hover animations ──────────────────────────────────────────────────────────

func _setup_btn_hover(btn: Button) -> void:
	_btn_base_pos[btn] = btn.position
	btn.mouse_entered.connect(_on_btn_hover.bind(btn, true))
	btn.mouse_exited.connect(_on_btn_hover.bind(btn, false))


func _on_btn_hover(btn: Button, hovered: bool) -> void:
	if _btn_tweens.has(btn) and _btn_tweens[btn] != null:
		_btn_tweens[btn].kill()
	var tween := create_tween()
	_btn_tweens[btn] = tween
	var base: Vector2 = _btn_base_pos.get(btn, Vector2.ZERO)
	var target_pos: Vector2 = base + Vector2(8.0, -3.0) if hovered else base
	tween.tween_property(btn, "position", target_pos, 0.22) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# ── Leaderboard ───────────────────────────────────────────────────────────────

func _on_hello_received(_id: String) -> void:
	_request_leaderboard()


func _request_leaderboard() -> void:
	for child in leaderboard_list.get_children():
		child.queue_free()
	var loading := Label.new()
	loading.text = "Loading..."
	loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading.add_theme_font_size_override("font_size", 14)
	loading.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.8))
	leaderboard_list.add_child(loading)
	Net.request_leaderboard(STATS[stat_selector.selected])


func _on_stat_selected(_idx: int) -> void:
	_request_leaderboard()


func _on_leaderboard_data(data: Dictionary) -> void:
	for child in leaderboard_list.get_children():
		child.queue_free()
	var rows: Array = data.get("rows", [])
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "No data yet"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.8))
		leaderboard_list.add_child(empty)
		return
	var stat: String = data.get("stat", "avg_rt")
	for i in rows.size():
		var row: Dictionary = rows[i]
		var entry := HBoxContainer.new()
		var name_lbl := Label.new()
		name_lbl.text = "#%d  %s" % [i + 1, row.get("username", "?")]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_override("font", FONT)
		name_lbl.add_theme_font_size_override("font_size", 17)
		name_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
		var val_lbl := Label.new()
		val_lbl.text = _format_stat(stat, row.get("value", 0.0))
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_lbl.add_theme_font_override("font", FONT)
		val_lbl.add_theme_font_size_override("font_size", 17)
		val_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.80))
		entry.add_child(name_lbl)
		entry.add_child(val_lbl)
		leaderboard_list.add_child(entry)


func _format_stat(stat: String, value: float) -> String:
	match stat:
		"avg_rt", "best_match_rt":
			return "%.1f ms" % value
		"wins":
			return "%d wins" % int(value)
		"winrate":
			return "%.1f%%" % value
	return "%.1f" % value


# ── Training box helpers ──────────────────────────────────────────────────────

func _box_go_red(box: ColorRect, timer: Timer) -> void:
	box.color = Color(0.65, 0.1, 0.1)
	timer.wait_time = randf_range(2.0, 6.0)
	timer.start()


func _box_go_green(box: ColorRect, timer: Timer) -> void:
	box.color = Color(0.2, 0.85, 0.3)
	timer.wait_time = 5.0
	timer.start()


func _box_go_gray(box: ColorRect, timer: Timer) -> void:
	box.color = Color(0.25, 0.25, 0.3)
	timer.wait_time = 2.0
	timer.start()


func _on_top_timer() -> void:
	match top_state:
		BoxState.RED:
			top_state = BoxState.GREEN
			top_green_at = Time.get_ticks_usec()
			_box_go_green(top_box, top_timer)
		BoxState.GREEN:
			top_state = BoxState.GRAY
			_box_go_gray(top_box, top_timer)
		BoxState.GRAY:
			top_state = BoxState.RED
			_box_go_red(top_box, top_timer)


func _on_bottom_timer() -> void:
	match bottom_state:
		BoxState.RED:
			bottom_state = BoxState.GREEN
			bottom_green_at = Time.get_ticks_usec()
			_box_go_green(bottom_box, bottom_timer)
		BoxState.GREEN:
			bottom_state = BoxState.GRAY
			_box_go_gray(bottom_box, bottom_timer)
		BoxState.GRAY:
			bottom_state = BoxState.RED
			_box_go_red(bottom_box, bottom_timer)


func _input(event: InputEvent) -> void:
	# Escape dismisses popup without navigating
	if _popup_overlay and _popup_overlay.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_popup_overlay.visible = false
			get_viewport().set_input_as_handled()
		return

	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var pos: Vector2 = event.position
	if top_box.get_global_rect().has_point(pos):
		match top_state:
			BoxState.GREEN:
				var rt := (Time.get_ticks_usec() - top_green_at) / 1000.0
				top_state = BoxState.GRAY
				_box_go_gray(top_box, top_timer)
				top_time_label.text = "%.1f ms" % rt
				Net.send_calibration(rt, "left")
			BoxState.RED:
				top_state = BoxState.GRAY
				_box_go_gray(top_box, top_timer)
				top_time_label.text = "Too early!"
	elif bottom_box.get_global_rect().has_point(pos):
		match bottom_state:
			BoxState.GREEN:
				var rt := (Time.get_ticks_usec() - bottom_green_at) / 1000.0
				bottom_state = BoxState.GRAY
				_box_go_gray(bottom_box, bottom_timer)
				bottom_time_label.text = "%.1f ms" % rt
				Net.send_calibration(rt, "right")
			BoxState.RED:
				bottom_state = BoxState.GRAY
				_box_go_gray(bottom_box, bottom_timer)
				bottom_time_label.text = "Too early!"
