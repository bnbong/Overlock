class_name HUD
extends CanvasLayer
## HUD 자식 갱신 중계 (아키텍처 §2/§8, presentation.md §4).
##
## RaceDirector가 매 틱 값을 주입하면 각 위젯에 분배한다. 오디오 훅은
## /root/AudioManager를 런타임 조회 + has_method 가드로 부른다(미등록 시 무시).

var _length: float = 1.0
var _prev_band: int = RunStats.Band.PERFECT

@onready var _stopwatch: Stopwatch = $Stopwatch
@onready var _speed_gauge: SpeedGauge = $SpeedGauge
@onready var _risk_meter: RiskMeter = $RiskMeter
@onready var _minimap: MiniMap = $MiniMap
@onready var _progress: SeamProgressBar = $ProgressBar
@onready var _status_label: Label = $StatusLabel
@onready var _countdown: Countdown = $Countdown
@onready var _pause_overlay: Control = $PauseOverlay


func setup(track: TrackData) -> void:
	_minimap.setup(track)
	_length = maxf(track.length, 1.0)
	_status_label.text = ""
	_progress.set_progress(0.0)
	_reset_audio_run()
	_play_bgm("gameplay")


func show_countdown(value: int) -> void:
	_countdown.show_number(value)


func show_go() -> void:
	_countdown.show_go()


func set_pause_visible(value: bool) -> void:
	_pause_overlay.visible = value


## 완주 줌아웃 연출 진입 시 인게임 HUD 위젯을 숨긴다(FinishView 오버레이가 화면을
## 차지, presentation.md §13). CanvasLayer.visible=false로 자식 위젯 일괄 숨김.
func enter_finish_view() -> void:
	visible = false


func update_frame(
	elapsed: float, player: PlayerController, _track: TrackData, progress_s: float, band: int
) -> void:
	_stopwatch.set_time(elapsed)
	_speed_gauge.set_stage(player.speed_index)
	_risk_meter.set_risk(player.risk)
	_minimap.update_view(player.position, player.heading, progress_s, player.speed)
	_progress.set_progress(progress_s / _length)
	_update_status(player, band)


func _update_status(player: PlayerController, band: int) -> void:
	if player.stun_timer > 0.0:
		_status_label.text = "FINGER CUT!"
		_status_label.modulate = Color(1.0, 0.3, 0.3)
	elif band == RunStats.Band.OFF_SEAM or band == RunStats.Band.TEAR:
		_status_label.text = "OFF-SEAM"
		_status_label.modulate = Color(1.0, 0.8, 0.2)
	else:
		_status_label.text = ""
		_status_label.modulate = Color(1.0, 1.0, 1.0)
	# Off-Seam 진입 상승엣지에서만 오디오 훅(밴드 전이).
	var was_on_seam: bool = (
		_prev_band != RunStats.Band.OFF_SEAM and _prev_band != RunStats.Band.TEAR
	)
	var now_off_seam: bool = band == RunStats.Band.OFF_SEAM or band == RunStats.Band.TEAR
	if was_on_seam and now_off_seam:
		_on_band_enter(band)
	_prev_band = band


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")


func _reset_audio_run() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("reset_run_state"):
		am.reset_run_state()


func _play_bgm(loop_id: String) -> void:
	var am: Node = _audio()
	if am != null and am.has_method("play_bgm"):
		am.play_bgm(loop_id)


func _on_band_enter(band: int) -> void:
	var am: Node = _audio()
	if am != null and am.has_method("on_band_enter"):
		am.on_band_enter(band)
