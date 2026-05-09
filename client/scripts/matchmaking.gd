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
	Net.cancelled.connect(_on_cancelled)
	if Net.queue_mode == "practice":
		status_label.text = "Practice — Finding opponent..."
		Net.practice_quickplay()
	else:
		status_label.text = "Ranked — Finding opponent..."
		Net.quickplay()


func _exit_tree() -> void:
	if Net.match_start.is_connected(_on_match_start):
		Net.match_start.disconnect(_on_match_start)
	if Net.cancelled.is_connected(_on_cancelled):
		Net.cancelled.disconnect(_on_cancelled)


func _animate() -> void:
	dots = (dots + 1) % 4
	dots_label.text = ".".repeat(dots)


func _on_match_start(_data: Dictionary) -> void:
	dots_timer.stop()
	cancel_btn.visible = false
	dots_label.visible = false
	status_label.add_theme_font_size_override("font_size", 48)
	status_label.text = "Match Found!"
	status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	await get_tree().create_timer(1.0).timeout
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_cancel() -> void:
	Net.cancel_queue()


func _on_cancelled() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
