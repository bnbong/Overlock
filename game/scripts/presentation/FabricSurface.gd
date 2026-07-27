class_name FabricSurface
extends Node2D
## 황록 원단 base 레이어 (presentation.md §2.1). SubViewport 안 월드 공간, draw-once.
##
## Mode 7 셰이더의 소스 최하단 레이어. 커버리지를 벗어나면 셰이더가
## fabric_color로 폴백하므로 여기서는 트랙 전체를 넉넉히 덮는 큰 사각형만
## 그린다. 원근 워프 가독성을 위해 옅은 격자선을 얹는다(원경으로 수렴하는
## 격자가 깊이감을 준다). texture가 지정되면 도형 대신 스프라이트로 교체.

const FABRIC_COLOR: Color = Color(0.72, 0.78, 0.34, 1.0)
const WEAVE_COLOR: Color = Color(0.66, 0.72, 0.30, 1.0)
const GRID_STEP: float = 48.0
const HALF_EXTENT: float = 3000.0 # 트랙 전체(약 1546×1111)를 여유 있게 덮는 반경

## 원단 타입별 타일 텍스처 경로(트랙 JSON의 fabric 필드). PresentationController가
## set_fabric로 주입한다. 없는 타입이면 texture=null 유지 → 절차적 격자 폴백.
const FABRIC_DIR: String = "res://assets/gfx/"
## 원단 타입별 대표색(셰이더 OOB 폴백 + 수평선 페이드용). 타일 텍스처의 지배색과
## 맞춰 원경이 자연스럽게 해당 원단색으로 흐려지게 한다.
const FABRIC_BASE: Dictionary = {
	"cotton": Color(0.74, 0.78, 0.40, 1.0),
	"denim": Color(0.22, 0.31, 0.48, 1.0),
	"silk": Color(0.79, 0.72, 0.85, 1.0),
	"knit": Color(0.81, 0.62, 0.41, 1.0),
}

## null이면 _draw 도형, 지정되면 스프라이트로 렌더(presentation.md §9 함정 13).
## 씬에서 수동 지정하지 않으면 set_fabric이 원단 타입에 맞는 타일을 로드한다.
@export var texture: Texture2D = null

var _base_color: Color = FABRIC_COLOR


func _ready() -> void:
	# 타일 반복(draw_texture_rect tile=true)이 동작하려면 캔버스 반복이 켜져야 한다.
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


## PresentationController가 _ready에서 1회 주입(원단 타입 → 타일 텍스처 + 대표색).
## 씬에서 texture를 수동 지정한 경우 그 override를 존중한다.
func set_fabric(fabric_type: String) -> void:
	_base_color = FABRIC_BASE.get(fabric_type, FABRIC_COLOR)
	if texture == null:
		var path: String = FABRIC_DIR + "fabric_" + fabric_type + ".png"
		if ResourceLoader.exists(path):
			texture = load(path)
	queue_redraw()


## 셰이더 fabric_color(OOB 폴백 + 수평선 페이드)에 넘길 원단 대표색.
func get_base_color() -> Color:
	return _base_color


func _draw() -> void:
	if texture != null:
		_draw_textured()
		return
	var rect: Rect2 = Rect2(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2.0, HALF_EXTENT * 2.0)
	draw_rect(rect, FABRIC_COLOR, true)
	# 옅은 격자(위브 느낌 + 원근 가독성). 월드 공간이라 셰이더가 자동 원근화.
	var n: int = int(HALF_EXTENT / GRID_STEP)
	for i in range(-n, n + 1):
		var p: float = float(i) * GRID_STEP
		draw_line(Vector2(p, -HALF_EXTENT), Vector2(p, HALF_EXTENT), WEAVE_COLOR, 1.0)
		draw_line(Vector2(-HALF_EXTENT, p), Vector2(HALF_EXTENT, p), WEAVE_COLOR, 1.0)


func _draw_textured() -> void:
	var tex_size: Vector2 = texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var rect: Rect2 = Rect2(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2.0, HALF_EXTENT * 2.0)
	draw_texture_rect(texture, rect, true) # tile=true
