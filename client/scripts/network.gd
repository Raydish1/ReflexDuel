extends Node
# Autoload singleton — registered as "Net" in Project Settings > Autoload.
# Owns the WebSocket connection so scene changes don't drop it.

const SERVER_URL := "ws://127.0.0.1:8000/ws/play"

# Signals — scenes connect to these to react to server events
signal hello_received(player_id: String)
signal queued()
signal room_created(code: String)
signal room_join_failed(code: String)
signal cancelled()
signal match_start(data: Dictionary)
signal round_prepare(round_num: int)
signal stimulus(server_time_us: int)
signal round_result(data: Dictionary)
signal match_end(data: Dictionary)
signal connection_lost()
signal rematch_status(votes: int)
signal rematch_go()
signal opponent_left()

var socket: WebSocketPeer
var player_id: String = ""
var username: String = "anon"
var connected: bool = false
var last_match_result: Dictionary = {}


func _ready() -> void:
	socket = WebSocketPeer.new()
	var err := socket.connect_to_url(SERVER_URL)
	if err != OK:
		push_error("WebSocket connect failed: %d" % err)


func _process(_delta: float) -> void:
	if socket == null:
		return
	socket.poll()
	var s := socket.get_ready_state()

	if s == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			print("[Net] Connected to server")
		while socket.get_available_packet_count() > 0:
			var packet := socket.get_packet()
			var text := packet.get_string_from_utf8()
			var msg = JSON.parse_string(text)
			if msg != null:
				_dispatch(msg)
	elif s == WebSocketPeer.STATE_CLOSED and connected:
		connected = false
		print("[Net] Connection lost")
		connection_lost.emit()


func _dispatch(msg: Dictionary) -> void:
	var t: String = msg.get("type", "")
	match t:
		"hello":
			player_id = msg.get("player_id", "")
			print("[Net] Got player ID: %s" % player_id)
			hello_received.emit(player_id)
		"username_set":
			username = msg.get("username", username)
		"queued":
			queued.emit()
		"room_created":
			room_created.emit(msg.get("room_code", ""))
		"room_join_failed":
			room_join_failed.emit(msg.get("code", ""))
		"cancelled":
			cancelled.emit()
		"match_start":
			match_start.emit(msg)
		"round_prepare":
			round_prepare.emit(msg.get("round_num", 0))
		"stimulus":
			stimulus.emit(msg.get("server_time_us", 0))
		"round_result":
			round_result.emit(msg)
		"match_end":
			match_end.emit(msg)
		"rematch_status":
			rematch_status.emit(msg.get("votes", 0))
		"rematch_go":
			rematch_go.emit()
		"opponent_left":
			opponent_left.emit()


func send(msg: Dictionary) -> void:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[Net] Tried to send but not connected: %s" % msg)
		return
	socket.send_text(JSON.stringify(msg))


func set_username(name: String) -> void:
	username = name
	send({"type": "set_username", "username": name})


func quickplay() -> void:
	send({"type": "quickplay"})


func create_room() -> void:
	send({"type": "create_room"})


func join_room(code: String) -> void:
	send({"type": "join_room", "room_code": code})


func cancel_queue() -> void:
	send({"type": "cancel_queue"})


func send_click(client_rt_ms: float, pre_click: bool) -> void:
	send({
		"type": "click",
		"client_rt_ms": client_rt_ms,
		"pre_click": pre_click,
	})


func send_rematch_vote() -> void:
	send({"type": "rematch_vote"})


func send_rematch_cancel() -> void:
	send({"type": "rematch_cancel"})
