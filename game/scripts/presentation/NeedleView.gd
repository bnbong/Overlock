class_name NeedleView
extends Node2D
## 금속 노루발 + 바늘 스크린 오버레이 (presentation.md §2.1/§5). ForegroundLayer 고정.
##
## 노드 원점(0,0)이 바늘이 내려꽂히는 재봉선 점(= 셰이더 v_needle 행)에 오도록
## PresentationController가 위치를 설정한다(상수 단일 소스, §9 함정 5). 바늘은
## 속도에 비례해 상하 왕복한다. texture 지정 시 스프라이트로 교체(§9 함정 13).

const METAL: Color = Color(0.78, 0.80, 0.84, 1.0)
const METAL_DARK: Color = Color(0.50, 0.52, 0.57, 1.0)
const METAL_HI: Color = Color(0.92, 0.94, 0.97, 1.0)
const NEEDLE_COLOR: Color = Color(0.90, 0.93, 0.97, 1.0)
const SHADOW: Color = Color(0.0, 0.0, 0.0, 0.28)

const BOB_AMPLITUDE: float = 26.0
const NEEDLE_REST_TOP: float = -70.0
const NEEDLE_LENGTH: float = 74.0

# 텍스처 정렬 오프셋(절차적 좌표와 동일한 노드 공간에서 유도, §9 함정 5).
# presser_foot.svg: 노드 y[-70,+50] → svg[0,120], x는 중앙. → 노드(-70,-70)에 배치.
const FOOT_TOP: float = -70.0
# needle.svg: svg y=12(샤프트 상단)이 노드(NEEDLE_REST_TOP + bob)에 오도록 -12 보정.
const NEEDLE_TOP_OFFSET: float = NEEDLE_REST_TOP - 12.0

## 노루발(정적)과 바늘(왕복)을 별도 스프라이트로 분리해 바늘 왕복 애니메이션을
## 보존한다(presentation.md §2.1). foot/needle 텍스처 중 하나라도 있으면 텍스처
## 모드. 없으면 절차적 도형. 단일 texture는 하위호환(왕복 없음)으로 남긴다.
@export var foot_texture: Texture2D = null
@export var needle_texture: Texture2D = null
## null이면 _draw 도형, 지정되면 스프라이트로 렌더(하위호환 단일 스프라이트).
@export var texture: Texture2D = null

var _speed: float = 0.0
var _phase: float = 0.0
var _bob: float = 0.0


func _process(delta: float) -> void:
	# 속도 비례 왕복(주행 중일수록 빠르게). 정지 시엔 서서히 멈춤.
	var rate: float = 4.0 + _speed / 12.0
	_phase += delta * rate
	_bob = BOB_AMPLITUDE * (0.5 - 0.5 * cos(_phase))
	queue_redraw()


## PresentationController가 매 프레임 player.speed를 주입.
func set_speed(speed: float) -> void:
	_speed = maxf(speed, 0.0)


func _draw() -> void:
	if foot_texture != null or needle_texture != null:
		_draw_textured()
		return
	if texture != null:
		var ts: Vector2 = texture.get_size()
		draw_texture(texture, Vector2(-ts.x * 0.5, -ts.y * 0.5))
		return
	_draw_needle()
	_draw_presser_foot()


## 바늘(왕복) → 노루발(정적, 앞) 순으로 그린다. 노루발이 바늘대를 가려 바늘 끝만
## 슬롯 사이로 왕복해 보인다(절차적 버전과 동일한 시각). _bob은 _process가 구동.
func _draw_textured() -> void:
	if needle_texture != null:
		var nsz: Vector2 = needle_texture.get_size()
		draw_texture(needle_texture, Vector2(-nsz.x * 0.5, NEEDLE_TOP_OFFSET + _bob))
	if foot_texture != null:
		var fsz: Vector2 = foot_texture.get_size()
		draw_texture(foot_texture, Vector2(-fsz.x * 0.5, FOOT_TOP))


func _draw_needle() -> void:
	var top: float = NEEDLE_REST_TOP + _bob
	var tip: float = top + NEEDLE_LENGTH
	# 바늘 대(샤프트).
	draw_rect(Rect2(-2.0, top, 4.0, NEEDLE_LENGTH - 8.0), NEEDLE_COLOR, true)
	# 바늘 끝(뾰족).
	var point: PackedVector2Array = PackedVector2Array(
		[Vector2(-2.0, tip - 10.0), Vector2(2.0, tip - 10.0), Vector2(0.0, tip)]
	)
	draw_colored_polygon(point, METAL_HI)
	# 바늘대 고정 클램프.
	draw_rect(Rect2(-7.0, top - 10.0, 14.0, 12.0), METAL_DARK, true)


func _draw_presser_foot() -> void:
	# 접지 그림자.
	draw_circle(Vector2(0.0, 40.0), 30.0, SHADOW)
	# 샤프트(위로 뻗는 금속 기둥).
	draw_rect(Rect2(-8.0, -64.0, 16.0, 64.0), METAL, true)
	draw_rect(Rect2(-8.0, -64.0, 4.0, 64.0), METAL_HI, true)
	# 노루발 몸통(가로 바).
	draw_rect(Rect2(-34.0, -6.0, 68.0, 14.0), METAL, true)
	draw_rect(Rect2(-34.0, -6.0, 68.0, 4.0), METAL_HI, true)
	# 좌/우 발(바늘 슬롯을 사이에 둠).
	_draw_toe(-30.0)
	_draw_toe(16.0)


func _draw_toe(x: float) -> void:
	var toe: PackedVector2Array = PackedVector2Array(
		[
			Vector2(x, 6.0),
			Vector2(x + 14.0, 6.0),
			Vector2(x + 14.0, 34.0),
			Vector2(x + 7.0, 42.0),
			Vector2(x, 34.0),
		]
	)
	draw_colored_polygon(toe, METAL)
	draw_line(Vector2(x, 6.0), Vector2(x, 34.0), METAL_DARK, 2.0)
