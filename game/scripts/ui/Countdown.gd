class_name Countdown
extends Label
## 시작 카운트다운 오버레이 3-2-1-GO (아키텍처 §10).

const GO_HIDE_DELAY: float = 0.8


var _last_beep: int = -1


func show_number(value: int) -> void:
	visible = true
	text = str(value)
	modulate = Color(1.0, 1.0, 1.0, 1.0)
	# 값이 바뀔 때만 비프(show_number가 매 틱 호출되므로 중복 방지).
	if value != _last_beep:
		_last_beep = value
		_play_countdown_beep(value)


func show_go() -> void:
	visible = true
	text = "GO!"
	modulate = Color(0.5, 1.0, 0.6, 1.0)
	# process_always=false: 일시정지 중에는 자동 숨김 타이머도 멈춰야 GO! 표시가
	# 화면의 다른 정지 상태와 어긋나지 않는다.
	var timer: SceneTreeTimer = get_tree().create_timer(GO_HIDE_DELAY, false)
	timer.timeout.connect(_on_hide_timeout)
	_play_go()


func _on_hide_timeout() -> void:
	visible = false


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")


func _play_countdown_beep(value: int) -> void:
	var am: Node = _audio()
	if am != null and am.has_method("play_countdown_beep"):
		am.play_countdown_beep(value)


func _play_go() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("play_go"):
		am.play_go()
