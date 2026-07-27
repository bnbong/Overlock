extends Control
## 결과 화면. GameState.last_result 렌더 + 신기록 라벨 + Retry/Menu (기획서 §8.4).

const TRACK_NAMES: Dictionary = {"cotton_01": "Cotton Warm-up"}

@onready var _title_label: Label = $Panel/TitleLabel
@onready var _grade_label: Label = $Panel/GradeLabel
@onready var _stats_label: Label = $Panel/StatsLabel
@onready var _new_record_label: Label = $Panel/NewRecordLabel
@onready var _retry_button: Button = $Panel/RetryButton
@onready var _menu_button: Button = $Panel/MenuButton


func _ready() -> void:
	_title_label.text = "RESULT"
	var result: Dictionary = GameState.last_result
	_apply_grade(result)
	_stats_label.text = _build_text(result)
	var is_new_record: bool = bool(result.get("is_new_record", false))
	if is_new_record:
		_new_record_label.text = "NEW RECORD!"
		_new_record_label.visible = true
	else:
		_new_record_label.visible = false
	_retry_button.pressed.connect(_on_retry_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	_retry_button.grab_focus()
	# 오디오 훅: 신기록이면 팡파레, 아니면 피니시 징글(가드: 미등록 시 무시).
	_play_result_audio(is_new_record)


## 재봉 평점(등급)을 큰 문자로 눈에 띄게 표시. 하위 호환: grade 없으면 "-".
func _apply_grade(result: Dictionary) -> void:
	var grade: String = str(result.get("grade", "-"))
	_grade_label.text = grade
	_grade_label.add_theme_color_override("font_color", FinishView.grade_color(grade))


func _build_text(result: Dictionary) -> String:
	if result.is_empty():
		return "No result data."
	var lines: Array[String] = []
	lines.append("Track: " + _track_name(str(result.get("track_id", ""))))
	lines.append(
		(
			"Seam Grade: %s  (%.0f)"
			% [str(result.get("grade", "-")), float(result.get("grade_score", 0.0))]
		)
	)
	lines.append("Difficulty: " + _capitalize(str(result.get("difficulty", ""))))
	lines.append("Finish Time: " + _format_ms(int(result.get("finish_ms", 0))))
	lines.append("Penalty: +" + _format_ms(int(result.get("penalty_ms", 0))))
	lines.append("Final Time: " + _format_ms(int(result.get("final_time_ms", 0))))
	lines.append("Accuracy: %.1f%%" % float(result.get("accuracy", 0.0)))
	lines.append("Perfect Rate: %.1f%%" % float(result.get("perfect_rate", 0.0)))
	lines.append("Off-Seam Time: " + _format_ms(int(result.get("off_seam_ms", 0))))
	lines.append("Finger Cuts: " + str(int(result.get("cuts", 0))))
	lines.append("Max Speed: " + str(int(result.get("max_speed", 1))))
	lines.append("Average Speed: %.1f" % float(result.get("avg_speed", 0.0)))
	return "\n".join(lines)


func _on_retry_pressed() -> void:
	GameState.start_run(GameState.track_id, GameState.difficulty)


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _play_result_audio(is_new_record: bool) -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am == null:
		return
	if is_new_record and am.has_method("play_record"):
		am.play_record()
	elif am.has_method("play_finish"):
		am.play_finish()


func _track_name(track_id: String) -> String:
	return TRACK_NAMES.get(track_id, track_id)


static func _capitalize(text: String) -> String:
	if text.is_empty():
		return text
	return text.substr(0, 1).to_upper() + text.substr(1)


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
