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
## 드리프트 누름 증폭: 드리프트 방향 손의 프레스에 더해지는 추가 press(반대 손은 0 유지).
const DRIFT_PRESS_BOOST: float = 0.85
## 엄마 찬스 전환 가로 슬라이드 거리(로컬 px). 노드 스케일(1.2)까지 곱해져 화면상 손을 확실히
## 밖으로 밀어낸다(swipe 양끝에서 잔상 없이 클리어되도록 넉넉히).
const MOM_SLIDE: float = 1700.0

## true면 좌측 손(기준 우측 손 텍스처를 좌우 반전).
@export var mirror: bool = false
## null이면 _draw 도형, 지정되면 스프라이트로 렌더.
@export var texture: Texture2D = null

## 엄마 찬스(오토파일럿) 중 표시하는 엄마 손. hand.png 캔버스·손 위치로 정렬돼 있어(엄마
## 고유 피부톤 유지) 중심 정렬(-ts/2) 기준 위치가 그대로 유지된다. 전환 중에는 현재(밴드 포함)
## 손과 엄마 손을 동시에 슬라이드로 교차시키므로 texture(플레이어 현재 손)는 절대 덮어쓰지 않는다
## → 종료 시 원래 상태(밴드 단계 포함)가 자동 복원된다(set_hand_texture 상태를 그대로 기억).
@export var mom_texture: Texture2D = preload("res://assets/gfx/hand_mom.png")

var _speed: float = 0.0
var _jitter: Vector2 = Vector2.ZERO
var _steer: float = 0.0
var _steer_target: float = 0.0
var _press: float = 0.0
# 드리프트 증폭(이 손이 드리프트 방향이면 1로 수렴, 아니면 0). 프레임 독립 보간.
var _drift_target: float = 0.0
var _drift_amt: float = 0.0
# 씬이 지정한 기본 손 텍스처(hand.png). set_hand_texture(null)로 복원할 때 사용.
var _base_texture: Texture2D = null
# 부상(cut) 차원의 현재 손 텍스처(기본 hand.png 또는 handcut* 단계). set_hand_texture로 갱신.
# 골무 차원과 결합해 최종 표시 텍스처를 산출하는 기준 상태다(_refresh_texture).
var _cut_texture: Texture2D = null
# 골무(thimble) 차원(양손). _thimble_on 활성 + 변형이 있으면 표시 텍스처를 _thimble_variant로
# 덮는다. 종료(set_thimble false) 시 _cut_texture로 정확히 복원된다(부상 단계 상태 보존).
var _thimble_on: bool = false
var _thimble_variant: Texture2D = null
# 엄마 찬스 전환 진행값(0..1). >0이면 _draw가 플레이어 손과 엄마 손을 슬라이드로 교차한다.
var _mom_swipe: float = 0.0


func _ready() -> void:
	# 씬에서 배선된 기본 텍스처를 기억해 둔다(부상 교체 후 복원 기준).
	_base_texture = texture
	_cut_texture = texture


func _process(delta: float) -> void:
	# 속도 비례 미세 진동.
	var amount: float = clampf(_speed / 300.0, 0.0, 1.0) * 2.5
	_jitter = Vector2(randf_range(-amount, amount), randf_range(-amount, amount))
	# 조향 값 보간(프레임 독립적 지수 감쇠).
	_steer += (_steer_target - _steer) * clampf(STEER_LERP * delta, 0.0, 1.0)
	# 드리프트 증폭도 같은 감쇠로 보간(급변 방지).
	_drift_amt += (_drift_target - _drift_amt) * clampf(STEER_LERP * delta, 0.0, 1.0)
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


## PresentationController가 매 프레임 드리프트 상태를 주입(active, dir=drift_dir -1..1).
## 드리프트 방향(dir 부호)과 같은 쪽 손이면 프레스를 더 깊게(DRIFT_PRESS_BOOST) 증폭하고,
## 반대 손은 증폭 없이 기존 조향 프레스 수준을 유지한다.
func set_drift(active: bool, dir: float) -> void:
	var own_side: float = -1.0 if mirror else 1.0
	_drift_target = 1.0 if (active and dir * own_side > 0.0) else 0.0


## PresentationController가 엄마 찬스(오토파일럿) 상태를 주입. swipe∈[0,1]=전환 진행값.
## texture(플레이어 현재 손)는 건드리지 않고 _draw에서 엄마 손과 슬라이드 교차만 한다 →
## 종료 시 set_hand_texture로 세팅된 밴드 단계가 그대로 복원된다. _process가 매 프레임
## queue_redraw 하므로 여기선 값만 저장한다.
func set_mom(_active: bool, swipe: float) -> void:
	_mom_swipe = clampf(swipe, 0.0, 1.0)


## 부상 단계에 따라 손 텍스처를 통째로 교체한다(§9 함정 13, 표현 전용).
## tex가 null이면 씬 기본 텍스처(hand.png)로 복원한다. 밴드가 그림에 구워진
## 손 텍스처들은 hand.png와 동일 캔버스·동일 손 위치로 정렬돼 있어, 교체해도
## _draw의 중심 정렬(-ts/2) 기준 손 위치가 그대로 유지된다. 골무 차원과 결합해
## 최종 표시 텍스처를 산출한다(_refresh_texture — 골무 활성 중 부상 발생도 정합).
func set_hand_texture(tex: Texture2D) -> void:
	_cut_texture = tex if tex != null else _base_texture
	_refresh_texture()


## 골무(thimble) 차원 주입(양손, 표현 전용). on=true + variant!=null이면 현재 부상 단계의
## _thimble 변형으로 표시 텍스처를 덮는다. PresentationController가 player.thimble_timer>0 상태와
## 현재 컷 단계에 맞는 변형(우: hand_thimble/handcut1_thimble/handcut3_thimble, 좌: hand_thimble/
## handcut2_thimble)을 매 프레임 전달한다. mirror=true인 좌측 손은 _draw가 변형을 좌우 반전해 그린다.
## 값이 그대로면 조기 반환(불필요한 재계산 방지).
func set_thimble(on: bool, variant: Texture2D) -> void:
	if on == _thimble_on and variant == _thimble_variant:
		return
	_thimble_on = on
	_thimble_variant = variant
	_refresh_texture()


## 부상 차원(_cut_texture)과 골무 차원(_thimble_on/_thimble_variant)을 결합해 실제 표시 텍스처를
## 결정한다. 골무 활성 + 변형 존재 시 변형 우선, 아니면 부상 단계 텍스처. 엄마 손 우선순위는 _draw의
## 스와이프 오버레이가 이 texture 위에 엄마 손을 그려 자연히 처리한다.
func _refresh_texture() -> void:
	texture = _thimble_variant if (_thimble_on and _thimble_variant != null) else _cut_texture
	queue_redraw()


func _draw() -> void:
	var flip: float = -1.0 if mirror else 1.0
	# 유효 프레스 = 조향 프레스 + 드리프트 증폭(드리프트 방향 손만 _drift_amt>0). 이 손이
	# 드리프트 방향일 때 1을 넘어 더 깊이 눌린다(반대 손은 증폭 0이라 기존 수준 그대로).
	var eff_press: float = _press + DRIFT_PRESS_BOOST * _drift_amt
	var s: float = 1.0 + PRESS_SCALE * eff_press
	# 누름은 아래(+y)로, 그리고 재봉선 쪽(안쪽)으로 이동한다. 안쪽은 우측 손이 -x,
	# 좌측 손이 +x이므로 flip 부호를 뒤집어(-flip) 양쪽 다 화면 중앙을 향하게 한다.
	var offset: Vector2 = _jitter + Vector2(-PRESS_INWARD * eff_press * flip, PRESS_DOWN * eff_press)
	# 엄마 찬스 전환 중: 플레이어 손(현재 texture=밴드 포함)을 왼쪽으로, 엄마 손을 오른쪽에서
	# 슬라이드 인(얼굴 슬라이드와 동일 매핑 — 전체 화면 푸시 느낌). swipe=1(hold)이면 플레이어
	# 손은 화면 밖, 엄마 손만 제자리. draw_set_transform의 translation은 flip 스케일에 곱해지지
	# 않으므로 양손 모두 같은 부호의 x 슬라이드를 준다.
	if _mom_swipe > 0.001 and mom_texture != null:
		_draw_hand_tex(texture, offset + Vector2(-_mom_swipe * MOM_SLIDE, 0.0), flip, s)
		_draw_hand_tex(mom_texture, offset + Vector2((1.0 - _mom_swipe) * MOM_SLIDE, 0.0), flip, s)
		return
	_draw_hand_tex(texture, offset, flip, s)


## 손 1장을 주어진 오프셋/스케일로 그린다. tex가 null이면 절차적 손 도형으로 폴백한다
## (기존 동작 보존 — 씬에서 texture가 항상 배선돼 실사용에선 스프라이트 경로).
func _draw_hand_tex(tex: Texture2D, offset: Vector2, flip: float, s: float) -> void:
	draw_set_transform(offset, 0.0, Vector2(flip * s, s))
	if tex != null:
		var ts: Vector2 = tex.get_size()
		draw_texture(tex, Vector2(-ts.x * 0.5, -ts.y * 0.5))
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
