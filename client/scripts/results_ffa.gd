extends Control
# scripts/results_ffa.gd

const FONT := preload("res://fonts/BebasNeue-Regular.ttf")

@onready var result_label: Label         = $VBox/ResultLabel
@onready var standings_label: Label      = $VBox/StandingsLabel
@onready var rematch_btn: Button         = $VBox/RematchButton
@onready var rematch_status_label: Label = $VBox/RematchStatus
@onready var menu_btn: Button            = $VBox/MenuButton

var _rematching := false


func _ready() -> void:
	var result: Dictionary = Net.last_ffa_match_result
	var my_slot: int        = result.get("my_server_slot", 0)
	var placements: Array   = result.get("placements", [1, 2, 3, 4])
	var final_scores: Array = result.get("scores", [0, 0, 0, 0])
	var names: Array        = result.get("player_names", ["?", "?", "?", "?"])
	var n: int              = placements.size()
	var my_place: int       = placements[my_slot] if my_slot < n else 0
	var _pstrs: Array = ["1ST", "2ND", "3RD", "4TH"]
	var _ps: String   = _pstrs[my_place - 1] if my_place >= 1 and my_place <= 4 else str(my_place)
	result_label.text = "%s PLACE%s" % [_ps, "!" if my_place == 1 else ""]
	if my_place == 1:
		result_label.add_theme_color_override("font_color", Color(0.12, 0.80, 0.30))
	elif my_place == n:
		result_label.add_theme_color_override("font_color", Color(0.78, 0.10, 0.10))
	elif my_place == 2:
		result_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	else:
		result_label.add_theme_color_override("font_color", Color(0.78, 0.55, 0.10))

	var mode_lbl := Label.new()
	mode_lbl.text = "FREE FOR ALL"
	mode_lbl.add_theme_color_override("font_color", Color(0.28, 0.28, 0.28))
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_lbl.add_theme_font_override("font", FONT)
	mode_lbl.add_theme_font_size_override("font_size", 22)
	$VBox.add_child(mode_lbl)
	$VBox.move_child(mode_lbl, 0)

	# Build standings text: sort by placement then slot for stability
	var order := range(n)
	order.sort_custom(func(a, b): return placements[a] < placements[b])
	var lines := ""
	var place_strs := ["1ST", "2ND", "3RD", "4TH"]
	for ss in order:
		var p: int = placements[ss]
		var ps: String = place_strs[p - 1] if p >= 1 and p <= 4 else str(p)
		var you := " (YOU)" if ss == my_slot else ""
		lines += "%s  %s  —  %d wins%s\n" % [ps, names[ss], final_scores[ss], you]
	standings_label.text = lines.strip_edges()

	rematch_btn.pressed.connect(_on_rematch)
	menu_btn.pressed.connect(_on_menu)
	Net.rematch_status.connect(_on_rematch_status)
	Net.rematch_go.connect(_on_rematch_go)
	Net.opponent_left.connect(_on_opponent_left)
	Net.ffa_match_start.connect(_on_ffa_match_start)


func _exit_tree() -> void:
	if not _rematching:
		Net.send_rematch_cancel()
	for pair in [
		[Net.rematch_status,   _on_rematch_status],
		[Net.rematch_go,       _on_rematch_go],
		[Net.opponent_left,    _on_opponent_left],
		[Net.ffa_match_start,  _on_ffa_match_start],
	]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


func _on_rematch() -> void:
	rematch_btn.disabled = true
	rematch_status_label.text = "Waiting for all players..."
	Net.send_rematch_vote()


func _on_rematch_status(votes: int) -> void:
	var total: int = Net.last_ffa_match_result.get("placements", [0, 0, 0, 0]).size()
	rematch_btn.text = "REMATCH (%d/%d)" % [votes, total]
	if votes > 0 and not rematch_btn.disabled:
		rematch_status_label.text = "%d / %d players ready" % [votes, total]


func _on_rematch_go() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "Starting..."
	rematch_status_label.text = ""


func _on_opponent_left() -> void:
	rematch_btn.disabled = true
	rematch_btn.text = "A player left"
	rematch_status_label.text = ""


func _on_ffa_match_start(_data: Dictionary) -> void:
	_rematching = true
	get_tree().change_scene_to_file("res://scenes/game_ffa.tscn")


func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
