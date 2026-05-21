extends Control

enum BoxState { RED, GREEN, GRAY }

const STATS: Array[String] = ["avg_rt", "best_match_rt", "wins", "winrate", "cheaters"]
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
@onready var auditory_btn: Button = $NavArea/AuditoryBtn
@onready var private_btn: Button = $NavArea/PrivateRoomBtn
@onready var team_quickplay_btn: Button = $NavArea/TeamQuickPlayBtn
@onready var ffa_btn: Button = $NavArea/FFABtn
@onready var recent_matches_btn: Button = $NavArea/RecentMatchesBtn
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

var _room_overlay: ColorRect = null
var _join_panel: Control = null
var _join_input: LineEdit = null
var _join_error_lbl: Label = null

var _lobby_overlay: ColorRect = null
var _lobby_code_lbl: Label = null
var _lobby_players_vbox: VBoxContainer = null
var _lobby_start_btn: Button = null
var _lobby_waiting_lbl: Label = null
var _lobby_mode_btns: Dictionary = {}
var _lobby_cur_mode: String = "1v1"
var _lobby_cue_btns: Dictionary = {}
var _lobby_cur_cue: String = "visual"
var _lobby_leader_id: String = ""


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
	auditory_btn.pressed.connect(_on_auditory)
	private_btn.pressed.connect(_on_private)
	team_quickplay_btn.pressed.connect(_on_team_quickplay)
	ffa_btn.pressed.connect(_on_ffa)
	recent_matches_btn.pressed.connect(_on_recent_matches)
	quit_btn.pressed.connect(get_tree().quit)
	username_input.text_submitted.connect(func(_t): username_input.release_focus())
	username_input.focus_exited.connect(_on_username_saved)

	for btn in [quickplay_btn, auditory_btn, private_btn, team_quickplay_btn, ffa_btn, recent_matches_btn, quit_btn]:
		_setup_btn_hover(btn)

	_build_username_popup()
	_build_room_popup()

	top_timer.timeout.connect(_on_top_timer)
	bottom_timer.timeout.connect(_on_bottom_timer)
	_box_go_red(top_box, top_timer)
	_box_go_red(bottom_box, bottom_timer)

	stat_selector.add_item("Avg Reaction Time")
	stat_selector.add_item("Best Match Avg")
	stat_selector.add_item("Most Wins")
	stat_selector.add_item("Win Rate (≥5 matches)")
	stat_selector.add_item("Cheaters")
	stat_selector.select(1)
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
	if Net.private_lobby_update.is_connected(_on_lobby_update):
		Net.private_lobby_update.disconnect(_on_lobby_update)
	if Net.private_join_error.is_connected(_on_lobby_join_error):
		Net.private_join_error.disconnect(_on_lobby_join_error)
	if Net.private_kicked.is_connected(_on_lobby_kicked):
		Net.private_kicked.disconnect(_on_lobby_kicked)


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
	if _pending_mode == "private":
		_on_private()
	else:
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


func _on_team_quickplay() -> void:
	_request_navigate("team", "res://scenes/matchmaking.tscn")


func _on_auditory() -> void:
	_request_navigate("auditory", "res://scenes/matchmaking.tscn")


func _on_ffa() -> void:
	_request_navigate("ffa", "res://scenes/matchmaking.tscn")


func _on_private() -> void:
	if not _session_username_set:
		_pending_mode = "private"
		_pending_scene = ""
		_show_popup()
		return
	_room_overlay.visible = true
	_join_panel.visible = false
	_join_error_lbl.visible = false


func _on_recent_matches() -> void:
	get_tree().change_scene_to_file("res://scenes/recent_matches.tscn")


# ── Private room / lobby ──────────────────────────────────────────────────────

func _build_room_popup() -> void:
	_room_overlay = ColorRect.new()
	_room_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_room_overlay.color = Color(0.0, 0.0, 0.0, 0.72)
	_room_overlay.visible = false
	_room_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_room_overlay)

	var card := ColorRect.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -230; card.offset_right  =  230
	card.offset_top  = -220; card.offset_bottom =  220
	card.color = Color(0.12, 0.12, 0.15)
	_room_overlay.add_child(card)

	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	close_btn.offset_left = -42; close_btn.offset_right  = -10
	close_btn.offset_top  =  10; close_btn.offset_bottom =  38
	close_btn.flat = true
	close_btn.add_theme_font_override("font", FONT)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	close_btn.pressed.connect(func(): _room_overlay.visible = false)
	card.add_child(close_btn)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 36; vbox.offset_right  = -36
	vbox.offset_top  = 28; vbox.offset_bottom = -28
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	card.add_child(vbox)

	var title := Label.new()
	title.text = "PRIVATE ROOM"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", FONT)
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color(0.97, 0.68, 0.05))
	vbox.add_child(title)

	var create_btn := Button.new()
	create_btn.text = "CREATE ROOM"
	create_btn.add_theme_font_override("font", FONT)
	create_btn.add_theme_font_size_override("font_size", 30)
	create_btn.add_theme_color_override("font_color", Color(0.10, 0.10, 0.13))
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.97, 0.68, 0.05)
	cs.corner_radius_top_left = 6; cs.corner_radius_top_right = 6
	cs.corner_radius_bottom_right = 6; cs.corner_radius_bottom_left = 6
	cs.content_margin_left = 24; cs.content_margin_right = 24
	cs.content_margin_top = 10; cs.content_margin_bottom = 10
	for s in ["normal", "hover", "pressed", "focus"]:
		create_btn.add_theme_stylebox_override(s, cs)
	create_btn.pressed.connect(_on_room_create)
	vbox.add_child(create_btn)

	var or_lbl := Label.new()
	or_lbl.text = "— or —"
	or_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	or_lbl.add_theme_font_size_override("font_size", 14)
	or_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(or_lbl)

	var join_toggle_btn := Button.new()
	join_toggle_btn.text = "JOIN ROOM"
	join_toggle_btn.add_theme_font_override("font", FONT)
	join_toggle_btn.add_theme_font_size_override("font_size", 26)
	join_toggle_btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	var jts := StyleBoxFlat.new()
	jts.bg_color = Color(0.22, 0.22, 0.28)
	jts.corner_radius_top_left = 6; jts.corner_radius_top_right = 6
	jts.corner_radius_bottom_right = 6; jts.corner_radius_bottom_left = 6
	jts.content_margin_left = 24; jts.content_margin_right = 24
	jts.content_margin_top = 10; jts.content_margin_bottom = 10
	for s in ["normal", "hover", "pressed", "focus"]:
		join_toggle_btn.add_theme_stylebox_override(s, jts)
	join_toggle_btn.pressed.connect(func(): _join_panel.visible = true; _join_input.grab_focus())
	vbox.add_child(join_toggle_btn)

	# join input panel (hidden until JOIN ROOM is clicked)
	_join_panel = VBoxContainer.new()
	_join_panel.visible = false
	_join_panel.add_theme_constant_override("separation", 8)
	vbox.add_child(_join_panel)

	var code_lbl := Label.new()
	code_lbl.text = "Enter 6-digit code:"
	code_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_lbl.add_theme_font_size_override("font_size", 15)
	code_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_join_panel.add_child(code_lbl)

	var input_row := HBoxContainer.new()
	input_row.alignment = BoxContainer.ALIGNMENT_CENTER
	input_row.add_theme_constant_override("separation", 8)
	_join_panel.add_child(input_row)

	_join_input = LineEdit.new()
	_join_input.placeholder_text = "XXXXXX"
	_join_input.max_length = 6
	_join_input.custom_minimum_size = Vector2(130, 0)
	_join_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_input.add_theme_font_override("font", FONT)
	_join_input.add_theme_font_size_override("font_size", 28)
	_join_input.add_theme_color_override("font_color", Color(1, 1, 1))
	var ji_s := StyleBoxFlat.new()
	ji_s.bg_color = Color(0.18, 0.18, 0.22)
	ji_s.corner_radius_top_left = 4; ji_s.corner_radius_top_right = 4
	ji_s.corner_radius_bottom_right = 4; ji_s.corner_radius_bottom_left = 4
	ji_s.content_margin_left = 8; ji_s.content_margin_right = 8
	ji_s.content_margin_top = 6; ji_s.content_margin_bottom = 6
	_join_input.add_theme_stylebox_override("normal", ji_s)
	_join_input.add_theme_stylebox_override("focus", ji_s)
	_join_input.text_submitted.connect(func(_t): _on_room_join())
	input_row.add_child(_join_input)

	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.add_theme_font_override("font", FONT)
	join_btn.add_theme_font_size_override("font_size", 24)
	join_btn.add_theme_color_override("font_color", Color(0.10, 0.10, 0.13))
	var jb_s := StyleBoxFlat.new()
	jb_s.bg_color = Color(0.97, 0.68, 0.05)
	jb_s.corner_radius_top_left = 4; jb_s.corner_radius_top_right = 4
	jb_s.corner_radius_bottom_right = 4; jb_s.corner_radius_bottom_left = 4
	jb_s.content_margin_left = 16; jb_s.content_margin_right = 16
	jb_s.content_margin_top = 6; jb_s.content_margin_bottom = 6
	for s in ["normal", "hover", "pressed", "focus"]:
		join_btn.add_theme_stylebox_override(s, jb_s)
	join_btn.pressed.connect(_on_room_join)
	input_row.add_child(join_btn)

	_join_error_lbl = Label.new()
	_join_error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_error_lbl.add_theme_font_override("font", FONT)
	_join_error_lbl.add_theme_font_size_override("font_size", 18)
	_join_error_lbl.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2))
	_join_error_lbl.visible = false
	_join_panel.add_child(_join_error_lbl)

	_build_lobby_overlay()

	Net.private_lobby_update.connect(_on_lobby_update)
	Net.private_join_error.connect(_on_lobby_join_error)
	Net.private_kicked.connect(_on_lobby_kicked)
	Net.match_start.connect(_on_lobby_game_start.bind("res://scenes/game.tscn"))
	Net.team_match_start.connect(_on_lobby_game_start.bind("res://scenes/game_2v2.tscn"))
	Net.ffa_match_start.connect(_on_lobby_game_start.bind("res://scenes/game_ffa.tscn"))


func _build_lobby_overlay() -> void:
	_lobby_overlay = ColorRect.new()
	_lobby_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby_overlay.color = Color(0.08, 0.08, 0.10)
	_lobby_overlay.visible = false
	_lobby_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_lobby_overlay)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 50; root.offset_right  = -50
	root.offset_top  = 36; root.offset_bottom = -36
	root.add_theme_constant_override("separation", 24)
	_lobby_overlay.add_child(root)

	# header row
	var header := HBoxContainer.new()
	root.add_child(header)

	var title_lbl := Label.new()
	title_lbl.text = "PRIVATE LOBBY"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_override("font", FONT)
	title_lbl.add_theme_font_size_override("font_size", 38)
	title_lbl.add_theme_color_override("font_color", Color(0.97, 0.68, 0.05))
	header.add_child(title_lbl)

	_lobby_code_lbl = Label.new()
	_lobby_code_lbl.text = "CODE: ------"
	_lobby_code_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_code_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_code_lbl.add_theme_font_override("font", FONT)
	_lobby_code_lbl.add_theme_font_size_override("font_size", 38)
	_lobby_code_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	header.add_child(_lobby_code_lbl)

	var leave_btn := Button.new()
	leave_btn.text = "LEAVE"
	leave_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	leave_btn.add_theme_font_override("font", FONT)
	leave_btn.add_theme_font_size_override("font_size", 24)
	leave_btn.add_theme_color_override("font_color", Color(0.85, 0.28, 0.28))
	var lv_e := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus"]:
		leave_btn.add_theme_stylebox_override(s, lv_e)
	leave_btn.pressed.connect(_on_lobby_leave)
	header.add_child(leave_btn)

	# content row: mode selector (left) + player list (right)
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 40)
	root.add_child(content)

	var mode_vbox := VBoxContainer.new()
	mode_vbox.custom_minimum_size = Vector2(250, 0)
	mode_vbox.add_theme_constant_override("separation", 14)
	content.add_child(mode_vbox)

	var mode_hdr := Label.new()
	mode_hdr.text = "GAME MODE"
	mode_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_hdr.add_theme_font_override("font", FONT)
	mode_hdr.add_theme_font_size_override("font_size", 26)
	mode_hdr.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	mode_vbox.add_child(mode_hdr)

	for info: Array in [["1V1", "1v1", "2 players"], ["2V2", "2v2", "4 players"], ["FFA", "ffa", "3-4 players"]]:
		var mb := Button.new()
		mb.text = "%s  (%s)" % [info[0], info[2]]
		mb.add_theme_font_override("font", FONT)
		mb.add_theme_font_size_override("font_size", 26)
		var mode_key: String = info[1]
		_lobby_mode_btns[mode_key] = mb
		mb.pressed.connect(func(): _on_lobby_mode_select(mode_key))
		mode_vbox.add_child(mb)

	var cue_hdr := Label.new()
	cue_hdr.text = "REACTION CUE"
	cue_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cue_hdr.add_theme_font_override("font", FONT)
	cue_hdr.add_theme_font_size_override("font_size", 26)
	cue_hdr.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	mode_vbox.add_child(cue_hdr)

	for info: Array in [["VISUAL", "visual"], ["AUDITORY", "auditory"]]:
		var cb := Button.new()
		cb.text = info[0]
		cb.add_theme_font_override("font", FONT)
		cb.add_theme_font_size_override("font_size", 26)
		var cue_key: String = info[1]
		_lobby_cue_btns[cue_key] = cb
		cb.pressed.connect(func(): _on_lobby_cue_select(cue_key))
		mode_vbox.add_child(cb)

	var players_vbox := VBoxContainer.new()
	players_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	players_vbox.add_theme_constant_override("separation", 10)
	content.add_child(players_vbox)

	var players_hdr := Label.new()
	players_hdr.text = "PLAYERS"
	players_hdr.add_theme_font_override("font", FONT)
	players_hdr.add_theme_font_size_override("font_size", 26)
	players_hdr.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	players_vbox.add_child(players_hdr)

	_lobby_players_vbox = VBoxContainer.new()
	_lobby_players_vbox.add_theme_constant_override("separation", 8)
	players_vbox.add_child(_lobby_players_vbox)

	# footer
	_lobby_start_btn = Button.new()
	_lobby_start_btn.text = "START GAME"
	_lobby_start_btn.add_theme_font_override("font", FONT)
	_lobby_start_btn.add_theme_font_size_override("font_size", 42)
	_lobby_start_btn.add_theme_color_override("font_color", Color(0.10, 0.10, 0.12))
	var ss := StyleBoxFlat.new()
	ss.bg_color = Color(0.97, 0.68, 0.05)
	ss.corner_radius_top_left = 8; ss.corner_radius_top_right = 8
	ss.corner_radius_bottom_right = 8; ss.corner_radius_bottom_left = 8
	ss.content_margin_left = 40; ss.content_margin_right = 40
	ss.content_margin_top = 14; ss.content_margin_bottom = 14
	for s in ["normal", "hover", "pressed", "focus"]:
		_lobby_start_btn.add_theme_stylebox_override(s, ss)
	var sd := StyleBoxFlat.new()
	sd.bg_color = Color(0.45, 0.32, 0.02)
	sd.corner_radius_top_left = 8; sd.corner_radius_top_right = 8
	sd.corner_radius_bottom_right = 8; sd.corner_radius_bottom_left = 8
	sd.content_margin_left = 40; sd.content_margin_right = 40
	sd.content_margin_top = 14; sd.content_margin_bottom = 14
	_lobby_start_btn.add_theme_stylebox_override("disabled", sd)
	_lobby_start_btn.visible = false
	_lobby_start_btn.pressed.connect(func(): Net.private_start())
	root.add_child(_lobby_start_btn)

	_lobby_waiting_lbl = Label.new()
	_lobby_waiting_lbl.text = "Waiting for leader to start..."
	_lobby_waiting_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_waiting_lbl.add_theme_font_override("font", FONT)
	_lobby_waiting_lbl.add_theme_font_size_override("font_size", 24)
	_lobby_waiting_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	root.add_child(_lobby_waiting_lbl)


func _on_room_create() -> void:
	Net.private_create()


func _on_room_join() -> void:
	var code := _join_input.text.strip_edges().to_upper()
	if code.length() != 6:
		return
	_join_error_lbl.visible = false
	Net.private_join(code)


func _on_lobby_join_error(reason: String) -> void:
	if not (_room_overlay and _room_overlay.visible):
		return
	_join_error_lbl.text = reason if reason != "" else "Could not join room"
	_join_error_lbl.visible = true


func _on_lobby_update(data: Dictionary) -> void:
	var code: String    = str(data.get("code", "------"))
	var players: Array  = data.get("players", [])
	var leader_id: String = str(data.get("leader_id", ""))
	var mode: String    = str(data.get("mode", "1v1"))
	var cue: String     = str(data.get("cue", "visual"))
	_lobby_leader_id = leader_id
	_lobby_cur_mode  = mode
	_lobby_cur_cue   = cue

	if not _lobby_overlay.visible:
		_room_overlay.visible = false
		_lobby_overlay.visible = true

	_lobby_code_lbl.text = "CODE: %s" % code

	for child in _lobby_players_vbox.get_children():
		child.queue_free()
	var is_leader := (Net.player_id == leader_id)
	for p: Dictionary in players:
		var pid: String   = str(p.get("id", ""))
		var pname: String = str(p.get("username", "?"))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var star := Label.new()
		star.text = "*" if pid == leader_id else " "
		star.custom_minimum_size = Vector2(20, 0)
		star.add_theme_font_override("font", FONT)
		star.add_theme_font_size_override("font_size", 22)
		star.add_theme_color_override("font_color", Color(0.97, 0.68, 0.05))
		row.add_child(star)

		var name_lbl := Label.new()
		name_lbl.text = pname
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_override("font", FONT)
		name_lbl.add_theme_font_size_override("font_size", 24)
		name_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
		row.add_child(name_lbl)

		if is_leader and pid != Net.player_id:
			var kick_btn := Button.new()
			kick_btn.text = "KICK"
			kick_btn.add_theme_font_override("font", FONT)
			kick_btn.add_theme_font_size_override("font_size", 18)
			kick_btn.add_theme_color_override("font_color", Color(0.85, 0.28, 0.28))
			var ke := StyleBoxEmpty.new()
			for s in ["normal", "hover", "pressed", "focus"]:
				kick_btn.add_theme_stylebox_override(s, ke)
			kick_btn.pressed.connect(func(): Net.private_kick(pid))
			row.add_child(kick_btn)

		_lobby_players_vbox.add_child(row)

	# mode button styling
	for mkey: String in _lobby_mode_btns:
		var mb: Button = _lobby_mode_btns[mkey]
		mb.disabled = not is_leader
		var active := (mkey == mode)
		var ms := StyleBoxFlat.new()
		ms.bg_color = Color(0.97, 0.68, 0.05) if active else Color(0.20, 0.20, 0.26)
		ms.corner_radius_top_left = 6; ms.corner_radius_top_right = 6
		ms.corner_radius_bottom_right = 6; ms.corner_radius_bottom_left = 6
		ms.content_margin_left = 14; ms.content_margin_right = 14
		ms.content_margin_top = 10; ms.content_margin_bottom = 10
		for s in ["normal", "hover", "pressed", "focus", "disabled"]:
			mb.add_theme_stylebox_override(s, ms)
		mb.add_theme_color_override("font_color",
			Color(0.10, 0.10, 0.12) if active else Color(0.88, 0.88, 0.88))

	for ckey: String in _lobby_cue_btns:
		var cb: Button = _lobby_cue_btns[ckey]
		cb.disabled = not is_leader
		var cue_active := (ckey == cue)
		var cs := StyleBoxFlat.new()
		cs.bg_color = Color(0.72, 0.45, 1.0) if cue_active else Color(0.20, 0.20, 0.26)
		cs.corner_radius_top_left = 6; cs.corner_radius_top_right = 6
		cs.corner_radius_bottom_right = 6; cs.corner_radius_bottom_left = 6
		cs.content_margin_left = 14; cs.content_margin_right = 14
		cs.content_margin_top = 10; cs.content_margin_bottom = 10
		for s in ["normal", "hover", "pressed", "focus", "disabled"]:
			cb.add_theme_stylebox_override(s, cs)
		cb.add_theme_color_override("font_color",
			Color(0.10, 0.10, 0.12) if cue_active else Color(0.88, 0.88, 0.88))

	var n := players.size()
	var can_start: bool = (
		(n == 2 and mode == "1v1") or
		(n == 4 and mode == "2v2") or
		(n >= 3 and mode == "ffa")
	)
	_lobby_start_btn.visible  = is_leader
	_lobby_start_btn.disabled = not can_start
	_lobby_waiting_lbl.visible = not is_leader


func _on_lobby_mode_select(mode: String) -> void:
	if Net.player_id != _lobby_leader_id:
		return
	Net.private_set_mode(mode)


func _on_lobby_cue_select(cue: String) -> void:
	if Net.player_id != _lobby_leader_id:
		return
	Net.private_set_cue(cue)


func _on_lobby_leave() -> void:
	Net.private_leave()
	_lobby_overlay.visible = false


func _on_lobby_kicked() -> void:
	_lobby_overlay.visible = false
	_room_overlay.visible  = false


func _on_lobby_game_start(_data: Dictionary, scene: String) -> void:
	if _lobby_overlay == null or not _lobby_overlay.visible:
		return
	_lobby_overlay.visible = false
	get_tree().change_scene_to_file(scene)


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
		if stat == "winrate" and row.has("wins"):
			val_lbl.text = "%.1f%%  %d-%d" % [row.get("value", 0.0), row.get("wins", 0), row.get("losses", 0)]
		else:
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
		"cheaters":
			return "%d flags" % int(value)
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
	if _popup_overlay and _popup_overlay.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_popup_overlay.visible = false
			get_viewport().set_input_as_handled()
		return
	if _room_overlay and _room_overlay.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_room_overlay.visible = false
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
