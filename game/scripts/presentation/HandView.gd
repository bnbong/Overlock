class_name HandView
extends Node2D
## 원단을 좌우에서 누르는 손 플레이스홀더 (presentation.md §2.1 / §5.1 참고작 구도).
##
## 캐릭터가 화면 건너편에서 카메라를 향해 손을 앞으로 뻗은 구도다. 손은 화면 좌우
## 가장자리에서 크게 들어오며, 손목·소매가 위·바깥(수평선 너머 캐릭터 몸 쪽)으로 빠져
## 화면 밖으로 잘리고, 손끝(손톱)이 아래·안쪽(카메라 쪽 재봉선)을 향한다. 손등·손톱이
## 카메라를 마주본다. 기준 텍스처(hand.png, mirror=false)는 우측 손(손목 우상단·손끝
## 좌하단)이고, mirror=true면 좌우 반전해 좌측 손(손목 좌상단·손끝 우하단)이 된다.
## 속도에 비례해 미세 진동하고, 조향 입력 시 조향 방향의 손이 원단을 더 누른다(아래+
## 안쪽 이동 + 약간 확대, 반대 손은 이완). texture 지정 시 스프라이트로 교체(§9 함정 13).

const SKIN_COLOR: Color = Color(0.85, 0.66, 0.54, 1.0)
const SKIN_SHADOW: Color = Color(0.72, 0.54, 0.44, 1.0)
const SKIN_HI: Color = Color(0.90, 0.74, 0.62, 1.0)
const NAIL_COLOR: Color = Color(0.94, 0.86, 0.80, 1.0)

## 조향 누름 연출 상수.
const PRESS_SCALE: float = 0.07  # 누르는 손 확대 / 이완 손 축소 비율
const PRESS_INWARD: float = 16.0  # 누를 때 안쪽(재봉선)으로 이동(px)
const PRESS_DOWN: float = 12.0  # 누를 때 아래(원단)로 이동(px)
const STEER_LERP: float = 9.0  # 조향 값 보간 속도(1/s)

## true면 좌측 손(기준 우측 손 텍스처를 좌우 반전).
@export var mirror: bool = false
## null이면 _draw 도형, 지정되면 스프라이트로 렌더.
@export var texture: Texture2D = null

var _speed: float = 0.0
var _jitter: Vector2 = Vector2.ZERO
var _steer: float = 0.0
var _steer_target: float = 0.0
var _press: float = 0.0
# 씬이 지정한 기본 손 텍스처(hand.png). set_hand_texture(null)로 복원할 때 사용.
var _base_texture: Texture2D = null


func _ready() -> void:
	# 씬에서 배선된 기본 텍스처를 기억해 둔다(부상 교체 후 복원 기준).
	_base_texture = texture


func _process(delta: float) -> void:
	# 속도 비례 미세 진동.
	var amount: float = clampf(_speed / 300.0, 0.0, 1.0) * 2.5
	_jitter = Vector2(randf_range(-amount, amount), randf_range(-amount, amount))
	# 조향 값 보간(프레임 독립적 지수 감쇠).
	_steer += (_steer_target - _steer) * clampf(STEER_LERP * delta, 0.0, 1.0)
	# 이 손 쪽으로 조향할수록 press>0(누름), 반대면 press<0(이완). mirror=false=우측 손은
	# 우조향(steer>0), mirror=true=좌측 손은 좌조향(steer<0)에서 누른다.
	var own_side: float = -1.0 if mirror else 1.0
	_press = clampf(_steer * own_side, -1.0, 1.0)
	queue_redraw()


## PresentationController가 매 프레임 player.speed를 주입.
func set_speed(speed: float) -> void:
	_speed = maxf(speed, 0.0)


## PresentationController가 매 프레임 player.actual_steer를 주입(-1..1, 음수=좌).
func set_steer(steer: float) -> void:
	_steer_target = clampf(steer, -1.0, 1.0)


## 부상 단계에 따라 손 텍스처를 통째로 교체한다(§9 함정 13, 표현 전용).
## tex가 null이면 씬 기본 텍스처(hand.png)로 복원한다. 밴드가 그림에 구워진
## 손 텍스처들은 hand.png와 동일 캔버스·동일 손 위치로 정렬돼 있어, 교체해도
## _draw의 중심 정렬(-ts/2) 기준 손 위치가 그대로 유지된다.
func set_hand_texture(tex: Texture2D) -> void:
	texture = tex if tex != null else _base_texture
	queue_redraw()


func _draw() -> void:
	var flip: float = -1.0 if mirror else 1.0
	var s: float = 1.0 + PRESS_SCALE * _press
	# 누름은 아래(+y)로, 그리고 재봉선 쪽(안쪽)으로 이동한다. 안쪽은 우측 손이 -x,
	# 좌측 손이 +x이므로 flip 부호를 뒤집어(-flip) 양쪽 다 화면 중앙을 향하게 한다.
	var offset: Vector2 = _jitter + Vector2(-PRESS_INWARD * _press * flip, PRESS_DOWN * _press)
	draw_set_transform(offset, 0.0, Vector2(flip * s, s))
	if texture != null:
		var ts: Vector2 = texture.get_size()
		draw_texture(texture, Vector2(-ts.x * 0.5, -ts.y * 0.5))
		return
	_draw_forearm()
	_draw_back()
	# 손가락 4개: 손등(위)에서 재봉선 쪽(아래·안쪽)으로 굽어 손톱이 보인다.
	_draw_finger(Vector2(58.0, -28.0), 66.0, 0.30, 15.0)  # 검지(위)
	_draw_finger(Vector2(62.0, -8.0), 78.0, 0.40, 16.0)  # 중지
	_draw_finger(Vector2(62.0, 12.0), 74.0, 0.50, 15.0)  # 약지
	_draw_finger(Vector2(56.0, 30.0), 58.0, 0.60, 13.0)  # 소지(아래)
	# 엄지(손목 쪽 아래에서 재봉선 쪽으로. 짧고 두껍게 → 손과 이어져 보인다).
	_draw_finger(Vector2(4.0, 37.0), 48.0, 0.95, 22.0)


func _draw_forearm() -> void:
	# 바깥쪽(화면 가장자리)에서 들어오는 팔뚝.
	var arm: PackedVector2Array = PackedVector2Array(
		[
			Vector2(-46.0, -26.0),
			Vector2(-46.0, 38.0),
			Vector2(-190.0, 30.0),
			Vector2(-190.0, -44.0),
		]
	)
	draw_colored_polygon(arm, SKIN_COLOR)
	draw_line(Vector2(-46.0, -26.0), Vector2(-190.0, -44.0), SKIN_HI, 2.0)


func _draw_back() -> void:
	# 손등(도르섬): 손목→너클. 위를 향하고 손톱이 보이는 면.
	var back: PackedVector2Array = PackedVector2Array(
		[
			Vector2(-48.0, -26.0),
			Vector2(62.0, -34.0),
			Vector2(64.0, 34.0),
			Vector2(-48.0, 40.0),
		]
	)
	draw_colored_polygon(back, SKIN_COLOR)
	# 힘줄 음영(너클→손목).
	draw_line(Vector2(50.0, -24.0), Vector2(-30.0, -18.0), SKIN_SHADOW, 1.5)
	draw_line(Vector2(52.0, -8.0), Vector2(-30.0, -2.0), SKIN_SHADOW, 1.5)
	draw_line(Vector2(52.0, 8.0), Vector2(-30.0, 14.0), SKIN_SHADOW, 1.5)
	# 너클 하이라이트.
	draw_line(Vector2(58.0, -30.0), Vector2(60.0, 30.0), SKIN_HI, 2.0)


func _draw_finger(base: Vector2, length: float, angle: float, width: float) -> void:
	var dir: Vector2 = Vector2(cos(angle), sin(angle))
	var side: Vector2 = Vector2(-dir.y, dir.x) * (width * 0.5)
	var tip: Vector2 = base + dir * length
	var neck: Vector2 = base + dir * (length - width)
	var quad: PackedVector2Array = PackedVector2Array(
		[base - side, base + side, tip + side, tip - side]
	)
	draw_colored_polygon(quad, SKIN_COLOR)
	draw_line(base - side, tip - side, SKIN_SHADOW, 1.5)
	# 손톱(손끝, 손등 방향이라 보인다).
	var nail: PackedVector2Array = PackedVector2Array(
		[neck - side * 0.7, neck + side * 0.7, tip + side * 0.55, tip - side * 0.55]
	)
	draw_colored_polygon(nail, NAIL_COLOR)
