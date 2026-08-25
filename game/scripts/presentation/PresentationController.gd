class_name PresentationController
extends Node
## 프레젠테이션 구동 (presentation.md §2.5). 물리 루프에서 분리해 _process(렌더
## 프레임)에서 플레이어 상태를 읽기만 한다(시뮬 결정론 불변).
##
## 이 노드가 Mode 7 투영 상수의 단일 소스다(presentation.md §9 함정 5). 셰이더
## uniform, 카메라 zoom, 노루발 오버레이 행(v_needle)을 모두 여기서 유도해 어긋남을
## 방지한다. 오디오 훅은 /root/AudioManager를 런타임 조회해 가드한다(미등록 시 무시).

# --- Mode 7 투영 상수 (단일 소스) ---
# HORIZON: 수평선 스크린 행. 참고작 구도(수평선 ~40%, 얼굴 눈·코가 그 위에 온전히)
# 에 맞춰 얼굴 스트립을 넓히려 0.40→0.42로 소폭 내렸다(참고작 대조, 최대 0.44 이내).
# v_needle·노루발 y·셰이더 horizon이 모두 이 상수에서 유도된다(§9 함정 5).
const HORIZON: float = 0.42
const DEPTH_SCALE: float = 28.0
const CAM_BACK: float = 140.0
const SPREAD: float = 0.9
const COVERAGE: float = 600.0

# --- 수평선-원단 이음새 상수 (단일 소스, 셰이더 uniform으로 전달) ---
# HORIZON_FADE: 수평선 근처를 원단 대표색으로 흐리는 대역(원경 앨리어싱 완화).
# EDGE_WIDTH/EDGE_DARKNESS: 수평선 바로 아래에 얇은 테이블 모서리 트림(어두운 라인)을
# 그려 원단이 테이블에 '놓여 있는' 느낌으로 봉합한다(떠 보임 해소, 참고작 구도).
const HORIZON_FADE: float = 0.028
const EDGE_WIDTH: float = 0.022
const EDGE_DARKNESS: float = 0.55

const INJURY_SHAKE: float = 14.0
# 맵 이탈 소프트 리셋 시 소폭 셰이크(부상 셰이크보다 약하게 — 부상과 구별되는 가벼운 피드백).
const OFFFABRIC_SHAKE: float = 8.0
const SHAKE_DECAY: float = 34.0
# 이동 판정 히스테리시스. 물리는 60Hz 고정이지만 _process는 렌더 프레임(90/120Hz)마다
# 도므로, 물리 틱 없는 프레임에선 position 변화가 0이라 순간적으로 "정지"로 오판된다.
# 마지막 이동 시각을 기억해 이 시간 안이면 계속 "주행 중"으로 유지한다(물리 틱 간격보다
# 넉넉히 큰 값이라 60Hz 동작은 불변).
const MOVE_HOLD: float = 0.1

const ToastScene := preload("res://scenes/Toast.tscn")

## cut 누적 단계별 손 텍스처 교체 매핑(표현 전용, §9 함정 13). 배열 원소를 순서대로
## 소비한다: 1번째 cut→오른손, 2번째→왼손, 3번째→오른손(업그레이드), … 홀수=오른손,
## 짝수=왼손. 배열 길이(기본 3)를 넘는 cut은 무시한다(런당 최대 3단). 인스펙터에서
## 원소를 handcut4(약지) 등으로 바꿔치기할 수 있다(Gameplay.tscn 미수정 시 이 기본값 사용).
@export var cut_hand_textures: Array[Texture2D] = [
	preload("res://assets/gfx/handcut1.png"),
	preload("res://assets/gfx/handcut2.png"),
	preload("res://assets/gfx/handcut3.png"),
]

var _mat: ShaderMaterial = null
var _injury_shake: float = 0.0
var _prev_stun_active: bool = false
# 맵 이탈 소프트 리셋 상승엣지 추적(스턴 엣지와 별개). cut 단계는 건드리지 않는다.
var _prev_offfabric: bool = false
# 드리프트 상승엣지 추적(가드형 오디오 훅용, 표현 전용). 셰이크는 리스크 연동이라 별도 없음.
var _prev_drifting: bool = false
var _toast: Toast = null
var _prev_pos: Vector2 = Vector2.ZERO
var _pos_inited: bool = false
var _move_hold_t: float = 0.0
# cut 누적 단계(소비한 cut_hand_textures 개수). 씬 재로드 시 _ready로 0에서 시작.
var _cut_stage: int = 0

@onready var _viewport: SubViewport = get_node_or_null("../SimHost/FabricSource")
@onready var _warp: ColorRect = get_node_or_null("../FabricLayer/FabricWarp")
@onready var _fabric: FabricSurface = get_node_or_null(
	"../SimHost/FabricSource/World/FabricSurface"
)
@onready var _player: PlayerController = get_node_or_null("../SimHost/FabricSource/World/Player")
@onready var _camera: Camera2D = get_node_or_null("../SimHost/FabricSource/World/Player/Camera2D")
@onready var _stitch: StitchTrail = get_node_or_null("../SimHost/FabricSource/World/StitchTrail")
@onready var _skid: DriftSkid = get_node_or_null("../SimHost/FabricSource/World/DriftSkid")
@onready var _needle: NeedleView = get_node_or_null("../ForegroundLayer/NeedleView")
@onready var _left_hand: HandView = get_node_or_null("../ForegroundLayer/LeftHand")
@onready var _right_hand: HandView = get_node_or_null("../ForegroundLayer/RightHand")
@onready var _face: BackgroundFace = get_node_or_null("../BackdropLayer/FaceView")
@onready var _backdrop_layer: CanvasLayer = get_node_or_null("../BackdropLayer")
@onready var _fabric_layer: CanvasLayer = get_node_or_null("../FabricLayer")
@onready var _foreground_layer: CanvasLayer = get_node_or_null("../ForegroundLayer")


static func v_needle() -> float:
	return HORIZON + DEPTH_SCALE / CAM_BACK


func _ready() -> void:
	_setup_projection()
	_setup_fabric()
	_place_needle()
	# 맵 이탈 안내용 토스트(재사용 컴포넌트). CanvasLayer라 이 노드 아래 붙어도 화면 최상단에 뜬다.
	_toast = ToastScene.instantiate()
	add_child(_toast)


## 트랙 JSON의 fabric 필드로 원단 타일 텍스처와 셰이더 대표색을 결정한다(1회).
## 읽기 전용(TrackLoader 캐시 조회) → 물리 루프·시뮬 결정론과 무관.
func _setup_fabric() -> void:
	var fabric_type: String = "cotton"
	var track: TrackData = TrackLoader.load_track(GameState.track_id)
	if track != null and track.fabric != "":
		fabric_type = track.fabric
	var base: Color = FabricSurface.FABRIC_COLOR
	if _fabric != null:
		_fabric.set_fabric(fabric_type)
		base = _fabric.get_base_color()
	if _mat != null:
		# 원경 OOB 폴백·수평선 페이드가 해당 원단색으로 흐려지게 한다.
		_mat.set_shader_parameter("fabric_color", base)


## 셰이더 uniform·카메라 zoom을 투영 상수에서 유도(단일 소스).
func _setup_projection() -> void:
	if _warp != null and _warp.material is ShaderMaterial:
		_mat = _warp.material as ShaderMaterial
		if _viewport != null:
			# ViewportTexture는 씬 직렬화 대신 코드로 연결(presentation.md §9 함정 1).
			_mat.set_shader_parameter("source_tex", _viewport.get_texture())
		_mat.set_shader_parameter("horizon", HORIZON)
		_mat.set_shader_parameter("depth_scale", DEPTH_SCALE)
		_mat.set_shader_parameter("cam_back", CAM_BACK)
		_mat.set_shader_parameter("spread", SPREAD)
		_mat.set_shader_parameter("coverage", COVERAGE)
		# 이음새(수평선 페이드 + 테이블 모서리 트림) 상수도 여기서 유도(단일 소스).
		_mat.set_shader_parameter("horizon_fade", HORIZON_FADE)
		_mat.set_shader_parameter("edge_width", EDGE_WIDTH)
		_mat.set_shader_parameter("edge_darkness", EDGE_DARKNESS)
	# 소스가 coverage 월드 px를 512 텍셀에 담도록 카메라를 축소(zoom<1).
	if _camera != null and _viewport != null:
		var vp_w: float = float(_viewport.size.x)
		var z: float = vp_w / COVERAGE
		_camera.zoom = Vector2(z, z)


## 노루발 오버레이를 v_needle 행에 정렬(셰이더와 동일 상수에서 유도).
func _place_needle() -> void:
	if _needle == null:
		return
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_needle.position = Vector2(screen.x * 0.5, v_needle() * screen.y)


func _process(delta: float) -> void:
	if _player == null:
		return
	var heading: float = _player.heading
	var speed: float = _player.speed
	var pos: Vector2 = _player.position
	var risk: float = _player.risk
	var stun_active: bool = _player.stun_timer > 0.0
	var offfabric_active: bool = _player.offfabric_timer > 0.0
	var speed_index: int = _player.speed_index
	# actual_steer: 노루발이 실제로 따라가는 지연 조향값(-1..1, 음수=좌). 얼굴 고개
	# 꺾기·손 누름 연출의 구동값. 뷰가 프레임 독립적으로 추가 보간한다.
	var steer: float = _player.actual_steer

	# 1) 셰이더 heading uniform 갱신.
	if _mat != null:
		_mat.set_shader_parameter("heading", heading)

	# 2) 주행 판정(position 변화량으로 추론 → 물리 루프 미조회).
	#    렌더 프레임마다 평가되므로, 이동을 감지하면 MOVE_HOLD만큼 "주행 중"을 유지해
	#    고주사율에서 물리 틱 없는 프레임이 틱을 끊는 것을 막는다.
	if not _pos_inited:
		_prev_pos = pos
		_pos_inited = true
	var moved: float = _prev_pos.distance_to(pos)
	_prev_pos = pos
	if moved > 0.5:
		_move_hold_t = MOVE_HOLD
	else:
		_move_hold_t = maxf(_move_hold_t - delta, 0.0)
	var running: bool = _move_hold_t > 0.0

	# 3) 스티치 샘플링(호길이 기반). 드리프트 중이면 원단 융기 스키드 자국도 함께 남긴다
	#    (표현 전용, dir=drift_dir 부호=밀린 방향 / intensity=|drift_dir|=길이·오프셋 스케일).
	if _stitch != null:
		_stitch.push_if_moved(pos)
	if _player.is_drifting and _skid != null:
		_skid.push(pos, _player.drift_dir, absf(_player.drift_dir))

	# 4) 바늘 왕복 = f(speed).
	if _needle != null:
		_needle.set_speed(speed)

	# 5) 손: 속도 진동 + 조향 방향 누름 강조(반대 손은 이완). 드리프트 중이면 그 방향 손을
	#    더 깊이 누른다(set_drift로 조향 프레스 김믹 증폭, 반대 손은 기존 수준 유지).
	if _left_hand != null:
		_left_hand.set_speed(speed)
		_left_hand.set_steer(steer)
		_left_hand.set_drift(_player.is_drifting, _player.drift_dir)
	if _right_hand != null:
		_right_hand.set_speed(speed)
		_right_hand.set_steer(steer)
		_right_hand.set_drift(_player.is_drifting, _player.drift_dir)

	# 6) 얼굴: 표정(부상>고위험>속도 집중) + 조향 고개 꺾기.
	if _face != null:
		_face.set_expression(risk, stun_active, speed_index)
		_face.set_steer(steer)

	# 7) 스크린 셰이크 = f(risk, 부상 상승엣지).
	if stun_active and not _prev_stun_active:
		_injury_shake = INJURY_SHAKE
		_play_injury_audio()
		# 스턴 상승엣지 = cut 1회(정확히 1회). 누적 단계에 맞추어 손 텍스처를 즉시 교체.
		_advance_cut_stage()
	# 7b) 맵 이탈 소프트 리셋 상승엣지(스턴 엣지와 별개). 부상이 아니므로 손 텍스처 단계는
	#     절대 진행하지 않는다(_advance_cut_stage 호출 금지). 소폭 셰이크 + 토스트 + 오프심 SFX 재사용.
	if offfabric_active and not _prev_offfabric:
		_injury_shake = maxf(_injury_shake, OFFFABRIC_SHAKE)
		if _toast != null:
			_toast.push("원단 이탈! 재봉선 복귀")
		_play_offfabric_audio()
	# 7c) 드리프트 상승엣지: 가드형 오디오 훅만(무음 기본, 신규 에셋 없음). 셰이크는 리스크
	#     연동으로 자동이라 여기서 추가하지 않는다(표현 전용, 시뮬 무관).
	if _player.is_drifting and not _prev_drifting:
		_play_drift_audio()
	_update_shake(delta, risk)

	# 8) 오디오: 속도 비례 재봉틀 틱(주행 중만).
	_update_machine_rate(running, speed)

	_prev_stun_active = stun_active
	_prev_offfabric = offfabric_active
	_prev_drifting = _player.is_drifting


func _update_shake(delta: float, risk: float) -> void:
	_injury_shake = move_toward(_injury_shake, 0.0, SHAKE_DECAY * delta)
	var amp: float = maxf(_injury_shake, risk * 1.5)
	var offset: Vector2 = Vector2.ZERO
	if amp > 0.05:
		offset = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	# 배경·원단·전경을 함께 이동해 화면이 균일하게 흔들리게(수평선 이음새 방지).
	if _backdrop_layer != null:
		_backdrop_layer.offset = offset
	if _fabric_layer != null:
		_fabric_layer.offset = offset
	if _foreground_layer != null:
		_foreground_layer.offset = offset


## cut 누적 단계를 한 칸 진행하고 해당 손 텍스처를 교체한다(스턴 상승엣지에서 1회 호출).
## 홀수 단계(1,3,…)=오른손, 짝수 단계(2,4,…)=왼손. 배열 길이를 넘는 cut은 무시한다.
func _advance_cut_stage() -> void:
	if _cut_stage >= cut_hand_textures.size():
		return  # 런당 최대 단계 도달 → 이후 cut은 손을 더 바꾸지 않는다.
	var tex: Texture2D = cut_hand_textures[_cut_stage]
	_cut_stage += 1
	if _cut_stage % 2 == 1:
		if _right_hand != null:
			_right_hand.set_hand_texture(tex)
	else:
		if _left_hand != null:
			_left_hand.set_hand_texture(tex)


## cut 단계·양손 텍스처를 초기 상태로 복원한다. 재시작은 씬 재로드(_ready 재실행)로
## 자동 초기화되지만, 재로드 없이 복원해야 하는 경로를 위해 명시 API로도 노출한다.
func reset_hands() -> void:
	_cut_stage = 0
	_prev_stun_active = false
	if _left_hand != null:
		_left_hand.set_hand_texture(null)
	if _right_hand != null:
		_right_hand.set_hand_texture(null)


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")


func _play_injury_audio() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("play_injury"):
		am.play_injury()


## 맵 이탈 소프트 리셋 피드백. 신규 에셋 없이 기존 오프심 SFX를 재사용한다(on_band_enter는
## 밴드 무관하게 sfx_offseam을 재생 — 표현 전용이라 시뮬 값·판정과 무관).
func _play_offfabric_audio() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("on_band_enter"):
		am.on_band_enter(RunStats.Band.OFF_SEAM)


## 드리프트 발동 피드백(표현 전용). 무음 기본 — AudioManager가 on_drift를 노출하면 그때만
## 재생한다(신규 에셋 없이 가드형 훅만; on_band_enter·play_injury 방식과 동일 관용구).
func _play_drift_audio() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("on_drift"):
		am.on_drift()


func _update_machine_rate(running: bool, speed: float) -> void:
	var am: Node = _audio()
	if am == null or not am.has_method("set_machine_rate"):
		return
	var norm: float = 0.0
	if running and Tuning.max_speed > 0.0:
		norm = clampf(speed / Tuning.max_speed, 0.0, 1.0)
	am.set_machine_rate(norm)
