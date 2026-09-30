class_name EditorItemTool
extends RefCounted
## 트랙 에디터의 아이템 도구 (track-editor-ux 4단계). 골무·엄마 찬스를 경로에 배치·선택·이동·삭제하고
## 종류를 바꾼다. 문서와 undo는 TrackEditor가 소유하고 이 도구는 그 API(_push_undo·_refresh·_set_status)
## 만 부른다.
##
## - 배치: 종류를 고르고 경로 가까이를 누르면 최근접 선분 투영의 호길이 s에 lat=0으로 놓는다.
##   놓은 아이템은 선택하지 않는다(선택은 마커를 눌러서만). 종류 버튼은 다음에 놓을 종류를 바꾸고,
##   선택한 아이템이 있으면 그 아이템의 종류도 바꾼다.
## - 선택·이동: 마커를 누르면 선택하고, 드래그하면 직전 s 근처 구간에서만 다시 투영해 경로를 따라
##   옮긴다(교차·근접 구간에서 다른 갈래로 튀지 않는다). lat은 유지한다. 뗄 때 undo 한 단위를 남긴다.
## - 제약: 최대 128개, 0 ≤ s ≤ 길이 − 0.5, |lat| ≤ fail(허브 게시 제약). 출발·도착 근처는 경고만 한다.
## - 검토 필요 아이템은 선택해 옮기면(또는 "이 위치로 확정") 개별로 해결된다.

const PICK_PX: float = 16.0  # 마커 선택 반경(화면)
const PICK_MIN: float = 10.0  # 월드 최소
const PLACE_PX: float = 28.0  # 경로에서 이 안을 눌러야 배치(화면)
const PLACE_MIN: float = 40.0
const DRAG_WINDOW_PX: float = 90.0  # 드래그 재투영 창(화면 기준, 직전 s ± 창)
const DRAG_WINDOW_MIN: float = 120.0
const END_WARN: float = 150.0  # 출발·도착에서 이보다 가까우면 경고(규칙 아님)

var place_type: String = "thimble"

var _ed: Control
var _press_snapshot: Dictionary = {}
var _dragging: bool = false
var _moved: bool = false


func _init(editor: Control) -> void:
	_ed = editor


## 아이템 막대(ItemBar) 버튼과 캔버스 아이템 신호를 연결한다.
func bind_ui() -> void:
	var cv: DrawCanvas = _ed._canvas
	cv.item_press.connect(press)
	cv.item_drag.connect(drag)
	cv.item_release.connect(release)
	var bar: Node = _ed.get_node("ItemBar")
	(bar.get_node("ThimbleType") as Button).icon = DrawCanvas.ICON_THIMBLE
	(bar.get_node("AutopilotType") as Button).icon = DrawCanvas.ICON_AUTOPILOT
	(bar.get_node("ThimbleType") as Button).pressed.connect(set_type.bind("thimble"))
	(bar.get_node("AutopilotType") as Button).pressed.connect(set_type.bind("autopilot"))
	(bar.get_node("ItemDelete") as Button).pressed.connect(delete_selected)
	(bar.get_node("ItemConfirm") as Button).pressed.connect(confirm_selected)


## 아이템 막대 갱신: 아이템 도구일 때만 보인다. 종류 버튼·선택 설명·삭제·검토 확정.
func refresh_bar() -> void:
	var bar: Control = _ed.get_node("ItemBar")
	var sel: int = selected()
	bar.visible = _ed._canvas.mode == DrawCanvas.Mode.ITEM
	var t: String = place_type if sel < 0 else str(_items()[sel]["type"])
	(bar.get_node("ThimbleType") as Button).set_pressed_no_signal(t == "thimble")
	(bar.get_node("AutopilotType") as Button).set_pressed_no_signal(t == "autopilot")
	(bar.get_node("ItemDelete") as Button).disabled = sel < 0
	(bar.get_node("ItemConfirm") as Button).visible = (
		sel >= 0 and EditorDoc.needs_review(_items()[sel])
	)
	var info: Label = bar.get_node("ItemInfo")
	if sel >= 0:
		info.text = describe(sel)
	else:
		info.text = "경로 가까이를 눌러 %s 놓기 (%d / %d개)" % [
			str(EditorDoc.ITEM_NAMES[place_type]), _items().size(), EditorDoc.MAX_ITEMS
		]


func selected() -> int:
	var i: int = int(_ed._selected_item)
	return i if i >= 0 and i < _items().size() else -1


func press(world: Vector2) -> void:
	_dragging = false
	_moved = false
	var hit: int = pick(world)
	if hit >= 0 and not EditorDoc.has_gap(_ed._doc):
		_ed._selected_item = hit
		_press_snapshot = EditorDoc.copy(_ed._doc)
		_dragging = true
		_ed._refresh()
		_ed._set_status(describe(hit), _ed.NEUTRAL_COLOR)
		return
	var path: PackedVector2Array = _ed._doc["path"]
	if path.size() < 2:
		_ed._set_status("아이템을 놓으려면 먼저 트랙을 그리세요.", _ed.WARN_COLOR)
		return
	if _ed._erase_tool.blocked("아이템을 놓을 수 없습니다"):
		return  # 틈이 있는 동안은 틈 선분 위에 놓이지 않게 배치를 막는다
	var pr: Dictionary = EditorDoc.project_on_path(path, world)
	if float(pr["dist"]) > _ed._canvas.world_radius(PLACE_PX, PLACE_MIN):
		_ed._selected_item = -1
		_ed._refresh()
		_ed._set_status("아이템은 경로(보라 선) 가까이를 눌러 놓습니다.", _ed.WARN_COLOR)
		return
	place(float(pr["s"]))


## 호길이 s에 현재 종류를 lat=0으로 배치한다(undo 한 단위).
func place(s: float) -> bool:
	if _items().size() >= EditorDoc.MAX_ITEMS:
		_ed._set_status("아이템은 최대 %d개까지 놓을 수 있습니다." % EditorDoc.MAX_ITEMS, _ed.FAIL_COLOR)
		return false
	var length: float = EditorDoc.path_length(_ed._doc["path"])
	_ed._push_undo("item_add")
	_items().append(
		{"s": clampf(s, 0.0, EditorDoc.item_s_max(length)), "type": place_type, "lat": 0.0}
	)
	# 놓은 뒤에는 선택하지 않는다. 종류 버튼이 방금 놓은 아이템을 바꾸지 않고 다음에 놓을 종류만
	# 바꾸게 하기 위해서다. 선택은 마커를 눌러서만 한다.
	_ed._selected_item = -1
	_ed._refresh()
	_announce(_items().size() - 1, "놓았습니다")
	return true


func drag(world: Vector2) -> void:
	var i: int = selected()
	if not _dragging or i < 0:
		return
	var it: Dictionary = _items()[i]
	var path: PackedVector2Array = _ed._doc["path"]
	var window: float = _ed._canvas.world_radius(DRAG_WINDOW_PX, DRAG_WINDOW_MIN)
	var pr: Dictionary = EditorDoc.project_on_path_near(path, world, float(it["s"]), window)
	var s: float = clampf(float(pr["s"]), 0.0, EditorDoc.item_s_max(EditorDoc.path_length(path)))
	if absf(s - float(it["s"])) < 0.01:
		return
	it["s"] = s
	_moved = true
	_ed._refresh()


func release() -> void:
	var i: int = selected()
	if _dragging and _moved and i >= 0:
		var it: Dictionary = _items()[i]
		var was_review: bool = EditorDoc.needs_review(it)
		_resolve_review(it)
		_ed._push_undo("item_move", _press_snapshot)
		_ed._refresh()
		_announce(i, "옮겼습니다" + ("(검토 해결)" if was_review else ""))
	_dragging = false
	_moved = false
	_press_snapshot = {}


func delete_selected() -> bool:
	_ed._cancel_gestures()
	var i: int = selected()
	if i < 0:
		return false
	var name: String = str(EditorDoc.ITEM_NAMES.get(str(_items()[i]["type"]), ""))
	_ed._push_undo("item_delete")
	_items().remove_at(i)
	_ed._selected_item = -1
	_ed._refresh()
	_ed._set_status("%s을(를) 지웠습니다." % name, _ed.NEUTRAL_COLOR)
	return true


## 배치할 종류를 바꾸고, 선택 아이템이 있으면 그 종류도 바꾼다(undo 한 단위).
func set_type(t: String) -> void:
	if not EditorDoc.ITEM_TYPES.has(t):
		return
	_ed._cancel_gestures()
	place_type = t
	var i: int = selected()
	if i >= 0 and str(_items()[i]["type"]) != t:
		_ed._push_undo("item_type")
		_items()[i]["type"] = t
		_ed._refresh()
		_announce(i, "종류를 바꿨습니다")


## 선택 아이템을 지금 위치로 확정(검토 해결, undo 한 단위).
func confirm_selected() -> void:
	_ed._cancel_gestures()
	var i: int = selected()
	if i < 0 or not EditorDoc.needs_review(_items()[i]):
		return
	_ed._push_undo("item_review")
	_resolve_review(_items()[i])
	_ed._refresh()
	_announce(i, "위치를 확정했습니다")


## 화면 기준 반경 안의 가장 가까운 마커(없으면 -1).
func pick(world: Vector2) -> int:
	var path: PackedVector2Array = _ed._doc["path"]
	if path.size() < 2:
		return -1
	var r: float = _ed._canvas.world_radius(PICK_PX, PICK_MIN)
	var best: int = -1
	var best_d: float = INF
	for i in range(_items().size()):
		var d: float = EditorDoc.item_world(path, _items()[i]).distance_to(world)
		if d <= r and d < best_d:
			best = i
			best_d = d
	return best


## 선택 마커 옆 라벨: 시작부터 거리와 전체 대비 %.
func progress_label(i: int) -> String:
	var length: float = maxf(EditorDoc.path_length(_ed._doc["path"]), 1.0)
	var s: float = float(_items()[i]["s"])
	return "시작부터 %d (%d%%)" % [roundi(s), roundi(s / length * 100.0)]


## 속성 패널 설명: 종류 · 시작부터 거리 / 트랙 길이 (%) · 옆 거리 · 검토 사유.
func describe(i: int) -> String:
	var it: Dictionary = _items()[i]
	var length: float = EditorDoc.path_length(_ed._doc["path"])
	var txt: String = "%s · 시작부터 %d / %d (%d%%) · 옆 거리 %s" % [
		str(EditorDoc.ITEM_NAMES.get(str(it["type"]), str(it["type"]))),
		roundi(float(it["s"])),
		roundi(length),
		roundi(float(it["s"]) / maxf(length, 1.0) * 100.0),
		EditorDoc.fmt(it.get("lat", 0.0)),
	]
	var reason: String = EditorDoc.review_text(str(it.get("review", "")))
	if not reason.is_empty():
		txt += " · 검토 필요: " + reason
	return txt


func _announce(i: int, verb: String) -> void:
	var s: float = float(_items()[i]["s"])
	var length: float = EditorDoc.path_length(_ed._doc["path"])
	var warn: bool = s < END_WARN or length - s < END_WARN
	var msg: String = "%s %s — %s" % [
		str(EditorDoc.ITEM_NAMES.get(str(_items()[i]["type"]), "")), verb, progress_label(i)
	]
	if warn:
		msg += "  (출발·도착에 가깝습니다. 놓을 수는 있습니다)"
	_ed._set_status(msg, _ed.WARN_COLOR if warn else _ed.NEUTRAL_COLOR)


## 검토 해결(사용자가 확정·이동했을 때만). 사유와 무관하게 s·lat을 저장 가능한 범위로 맞춘 뒤 푼다.
func _resolve_review(it: Dictionary) -> void:
	EditorDoc.resolve_item(
		it, EditorDoc.path_length(_ed._doc["path"]), float(_ed._doc["width"]["fail"])
	)


## 진행 중인 드래그를 취소한다(문서를 누르기 전 상태로 되돌리고 undo를 쌓지 않는다). undo/redo 직전에
## 불러, 드래그 스냅샷이 history 변경 뒤에 늦게 쌓이지 않게 한다.
func cancel() -> void:
	if _dragging and _moved and not _press_snapshot.is_empty():
		_ed._doc = _press_snapshot
	_dragging = false
	_moved = false
	_press_snapshot = {}


func _items() -> Array:
	return _ed._doc["items"]
