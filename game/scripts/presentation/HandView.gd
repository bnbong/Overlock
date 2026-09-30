class_name HandView
extends Node2D
## 원단 위에 손바닥을 붙이고 누르는 손 (presentation.md §2.1 / §5.1, palm-contact 구도).
##
## 캐릭터가 화면 건너편에서 테이블에 엎드려 양손을 원단 위에 평평하게 얹은 구도다. 손목은
## 낮게 원단에 닿아 있고, 소매는 화면 좌우 가장자리 밖으로 잘리며, 손바닥·손가락이 원단에
## 밀착된 채 손끝(손톱)이 안쪽 아래(노루발 좌우의 재봉선 쪽)를 향한다. 기준 텍스처
## (palm_contact/hand_flat.png, mirror=false)는 우측 손(손목·소매 우측, 손끝 좌하단)이고,
## mirror=true면 좌우 반전해 좌측 손이 된다.
## 모든 손 변형(기본·부상 3단계·골무 4종·엄마)은 같은 1448x1086 캔버스라, 원본 크기와 무관하게
## 노드 원점 중심 사각형에 그린다. 플레이어(아이) 손 8종은 공통 표시 사각형(DISPLAY_SIZE)을,
## 엄마(어른) 손은 같은 중심·같은 4:3 비율로 MOM_HAND_SCALE배 큰 사각형을 쓴다. 텍스처별 불투명
## 영역 크롭은 하지 않는다(상태 전환 시 손목·손끝 위치 불변).
## 엄마 찬스 전환 때는 현재 손이 자기 쪽 화면 가장자리 밖으로 빠져나간 뒤 다음 캐릭터의 손이 같은
## 가장자리에서 들어온다(좌측 손은 왼쪽, 우측 손은 오른쪽). 두 캐릭터의 손이 동시에 보이지 않는다.
## 속도에 비례해 미세 진동하고, 조향 입력 시 조향 방향의 손이 원단을 더 누른다(안쪽 이동 +
## 약간의 하강 + 눈에 보이는 확대, 반대 손은 이완·약간 축소). 드리프트 방향 손은 더 크게 확대된다.
## 확대 기준점은 손끝 쪽(PRESS_PIVOT)이라 손이 주로 바깥·위쪽으로 커지고 손끝은 노루발 쪽으로 조금만
## 다가간다. 손목이 원단에서 들뜨지 않도록 세로 이동은 작게 유지한다. 손 아래에는 손과 같은 변환을
## 따르는 짧은 접촉 그림자를 먼저 그린다.
## texture가 null이면 절차적 도형으로 폴백한다(§9 함정 13).

## 부상 사전 연출 단계(SLIP: 미끄러짐, RECOIL: cut 직후 움찔 복귀, RELEASE: cut 없는 해제 복귀).
enum SlipMode { NONE, SLIP, RECOIL, RELEASE }

const SKIN_COLOR: Color = Color(0.85, 0.66, 0.54, 1.0)
const SKIN_SHADOW: Color = Color(0.72, 0.54, 0.44, 1.0)
const SKIN_HI: Color = Color(0.90, 0.74, 0.62, 1.0)
const NAIL_COLOR: Color = Color(0.94, 0.86, 0.80, 1.0)

## 플레이어(아이) 손 텍스처 공통 표시 크기(노드 로컬 px, 씬 scale 1.0이라 1280x720 기준 화면
## px). 원본 1448x1086(4:3) 캔버스를 가로·세로 같은 배율(630/1448 = 472.5/1086 ≈ 0.4351)로 그려
## 원본 종횡비를 그대로 보존한다(세로만 누르면 손이 납작해 보인다). 이전 600x450에서 5% 키웠다:
## 노드 위치는 그대로라 사각형이 중심 기준으로 커지고, 손끝(노드 중심에서 폭의 약 0.4배 안쪽)이
## 노루발 쪽으로 약 12px 다가간다. 부상·골무 변형 8종이 같은 사각형·같은 원점(중심)을 쓴다.
## 회귀 검사가 이 값을 읽는다.
const DISPLAY_SIZE: Vector2 = Vector2(630.0, 472.5)
## 엄마(어른) 손 표시 배율(DISPLAY_SIZE 대비, 가로·세로 같은 배율이라 4:3 유지). 손끝이 아이 손보다
## 노루발 쪽으로 더 다가가므로, 최대 드리프트 누름에서도 노루발 불투명 영역을 덮지 않는 범위에서
## 정했다(mom_display_rect 참조).
const MOM_HAND_SCALE: float = 1.08

## 접촉 그림자: 같은 텍스처를 어두운 반투명색으로 몇 px 아래에 먼저 그려, 손목·손바닥·
## 손가락 아래 가장자리에만 짧게 밀착된 그림자가 드러나게 한다(큰 원형 드롭 섀도 없음).
## 두 겹(가까운 진한 층 + 조금 먼 옅은 층)으로 가장자리를 부드럽게 한다.
## 오프셋은 화면 기준 방향이다(+x = 화면 오른쪽). 양손이 같은 광원을 받으므로 mirror 손도
## 화면에서 같은 쪽으로 밀린다(_draw_hand_tex가 로컬 x에 flip을 곱해 보정).
const CONTACT_SHADOW_NEAR: Vector2 = Vector2(0.0, 3.0)
const CONTACT_SHADOW_FAR: Vector2 = Vector2(2.0, 7.0)
const CONTACT_SHADOW_NEAR_COLOR: Color = Color(0.10, 0.03, 0.16, 0.42)
const CONTACT_SHADOW_FAR_COLOR: Color = Color(0.10, 0.03, 0.16, 0.18)

## 조향 누름 연출 상수. 손바닥이 원단에 붙어 있으므로 하강은 작게, 안쪽 이동과 확대 위주.
## 확대율은 조향(PRESS_SCALE)·이완(RELAX_SCALE)·드리프트(DRIFT_SCALE)를 따로 둬 독립적으로 조절한다
## (press_scale 참조). 최대 조향 1+PRESS_SCALE, 최대 드리프트 1+PRESS_SCALE+DRIFT_SCALE,
## 반대(이완) 손 최소 1-RELAX_SCALE.
## v2.2.1: 플레이 중 확대가 잘 안 보인다는 피드백으로 0.07/0.03/0.05에서 키웠다(최대 1.22배). 기준점이
## 손끝 쪽이라 늘어난 확대는 주로 바깥·위로 퍼지고, 손끝 안쪽 이동은 최대 드리프트에서 약 34px로
## 노루발 간격 예산(40px) 안이다(tools/palm_contact_regression 검사).
const PRESS_SCALE: float = 0.13  # 누르는 손(조향 방향) 확대 비율(최대 조향 기준)
const RELAX_SCALE: float = 0.05  # 이완 손(조향 반대) 축소 비율. 확대보다 작게 둬 과하게 줄지 않게 한다.
## 드리프트 방향 손 추가 확대 비율(_drift_amt=1 기준). 반대 손에는 더하지 않는다.
const DRIFT_SCALE: float = 0.09
## 확대 기준점(표시 사각형 크기 대비 비율, 사각형 중심 기준, mirror=false 우측 손 로컬). x는 손끝
## 쪽(안쪽, 음수), y는 손끝보다 조금 아래(손가락 중간 높이)다. 중심 기준으로 키우면 손끝(중심에서
## 폭의 약 0.4배 안쪽)이 확대율×폭×0.4만큼 노루발 쪽으로 다가가, 최대 드리프트(아이 손)와 최대
## 조향(엄마 손)에서 노루발과의 가로 간격이 10px 아래로 줄어든다. 기준점을 손끝 쪽으로 옮겨 손이
## 주로 바깥·위쪽으로 커지게 하고, 손끝은 확대율×폭×0.14만큼만 다가가게 한다(안쪽 이동
## PRESS_INWARD는 그대로 둔다). y를 손끝보다 아래에 둬 아래쪽 손가락이 속도 패널 쪽으로 덜
## 내려오게 한다. mirror 손은 _draw_hand_tex의 flip이 x를 뒤집어 같은 규칙이 적용된다.
const PRESS_PIVOT: Vector2 = Vector2(-0.26, 0.16)
const PRESS_INWARD: float = 8.0  # 누를 때 안쪽(재봉선)으로 이동(px)
const PRESS_DOWN: float = 2.5  # 누를 때 아래(원단)로 이동(px)
const STEER_LERP: float = 9.0  # 조향 값 보간 속도(1/s)
## 드리프트 누름 증폭: 드리프트 방향 손의 프레스에 더해지는 추가 press(반대 손은 0 유지).
const DRIFT_PRESS_BOOST: float = 0.85
## 드리프트 증폭 목표를 |dir|(=|drift_dir|=드리프트 중 actual_steer 크기)로 정하는 smoothstep 구간.
## |dir|<=DRIFT_DIR_LO면 증폭 0, |dir|>=DRIFT_DIR_HI면 1이다. 조향이 거의 없는 드리프트
## (actual_steer≈0)에서 남은 미세한 부호만으로 한쪽 손이 최대 증폭되거나, 부호가 뒤집힐 때 좌우 손이
## 번갈아 커지지 않게 한다. HI를 최대 조향(1)보다 작게 둬 중간 정도 조향한 드리프트부터 최대 확대가 걸린다.
const DRIFT_DIR_LO: float = 0.08
const DRIFT_DIR_HI: float = 0.4
## 속도 비례 진동 최대 진폭(px). 손목이 원단에서 들떠 보이지 않도록 세로는 0.5px 이하.
const JITTER_X: float = 1.2
const JITTER_Y: float = 0.4
## 엄마 찬스 손 교대 전환 시간(초). 앞 절반은 현재 손 퇴장, 뒤 절반은 다음 손 등장이다. 얼굴
## 슬라이드(0.35초)를 그대로 따르면 퇴장·등장이 각 0.175초라 너무 빨라 읽히지 않으므로, HandView가
## set_mom의 swipe 증감 방향만 목표로 삼아 자체 진행값(_swap)을 delta 기반으로 돌린다.
const MOM_SWAP_TIME: float = 0.44
## 교대 퇴장 이동 거리 산출용 기준 뷰포트 폭(project.godot viewport_width, stretch=canvas_items +
## keep이라 모바일에서도 캔버스 좌표 폭은 1280 고정).
const SWAP_VIEWPORT_W: float = 1280.0
## 교대 퇴장 위치에서 손 사각형 안쪽 끝이 화면 가장자리 밖으로 더 나가는 여유(px). 화면 흔들림
## (ForegroundLayer.offset)·접촉 그림자·진동을 넉넉히 덮는다.
const SWAP_MARGIN: float = 32.0
## 퇴장 거리 산출에 쓰는 최대 유효 프레스(조향 1 + 드리프트 증폭). 안쪽 이동 거리에 쓰고, 확대는
## max_press_scale()을 쓴다.
const SWAP_MAX_PRESS: float = 1.0 + DRIFT_PRESS_BOOST

## --- 부상 사전 연출(finger slip): RISK 최고 → 손 미끄러짐 → cut → 움찔 복귀 ---
## PresentationController가 cut 대상 손에만 set_slip(u)로 사전 연출 진행값(0..1)을 주입하고, 실제
## cut(스턴 상승엣지)에서 play_slip_recoil(), cut 없이 해제되면 release_slip()을 부른다. 추가 오프셋은
## 조향·진동·엄마 교대 오프셋 위에 더해지며 플레이어 손에만 적용된다(엄마 손에는 전이하지 않음).
## 손 이미지는 그대로 평행 이동만 한다(확대율·종횡비 불변, 그림자도 같은 변환을 공유).
## 접촉 손가락 끝(표시 사각형 중심 기준 로컬 px, mirror=false 우측 손). 기본·밴드·골무 변형 모두 같은
## 캔버스라 hand_flat.png 원본 1448x1086의 검지 손톱 끝(158,863)을 DISPLAY_SIZE 배율로 옮긴 값이다.
## 손 안쪽에서 가장 앞서는 손가락이라 노루발에 먼저 닿는다(1·3번째 cut의 밴드 손가락과 같다).
const SLIP_TIP: Vector2 = Vector2(-246.3, 139.2)
## 미끄러짐 끝에서 접촉 손가락 끝이 닿는 화면 지점. 화면 중앙(바늘 x=640)에서 가로 SLIP_TARGET_DX,
## 세로 SLIP_TARGET_Y(1280x720 캔버스). 노루발 불투명 영역(x 558..723, 아래 끝 y≈473)의 발끝 옆·
## 조금 앞쪽이라 손가락이 바늘 자리(x=640)나 노루발 밑으로 들어가지 않는다. 좌측 손은 좌우 대칭.
const SLIP_TARGET_DX: float = 90.0
const SLIP_TARGET_Y: float = 500.0
## 미끄러짐 이동 상한(px). 안쪽은 SLIP_MAX_IN, 위쪽은 SLIP_MAX_UP까지만 움직인다(손목이 원단에서
## 들떠 보이지 않도록 세로는 작게). 이미 눌려 안쪽으로 온 손은 필요한 만큼만 움직인다.
const SLIP_MAX_IN: float = 80.0
const SLIP_MAX_UP: float = 36.0
## 미끄러짐 곡선 c(u) = SLIP_EASE_LIN·u + (1-SLIP_EASE_LIN)·u². 기울기가 계속 커지는 ease-in이라
## 점점 빨라지고, 첫 프레임부터 조금은 움직여 놀란 눈과 함께 바로 읽힌다.
const SLIP_EASE_LIN: float = 0.25
## cut 직후 움찔 복귀(닫힌 형식, 프레임 독립). 전체 SLIP_RECOIL_DUR 중 앞 SLIP_RECOIL_OUT_FRAC 구간에
## 접촉 위치에서 바깥으로 SLIP_RECOIL_PX(아래로 SLIP_RECOIL_DOWN)만큼 튕겨 나가고, 나머지 구간에
## 제자리(0)로 부드럽게 돌아온다.
const SLIP_RECOIL_DUR: float = 0.16
const SLIP_RECOIL_OUT_FRAC: float = 0.35
const SLIP_RECOIL_PX: float = 14.0
const SLIP_RECOIL_DOWN: float = 2.0
## cut 없이 pending이 해제될 때(골무·엄마 찬스·이탈 리셋·리셋) 제자리로 돌아가는 시간(초, smoothstep).
const SLIP_RELEASE_DUR: float = 0.18
## 짧은 속도선(미끄러짐 중)과 접촉 섬광(cut 직후) 표현. Godot 기본 draw만 쓴다.
const SLIP_STREAK_COLOR: Color = Color(1.0, 1.0, 1.0, 0.7)
const SLIP_SPARK_DUR: float = 0.12
const SLIP_SPARK_LEN: float = 20.0
const SLIP_SPARK_COLOR: Color = Color(1.0, 0.93, 0.55, 1.0)


## true면 좌측 손(기준 우측 손 텍스처를 좌우 반전).
@export var mirror: bool = false
## null이면 _draw 도형, 지정되면 스프라이트로 렌더.
@export var texture: Texture2D = null

## 엄마 찬스(오토파일럿) 중 표시하는 엄마 손. 다른 손 변형과 같은 캔버스·같은 중심에 MOM_HAND_SCALE배
## 사각형으로 그린다(엄마 고유 피부톤·버건디 소매 유지). 전환은 _draw가 플레이어 손(현재 texture,
## 밴드·골무 포함)과 엄마 손 중 하나만 골라 그리므로 texture는 절대 덮어쓰지 않는다 → 종료 시 원래
## 상태(밴드 단계·골무 포함)가 자동 복원된다.
@export var mom_texture: Texture2D = preload("res://assets/gfx/palm_contact/hand_mom_flat.png")

var _speed: float = 0.0
var _jitter: Vector2 = Vector2.ZERO
var _steer: float = 0.0
var _steer_target: float = 0.0
var _press: float = 0.0
# 드리프트 증폭(이 손이 드리프트 방향이면 |dir| 크기에 따라 0..1로 수렴, 아니면 0). 프레임 독립 보간.
var _drift_target: float = 0.0
var _drift_amt: float = 0.0
# 씬이 지정한 기본 손 텍스처(hand_flat.png). set_hand_texture(null)로 복원할 때 사용.
var _base_texture: Texture2D = null
# 부상(cut) 차원의 현재 손 텍스처(기본 hand_flat.png 또는 handcut*_flat 단계). set_hand_texture로 갱신.
# 골무 차원과 결합해 최종 표시 텍스처를 산출하는 기준 상태다(_refresh_texture).
var _cut_texture: Texture2D = null
# 골무(thimble) 차원(양손). _thimble_on 활성 + 변형이 있으면 표시 텍스처를 _thimble_variant로
# 덮는다. 종료(set_thimble false) 시 _cut_texture로 정확히 복원된다(부상 단계 상태 보존).
var _thimble_on: bool = false
var _thimble_variant: Texture2D = null
# PresentationController가 주입한 엄마 찬스 전환 진행값(0..1, 얼굴 슬라이드와 공유). 손은 이 값의
# 증감 방향만 목표(_swap_target)로 삼는다.
var _mom_swipe: float = 0.0
# 손 교대 목표(0=플레이어 손, 1=엄마 손)와 자체 진행값(0..1). _swap<0.5 구간은 플레이어 손 퇴장,
# 0.5< 구간은 엄마 손 등장이다. 되감기(엄마→플레이어)는 같은 곡선을 거꾸로 따라가 엄마 손이 먼저
# 빠지고 플레이어 손이 들어온다. 도중에 목표가 바뀌어도 _swap이 연속이라 손이 순간 이동하지 않는다.
var _swap_target: float = 0.0
var _swap: float = 0.0
# 부상 사전 연출 상태. SLIP은 주입된 진행값(_slip_u)으로, RECOIL/RELEASE는 경과 시간(_slip_t)과
# 시작 순간 오프셋(_slip_from)의 닫힌 형식으로 오프셋을 정한다.
var _slip_mode: int = SlipMode.NONE
var _slip_u: float = 0.0
var _slip_t: float = 0.0
var _slip_from: Vector2 = Vector2.ZERO
# 접촉 섬광 위치(노드 로컬, cut 순간 손가락 끝).
var _spark_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	# 씬에서 배선된 기본 텍스처를 기억해 둔다(부상 교체 후 복원 기준).
	_base_texture = texture
	_cut_texture = texture


func _process(delta: float) -> void:
	# 속도 비례 미세 진동.
	# 세로 성분은 JITTER_Y(0.5px 이하)로 제한해 손목이 원단에서 들뜨지 않게 한다.
	var amount: float = clampf(_speed / 300.0, 0.0, 1.0)
	_jitter = Vector2(
		randf_range(-JITTER_X, JITTER_X) * amount, randf_range(-JITTER_Y, JITTER_Y) * amount
	)
	# 조향 값 보간(프레임 독립적 지수 감쇠).
	_steer += (_steer_target - _steer) * clampf(STEER_LERP * delta, 0.0, 1.0)
	# 드리프트 증폭도 같은 감쇠로 보간(급변 방지).
	_drift_amt += (_drift_target - _drift_amt) * clampf(STEER_LERP * delta, 0.0, 1.0)
	# 이 손 쪽으로 조향할수록 press>0(누름), 반대면 press<0(이완). mirror=false=우측 손은
	# 우조향(steer>0), mirror=true=좌측 손은 좌조향(steer<0)에서 누른다.
	var own_side: float = -1.0 if mirror else 1.0
	_press = clampf(_steer * own_side, -1.0, 1.0)
	# 손 교대 진행(프레임 독립 선형 진행, 곡선은 swap_fracs가 입힌다). 엄마 손 텍스처가 없으면
	# 교대하지 않고 플레이어 손을 제자리에 둔다(목표 0 고정, 그릴 엄마 손이 없어 빈 화면 방지).
	var swap_goal: float = _swap_target if mom_texture != null else 0.0
	_swap = move_toward(_swap, swap_goal, delta / MOM_SWAP_TIME)
	# 움찔 복귀·해제 복귀 경과 시간(닫힌 형식이라 누적 시간만 진행). 끝나면 오프셋 0으로 종료.
	if _slip_mode == SlipMode.RECOIL or _slip_mode == SlipMode.RELEASE:
		_slip_t += maxf(delta, 0.0)
		var dur: float = SLIP_RECOIL_DUR if _slip_mode == SlipMode.RECOIL else SLIP_RELEASE_DUR
		if _slip_t >= dur:
			_slip_mode = SlipMode.NONE
	queue_redraw()


## PresentationController가 매 프레임 player.speed를 주입.
func set_speed(speed: float) -> void:
	_speed = maxf(speed, 0.0)


## PresentationController가 매 프레임 player.actual_steer를 주입(-1..1, 음수=좌).
func set_steer(steer: float) -> void:
	_steer_target = clampf(steer, -1.0, 1.0)


## PresentationController가 매 프레임 드리프트 상태를 주입(active, dir=drift_dir -1..1).
## 드리프트 방향(dir 부호)과 같은 쪽 손이면 프레스를 더 깊게(DRIFT_PRESS_BOOST) 증폭하고,
## 반대 손은 증폭 없이 기존 조향 프레스 수준을 유지한다. 증폭 목표는 부호만 보지 않고
## smoothstep(DRIFT_DIR_LO, DRIFT_DIR_HI, |dir|)로 조향 크기에 따라 연속으로 정한다. 조향이 0 근처면
## 양손 모두 증폭 0이라 미세한 부호 변화에 손 크기가 흔들리지 않는다.
func set_drift(active: bool, dir: float) -> void:
	var own_side: float = -1.0 if mirror else 1.0
	if not active or dir * own_side <= 0.0:
		_drift_target = 0.0
		return
	_drift_target = smoothstep(DRIFT_DIR_LO, DRIFT_DIR_HI, absf(dir))


## PresentationController가 엄마 찬스(오토파일럿) 상태를 주입. swipe∈[0,1]=얼굴 전환 진행값.
## active는 swipe>0인 동안 계속 true라(복귀 중에도) 방향 판단에 쓰지 않는다. 손은 swipe가 끝값
## (0/1)이면 그 값을, 중간이면 증가(진입)/감소(복귀) 방향을 교대 목표로 삼아 _process에서 자체
## 진행값을 움직인다. texture(플레이어 현재 손)는 건드리지 않는다 → 종료 시 set_hand_texture로
## 세팅된 밴드 단계가 그대로 복원된다.
func set_mom(_active: bool, swipe: float) -> void:
	var s: float = clampf(swipe, 0.0, 1.0)
	if s >= 0.999:
		_swap_target = 1.0
	elif s <= 0.001:
		_swap_target = 0.0
	elif s > _mom_swipe:
		_swap_target = 1.0
	elif s < _mom_swipe:
		_swap_target = 0.0
	_mom_swipe = s


## 부상 단계에 따라 손 텍스처를 통째로 교체한다(§9 함정 13, 표현 전용).
## tex가 null이면 씬 기본 텍스처(hand_flat.png)로 복원한다. 밴드가 그림에 구워진
## 손 텍스처들은 hand_flat.png와 동일 캔버스·동일 손 위치로 정렬돼 있고 모두 같은
## DISPLAY_SIZE 사각형에 그려지므로, 교체해도 손 위치가 그대로 유지된다. 골무 차원과 결합해
## 최종 표시 텍스처를 산출한다(_refresh_texture — 골무 활성 중 부상 발생도 정합).
func set_hand_texture(tex: Texture2D) -> void:
	_cut_texture = tex if tex != null else _base_texture
	_refresh_texture()


## 골무(thimble) 차원 주입(양손, 표현 전용). on=true + variant!=null이면 현재 부상 단계의
## _thimble 변형으로 표시 텍스처를 덮는다. PresentationController가 player.thimble_timer>0 상태와
## 현재 컷 단계에 맞는 변형(우: hand_thimble/handcut1_thimble/handcut3_thimble, 좌: hand_thimble/
## handcut2_thimble, 모두 palm_contact/*_flat)을 매 프레임 전달한다. mirror=true인 좌측 손은 _draw가 변형을 좌우 반전해 그린다.
## 값이 그대로면 조기 반환(불필요한 재계산 방지).
func set_thimble(on: bool, variant: Texture2D) -> void:
	if on == _thimble_on and variant == _thimble_variant:
		return
	_thimble_on = on
	_thimble_variant = variant
	_refresh_texture()


## 부상 차원(_cut_texture)과 골무 차원(_thimble_on/_thimble_variant)을 결합해 실제 표시 텍스처를
## 결정한다. 골무 활성 + 변형 존재 시 변형 우선, 아니면 부상 단계 텍스처. 엄마 손 표시 여부는 _draw가
## 교대 진행값으로 결정하므로 이 texture와 무관하다.
func _refresh_texture() -> void:
	texture = _thimble_variant if (_thimble_on and _thimble_variant != null) else _cut_texture
	queue_redraw()


func _draw() -> void:
	var flip: float = -1.0 if mirror else 1.0
	var s: float = press_scale()
	# 엄마 찬스 손 교대: 플레이어 손(현재 texture=밴드·골무 포함)과 엄마 손 중 하나만 그린다.
	# 각 손은 자기 쪽 바깥(좌측 손 -x, 우측 손 +x)으로 swap_distance만큼 빠진 자리와 제자리 사이를
	# 오간다. 누름·진동 오프셋은 전환 중에도 그대로 더해 손 모양이 튀지 않게 한다. 접촉 그림자도
	# 같은 호출 안에서 그려 이동을 그대로 따라간다(손이 빠진 자리에 그림자가 남지 않음).
	# 부상 미끄러짐 오프셋은 플레이어 손에만 더한다(엄마 손으로 전이하지 않음).
	if mom_texture != null and mom_hand_visible():
		_draw_hand_tex(mom_texture, _mom_draw_offset(), flip, s, mom_display_rect())
	elif player_hand_visible():
		_draw_hand_tex(texture, _player_draw_offset(), flip, s, display_rect())
		draw_set_transform(Vector2(player_hand_dx(), 0.0), 0.0, Vector2.ONE)
		_draw_slip_accents(slip_offset())


## 엄마 손 그리기 오프셋(진동 + 누름 + 교대). 부상 미끄러짐은 더하지 않는다.
func _mom_draw_offset() -> Vector2:
	return _jitter + _press_offset() + Vector2(mom_hand_dx(), 0.0)


## 플레이어 손 그리기 오프셋(진동 + 누름 + 교대 + 부상 미끄러짐).
func _player_draw_offset() -> Vector2:
	return _jitter + _press_offset() + Vector2(player_hand_dx(), 0.0) + slip_offset()


## 누름 오프셋(진동 제외). 유효 프레스 = 조향 프레스 + 드리프트 증폭(드리프트 방향 손만 _drift_amt>0).
## 이 손이 드리프트 방향일 때 1을 넘어 더 깊이 눌린다(반대 손은 증폭 0이라 기존 수준 그대로).
## 누름은 아래(+y)로, 그리고 재봉선 쪽(안쪽)으로 이동한다. 안쪽은 우측 손이 -x, 좌측 손이 +x이므로
## flip 부호를 뒤집어(-flip) 양쪽 다 화면 중앙을 향하게 한다.
func _press_offset() -> Vector2:
	var flip: float = -1.0 if mirror else 1.0
	var eff_press: float = _press + DRIFT_PRESS_BOOST * _drift_amt
	return Vector2(-PRESS_INWARD * eff_press * flip, PRESS_DOWN * eff_press)


## 부상 사전 연출 진행값 주입(PresentationController가 cut 대상 손에만 매 프레임 호출, 0..1).
## 움찔·해제 복귀 중에 새 pending이 시작되면 현재 위치에서 이어 가도록 SLIP으로 바로 전환한다.
func set_slip(u: float) -> void:
	_slip_mode = SlipMode.SLIP
	_slip_u = clampf(u, 0.0, 1.0)
	queue_redraw()


## 실제 cut(스턴 상승엣지): 현재 미끄러진 위치에서 바깥으로 짧게 움찔한 뒤 제자리로 돌아온다.
## 접촉 섬광은 이 순간의 손가락 끝에서 짧게 터진다.
func play_slip_recoil() -> void:
	_slip_from = slip_offset()
	_spark_pos = _press_point(SLIP_TIP, display_rect()) + _slip_from
	_slip_mode = SlipMode.RECOIL
	_slip_t = 0.0
	queue_redraw()


## cut 없이 pending이 해제됨(골무·엄마 찬스·이탈 리셋·리셋): 움찔 없이 부드럽게 제자리로.
## immediate=true면 즉시 제자리(리셋·재시작 경로).
func release_slip(immediate: bool = false) -> void:
	if immediate:
		_slip_mode = SlipMode.NONE
		_slip_u = 0.0
		_slip_t = 0.0
		_slip_from = Vector2.ZERO
	elif _slip_mode != SlipMode.NONE:
		_slip_from = slip_offset()
		_slip_mode = SlipMode.RELEASE
		_slip_t = 0.0
	queue_redraw()


## 현재 부상 연출 추가 오프셋(노드 로컬 px, 화면 방향). 회귀 검사·캡처용 읽기 전용.
func slip_offset() -> Vector2:
	match _slip_mode:
		SlipMode.SLIP:
			var u: float = _slip_u
			return _slip_goal() * (SLIP_EASE_LIN * u + (1.0 - SLIP_EASE_LIN) * u * u)
		SlipMode.RECOIL:
			return _recoil_offset_at(_slip_t, _slip_from, _outward())
		SlipMode.RELEASE:
			var k: float = clampf(_slip_t / SLIP_RELEASE_DUR, 0.0, 1.0)
			return _slip_from * (1.0 - k * k * (3.0 - 2.0 * k))
	return Vector2.ZERO


## 미끄러짐 끝(u=1)의 목표 오프셋. 지금 누름 상태의 손가락 끝(진동 제외)에서 접촉 목표 지점까지의
## 벡터를 안쪽 [0, SLIP_MAX_IN], 세로 [-SLIP_MAX_UP, 0]으로 자른다. 누름·확대로 이미 안쪽에 온
## 손은 덜 움직여 어느 조향 상태에서도 손가락 끝이 같은 자리에서 멈춘다(바늘 자리 침범 방지).
func _slip_goal() -> Vector2:
	var tip: Vector2 = _press_point(SLIP_TIP, display_rect())
	var d: Vector2 = _slip_target_local() - tip
	var inward: float = clampf(-d.x * _outward(), 0.0, SLIP_MAX_IN)
	return Vector2(-inward * _outward(), clampf(d.y, -SLIP_MAX_UP, 0.0))


## 접촉 목표 지점(노드 로컬). 화면 중앙 x에서 자기 쪽으로 SLIP_TARGET_DX, 세로 SLIP_TARGET_Y.
func _slip_target_local() -> Vector2:
	var cx: float = SWAP_VIEWPORT_W * 0.5 + SLIP_TARGET_DX * _outward()
	return Vector2(cx, SLIP_TARGET_Y) - position


## 현재 손가락 끝의 노드 로컬 위치(진동 제외, 미끄러짐 포함). 회귀 검사·캡처가 읽는다.
func _slip_tip_local() -> Vector2:
	return _press_point(SLIP_TIP, display_rect()) + slip_offset()


## 움찔 복귀 오프셋(닫힌 형식). t∈[0, OUT]: 시작 오프셋 from에서 바깥 튕김 지점까지 ease-out,
## t∈[OUT, DUR]: 튕김 지점에서 0까지 smoothstep. DUR 이후 0. outward는 바깥 x 부호(+1 우측 손).
static func _recoil_offset_at(t: float, from: Vector2, outward: float) -> Vector2:
	if t < 0.0:
		return from
	if t >= SLIP_RECOIL_DUR:
		return Vector2.ZERO
	var peak: Vector2 = Vector2(SLIP_RECOIL_PX * outward, SLIP_RECOIL_DOWN)
	var t_out: float = SLIP_RECOIL_DUR * SLIP_RECOIL_OUT_FRAC
	if t < t_out:
		var v: float = t / t_out
		return from.lerp(peak, 1.0 - (1.0 - v) * (1.0 - v))
	var w: float = (t - t_out) / (SLIP_RECOIL_DUR - t_out)
	return peak * (1.0 - w * w * (3.0 - 2.0 * w))


## 로컬 점 p(표시 사각형 기준, mirror 전)가 지금 누름 변환(확대 기준점·안쪽 이동, 진동 제외)으로
## 그려지는 노드 로컬 위치. _draw_hand_tex의 변환과 같은 식이다.
func _press_point(p: Vector2, rect: Rect2) -> Vector2:
	var flip: float = -1.0 if mirror else 1.0
	var s: float = press_scale()
	var pivot: Vector2 = rect.get_center() + rect.size * PRESS_PIVOT
	var origin: Vector2 = _press_offset() + Vector2(pivot.x * flip, pivot.y) * (1.0 - s)
	return origin + Vector2(p.x * flip, p.y) * s


## 속도선(미끄러짐 중, 손등 바깥 뒤쪽으로 짧게)과 접촉 섬광(cut 직후 손가락 끝). 손 변환과 무관한
## 노드 로컬 좌표에 그린다(확대·반전 없음).
func _draw_slip_accents(slip: Vector2) -> void:
	var out: float = _outward()
	if _slip_mode == SlipMode.SLIP and _slip_u > 0.2:
		var a: float = clampf((_slip_u - 0.2) / 0.5, 0.0, 1.0)
		var tip: Vector2 = _press_point(SLIP_TIP, display_rect()) + slip
		var col: Color = Color(SLIP_STREAK_COLOR, SLIP_STREAK_COLOR.a * a)
		var len_px: float = 18.0 + 30.0 * _slip_u
		# 손가락 끝 아래 원단 위에 이동 방향(안쪽·위)과 평행하게, 바깥 뒤쪽으로 꼬리를 남긴다.
		for k in range(3):
			var base: Vector2 = tip + Vector2(out * (18.0 + 30.0 * k), 40.0 + 12.0 * k)
			draw_line(base, base + Vector2(out, 0.8) * len_px * 0.7, col, 3.0, true)
	if _slip_mode == SlipMode.RECOIL and _slip_t < SLIP_SPARK_DUR:
		var k2: float = _slip_t / SLIP_SPARK_DUR
		var col2: Color = Color(SLIP_SPARK_COLOR, 1.0 - k2 * k2)
		for j in range(5):
			var dir: Vector2 = Vector2(-out, 0.0).rotated((-0.9 + 0.45 * j) * out)
			var a0: Vector2 = _spark_pos + dir * SLIP_SPARK_LEN * (0.3 + 0.6 * k2)
			var a1: Vector2 = _spark_pos + dir * SLIP_SPARK_LEN * (0.9 + 0.8 * k2)
			draw_line(a0, a1, col2, 3.0, true)


## 교대 진행값 p(0..1)에서 (플레이어 손, 엄마 손)의 퇴장 비율(0=제자리, 1=화면 밖 퇴장 위치).
## p 0→0.5: 플레이어 손이 가속하며 빠진다(2차 ease-in). p 0.5→1: 엄마 손이 감속하며 들어온다(2차
## ease-out). 거꾸로 진행하면 엄마 손이 가속하며 빠지고 플레이어 손이 감속하며 들어온다. p=0.5에서
## 둘 다 1. 3차 곡선은 출발이 4~5프레임 정체돼 반응이 늦어 보여 2차를 쓴다.
static func swap_fracs(p: float) -> Vector2:
	var u: float = clampf(p / 0.5, 0.0, 1.0)
	var v: float = clampf((p - 0.5) / 0.5, 0.0, 1.0)
	return Vector2(u * u, (1.0 - v) * (1.0 - v))


## 교대 퇴장 이동 거리(px, 양수). 손 사각형 안쪽 끝(손끝 쪽)이 자기 쪽 화면 가장자리 밖으로
## SWAP_MARGIN만큼 더 나갈 거리다. 더 큰 엄마 사각형·최대 누름 확대·안쪽 이동·진동·그림자를 모두
## 포함해 두 손에 같은 거리를 쓴다(퇴장/등장 속도 일치). 확대 기준점이 안쪽(PRESS_PIVOT.x<0)이라
## 실제 안쪽 끝의 확장은 반폭×max_press_scale()보다 작으므로 이 값은 보수적인 상한이다.
func swap_distance() -> float:
	var edge: float = position.x if mirror else SWAP_VIEWPORT_W - position.x
	var half_w: float = mom_display_rect().size.x * 0.5 * max_press_scale()
	var shadow: float = maxf(absf(CONTACT_SHADOW_FAR.x), absf(CONTACT_SHADOW_NEAR.x))
	return edge + half_w + PRESS_INWARD * SWAP_MAX_PRESS + JITTER_X + shadow + SWAP_MARGIN


## 현재 표시 확대율(1=기본). 이 손 쪽으로 조향할수록 1+PRESS_SCALE까지, 반대면 1-RELAX_SCALE까지,
## 드리프트 방향 손이면 DRIFT_SCALE×_drift_amt(|dir|에 따라 0..1)를 더한다. _press·_drift_amt가
## STEER_LERP로 보간되므로 확대율도 부드럽게 변한다(press=0에서 기울기만 바뀌고 값은 연속).
## 회귀 검사·캡처용 읽기 전용.
func press_scale() -> float:
	var steer_part: float = PRESS_SCALE * _press if _press > 0.0 else RELAX_SCALE * _press
	return 1.0 + steer_part + DRIFT_SCALE * _drift_amt


## 누름 확대율 상한(최대 조향 + 최대 드리프트). 교대 퇴장 거리·회귀 검사가 쓴다.
static func max_press_scale() -> float:
	return 1.0 + PRESS_SCALE + DRIFT_SCALE


## 현재 교대 진행값(0=플레이어 손 제자리, 1=엄마 손 제자리). 회귀 검사·캡처용 읽기 전용.
## mom_texture가 null이면 교대하지 않으므로 항상 0이다(아래 접근자 모두 이 값을 기준으로 한다).
func swap_progress() -> float:
	return _swap if mom_texture != null else 0.0


## 플레이어 손의 교대 x 오프셋(px, 바깥쪽 부호). 좌측 손은 음수, 우측 손은 양수로 빠진다.
func player_hand_dx() -> float:
	return _outward() * swap_distance() * swap_fracs(swap_progress()).x


## 엄마 손의 교대 x 오프셋(px, 바깥쪽 부호).
func mom_hand_dx() -> float:
	return _outward() * swap_distance() * swap_fracs(swap_progress()).y


## 플레이어 손을 그리는 구간인가(p<0.5). p=0.5는 두 손 모두 화면 밖이라 그리지 않는다.
func player_hand_visible() -> bool:
	return swap_progress() < 0.5


## 엄마 손을 그리는 구간인가(p>0.5).
func mom_hand_visible() -> bool:
	return swap_progress() > 0.5


func _outward() -> float:
	return -1.0 if mirror else 1.0


## 플레이어(아이) 손 공통 표시 사각형(노드 원점 중심). 기본·부상·골무 변형이 이 사각형을 공유한다.
static func display_rect() -> Rect2:
	return Rect2(-DISPLAY_SIZE * 0.5, DISPLAY_SIZE)


## 엄마(어른) 손 표시 사각형. display_rect와 같은 중심·같은 4:3 비율, MOM_HAND_SCALE배 크기.
static func mom_display_rect() -> Rect2:
	var size: Vector2 = DISPLAY_SIZE * MOM_HAND_SCALE
	return Rect2(-size * 0.5, size)


## 손 1장을 주어진 오프셋/스케일로 그린다. 접촉 그림자(같은 텍스처의 어두운 실루엣을 몇 px
## 아래에)를 먼저 그리고 그 위에 손을 주어진 표시 사각형(rect)으로 그린다. 그림자와 손이 같은
## 트랜스폼(오프셋·스케일·mirror)을 공유하므로 누름·조향·엄마 교대 이동을 함께 따른다.
## 확대는 노드 원점이 아니라 rect 기준 PRESS_PIVOT 지점을 고정점으로 삼는다(s=1이면 이동 없음).
## tex가 null이면 절차적 손 도형으로 폴백한다(씬에서 texture가 항상 배선돼 실사용에선
## 스프라이트 경로).
func _draw_hand_tex(tex: Texture2D, offset: Vector2, flip: float, s: float, rect: Rect2) -> void:
	# 고정점 p(로컬, mirror 전)가 화면에서 제자리에 남도록 원점을 p*(1-s)만큼 옮긴다.
	var pivot: Vector2 = rect.get_center() + rect.size * PRESS_PIVOT
	var origin: Vector2 = offset + Vector2(pivot.x * flip, pivot.y) * (1.0 - s)
	draw_set_transform(origin, 0.0, Vector2(flip * s, s))
	if tex != null:
		# 트랜스폼의 x 스케일(flip)이 로컬 x를 뒤집으므로 flip을 곱해 화면 기준 방향을 유지한다.
		var far_off: Vector2 = Vector2(CONTACT_SHADOW_FAR.x * flip, CONTACT_SHADOW_FAR.y)
		var near_off: Vector2 = Vector2(CONTACT_SHADOW_NEAR.x * flip, CONTACT_SHADOW_NEAR.y)
		var far: Rect2 = Rect2(rect.position + far_off, rect.size)
		var near: Rect2 = Rect2(rect.position + near_off, rect.size)
		draw_texture_rect(tex, far, false, CONTACT_SHADOW_FAR_COLOR)
		draw_texture_rect(tex, near, false, CONTACT_SHADOW_NEAR_COLOR)
		draw_texture_rect(tex, rect, false)
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
