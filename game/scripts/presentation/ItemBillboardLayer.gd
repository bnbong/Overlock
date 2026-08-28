class_name ItemBillboardLayer
extends Control
## 필드 아이템 빌보드 레이어 (presentation.md §2.5 / v1.1.0). SubViewport '밖' 스크린 공간.
##
## 미획득 아이템을 진행 방향(카메라)을 바라보는 '세워진 스프라이트'로 그린다. 바닥 평면에
## 납작하게 워프되던 구(舊) 방식 대신, 공중에 살짝 떠서 둥실거리고(bob) 거리(depth)에
## 반비례해 작아지는 빌보드다. 접지 그림자는 ItemField(World 계층)가 워프해 바닥에 붙여
## 그리므로, 빌보드 밑동이 그 그림자 바로 위에 정확히 얹힌다(같은 투영에서 유도).
##
## 투영 정합(단일 소스): fabric_mode7.gdshader의 화면→월드 샘플 수식
##   dy = uv.y-horizon;  depth = depth_scale/dy;  lateral = (uv.x-0.5)*depth*spread;
##   forward = depth-cam_back;  world_off = fwd*forward + rgt*lateral;  world_off = P-player
## 을 '역함수'로 풀어 월드 좌표 P → 화면 좌표를 유도한다(d = P-player):
##   forward = d·fwd;  lateral = d·rgt;  depth = forward + cam_back(>0);
##   uv.y = horizon + depth_scale/depth;  uv.x = 0.5 + lateral/(depth*spread).
## 상수(HORIZON/DEPTH_SCALE/CAM_BACK/SPREAD)는 셰이더 uniform과 동일하게 반드시
## PresentationController(단일 소스)에서 프레임마다 읽어 어긋남을 막는다(§9 함정 5).
##
## 시뮬 무결합: 플레이어 position/heading을 렌더 프레임에 '읽기만' 하고(결정론 불변),
## 아이템 목록·획득 통지는 ItemField가 계약(set_items/on_collected)으로 전달한다(null-safe).

## ItemField가 그룹 조회로 이 레이어를 찾는다(경로 대신 그룹 — 씬 재배치에 견고).
const GROUP: String = "item_billboard"

## depth=CAM_BACK(플레이어 접지 행)에서의 텍스처 스케일. 스프라이트는 ∝ 1/depth로 축소된다.
## 256px 아트 기준 근경(픽업 직전 depth≈170)에서 ~100px, 원경(depth≈440)에서 ~37px.
const REF_SCALE: float = 0.46
## 부양: 접지점에서 스프라이트 높이의 이 비율만큼 위로 띄운다(공중에 뜬 느낌).
const FLOAT_FRAC: float = 0.35
## 둥실 bob: 진폭(스프라이트 높이 비율)과 각속도(rad/s). 표현 전용 time 기반이라 결정론 무관.
const BOB_FRAC: float = 0.09
const BOB_RATE: float = 2.4
## 획득 팝: 지속(초)·최대 스케일 배율(ItemField 그림자 페이드와 동일 지속으로 맞춘다).
const POP_DUR: float = 0.35
const POP_SCALE: float = 1.9
## 투영 최소 depth(px). 이하이면 카메라 뒤/특이점이라 숨긴다.
const MIN_DEPTH: float = 1.0

# 각 원소 {"pos":Vector2(월드), "tex":Texture2D, "phase":float, "collected":bool, "pop":float}.
var _items: Array = []
var _time: float = 0.0

@onready var _player: PlayerController = get_node_or_null("../../SimHost/FabricSource/World/Player")
# 완주 줌아웃 오버레이. 가시성만 읽어(다른 소유 파일이라 변경 없음) 그 동안 빌보드를 숨긴다.
@onready var _finish_view: CanvasItem = get_node_or_null("../../FinishViewLayer/FinishView")


func _ready() -> void:
	add_to_group(GROUP)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## ItemField.setup가 트랙 로드/재시작 때 호출(null-safe 계약). 월드 좌표·텍스처·bob 위상을
## 넘겨받아 표현 상태를 (재)구성한다. 각 원소는 {"pos":Vector2, "tex":Texture2D, "phase":float}.
func set_items(items: Array) -> void:
	_items.clear()
	for src in items:
		(
			_items
			. append(
				{
					"pos": Vector2(src["pos"]),
					"tex": src["tex"],
					"phase": float(src.get("phase", 0.0)),
					"collected": false,
					"pop": 0.0,
				}
			)
		)
	queue_redraw()


## ItemField.on_collected가 픽업 상승 시 정확히 1회 전달. 해당 아이템에 스케일업+페이드 팝을
## 시작한다(_process가 pop을 진행해 완료되면 숨김). 범위 밖 인덱스는 무시한다.
func on_collected(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	var it: Dictionary = _items[index]
	if bool(it["collected"]):
		return
	it["collected"] = true
	it["pop"] = 0.0
	queue_redraw()


## 아이템 상태를 모두 비운다(ItemField.clear 경유). 재시작은 씬 재로드로 자동 초기화된다.
func clear() -> void:
	_items.clear()
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	# 완주 줌아웃 중에는 빌보드를 숨긴다(FinishView가 화면을 덮으므로 잔상만 방지).
	if _finish_view != null and _finish_view.visible:
		if visible:
			visible = false
		return
	if not visible:
		visible = true
		queue_redraw()
	var need_redraw: bool = false
	for it in _items:
		if bool(it["collected"]):
			if float(it["pop"]) < 1.0:
				it["pop"] = minf(float(it["pop"]) + delta / POP_DUR, 1.0)
				need_redraw = true
		else:
			# 미획득은 bob·플레이어 이동을 반영하려 매 프레임 다시 그린다(표현 전용).
			need_redraw = true
	if need_redraw:
		queue_redraw()


func _draw() -> void:
	if _player == null or _items.is_empty():
		return
	var screen: Vector2 = get_viewport_rect().size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return
	# 투영 상수를 셰이더와 동일 소스(PresentationController)에서 읽는다(프레임마다 정합).
	var horizon: float = PresentationController.HORIZON
	var depth_scale: float = PresentationController.DEPTH_SCALE
	var cam_back: float = PresentationController.CAM_BACK
	var spread: float = PresentationController.SPREAD
	var ph: float = _player.heading
	var ppos: Vector2 = _player.position
	var fwd: Vector2 = Vector2(cos(ph), sin(ph))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)  # 셰이더 rgt = vec2(-fwd.y, fwd.x)와 동일
	# 원경→근경(먼 것 먼저) 페인터 정렬로 근경 아이템이 원경 위에 겹치게 그린다.
	var draws: Array = []
	for it in _items:
		var pop: float = float(it["pop"])
		var collected: bool = bool(it["collected"])
		if collected and pop >= 1.0:
			continue  # 팝 완료 → 숨김.
		var tex: Texture2D = it["tex"]
		if tex == null:
			continue
		var d: Vector2 = Vector2(it["pos"]) - ppos
		var forward: float = d.dot(fwd)
		var lateral: float = d.dot(rgt)
		var depth: float = forward + cam_back
		# 미획득은 앞(forward>0)에 있을 때만 그린다 — 뒤로 지나친 아이템이 카메라와 플레이어
		# 사이에서 풍선처럼 커지는 것을 막는다(구 평면 워프의 '앞만 보임' 감각 유지).
		if not collected and forward <= 0.0:
			continue
		# 획득 팝은 뒤로 지나쳐도 플레이어 접지(needle 행) 근처에서 재생되도록 depth를 하한 클램프.
		if collected:
			depth = maxf(depth, cam_back)
		if depth <= MIN_DEPTH:
			continue  # 카메라 뒤/특이점 → 숨김.
		# 접지(그림자) 화면 좌표 = 셰이더 역함수. uv.y는 항상 horizon 아래(수평선 위로 안 뜸).
		var gx: float = (0.5 + lateral / (depth * spread)) * screen.x
		var gy: float = (horizon + depth_scale / depth) * screen.y
		# 렌더 스케일(멀면 작게, ∝ 1/depth). depth는 페인터 정렬 키로도 쓴다.
		var scl: float = REF_SCALE * cam_back / depth
		var bw: float = float(tex.get_width()) * scl
		var bh: float = float(tex.get_height()) * scl
		# 기본 부양 + 둥실 bob(스프라이트 높이 비례). 접지점에서 위로 띄운다.
		var bob01: float = 0.5 + 0.5 * sin(_time * BOB_RATE + float(it["phase"]))
		var bottom_y: float = gy - (FLOAT_FRAC * bh + BOB_FRAC * bh * bob01)
		# 획득 팝: 중심 기준 스케일업 + 페이드 아웃.
		var pop_scale: float = lerpf(1.0, POP_SCALE, pop) if collected else 1.0
		var alpha: float = (1.0 - pop) if collected else 1.0
		var w: float = bw * pop_scale
		var h: float = bh * pop_scale
		var cy: float = bottom_y - bh * 0.5  # 안정된(팝 전) 스프라이트 중심 — 팝은 중심 기준 확대.
		var rect: Rect2 = Rect2(gx - w * 0.5, cy - h * 0.5, w, h)
		# 화면 밖(사각형이 화면과 겹치지 않음) → 숨김.
		if (
			rect.position.x > screen.x
			or rect.end.x < 0.0
			or rect.position.y > screen.y
			or rect.end.y < 0.0
		):
			continue
		draws.append({"tex": tex, "rect": rect, "alpha": alpha, "depth": depth})
	draws.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] > b["depth"])
	for e in draws:
		draw_texture_rect(e["tex"], e["rect"], false, Color(1.0, 1.0, 1.0, float(e["alpha"])))
