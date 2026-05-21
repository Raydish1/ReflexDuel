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
signal private_lobby_update(data: Dictionary)
signal private_join_error(reason: String)
signal private_kicked()
signal private_left()
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
signal recent_matches_data(player_id: String, matches: Array)
signal team_match_start(data: Dictionary)
signal team_round_result(data: Dictionary)
signal team_match_end(data: Dictionary)
signal team_player_clicked(data: Dictionary)
signal team_queue_update(needed: int)
signal ffa_match_start(data: Dictionary)
signal ffa_round_result(data: Dictionary)
signal ffa_match_end(data: Dictionary)
signal ffa_player_clicked(data: Dictionary)
signal ffa_queue_update(needed: int)

var socket: WebSocketPeer
var player_id: String = ""
var username: String = "anon"
var connected: bool = false
var last_match_result: Dictionary = {}
var last_match_start: Dictionary = {}
var last_team_match_start: Dictionary = {}
var last_team_match_result: Dictionary = {}
var last_ffa_match_start: Dictionary = {}
var last_ffa_match_result: Dictionary = {}
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
		"private_lobby_created", "private_lobby_update":
			private_lobby_update.emit(msg)
		"private_join_error":
			private_join_error.emit(msg.get("reason", ""))
		"private_kicked":
			private_kicked.emit()
		"private_left":
			private_left.emit()
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
		"recent_matches_data":
			recent_matches_data.emit(msg.get("player_id", ""), msg.get("matches", []))
		"team_match_start":
			last_team_match_start = msg
			last_round_prepare = -1
			team_match_start.emit(msg)
		"team_round_prepare":
			last_round_prepare = msg.get("round_num", 0)
			round_prepare.emit(last_round_prepare)
		"team_round_result":
			team_round_result.emit(msg)
		"team_match_end":
			team_match_end.emit(msg)
		"team_player_clicked":
			team_player_clicked.emit(msg)
		"ffa_match_start":
			last_ffa_match_start = msg
			last_round_prepare = -1
			ffa_match_start.emit(msg)
		"ffa_round_prepare":
			last_round_prepare = msg.get("round_num", 0)
			round_prepare.emit(last_round_prepare)
		"ffa_round_result":
			ffa_round_result.emit(msg)
		"ffa_match_end":
			ffa_match_end.emit(msg)
		"ffa_player_clicked":
			ffa_player_clicked.emit(msg)
		"queue_update":
			match msg.get("mode", ""):
				"team":
					team_queue_update.emit(int(msg.get("needed", 4)))
				"ffa":
					ffa_queue_update.emit(int(msg.get("needed", 4)))


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


func auditory_quickplay() -> void:
	queue_mode = "auditory"
	send({"type": "auditory_quickplay"})


func team_quickplay() -> void:
	queue_mode = "team"
	send({"type": "team_quickplay"})


func ffa_quickplay() -> void:
	queue_mode = "ffa"
	send({"type": "ffa_quickplay"})


func practice_quickplay() -> void:
	queue_mode = "practice"
	send({"type": "practice_quickplay"})


func private_create() -> void:
	send({"type": "private_create"})


func private_join(code: String) -> void:
	send({"type": "private_join", "code": code})


func private_kick(target_id: String) -> void:
	send({"type": "private_kick", "player_id": target_id})


func private_set_mode(mode: String) -> void:
	send({"type": "private_set_mode", "mode": mode})


func private_set_cue(cue: String) -> void:
	send({"type": "private_set_cue", "cue": cue})


func private_leave() -> void:
	send({"type": "private_leave"})


func private_start() -> void:
	send({"type": "private_start"})


func cancel_queue() -> void:
	send({"type": "cancel_queue"})


func send_click(client_rt_ms: float, pre_click: bool, mouse_dist_px: float = 0.0, time_since_move_ms: float = 0.0, window_focused: bool = true, click_pos_x: float = 0.0, click_pos_y: float = 0.0, pre_click_displacement_px: float = 0.0) -> void:
	send({
		"type": "click",
		"client_rt_ms": client_rt_ms,
		"pre_click": pre_click,
		"mouse_distance_5s_px": mouse_dist_px,
		"time_since_mouse_move_ms": time_since_move_ms,
		"window_focused": window_focused,
		"click_pos_x": click_pos_x,
		"click_pos_y": click_pos_y,
		"pre_click_displacement_px": pre_click_displacement_px,
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


func request_recent_matches(pid: String = "", match_type: String = "all") -> void:
	var msg := {"type": "recent_matches_request", "match_type": match_type}
	if pid != "":
		msg["player_id"] = pid
	send(msg)
