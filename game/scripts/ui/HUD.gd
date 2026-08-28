class_name HUD
extends CanvasLayer
## HUD 자식 갱신 중계 (아키텍처 §2/§8, presentation.md §4).
##
## RaceDirector가 매 틱 값을 주입하면 각 위젯에 분배한다. 오디오 훅은
## /root/AudioManager를 런타임 조회 + has_method 가드로 부른다(미등록 시 무시).

## 효과 타이머 카드 아이콘(월드 아이템과 동일 스프라이트). 골무=금색 골무, 엄마찬스=분홍 하트.
const ICON_THIMBLE := preload("res://assets/gfx/item_thimble.png")
const ICON_AUTOPILOT := preload("res://assets/gfx/item_moms_chance.png")
## 효과별 강조색(게이지 채움·만료 임박 점멸·테두리 강조). 골무=금색(RiskMeter 실드 톤과 통일),
## 엄마찬스=분홍(월드 하트 아이템과 통일).
const THIMBLE_ACCENT := Color(1.0, 0.82, 0.28)
const THIMBLE_ACCENT_DEEP := Color(0.78, 0.58, 0.12)
const AUTOPILOT_ACCENT := Color(0.93, 0.46, 0.62)
const AUTOPILOT_ACCENT_DEEP := Color(0.70, 0.28, 0.42)

var _length: float = 1.0
var _prev_band: int = RunStats.Band.PERFECT

# 좌하단 RISK 패널 위 효과 타이머 카드(아이콘 + 줄어드는 게이지 바 + 남은 초). 두 효과 동시면 세로 스택,
# 시작 팝 등장 / 만료 임박 점멸 / 종료 페이드 아웃은 카드가 자체 구동한다(EffectTimerCard).
var _effect_box: VBoxContainer = null
var _thimble_card: EffectTimerCard = null
var _autopilot_card: EffectTimerCard = null

@onready var _stopwatch: Stopwatch = $Stopwatch
@onready var _speed_gauge: SpeedGauge = $SpeedGauge
@onready var _risk_meter: RiskMeter = $RiskMeter
@onready var _minimap: MiniMap = $MiniMap
@onready var _progress: SeamProgressBar = $ProgressBar
@onready var _status_label: Label = $StatusLabel
@onready var _countdown: Countdown = $Countdown
@onready var _pause_overlay: Control = $PauseOverlay


func _ready() -> void:
	_apply_skin()
	_build_effect_cards()


## 좌하단 RISK 패널(offset_top=-186) 바로 위에 효과 타이머 카드 VBox를 동적 생성한다(씬 미수정 —
## 동적 생성 컨벤션). 아래 앵커에 붙여 위로 자라게(GROW_BEGIN) 두고, 골무·엄마찬스 카드를 담는다.
## 각 카드는 비활성 시 숨김(visible=false)이라 컨테이너가 자동 축소되고, 활성 시 팝 등장한다.
func _build_effect_cards() -> void:
	_effect_box = VBoxContainer.new()
	_effect_box.name = "EffectTimers"
	_effect_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effect_box.add_theme_constant_override("separation", 8)
	_effect_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_effect_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_effect_box.offset_left = 16.0
	_effect_box.offset_bottom = -196.0  # RISK 패널 상단(-186)보다 10px 위.
	add_child(_effect_box)
	_thimble_card = EffectTimerCard.new()
	_thimble_card.setup(ICON_THIMBLE, THIMBLE_ACCENT, THIMBLE_ACCENT_DEEP, Tuning.thimble_duration)
	_autopilot_card = EffectTimerCard.new()
	_autopilot_card.setup(
		ICON_AUTOPILOT, AUTOPILOT_ACCENT, AUTOPILOT_ACCENT_DEEP, Tuning.autopilot_duration
	)
	_effect_box.add_child(_thimble_card)
	_effect_box.add_child(_autopilot_card)


## 사용자 제공 시트 스킨(있으면): TIME=태그 라벨, 일시정지=베이지 패널. 없으면 절차 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		return
	# TIME: 태그 라벨 텍스처로 교체(UiSkin.SKIN_TIME_TAG). 밑에 깔린 절차 패치(SewingSkin)
	# 드로우는 제거해 태그가 씬 위에 깔끔히 떠 보이게 한다(태그의 둥근 모서리 밖으로 패치가
	# 비치지 않게). 플래그가 꺼져 있으면 TimePanel의 절차 패치를 그대로 둔다(위젯 단위 원복).
	var tp: Control = $TimePanel
	if UiSkin.SKIN_TIME_TAG and UiSkin.skin_texture_bg(tp, "tag_label") != null:
		tp.set_script(null)
	UiSkin.skin_panel($PauseOverlay/PausePanel, "beige")


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
	# 골무(thimble) 활성 중엔 게이지를 금색 실드 톤으로(risk 값 로직 불변).
	_risk_meter.set_shield(player.thimble_timer > 0.0)
	_minimap.update_view(player.position, player.heading, progress_s, player.speed)
	_progress.set_progress(progress_s / _length)
	_update_status(player, band)
	_update_effect_cards(player)


## 활성 효과(골무/엄마찬스) 타이머 카드의 활성/잔여시간을 갱신한다. 타이머>0이면 카드를 활성(팝 등장·
## 게이지·초 갱신), 아니면 비활성(페이드 아웃)한다. 카드가 팝/점멸/페이드를 자체 구동하므로 여기선
## 상태 전이와 잔여시간 주입만 한다. player.thimble_timer/autopilot_timer는 update_frame에 전달됨.
func _update_effect_cards(player: PlayerController) -> void:
	if _effect_box == null:
		return
	var t: float = player.thimble_timer
	if t > 0.0:
		_thimble_card.activate()
		_thimble_card.set_remaining(t)
	else:
		_thimble_card.deactivate()
	var a: float = player.autopilot_timer
	if a > 0.0:
		_autopilot_card.activate()
		_autopilot_card.set_remaining(a)
	else:
		_autopilot_card.deactivate()


func _update_status(player: PlayerController, band: int) -> void:
	if player.stun_timer > 0.0:
		_status_label.text = "FINGER CUT!"
		_status_label.modulate = Color(1.0, 0.3, 0.3)
	elif player.offfabric_timer > 0.0:
		# 맵 이탈 소프트 리셋 잠금 중(부상보다 아래, 오프심보다 위 우선순위) — 주황 안내.
		_status_label.text = "원단 이탈 · 복귀"
		_status_label.modulate = Color(1.0, 0.55, 0.1)
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
