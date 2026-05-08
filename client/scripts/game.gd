extends Control
# scripts/game.gd

enum State { WAITING_MATCH, WAITING, STIMULUS, READY_UP, MATCH_END }
var state: State = State.WAITING_MATCH

var t_stimulus_us: int = 0
var my_score: int = 0
var opp_score: int = 0
var opponent_username: String = "?"
var _countdown: int = 5
var _readied: bool = false

@onready var background: ColorRect = $Background
@onready var stimulus: ColorRect = $Stimulus
@onready var status_label: Label = $StatusLabel
@onready var rt_label: Label = $RTLabel
@onready var ready_label: Label = $ReadyLabel
@onready var countdown_label: Label = $CountdownLabel
@onready var countdown_timer: Timer = $CountdownTimer


func _ready() -> void:
	_set_idle("Match starting...")
	ready_label.visible = false
	countdown_label.visible = false
	countdown_timer.timeout.connect(_on_countdown_tick)
	Net.match_start.connect(_on_match_start)
	Net.round_prepare.connect(_on_round_prepare)
	Net.stimulus.connect(_on_stimulus)
	Net.round_result.connect(_on_round_result)
	Net.match_end.connect(_on_match_end)


func _exit_tree() -> void:
	if Net.match_start.is_connected(_on_match_start):
		Net.match_start.disconnect(_on_match_start)
	if Net.round_prepare.is_connected(_on_round_prepare):
		Net.round_prepare.disconnect(_on_round_prepare)
	if Net.stimulus.is_connected(_on_stimulus):
		Net.stimulus.disconnect(_on_stimulus)
	if Net.round_result.is_connected(_on_round_result):
		Net.round_result.disconnect(_on_round_result)
	if Net.match_end.is_connected(_on_match_end):
		Net.match_end.disconnect(_on_match_end)


func _on_match_start(data: Dictionary) -> void:
	opponent_username = data.get("opponent_username", "?")
	my_score = 0
	opp_score = 0
	_set_idle("vs %s\nGet ready!" % opponent_username)


func _on_round_prepare(round_num: int) -> void:
	state = State.WAITING
	countdown_timer.stop()
	ready_label.visible = false
	countdown_label.visible = false
	stimulus.color = Color(0.2, 0.2, 0.2)
	status_label.text = "Round %d - wait for green..." % round_num
	rt_label.text = "%d - %d" % [my_score, opp_score]


func _on_stimulus(_server_time_us: int) -> void:
	state = State.STIMULUS
	stimulus.color = Color(0.2, 0.9, 0.3)
	status_label.text = "CLICK!"
	t_stimulus_us = Time.get_ticks_usec()


func _on_round_result(data: Dictionary) -> void:
	my_score = data.get("your_score", my_score)
	opp_score = data.get("opponent_score", opp_score)
	var won: bool = data.get("you_won_round", false)
	stimulus.color = Color(0.2, 0.9, 0.3) if won else Color(0.7, 0.2, 0.2)
	status_label.text = "Round %s" % ("WON" if won else "LOST")
	rt_label.text = "You: %s ms  |  %s: %s ms\nScore: %d - %d" % [
		_fmt(data.get("your_rt_ms")),
		opponent_username,
		_fmt(data.get("opponent_rt_ms")),
		my_score, opp_score
	]
	_enter_ready_up()


func _enter_ready_up() -> void:
	state = State.READY_UP
	_readied = false
	_countdown = 5
	ready_label.text = "Click to ready up"
	ready_label.visible = true
	countdown_label.text = "5"
	countdown_label.visible = true
	countdown_timer.start()


func _on_countdown_tick() -> void:
	_countdown -= 1
	if _countdown <= 0:
		countdown_timer.stop()
		countdown_label.text = "0"
		if not _readied:
			ready_label.text = "Starting..."
	else:
		countdown_label.text = str(_countdown)


func _on_match_end(data: Dictionary) -> void:
	state = State.MATCH_END
	countdown_timer.stop()
	Net.last_match_result = {
		"won": data.get("you_won", false),
		"final_score": data.get("final_score", ""),
		"opponent": opponent_username,
	}
	get_tree().change_scene_to_file("res://scenes/results.tscn")


func _fmt(v) -> String:
	if v == null:
		return "—"
	return "%.1f" % float(v)


func _set_idle(text: String) -> void:
	stimulus.color = Color(0.2, 0.2, 0.2)
	status_label.text = text
	rt_label.text = ""


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	match state:
		State.STIMULUS:
			var rt := (Time.get_ticks_usec() - t_stimulus_us) / 1000.0
			Net.send_click(rt, false)
			status_label.text = "Click sent — waiting for opponent..."
		State.WAITING:
			Net.send_click(0.0, true)
			status_label.text = "Too early! Forfeit."
		State.READY_UP:
			if not _readied:
				_readied = true
				Net.send_ready_up()
				ready_label.text = "Ready! Waiting for opponent..."
