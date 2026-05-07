extends Control
# scripts/main_menu.gd
# Attach to the MainMenu root node of scenes/main_menu.tscn

@onready var quickplay_btn: Button = $VBox/QuickplayButton
@onready var private_btn: Button = $VBox/PrivateRoomButton
@onready var name_btn: Button = $VBox/ChangeNameButton
@onready var quit_btn: Button = $VBox/QuitButton
@onready var subtitle: Label = $VBox/Subtitle


func _ready() -> void:
	subtitle.text = "Playing as: %s" % Net.username
	quickplay_btn.pressed.connect(_on_quickplay)
	private_btn.pressed.connect(_on_private)
	name_btn.pressed.connect(_on_change_name)
	quit_btn.pressed.connect(get_tree().quit)


func _on_quickplay() -> void:
	Net.quickplay()
	get_tree().change_scene_to_file("res://scenes/matchmaking.tscn")


func _on_private() -> void:
	get_tree().change_scene_to_file("res://scenes/private_lobby.tscn")


func _on_change_name() -> void:
	get_tree().change_scene_to_file("res://scenes/username.tscn")
