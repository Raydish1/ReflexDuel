extends Node
# Autoload singleton — registered as "Net" in Project Settings > Autoload.
# Owns the WebSocket connection so scene changes don't drop it.

# In the editor: connects to your local server.
# In exported builds: connects to production.
# To test an exported build against your local server, temporarily swap the URL below.
var SERVER_URL: String = (
	"ws://127.0.0.1:8000/ws/play" if OS.has_feature("editor")
	else "wss://reflexduel-server.fly.dev/ws/play"
)

const CLIENT_VERSION: String = "0.2.0"

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
signal opponent_clicked(pre_click: bool)
signal leaderboard_data(data: Dictionary)

var socket: WebSocketPeer
var player_id: String = ""
var username: String = "anon"
var connected: bool = false
var last_match_result: Dictionary = {}
var last_match_start: Dictionary = {}
var last_round_prepare: int = -1
var queue_mode: String = "ranked"


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
		"ping":
			send({"type": "pong", "ping_id": msg.get("ping_id", 0)})
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
			last_match_start = msg
			last_round_prepare = -1  # reset for new match
			match_start.emit(msg)
		"round_prepare":
			last_round_prepare = msg.get("round_num", 0)
			round_prepare.emit(last_round_prepare)
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
		"opponent_clicked":
			opponent_clicked.emit(bool(msg.get("pre_click", false)))
		"leaderboard_data":
			leaderboard_data.emit(msg)


func send(msg: Dictionary) -> void:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[Net] Tried to send but not connected: %s" % msg)
		return
	socket.send_text(JSON.stringify(msg))


func set_username(new_username: String) -> void:
	username = new_username
	send({"type": "set_username", "username": new_username})


func quickplay() -> void:
	queue_mode = "ranked"
	send({"type": "quickplay"})


func practice_quickplay() -> void:
	queue_mode = "practice"
	send({"type": "practice_quickplay"})


func create_room() -> void:
	send({"type": "create_room"})


func join_room(code: String) -> void:
	send({"type": "join_room", "room_code": code})


func cancel_queue() -> void:
	send({"type": "cancel_queue"})


func send_click(client_rt_ms: float, pre_click: bool, mouse_dist_px: float = 0.0, time_since_move_ms: float = 0.0, window_focused: bool = true) -> void:
	send({
		"type": "click",
		"client_rt_ms": client_rt_ms,
		"pre_click": pre_click,
		"mouse_distance_5s_px": mouse_dist_px,
		"time_since_mouse_move_ms": time_since_move_ms,
		"window_focused": window_focused,
	})


func send_click_info(duration_ms: float) -> void:
	send({"type": "click_info", "click_duration_ms": duration_ms})


func send_client_info() -> void:
	var refresh := DisplayServer.screen_get_refresh_rate()
	var res := DisplayServer.screen_get_size()
	send({
		"type": "client_info",
		"platform": OS.get_name().to_lower(),
		"screen_refresh_hz": refresh,
		"screen_resolution": "%dx%d" % [res.x, res.y],
		"client_version": CLIENT_VERSION,
	})


func send_rematch_vote() -> void:
	send({"type": "rematch_vote"})


func send_rematch_cancel() -> void:
	send({"type": "rematch_cancel"})


func send_ready_up() -> void:
	send({"type": "ready_up"})


func send_calibration(rt_ms: float, side: String) -> void:
	send({"type": "calibration_click", "rt_ms": rt_ms, "side": side})


func request_leaderboard(stat: String) -> void:
	send({"type": "leaderboard_request", "stat": stat})
