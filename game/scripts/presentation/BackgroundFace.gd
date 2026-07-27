class_name BackgroundFace
extends Control
## 내려다보는 캐릭터 얼굴 플레이스홀더 (presentation.md §2.1). BackdropLayer 스크린 고정.
##
## 화면 폭에 꽉 차는 큰 실루엣, 수평선 위쪽에 눈 부근만 보이는 단순 도형 구성.
## 표정은 리스크/스턴에 따라 눈썹 각도·눈 모양이 변한다(PresentationController가 주입).
## texture가 지정되면 도형 대신 스프라이트로 교체(presentation.md §9 함정 13).

const SKIN_COLOR: Color = Color(0.86, 0.68, 0.56, 1.0)
const SKIN_SHADOW: Color = Color(0.74, 0.56, 0.46, 1.0)
const HAIR_COLOR: Color = Color(0.20, 0.16, 0.18, 1.0)
const EYE_WHITE: Color = Color(0.95, 0.95, 0.92, 1.0)
const PUPIL_COLOR: Color = Color(0.16, 0.12, 0.12, 1.0)
const BROW_COLOR: Color = Color(0.22, 0.17, 0.15, 1.0)

## 조향 고개 꺾기 연출 상수.
const MAX_HEAD_TILT: float = 0.11  # 최대 고개 기울기(rad, ~6°)
const HEAD_LEAN_PX: float = 24.0  # 조향 방향으로 얼굴 이동(px)
const STEER_LERP: float = 8.0  # 조향 값 보간 속도(1/s)

## null이면 _draw 도형, 지정되면 스프라이트로 렌더.
@export var texture: Texture2D = null

var _tension: float = 0.0  # 0..1 (부상>고위험>속도 집중 통합 강도)
var _stunned: bool = false
var _steer: float = 0.0
var _steer_target: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## PresentationController가 매 프레임 주입. 표정 우선순위(presentation.md §5.1 참고작):
## 부상(X자 눈, _stunned) > 고위험(risk) > 속도별 집중(speed_index) > 평상.
## risk와 속도 집중은 같은 '집중' 축이라 더 큰 값이 우선한다(5단에서 집중 최대).
func set_expression(risk: float, stunned: bool, speed_index: int) -> void:
	var focus: float = clampf(float(speed_index - 1) / 4.0, 0.0, 1.0)
	var tension: float = clampf(maxf(risk, focus), 0.0, 1.0)
	if is_equal_approx(tension, _tension) and stunned == _stunned:
		return
	_tension = tension
	_stunned = stunned
	queue_redraw()


## PresentationController가 매 프레임 player.actual_steer를 주입(-1..1, 음수=좌).
func set_steer(steer: float) -> void:
	_steer_target = clampf(steer, -1.0, 1.0)


func _process(delta: float) -> void:
	var prev: float = _steer
	_steer += (_steer_target - _steer) * clampf(STEER_LERP * delta, 0.0, 1.0)
	if absf(_steer - prev) > 0.0005:
		queue_redraw()


func _draw() -> void:
	# 조향 방향으로 고개를 기울인다(하단 피벗 기준 회전 + 약간의 수평 이동).
	var pivot: Vector2 = Vector2(size.x * 0.5, size.y * 0.58)
	var angle: float = _steer * MAX_HEAD_TILT
	var lean: Vector2 = Vector2(_steer * HEAD_LEAN_PX, 0.0)
	draw_set_transform(lean + pivot - pivot.rotated(angle), angle, Vector2.ONE)
	var w: float = size.x
	var eye_y: float = size.y * 0.33
	var face_bottom: float = size.y * 0.44
	var cx: float = w * 0.5
	# 머리/피부/머리카락/코는 텍스처 베이스로, 표정 요소(눈썹·눈·X자 눈)는 절차적
	# 유지 → 조향 고개꺾기·속도 집중·고위험·부상 표정 기믹을 전부 보존한다.
	# 텍스처의 눈 소켓은 아래 절차적 눈 좌표(cx±0.19w, 0.33h)에 맞춰 저작했다.
	if texture != null:
		draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
	else:
		_draw_head(w, face_bottom)
		# 코 능선(텍스처엔 이미 포함 → 폴백에서만 그린다).
		var nose: PackedVector2Array = PackedVector2Array(
			[
				Vector2(cx - 14.0, eye_y),
				Vector2(cx + 14.0, eye_y),
				Vector2(cx + 4.0, face_bottom - 6.0),
				Vector2(cx - 4.0, face_bottom - 6.0),
			]
		)
		draw_colored_polygon(nose, SKIN_SHADOW)
	# 표정(눈 + 눈썹)은 두 모드 모두 절차적으로 위에 그린다.
	var eye_dx: float = w * 0.19
	_draw_eye(Vector2(cx - eye_dx, eye_y))
	_draw_eye(Vector2(cx + eye_dx, eye_y))
	_draw_brow(Vector2(cx - eye_dx, eye_y), false)
	_draw_brow(Vector2(cx + eye_dx, eye_y), true)


func _draw_head(w: float, face_bottom: float) -> void:
	# 돔형 얼굴(위/좌우로 화면 밖까지). 아래 가장자리는 턱선.
	var head: PackedVector2Array = PackedVector2Array(
		[
			Vector2(-w * 0.15, -40.0),
			Vector2(w * 1.15, -40.0),
			Vector2(w * 1.15, face_bottom * 0.55),
			Vector2(w * 0.78, face_bottom),
			Vector2(w * 0.5, face_bottom + 18.0),
			Vector2(w * 0.22, face_bottom),
			Vector2(-w * 0.15, face_bottom * 0.55),
		]
	)
	draw_colored_polygon(head, SKIN_COLOR)
	# 머리카락 밴드(최상단).
	var hair: PackedVector2Array = PackedVector2Array(
		[
			Vector2(-w * 0.15, -40.0),
			Vector2(w * 1.15, -40.0),
			Vector2(w * 1.15, face_bottom * 0.16),
			Vector2(w * 0.5, face_bottom * 0.26),
			Vector2(-w * 0.15, face_bottom * 0.16),
		]
	)
	draw_colored_polygon(hair, HAIR_COLOR)


func _draw_eye(center: Vector2) -> void:
	if _stunned:
		# 부상 시 질끈 감은 눈(">< " 느낌의 선).
		draw_line(center + Vector2(-26.0, -8.0), center + Vector2(26.0, 8.0), PUPIL_COLOR, 4.0)
		draw_line(center + Vector2(-26.0, 8.0), center + Vector2(26.0, -8.0), PUPIL_COLOR, 4.0)
		return
	var rx: float = 30.0
	var ry: float = lerpf(18.0, 12.0, _tension)  # 긴장할수록 가늘게
	_draw_ellipse(center, rx, ry, EYE_WHITE)
	# 동공은 아래쪽(내려다봄).
	draw_circle(center + Vector2(0.0, ry * 0.35), 9.0, PUPIL_COLOR)


func _draw_brow(eye_center: Vector2, is_right: bool) -> void:
	# 긴장할수록 안쪽이 내려와 찡그린 표정.
	var inner_drop: float = lerpf(-2.0, 10.0, _tension)
	var outer_drop: float = lerpf(-6.0, -10.0, _tension)
	var brow_y: float = eye_center.y - 26.0
	var inner_x: float = eye_center.x + (18.0 if not is_right else -18.0)
	var outer_x: float = eye_center.x + (-30.0 if not is_right else 30.0)
	draw_line(
		Vector2(inner_x, brow_y + inner_drop),
		Vector2(outer_x, brow_y + outer_drop),
		BROW_COLOR,
		5.0
	)


func _draw_ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	var steps: int = 24
	for i in range(steps):
		var a: float = TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)
