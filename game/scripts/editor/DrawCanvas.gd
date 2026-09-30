class_name DrawCanvas
extends Control
## 트랙 에디터의 유일한 _draw 노드 (track_editor.md §3). 순수 뷰 + 입력 수집.
##
## 좌표는 항상 월드 단위로 다루고 그릴 때만 screen = world·zoom + pan 변환한다
## (§12 함정 7). 스트로크 데이터는 TrackEditor가 소유하고, 여기서는 진행 중 원시
## 스트로크만 로컬 보관해 즉시 피드백을 그린다. 릴리스 시 stroke_committed로 넘긴다.
##
## 배경 패치·원시 스트로크·평활 중심선·fail 코리도·시작/끝 마커·검증 마커·그리드를
## 한 곳에서 그린다(레이어 분리 불필요). 스킨은 SewingSkin 팔레트로 통일.

signal stroke_committed(raw: PackedVector2Array)
# 끝부분 자르기(TRIM): 누름·드래그로 자를 지점을 고르고 뗄 때 한 번에 자른다. 누르지 않은 채
# 움직이면 hover로 잘릴 구간을 미리 보여 준다. 판정·적용은 TrackEditor가 한다.
signal trim_begin(world_pos: Vector2)
signal trim_dragged(world_pos: Vector2)
signal trim_end
signal trim_hover(world_pos: Vector2)
signal trim_hover_exit
# 카메라(zoom/pan)가 바뀌었다(배율 표시 갱신용). 경로 좌표와 무관하다.
signal view_changed
# 아이템 도구(ITEM): 누름·드래그·뗌을 월드 좌표로 넘긴다. 배치·선택·이동 판정은 EditorItemTool이 한다.
# 아이템 도구에서는 스트로크를 시작하지 않는다.
signal item_press(world_pos: Vector2)
signal item_drag(world_pos: Vector2)
signal item_release
# 구간 지우기(ERASE): 누름·드래그 위치를 월드 좌표로 넘기고, 그리기 영역 안에서 떼면 erase_end,
# 영역 밖에서 떼거나 뗌을 놓치거나 취소되면 erase_cancel(문서 불변). 판정·적용은 EditorEraseTool이 한다.
# continuous=false는 영역 밖에 나갔다가 들어온 첫 위치다(그 사이를 브러시로 잇지 않는다).
signal erase_begin(world_pos: Vector2)
signal erase_dragged(world_pos: Vector2, continuous: bool)
signal erase_end
signal erase_cancel

# 도구. 값은 테스트 복귀 스냅샷에 정수로 남으므로 기존 값(DRAW=0, TRIM=1)을 유지하고 뒤에 붙인다.
enum Mode { DRAW, TRIM, PAN, ITEM, ERASE }

const MIN_SAMPLE_PX: float = 4.0  # 최소 이동 4px마다 원시 점 추가
# 새 문서 시작 배율. 수동 축소·전체 보기의 하한(ZOOM_MIN)은 이보다 낮아, 허용 최대 길이(8000)의 직선
# 트랙도 844×390 터치 레이아웃의 그리기 영역(기준 해상도에서 약 1264×454)에 담긴다.
const ZOOM_DEFAULT: float = 0.15
const ZOOM_MIN: float = 0.04
const ZOOM_MAX: float = 4.0
const ZOOM_STEP: float = 1.1  # 휠 한 칸
const ZOOM_BUTTON_STEP: float = 1.4  # +/− 버튼 한 번
const GRID_SPACING: float = 100.0
const FIT_MARGIN_PX: float = 28.0  # 전체 보기 화면 여백(마커 반경 + 여유)

const BG_COLOR: Color = Color(0.145, 0.128, 0.155, 1.0)
const GRID_COLOR: Color = Color(0.42, 0.36, 0.52, 0.14)
const AXIS_COLOR: Color = Color(0.5, 0.42, 0.62, 0.28)
const RAW_COLOR: Color = Color(0.86, 0.80, 0.66, 0.75)  # 진행 중 원시 스트로크(옅은 크림)
const CENTER_COLOR: Color = Color(0.72, 0.56, 0.96, 0.98)  # 중심선(실 보라)
const CORRIDOR_COLOR: Color = Color(0.34, 0.24, 0.44, 0.30)  # fail 코리도(옅은 밴드)
const SAFE_COLOR: Color = Color(0.42, 0.30, 0.58, 0.30)
const START_COLOR: Color = Color(0.40, 0.90, 0.55, 1.0)
const FINISH_COLOR: Color = Color(0.98, 0.84, 0.34, 1.0)
const ARROW_COLOR: Color = Color(0.95, 0.55, 0.15, 1.0)
const VIOL_HARD_COLOR: Color = Color(0.90, 0.24, 0.22, 0.95)
const VIOL_SOFT_COLOR: Color = Color(0.98, 0.66, 0.28, 0.9)
const TRIM_COLOR: Color = Color(0.95, 0.30, 0.28, 0.95)  # 잘릴 구간 미리보기
const PREVIEW_COLOR: Color = Color(0.45, 0.92, 0.85, 0.95)  # 길이 조절·자동 수정 미리보기 경로
const THIMBLE_COLOR: Color = Color(1.0, 0.82, 0.28, 1.0)  # 골무(HUD 효과 카드와 같은 톤)
const AUTOPILOT_COLOR: Color = Color(0.93, 0.46, 0.62, 1.0)  # 엄마 찬스
const REVIEW_COLOR: Color = Color(1.0, 0.25, 0.2, 1.0)  # 검토 필요 아이템 테두리
const SELECT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)  # 선택 아이템 테두리
const FOCUS_COLOR: Color = Color(0.35, 0.85, 1.0, 1.0)  # 검증 항목 "해당 위치로 이동" 강조
const GAP_COLOR: Color = Color(1.0, 0.36, 0.30, 1.0)  # 틈 끝점(이어 그릴 곳)
const BRUSH_COLOR: Color = Color(1.0, 0.95, 0.85, 0.8)  # 지우기 브러시 원
# 틈 끝점 고리 반경: TrackEditor의 이어 그리기 스냅 반경(SNAP_PX 24, 월드 최소 28)과 같게 그린다.
const GAP_RING_PX: float = 24.0
const GAP_RING_MIN: float = 28.0
const ITEM_ICON_PX: float = 22.0  # 아이템 아이콘 화면 크기(줌과 무관)
# 게임 아이템과 같은 스프라이트(ItemField·HUD와 같은 에셋).
const ICON_THIMBLE: Texture2D = preload("res://assets/gfx/item_thimble.png")
const ICON_AUTOPILOT: Texture2D = preload("res://assets/gfx/item_moms_chance.png")
# 최대 줌아웃에서도 보이도록 화면 기준 최소 크기(px)로 그리는 값.
const MIN_BAND_PX: float = 3.0  # 코리도 밴드 최소 두께

var mode: int = Mode.DRAW
# 구간 지우기 미리보기(EditorEraseTool이 넣는다. {segs, refused, start?, gap?}, 빈 Dictionary면 끔).
var erase_preview: Dictionary = {}:
	set(value):
		erase_preview = value
		queue_redraw()

var _zoom: float = ZOOM_DEFAULT
var _pan: Vector2 = Vector2.ZERO
var _view_inited: bool = false
var _pending_fit: Rect2 = Rect2()  # 크기가 정해지기 전에 요청된 전체 보기(월드 bounds)
var _last_size: Vector2 = Vector2.ZERO

var _active_raw: PackedVector2Array = PackedVector2Array()
var _drawing: bool = false
var _last_screen: Vector2 = Vector2.ZERO

var _panning: bool = false
var _last_pan: Vector2 = Vector2.ZERO
var _trimming: bool = false

# TrackEditor가 밀어 넣는 표시 데이터.
var _centerline: PackedVector2Array = PackedVector2Array()
var _safe: float = 42.0
var _fail: float = 90.0
var _curv_viol: Array = []
var _prox_viol: Array = []
var _trim_from: int = -1  # 잘릴 구간 시작 점 index(-1이면 미리보기 없음)
var _item_marks: Array = []  # [{pos(월드), type, review(bool)}]
var _preview: PackedVector2Array = PackedVector2Array()  # 적용 전 미리보기 경로(비면 없음)
var _item_active: bool = false  # 아이템 도구 누름 중
var _focus_points: PackedVector2Array = PackedVector2Array()  # 검증 항목 강조 위치(월드)
var _gap: int = -1  # 틈 index(EditorDoc gap). _centerline[_gap-1]과 [_gap] 사이는 그리지 않는다
var _erasing: bool = false
var _erase_outside: bool = false  # 지우기 드래그가 그리기 영역 밖에 나가 있다
var _brush_on: bool = false
var _brush_screen: Vector2 = Vector2.ZERO
# 마지막 포인터 위치(화면)와 그때의 월드 좌표. 드래그 중 카메라가 바뀌어 포인터 아래 월드 점이 달라지면
# (키·버튼 줌, 전체 보기, 화면 이동) 이전 위치와 잇지 않는다(_on_view_jump).
var _pointer_screen: Vector2 = Vector2.ZERO
var _pointer_world: Vector2 = Vector2.ZERO


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	_last_size = size
	view_changed.connect(_on_view_jump)


func world_to_screen(w: Vector2) -> Vector2:
	return w * _zoom + _pan


func screen_to_world(s: Vector2) -> Vector2:
	return (s - _pan) / _zoom


## 화면 기준 반경 px를 현재 배율의 월드 거리로 바꾼다(최소 min_world). 스냅·자르기·선택 히트 영역용.
func world_radius(px: float, min_world: float) -> float:
	return maxf(min_world, px / _zoom)


## 중심선/폭 갱신(스트로크·편집 후 TrackEditor가 호출). gap은 틈 위치(EditorDoc.gap_index, 없으면 -1)이며
## 틈 선분은 그리지 않고 두 끝점을 강조한다.
func set_track(centerline: PackedVector2Array, safe: float, fail: float, gap: int = -1) -> void:
	_centerline = centerline
	_safe = safe
	_fail = fail
	_gap = gap
	queue_redraw()


func set_markers(curv: Array, prox: Array) -> void:
	_curv_viol = curv
	_prox_viol = prox
	queue_redraw()


func clear_markers() -> void:
	_curv_viol = []
	_prox_viol = []
	queue_redraw()


func set_mode(m: int) -> void:
	cancel_input()
	mode = m
	if m != Mode.TRIM:
		set_trim_preview(-1)
	if m != Mode.ERASE:
		_brush_on = false
		erase_preview = {}
	mouse_default_cursor_shape = CURSOR_DRAG if m == Mode.PAN else CURSOR_ARROW
	if m == Mode.ITEM:
		mouse_default_cursor_shape = CURSOR_POINTING_HAND


## 잘릴 구간(index 이후) 강조. -1이면 끈다.
func set_trim_preview(from_index: int) -> void:
	if _trim_from == from_index:
		return
	_trim_from = from_index
	queue_redraw()


## 아이템 표시(편집 문서의 아이템 월드 좌표). 배치 도구는 뒤 단계에서 붙는다.
func set_items(marks: Array) -> void:
	_item_marks = marks
	queue_redraw()


## 적용 전 미리보기 경로(길이 조절·자동 수정). 빈 배열이면 끈다. 문서 경로는 바꾸지 않는다.
func set_preview(path: PackedVector2Array) -> void:
	_preview = path
	queue_redraw()


## 화면 상태(테스트 복귀 스냅샷용). 경로 좌표와 무관한 카메라 값만 다룬다.
func get_view() -> Dictionary:
	if not _view_inited:
		_reset_view()
	return {"zoom": _zoom, "pan": _pan}


func set_view(zoom: float, pan: Vector2) -> void:
	_zoom = clampf(zoom, ZOOM_MIN, ZOOM_MAX)
	_pan = pan
	_view_inited = true
	_pending_fit = Rect2()
	queue_redraw()
	view_changed.emit()


## 새 문서 카메라: 시작 배율(ZOOM_DEFAULT), 월드 원점을 그리기 영역 중앙에.
func reset_view() -> void:
	set_view(ZOOM_DEFAULT, size * 0.5)


## 그리기 영역 중앙을 기준으로 배율을 factor배(+/− 버튼).
func zoom_by(factor: float) -> void:
	_apply_zoom(size * 0.5, factor)


## 전체 보기: 월드 bounds(경로 + 폭 여유를 호출자가 포함)가 그리기 영역에 들어오게 카메라만 맞춘다.
## 크기가 아직 정해지지 않았으면(씬 진입 직후) 크기가 정해질 때 적용한다.
func fit_rect(bounds: Rect2) -> void:
	if size.x < 2.0 or size.y < 2.0:
		_pending_fit = bounds
		_view_inited = false
		return
	var avail: Vector2 = size - Vector2.ONE * FIT_MARGIN_PX * 2.0
	var bw: float = maxf(bounds.size.x, 1.0)
	var bh: float = maxf(bounds.size.y, 1.0)
	var z: float = clampf(minf(avail.x / bw, avail.y / bh), ZOOM_MIN, ZOOM_MAX)
	set_view(z, size * 0.5 - bounds.get_center() * z)


## 경로를 전체 보기로 맞춘다(폭 fail과 화면 마커 여백 포함). 경로가 없으면 새 문서 카메라.
func fit_path(path: PackedVector2Array, fail: float) -> void:
	if path.size() < 2:
		reset_view()
		return
	var r: Rect2 = Rect2(path[0], Vector2.ZERO)
	for p in path:
		r = r.expand(p)
	fit_rect(r.grow(fail))


## 진행 중 입력(그리기·자르기·이동)을 버린다. 확인창이 뜨거나 화면을 떠날 때 상태가 남지 않게 한다.
func cancel_input() -> void:
	_drawing = false
	_active_raw = PackedVector2Array()
	_panning = false
	if _item_active:
		_item_active = false
		item_release.emit()
	if _trimming:
		_trimming = false
		trim_hover_exit.emit()  # 취소는 자르지 않는다(미리보기만 끔)
	if _erasing:
		_erasing = false
		erase_cancel.emit()  # 취소는 지우지 않는다
	queue_redraw()


func is_busy() -> bool:
	return _drawing or _panning or _trimming or _item_active or _erasing


## 월드 점을 그리기 영역 중앙으로 옮긴다(zoom은 min_zoom보다 작으면 올린다). 카메라만 바뀐다.
func center_on(world: Vector2, min_zoom: float = 0.0) -> void:
	var z: float = maxf(_zoom, min_zoom)
	set_view(z, size * 0.5 - world * z)


## 검증 항목 위치 강조(빈 배열이면 끔).
func set_focus(points: PackedVector2Array) -> void:
	_focus_points = points
	queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			if mode == Mode.TRIM and not _trimming:
				trim_hover_exit.emit()
			if _brush_on:
				_brush_on = false
				queue_redraw()
		NOTIFICATION_RESIZED:
			_on_resized()
		NOTIFICATION_FOCUS_EXIT, NOTIFICATION_VISIBILITY_CHANGED:
			# 포커스를 잃거나 숨겨지면 진행 중 입력을 버린다(뗌 이벤트를 못 받는 경우 대비).
			if is_busy():
				cancel_input()
		NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if is_busy():
				cancel_input()


## 크기가 바뀌면 보던 월드 중심을 유지하고, 미뤄 둔 전체 보기가 있으면 적용한다.
func _on_resized() -> void:
	if _pending_fit.has_area() and size.x >= 2.0 and size.y >= 2.0:
		var r: Rect2 = _pending_fit
		_pending_fit = Rect2()
		fit_rect(r)
	elif _view_inited and _last_size.x > 0.0:
		_pan += (size - _last_size) * 0.5
		queue_redraw()
	_last_size = size


func _reset_view() -> void:
	if _pending_fit.has_area() and size.x >= 2.0:
		var r: Rect2 = _pending_fit
		_pending_fit = Rect2()
		fit_rect(r)
		return
	_zoom = ZOOM_DEFAULT
	_pan = size * 0.5
	_view_inited = true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)
	elif event is InputEventMagnifyGesture:
		# 트랙패드·터치 핀치(가능한 플랫폼에서만). 필수 조작은 +/− 버튼이다.
		var mg: InputEventMagnifyGesture = event
		_apply_zoom(mg.position, mg.factor)
	elif event is InputEventPanGesture:
		_pan -= (event as InputEventPanGesture).delta * 8.0
		queue_redraw()
		view_changed.emit()


func _handle_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_apply_zoom(event.position, ZOOM_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_apply_zoom(event.position, 1.0 / ZOOM_STEP)
		MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
			_panning = event.pressed
			_last_pan = event.position
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_left(event.position)
			else:
				_release_left(event.position)


func _press_left(pos: Vector2) -> void:
	grab_focus()
	cancel_input()
	_track_pointer(pos)
	match mode:
		Mode.TRIM:
			_trimming = true
			trim_begin.emit(screen_to_world(pos))
		Mode.PAN:
			_panning = true
			_last_pan = pos
		Mode.ITEM:
			_item_active = true
			item_press.emit(screen_to_world(pos))
		Mode.ERASE:
			_erasing = true
			_erase_outside = false
			_brush_on = true
			_brush_screen = pos
			erase_begin.emit(screen_to_world(pos))
		_:
			_drawing = true
			_active_raw = PackedVector2Array([screen_to_world(pos)])
			_last_screen = pos
			queue_redraw()


## 왼쪽 뗌. 그리기 영역 밖에서 떼도(마우스 포커스가 캔버스에 남아 이벤트가 온다) 같은 처리다.
## 단 구간 지우기는 영역 안에서 뗐을 때만 적용하고, 밖에서 떼거나 뗌을 놓치면(pos 없음) 취소한다.
func _release_left(pos: Vector2 = Vector2.INF) -> void:
	if _drawing:
		_finish_stroke()
	if _erasing:
		_erasing = false
		_brush_on = false  # 터치에서는 손가락을 뗀 뒤 브러시 원이 남지 않게 한다
		queue_redraw()
		if Rect2(Vector2.ZERO, size).has_point(pos):
			erase_end.emit()
		else:
			erase_cancel.emit()
	if _trimming:
		_trimming = false
		trim_end.emit()
	if _item_active:
		_item_active = false
		item_release.emit()
	if mode == Mode.PAN:
		_panning = false


func _handle_motion(event: InputEventMouseMotion) -> void:
	var left: bool = (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	_track_pointer(event.position)
	# 뗌 이벤트를 놓친 채(창 밖에서 뗌 등) 버튼 없이 움직이면 뗀 것으로 마무리한다.
	var any_left: bool = _drawing or _trimming or _item_active or _erasing
	if not left and (any_left or (_panning and mode == Mode.PAN)):
		var other: bool = (
			(event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
		)
		if not (_panning and other):
			_release_left()
	if _panning:
		_pan += event.position - _last_pan
		_last_pan = event.position
		queue_redraw()
		view_changed.emit()
		return
	if mode == Mode.ITEM:
		if _item_active and left:
			item_drag.emit(screen_to_world(event.position))
		return
	if mode == Mode.ERASE:
		_erase_motion(event.position, left)
		return
	if mode == Mode.TRIM:
		if _trimming and left:
			trim_dragged.emit(screen_to_world(event.position))
		elif not _trimming:
			trim_hover.emit(screen_to_world(event.position))
		return
	if _drawing and left:
		if event.position.distance_to(_last_screen) >= MIN_SAMPLE_PX:
			_active_raw.append(screen_to_world(event.position))
			_last_screen = event.position
			queue_redraw()


## 진행 중 스트로크를 지금까지 그린 원시 점으로 마무리한다(뗌·카메라 점프 공용).
func _finish_stroke() -> void:
	_drawing = false
	var raw: PackedVector2Array = _active_raw
	_active_raw = PackedVector2Array()
	queue_redraw()
	if raw.size() >= 1:
		stroke_committed.emit(raw)


func _track_pointer(pos: Vector2) -> void:
	_pointer_screen = pos
	_pointer_world = screen_to_world(pos)


## 카메라가 바뀌었을 때: 포인터 아래 월드 점이 그대로면(포인터 기준 휠 줌) 아무것도 하지 않는다. 달라졌으면
## 지우기는 다음 이동을 이전 위치와 잇지 않고(문지르지 않은 구간을 지우지 않게), 그리기는 지금까지 그린
## 스트로크로 마무리한다(새 위치까지 직선이 끼어들지 않게). 끝부분 자르기·아이템 드래그는 현재 위치만 판정해
## 보간이 없으므로 그대로 둔다.
func _on_view_jump() -> void:
	if not (_drawing or _erasing):
		return
	var now: Vector2 = screen_to_world(_pointer_screen)
	if now.distance_to(_pointer_world) * _zoom < 0.5:
		return
	_pointer_world = now
	if _erasing:
		_erase_outside = true
	if _drawing:
		_finish_stroke()


## 지우기 도구 이동: 브러시 원을 따라 그리고, 누르는 중이면 영역 안 위치만 넘긴다.
func _erase_motion(pos: Vector2, left: bool) -> void:
	_brush_on = true
	_brush_screen = pos
	queue_redraw()
	if not (_erasing and left):
		return
	if not Rect2(Vector2.ZERO, size).has_point(pos):
		_erase_outside = true
		return
	erase_dragged.emit(screen_to_world(pos), not _erase_outside)
	_erase_outside = false


func _apply_zoom(pivot: Vector2, factor: float) -> void:
	var world_before: Vector2 = screen_to_world(pivot)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = pivot - world_before * _zoom
	_view_inited = true
	queue_redraw()
	view_changed.emit()


func _draw() -> void:
	if not _view_inited:
		_reset_view()
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)
	_draw_grid()
	if _centerline.size() >= 2:
		_draw_centerline()
		_draw_trim_preview()
		_draw_gap()
		_draw_erase_preview()
		_draw_items()
	if _preview.size() >= 2:
		draw_polyline(_project(_preview), PREVIEW_COLOR, 2.0)
	if _active_raw.size() >= 2:
		draw_polyline(_project(_active_raw), RAW_COLOR, 1.5)
	if _brush_on and mode == Mode.ERASE:
		var br: float = world_radius(EditorEraseTool.ERASE_PX, EditorEraseTool.ERASE_RADIUS) * _zoom
		draw_arc(_brush_screen, br, 0.0, TAU, 32, BRUSH_COLOR, 1.5)
	_draw_markers()
	for f in _focus_points:
		var fc: Vector2 = world_to_screen(f)
		draw_arc(fc, 20.0, 0.0, TAU, 28, FOCUS_COLOR, 3.0)
		draw_arc(fc, 27.0, 0.0, TAU, 28, Color(FOCUS_COLOR, 0.45), 2.0)


func _draw_grid() -> void:
	var tl: Vector2 = screen_to_world(Vector2.ZERO)
	var br: Vector2 = screen_to_world(size)
	# 축소할수록 격자 간격을 2배씩 넓혀 화면 간격을 12px 이상으로 유지한다(선이 뭉치지 않게).
	var step: float = GRID_SPACING
	while step * _zoom < 12.0:
		step *= 2.0
	var x0: float = floorf(tl.x / step) * step
	var y0: float = floorf(tl.y / step) * step
	var x: float = x0
	while x <= br.x:
		var col: Color = AXIS_COLOR if absf(x) < 0.5 else GRID_COLOR
		draw_line(world_to_screen(Vector2(x, tl.y)), world_to_screen(Vector2(x, br.y)), col, 1.0)
		x += step
	var y: float = y0
	while y <= br.y:
		var col2: Color = AXIS_COLOR if absf(y) < 0.5 else GRID_COLOR
		draw_line(world_to_screen(Vector2(tl.x, y)), world_to_screen(Vector2(br.x, y)), col2, 1.0)
		y += step


func _draw_centerline() -> void:
	var screen: PackedVector2Array = _project(_centerline)
	# fail/safe 코리도 밴드(폭×2 두께 폴리라인) → 중심선 → 시작/끝 마커 → 진행 화살표.
	# 틈이 있으면 앞 조각과 뒤 조각을 따로 그린다(틈 선분은 실제 경로가 아니다).
	for piece in _pieces(screen):
		draw_polyline(piece, CORRIDOR_COLOR, maxf(_fail * 2.0 * _zoom, MIN_BAND_PX * 2.0))
		draw_polyline(piece, SAFE_COLOR, maxf(_safe * 2.0 * _zoom, MIN_BAND_PX))
		draw_polyline(piece, CENTER_COLOR, 2.5)
	var start_s: Vector2 = screen[0]
	var finish_s: Vector2 = screen[screen.size() - 1]
	draw_circle(start_s, 6.0, START_COLOR)
	_draw_finish_marker(finish_s)
	if screen.size() >= 2:
		var dir: Vector2 = (screen[1] - screen[0])
		if dir.length() > 0.001:
			dir = dir.normalized()
			var tip: Vector2 = start_s + dir * 26.0
			draw_line(start_s, tip, ARROW_COLOR, 2.5)
			var perp: Vector2 = dir.orthogonal() * 6.0
			draw_line(tip, tip - dir * 8.0 + perp, ARROW_COLOR, 2.5)
			draw_line(tip, tip - dir * 8.0 - perp, ARROW_COLOR, 2.5)


## 화면 점 열을 틈에서 나눈 조각들(틈이 없으면 하나).
func _pieces(screen: PackedVector2Array, offset: int = 0) -> Array:
	var g: int = _gap - offset
	if _gap < 0 or g < 1 or g >= screen.size():
		return [screen]
	return [screen.slice(0, g), screen.slice(g)]


func _draw_trim_preview() -> void:
	if _trim_from < 0 or _trim_from >= _centerline.size():
		return
	var from: int = maxi(_trim_from - 1, 0)
	var cut: PackedVector2Array = _project(_centerline.slice(from))
	for piece in _pieces(cut, from):
		if piece.size() >= 2:
			draw_polyline(piece, TRIM_COLOR, 6.0)
	draw_circle(cut[0], 7.0, TRIM_COLOR)


## 틈: 두 끝점을 빨간 점과 이어 그리기 스냅 반경 고리로, 그 사이를 점선으로 표시한다.
func _draw_gap() -> void:
	if _gap < 1 or _gap >= _centerline.size():
		return
	var a: Vector2 = world_to_screen(_centerline[_gap - 1])
	var b: Vector2 = world_to_screen(_centerline[_gap])
	_draw_dashed(a, b, GAP_COLOR)
	var ring: float = maxf(GAP_RING_PX, GAP_RING_MIN * _zoom)
	for c in [a, b]:
		draw_circle(c, 7.0, GAP_COLOR)
		draw_arc(c, ring, 0.0, TAU, 32, Color(GAP_COLOR, 0.6), 2.0)


## 구간 지우기 미리보기: 지워질 선분(빨강, 거절이면 주황), 옮겨질 시작점(초록 고리), 생길 틈 끝점.
func _draw_erase_preview() -> void:
	if erase_preview.is_empty():
		return
	var refused: bool = bool(erase_preview.get("refused", false))
	var col: Color = VIOL_SOFT_COLOR if refused else TRIM_COLOR
	for seg in erase_preview.get("segs", []):
		var sp: PackedVector2Array = _project(seg)
		if sp.size() >= 2:
			draw_polyline(sp, col, 6.0)
	if erase_preview.has("start"):
		var st: Vector2 = world_to_screen(erase_preview["start"])
		draw_arc(st, 11.0, 0.0, TAU, 24, START_COLOR, 3.0)
		draw_circle(st, 5.0, START_COLOR)
	if erase_preview.has("gap"):
		for w in erase_preview["gap"]:
			draw_arc(world_to_screen(w), 9.0, 0.0, TAU, 20, GAP_COLOR, 3.0)


## 아이템 마커: 게임과 같은 아이콘(화면 고정 크기) + 종류 색 테두리. 검토 필요는 빨간 테두리,
## 선택은 흰 테두리와 "시작부터 거리" 라벨(교차·근접 구간에서 어느 갈래인지 확인용).
func _draw_items() -> void:
	var font: Font = get_theme_default_font()
	for m in _item_marks:
		var c: Vector2 = world_to_screen(m["pos"])
		var thimble: bool = str(m["type"]) == "thimble"
		var col: Color = THIMBLE_COLOR if thimble else AUTOPILOT_COLOR
		var half: float = ITEM_ICON_PX * 0.5
		draw_circle(c, half + 2.0, Color(0.16, 0.11, 0.1, 0.85))
		draw_texture_rect(
			ICON_THIMBLE if thimble else ICON_AUTOPILOT,
			Rect2(c - Vector2(half, half), Vector2(ITEM_ICON_PX, ITEM_ICON_PX)),
			false
		)
		draw_arc(c, half + 2.0, 0.0, TAU, 20, col, 2.0)
		if bool(m.get("review", false)):
			draw_arc(c, half + 6.0, 0.0, TAU, 24, REVIEW_COLOR, 3.0)
		if bool(m.get("selected", false)):
			draw_arc(c, half + 9.0, 0.0, TAU, 24, SELECT_COLOR, 2.5)
			var label: String = str(m.get("label", ""))
			if not label.is_empty() and font != null:
				var at: Vector2 = c + Vector2(half + 12.0, -half - 4.0)
				draw_string_outline(
					font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4, Color(0.1, 0.07, 0.06)
				)
				draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, SELECT_COLOR)


func _draw_finish_marker(center: Vector2) -> void:
	# 작은 체커 마커(피니시).
	var r: float = 6.0
	draw_circle(center, r, FINISH_COLOR)
	draw_arc(center, r, 0.0, TAU, 16, Color(0.2, 0.14, 0.1, 0.9), 1.5)


func _draw_markers() -> void:
	# 곡률 위반: 빨간/주황 원호 하이라이트.
	for v in _curv_viol:
		var i: int = int(v["i"])
		if i < 0 or i >= _centerline.size():
			continue
		var c: Color = VIOL_HARD_COLOR if str(v["kind"]) == "hard" else VIOL_SOFT_COLOR
		draw_arc(world_to_screen(_centerline[i]), 12.0, 0.0, TAU, 20, c, 2.5)
	# 자기근접 위반: 두 구간을 잇는 점선.
	for p in _prox_viol:
		var i2: int = int(p["i"])
		var j2: int = int(p["j"])
		if i2 < 0 or j2 < 0 or i2 >= _centerline.size() or j2 >= _centerline.size():
			continue
		var col: Color = VIOL_HARD_COLOR if str(p["kind"]) == "hard" else VIOL_SOFT_COLOR
		_draw_dashed(world_to_screen(_centerline[i2]), world_to_screen(_centerline[j2]), col)


func _draw_dashed(a: Vector2, b: Vector2, color: Color) -> void:
	var seg: Vector2 = b - a
	var seg_len: float = seg.length()
	if seg_len < 0.001:
		draw_circle(a, 4.0, color)
		return
	var dir: Vector2 = seg / seg_len
	var d: float = 0.0
	while d < seg_len:
		var e: float = minf(d + 5.0, seg_len)
		draw_line(a + dir * d, a + dir * e, color, 2.0)
		d += 9.0


func _project(pts: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(pts.size())
	for i in range(pts.size()):
		out[i] = pts[i] * _zoom + _pan
	return out
