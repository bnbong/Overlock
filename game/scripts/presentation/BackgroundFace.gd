class_name BackgroundFace
extends Control
## 내려다보는 캐릭터 얼굴 (presentation.md §2.1 / §14). BackdropLayer 스크린 고정.
##
## 참고작('용과 같이' 재봉 미니게임) 구도에 맞춰 얼굴을 수평선 위 백드롭 스트립 안에
## 눈·코까지 온전히 보이도록 재배치한다(구도 결함 수정 2). 텍스처를 전체 화면이 아니라
## 상단부 face_rect(스케일+세로 오프셋)에 그려, 720px 전체 높이 배치 때 수평선(~40%)이
## 눈을 잘라버리던 문제를 해소한다. 표정 오버레이·고개꺾기 피벗도 모두 이 face_rect
## 기준으로 유도해 재배치와 정합을 유지한다.
##
## 표정 표현은 세 모드를 우선순위대로 지원한다:
##  1) 눈 오버레이 스왑(현행 기본, 스크립트 preload 배선): 눈 없는 고정 베이스
##     (base_clean) 위에 상태별 눈 오버레이(eyes_normal/eyes_focus/eyes_injured)를
##     얹고, 상태 전환 시 **눈 오버레이만** 크로스페이드한다. 베이스가 고정이라
##     크로스페이드 중에도 머리카락·헤어밴드·볼 외곽이 전혀 떨리지 않는다(구
##     전체-얼굴 스왑 방식의 얼굴 떨림·눈 주변 밴드 경계 원천 차단). 땀방울은
##     sweat_texture 스프라이트로 집중 강도에 비례해 표시한다.
##  2) 전체-얼굴 텍스처 스왑(레거시): face_normal/face_focus/face_injured 슬롯이
##     하나라도 지정되고 오버레이 모드가 꺼졌을 때만. 상태별 얼굴 텍스처를
##     크로스페이드로 교체한다(눈 영역만 다른 동일 구도 3종).
##  3) 단일 base + 절차적 라인아트(레거시): 위 슬롯이 전부 비었을 때.
##     2차 아트의 앞머리가 눈을 덮는 구도라, 평상시엔 오버레이를 그리지 않고(가려진
##     콘셉트) 상태(집중/부상)일 때만 앞머리 사이 피부 창에 라인아트를 얹는다.
## 슬롯이 비어 있으면 순차적으로 하위 레거시 동작으로 복귀한다(회귀 금지).
## 조향 고개 꺾기는 모든 모드 공통(노드 트랜스폼).

## 표정 상태(스왑용). 부상 > 집중 > 평상 우선순위로 결정.
enum FaceState { NORMAL, FOCUS, INJURED }

const SKIN_COLOR: Color = Color(0.86, 0.68, 0.56, 1.0)
const SKIN_SHADOW: Color = Color(0.74, 0.56, 0.46, 1.0)
const HAIR_COLOR: Color = Color(0.20, 0.16, 0.18, 1.0)
const EYE_WHITE: Color = Color(0.95, 0.95, 0.92, 1.0)
const PUPIL_COLOR: Color = Color(0.16, 0.12, 0.12, 1.0)
const BROW_COLOR: Color = Color(0.22, 0.17, 0.15, 1.0)
## 표정 오버레이(피부 위에 얹혀 대비되도록 진한 자두색 라인).
const EXPR_LINE: Color = Color(0.24, 0.13, 0.16, 1.0)
const XEYE_COLOR: Color = Color(0.20, 0.09, 0.11, 1.0)
const SWEAT_FILL: Color = Color(0.62, 0.82, 0.95, 0.85)
const SWEAT_HI: Color = Color(0.92, 0.97, 1.0, 0.95)

## 조향 고개 꺾기 연출 상수.
const MAX_HEAD_TILT: float = 0.11  # 최대 고개 기울기(rad, ~6°)
const HEAD_LEAN_PX: float = 24.0  # 조향 방향으로 얼굴 이동(px)
const STEER_LERP: float = 8.0  # 조향 값 보간 속도(1/s)
## 고개꺾기 피벗 세로 위치(face_rect 높이 대비). 얼굴 아래(목/턱 근처)에서 기운다.
const HEAD_PIVOT_FRAC: float = 0.60

## 집중 상태로 전환하는 긴장(속도·리스크 통합) 임계치.
const FOCUS_THRESHOLD: float = 0.5
## 상태 전환 크로스페이드 지속(초).
const FACE_FADE_DUR: float = 0.2

## 눈 앵커 중점(캔버스 텍셀 640,248)의 오버레이 텍스처 대비 비율. eyes_scale 피벗.
## 눈동자 좌 (454,248)·우 (826,248)의 중점 = (640,248), 텍스처 1280×720 기준.
const EYE_ANCHOR_FRAC: Vector2 = Vector2(0.5, 248.0 / 720.0)

## 집중 땀방울 앵커(눈 오버레이 eye_rect 대비 비율). 오른쪽 눈(뷰어-우, 동공 앵커
## 826,248 → eye_rect 비율 ≈ 0.645,0.344) 바깥 관자놀이 부근 — 애니메이션 관례 위치.
## eye_rect가 eyes_offset_y·eyes_scale을 이미 반영하므로, 두 값을 바꿔도 땀 위치·크기가
## 자동으로 눈을 따라온다(구 독립 앵커 expr_sweat_frac은 절차 폴백 전용으로만 잔존).
## 우 동공에서 바깥으로 약 +0.07·아래로 약 +0.006 떨어진 관자놀이에 방울 꼬리를 앉힌다.
const EYE_SWEAT_FRAC: Vector2 = Vector2(0.715, 0.35)

## --- 눈 오버레이 스왑 모드(현행 기본) — 스크립트 preload 배선 ---
## Gameplay.tscn을 수정하지 않고 새 모드를 기본 활성화하기 위해 preload 기본값으로
## 배선한다(씬은 아래 face_normal/face_focus/face_injured만 지정 → 레거시 슬롯).
## base_clean이 지정되고 눈 오버레이가 하나라도 있으면 이 모드가 우선한다.
@export var base_clean: Texture2D = preload("res://assets/gfx/face_base_clean.png")
@export var eyes_normal: Texture2D = preload("res://assets/gfx/eyes_normal.png")
@export var eyes_focus: Texture2D = preload("res://assets/gfx/eyes_focus.png")
@export var eyes_injured: Texture2D = preload("res://assets/gfx/eyes_injured.png")
## 집중 땀방울 스프라이트(절차적 땀 대체). null이면 절차적 _draw_drop 폴백.
@export var sweat_texture: Texture2D = preload("res://assets/gfx/sweat.png")
## 땀방울 스프라이트 크기 배율(캔버스 기준 추가 배율). face_draw_scale과 곱해진다.
@export var sweat_scale: float = 1.0
## 눈 오버레이 세로 미세 조정(px, 캔버스 기준). 앞머리 위 눈 구도가 어색하면 조정.
## 사용자 확정값(2026-08-22): 50.0 — 취향 확정이므로 워커가 임의로 되돌리지 말 것.
@export var eyes_offset_y: float = 50.0
## 눈 오버레이 전체 스케일(앵커 중점 기준). 1.0=원본 PNG 크기. PNG 재가공 없이 눈
## 크기를 취향대로 미세 조정한다(eyes_offset_y와 동일 성격). 앵커 중점(640,248)을
## 고정점으로 확대/축소하므로 1.0보다 크면 두 눈이 함께 커지며 살짝 벌어진다. 눈
## 파츠 자체는 각 동공 중심 기준으로 이미 확대되어 PNG에 구워져 있고(앵커 유지),
## 이 값은 그 위에 얹는 런타임 미세 배율이다.
## 사용자 확정값(2026-08-22): 0.9 — 취향 확정이므로 워커가 임의로 되돌리지 말 것.
@export var eyes_scale: float = 0.9

## null이면 _draw 도형, 지정되면 스프라이트로 렌더(레거시 base + 오버레이).
@export var texture: Texture2D = null

## @deprecated 전체-얼굴 텍스처 스왑(레거시). Gameplay.tscn이 여전히 값을 할당하므로
## 프로퍼티는 유지하되, 위 눈 오버레이 스왑 모드가 우선한다(base_clean 지정 시 미사용).
## 오버레이 슬롯을 전부 비워야 이 레거시 스왑 경로가 활성화된다.
@export var face_normal: Texture2D = null
@export var face_focus: Texture2D = null
@export var face_injured: Texture2D = null

## 얼굴 배치(구도 결함 수정 2). 텍스처를 이 스케일로 축소해 상단부에 그린다.
## face_draw_scale=1.0, face_offset_y=0 이면 전체 화면(구 배치)과 동일.
@export var face_draw_scale: float = 0.72
@export var face_offset_y: float = -24.0

## 표정 오버레이 앵커(face_rect 대비 비율). 앞머리 사이 피부 창(눈·땀) 위치.
@export var expr_eye_dx_frac: float = 0.145  # 중앙 대비 좌우 눈 간격
@export var expr_eye_y_frac: float = 0.345  # 눈 세로 위치
## @deprecated 집중 땀방울 위치(face_rect 대비, 눈과 독립). 현행 눈 오버레이 스왑 모드는
## EYE_SWEAT_FRAC(eye_rect 기준)으로 땀을 파생시키므로 쓰지 않는다. 이 값은 최하위 절차
## 라인아트 폴백(_draw_state_overlay → _draw_sweat)에서만 사용된다(그 모드엔 눈 오버레이가
## 없어 face_rect 앵커가 필요).
@export var expr_sweat_frac: Vector2 = Vector2(0.69, 0.375)  # (레거시 절차 폴백 전용)

var _tension: float = 0.0  # 0..1 (부상>고위험>속도 집중 통합 강도)
var _stunned: bool = false
var _steer: float = 0.0
var _steer_target: float = 0.0

var _state: int = FaceState.NORMAL  # 현재 표정 상태(스왑용)
var _fade_from: int = FaceState.NORMAL  # 크로스페이드 시작 상태
var _fade_t: float = 1.0  # 0..1, 1이면 전환 완료
var _ovl_scale: float = 1.0  # 오버레이 도형 크기 스케일(face_rect에 비례)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## PresentationController가 매 프레임 주입. 표정 우선순위(presentation.md §5.1 참고작):
## 부상(_stunned) > 고위험(risk) > 속도별 집중(speed_index) > 평상.
## risk와 속도 집중은 같은 '집중' 축이라 더 큰 값이 우선한다(5단에서 집중 최대).
func set_expression(risk: float, stunned: bool, speed_index: int) -> void:
	var focus: float = clampf(float(speed_index - 1) / 4.0, 0.0, 1.0)
	var tension: float = clampf(maxf(risk, focus), 0.0, 1.0)
	var new_state: int = _compute_state(tension, stunned)
	if is_equal_approx(tension, _tension) and stunned == _stunned:
		return  # 아무것도 안 바뀜(상태도 tension·stunned에서 유도되므로 동일).
	_tension = tension
	_stunned = stunned
	if new_state != _state:
		# 스왑 크로스페이드 시작(절차적 폴백 모드에선 _fade_*가 그려지지 않아 무해).
		_fade_from = _state
		_state = new_state
		_fade_t = 0.0
	queue_redraw()


func _compute_state(tension: float, stunned: bool) -> int:
	if stunned:
		return FaceState.INJURED
	if tension >= FOCUS_THRESHOLD:
		return FaceState.FOCUS
	return FaceState.NORMAL


## PresentationController가 매 프레임 player.actual_steer를 주입(-1..1, 음수=좌).
func set_steer(steer: float) -> void:
	_steer_target = clampf(steer, -1.0, 1.0)


func _process(delta: float) -> void:
	var need_redraw: bool = false
	var prev: float = _steer
	_steer += (_steer_target - _steer) * clampf(STEER_LERP * delta, 0.0, 1.0)
	if absf(_steer - prev) > 0.0005:
		need_redraw = true
	# 상태 전환 크로스페이드 진행(스왑/오버레이 모드에서만 시각 효과).
	if _fade_t < 1.0:
		_fade_t = minf(_fade_t + delta / FACE_FADE_DUR, 1.0)
		need_redraw = true
	if need_redraw:
		queue_redraw()


## 눈 오버레이 스왑 모드 활성 조건: 고정 베이스 + 눈 오버레이가 하나라도 지정.
func _overlay_active() -> bool:
	if base_clean == null:
		return false
	return eyes_normal != null or eyes_focus != null or eyes_injured != null


## 전체-얼굴 텍스처 스왑(레거시) 활성 조건: face_* 슬롯이 하나라도 지정.
func _swap_active() -> bool:
	return face_normal != null or face_focus != null or face_injured != null


## 얼굴 텍스처 draw rect(상단부 배치). 텍스처 원본 aspect(1280×720=화면과 동일)를
## 유지하도록 가로·세로를 같은 배율로 줄이고 가로 중앙 정렬한다.
func _face_rect() -> Rect2:
	var dw: float = size.x * face_draw_scale
	var dh: float = size.y * face_draw_scale
	var dx: float = (size.x - dw) * 0.5
	return Rect2(dx, face_offset_y, dw, dh)


func _draw() -> void:
	var rect: Rect2 = _face_rect()
	_ovl_scale = face_draw_scale
	# 조향 방향으로 고개를 기울인다(face_rect 하단 피벗 기준 회전 + 약간의 수평 이동).
	var pivot: Vector2 = Vector2(
		rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * HEAD_PIVOT_FRAC
	)
	var angle: float = _steer * MAX_HEAD_TILT
	var lean: Vector2 = Vector2(_steer * HEAD_LEAN_PX, 0.0)
	draw_set_transform(lean + pivot - pivot.rotated(angle), angle, Vector2.ONE)
	if _overlay_active():
		_draw_overlay(rect)
	elif _swap_active():
		_draw_swap(rect)
	elif texture != null:
		# 레거시: base 스프라이트 + 상태(집중/부상)일 때만 앞머리 사이 피부 창 오버레이.
		draw_texture_rect(texture, rect, false)
		_draw_state_overlay(rect)
	else:
		_draw_fallback(rect)


## 눈 오버레이 스왑 모드(현행 기본): 고정 베이스를 불투명하게 깐 뒤, 상태별 눈
## 오버레이를 그 위에 얹는다. 상태 전환 시 눈 오버레이만 크로스페이드(옛→새 알파
## 상보 디졸브)한다. 베이스는 매 프레임 동일·불투명이라 얼굴 윤곽이 절대 떨리지 않고,
## 오버레이는 투명 배경이라 눈 주변 밴드 경계가 생기지 않는다.
func _draw_overlay(rect: Rect2) -> void:
	if base_clean != null:
		draw_texture_rect(base_clean, rect, false)
	# 눈 오버레이는 eyes_offset_y(캔버스 px)만큼 세로로 미세 이동해 그린다(베이스는 고정).
	var eye_rect: Rect2 = rect
	eye_rect.position.y += eyes_offset_y * face_draw_scale
	# eyes_scale: 앵커 중점(640,248)을 고정점으로 눈 오버레이만 확대/축소(베이스 불변).
	# 1.0이면 항등(원본 PNG 크기). PNG 재가공 없는 런타임 취향 조정 손잡이.
	if not is_equal_approx(eyes_scale, 1.0):
		var pivot: Vector2 = eye_rect.position + EYE_ANCHOR_FRAC * eye_rect.size
		var new_size: Vector2 = eye_rect.size * eyes_scale
		eye_rect = Rect2(pivot - EYE_ANCHOR_FRAC * new_size, new_size)
	var to_ov: Texture2D = _eye_overlay(_state)
	if _fade_t < 1.0:
		var from_ov: Texture2D = _eye_overlay(_fade_from)
		if from_ov != null:
			draw_texture_rect(from_ov, eye_rect, false, Color(1.0, 1.0, 1.0, 1.0 - _fade_t))
		if to_ov != null:
			draw_texture_rect(to_ov, eye_rect, false, Color(1.0, 1.0, 1.0, _fade_t))
	elif to_ov != null:
		draw_texture_rect(to_ov, eye_rect, false)
	# 집중 땀방울(부상 제외). 눈 오버레이 rect 기준이라 눈을 따라 이동한다. 긴장 강도에
	# 비례해 커지고 고집중에선 둘째 방울 추가.
	if not _stunned and _tension > 0.04:
		_draw_sweat_sprite(eye_rect)


## 상태 → 눈 오버레이(폴백: 상태 슬롯 → eyes_normal).
func _eye_overlay(state: int) -> Texture2D:
	var slot: Texture2D = null
	match state:
		FaceState.INJURED:
			slot = eyes_injured
		FaceState.FOCUS:
			slot = eyes_focus
		_:
			slot = eyes_normal
	if slot != null:
		return slot
	return eyes_normal


## 땀방울 스프라이트: 눈 오버레이 eye_rect 기준 상대 위치(EYE_SWEAT_FRAC)의 관자놀이에
## 그린다. eye_rect가 eyes_offset_y·eyes_scale을 이미 반영하므로 눈을 옮기거나 키우면
## 땀도 자동으로 따라온다(구 독립 face_rect 앵커 폐기). 크기·둘째 방울 간격은 눈 스케일
## (eyes_scale)에 비례시켜 눈과 함께 축척된다. sweat_texture가 없으면 절차적 _draw_drop
## 폴백. 긴장 강도로 크기 변조.
func _draw_sweat_sprite(eye_rect: Rect2) -> void:
	var base: Vector2 = eye_rect.position + EYE_SWEAT_FRAC * eye_rect.size
	# 방울 축척: 얼굴 배치 축척 × 눈 스케일(눈과 동일 체계라 눈이 작아지면 땀도 작아진다).
	var spr: float = _ovl_scale * eyes_scale
	if sweat_texture == null:
		_draw_drop(base, lerpf(4.0, 9.0, _tension) * spr)
		if _tension > 0.55:
			_draw_drop(base + Vector2(-16.0, 20.0) * spr, lerpf(2.0, 6.0, _tension) * spr)
		return
	var scl: float = spr * sweat_scale * lerpf(0.85, 1.35, _tension)
	var tsize: Vector2 = Vector2(sweat_texture.get_width(), sweat_texture.get_height()) * scl
	# 물방울 위쪽 꼬리를 앵커에 맞추고 아래로 늘어지게(가로 중앙 정렬).
	var pos: Vector2 = base - Vector2(tsize.x * 0.5, tsize.y * 0.15)
	draw_texture_rect(sweat_texture, Rect2(pos, tsize), false)
	if _tension > 0.55:
		var scl2: float = scl * 0.62
		var tsize2: Vector2 = Vector2(sweat_texture.get_width(), sweat_texture.get_height()) * scl2
		var pos2: Vector2 = (
			base + Vector2(-16.0, 24.0) * spr - Vector2(tsize2.x * 0.5, tsize2.y * 0.15)
		)
		draw_texture_rect(sweat_texture, Rect2(pos2, tsize2), false)


## 전체-얼굴 텍스처 스왑(레거시): 상태별 얼굴 텍스처를 크로스페이드로 그린다(눈 영역만
## 다른 동일 구도라 오버레이 불요 — 표정이 텍스처에 베이크됨). 슬롯이 일부만
## 채워졌으면 face_normal → base texture 순으로 폴백한다.
func _draw_swap(rect: Rect2) -> void:
	var to_tex: Texture2D = _state_tex(_state)
	if _fade_t < 1.0:
		var from_tex: Texture2D = _state_tex(_fade_from)
		if from_tex != null:
			# from_tex를 불투명하게 먼저 깔고 그 위에 to_tex만 _fade_t로 얹는다. 세 텍스처는
			# 알파 실루엣이 동일(규격 계약)하므로 얼굴이 항상 불투명하게 유지된다. 두 장을
			# 모두 부분 알파로 순차 블렌드하면(구 방식) 불투명 영역에도 배경이 최대 25%
			# 비쳐 보이던 크로스페이드 배경 누출을 없앤다.
			draw_texture_rect(from_tex, rect, false)
			if to_tex != null:
				draw_texture_rect(to_tex, rect, false, Color(1.0, 1.0, 1.0, _fade_t))
		elif to_tex != null:
			draw_texture_rect(to_tex, rect, false)
	elif to_tex != null:
		draw_texture_rect(to_tex, rect, false)


## 상태 → 텍스처(폴백: 상태 슬롯 → face_normal → base texture).
func _state_tex(state: int) -> Texture2D:
	var slot: Texture2D = null
	match state:
		FaceState.INJURED:
			slot = face_injured
		FaceState.FOCUS:
			slot = face_focus
		_:
			slot = face_normal
	if slot != null:
		return slot
	if face_normal != null:
		return face_normal
	return texture


## 스프라이트(레거시) 모드 표정 오버레이: 평상=없음, 집중=결의 눈+찡그림+땀,
## 부상=X자 눈. 좌표는 face_rect 기준이라 얼굴 재배치와 함께 따라간다.
func _draw_state_overlay(rect: Rect2) -> void:
	var cx: float = rect.position.x + rect.size.x * 0.5
	var eye_y: float = rect.position.y + rect.size.y * expr_eye_y_frac
	var eye_dx: float = rect.size.x * expr_eye_dx_frac
	var left: Vector2 = Vector2(cx - eye_dx, eye_y)
	var right: Vector2 = Vector2(cx + eye_dx, eye_y)
	if _stunned:
		_draw_x_eye(left)
		_draw_x_eye(right)
		return
	if _tension > 0.04:
		_draw_focus_eye(left, false)
		_draw_focus_eye(right, true)
		_draw_focus_brow(left, false)
		_draw_focus_brow(right, true)
		_draw_sweat(rect)


## 앞머리 사이 피부 창으로 내려다보며 치켜뜬 결의 눈매. 안쪽이 내려오는 굵은
## 윗속눈썹 라인 + 아래쪽 응시 눈동자. 긴장할수록 날카롭게(단순·또렷하게).
func _draw_focus_eye(center: Vector2, is_right: bool) -> void:
	var rx: float = 18.0 * _ovl_scale
	var inner: float = -1.0 if is_right else 1.0
	var slant: float = lerpf(3.0, 7.0, _tension) * _ovl_scale
	var in_pt: Vector2 = center + Vector2(inner * rx, slant)
	var out_pt: Vector2 = center + Vector2(-inner * rx, -slant * 0.7)
	draw_line(in_pt, out_pt, EXPR_LINE, 4.5 * _ovl_scale)
	draw_circle(
		center + Vector2(inner * rx * 0.15, 5.0 * _ovl_scale), 3.5 * _ovl_scale, PUPIL_COLOR
	)


## 찡그린 눈썹(안쪽이 내려와 결의/집중). 긴장할수록 강하게.
func _draw_focus_brow(eye_center: Vector2, is_right: bool) -> void:
	var inner: float = -1.0 if is_right else 1.0
	var brow_y: float = eye_center.y - 22.0 * _ovl_scale
	var inner_drop: float = lerpf(3.0, 12.0, _tension) * _ovl_scale
	var inner_x: float = eye_center.x + inner * 6.0 * _ovl_scale
	var outer_x: float = eye_center.x - inner * 22.0 * _ovl_scale
	draw_line(
		Vector2(inner_x, brow_y + inner_drop),
		Vector2(outer_x, brow_y - 6.0 * _ovl_scale),
		EXPR_LINE,
		4.0 * _ovl_scale
	)


## 부상 X자 눈(만화적, 눈 위치에 크게). 피부 창 위라 진한 라인이 또렷이 대비된다.
func _draw_x_eye(center: Vector2) -> void:
	var r: float = 15.0 * _ovl_scale
	draw_line(center + Vector2(-r, -r), center + Vector2(r, r), XEYE_COLOR, 6.0 * _ovl_scale)
	draw_line(center + Vector2(-r, r), center + Vector2(r, -r), XEYE_COLOR, 6.0 * _ovl_scale)


## 집중 땀방울(관자놀이). 긴장 강도에 비례해 커지고, 고집중에선 둘째 방울 추가.
func _draw_sweat(rect: Rect2) -> void:
	var base: Vector2 = Vector2(
		rect.position.x + rect.size.x * expr_sweat_frac.x,
		rect.position.y + rect.size.y * expr_sweat_frac.y
	)
	_draw_drop(base, lerpf(4.0, 9.0, _tension) * _ovl_scale)
	if _tension > 0.55:
		_draw_drop(base + Vector2(-16.0, 20.0) * _ovl_scale, lerpf(2.0, 6.0, _tension) * _ovl_scale)


func _draw_drop(center: Vector2, r: float) -> void:
	# 물방울: 아래 원 + 위 삼각 꼬리.
	draw_circle(center, r, SWEAT_FILL)
	var tail: PackedVector2Array = PackedVector2Array(
		[
			center + Vector2(-r * 0.75, -r * 0.2),
			center + Vector2(r * 0.75, -r * 0.2),
			center + Vector2(0.0, -r * 2.1),
		]
	)
	draw_colored_polygon(tail, SWEAT_FILL)
	draw_circle(center + Vector2(-r * 0.35, -r * 0.35), r * 0.35, SWEAT_HI)


# --- 폴백(텍스처 미지정): 1차 도형 얼굴(원안 그대로 보존, face_rect 기준) ---


func _draw_fallback(rect: Rect2) -> void:
	var w: float = rect.size.x
	var ox: float = rect.position.x
	var oy: float = rect.position.y
	var eye_y: float = oy + rect.size.y * 0.33
	var face_bottom: float = oy + rect.size.y * 0.44
	var cx: float = ox + w * 0.5
	_draw_head(rect)
	# 코 능선.
	var nose: PackedVector2Array = PackedVector2Array(
		[
			Vector2(cx - 14.0, eye_y),
			Vector2(cx + 14.0, eye_y),
			Vector2(cx + 4.0, face_bottom - 6.0),
			Vector2(cx - 4.0, face_bottom - 6.0),
		]
	)
	draw_colored_polygon(nose, SKIN_SHADOW)
	var eye_dx: float = w * 0.19
	_draw_eye(Vector2(cx - eye_dx, eye_y))
	_draw_eye(Vector2(cx + eye_dx, eye_y))
	_draw_brow(Vector2(cx - eye_dx, eye_y), false)
	_draw_brow(Vector2(cx + eye_dx, eye_y), true)


func _draw_head(rect: Rect2) -> void:
	var w: float = rect.size.x
	var ox: float = rect.position.x
	var oy: float = rect.position.y
	var face_bottom: float = oy + rect.size.y * 0.44
	# 돔형 얼굴(위/좌우로 face_rect 밖까지). 아래 가장자리는 턱선.
	var head: PackedVector2Array = PackedVector2Array(
		[
			Vector2(ox - w * 0.15, oy - 40.0),
			Vector2(ox + w * 1.15, oy - 40.0),
			Vector2(ox + w * 1.15, oy + rect.size.y * 0.44 * 0.55),
			Vector2(ox + w * 0.78, face_bottom),
			Vector2(ox + w * 0.5, face_bottom + 18.0),
			Vector2(ox + w * 0.22, face_bottom),
			Vector2(ox - w * 0.15, oy + rect.size.y * 0.44 * 0.55),
		]
	)
	draw_colored_polygon(head, SKIN_COLOR)
	# 머리카락 밴드(최상단).
	var hair: PackedVector2Array = PackedVector2Array(
		[
			Vector2(ox - w * 0.15, oy - 40.0),
			Vector2(ox + w * 1.15, oy - 40.0),
			Vector2(ox + w * 1.15, oy + rect.size.y * 0.44 * 0.16),
			Vector2(ox + w * 0.5, oy + rect.size.y * 0.44 * 0.26),
			Vector2(ox - w * 0.15, oy + rect.size.y * 0.44 * 0.16),
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
