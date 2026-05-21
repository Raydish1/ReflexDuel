extends Control
# scripts/matchmaking.gd

@onready var status_label: Label = $VBox/StatusLabel
@onready var dots_label: Label = $VBox/DotsLabel
@onready var cancel_btn: Button = $VBox/CancelButton
@onready var dots_timer: Timer = $DotsTimer

var dots := 0


func _ready() -> void:
	cancel_btn.pressed.connect(_on_cancel)
	dots_timer.timeout.connect(_animate)
	Net.match_start.connect(_on_match_start)
	Net.team_match_start.connect(_on_team_match_start)
	Net.ffa_match_start.connect(_on_ffa_match_start)
	Net.cancelled.connect(_on_cancelled)
	Net.team_queue_update.connect(_on_team_queue_update)
	Net.ffa_queue_update.connect(_on_ffa_queue_update)
	if Net.queue_mode == "practice":
		status_label.text = "Practice — Finding opponent..."
		Net.practice_quickplay()
	elif Net.queue_mode == "team":
		status_label.text = "2v2 — Waiting for 3 more players..."
		Net.team_quickplay()
	elif Net.queue_mode == "ffa":
		status_label.text = "FFA — Waiting for 3 more players..."
		Net.ffa_quickplay()
	elif Net.queue_mode == "auditory":
		status_label.text = "Auditory 1v1 — Finding opponent..."
		Net.auditory_quickplay()
	else:
		status_label.text = "Ranked — Finding opponent..."
		Net.quickplay()


func _exit_tree() -> void:
	if Net.match_start.is_connected(_on_match_start):
		Net.match_start.disconnect(_on_match_start)
	if Net.team_match_start.is_connected(_on_team_match_start):
		Net.team_match_start.disconnect(_on_team_match_start)
	if Net.ffa_match_start.is_connected(_on_ffa_match_start):
		Net.ffa_match_start.disconnect(_on_ffa_match_start)
	if Net.cancelled.is_connected(_on_cancelled):
		Net.cancelled.disconnect(_on_cancelled)
	if Net.team_queue_update.is_connected(_on_team_queue_update):
		Net.team_queue_update.disconnect(_on_team_queue_update)
	if Net.ffa_queue_update.is_connected(_on_ffa_queue_update):
		Net.ffa_queue_update.disconnect(_on_ffa_queue_update)


func _animate() -> void:
	dots = (dots + 1) % 4
	dots_label.text = ".".repeat(dots)


func _on_match_start(_data: Dictionary) -> void:
	_show_found_banner()
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_team_match_start(_data: Dictionary) -> void:
	_show_found_banner()
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file("res://scenes/game_2v2.tscn")


func _on_ffa_match_start(_data: Dictionary) -> void:
	_show_found_banner()
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file("res://scenes/game_ffa.tscn")


func _show_found_banner() -> void:
	dots_timer.stop()
	cancel_btn.visible = false
	dots_label.visible = false
	status_label.add_theme_font_size_override("font_size", 48)
	status_label.text = "Match Found!"
	status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))


func _on_cancel() -> void:
	Net.cancel_queue()


func _on_cancelled() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_team_queue_update(needed: int) -> void:
	if Net.queue_mode == "team" and status_label.text != "Match Found!":
		status_label.text = "2v2 — Waiting for %d more player%s..." % [needed, "s" if needed != 1 else ""]


func _on_ffa_queue_update(needed: int) -> void:
	if Net.queue_mode == "ffa" and status_label.text != "Match Found!":
		status_label.text = "FFA — Waiting for %d more player%s..." % [needed, "s" if needed != 1 else ""]
