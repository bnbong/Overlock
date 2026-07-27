class_name FinishLine
extends Node2D
## 피니시 시각 마커 (아키텍처 §2.2).
##
## RaceDirector가 경로 끝점 위치와 접선 방향(rotation), 폭을 설정하면
## 경로에 수직인 피니시 라인을 그린다. 노드가 접선 방향으로 회전돼 있으므로
## 로컬 Y축(±half_width)으로 선을 그으면 경로에 수직인 마커가 된다.

const COLOR: Color = Color(0.40, 0.95, 0.60, 1.0)
const THICKNESS: float = 4.0

var half_width: float = 90.0


## RaceDirector가 트랙 fail 폭을 마커 반폭으로 넘긴다.
func setup(width: float) -> void:
	half_width = width
	queue_redraw()


func _draw() -> void:
	draw_line(Vector2(0.0, -half_width), Vector2(0.0, half_width), COLOR, THICKNESS)
