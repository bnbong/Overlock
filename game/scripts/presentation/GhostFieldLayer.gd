class_name GhostFieldLayer
extends Control
## 필드 위 개인 고스트 마커 (v2.3.0, docs/architecture.md §3.3). SubViewport '밖' 스크린 공간.
##
## 고스트의 월드 위치(GhostRun.state_at 결과)를 아이템 빌보드(ItemBillboardLayer)와 같은 Mode 7 역투영으로
## 화면 좌표로 옮겨, 기존 노루발 그림(presser_foot_large.png)을 반투명 보라 실루엣으로 작게 그리고
## 바닥 접지 타원과 "고스트" 라벨을 붙인다. 새 그림은 쓰지 않는다.
##
## 투영(단일 소스 PresentationController 상수, ItemBillboardLayer 머리말과 같은 식): d = P - player,
##   forward = d·fwd, lateral = d·rgt, depth = forward + CAM_BACK,
##   uv.y = HORIZON + DEPTH_SCALE/depth, uv.x = 0.5 + lateral/(depth*SPREAD).
## 크기는 플레이어 노루발 표시 크기(NeedleView.FOOT_RECT, depth=CAM_BACK에서 200px)에 CAM_BACK/depth와
## SCALE을 곱한다. 상대 진행 방향은 화면 회전으로 약하게(TURN_GAIN, ±TURN_MAX) 보인다.
##
## 가림 방지: 플레이어 뒤(forward ≤ 0)면 그리지 않는다(카메라와 노루발 사이에서 커지는 것 방지, 미니맵이
## 대신 보인다). 플레이어와의 월드 거리가 NEAR_HIDE 이하이면 숨기고 NEAR_FULL까지 알파를 올려 노루발·바늘·
## 재봉선을 가리지 않는다. 수평선 근처(HORIZON_CLIP 대역)는 알파를 줄여 원경 앨리어싱 대역에서 사라진다.
## 레이어: ItemLayer(-5) 안에서 아이템 빌보드보다 먼저(아래) 그린다. 손·노루발·바늘(ForegroundLayer)과
## HUD(10)는 항상 고스트 위에 그려진다.
##
## 시간: RaceDirector가 물리 틱마다 미니맵과 같은 상태(주행 경과 시간의 state_at)를 넘긴다. 렌더 FPS와
## 무관하게 같은 물리 시간이면 같은 위치다. 고스트가 먼저 완주하면 결승 위치에 ARRIVE_HOLD_MS 동안 남았다가
## 마지막 ARRIVE_FADE_MS 동안 흐려지며 사라진다. 시뮬레이션 상태는 읽기만 한다(결정론 불변).

const FOOT_TEX: Texture2D = preload("res://assets/gfx/palm_contact/presser_foot_large.png")
## 플레이어 노루발 표시 사각형(NeedleView.FOOT_RECT와 같은 값, 관통점 기준 로컬).
const FOOT_RECT: Rect2 = Rect2(-99.5, -157.1, 200.0, 200.0)
const SCALE: float = 0.8
const TINT: Color = Color(0.80, 0.70, 1.0, 1.0)
const BASE_ALPHA: float = 0.5
const NEAR_HIDE: float = 40.0
const NEAR_FULL: float = 90.0
const HORIZON_CLIP: Vector2 = Vector2(0.012, 0.05)  # 수평선 아래 이 uv 대역에서 알파 0→1
const TURN_GAIN: float = 0.6
const TURN_MAX: float = 0.5
const ARRIVE_HOLD_MS: float = 2000.0
const ARRIVE_FADE_MS: float = 500.0
const SHADOW_COLOR: Color = Color(0.25, 0.18, 0.40, 0.35)
const LABEL_COLOR: Color = Color(0.25, 0.18, 0.40, 1.0)
const MIN_DEPTH: float = 1.0

var _player: PlayerController = null
var _state: Dictionary = {}
@onready var _finish_view: CanvasItem = get_node_or_null("../../FinishViewLayer/FinishView")


func _ready() -> void:
	name = "GhostField"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func setup(player: PlayerController) -> void:
	_player = player


## 고스트 상태(GhostRun.state_at 결과). 빈 dict면 숨긴다(토글 OFF·고스트 없음).
func set_state(state: Dictionary) -> void:
	_state = state
	queue_redraw()


func _process(_delta: float) -> void:
	var hide: bool = _finish_view != null and _finish_view.visible
	if visible == hide:
		visible = not hide
	if visible and not _state.is_empty():
		queue_redraw()


## 현재 마커 배치 {visible, ground(화면 접지점), scale, alpha, angle, depth}. _draw와 회귀 검사가 함께 쓴다.
func marker() -> Dictionary:
	var out: Dictionary = {"visible": false, "ground": Vector2.ZERO, "scale": 0.0, "alpha": 0.0}
	if _player == null or _state.is_empty():
		return out
	var screen: Vector2 = get_viewport_rect().size
	var arrive_alpha: float = 1.0
	if bool(_state.get("arrived", false)):
		var since: float = float(_state.get("since_finish_ms", 0.0))
		if since >= ARRIVE_HOLD_MS:
			return out
		arrive_alpha = clampf((ARRIVE_HOLD_MS - since) / ARRIVE_FADE_MS, 0.0, 1.0)
	var ph: float = _player.heading
	var fwd: Vector2 = Vector2(cos(ph), sin(ph))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	var d: Vector2 = Vector2(_state.get("pos", Vector2.ZERO)) - _player.position
	var forward: float = d.dot(fwd)
	var depth: float = forward + PresentationController.CAM_BACK
	if forward <= 0.0 or depth <= MIN_DEPTH:
		return out
	var uv_y: float = PresentationController.HORIZON + PresentationController.DEPTH_SCALE / depth
	var uv_x: float = 0.5 + d.dot(rgt) / (depth * PresentationController.SPREAD)
	var dh: float = uv_y - PresentationController.HORIZON
	var alpha: float = BASE_ALPHA * arrive_alpha
	alpha *= smoothstep(NEAR_HIDE, NEAR_FULL, d.length())
	alpha *= smoothstep(HORIZON_CLIP.x, HORIZON_CLIP.y, dh)
	var scl: float = SCALE * PresentationController.CAM_BACK / depth
	var ground: Vector2 = Vector2(uv_x * screen.x, uv_y * screen.y)
	var rel: float = angle_difference(ph, float(_state.get("heading", ph)))
	var bounds: Rect2 = Rect2(ground + FOOT_RECT.position * scl, FOOT_RECT.size * scl)
	var on_screen: bool = bounds.intersects(Rect2(Vector2.ZERO, screen))
	out["visible"] = alpha > 0.01 and on_screen
	out["ground"] = ground
	out["scale"] = scl
	out["alpha"] = alpha
	out["angle"] = clampf(rel * TURN_GAIN, -TURN_MAX, TURN_MAX)
	out["depth"] = depth
	return out


func _draw() -> void:
	var m: Dictionary = marker()
	if not bool(m["visible"]):
		return
	var g: Vector2 = m["ground"]
	var scl: float = m["scale"]
	var a: float = m["alpha"]
	# 바닥 접지 타원(납작한 원).
	draw_set_transform(g, 0.0, Vector2(1.0, 0.32))
	draw_circle(Vector2.ZERO, 70.0 * scl, Color(SHADOW_COLOR, SHADOW_COLOR.a * a / BASE_ALPHA))
	# 반투명 노루발 실루엣(관통점 = 접지점).
	draw_set_transform(g, float(m["angle"]), Vector2.ONE * scl)
	draw_texture_rect(FOOT_TEX, FOOT_RECT, false, Color(TINT, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 라벨(모양과 함께 고스트임을 글자로 알린다).
	var font: Font = get_theme_default_font()
	var fs: int = clampi(int(round(36.0 * scl)), 13, 20)
	var text: String = "고스트"
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var top: float = g.y + FOOT_RECT.position.y * scl - 4.0
	var col: Color = Color(LABEL_COLOR, minf(1.0, a * 1.8))
	draw_string(font, Vector2(g.x - w * 0.5, top), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
