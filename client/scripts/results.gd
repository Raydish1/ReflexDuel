extends Control
# scripts/results.gd

@onready var result_label: Label = $VBox/ResultLabel
@onready var score_label: Label = $VBox/ScoreLabel
@onready var play_again_btn: Button = $VBox/PlayAgainButton
@onready var menu_btn: Button = $VBox/MenuButton


func _ready() -> void:
	var result: Dictionary = Net.last_match_result
	var won: bool = result.get("won", false)
	result_label.text = "YOU WON" if won else "YOU LOST"
	result_label.modulate = Color(0.3, 0.9, 0.4) if won else Color(0.9, 0.3, 0.3)
	score_label.text = "vs %s   final: %s" % [
		result.get("opponent", "?"),
		result.get("final_score", "")
	]
	play_again_btn.pressed.connect(_on_play_again)
	menu_btn.pressed.connect(_on_menu)


func _on_play_again() -> void:
	get_tree().change_scene_to_file("res://scenes/matchmaking.tscn")


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
