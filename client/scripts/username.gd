extends Control
# scripts/username.gd

@onready var name_input: LineEdit = $VBox/NameInput
@onready var save_btn: Button = $VBox/ButtonRow/SaveButton
@onready var back_btn: Button = $VBox/ButtonRow/BackButton


func _ready() -> void:
	name_input.text = Net.username if Net.username != "anon" else ""
	name_input.placeholder_text = "Enter username (2-32 chars)"
	name_input.grab_focus()
	save_btn.pressed.connect(_on_save)
	back_btn.pressed.connect(_on_back)
	name_input.text_submitted.connect(func(_t): _on_save())


func _on_save() -> void:
	var name: String = name_input.text.strip_edges()
	if name.length() < 2:
		name_input.placeholder_text = "Must be at least 2 characters"
		return
	Net.set_username(name)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
