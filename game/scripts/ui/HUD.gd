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

# 모바일 터치 컨트롤(docs/mobile.md 1단계). 터치 기기(또는 --touch-controls 강제)에서만 생성한다.
# _modal_count는 HUD 위에 뒤늦게 붙는 모달 수 — 떠 있는 동안 버튼을 숨기고 막는다.
# _tutorial_count는 튜토리얼 코치마크 수 — 버튼을 가리켜 설명하므로 보이게 두고 입력만 막는다.
var _touch: TouchControls = null
var _pause_visible: bool = false
var _modal_count: int = 0
var _tutorial_count: int = 0
var _in_finish_view: bool = false

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
	_build_touch_controls()


## 좌하단 RISK 패널(offset_top=-186) 바로 위에 효과 타이머 카드 VBox를 동적 생성한다(씬 미수정 —
## 동적 생성 컨벤션). 아래 앵커에 붙여 위로 자라게(GROW_BEGIN) 두고, 골무·엄마찬스 카드를 담는다.
## 터치 모드에서는 _apply_touch_layout이 RISK 패널과 함께 위로 옮긴다.
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
	_pause_visible = value
	_refresh_touch_block()


## 완주 줌아웃 연출 진입 시 인게임 HUD 위젯을 숨긴다(FinishView 오버레이가 화면을
## 차지, presentation.md §13). CanvasLayer.visible=false로 자식 위젯 일괄 숨김.
func enter_finish_view() -> void:
	visible = false
	_in_finish_view = true


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


# --- 모바일 터치 컨트롤 (docs/mobile.md 1단계) ---


## 터치 기기면 온스크린 버튼(TouchControls)을 동적 생성하고(씬 미수정 컨벤션), 키보드 전용
## 힌트를 터치에 맞게 정리하며, 일시정지 오버레이에 재개/재시작/메인 버튼을 붙인다.
func _build_touch_controls() -> void:
	if not TouchControls.should_show():
		return
	_touch = TouchControls.new()
	add_child(_touch)
	_apply_touch_layout()
	# 버튼보다 일시정지 오버레이가 위에 그려지도록 오버레이 바로 앞에 둔다.
	move_child(_touch, _pause_overlay.get_index())
	# 키 이름 힌트는 터치 화면에서 뜻이 없으니 정리한다(속도 게이지 라벨 역할은 유지).
	($SteerHint as Label).visible = false
	($SpeedHintUp as Label).text = "FASTER"
	($SpeedHintDown as Label).text = "SLOWER"
	_build_pause_touch_buttons()
	# _ready 이후 HUD에 붙는 Control(튜토리얼 모달 등)은 모달로 보고 떠 있는 동안 버튼을 막는다.
	child_entered_tree.connect(_on_child_entered)


## 터치 모드 하단 위젯 재배치(씬 미수정 — 키보드 모드는 씬 배치 그대로). 조향 버튼은 왼쪽 끝,
## 속도·드리프트 버튼은 오른쪽 끝에 붙으므로(TouchControls.button_rect) 그 위로 위젯을 올린다.
## - 좌측: RISK 패널을 ◀ 바로 위(왼쪽 정렬)로, 효과 카드 스택은 RISK 위 간격(10px)을 유지한 채 함께.
## - 우측: SPEED 패널을 ▲ 열 폭에 맞춰(오른쪽 정렬) ▲ 바로 위로, 게이지·힌트 라벨은 패널 안에서
##   씬과 같은 세로 관계를 유지한 채 함께 옮긴다.
## 모든 위젯이 하단(좌/우) 앵커라 offset만 바꾸면 되고, 캔버스는 1280×720 고정(stretch keep)이다.
func _apply_touch_layout() -> void:
	var m: float = TouchControls.EDGE_MARGIN
	var gap: float = TouchControls.HUD_GAP
	# 좌측: RISK 바닥 = ◀ 윗변 - gap. 효과 카드 VBox(아래 앵커, 위로 자람)도 같은 만큼 올린다.
	var risk_bottom: float = -(m + TouchControls.STEER_SIZE + gap)
	var dy_left: float = risk_bottom - _risk_meter.offset_bottom
	_shift_offsets(_risk_meter, 0.0, dy_left)
	if _effect_box != null:
		_shift_offsets(_effect_box, 0.0, dy_left)
	# 우측: SPEED 패널 = ▲ 열(오른쪽 여백 m, 폭 SPEED_SIZE), 바닥 = ▲ 윗변 - gap. 높이는 씬 값 유지.
	var panel: Control = $SpeedPanel
	var col_w: float = TouchControls.SPEED_SIZE
	var panel_bottom: float = -(m + TouchControls.SPEED_SIZE * 2.0 + TouchControls.BUTTON_GAP + gap)
	var dy_right: float = panel_bottom - panel.offset_bottom
	var dx_right: float = (-m - col_w * 0.5) - (panel.offset_left + panel.offset_right) * 0.5
	var inset: float = 8.0
	for c in [$SpeedHintUp, $SpeedGauge, $SpeedHintDown]:
		var ctrl: Control = c
		_shift_offsets(ctrl, dx_right, dy_right)
		if ctrl is Label:
			# 캡션 라벨은 좁아진 패널 안쪽 폭에 맞춘다(가운데 정렬 유지).
			ctrl.offset_left = -m - col_w + inset
			ctrl.offset_right = -m - inset
	panel.offset_left = -m - col_w
	panel.offset_right = -m
	_shift_offsets(panel, 0.0, dy_right)


static func _shift_offsets(c: Control, dx: float, dy: float) -> void:
	c.offset_left += dx
	c.offset_right += dx
	c.offset_top += dy
	c.offset_bottom += dy


func _build_pause_touch_buttons() -> void:
	($PauseOverlay/PauseHint as Label).visible = false
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "TouchPauseButtons"
	# 트리가 paused여도 버튼이 눌려야 한다(HUD는 PAUSABLE).
	row.process_mode = Node.PROCESS_MODE_ALWAYS
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	row.set_anchors_preset(Control.PRESET_CENTER)
	row.offset_left = -228.0
	row.offset_right = 228.0
	row.offset_top = 6.0
	row.offset_bottom = 86.0
	_pause_overlay.add_child(row)
	var defs: Array = [["계속", &"pause"], ["재시작", &"restart"], ["메인", &"to_menu"]]
	for d in defs:
		var btn: Button = Button.new()
		btn.text = d[0]
		btn.custom_minimum_size = Vector2(136.0, 76.0)
		btn.focus_mode = Control.FOCUS_NONE
		_style_touch_button(btn)
		btn.pressed.connect(_tap_action.bind(d[1]))
		row.add_child(btn)


## 일시정지 오버레이의 터치 버튼 룩. 시트 버튼(UiSkin small/large)은 세로로 늘리면 모서리 단추
## 장식이 반복돼 깨지므로, 손가락 크기(높이 76px)에 맞춰 재봉 팔레트 StyleBoxFlat을 쓴다.
func _style_touch_button(btn: Button) -> void:
	var looks: Dictionary = {
		"normal": SewingSkin.FABRIC,
		"hover": SewingSkin.FABRIC,
		"pressed": SewingSkin.THREAD_PURPLE,
		"hover_pressed": SewingSkin.THREAD_PURPLE,
	}
	for key in looks:
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = looks[key]
		sb.set_corner_radius_all(16)
		sb.border_color = SewingSkin.THREAD_PURPLE
		sb.set_border_width_all(3)
		btn.add_theme_stylebox_override(key, sb)
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", SewingSkin.INK)
	btn.add_theme_color_override("font_hover_color", SewingSkin.INK)
	btn.add_theme_color_override("font_pressed_color", SewingSkin.CREAM)
	btn.add_theme_color_override("font_hover_pressed_color", SewingSkin.CREAM)


## 키 한 번 누름과 같은 눌림→뗌 액션 쌍을 주입한다(RaceDirector 무수정 — Esc/R/M 등가).
func _tap_action(action: StringName) -> void:
	for pressed in [true, false]:
		var ev: InputEventAction = InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		ev.strength = 1.0 if pressed else 0.0
		Input.parse_input_event(ev)


func _on_child_entered(node: Node) -> void:
	if node == _touch or not (node is Control):
		return
	if node is TutorialDialog:
		_tutorial_count += 1
		node.tree_exiting.connect(_on_tutorial_exiting)
	else:
		_modal_count += 1
		node.tree_exiting.connect(_on_modal_exiting)
	_refresh_touch_block()


func _on_modal_exiting() -> void:
	_modal_count = maxi(_modal_count - 1, 0)
	_refresh_touch_block()


func _on_tutorial_exiting() -> void:
	_tutorial_count = maxi(_tutorial_count - 1, 0)
	_refresh_touch_block()


## 일시정지·일반 모달은 버튼을 숨기고, 튜토리얼 코치마크만 떠 있으면 보이게 둔 채 입력만 막는다.
func _refresh_touch_block() -> void:
	if _touch == null:
		return
	var hide: bool = _pause_visible or _modal_count > 0
	_touch.set_blocked(hide or _tutorial_count > 0, hide)


## 완주 줌아웃 스킵(아무 키) 등가 처리. FINISH_VIEW 동안엔 HUD가 숨고, 배경 ColorRect(SkyRect 등,
## mouse_filter STOP)가 GUI 단계에서 터치와 에뮬레이션 마우스를 소비해 RaceDirector의
## _unhandled_input까지 오지 않는다. 그래서 _input(GUI보다 먼저)에서 터치 눌림을 보고
## 눌림→뗌 액션 쌍을 주입해 "아무 키 입력"과 같은 스킵을 만든다.
func _input(event: InputEvent) -> void:
	if _touch == null or not _in_finish_view:
		return
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_tap_action(&"drift")


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
