extends Control
# scripts/private_lobby.gd

@onready var create_btn: Button = $VBox/CreateSection/CreateButton
@onready var code_display: Label = $VBox/CreateSection/CodeDisplay
@onready var code_input: LineEdit = $VBox/JoinSection/CodeInput
@onready var join_btn: Button = $VBox/JoinSection/JoinButton
@onready var error_label: Label = $VBox/ErrorLabel
@onready var back_btn: Button = $VBox/BackButton


func _ready() -> void:
	code_display.text = ""
	error_label.text = ""
	code_input.placeholder_text = "ENTER CODE"
	code_input.max_length = 6

	create_btn.pressed.connect(_on_create)
	join_btn.pressed.connect(_on_join)
	back_btn.pressed.connect(_on_back)
	code_input.text_submitted.connect(func(_t): _on_join())

	Net.room_created.connect(_on_room_created)
	Net.room_join_failed.connect(_on_room_failed)
	Net.match_start.connect(_on_match_start)


func _exit_tree() -> void:
	if Net.room_created.is_connected(_on_room_created):
		Net.room_created.disconnect(_on_room_created)
	if Net.room_join_failed.is_connected(_on_room_failed):
		Net.room_join_failed.disconnect(_on_room_failed)
	if Net.match_start.is_connected(_on_match_start):
		Net.match_start.disconnect(_on_match_start)


func _on_create() -> void:
	error_label.text = ""
	code_display.text = "Creating..."
	Net.create_room()


func _on_room_created(code: String) -> void:
	code_display.text = "Code: %s" % code
	create_btn.disabled = true
	create_btn.text = "Waiting for opponent..."


func _on_join() -> void:
	var code: String = code_input.text.strip_edges().to_upper()
	if code.length() != 6:
		error_label.text = "Code must be 6 characters"
		return
	error_label.text = "Joining..."
	Net.join_room(code)


func _on_room_failed(code: String) -> void:
	error_label.text = "Room %s not found" % code


func _on_match_start(_data: Dictionary) -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_back() -> void:
	Net.cancel_queue()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
