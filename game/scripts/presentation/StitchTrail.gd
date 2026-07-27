class_name StitchTrail
extends Node2D
## 빨간 스티치 트레일 (presentation.md §3). SubViewport 안 월드 공간.
##
## 플레이어의 실제 궤적을 호길이(STITCH_SPACING) 간격으로 샘플링한 링버퍼.
## 월드 공간 _draw라 Mode 7 셰이더가 자동 원근화한다(전진할수록 근경=화면
## 하단으로 흘러감). 물리 루프와 무결합: PresentationController가 player.position만
## 읽어 push_if_moved를 호출한다(시뮬 결정론 불변).
##
## 주행 중 렌더는 링버퍼(_points, MAX_STITCHES 상한)로 근경 윈도만 그린다. 완주
## 줌아웃 연출(presentation.md §13)은 전체 궤적이 필요하므로 상한 없는 _full_points에
## 같은 샘플을 함께 쌓는다(트랙 3200px대 → 수백 점, 수 KB로 메모리 무해).

const STITCH_SPACING: float = 10.0
const MAX_STITCHES: int = 96
const STITCH_HALF_LEN: float = 3.0  # 진행 방향 대시 반길이(px) → 총 6px 대시, 4px 간격
const STITCH_COLOR: Color = Color(0.85, 0.15, 0.15, 1.0)
const STITCH_WIDTH: float = 2.0

var _points: PackedVector2Array = PackedVector2Array()
var _full_points: PackedVector2Array = PackedVector2Array()  # 상한 없는 전체 궤적(줌아웃용)
var _last: Vector2 = Vector2.ZERO


## 마지막 스티치에서 STITCH_SPACING 이상 이동했으면 현재 위치를 기록.
func push_if_moved(pos: Vector2) -> void:
	if _points.is_empty() or _last.distance_to(pos) >= STITCH_SPACING:
		_points.append(pos)
		if _points.size() > MAX_STITCHES:
			_points.remove_at(0)
		_full_points.append(pos)  # 링버퍼와 같은 샘플을 전체 궤적에도 보존.
		_last = pos
		queue_redraw()


## 완주 줌아웃 연출이 읽는 전체 궤적(월드 공간). 링버퍼와 달리 초반 점도 유실 안 됨.
func get_full_points() -> PackedVector2Array:
	return _full_points


func clear_trail() -> void:
	_points = PackedVector2Array()
	_full_points = PackedVector2Array()
	queue_redraw()


func _draw() -> void:
	var count: int = _points.size()
	if count < 2:
		return
	# 각 스티치는 진행 접선 방향의 짧은 선분(길이:너비 = 6:2)이라 재봉선을 따라 흐른다.
	# (수직 대시는 근경에서 Mode 7 원근에 가로로 늘어나 넓은 타원처럼 보였다.)
	for i in range(count):
		var tangent: Vector2 = _tangent_at(i, count)
		var p: Vector2 = _points[i]
		draw_line(
			p - tangent * STITCH_HALF_LEN, p + tangent * STITCH_HALF_LEN, STITCH_COLOR, STITCH_WIDTH
		)


## 인접 점 방향으로 접선을 추정(끝점은 한쪽 이웃만 사용).
func _tangent_at(i: int, count: int) -> Vector2:
	var a: Vector2
	var b: Vector2
	if i == 0:
		a = _points[0]
		b = _points[1]
	elif i == count - 1:
		a = _points[count - 2]
		b = _points[count - 1]
	else:
		a = _points[i - 1]
		b = _points[i + 1]
	var d: Vector2 = b - a
	if d.length_squared() < 0.0001:
		return Vector2.RIGHT
	return d.normalized()
