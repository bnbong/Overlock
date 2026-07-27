class_name TrackRenderer
extends Node2D
## 중심선 + perfect/safe/fail 폭 밴드 시각화 (아키텍처 §10).
##
## 밴드는 폭×2 두께의 폴리라인으로 그린다. 세그먼트별 오프셋 quad를
## draw_colored_polygon()으로 채우던 이전 방식은 곡률 반경이 오프셋 폭보다
## 작은 급커브에서 사각형이 자기교차(bowtie)해 "triangulation failed"를
## 냈다. 폴리라인은 삼각분할을 거치지 않는 삼각형 스트립이라 그 오류가
## 원리적으로 발생하지 않는다. setup() 시 한 번만 queue_redraw() 한다.
##
## 피니시 마커는 FinishLine 노드가 그린다(아키텍처 §2.2).

const BAND_FAIL_COLOR: Color = Color(0.20, 0.15, 0.28, 0.45)
const BAND_SAFE_COLOR: Color = Color(0.32, 0.22, 0.46, 0.55)
const BAND_PERFECT_COLOR: Color = Color(0.55, 0.40, 0.82, 0.55)
const CENTER_COLOR: Color = Color(0.82, 0.68, 1.0, 0.95)

var _track: TrackData


func setup(track: TrackData) -> void:
	_track = track
	queue_redraw()


func _draw() -> void:
	if _track == null or _track.points.size() < 2:
		return
	# 넓은 밴드부터(fail → safe → perfect → 중심선) 겹쳐 그린다.
	_draw_band(_track.fail, BAND_FAIL_COLOR)
	_draw_band(_track.safe, BAND_SAFE_COLOR)
	_draw_band(_track.perfect, BAND_PERFECT_COLOR)
	draw_polyline(_track.points, CENTER_COLOR, 2.0)


func _draw_band(width: float, color: Color) -> void:
	# 중심선을 따라 폭×2 두께로 그은 폴리라인 = 중심선 기준 ±width 밴드.
	# 삼각형 스트립이라 급커브에서도 자기교차로 인한 삼각분할 실패가 없다.
	draw_polyline(_track.points, color, width * 2.0)
