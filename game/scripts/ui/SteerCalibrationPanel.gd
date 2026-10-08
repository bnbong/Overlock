class_name SteerCalibrationPanel
extends Control
## 데모 주행 HUD의 조향 감도 맞추기 패널(docs/sensitivity-calibration-plan.md "데모 주행 HUD").
##
## `.tscn` 없이 `SteerCalibrationPanel.new()`를 HUD(CanvasLayer)에 붙이면 _ready에서 스스로 UI를
## 짓고 현재 Tuning.steer_expo(저장값)에서 시작한다. 상단 중앙 빈 자리(미니맵 216px 오른쪽, TIME
## 패널·터치 일시정지 버튼 왼쪽)에 베이지 재봉 패치로 뜬다. 캔버스는 1280×720 고정이다.
##
## 값 규칙은 설정 화면의 "부드러움 %"와 같다. 왼쪽 = 반응 빠름(steer_expo 낮음), 오른쪽 = 부드러움
## (steer_expo 높음), 0~100% ↔ LeaderboardClient.STEER_EXPO_MIN..MAX, 1% 단위.
## 값이 바뀌면 Tuning.steer_expo에 바로 반영하고, 디스크 쓰기는 드래그를 놓을 때 바로, −/+ 버튼·
## 휠·[ ] 키(nudge)는 SAVE_DELAY 뒤 한 번으로 모은다. 저장은 LeaderboardClient.save_steer_expo만 쓴다.
## 저장에 실패하면 값은 이번 실행에 유지하고 상태 줄에 알린다.
##
## 모든 컨트롤은 포커스를 받지 않는다(FOCUS_NONE). 키보드 ←→(조향)·Enter·Space(아이템)가 패널에
## 먹히지 않게 하기 위해서다. 마우스·터치는 패치 영역에서만 막고 바깥은 그대로 통과시킨다.
## 다시 달리기·나가기는 시그널만 낸다(저장 반영 flush_save와 화면 전환은 호출자 몫).

signal restart_requested
signal finish_requested

## 디바운스 저장 지연(초). −/+ 연타·[ ] 키 반복을 이 간격 뒤 한 번의 디스크 쓰기로 모은다.
const SAVE_DELAY: float = 0.6
const TITLE_TEXT: String = "조향 감도 맞추기"
const HELP_TEXT: String = "빠르게: 작은 조향에도 잘 꺾임 · 부드럽게: 천천히 꺾임"
const NOTE_TEXT: String = "설정에서도 언제든 바꿀 수 있어요"
const SAVE_FAIL_MSG: String = "저장하지 못했어요. 이번 주행에는 적용되지만 설정은 남지 않을 수 있어요"
## 캔버스 위쪽 여백(px).
const TOP_MARGIN: float = 8.0
## 패치 폭(1280 캔버스 기준). 데스크톱은 미니맵(~216)·TIME 패널(1042~) 사이, 터치는 일시정지 버튼
## (946~1026) 왼쪽까지 쓴다(가운데 640 기준 반폭 ≤ 306).
const WIDTH_DESKTOP: float = 500.0
const WIDTH_TOUCH: float = 600.0
## 터치 버튼 높이(논리). 패널이 화면 위를 너무 가리지 않게 MenuTouch.MIN_H(84)보다 낮게 잡는다.
const TOUCH_BUTTON_H: float = 56.0

const _WARN: Color = Color(0.72, 0.2, 0.16)
# 슬라이더 재봉 톤(SettingsScreen과 동일).
const _THREAD_HI: Color = Color(0.616, 0.435, 0.784)
const _KNOT_HI: Color = Color(0.6, 0.44, 0.34)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
const _RADIUS: float = 14.0
const _STITCH_INSET: float = 6.0

## 직전 패널의 저장 실패를 다음 패널에 넘기는 플래그. 재시작 리로드로 안내가 사라지지 않게,
## flush_save 실패 때 세우고 새 패널의 _ready가 소비해 실패 안내를 바로 띄운다.
static var pending_fail_notice: bool = false

var _touch: bool = false
var _dirty: bool = false
var _grabber_d: int = 18
var _patch: PanelContainer
var _slider: HSlider
var _value_label: Label
var _status_label: Label
var _save_timer: Timer


func _init() -> void:
	# 기본 노드 이름. 호출자가 add_child 전에 다른 이름을 주면 그 이름을 쓴다.
	name = "SteerCalibrationPanel"


func _ready() -> void:
	_touch = MenuTouch.active()
	_grabber_d = MenuTouch.GRABBER_D if _touch else 18
	# 루트는 배치용 틀일 뿐 입력을 받지 않는다(패치 PanelContainer만 STOP).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_save_timer = Timer.new()
	_save_timer.name = "SaveTimer"
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	# 트리가 paused여도 예약된 저장이 돌아야 한다(HUD는 PAUSABLE).
	_save_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_save_timer.timeout.connect(_on_save_timer_timeout)
	add_child(_save_timer)
	_build()
	_slider.set_value_no_signal(roundf(expo_to_percent(Tuning.steer_expo)))
	_update_value_label()
	if pending_fail_notice:
		pending_fail_notice = false
		_set_status(SAVE_FAIL_MSG)
	_slider.value_changed.connect(_on_slider_changed)
	_slider.drag_ended.connect(_on_slider_drag_ended)
	_fit()


## 씬 이탈(메인 복귀·재시작 리로드 등)로 트리에서 빠질 때 디바운스 중인 저장을 마저 쓴다.
## 이미 flush된 뒤면 _dirty가 false라 아무것도 쓰지 않는다. LeaderboardClient는 오토로드라 이 시점에도 살아 있다.
func _exit_tree() -> void:
	if _dirty:
		flush_save()


## 앱 종료 요청(창 닫기) 때도 마지막 SAVE_DELAY 안의 변경이 유실되지 않게 바로 쓴다.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _dirty:
		flush_save()


## [ ] 키용: 현재 %에 delta_percent를 더해 0..100으로 자른다. 값이 바뀌면 Tuning·표시를 갱신하고
## 디바운스 저장을 예약한다(value_changed 경로).
func nudge(delta_percent: int) -> void:
	if _slider == null:
		return
	var next: float = clampf(roundf(_slider.value) + float(delta_percent), 0.0, 100.0)
	if next == _slider.value:
		return
	_slider.value = next


## 예약된 저장이 있으면 지금 쓴다. 쓰기 실패면 상태 줄에 알리고 false. 저장할 변경이 없으면 true.
func flush_save() -> bool:
	if _save_timer != null:
		_save_timer.stop()
	if not _dirty:
		return true
	if LeaderboardClient.save_steer_expo(Tuning.steer_expo):
		_dirty = false
		pending_fail_notice = false
		_set_status("")
		return true
	pending_fail_notice = true
	_set_status(SAVE_FAIL_MSG)
	return false


## steer_expo(∈[MIN,MAX]) → 부드러움 퍼센트(0..100). SettingsScreen._expo_to_percent와 동형.
static func expo_to_percent(expo: float) -> float:
	var span: float = LeaderboardClient.STEER_EXPO_MAX - LeaderboardClient.STEER_EXPO_MIN
	return clampf((expo - LeaderboardClient.STEER_EXPO_MIN) / span * 100.0, 0.0, 100.0)


## 부드러움 퍼센트(0..100) → steer_expo(∈[MIN,MAX]). SettingsScreen._percent_to_expo와 동형.
static func percent_to_expo(percent: float) -> float:
	var span: float = LeaderboardClient.STEER_EXPO_MAX - LeaderboardClient.STEER_EXPO_MIN
	return LeaderboardClient.STEER_EXPO_MIN + percent / 100.0 * span


# --- 입력 처리 ---


## 값 변경(드래그·휠·−/+·nudge 공통): Tuning에 바로 반영하고 디바운스 저장을 다시 예약한다.
func _on_slider_changed(percent: float) -> void:
	Tuning.steer_expo = percent_to_expo(percent)
	_update_value_label()
	_dirty = true
	_save_timer.start(SAVE_DELAY)


## 드래그를 놓으면 기다리지 않고 바로 쓴다.
func _on_slider_drag_ended(_value_changed: bool) -> void:
	flush_save()


func _on_save_timer_timeout() -> void:
	flush_save()


func _update_value_label() -> void:
	_value_label.text = "부드러움 %d%%" % int(roundf(_slider.value))


func _set_status(text: String) -> void:
	_status_label.text = text
	_status_label.visible = not text.is_empty()


# --- UI 구성 ---


## 패치(PanelContainer) 안에 다섯 줄을 쌓는다.
##  1) 제목 ·············· 부드러움 NN%
##  2) 도움말
##  3) 빠르게 ◀ [−] ━━●━━ [+] ▶ 부드럽게
##  4) 안내 ········ [다시 달리기] [나가기]
##  5) 상태(평소 숨김, 저장 실패 시 경고색)
func _build() -> void:
	var body: int = 21 if _touch else 15
	var btn_font: int = 22 if _touch else 16
	_patch = PanelContainer.new()
	_patch.name = "Patch"
	_patch.mouse_filter = Control.MOUSE_FILTER_STOP
	_patch.focus_mode = Control.FOCUS_NONE
	var empty: StyleBoxEmpty = StyleBoxEmpty.new()
	empty.content_margin_left = 16.0
	empty.content_margin_right = 16.0
	empty.content_margin_top = 10.0
	empty.content_margin_bottom = 12.0
	_patch.add_theme_stylebox_override("panel", empty)
	_patch.draw.connect(_draw_patch)
	_patch.resized.connect(_patch.queue_redraw)
	add_child(_patch)
	_patch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_patch.add_child(col)

	var head: HBoxContainer = HBoxContainer.new()
	col.add_child(head)
	var title: Label = _label(TITLE_TEXT, 24 if _touch else 20, SewingSkin.INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_value_label = _label("", 24 if _touch else 18, SewingSkin.THREAD_PURPLE)
	_value_label.name = "ValueLabel"
	head.add_child(_value_label)

	col.add_child(_label(HELP_TEXT, body, SewingSkin.INK_SOFT))

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	row.add_child(_label("빠르게 ◀", body, SewingSkin.INK))
	var minus: Button = _button("−", btn_font, true)
	minus.name = "MinusButton"
	minus.pressed.connect(nudge.bind(-1))
	row.add_child(minus)
	_slider = HSlider.new()
	_slider.name = "SteerSlider"
	_slider.min_value = 0.0
	_slider.max_value = 100.0
	_slider.step = 1.0
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.custom_minimum_size.y = float(_grabber_d) + 4.0
	_skin_slider(_slider)
	row.add_child(_slider)
	var plus: Button = _button("+", btn_font, true)
	plus.name = "PlusButton"
	plus.pressed.connect(nudge.bind(1))
	row.add_child(plus)
	row.add_child(_label("▶ 부드럽게", body, SewingSkin.INK))

	var foot: HBoxContainer = HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	col.add_child(foot)
	var note: Label = _label(NOTE_TEXT, body, SewingSkin.INK_SOFT)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(note)
	var restart: Button = _button("다시 달리기", btn_font)
	restart.name = "RestartButton"
	restart.pressed.connect(restart_requested.emit)
	foot.add_child(restart)
	var finish: Button = _button("나가기", btn_font)
	finish.name = "FinishButton"
	finish.pressed.connect(finish_requested.emit)
	foot.add_child(finish)

	_status_label = _label("", body, _WARN)
	_status_label.name = "StatusLabel"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.visible = false
	col.add_child(_status_label)
	# 상태 줄이 나타나거나 사라지면 패치 높이를 내용에 다시 맞춘다.
	_patch.minimum_size_changed.connect(_fit)


## 상단 중앙 앵커 + 위 여백 TOP_MARGIN, 높이는 패치 내용의 최소 높이에 맞춘다.
func _fit() -> void:
	var w: float = WIDTH_TOUCH if _touch else WIDTH_DESKTOP
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -w * 0.5
	offset_right = w * 0.5
	offset_top = TOP_MARGIN
	offset_bottom = TOP_MARGIN + _patch.get_combined_minimum_size().y


## 베이지 원단 패치 + 실 보라 박음질 테두리(SewingSkin 정적 헬퍼).
func _draw_patch() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, _patch.size)
	SewingSkin.draw_patch(_patch, rect, SewingSkin.FABRIC, _RADIUS, true)
	SewingSkin.draw_stitch_border(
		_patch, rect, SewingSkin.THREAD_PURPLE, _STITCH_INSET, _RADIUS, 2.0
	)


func _label(text: String, font_size: int, color: Color) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


## 포커스를 받지 않는 재봉 톤 버튼(SettingsScreen._skin_button 계열). square면 −/+ 정사각 버튼.
## 터치 배치에서는 손가락 높이(TOUCH_BUTTON_H)로 키운다.
func _button(text: String, font_size: int, square: bool = false) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", SewingSkin.INK)
	b.add_theme_color_override("font_hover_color", _INK_HOVER)
	b.add_theme_color_override("font_pressed_color", _INK_HOVER)
	var pad: float = 6.0 if square else 12.0
	b.add_theme_stylebox_override(
		"normal", _box(Color(0.831, 0.753, 0.6), SewingSkin.THREAD_PURPLE, pad)
	)
	b.add_theme_stylebox_override("hover", _box(Color(0.906, 0.835, 0.686), _THREAD_HI, pad))
	b.add_theme_stylebox_override("pressed", _box(Color(0.761, 0.682, 0.541), SewingSkin.KNOT, pad))
	var h: float = TOUCH_BUTTON_H if _touch else 32.0
	b.custom_minimum_size = Vector2(h if square else 0.0, h)
	return b


## 재봉 톤 슬라이더: 원단 그늘 트랙 + 실 보라 채움 + 단추(매듭) 그래버(SettingsScreen._skin_slider와 동형).
func _skin_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = SewingSkin.FABRIC_DEEP
	track.set_corner_radius_all(4)
	# 터치 배치에서는 트랙을 두껍게(손가락으로 짚기 쉽게) 한다.
	var thick: float = 4.0 if _grabber_d <= 18 else 9.0
	track.content_margin_top = thick
	track.content_margin_bottom = thick
	slider.add_theme_stylebox_override("slider", track)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = SewingSkin.THREAD_PURPLE
	fill.set_corner_radius_all(4)
	slider.add_theme_stylebox_override("grabber_area", fill)
	var fill_hi: StyleBoxFlat = fill.duplicate()
	fill_hi.bg_color = _THREAD_HI
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	slider.add_theme_icon_override("grabber", _make_grabber(SewingSkin.KNOT, _grabber_d))
	slider.add_theme_icon_override("grabber_highlight", _make_grabber(_KNOT_HI, _grabber_d))


## 단추(매듭) 모양 그래버 텍스처(안티에일리어스 원). SettingsScreen._make_grabber와 동형. d는 지름(px).
static func _make_grabber(color: Color, d: int = 18) -> ImageTexture:
	var img: Image = Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c: float = (d - 1) * 0.5
	var r: float = c - 1.0
	for y in range(d):
		for x in range(d):
			var dist: float = Vector2(x - c, y - c).length()
			if dist <= r:
				img.set_pixel(x, y, color)
			elif dist <= r + 1.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, r + 1.0 - dist))
	return ImageTexture.create_from_image(img)


static func _box(bg: Color, border: Color, pad: float = 12.0) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb
