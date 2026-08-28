class_name ItemField
extends Node2D
## 필드 아이템 접지 그림자 + 빌보드 브릿지 (presentation.md §2.5 / v1.1.0). SubViewport 안 월드 공간.
##
## v1.1.0 빌보드 개편: 아이템 아이콘 자체는 세워진 스프라이트로 ItemBillboardLayer(스크린 공간,
## SubViewport 밖)가 그리고, ItemField는 (1) 시뮬 계약과 (2) '접지 그림자'만 담당한다. 그림자는
## World 계층에 있어 Mode 7로 워프되어 바닥에 붙는 게 정답이다(빌보드 밑동이 그 위에 얹힌다).
## DriftSkid·StitchTrail과 형제라 같은 워프 전 계층에 있고, 원근·미니맵·줌아웃이 자동 반영된다.
##
## 물리 루프와 무결합: 시뮬(RaceDirector)이 계약 API만 null-safe 호출한다.
##   setup(track)       — 트랙 로드/재시작 시 아이템 배치를 (재)구성(그림자 + 빌보드 목록 전달).
##   on_collected(index) — 픽업 판정 상승 시 그림자 페이드 시작 + 빌보드에 팝 통지.
## 월드 좌표는 시뮬의 픽업 판정과 동일 공식(중심선 점 + lat*접선법선)으로 유도한다.
## 표현 전용 상태(bob 위상·팝 진행)만 가지며 시뮬 값·결정론에는 절대 영향을 주지 않는다.

## type 문자열 → 빌보드 스프라이트(시뮬 계약: "thimble"=골무, "autopilot"=엄마찬스).
const TEX_THIMBLE := preload("res://assets/gfx/item_thimble.png")
const TEX_AUTOPILOT := preload("res://assets/gfx/item_moms_chance.png")

## 접지 그림자 월드 반경(px). Mode 7가 추가로 원근 압축하므로 바닥에 붙는 타원이 된다.
## RX(가로)>RY(세로)로 살짝 눌러 지면 밀착을 강조한다.
const SHADOW_RX: float = 22.0
const SHADOW_RY: float = 12.0
const SHADOW_ALPHA: float = 0.26
## bob 위상 연동: 아이템이 떠오를수록(bob01↑) 그림자가 살짝 작아지고 옅어진다.
const SHADOW_BOB_SHRINK: float = 0.16
const SHADOW_BOB_FADE: float = 0.28
## 획득 팝 지속(초). 이 시간에 걸쳐 그림자를 페이드 아웃한다(빌보드 팝과 동일 지속).
const POP_DUR: float = 0.35
const SHADOW_SEGMENTS: int = 16

# 각 원소 {"pos":Vector2, "tex":Texture2D, "collected":bool, "pop":float, "phase":float}.
var _items: Array = []
var _time: float = 0.0


## 시뮬(RaceDirector._init_player)이 트랙 로드·재시작 때 호출(null-safe 계약). track.items를
## 시뮬과 동일 공식(중심선 점 + lat*접선법선)으로 월드 좌표화해 그림자 상태를 재구성하고,
## 같은 목록을 빌보드 레이어에 전달한다(스프라이트 렌더는 빌보드가 담당).
func setup(track: TrackData) -> void:
	_items.clear()
	if track == null:
		_push_billboards()
		queue_redraw()
		return
	for i in track.items.size():
		var item: Dictionary = track.items[i]
		var item_s: float = float(item.get("s", 0.0))
		var lat: float = float(item.get("lat", 0.0))
		var world: Vector2 = (
			track.point_at_s(item_s) + track.tangent_at_s(item_s).orthogonal() * lat
		)
		var tex: Texture2D = _tex_for(str(item.get("type", "")))
		(
			_items
			. append(
				{
					"pos": world,
					"tex": tex,
					"collected": false,
					"pop": 0.0,
					# 위상을 아크길이에서 유도해 아이템마다 bob이 어긋나게(표현 다양성, 결정론 무관).
					# 빌보드도 같은 위상·BOB_RATE를 써 그림자와 스프라이트 bob이 동기된다.
					"phase": item_s * 0.017,
				}
			)
		)
	_push_billboards()
	queue_redraw()


## 시뮬(RaceDirector._check_item_pickups)이 픽업 상승 시 정확히 1회 호출. 그림자 페이드를
## 시작하고 빌보드에 팝(스케일업+페이드)을 통지한다(null-safe). 범위 밖 인덱스는 무시.
func on_collected(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	var it: Dictionary = _items[index]
	if bool(it["collected"]):
		return
	it["collected"] = true
	it["pop"] = 0.0
	var bb: Node = _billboard()
	if bb != null and bb.has_method("on_collected"):
		bb.on_collected(index)
	queue_redraw()


## 아이템 상태를 모두 비운다(그림자 + 빌보드). 재시작은 씬 재로드(setup 재호출)로 자동
## 초기화되지만, 재로드 없이 비워야 하는 경로를 위해 명시 API로도 노출한다(DriftSkid.clear 관용구).
func clear() -> void:
	_items.clear()
	var bb: Node = _billboard()
	if bb != null and bb.has_method("clear"):
		bb.clear()
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	var need_redraw: bool = false
	for it in _items:
		if bool(it["collected"]):
			if float(it["pop"]) < 1.0:
				it["pop"] = minf(float(it["pop"]) + delta / POP_DUR, 1.0)
				need_redraw = true
		else:
			# 미획득은 bob 위상 연동 그림자 크기 변화를 위해 매 프레임 다시 그린다(표현 전용).
			need_redraw = true
	if need_redraw:
		queue_redraw()


func _draw() -> void:
	for it in _items:
		var pop: float = float(it["pop"])
		var collected: bool = bool(it["collected"])
		if collected and pop >= 1.0:
			continue  # 팝 완료 → 숨김.
		# 빌보드와 동일 위상·BOB_RATE로 bob을 계산해 그림자↔스프라이트가 어긋나지 않게 한다.
		var bob01: float = 0.5 + 0.5 * sin(_time * ItemBillboardLayer.BOB_RATE + float(it["phase"]))
		var scale: float = 1.0 - SHADOW_BOB_SHRINK * bob01
		var alpha: float = SHADOW_ALPHA * (1.0 - SHADOW_BOB_FADE * bob01)
		if collected:
			alpha *= 1.0 - pop  # 팝과 함께 그림자도 페이드 아웃.
		_draw_shadow(Vector2(it["pos"]), SHADOW_RX * scale, SHADOW_RY * scale, alpha)


## 월드 공간에 눌린 타원 그림자를 그린다(Mode 7가 추가 원근 압축 → 바닥 밀착). alpha가
## 무시할 만큼 작으면 생략한다.
func _draw_shadow(center: Vector2, rx: float, ry: float, alpha: float) -> void:
	if alpha <= 0.004:
		return
	var pts: PackedVector2Array = PackedVector2Array()
	for i in range(SHADOW_SEGMENTS):
		var a: float = TAU * float(i) / float(SHADOW_SEGMENTS)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, alpha))


## 빌보드 레이어를 그룹 조회로 찾는다(경로 대신 그룹 — 없으면 null, 전부 null-safe).
func _billboard() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(ItemBillboardLayer.GROUP)


## 현재 아이템 목록(월드 좌표·텍스처·bob 위상)을 빌보드 레이어에 밀어넣는다(null-safe).
func _push_billboards() -> void:
	var bb: Node = _billboard()
	if bb == null or not bb.has_method("set_items"):
		return
	var payload: Array = []
	for it in _items:
		payload.append({"pos": it["pos"], "tex": it["tex"], "phase": it["phase"]})
	bb.set_items(payload)


func _tex_for(type: String) -> Texture2D:
	match type:
		"thimble":
			return TEX_THIMBLE
		"autopilot":
			return TEX_AUTOPILOT
		_:
			return null
