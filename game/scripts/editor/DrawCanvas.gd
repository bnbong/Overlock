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
signal erase_begin
signal erase_dragged(world_pos: Vector2)
signal erase_end

enum Mode { DRAW, ERASE }

const MIN_SAMPLE_PX: float = 4.0  # 최소 이동 4px마다 원시 점 추가
const ZOOM_MIN: float = 0.15
const ZOOM_MAX: float = 4.0
const ZOOM_STEP: float = 1.1
const GRID_SPACING: float = 100.0

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

var mode: int = Mode.DRAW

var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO
var _view_inited: bool = false

var _active_raw: PackedVector2Array = PackedVector2Array()
var _drawing: bool = false
var _last_screen: Vector2 = Vector2.ZERO

var _panning: bool = false
var _last_pan: Vector2 = Vector2.ZERO
var _erasing: bool = false

# TrackEditor가 밀어 넣는 표시 데이터.
var _centerline: PackedVector2Array = PackedVector2Array()
var _safe: float = 42.0
var _fail: float = 90.0
var _curv_viol: Array = []
var _prox_viol: Array = []


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK


func world_to_screen(w: Vector2) -> Vector2:
	return w * _zoom + _pan


func screen_to_world(s: Vector2) -> Vector2:
	return (s - _pan) / _zoom


## 중심선/폭 갱신(스트로크·편집 후 TrackEditor가 호출).
func set_track(centerline: PackedVector2Array, safe: float, fail: float) -> void:
	_centerline = centerline
	_safe = safe
	_fail = fail
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
	mode = m


func _reset_view() -> void:
	_zoom = 1.0
	_pan = size * 0.5
	_view_inited = true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)


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
				grab_focus()
				if mode == Mode.ERASE:
					_erasing = true
					erase_begin.emit()
					erase_dragged.emit(screen_to_world(event.position))
				else:
					_drawing = true
					_active_raw = PackedVector2Array([screen_to_world(event.position)])
					_last_screen = event.position
					queue_redraw()
			else:
				if _drawing:
					_drawing = false
					if _active_raw.size() >= 1:
						stroke_committed.emit(_active_raw)
					_active_raw = PackedVector2Array()
					queue_redraw()
				if _erasing:
					_erasing = false
					erase_end.emit()


func _handle_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		_pan += event.position - _last_pan
		_last_pan = event.position
		queue_redraw()
		return
	if mode == Mode.ERASE and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		erase_dragged.emit(screen_to_world(event.position))
		return
	if _drawing and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if event.position.distance_to(_last_screen) >= MIN_SAMPLE_PX:
			_active_raw.append(screen_to_world(event.position))
			_last_screen = event.position
			queue_redraw()


func _apply_zoom(pivot: Vector2, factor: float) -> void:
	var world_before: Vector2 = screen_to_world(pivot)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = pivot - world_before * _zoom
	queue_redraw()


func _draw() -> void:
	if not _view_inited:
		_reset_view()
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)
	_draw_grid()
	if _centerline.size() >= 2:
		_draw_centerline()
	if _active_raw.size() >= 2:
		draw_polyline(_project(_active_raw), RAW_COLOR, 1.5)
	_draw_markers()


func _draw_grid() -> void:
	var tl: Vector2 = screen_to_world(Vector2.ZERO)
	var br: Vector2 = screen_to_world(size)
	var x0: float = floorf(tl.x / GRID_SPACING) * GRID_SPACING
	var y0: float = floorf(tl.y / GRID_SPACING) * GRID_SPACING
	var x: float = x0
	while x <= br.x:
		var col: Color = AXIS_COLOR if absf(x) < 0.5 else GRID_COLOR
		draw_line(world_to_screen(Vector2(x, tl.y)), world_to_screen(Vector2(x, br.y)), col, 1.0)
		x += GRID_SPACING
	var y: float = y0
	while y <= br.y:
		var col2: Color = AXIS_COLOR if absf(y) < 0.5 else GRID_COLOR
		draw_line(world_to_screen(Vector2(tl.x, y)), world_to_screen(Vector2(br.x, y)), col2, 1.0)
		y += GRID_SPACING


func _draw_centerline() -> void:
	var screen: PackedVector2Array = _project(_centerline)
	# fail/safe 코리도 밴드(폭×2 두께 폴리라인) → 중심선 → 시작/끝 마커 → 진행 화살표.
	draw_polyline(screen, CORRIDOR_COLOR, _fail * 2.0 * _zoom)
	draw_polyline(screen, SAFE_COLOR, _safe * 2.0 * _zoom)
	draw_polyline(screen, CENTER_COLOR, 2.5)
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
