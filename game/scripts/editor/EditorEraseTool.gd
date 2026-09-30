class_name EditorEraseTool
extends RefCounted
## 구간 지우기 도구(v2.2.1, TrackEditor.gd 분리). 경로 위를 브러시로 문지르면 문지른 구간만 지운다.
## 문서와 undo는 TrackEditor가 소유하고 이 도구는 그 API(_push_undo·_after_edit·_set_status)만 부른다.
##
## - 드래그하는 동안에는 문서를 바꾸지 않는다. 브러시(화면 기준 반경, world_radius 규칙)에 닿은 점을
##   모아 지워질 구간을 빨간색으로 미리 보여 주고, 뗄 때 한 번에 적용한다(누름~뗌 = undo 한 단위).
##   포커스 상실·그리기 영역 밖에서 뗌·뗌 누락·도구 전환·undo는 취소이며 문서를 바꾸지 않는다.
## - 지운 뒤 남는 조각(2점 이상)이 하나면 끝 자르기와 같다. 시작 쪽을 지우면 시작점이 옮겨진다.
##   조각이 둘이면 그 사이가 "틈"(EditorDoc gap)이다. 틈은 하나만 허용하며, 셋 이상 남는 지우기는
##   적용하지 않고 안내한다.
## - 틈: 그리기 도구로 한쪽 끝점 근처에서 시작해 다른 쪽 끝점 근처에서 끝나는 스트로크를 그리면 그 사이를
##   새 스트로크로 채워 한 경로로 잇는다(어느 쪽에서 그리든 경로 진행 방향으로 맞춘다). 한쪽에만 닿으면
##   닿은 쪽에서 이어진 만큼만 늘고 틈은 남는다. "직선으로 잇기"와 "뒤쪽 버리기"(= 틈 앞 끝에서 끝 자르기)도
##   있다. 틈이 있는 동안 검증·저장·테스트·루프 닫기·자동 수정·길이 조절·아이템 배치를 막는다.
## - 아이템: 지워진 구간의 아이템은 같은 undo 단위로 제거하고 개수를 알린다. 틈 뒤 조각의 아이템은
##   조각 좌표가 그대로이므로 호길이 차이만큼 s를 옮겨 월드 위치를 유지한다. 옮긴 뒤 월드 위치가 재투영
##   검토 기준(EditorDoc.REVIEW_MOVE_LIMIT)보다 어긋나면(조각 경계에 걸친 lat≠0 아이템) 검토 필요로 표시한다.
## - 닫힌 루프에서 지우면 루프를 열고(closed=false) 같은 규칙을 적용한다.

const ERASE_PX: float = 18.0  # 브러시 반경(화면 px). 끝부분 자르기와 같은 크기
const ERASE_RADIUS: float = 22.0  # 브러시 반경 월드 최소
const GAP_HINT: String = (
	"경로에 틈이 있습니다. 그리기 도구로 빨간 끝점 한쪽에서 다른 쪽까지 이어 그리거나"
	+ " '직선으로 잇기'·'뒤쪽 버리기'를 누르세요."
)
const EPS: float = 0.0005

var _ed: Control
var _active: bool = false
var _touched: Dictionary = {}  # 브러시에 닿은 점 index -> true
var _last_world: Vector2 = Vector2.ZERO
var _path_key: int = 0  # 누를 때 경로의 hash. 드래그 중 경로가 바뀌면 모은 index가 무효라 지우기를 버린다


func _init(editor: Control) -> void:
	_ed = editor


func bind() -> void:
	var cv: DrawCanvas = _ed._canvas
	cv.erase_begin.connect(begin)
	cv.erase_dragged.connect(dragged)
	cv.erase_end.connect(end)
	cv.erase_cancel.connect(cancel)
	_ed._mode_erase.pressed.connect(_ed._set_mode.bind(DrawCanvas.Mode.ERASE))
	var row: Node = _ed.get_node("GapRow")
	(row.get_node("GapJoinButton") as Button).pressed.connect(join_straight)
	(row.get_node("GapDropButton") as Button).pressed.connect(drop_tail)


func brush_radius() -> float:
	return _ed._canvas.world_radius(ERASE_PX, ERASE_RADIUS)


func is_active() -> bool:
	return _active


## 도구가 바뀌었다(TrackEditor._set_mode). 지우기 도구를 고르면 사용법을 알린다.
func on_mode(m: int) -> void:
	if m == DrawCanvas.Mode.ERASE and _ed._doc.has("path"):
		_ed._set_status(
			"구간 지우기: 경로 위를 문지르면 문지른 구간만 지웁니다(빨간색 미리보기, 뗄 때 적용)."
			+ " 끝에 닿으면 그 끝을 잘라 냅니다.",
			_ed.NEUTRAL_COLOR
		)


## 틈 안내 줄(GapRow) 갱신.
func refresh_row() -> void:
	(_ed.get_node("GapRow") as Control).visible = EditorDoc.has_gap(_ed._doc)


## 틈이 있으면 사유를 상태줄에 보이고 true(호출한 동작을 막는다). what은 "저장할 수 없습니다" 같은 서술.
func blocked(what: String) -> bool:
	if not EditorDoc.has_gap(_ed._doc):
		return false
	_ed._set_status("경로에 틈이 있어 %s. 빨간 끝점 두 곳을 잇거나 '뒤쪽 버리기'를 누르세요." % what, _ed.FAIL_COLOR)
	return true


# --- 드래그(미리보기) ---


func begin(world: Vector2) -> void:
	_active = true
	_touched = {}
	_path_key = hash(_ed._doc["path"])
	_last_world = world
	_touch_at(world)
	_update_preview()


## continuous=false면 직전 위치와 잇지 않는다(그리기 영역 밖에 나갔다가 들어온 경우).
func dragged(world: Vector2, continuous: bool = true) -> void:
	if not _active or _stale():
		return
	var r: float = brush_radius()
	var from: Vector2 = _last_world if continuous else world
	var n: int = maxi(1, ceili(from.distance_to(world) / (r * 0.5)))
	for k in range(1, n + 1):
		_touch_at(from.lerp(world, float(k) / float(n)))
	_last_world = world
	_update_preview()


func end() -> void:
	if not _active or _stale():
		return
	var p: Dictionary = plan(_touched.keys())
	_clear()
	apply(p)


## 드래그 중 경로가 바뀌었으면(취소되지 않은 다른 편집) 진행 중 지우기를 버리고 true.
func _stale() -> bool:
	if hash(_ed._doc["path"]) == _path_key:
		return false
	_clear()
	return true


## 진행 중인 지우기를 버린다(문서는 드래그 중에 바뀌지 않으므로 그대로다).
func cancel() -> void:
	_clear()


func _clear() -> void:
	_active = false
	_touched = {}
	_ed._canvas.erase_preview = {}
	_clear_hint()


func _touch_at(world: Vector2) -> void:
	var path: PackedVector2Array = _ed._doc["path"]
	if path.size() < 2:
		return
	var r: float = brush_radius()
	for i in range(path.size()):
		if path[i].distance_to(world) <= r:
			_touched[i] = true


func _update_preview() -> void:
	var p: Dictionary = plan(_touched.keys())
	if p.is_empty():
		_ed._canvas.erase_preview = {}
		_clear_hint()
		return
	_ed._canvas.erase_preview = p["preview"]
	var restore: Array = _ed._hint_restore
	if restore.is_empty():
		restore = [_ed._status_label.text, _ed._status_color()]
	_ed._set_status(_describe(p, true), _ed.WARN_COLOR if bool(p["ok"]) else _ed.FAIL_COLOR)
	_ed._hint_restore = restore


func _clear_hint() -> void:
	var restore: Array = _ed._hint_restore
	if restore.is_empty():
		return
	_ed._set_status(str(restore[0]), restore[1])
	_ed._hint_restore = []


# --- 지우기 계획·적용 ---


## 닿은 점 index 목록으로 지우기 결과를 계산한다(문서는 바꾸지 않는다). 닿은 점이 없으면 {}.
## 반환 {ok, path, gap, items, removed(아이템 수), pieces, start_moved, gap_made, opened, preview}.
func plan(touched: Array) -> Dictionary:
	var path: PackedVector2Array = _ed._doc["path"]
	var n: int = path.size()
	if n < 2 or touched.is_empty():
		return {}
	var valid: Array = touched.filter(func(t: Variant) -> bool: return int(t) >= 0 and int(t) < n)
	if valid.is_empty():
		return {}  # 범위 밖 index만 있으면(옛 경로 기준) 지울 것이 없다
	var g: int = EditorDoc.gap_index(_ed._doc)
	var pieces: Array = _pieces(n, g, valid)
	var out: Dictionary = {
		"ok": pieces.size() <= 2,
		"pieces": pieces,
		"removed": 0,
		"start_moved": not pieces.is_empty() and int(pieces[0][0]) != 0,
		"gap_made": pieces.size() == 2 and g < 0,
		"opened": bool(_ed._doc["closed"]),
		"preview": _preview_for(path, g, pieces),
	}
	if not bool(out["ok"]):
		return out
	var new_path: PackedVector2Array = PackedVector2Array()
	var new_gap: int = -1
	for k in range(pieces.size()):
		if k == 1:
			new_gap = new_path.size()
		new_path.append_array(path.slice(int(pieces[k][0]), int(pieces[k][1]) + 1))
	var cum: PackedFloat64Array = _cumulative(path)
	var offsets: Array = [0.0, EditorDoc.length_to(new_path, new_gap) if new_gap >= 0 else 0.0]
	var limit: float = EditorDoc.item_s_max(EditorDoc.path_length(new_path))
	var items: Array = []
	for it in _ed._doc["items"]:
		var s: float = float(it["s"])
		for k in range(pieces.size()):
			var s_lo: float = cum[int(pieces[k][0])]
			var s_hi: float = cum[int(pieces[k][1])]
			if k == pieces.size() - 1:
				s_hi -= EditorDoc.ITEM_END_MARGIN
			if s >= s_lo - EPS and s <= s_hi + EPS:
				var d: Dictionary = (it as Dictionary).duplicate()
				d["s"] = clampf(s - s_lo + float(offsets[k]), 0.0, limit)
				_flag_if_moved(path, new_path, it, d)
				items.append(d)
				break
	out["path"] = new_path
	out["gap"] = new_gap
	out["items"] = items
	out["removed"] = (_ed._doc["items"] as Array).size() - items.size()
	return out


## 지워지지 않은 연속 점(틈에서 끊는다) 중 2점 이상인 조각 [lo, hi] 목록.
static func _pieces(n: int, g: int, touched: Array) -> Array:
	var gone: PackedByteArray = PackedByteArray()
	gone.resize(n)
	for t in touched:
		if int(t) >= 0 and int(t) < n:
			gone[int(t)] = 1
	var pieces: Array = []
	var i: int = 0
	while i < n:
		if gone[i] == 1:
			i += 1
			continue
		var lo: int = i
		i += 1
		while i < n and gone[i] == 0 and i != g:
			i += 1
		if i - lo >= 2:
			pieces.append([lo, i - 1])
	return pieces


## 계획을 문서에 적용한다(undo 한 단위). 틈이 둘 이상 생기는 계획은 적용하지 않고 안내한다.
func apply(p: Dictionary) -> bool:
	if p.is_empty():
		return false
	if not bool(p["ok"]):
		_ed._set_status(_describe(p, false), _ed.FAIL_COLOR)
		return false
	_ed._push_undo("erase")
	_ed._doc["path"] = p["path"]
	_ed._doc["gap"] = p["gap"]
	_ed._doc["items"] = p["items"]
	if bool(p["opened"]):
		_ed._doc["closed"] = false
		_ed._doc["pre_close"] = PackedVector2Array()  # 지운 뒤에는 닫기 전 경로가 뜻이 없다
	_ed._selected_item = -1
	_ed._sync_ui()
	_ed._after_edit()
	var has_gap: bool = EditorDoc.has_gap(_ed._doc)
	_ed._set_status(_describe(p, false), _ed.WARN_COLOR if has_gap else _ed.NEUTRAL_COLOR)
	return true


## 상태줄 문구. preview=true면 누르는 중 안내("놓으면 …").
func _describe(p: Dictionary, preview: bool) -> String:
	if not bool(p["ok"]):
		return (
			"경로 중간 구간은 한 번에 하나만 지울 수 있습니다(틈은 하나까지). 틈을 먼저 잇거나,"
			+ " 교차 지점이면 확대해서 지우세요."
		)
	var pieces: Array = p["pieces"]
	var head: String = "빨간 구간을 지웁니다" if preview else "구간을 지웠습니다"
	if pieces.is_empty():
		head = "경로를 모두 지웁니다" if preview else "경로를 모두 지웠습니다"
	elif bool(p["gap_made"]):
		head = "구간을 지워 틈이 생깁니다" if preview else "구간을 지워 틈이 생겼습니다"
	elif bool(p["start_moved"]):
		head = "시작 부분을 지웁니다(시작점이 초록 원으로 옮겨집니다)"
		if not preview:
			head = "시작 부분을 지웠습니다(시작점이 옮겨졌습니다)"
	if preview:
		head = "놓으면 " + head
	var extra: String = ""
	if int(p["removed"]) > 0:
		extra += "  (아이템 %d개 함께 제거)" % int(p["removed"])
	if bool(p["opened"]):
		extra += "  (루프가 열립니다)" if preview else "  (루프를 열었습니다)"
	if not preview and pieces.size() == 2:
		extra += ". 빨간 끝점 두 곳을 이어 그리거나 '직선으로 잇기'·'뒤쪽 버리기'를 누르세요."
	return head + extra


## 지워질 선분(빨간색)과 결과 표식(새 시작점, 새 틈 끝점) 미리보기 데이터(월드 좌표).
static func _preview_for(path: PackedVector2Array, g: int, pieces: Array) -> Dictionary:
	var keep: PackedInt32Array = PackedInt32Array()
	keep.resize(path.size())
	keep.fill(-1)
	for k in range(pieces.size()):
		for j in range(int(pieces[k][0]), int(pieces[k][1]) + 1):
			keep[j] = k
	var segs: Array = []
	var cur: PackedVector2Array = PackedVector2Array()
	for j in range(path.size() - 1):
		# 틈 선분(j+1 == g)은 실제 경로가 아니므로 그리지 않는다.
		var removed: bool = j + 1 != g and (keep[j] < 0 or keep[j] != keep[j + 1])
		if removed:
			if cur.is_empty():
				cur.append(path[j])
			cur.append(path[j + 1])
		elif not cur.is_empty():
			segs.append(cur)
			cur = PackedVector2Array()
	if not cur.is_empty():
		segs.append(cur)
	var pv: Dictionary = {"segs": segs, "refused": pieces.size() > 2}
	if not pieces.is_empty() and int(pieces[0][0]) != 0:
		pv["start"] = path[int(pieces[0][0])]
	if pieces.size() == 2:
		pv["gap"] = [path[int(pieces[0][1])], path[int(pieces[1][0])]]
	return pv


# --- 틈 잇기 ---


## 틈이 있을 때 그리기 스트로크(처리된 세그먼트)를 받는다. 틈 끝점에 닿으면 잇거나 늘리고 true.
## 어디에도 닿지 않으면 안내하고 true. 경로 끝점에서 시작한 보통 이어 그리기는 false(호출자가 처리).
func gap_stroke(seg: PackedVector2Array) -> bool:
	var g: int = EditorDoc.gap_index(_ed._doc)
	if g < 0 or seg.size() < 2:
		return false
	var path: PackedVector2Array = _ed._doc["path"]
	var a: Vector2 = path[g - 1]
	var b: Vector2 = path[g]
	var snap: float = _ed._canvas.world_radius(_ed.SNAP_PX, _ed.SNAP_RADIUS)
	var s0: Vector2 = seg[0]
	var s1: Vector2 = seg[seg.size() - 1]
	var rev: PackedVector2Array = seg.duplicate()
	rev.reverse()
	if s0.distance_to(a) <= snap and s1.distance_to(b) <= snap:
		_join(_between(seg, a, b), "stroke")
	elif s0.distance_to(b) <= snap and s1.distance_to(a) <= snap:
		_join(_between(rev, a, b), "stroke")
	elif s0.distance_to(a) <= snap or s1.distance_to(a) <= snap:
		_extend(_from_closest(seg if s0.distance_to(a) <= snap else rev, a), true)
	elif s0.distance_to(b) <= snap or s1.distance_to(b) <= snap:
		var into_b: PackedVector2Array = seg if s1.distance_to(b) <= snap else rev
		into_b.reverse()
		into_b = _from_closest(into_b, b)
		into_b.reverse()
		_extend(into_b, false)
	elif path[path.size() - 1].distance_to(s0) <= snap:
		return false
	else:
		_ed._set_status(
			"틈을 이으려면 빨간 끝점 근처에서 그리기 시작하세요. 끝점(노란 점)에서 이어 그릴 수도 있습니다.",
			_ed.WARN_COLOR
		)
	return true


## "직선으로 잇기": 틈 두 끝점을 직선(6 간격)으로 이어 한 경로로 만든다(undo 한 단위).
func join_straight() -> void:
	_ed._cancel_gestures()
	if EditorDoc.has_gap(_ed._doc):
		_join(PackedVector2Array(), "straight")


## "뒤쪽 버리기": 틈 뒤 조각을 버리고 틈 앞 끝에서 경로를 끝낸다(끝 자르기와 같다, undo 한 단위).
func drop_tail() -> void:
	_ed._cancel_gestures()
	var g: int = EditorDoc.gap_index(_ed._doc)
	if g < 0:
		return
	var path: PackedVector2Array = _ed._doc["path"]
	var front: PackedVector2Array = path.slice(0, g)
	var kept: Dictionary = EditorDoc.items_within(_ed._doc["items"], EditorDoc.path_length(front))
	_ed._push_undo("erase_drop")
	_ed._doc["path"] = front
	_ed._doc["gap"] = -1
	_ed._doc["items"] = kept["items"]
	_ed._selected_item = -1
	_ed._after_edit()
	var extra: String = "  (아이템 %d개 함께 제거)" % int(kept["removed"]) if kept["removed"] > 0 else ""
	_ed._set_status("틈 뒤쪽 조각을 버렸습니다" + extra, _ed.NEUTRAL_COLOR)


## 틈을 mid(틈 앞 끝점과 뒤 끝점 사이를 채울 점들, 비면 직선)로 채워 한 경로로 잇는다.
func _join(mid_pts: PackedVector2Array, how: String) -> void:
	var path: PackedVector2Array = _ed._doc["path"]
	var g: int = EditorDoc.gap_index(_ed._doc)
	var mid: PackedVector2Array = _bridge(path[g - 1], mid_pts, path[g], true)
	_rebuild(mid, -1)
	var msg: String = "틈을 직선으로 이었습니다" if how == "straight" else "틈을 이었습니다"
	_ed._set_status(msg + ". 검증하려면 '검증'(Enter)을 누르세요.", _ed.NEUTRAL_COLOR)


## 한쪽 끝점에서만 이어 그린 스트로크로 그쪽 조각을 늘린다. front=true면 틈 앞 끝점(A)에서 pts 방향으로,
## false면 pts의 마지막이 틈 뒤 끝점(B)에 닿도록 뒤 조각을 앞으로 늘린다. 틈은 남는다.
func _extend(pts: PackedVector2Array, front: bool) -> void:
	var path: PackedVector2Array = _ed._doc["path"]
	var g: int = EditorDoc.gap_index(_ed._doc)
	var mid: PackedVector2Array
	if front:
		mid = _bridge(path[g - 1], pts, Vector2.INF, false)
	else:
		mid = _bridge(pts[0], pts.slice(1), path[g], true)
		mid.insert(0, pts[0])
	if mid.is_empty():
		return
	_rebuild(mid, g + mid.size() if front else g)
	var still: bool = EditorDoc.has_gap(_ed._doc)
	_ed._set_status(
		"틈 %s 끝을 늘렸습니다. %s" % ["앞쪽" if front else "뒤쪽", GAP_HINT if still else ""],
		_ed.WARN_COLOR
	)


## 틈 자리(g)에 mid를 끼워 새 경로를 만든다(undo 한 단위). 틈 앞 조각 아이템은 그대로, 뒤 조각 아이템은
## 뒤 끝점의 호길이 변화만큼 s를 옮긴다. new_gap은 새 경로의 틈 index(-1이면 이어짐).
func _rebuild(mid: PackedVector2Array, new_gap: int) -> void:
	var path: PackedVector2Array = _ed._doc["path"]
	var g: int = EditorDoc.gap_index(_ed._doc)
	var new_path: PackedVector2Array = path.slice(0, g)
	new_path.append_array(mid)
	new_path.append_array(path.slice(g))
	var b_old: float = EditorDoc.length_to(path, g)
	var shift: float = EditorDoc.length_to(new_path, g + mid.size()) - b_old
	var limit: float = EditorDoc.item_s_max(EditorDoc.path_length(new_path))
	var items: Array = []
	for it in _ed._doc["items"]:
		var d: Dictionary = (it as Dictionary).duplicate()
		if float(d["s"]) >= b_old - EPS:
			d["s"] = clampf(float(d["s"]) + shift, 0.0, limit)
			_flag_if_moved(path, new_path, it, d)
		items.append(d)
	_ed._push_undo("gap_join" if new_gap < 0 else "gap_extend")
	_ed._doc["path"] = new_path
	_ed._doc["gap"] = new_gap
	_ed._doc["items"] = items
	_ed._selected_item = -1
	_ed._after_edit()


## 옮긴 아이템의 월드 위치가 재투영 기준보다 어긋나면 검토 필요("moved")로 표시한다.
static func _flag_if_moved(
	old_path: PackedVector2Array, new_path: PackedVector2Array, old_it: Dictionary, d: Dictionary
) -> void:
	var before: Vector2 = EditorDoc.item_world(old_path, old_it)
	if EditorDoc.item_world(new_path, d).distance_to(before) > EditorDoc.REVIEW_MOVE_LIMIT:
		d["review"] = "moved"


## from 뒤에 pts를 잇고(선분마다 SUBDIV_STEP 간격으로 채움) to 앞에서 멈춘 점 목록. from과 to는 넣지 않는다.
## to_on=false면 끝을 잇지 않는다.
func _bridge(
	from: Vector2, pts: PackedVector2Array, to: Vector2, to_on: bool
) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	var prev: Vector2 = from
	var targets: PackedVector2Array = pts.duplicate()
	if to_on:
		targets.append(to)
	for p in targets:
		var dist: float = prev.distance_to(p)
		if dist < 0.01:
			continue
		var n: int = maxi(1, ceili(dist / _ed.SUBDIV_STEP))
		for m in range(1, n + 1):
			out.append(prev.lerp(p, float(m) / float(n)))
		prev = p
	if to_on and not out.is_empty() and out[out.size() - 1].is_equal_approx(to):
		out.remove_at(out.size() - 1)
	return out


## 스트로크의 a에 가장 가까운 점부터 b에 가장 가까운 점까지(끝점을 넘어 그린 부분을 버린다).
static func _between(seg: PackedVector2Array, a: Vector2, b: Vector2) -> PackedVector2Array:
	var ia: int = _closest(seg, a)
	var ib: int = _closest(seg, b)
	return seg.slice(ia, ib + 1) if ia < ib else seg


## 스트로크의 p에 가장 가까운 점부터 끝까지.
static func _from_closest(seg: PackedVector2Array, p: Vector2) -> PackedVector2Array:
	var i: int = _closest(seg, p)
	return seg.slice(i) if i < seg.size() - 1 else seg


static func _closest(seg: PackedVector2Array, p: Vector2) -> int:
	var best: int = 0
	for i in range(seg.size()):
		if seg[i].distance_to(p) < seg[best].distance_to(p):
			best = i
	return best


static func _cumulative(path: PackedVector2Array) -> PackedFloat64Array:
	var cum: PackedFloat64Array = PackedFloat64Array()
	cum.resize(path.size())
	var acc: float = 0.0
	for i in range(path.size()):
		if i > 0:
			acc += path[i - 1].distance_to(path[i])
		cum[i] = acc
	return cum
