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
const SHAKE_DECAY: float = 34.0
# 이동 판정 히스테리시스. 물리는 60Hz 고정이지만 _process는 렌더 프레임(90/120Hz)마다
# 도므로, 물리 틱 없는 프레임에선 position 변화가 0이라 순간적으로 "정지"로 오판된다.
# 마지막 이동 시각을 기억해 이 시간 안이면 계속 "주행 중"으로 유지한다(물리 틱 간격보다
# 넉넉히 큰 값이라 60Hz 동작은 불변).
const MOVE_HOLD: float = 0.1

var _mat: ShaderMaterial = null
var _injury_shake: float = 0.0
var _prev_stun_active: bool = false
var _prev_pos: Vector2 = Vector2.ZERO
var _pos_inited: bool = false
var _move_hold_t: float = 0.0

@onready var _viewport: SubViewport = get_node_or_null("../SimHost/FabricSource")
@onready var _warp: ColorRect = get_node_or_null("../FabricLayer/FabricWarp")
@onready var _fabric: FabricSurface = get_node_or_null(
	"../SimHost/FabricSource/World/FabricSurface"
)
@onready var _player: PlayerController = get_node_or_null("../SimHost/FabricSource/World/Player")
@onready var _camera: Camera2D = get_node_or_null("../SimHost/FabricSource/World/Player/Camera2D")
@onready var _stitch: StitchTrail = get_node_or_null("../SimHost/FabricSource/World/StitchTrail")
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

	# 3) 스티치 샘플링(호길이 기반).
	if _stitch != null:
		_stitch.push_if_moved(pos)

	# 4) 바늘 왕복 = f(speed).
	if _needle != null:
		_needle.set_speed(speed)

	# 5) 손: 속도 진동 + 조향 방향 누름 강조(반대 손은 이완).
	if _left_hand != null:
		_left_hand.set_speed(speed)
		_left_hand.set_steer(steer)
	if _right_hand != null:
		_right_hand.set_speed(speed)
		_right_hand.set_steer(steer)

	# 6) 얼굴: 표정(부상>고위험>속도 집중) + 조향 고개 꺾기.
	if _face != null:
		_face.set_expression(risk, stun_active, speed_index)
		_face.set_steer(steer)

	# 7) 스크린 셰이크 = f(risk, 부상 상승엣지).
	if stun_active and not _prev_stun_active:
		_injury_shake = INJURY_SHAKE
		_play_injury_audio()
	_update_shake(delta, risk)

	# 8) 오디오: 속도 비례 재봉틀 틱(주행 중만).
	_update_machine_rate(running, speed)

	_prev_stun_active = stun_active


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


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")


func _play_injury_audio() -> void:
	var am: Node = _audio()
	if am != null and am.has_method("play_injury"):
		am.play_injury()


func _update_machine_rate(running: bool, speed: float) -> void:
	var am: Node = _audio()
	if am == null or not am.has_method("set_machine_rate"):
		return
	var norm: float = 0.0
	if running and Tuning.max_speed > 0.0:
		norm = clampf(speed / Tuning.max_speed, 0.0, 1.0)
	am.set_machine_rate(norm)
