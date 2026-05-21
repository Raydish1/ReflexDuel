extends Control
# scripts/results_2v2.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

@onready var result_label: Label        = $VBox/ResultLabel
@onready var score_label: Label         = $VBox/ScoreLabel
@onready var rematch_btn: Button        = $VBox/RematchButton
@onready var rematch_status_label: Label = $VBox/RematchStatus
@onready var menu_btn: Button           = $VBox/MenuButton

var _rematching := false


func _ready() -> void:
	var result: Dictionary = Net.last_team_match_result
	var won: bool      = result.get("won", false)
	var is_tie: bool   = result.get("is_tie", false)
	var my_team: int   = result.get("my_team", 1)
	var t1_names: Array = result.get("team1_names", ["?", "?"])
	var t2_names: Array = result.get("team2_names", ["?", "?"])
	var t1_score: int  = result.get("t1_score", 0)
	var t2_score: int  = result.get("t2_score", 0)
	var my_score  := t1_score if my_team == 1 else t2_score
	var opp_score := t2_score if my_team == 1 else t1_score
	var my_names  := t1_names if my_team == 1 else t2_names
	var opp_names := t2_names if my_team == 1 else t1_names

	if is_tie:
		result_label.text = "TIE"
		result_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	elif won:
		result_label.text = "YOU WON"
		result_label.add_theme_color_override("font_color", Color(0.12, 0.80, 0.30))
	else:
		result_label.text = "YOU LOST"
		result_label.add_theme_color_override("font_color", Color(0.78, 0.10, 0.10))

	var mode_lbl := Label.new()
	mode_lbl.text = "2V2"
	mode_lbl.add_theme_color_override("font_color", Color(0.28, 0.28, 0.28))
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_lbl.add_theme_font_override("font", FONT)
	mode_lbl.add_theme_font_size_override("font_size", 26)
	$VBox.add_child(mode_lbl)
	$VBox.move_child(mode_lbl, 0)

	score_label.text = "%s & %s  vs  %s & %s   final: %d — %d" % [
		my_names[0], my_names[1],
		opp_names[0], opp_names[1],
		my_score, opp_score,
	]

	rematch_btn.pressed.connect(_on_rematch)
	menu_btn.pressed.connect(_on_menu)
	Net.rematch_status.connect(_on_rematch_status)
	Net.rematch_go.connect(_on_rematch_go)
	Net.opponent_left.connect(_on_opponent_left)
	Net.team_match_start.connect(_on_team_match_start)


func _exit_tree() -> void:
	if not _rematching:
		Net.send_rematch_cancel()
	if Net.rematch_status.is_connected(_on_rematch_status):
		Net.rematch_status.disconnect(_on_rematch_status)
	if Net.rematch_go.is_connected(_on_rematch_go):
		Net.rematch_go.disconnect(_on_rematch_go)
	if Net.opponent_left.is_connected(_on_opponent_left):
		Net.opponent_left.disconnect(_on_opponent_left)
	if Net.team_match_start.is_connected(_on_team_match_start):
		Net.team_match_start.disconnect(_on_team_match_start)


func _on_rematch() -> void:
	rematch_btn.disabled = true
	rematch_status_label.text = "Waiting for all players..."
	Net.send_rematch_vote()


func _on_rematch_status(votes: int) -> void:
	rematch_btn.text = "REMATCH (%d/4)" % votes
	if votes > 0 and not rematch_btn.disabled:
		rematch_status_label.text = "%d / 4 players ready" % votes


func _on_rematch_go() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "Starting..."
	rematch_status_label.text = ""


func _on_opponent_left() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "A player left"
	rematch_status_label.text = ""


func _on_team_match_start(_data: Dictionary) -> void:
	_rematching = true
	get_tree().change_scene_to_file("res://scenes/game_2v2.tscn")


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
