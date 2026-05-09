extends Control
# scripts/main_menu.gd

enum BoxState { RED, GREEN, GRAY }

const STATS: Array[String] = ["avg_rt", "best_match_rt", "wins", "winrate"]

@onready var quickplay_btn: Button = $VBox/QuickplayButton
@onready var private_btn: Button = $VBox/PrivateRoomButton
@onready var quit_btn: Button = $VBox/QuitButton
var practice_btn: Button
@onready var username_input: LineEdit = $VBox/UsernameRow/UsernameInput

@onready var top_box: ColorRect = $LeftPanel/TopGroup/TopBox
@onready var top_time_label: Label = $LeftPanel/TopGroup/TopTimeLabel
@onready var bottom_box: ColorRect = $LeftPanel/BottomGroup/BottomBox
@onready var bottom_time_label: Label = $LeftPanel/BottomGroup/BottomTimeLabel
@onready var top_timer: Timer = $TopTimer
@onready var bottom_timer: Timer = $BottomTimer
var top_state: BoxState = BoxState.RED
var top_green_at: int = 0
var bottom_state: BoxState = BoxState.RED
var bottom_green_at: int = 0

@onready var stat_selector: OptionButton = $RightPanel/StatSelector
@onready var leaderboard_list: VBoxContainer = $RightPanel/LeaderboardList


func _ready() -> void:
	username_input.text = Net.username
	quickplay_btn.pressed.connect(_on_quickplay)
	private_btn.pressed.connect(_on_private)
	quit_btn.pressed.connect(get_tree().quit)

	practice_btn = Button.new()
	practice_btn.text = "Practice"
	practice_btn.add_theme_color_override("font_color", Color(1.0, 0.65, 0.0))
	quickplay_btn.get_parent().add_child(practice_btn)
	quickplay_btn.get_parent().move_child(practice_btn, quickplay_btn.get_index() + 1)
	practice_btn.pressed.connect(_on_practice)
	username_input.text_submitted.connect(func(_t): username_input.release_focus())
	username_input.focus_exited.connect(_on_username_saved)

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


func _on_username_saved() -> void:
	var new_name := username_input.text.strip_edges()
	if new_name.length() < 2:
		username_input.text = Net.username
		return
	if new_name != Net.username:
		Net.set_username(new_name)


func _on_quickplay() -> void:
	Net.queue_mode = "ranked"
	get_tree().change_scene_to_file("res://scenes/matchmaking.tscn")


func _on_practice() -> void:
	Net.queue_mode = "practice"
	get_tree().change_scene_to_file("res://scenes/matchmaking.tscn")


func _on_private() -> void:
	get_tree().change_scene_to_file("res://scenes/private_lobby.tscn")


# ── Leaderboard ───────────────────────────────────────────────────────────────

func _on_hello_received(_id: String) -> void:
	_request_leaderboard()


func _request_leaderboard() -> void:
	for child in leaderboard_list.get_children():
		child.queue_free()
	var loading := Label.new()
	loading.text = "Loading..."
	loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading.add_theme_font_size_override("font_size", 16)
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
		empty.add_theme_font_size_override("font_size", 16)
		leaderboard_list.add_child(empty)
		return
	var stat: String = data.get("stat", "avg_rt")
	for i in rows.size():
		var row: Dictionary = rows[i]
		var entry := HBoxContainer.new()
		var name_lbl := Label.new()
		name_lbl.text = "#%d  %s" % [i + 1, row.get("username", "?")]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 16)
		var val_lbl := Label.new()
		val_lbl.text = _format_stat(stat, row.get("value", 0.0))
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_lbl.add_theme_font_size_override("font_size", 16)
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
