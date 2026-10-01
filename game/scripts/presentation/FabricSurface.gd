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
## set_fabric로 주입한다. 없는 타입이거나 파일이 없으면 texture=null 유지 → 절차적 격자 폴백.
## v2.3.0부터 8종 모두 사실적 원단 타일(assets/gfx/fabrics/, 원본은 fabrics_realistic_v1/)을 쓴다.
## 구 128² 타일 4종은 롤백용으로 assets/gfx/src/legacy_fabric_128/에 보존했다.
const FABRIC_DIR: String = "res://assets/gfx/fabrics/"
## 원단 타입별 대표색(셰이더 OOB 폴백 + 수평선 페이드 + 스와치 배경). 값은 각 타일 PNG
## (fabrics/fabric_<id>.png)의 실제 sRGB 평균색이다. 원경이 해당 원단색으로 자연스럽게
## 흐려지고 수평선 페이드 대역이 단색 띠로 뜨지 않게 한다(구도 결함 수정 3). 타일 PNG를
## 바꾸면 fabrics_realistic_v1/make_tileable.py가 출력하는 평균색으로 함께 갱신한다.
const FABRIC_BASE: Dictionary = {
	"cotton": Color(0.635, 0.586, 0.252, 1.0),
	"denim": Color(0.154, 0.224, 0.333, 1.0),
	"silk": Color(0.745, 0.659, 0.747, 1.0),
	"knit": Color(0.659, 0.396, 0.207, 1.0),
	"felt": Color(0.764, 0.509, 0.106, 1.0),
	"satin": Color(0.838, 0.693, 0.609, 1.0),
	"wool": Color(0.490, 0.424, 0.370, 1.0),
	"leather": Color(0.439, 0.239, 0.125, 1.0),
}
## 타일 1장이 바닥에서 차지하는 월드 한 변(px). 텍스처 픽셀 크기와 독립이라 타일 해상도를
## 바꿔도 원단 조직의 화면 크기가 변하지 않는다. 표에 없는 재질은 TILE_WORLD_DEFAULT.
## 새 타일은 한 장에 조직이 55~150주기 들어 있어 구 128² 타일처럼 128로 깔면 한 주기가
## 1 SubViewport px 안팎이 되어 평탄한 색으로 뭉개진다. 512를 기준으로 구 타일의 조직 밀도
## (면 28주기·니트 12코/128)와 비슷하게 맞췄고, 주기가 촘촘한 데님(140주기)과 새틴(152주기)은
## 한 주기가 4 SubViewport px 이상이 되도록 넓혀 원경 모아레를 줄였다.
const TILE_WORLD_DEFAULT: float = 512.0
const TILE_WORLD: Dictionary = {
	"cotton": 512.0,
	"denim": 768.0,
	"silk": 512.0,
	"knit": 512.0,
	"felt": 512.0,
	"satin": 640.0,
	"wool": 512.0,
	"leather": 512.0,
}
## 스와치가 보여 주는 바닥 월드 한 변(px). 구 128² 타일의 중앙 55% 크롭(약 70px)과 같은 면적이라
## 반복 크기가 재질마다 달라도 견본 속 조직 크기가 바닥과 같은 비율로 보인다.
const SWATCH_WORLD: float = 70.0

## null이면 _draw 도형, 지정되면 스프라이트로 렌더(presentation.md §9 함정 13).
## 씬에서 수동 지정하지 않으면 set_fabric이 원단 타입에 맞는 타일을 로드한다.
@export var texture: Texture2D = null

var _base_color: Color = FABRIC_COLOR
var _tile_world: float = TILE_WORLD_DEFAULT


func _ready() -> void:
	# 타일 반복(draw_texture_rect tile=true)이 동작하려면 캔버스 반복이 켜져야 한다.
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# 타일 텍스처는 SubViewport에서 축소되어 그려지므로(약 0.85 px/월드) 밉맵 선형 필터로
	# 원단 조직의 모아레·반짝임을 줄인다(타일 import는 mipmaps/generate=true).
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## PresentationController가 _ready에서 1회 주입(원단 타입 → 타일 텍스처 + 대표색).
## 씬에서 texture를 수동 지정한 경우 그 override를 존중한다.
func set_fabric(fabric_type: String) -> void:
	_base_color = FABRIC_BASE.get(fabric_type, FABRIC_COLOR)
	_tile_world = tile_world(fabric_type)
	if texture == null:
		var path: String = _tile_path(fabric_type)
		if ResourceLoader.exists(path):
			texture = load(path)
	queue_redraw()


## 셰이더 fabric_color(OOB 폴백 + 수평선 페이드)에 넘길 원단 대표색.
func get_base_color() -> Color:
	return _base_color


## 원단 타입의 타일 1장이 차지하는 월드 한 변(px). 미지 재질은 TILE_WORLD_DEFAULT.
static func tile_world(fabric_type: String) -> float:
	return float(TILE_WORLD.get(fabric_type, TILE_WORLD_DEFAULT))


## 원단 타입의 타일 텍스처 경로(FABRIC_DIR 기준). set_fabric·swatch_source가 공유하는
## 단일 파생식이라 두 곳의 경로 조립 방식이 어긋날 일이 없다.
static func _tile_path(fabric_type: String) -> String:
	return FABRIC_DIR + "fabric_" + fabric_type + ".png"


## read-only 조회 헬퍼(트랙 선택 화면 등 프레젠테이션 밖에서 원단 스와치를 그릴 때 사용).
## FABRIC_BASE/FABRIC_DIR 단일 소스에서 파생하므로 렌더 정의가 바뀌면 자동으로 따라온다.
## 반환 Dictionary: {"known": bool, "texture": Texture2D(or null), "color": Color, "region": Rect2}.
## region은 텍스처 중앙에서 SWATCH_WORLD 월드 면적에 해당하는 크롭 영역이다(텍스처가 없으면 빈 Rect2).
## known=false면 FABRIC_BASE에 없는 완전 미지 재질 — 호출부가 회색 등 자체 폴백을 그리게 한다.
static func swatch_source(fabric_type: String) -> Dictionary:
	if not FABRIC_BASE.has(fabric_type):
		return {"known": false, "texture": null, "color": FABRIC_COLOR, "region": Rect2()}
	var tex: Texture2D = null
	var region: Rect2 = Rect2()
	var path: String = _tile_path(fabric_type)
	if ResourceLoader.exists(path):
		tex = load(path)
	if tex != null:
		var sz: Vector2 = tex.get_size()
		var frac: float = clampf(SWATCH_WORLD / tile_world(fabric_type), 0.05, 1.0)
		var crop: float = minf(sz.x, sz.y) * frac
		region = Rect2((sz - Vector2(crop, crop)) * 0.5, Vector2(crop, crop))
	return {"known": true, "texture": tex, "color": FABRIC_BASE[fabric_type], "region": region}


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


## 타일을 텍스처 픽셀 크기가 아니라 월드 반복 크기(_tile_world)로 깐다. 텍스처 픽셀 공간에서
## 반복 사각형을 그리고 변환 배율(_tile_world / 텍스처 한 변)로 월드에 맞춘다.
func _draw_textured() -> void:
	var tex_size: Vector2 = texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0 or _tile_world <= 0.0:
		return
	var scale_v: Vector2 = Vector2(_tile_world / tex_size.x, _tile_world / tex_size.y)
	var rect: Rect2 = Rect2(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2.0, HALF_EXTENT * 2.0)
	draw_set_transform(Vector2.ZERO, 0.0, scale_v)
	draw_texture_rect(
		texture, Rect2(rect.position / scale_v, rect.size / scale_v), true
	) # tile=true
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
