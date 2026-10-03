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
## 새 타일은 한 장에 조직이 55~150주기 들어 있다. Mode 7 근경은 월드 1px이 화면 가로 10~29px로
## 확대되므로, 반복을 128로 촘촘히 깔아 근경 조직이 실제 원단처럼 잘게 보이게 했다. 바닥
## SubViewport(PresentationController.SOURCE_SIZE=2048, 3.41 px/월드)에서 조직 한 주기가 3.5px 이상
## 담기도록, 주기가 촘촘한 데님(140주기)은 192, 새틴(152주기)은 160으로 넓혔다. 512² 타일이면
## 128 반복에서 4 texel/월드라 뷰포트 해상도보다 촘촘하다.
const TILE_WORLD_DEFAULT: float = 128.0
const TILE_WORLD: Dictionary = {
	"cotton": 128.0,
	"denim": 192.0,
	"silk": 128.0,
	"knit": 128.0,
	"felt": 128.0,
	"satin": 160.0,
	"wool": 128.0,
	"leather": 128.0,
}
## 스와치가 보여 주는 바닥 월드 한 변(px). 재질 사이의 조직 크기 비율은 바닥과 같다. 견본은 18~34px로
## 작아서, 128 반복 기준으로 타일의 1/8(512² 타일에서 64 texel, 면 약 13주기·니트 약 7코)만 보여 줘야
## 조직이 단색으로 뭉개지지 않는다.
const SWATCH_WORLD: float = 16.0
## 타일을 월드 좌표로 샘플하고 Mode 7 깊이에 맞춰 밉맵을 고르는 셰이더(fabric_surface.gdshader).
## Mode 7·주름 셰이더가 이 SubViewport를 밉맵 없이 읽으므로 중·원경 모아레를 여기서 미리 거른다.
const SURFACE_SHADER_PATH: String = "res://shaders/fabric_surface.gdshader"
## 깊이 기반 밉맵에서 세로(깊이 방향) 발자국 비중과 레벨 보정(fabric_surface.gdshader 참고).
const LOD_ANISO_WEIGHT: float = 0.7
const LOD_BIAS: float = 0.0

## null이면 _draw 도형, 지정되면 스프라이트로 렌더(presentation.md §9 함정 13).
## 씬에서 수동 지정하지 않으면 set_fabric이 원단 타입에 맞는 타일을 로드한다.
@export var texture: Texture2D = null

var _base_color: Color = FABRIC_COLOR
var _tile_world: float = TILE_WORLD_DEFAULT
var _surface_mat: ShaderMaterial = null
var _player: Node2D = null


func _ready() -> void:
	# 타일 반복(draw_texture_rect tile=true)이 동작하려면 캔버스 반복이 켜져야 한다.
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# 셰이더가 없을 때의 폴백 경로도 밉맵 선형 필터로 그린다(타일 import는 mipmaps/generate=true).
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists(SURFACE_SHADER_PATH):
		_surface_mat = ShaderMaterial.new()
		_surface_mat.shader = load(SURFACE_SHADER_PATH)
		_surface_mat.set_shader_parameter("depth_scale", PresentationController.DEPTH_SCALE)
		_surface_mat.set_shader_parameter("cam_back", PresentationController.CAM_BACK)
		_surface_mat.set_shader_parameter("spread", PresentationController.SPREAD)
		_surface_mat.set_shader_parameter("aniso_weight", LOD_ANISO_WEIGHT)
		_surface_mat.set_shader_parameter("lod_bias", LOD_BIAS)
	# 같은 World 아래 플레이어(SimHost/FabricSource/World/Player). 게임 밖에서는 없을 수 있다.
	_player = get_node_or_null("../Player") as Node2D


## 깊이 기반 밉맵이 쓰는 플레이어 위치·진행 방향을 매 프레임 넘긴다(표현 전용 읽기).
func _process(_delta: float) -> void:
	if _surface_mat == null or material != _surface_mat:
		return
	var has_player: bool = _player != null and "heading" in _player
	_surface_mat.set_shader_parameter("use_depth", has_player)
	if has_player:
		var h: float = float(_player.get("heading"))
		_surface_mat.set_shader_parameter("player_pos", _player.position)
		_surface_mat.set_shader_parameter("fwd", Vector2(cos(h), sin(h)))
	var vp: Viewport = get_viewport()
	if vp is SubViewport:
		var vp_w: float = float((vp as SubViewport).size.x)
		_surface_mat.set_shader_parameter("vp_per_world", vp_w / PresentationController.COVERAGE)


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
	# 타일 셰이더는 텍스처 경로에서만 쓴다(절차적 폴백은 기본 캔버스 렌더).
	var want: Material = _surface_mat if texture != null else null
	if material != want:
		material = want
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


## 타일을 텍스처 픽셀 크기가 아니라 월드 반복 크기(_tile_world)로 깐다. 셰이더가 있으면 큰
## 사각형 하나를 그리고 셰이더가 월드 좌표로 샘플한다. 없으면 텍스처 픽셀 공간에서 반복 사각형을
## 그리고 변환 배율(_tile_world / 텍스처 한 변)로 월드에 맞춘다.
func _draw_textured() -> void:
	var tex_size: Vector2 = texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0 or _tile_world <= 0.0:
		return
	var rect: Rect2 = Rect2(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2.0, HALF_EXTENT * 2.0)
	if _surface_mat != null:
		_surface_mat.set_shader_parameter("fabric_tex", texture)
		_surface_mat.set_shader_parameter("tile_world", _tile_world)
		_surface_mat.set_shader_parameter("texels_per_world", tex_size.x / _tile_world)
		draw_rect(rect, Color.WHITE)
		return
	var scale_v: Vector2 = Vector2(_tile_world / tex_size.x, _tile_world / tex_size.y)
	draw_set_transform(Vector2.ZERO, 0.0, scale_v)
	draw_texture_rect(
		texture, Rect2(rect.position / scale_v, rect.size / scale_v), true
	) # tile=true
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
