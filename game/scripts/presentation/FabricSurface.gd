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
## 맞춰 원경이 자연스럽게 해당 원단색으로 흐려지게 한다. 값은 각 타일 PNG의 실제
## 평균색으로 맞췄다(수평선 페이드 대역이 단색 띠로 뜨지 않게 — 구도 결함 수정 3).
## 아래 4종(felt/satin/wool/leather)은 아직 전용 타일 PNG가 없어 절차적 폴백(_draw)만
## 렌더한다 — 폴백이 이 대표색을 그대로 채워 그리므로(FABRIC_COLOR 고정값이 아니라)
## 여기 값이 곧 실제 바닥색이다. felt=따뜻한 머스터드/황토, satin=옅은 광택
## 로즈/샴페인, wool=회갈색 짜임, leather=진한 카라멜 브라운으로 서로 및 기존
## 4종과 구별되게 잡았다.
const FABRIC_BASE: Dictionary = {
	"cotton": Color(0.695, 0.686, 0.308, 1.0),
	"denim": Color(0.159, 0.233, 0.402, 1.0),
	"silk": Color(0.775, 0.670, 0.795, 1.0),
	"knit": Color(0.747, 0.497, 0.291, 1.0),
	"felt": Color(0.780, 0.560, 0.160, 1.0),
	"satin": Color(0.870, 0.740, 0.680, 1.0),
	"wool": Color(0.520, 0.460, 0.400, 1.0),
	"leather": Color(0.450, 0.260, 0.120, 1.0),
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
		var path: String = _tile_path(fabric_type)
		if ResourceLoader.exists(path):
			texture = load(path)
	queue_redraw()


## 셰이더 fabric_color(OOB 폴백 + 수평선 페이드)에 넘길 원단 대표색.
func get_base_color() -> Color:
	return _base_color


## 원단 타입의 타일 텍스처 경로(FABRIC_DIR 기준). set_fabric·swatch_source가 공유하는
## 단일 파생식이라 두 곳의 경로 조립 방식이 어긋날 일이 없다.
static func _tile_path(fabric_type: String) -> String:
	return FABRIC_DIR + "fabric_" + fabric_type + ".png"


## read-only 조회 헬퍼(트랙 선택 화면 등 프레젠테이션 밖에서 원단 스와치를 그릴 때 사용).
## FABRIC_BASE/FABRIC_DIR 단일 소스에서 파생하므로 렌더 정의가 바뀌면 자동으로 따라온다.
## 반환 Dictionary: {"known": bool, "texture": Texture2D(or null), "color": Color}.
## known=false면 FABRIC_BASE에 없는 완전 미지 재질 — 호출부가 회색 등 자체 폴백을 그리게 한다.
static func swatch_source(fabric_type: String) -> Dictionary:
	if not FABRIC_BASE.has(fabric_type):
		return {"known": false, "texture": null, "color": FABRIC_COLOR}
	var tex: Texture2D = null
	var path: String = _tile_path(fabric_type)
	if ResourceLoader.exists(path):
		tex = load(path)
	return {"known": true, "texture": tex, "color": FABRIC_BASE[fabric_type]}


func _draw() -> void:
	if texture != null:
		_draw_textured()
		return
	var rect: Rect2 = Rect2(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2.0, HALF_EXTENT * 2.0)
	# 텍스처가 없는 원단은 이 사각형이 곧 바닥이므로 원단별 대표색(_base_color)을 채운다.
	# 미지 원단은 set_fabric에서 _base_color가 FABRIC_COLOR로 폴백되어 있어 기존 렌더와 동일.
	draw_rect(rect, _base_color, true)
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
