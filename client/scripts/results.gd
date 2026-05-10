extends Control
# scripts/results.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

@onready var result_label: Label = $VBox/ResultLabel
@onready var score_label: Label = $VBox/ScoreLabel
@onready var rematch_btn: Button = $VBox/RematchButton
@onready var rematch_status_label: Label = $VBox/RematchStatus
@onready var menu_btn: Button = $VBox/MenuButton

var _rematching := false


func _ready() -> void:
	var result: Dictionary = Net.last_match_result
	var won: bool = result.get("won", false)
	var mode: String = result.get("mode", "ranked")

	result_label.text = "YOU WON" if won else "YOU LOST"
	result_label.add_theme_color_override("font_color", Color(0.12, 0.80, 0.30) if won else Color(0.78, 0.10, 0.10))

	var mode_lbl := Label.new()
	mode_lbl.text = "PRACTICE MODE" if mode == "practice" else "RANKED"
	mode_lbl.add_theme_color_override("font_color", Color(0.28, 0.28, 0.28))
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_lbl.add_theme_font_override("font", FONT)
	mode_lbl.add_theme_font_size_override("font_size", 26)
	$VBox.add_child(mode_lbl)
	$VBox.move_child(mode_lbl, 0)

	score_label.text = "%s  vs  %s   final: %d — %d" % [
		Net.username,
		result.get("opponent", "?"),
		result.get("my_score", 0),
		result.get("opp_score", 0),
	]
	rematch_btn.pressed.connect(_on_rematch)
	menu_btn.pressed.connect(_on_menu)
	Net.rematch_status.connect(_on_rematch_status)
	Net.rematch_go.connect(_on_rematch_go)
	Net.opponent_left.connect(_on_opponent_left)
	Net.match_start.connect(_on_match_start)


func _exit_tree() -> void:
	if not _rematching:
		Net.send_rematch_cancel()
	if Net.rematch_status.is_connected(_on_rematch_status):
		Net.rematch_status.disconnect(_on_rematch_status)
	if Net.rematch_go.is_connected(_on_rematch_go):
		Net.rematch_go.disconnect(_on_rematch_go)
	if Net.opponent_left.is_connected(_on_opponent_left):
		Net.opponent_left.disconnect(_on_opponent_left)
	if Net.match_start.is_connected(_on_match_start):
		Net.match_start.disconnect(_on_match_start)


func _on_rematch() -> void:
	rematch_btn.disabled = true
	rematch_status_label.text = "Waiting for opponent..."
	Net.send_rematch_vote()


func _on_rematch_status(votes: int) -> void:
	rematch_btn.text = "Rematch (%d/2)" % votes
	if votes == 1 and not rematch_btn.disabled:
		rematch_status_label.text = "Opponent wants a rematch!"


func _on_rematch_go() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "Starting..."
	rematch_status_label.text = ""


func _on_opponent_left() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "Opponent left"
	rematch_status_label.text = ""


func _on_match_start(_data: Dictionary) -> void:
	_rematching = true
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
