class_name NeedleView
extends Node2D
## 확대 금속 노루발 + 상하 왕복 바늘·바늘대 스크린 오버레이 (presentation.md §2.1/§5).
## ForegroundLayer 고정.
##
## 노드 원점(0,0) = 내려간 바늘 끝의 관통점(= 셰이더 v_needle 행, 노루발 U자 슬롯 중앙).
## PresentationController가 위치를 설정한다(상수 단일 소스, §9 함정 5).
## 노루발은 FOOT_RECT에 고정으로 그리고 절대 움직이지 않는다. 바늘과 바늘대는 같은
## 이동량으로 함께 왕복한다: 최하단 끝 = 원점(0), 최상단 끝 = -NEEDLE_TRAVEL.
## 그리기 순서는 노루발 → 바늘대 → 바늘 → 클램프. 바늘이 노루발 중앙(생크·핀 블록) 앞을
## 지나 슬롯으로 내려가므로 왕복이 가려지지 않고, 양쪽 발과는 겹치지 않는다.
## 주행 중(set_running(true))에는 속도 비례 주파수로 왕복하고, 정지·카운트다운·완주
## 시에는 위상이 앞으로만 진행하며 감속해 다음 상승점에서 멈춘다(역행·순간 이동 없음).

const METAL: Color = Color(0.78, 0.80, 0.84, 1.0)
const METAL_DARK: Color = Color(0.50, 0.52, 0.57, 1.0)
const METAL_HI: Color = Color(0.92, 0.94, 0.97, 1.0)
const METAL_EDGE: Color = Color(0.22, 0.23, 0.27, 1.0)
const NEEDLE_COLOR: Color = Color(0.90, 0.93, 0.97, 1.0)
const SHADOW: Color = Color(0.0, 0.0, 0.0, 0.28)
# 바늘 외곽선(은색 노루발 앞에서도 바늘이 읽히도록)과 노루발에 떨어지는 바늘 그림자.
const NEEDLE_OUTLINE: Color = Color(0.12, 0.12, 0.16, 1.0)
const NEEDLE_SHADOW: Color = Color(0.0, 0.0, 0.0, 0.22)
# 바늘 실루엣 드롭 섀도(오프셋·색). 외곽선 아래에 먼저 그린다.
const NEEDLE_DROP: Vector2 = Vector2(2.5, 1.5)
const NEEDLE_DROP_COLOR: Color = Color(0.0, 0.0, 0.0, 0.45)
# needle.png 밝기 보정(1 초과 = 밝게). 중간 회색 생크 앞에서 밝은 바늘 + 어두운 외곽선으로 읽힌다.
const NEEDLE_TINT: Color = Color(1.3, 1.3, 1.35, 1.0)

## 바늘 상승 높이(px, 양수). 최상단에서 바늘 끝 y = -NEEDLE_TRAVEL.
const NEEDLE_TRAVEL: float = 90.0

# 노루발 표시 사각형(노드 로컬, 불변). presser_foot_large.png(1254x1254) 픽셀 측정값에서 유도:
#   불투명 bbox x[109,1144] y[62,1153] (폭 1036px), U자 슬롯 상단 y=897, 슬롯 중앙 x=624.
#   관통점 = 슬롯 중앙, 슬롯 상단에서 약 35% 깊이(재봉선 첫 땀 위) → 원본 (624, 985).
#   표시 크기 200 → 배율 200/1254 = 0.1595, 표시 불투명 폭 ≈ 165px(구 presser_foot.png 91px의
#   약 1.8배). 불투명 영역(노드 로컬) x[-82, 83] y[-147, 27]. 관통점 화면 y 446.4 기준 생크
#   상단은 화면 y 약 299.3(446.4 - 147.1)으로 수평선(302.4)보다 약 3px 위까지 올라가며, 노루발
#   좌우와 뒤쪽으로 다가오는 재봉선·커브는 가리지 않는다.
#   오프셋 = -(624, 985) * 0.1595 = (-99.5, -157.1). 원본 픽셀 비율로만 정의하므로
#   import size_limit으로 텍스처 해상도가 줄어도 위치는 변하지 않는다.
const FOOT_RECT: Rect2 = Rect2(-99.5, -157.1, 200.0, 200.0)
# 생크(중앙 수직 기둥) 상단의 원본 비율 y(= 불투명 bbox 상단 62/1254). 바늘 그림자 시작점.
const FOOT_SHANK_TOP_FRAC: float = 0.05

# 바늘 끝 스프라이트(needle.png 20x96): 끝점 원본 (10, 92), 샹크 상단 원본 y=2.
const NEEDLE_SCALE: float = 1.25
const NEEDLE_SRC_SIZE: Vector2 = Vector2(20.0, 96.0)
const NEEDLE_TIP_SRC: Vector2 = Vector2(10.0, 92.0)
const NEEDLE_SHANK_SRC_TOP: float = 2.0
# 절차적 폴백 바늘 길이(needle.png 표시 길이와 동일).
const NEEDLE_LENGTH: float = (NEEDLE_TIP_SRC.y - NEEDLE_SHANK_SRC_TOP) * NEEDLE_SCALE

# 바늘대(절차적). 모든 y는 현재 바늘 끝 기준 상대값(바늘과 같은 이동량으로 움직임).
# 가는 하부 봉 + 바늘 윗부분 클램프 + 화면 위쪽의 약간 굵은 상부 봉. 상단은 화면 밖까지.
const BAR_WIDTH: float = 7.0
const BAR_THICK_WIDTH: float = 14.0
const BAR_THICK_FROM: float = -330.0
const BAR_TOP: float = -1000.0
const CLAMP_SIZE: Vector2 = Vector2(18.0, 20.0)
# 클램프가 바늘 샹크 상단을 덮는 깊이.
const CLAMP_OVERLAP: float = 6.0

# 왕복 주파수(전체 왕복 주기 기준 Hz). 속도 0..max_speed → MIN..MAX 선형.
const FREQ_MIN_HZ: float = 3.0
const FREQ_MAX_HZ: float = 7.0
# Tuning.max_speed를 못 읽을 때의 정규화 기준.
const SPEED_REF_FALLBACK: float = 300.0
# 위상 속도(주기/초)가 목표 주파수를 따라가는 지수 추종 계수(1/초). 출발·속도 변화가 부드럽다.
# 위상은 지수 추종의 닫힌 형식으로 구간 적분하므로 프레임레이트와 무관하게 같은 궤적을 낸다.
const RATE_FOLLOW: float = 10.0
# 정지 시 위상 속도가 PARK_MIN_RATE(주기/초)를 향해 지수 수렴하는 계수(1/초). 빠르면 감속하고
# 출발 직후처럼 느리면 부드럽게 올라가므로 진입 속도와 무관하게 속도가 연속이고, 어떤 진입
# 상태에서도 1초 안에 다음 상승점에 도착한다(최악: 상승점 직후·속도 0 진입, 약 0.91초).
# 위상은 앞으로만 진행해 다음 상승점에서 멈춘다(역행·순간 이동 없음). 상승점은 cos 곡선의
# 극값이라 도착 순간 바늘 속도가 0이다.
const PARK_DECEL: float = 4.0
const PARK_MIN_RATE: float = 1.5

## 노루발(정적)과 바늘(왕복)을 별도 스프라이트로 분리한다(presentation.md §2.1).
## foot/needle 텍스처가 없으면 해당 파츠를 절차적 도형으로 그린다.
@export var foot_texture: Texture2D = null:
	set(value):
		foot_texture = value
		queue_redraw()
@export var needle_texture: Texture2D = null:
	set(value):
		needle_texture = value
		queue_redraw()
## 하위호환 단일 스프라이트(왕복 없음). foot/needle이 모두 없을 때만 사용.
@export var texture: Texture2D = null:
	set(value):
		texture = value
		queue_redraw()

var _speed: float = 0.0
var _running: bool = false
# 위상 [0,1): 0 = 상승점(끝 y=-NEEDLE_TRAVEL), 0.5 = 최하단(끝 y=0).
var _phase: float = 0.0
# 현재 위상 속도(주기/초). 주차 완료 시 0.
var _rate: float = 0.0
# 상승점에 주차 완료(정지) 상태. 씬 시작·카운트다운은 상승점 정지로 시작한다. 출발 직후처럼
# _rate가 0에 가까운 주행 상태와 구분하려고 속도 비교 대신 명시적 상태를 둔다.
var _parked: bool = true
# 주파수 정규화 기준 속도. _ready에서 Tuning.max_speed로 갱신.
var _speed_ref: float = SPEED_REF_FALLBACK


func _ready() -> void:
	# Tuning은 노드 경로로 읽는다(전역 식별자 미사용). 오토로드 없이 스크립트만 로드하는
	# 검사에서도 컴파일되고, 그때는 SPEED_REF_FALLBACK을 쓴다.
	var tuning: Node = get_node_or_null("/root/Tuning")
	if tuning != null and float(tuning.get("max_speed")) > 0.0:
		_speed_ref = float(tuning.get("max_speed"))


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	var was_parked: bool = _parked
	if _running:
		# 상승점 정지(_rate=0)에서 재개해도 지수 추종으로 연속 가속한다. 목표는 프레임 시작 값.
		_parked = false
		_phase = fposmod(_phase + _advance(_frequency(), RATE_FOLLOW, delta), 1.0)
	elif not _parked:
		# 현재 행정을 마저 진행하며 PARK_MIN_RATE로 수렴하고, 다음 상승점(위상 1.0)에 닿는
		# 프레임에서는 넘어간 만큼 더 진행하지 않고 정확히 상승점에 멈춘다.
		_phase += _advance(PARK_MIN_RATE, PARK_DECEL, delta)
		if _phase >= 1.0:
			_phase = 0.0
			_rate = 0.0
			_parked = true
	# 이미 주차된 채 정지가 이어지는 프레임은 그림이 같으므로 다시 그리지 않는다. 주차에 도달하는
	# 프레임(was_parked=false)과 재개하는 프레임(_parked=false)은 다시 그린다. 씬 시작 직후 첫
	# 그림은 트리 진입 시 엔진이 그리고, 텍스처 교체는 export 세터가 다시 그리게 한다.
	if not (was_parked and _parked):
		queue_redraw()


## 위상 속도 r(t) = f + (r0 - f)·e^(-k·t)를 [0, dt] 구간에서 적분한 위상 진행량을 돌려주고
## _rate를 구간 끝 속도로 갱신한다. 진행량 = f·dt + (r0 - f)·(1 - e^(-k·dt)) / k.
## 닫힌 형식이라 dt를 어떻게 나눠도 결과가 같다(프레임레이트 독립).
func _advance(target: float, k: float, dt: float) -> float:
	var decay: float = exp(-k * dt)
	var gap: float = _rate - target
	_rate = target + gap * decay
	return target * dt + gap * (1.0 - decay) / k


## PresentationController가 매 프레임 player.speed를 주입.
func set_speed(speed: float) -> void:
	_speed = maxf(speed, 0.0)


## PresentationController가 매 프레임 이동 히스테리시스 판정을 주입(정지·카운트다운·완주=false).
func set_running(running: bool) -> void:
	_running = running


## 현재 바늘 끝 y(노드 로컬). 최하단 0.0, 최상단 -NEEDLE_TRAVEL.
func needle_tip_y() -> float:
	return -NEEDLE_TRAVEL * (0.5 + 0.5 * cos(TAU * _phase))


## 노루발 표시 사각형(노드 로컬). 항상 동일하다.
func foot_rect() -> Rect2:
	return FOOT_RECT


## 속도 0..max_speed → FREQ_MIN_HZ..FREQ_MAX_HZ.
func _frequency() -> float:
	return lerpf(FREQ_MIN_HZ, FREQ_MAX_HZ, clampf(_speed / _speed_ref, 0.0, 1.0))


func _draw() -> void:
	if foot_texture == null and needle_texture == null and texture != null:
		var ts: Vector2 = texture.get_size()
		draw_texture(texture, Vector2(-ts.x * 0.5, -ts.y * 0.5))
		return
	if foot_texture != null:
		draw_texture_rect(foot_texture, FOOT_RECT, false)
	else:
		_draw_presser_foot()
	var tip: float = needle_tip_y()
	_draw_needle_shadow(tip)
	_draw_bar(tip)
	if needle_texture != null:
		var nsz: Vector2 = NEEDLE_SRC_SIZE * NEEDLE_SCALE
		var npos: Vector2 = Vector2(-NEEDLE_TIP_SRC.x, -NEEDLE_TIP_SRC.y) * NEEDLE_SCALE
		var nrect: Rect2 = Rect2(npos + Vector2(0.0, tip), nsz)
		# 오른쪽 아래로 비낀 바늘 실루엣 그림자: 상승점에서 바늘 끝이 은색 생크 위에 겹쳐도
		# 끝 모양이 어두운 배경 위에 떠 보이게 한다.
		var drop: Rect2 = Rect2(nrect.position + NEEDLE_DROP, nsz)
		draw_texture_rect(needle_texture, drop, false, NEEDLE_DROP_COLOR)
		for o in [Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0)]:
			draw_texture_rect(needle_texture, Rect2(nrect.position + o, nsz), false, NEEDLE_OUTLINE)
		draw_texture_rect(needle_texture, nrect, false, NEEDLE_TINT)
	else:
		_draw_needle(tip)
	_draw_clamp(tip)


## 노루발 윗면(생크 상단)부터 바늘 끝까지 오른쪽으로 비낀 그림자. 원점 기준 FOOT_RECT 안쪽만.
func _draw_needle_shadow(tip: float) -> void:
	var top: float = FOOT_RECT.position.y + FOOT_SHANK_TOP_FRAC * FOOT_RECT.size.y
	if tip <= top:
		return
	draw_rect(Rect2(3.0, top, 5.0, tip - top), NEEDLE_SHADOW, true)


## 바늘대: 클램프 위부터 화면 밖(BAR_TOP)까지. 상부는 약간 굵은 봉.
func _draw_bar(tip: float) -> void:
	var clamp_top: float = tip - NEEDLE_LENGTH - CLAMP_SIZE.y + CLAMP_OVERLAP
	var thick_y: float = tip + BAR_THICK_FROM
	_draw_rod(BAR_WIDTH, thick_y, clamp_top + 1.0)
	_draw_rod(BAR_THICK_WIDTH, tip + BAR_TOP, thick_y)
	# 굵기 전환부의 짧은 테이퍼 칼라.
	draw_rect(Rect2(-BAR_THICK_WIDTH * 0.5, thick_y - 3.0, BAR_THICK_WIDTH, 3.0), METAL_DARK, true)


func _draw_rod(width: float, top: float, bottom: float) -> void:
	var x: float = -width * 0.5
	var h: float = bottom - top
	draw_rect(Rect2(x - 1.0, top, width + 2.0, h), METAL_EDGE, true)
	draw_rect(Rect2(x, top, width, h), METAL, true)
	draw_rect(Rect2(x + width * 0.2, top, maxf(width * 0.25, 1.0), h), METAL_HI, true)
	draw_rect(Rect2(x + width * 0.75, top, width * 0.25, h), METAL_DARK, true)


## 바늘 샹크 상단을 물고 있는 클램프(바늘과 함께 이동).
func _draw_clamp(tip: float) -> void:
	var top: float = tip - NEEDLE_LENGTH - CLAMP_SIZE.y + CLAMP_OVERLAP
	var r: Rect2 = Rect2(-CLAMP_SIZE.x * 0.5, top, CLAMP_SIZE.x, CLAMP_SIZE.y)
	draw_rect(r.grow(1.0), METAL_EDGE, true)
	draw_rect(r, METAL_DARK, true)
	draw_rect(Rect2(r.position.x + 2.0, top + 2.0, 4.0, CLAMP_SIZE.y - 4.0), METAL, true)
	draw_circle(Vector2(CLAMP_SIZE.x * 0.5 - 1.0, top + CLAMP_SIZE.y * 0.5), 3.0, METAL_HI)


## 절차적 폴백 바늘(needle_texture 없을 때). 끝점 = (0, tip).
func _draw_needle(tip: float) -> void:
	var top: float = tip - NEEDLE_LENGTH
	draw_rect(Rect2(-2.5, top, 5.0, NEEDLE_LENGTH - 12.0), NEEDLE_COLOR, true)
	var point: PackedVector2Array = PackedVector2Array(
		[Vector2(-2.5, tip - 12.0), Vector2(2.5, tip - 12.0), Vector2(0.0, tip)]
	)
	draw_colored_polygon(point, METAL_HI)


## 절차적 폴백 노루발(foot_texture 없을 때). 원점 기준 FOOT_RECT와 비슷한 크기로 확대
## (배율 1.6: 노드 로컬 y[-144, 26], 폭 약 109px).
func _draw_presser_foot() -> void:
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.6, 1.6))
	# 접지 그림자.
	draw_circle(Vector2(0.0, 12.0), 30.0, SHADOW)
	# 샤프트(위로 뻗는 금속 기둥).
	draw_rect(Rect2(-8.0, -90.0, 16.0, 64.0), METAL, true)
	draw_rect(Rect2(-8.0, -90.0, 4.0, 64.0), METAL_HI, true)
	# 노루발 몸통(가로 바).
	draw_rect(Rect2(-34.0, -32.0, 68.0, 14.0), METAL, true)
	draw_rect(Rect2(-34.0, -32.0, 68.0, 4.0), METAL_HI, true)
	# 좌/우 발(바늘 슬롯을 사이에 둠).
	_draw_toe(-30.0)
	_draw_toe(16.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_toe(x: float) -> void:
	var toe: PackedVector2Array = PackedVector2Array(
		[
			Vector2(x, -20.0),
			Vector2(x + 14.0, -20.0),
			Vector2(x + 14.0, 8.0),
			Vector2(x + 7.0, 16.0),
			Vector2(x, 8.0),
		]
	)
	draw_colored_polygon(toe, METAL)
	draw_line(Vector2(x, -20.0), Vector2(x, 8.0), METAL_DARK, 2.0)
