class_name MiniMap
extends Control
## 부분 미니맵 (기획서 §8.3, 아키텍처 §8, presentation.md §4.1).
##
## 플레이어를 중심에 두고 진행 방향이 화면 위(-Y)를 향하도록 회전한다.
## preview = speed*4.0, back = speed*1.5 구간의 베이크 점만 사용한다.
## 리스타일: 베이지 패널 + 스티치풍 대시 테두리 + 지나온 궤적(회색 대시) /
## 앞으로 갈 길(보라 실선) 분리(로직 골격은 불변).

const PATH_COLOR: Color = Color(0.55, 0.35, 0.85, 1.0)  # 앞으로 갈 길(보라 실선)
const PAST_COLOR: Color = Color(0.47, 0.40, 0.33, 0.85)  # 지나온 길(웜톤 회갈색 대시)
const PLAYER_COLOR: Color = Color(0.20, 0.16, 0.14, 1.0)
const ARROW_COLOR: Color = Color(0.95, 0.55, 0.15, 1.0)
const FINISH_COLOR: Color = Color(0.20, 0.70, 0.40, 1.0)
const BG_COLOR: Color = Color(0.913, 0.856, 0.717, 0.95)  # 베이지 원단 패널
const STITCH_COLOR: Color = Color(0.553, 0.384, 0.725, 1.0)  # 실 보라 박음질 테두리
const RADIUS: float = 12.0
const DASH_LEN: float = 6.0
const DASH_GAP: float = 4.0
# 표시 줌 추종 시정수(초). 속도 단계가 바뀔 때 표시 범위(preview/back/scale)가
# 계단식으로 튀지 않게 하는 표시 전용 보간 상수 — 시뮬레이션에는 절대 개입하지 않는다.
const SPEED_SMOOTH_TAU: float = 0.5

var _track: TrackData
var _player_pos: Vector2 = Vector2.ZERO
var _heading: float = 0.0
var _progress_s: float = 0.0
var _speed: float = 80.0
# 표시 범위 계산에 쓰는 부드럽게 추종하는 속도(버그 1). _speed(즉시값)를 목표로
# _process에서 지수 보간한다. _draw는 이 값만 쓴다.
var _display_speed: float = 80.0
var _display_inited: bool = false


func _ready() -> void:
	clip_contents = true


func setup(track: TrackData) -> void:
	_track = track
	queue_redraw()


func update_view(player_pos: Vector2, heading: float, progress_s: float, speed: float) -> void:
	_player_pos = player_pos
	_heading = heading
	_progress_s = progress_s
	_speed = speed
	if not _display_inited:
		_display_speed = speed  # 시작 시 램프 방지: 첫 프레임은 즉시 정합.
		_display_inited = true
	queue_redraw()


func _process(delta: float) -> void:
	# 표시용 속도를 목표 속도(_speed)로 부드럽게 추종시킨다(시정수 SPEED_SMOOTH_TAU).
	# 속도 1↔5 단계 변경 시 미니맵 줌이 즉시 점프하지 않고 연속적으로 변한다.
	# 표시 전용 보간이라 물리/판정에는 어떤 영향도 주지 않는다.
	var k: float = 1.0 - exp(-delta / SPEED_SMOOTH_TAU)
	var next: float = lerpf(_display_speed, _speed, k)
	if absf(next - _display_speed) > 0.001:
		_display_speed = next
		queue_redraw()


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	SewingSkin.draw_patch(self, rect, BG_COLOR, RADIUS)
	if not (_track == null or _track.points.size() < 2):
		_draw_route()
	# 박음질 테두리·모서리 단추는 궤적 위에 그려 패치 프레임을 또렷하게 유지한다.
	SewingSkin.draw_stitch_border(self, rect, STITCH_COLOR, 7.0, RADIUS)
	SewingSkin.draw_corner_buttons(self, rect, 12.0)


## 미니맵 궤적(지나온 길·앞으로 갈 길·피니시·플레이어)을 그린다.
func _draw_route() -> void:
	var preview: float = maxf(_display_speed * 4.0, 1.0)
	var back: float = _display_speed * 1.5
	var scale_factor: float = (size.x * 0.5) / preview
	var center: Vector2 = size * 0.5
	var rot: float = -_heading - PI * 0.5  # forward → 화면 위(-Y)
	# 지나온 길: [progress_s-back, progress_s] 회색 대시.
	var past: PackedVector2Array = _window_polyline(
		_progress_s - back, _progress_s, rot, scale_factor, center
	)
	_draw_dashed_polyline(past, PAST_COLOR)
	# 앞으로 갈 길: [progress_s, progress_s+preview] 보라 실선.
	var ahead: PackedVector2Array = _window_polyline(
		_progress_s, _progress_s + preview, rot, scale_factor, center
	)
	if ahead.size() >= 2:
		draw_polyline(ahead, PATH_COLOR, 2.5)
	_draw_finish_marker(preview, rot, scale_factor, center)
	draw_circle(center, 3.0, PLAYER_COLOR)
	draw_line(center, center + Vector2(0.0, -8.0), ARROW_COLOR, 2.5)


func _window_polyline(
	s_lo: float, s_hi: float, rot: float, scale_factor: float, center: Vector2
) -> PackedVector2Array:
	var result: PackedVector2Array = PackedVector2Array()
	var count: int = _track.s_arr.size()
	for i in range(count):
		var s_val: float = _track.s_arr[i]
		if s_val < s_lo or s_val > s_hi:
			continue
		var rel: Vector2 = (_track.points[i] - _player_pos).rotated(rot) * scale_factor
		result.append(center + rel)
	return result


func _draw_dashed_polyline(pts: PackedVector2Array, color: Color) -> void:
	if pts.size() < 2:
		return
	for i in range(pts.size() - 1):
		_draw_dashed_segment(pts[i], pts[i + 1], color)


func _draw_dashed_segment(a: Vector2, b: Vector2, color: Color) -> void:
	var seg: Vector2 = b - a
	var seg_len: float = seg.length()
	if seg_len < 0.001:
		return
	var dir: Vector2 = seg / seg_len
	var step: float = DASH_LEN + DASH_GAP
	var d: float = 0.0
	while d < seg_len:
		var end_d: float = minf(d + DASH_LEN, seg_len)
		draw_line(a + dir * d, a + dir * end_d, color, 1.5)
		d += step


func _draw_finish_marker(preview: float, rot: float, scale_factor: float, center: Vector2) -> void:
	if _track.length > _progress_s + preview:
		return
	var count: int = _track.points.size()
	if count == 0:
		return
	var finish_pos: Vector2 = _track.points[count - 1]
	var rel: Vector2 = (finish_pos - _player_pos).rotated(rot) * scale_factor
	draw_circle(center + rel, 4.0, FINISH_COLOR)
