class_name TouchControls
extends Control
## 게임플레이 온스크린 터치 버튼 (docs/mobile.md 1단계).
##
## 좌측 하단 ◀ ▶ 조향, 우측 하단 ▲ ▼ 속도 + DRIFT 홀드 + 그 위 USE(아이템 사용), 상단 우측 ‖ 일시정지.
## 버튼은 키를 흉내 내지 않고 InputMap 액션 자체를 주입한다: 눌림/뗌마다
## InputEventAction(action, pressed)을 Input.parse_input_event()로 보낸다. 그러면
## RaceDirector의 Input.is_action_pressed(조향·드리프트)와 _unhandled_input의
## is_action_pressed(속도·일시정지)가 키보드와 똑같은 경로로 값을 읽는다.
## 조향은 원래 디지털(눌림/안 눌림)이라 터치 = 키보드 등가이며 시뮬 코드는 무수정이다.
##
## 멀티터치는 InputEventScreenTouch/ScreenDrag의 index를 직접 추적해 처리한다
## (TouchScreenButton 대신 수동 추적을 고른 근거는 docs/mobile.md §4.1).
## - 조향·드리프트(홀드형): 손가락을 떼지 않고 옆 버튼으로 미끄러지면 전환(passby).
## - 속도·일시정지·아이템 사용(탭형): 터치가 시작된 버튼에서만 눌림을 인정한다(미끄러져 들어오면 무시).
##
## 순수 입력 어댑터 — 게임 값·판정에는 관여하지 않는다.

enum Btn { STEER_LEFT, STEER_RIGHT, SPEED_UP, SPEED_DOWN, DRIFT, PAUSE, USE_ITEM }

## 데스크톱 검증용 강제 표시 인자(`godot -- --touch-controls`). 마우스 왼쪽 버튼도 터치처럼 받는다.
const FORCE_ARG: String = "--touch-controls"

const ACTIONS: Dictionary = {
	Btn.STEER_LEFT: &"steer_left",
	Btn.STEER_RIGHT: &"steer_right",
	Btn.SPEED_UP: &"speed_up",
	Btn.SPEED_DOWN: &"speed_down",
	Btn.DRIFT: &"drift",
	Btn.PAUSE: &"pause",
	Btn.USE_ITEM: &"use_item",
}
## 홀드형(미끄러져 들어오기 허용) 버튼.
const HOLD_BUTTONS: Array = [Btn.STEER_LEFT, Btn.STEER_RIGHT, Btn.DRIFT]

# 레이아웃(1280×720 기준 캔버스 좌표). 조향·속도 버튼은 화면 좌우 가장자리에 붙이고,
# HUD가 터치 모드에서 하단 위젯을 버튼 위로 옮긴다(HUD._apply_touch_layout).
#  - 좌측: ◀ ▶를 왼쪽 끝·바닥에 나란히 → 그 위에 RISK 패널, 다시 그 위에 효과 카드 스택.
#  - 우측: ▲ ▼를 오른쪽 끝 열에 세로로 쌓고 DRIFT는 그 왼쪽 열 바닥 정렬 → ▲ 위에 SPEED 패널.
#    USE(아이템 사용)는 DRIFT 열 가운데, DRIFT 위 USE_ITEM_GAP 지점(오른손 엄지가 위로 뻗어 닿는 자리).
#  - 우상단 TIME 패널(오른쪽에서 238~8, 위 6~92) → 일시정지는 그 왼쪽.
const STEER_SIZE: float = 144.0
const SPEED_SIZE: float = 112.0
const DRIFT_SIZE: float = 132.0
const PAUSE_SIZE: float = 80.0
const USE_ITEM_SIZE: float = 112.0
## USE와 DRIFT 사이 간격. DRIFT를 누른 엄지가 조금 위로 밀려도 판정 영역(HIT_PAD)이 붙지 않게
## 일반 간격(BUTTON_GAP)보다 넓게 둔다(판정 영역 사이 8px).
const USE_ITEM_GAP: float = 24.0
## 화면 가장자리(좌·우·아래)와 버튼 사이 여백.
const EDGE_MARGIN: float = 16.0
## 이웃한 버튼 사이 간격.
const BUTTON_GAP: float = 16.0
## 버튼 윗변과 그 위로 옮긴 HUD 위젯(RISK·SPEED 패널) 사이 간격.
const HUD_GAP: float = 12.0
## 시각 사각형보다 넓게 잡는 판정 여유(엄지가 가장자리를 눌러도 인정).
const HIT_PAD: float = 8.0

const FILL_IDLE: Color = Color(0.913, 0.856, 0.717, 0.34)  # SewingSkin.FABRIC 반투명
const FILL_PRESSED: Color = Color(0.553, 0.384, 0.725, 0.72)  # SewingSkin.THREAD_PURPLE
const STITCH_IDLE: Color = Color(0.553, 0.384, 0.725, 0.7)
const STITCH_PRESSED: Color = Color(0.968, 0.929, 0.847, 0.95)  # SewingSkin.CREAM
const GLYPH_IDLE: Color = Color(0.278, 0.203, 0.153, 0.85)  # SewingSkin.INK
const GLYPH_PRESSED: Color = Color(0.968, 0.929, 0.847, 1.0)
## 슬롯이 빈 USE 버튼(비활성 표시): 채움·박음질·글자를 옅게.
const FILL_DISABLED: Color = Color(0.913, 0.856, 0.717, 0.16)
const STITCH_DISABLED: Color = Color(0.553, 0.384, 0.725, 0.3)
const GLYPH_DISABLED: Color = Color(0.278, 0.203, 0.153, 0.35)

## 터치 index → 현재 누르고 있는 버튼(없으면 -1). 마우스 강제 모드는 MOUSE_INDEX를 쓴다.
const MOUSE_INDEX: int = 1000

var _forced: bool = false
var _blocked: bool = false
var _touch_btn: Dictionary = {}
var _press_count: Dictionary = {}
# USE 버튼에 그릴 다음 아이템 아이콘(HUD가 슬롯 변화 때 넣는다). null이면 빈 슬롯 = 비활성 표시.
var _use_icon: Texture2D = null


## 온스크린 버튼을 보여야 하는가. 튜토리얼과 같은 기준(DisplayServer.is_touchscreen_available)에
## 웹 한정 navigator.maxTouchPoints 보조 판별과 커맨드라인 강제 인자를 더한다.
static func should_show() -> bool:
	if is_forced():
		return true
	if DisplayServer.is_touchscreen_available():
		return true
	if OS.has_feature("web"):
		var points: Variant = JavaScriptBridge.eval("navigator.maxTouchPoints || 0", true)
		if points != null and int(points) > 0:
			return true
	return false


static func is_forced() -> bool:
	return FORCE_ARG in OS.get_cmdline_user_args() or FORCE_ARG in OS.get_cmdline_args()


func _ready() -> void:
	name = "TouchControls"
	# 일시정지 중에도 뗌 처리·재표시를 할 수 있게 항상 처리한다(HUD는 PAUSABLE).
	process_mode = Node.PROCESS_MODE_ALWAYS
	# GUI 히트 테스트에서 빠진다 — 입력은 _input에서 직접 추적한다(아래 위젯 클릭을 막지 않음).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_forced = is_forced()
	for b in ACTIONS.keys():
		_press_count[b] = 0
	resized.connect(queue_redraw)
	visibility_changed.connect(_on_visibility_changed)


## 모달이나 일시정지 오버레이가 떠 있으면 버튼 입력을 막고 눌린 액션을 모두 뗀다.
## hide=false면 버튼은 보이게 둔 채 입력만 막는다(튜토리얼 코치마크가 버튼을 가리켜 설명할 때).
func set_blocked(value: bool, hide: bool = true) -> void:
	_blocked = value
	if value:
		release_all()
	visible = not (value and hide)


func is_blocked() -> bool:
	return _blocked


## USE 버튼 아이콘(다음에 쓸 아이템). null이면 비활성 표시로 그린다(탭은 그대로 받는다).
func set_use_icon(tex: Texture2D) -> void:
	if tex == _use_icon:
		return
	_use_icon = tex
	queue_redraw()


func use_icon() -> Texture2D:
	return _use_icon


## 버튼의 화면(캔버스) 사각형. 레이아웃은 현재 크기(뷰포트 1280×720)에 맞춰 계산한다.
func button_rect(b: int) -> Rect2:
	var w: float = size.x
	var h: float = size.y
	var steer_y: float = h - EDGE_MARGIN - STEER_SIZE
	var speed_x: float = w - EDGE_MARGIN - SPEED_SIZE
	var r: Rect2 = Rect2()
	match b:
		Btn.STEER_LEFT:
			r = Rect2(EDGE_MARGIN, steer_y, STEER_SIZE, STEER_SIZE)
		Btn.STEER_RIGHT:
			r = Rect2(EDGE_MARGIN + STEER_SIZE + BUTTON_GAP, steer_y, STEER_SIZE, STEER_SIZE)
		Btn.SPEED_UP:
			r = Rect2(
				speed_x, h - EDGE_MARGIN - SPEED_SIZE * 2.0 - BUTTON_GAP, SPEED_SIZE, SPEED_SIZE
			)
		Btn.SPEED_DOWN:
			r = Rect2(speed_x, h - EDGE_MARGIN - SPEED_SIZE, SPEED_SIZE, SPEED_SIZE)
		Btn.DRIFT:
			# 오른손 엄지가 쉬는 바닥 줄에 둔다(◀ ▶·▼와 같은 바닥선, 가장 자주 누르는 홀드 버튼).
			r = Rect2(
				speed_x - BUTTON_GAP - DRIFT_SIZE,
				h - EDGE_MARGIN - DRIFT_SIZE,
				DRIFT_SIZE,
				DRIFT_SIZE
			)
		Btn.PAUSE:
			r = Rect2(w - 238.0 - 16.0 - PAUSE_SIZE, 10.0, PAUSE_SIZE, PAUSE_SIZE)
		Btn.USE_ITEM:
			var drift: Rect2 = button_rect(Btn.DRIFT)
			r = Rect2(
				drift.get_center().x - USE_ITEM_SIZE * 0.5,
				drift.position.y - USE_ITEM_GAP - USE_ITEM_SIZE,
				USE_ITEM_SIZE,
				USE_ITEM_SIZE
			)
	return r


## 말풍선(Toast) 등 하단 중앙 요소가 피해야 할 가로 구간 [오른쪽 조향 버튼 오른쪽 끝, DRIFT 왼쪽 끝]
## (1280 폭 캔버스 기준 x, 판정 여유 제외). 터치 모드 배치 조정용 정적 계산.
static func bottom_free_span(view_w: float) -> Vector2:
	var steer_right: float = EDGE_MARGIN + STEER_SIZE * 2.0 + BUTTON_GAP
	var drift_left: float = view_w - EDGE_MARGIN - SPEED_SIZE - BUTTON_GAP - DRIFT_SIZE
	return Vector2(steer_right, drift_left)


func is_button_pressed(b: int) -> bool:
	return int(_press_count.get(b, 0)) > 0


## 버튼 누름(테스트·외부 헬퍼 겸용). 같은 버튼을 여러 손가락이 누르면 첫 누름에서만 주입한다.
func press_button(b: int) -> void:
	var n: int = int(_press_count.get(b, 0))
	_press_count[b] = n + 1
	if n == 0:
		_inject(ACTIONS[b], true)
		queue_redraw()


func release_button(b: int) -> void:
	var n: int = int(_press_count.get(b, 0))
	if n <= 0:
		return
	_press_count[b] = n - 1
	if n == 1:
		_inject(ACTIONS[b], false)
		queue_redraw()


## 눌린 모든 버튼을 뗀다(숨김·일시정지·모달 진입 시 액션이 눌린 채 남지 않게).
func release_all() -> void:
	_touch_btn.clear()
	for b in ACTIONS.keys():
		if int(_press_count[b]) > 0:
			_press_count[b] = 1
			release_button(b)


func _inject(action: StringName, pressed: bool) -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)


## 앱 전환·알림 등으로 창 포커스를 잃으면 뗌 이벤트가 오지 않을 수 있으므로 모두 뗀다.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		release_all()


## 재시작(reload_current_scene) 등으로 트리에서 빠질 때는 visibility_changed가 오지 않으므로,
## 주입한 액션이 눌린 채 남지 않게 여기서도 뗀다.
func _exit_tree() -> void:
	release_all()


func _hit(canvas_pos: Vector2, hold_only: bool) -> int:
	for b in ACTIONS.keys():
		if hold_only and not (b in HOLD_BUTTONS):
			continue
		if button_rect(b).grow(HIT_PAD).has_point(canvas_pos):
			return b
	return -1


func _to_local_pos(viewport_pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * viewport_pos


func _input(event: InputEvent) -> void:
	if _blocked or not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var st: InputEventScreenTouch = event
		_on_touch(st.index, _to_local_pos(st.position), st.pressed)
	elif event is InputEventScreenDrag:
		var sd: InputEventScreenDrag = event
		_on_drag(sd.index, _to_local_pos(sd.position))
	elif _forced and event is InputEventMouseButton:
		# 데스크톱 강제 모드 전용: 실제 마우스 왼쪽 버튼을 터치 한 개처럼 받는다.
		# 터치에서 에뮬레이션된 마우스 이벤트는 이미 터치로 처리했으므로 무시한다.
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.device != InputEvent.DEVICE_ID_EMULATION:
			_on_touch(MOUSE_INDEX, _to_local_pos(mb.position), mb.pressed)
	elif _forced and event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _touch_btn.has(MOUSE_INDEX) and mm.device != InputEvent.DEVICE_ID_EMULATION:
			_on_drag(MOUSE_INDEX, _to_local_pos(mm.position))


func _on_touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		var b: int = _hit(pos, false)
		if b < 0:
			return
		# 같은 index가 뗌 없이 다시 눌리는 비정상 순서 방어.
		if _touch_btn.has(index):
			var prev: int = _touch_btn[index]
			if prev >= 0:
				release_button(prev)
		_touch_btn[index] = b
		press_button(b)
		get_viewport().set_input_as_handled()
	elif _touch_btn.has(index):
		var held: int = _touch_btn[index]
		_touch_btn.erase(index)
		if held >= 0:
			release_button(held)
		get_viewport().set_input_as_handled()


func _on_drag(index: int, pos: Vector2) -> void:
	if not _touch_btn.has(index):
		return
	var held: int = _touch_btn[index]
	# 탭형 버튼에서 시작한 손가락은 버튼 밖으로 나가도 그대로 유지(뗄 때 한 번만 뗌 주입).
	if held >= 0 and not (held in HOLD_BUTTONS):
		get_viewport().set_input_as_handled()
		return
	var now: int = _hit(pos, true)
	if now == held:
		get_viewport().set_input_as_handled()
		return
	if held >= 0:
		release_button(held)
	_touch_btn[index] = now
	if now >= 0:
		press_button(now)
	get_viewport().set_input_as_handled()


# --- 드로잉 ---


func _draw() -> void:
	for b in ACTIONS.keys():
		_draw_button(b)


func _draw_button(b: int) -> void:
	var rect: Rect2 = button_rect(b)
	var on: bool = is_button_pressed(b)
	var radius: float = minf(rect.size.x, rect.size.y) * 0.24
	var off: bool = b == Btn.USE_ITEM and _use_icon == null and not on
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = FILL_PRESSED if on else (FILL_DISABLED if off else FILL_IDLE)
	sb.set_corner_radius_all(int(radius))
	sb.border_color = Color(0.278, 0.203, 0.153, 0.35)
	sb.set_border_width_all(2)
	draw_style_box(sb, rect)
	var stitch: Color = STITCH_PRESSED if on else (STITCH_DISABLED if off else STITCH_IDLE)
	SewingSkin.draw_stitch_border(self, rect, stitch, 7.0, radius, 2.0)
	var glyph: Color = GLYPH_PRESSED if on else (GLYPH_DISABLED if off else GLYPH_IDLE)
	var c: Vector2 = rect.get_center()
	var r: float = rect.size.x * 0.22
	match b:
		Btn.STEER_LEFT:
			_draw_triangle(c, r, Vector2.LEFT, glyph)
		Btn.STEER_RIGHT:
			_draw_triangle(c, r, Vector2.RIGHT, glyph)
		Btn.SPEED_UP:
			_draw_triangle(c, r, Vector2.UP, glyph)
		Btn.SPEED_DOWN:
			_draw_triangle(c, r, Vector2.DOWN, glyph)
		Btn.DRIFT:
			_draw_label(rect, "DRIFT", 26, glyph)
		Btn.PAUSE:
			var bw: float = rect.size.x * 0.11
			var bh: float = rect.size.y * 0.4
			draw_rect(Rect2(c + Vector2(-bw * 1.6, -bh * 0.5), Vector2(bw, bh)), glyph)
			draw_rect(Rect2(c + Vector2(bw * 0.6, -bh * 0.5), Vector2(bw, bh)), glyph)
		Btn.USE_ITEM:
			_draw_use(rect, glyph)


## USE 버튼: 다음 아이템 아이콘(위) + "USE" 글자(아래). 빈 슬롯이면 글자만 옅게 그린다.
func _draw_use(rect: Rect2, glyph: Color) -> void:
	var label_h: float = 30.0
	if _use_icon != null:
		var side: float = rect.size.x * 0.52
		var top: Vector2 = Vector2(rect.get_center().x - side * 0.5, rect.position.y + 12.0)
		draw_texture_rect(_use_icon, Rect2(top, Vector2(side, side)), false)
		var lr: Rect2 = Rect2(
			Vector2(rect.position.x, rect.end.y - label_h - 6.0), Vector2(rect.size.x, label_h)
		)
		_draw_label(lr, "USE", 22, glyph)
	else:
		_draw_label(rect, "USE", 24, glyph)


func _draw_triangle(c: Vector2, r: float, dir: Vector2, color: Color) -> void:
	var side: Vector2 = Vector2(-dir.y, dir.x)
	var pts: PackedVector2Array = PackedVector2Array(
		[c + dir * r, c - dir * r * 0.7 + side * r * 0.95, c - dir * r * 0.7 - side * r * 0.95]
	)
	draw_colored_polygon(pts, color)


func _draw_label(rect: Rect2, text: String, font_size: int, color: Color) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var ts: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pos: Vector2 = Vector2(
		rect.position.x + (rect.size.x - ts.x) * 0.5,
		(
			rect.position.y
			+ (rect.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		)
	)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
