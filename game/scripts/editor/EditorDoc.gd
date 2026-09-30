class_name EditorDoc
extends RefCounted
## 트랙 에디터의 편집 문서 도우미 (track-editor-ux 6단계·1단계 전제).
##
## 편집 문서는 저장·undo/redo·dirty·테스트 복귀의 단위이며 Dictionary 하나로 다룬다(스냅샷 복사와
## 비교가 쉽다). 키:
##   path(PackedVector2Array, 월드 중심선) · closed(bool) · pre_close(PackedVector2Array, 닫기 전 경로)
##   name(String, 이름 입력 원문) · difficulty(String, DIFFS id) · fabric(String, FABRICS id)
##   width({perfect, safe, fail} float, 난이도 프리셋과 다르면 "사용자 지정 폭")
##   items(Array[{s, type, lat}], 시작부터 호길이 s · 중심선 옆 거리 lat)
##   local_id(String, 저장된 custom_ id, 저장 전이면 "")
##   doc_key(int, 같은 트랙 계보 식별. 불러오기·사본 열기마다 새 값. 저장 id·저장 기준을 계보별로 맞춘다)
## 화면 상태(zoom/pan·선택 도구·선택 아이템)는 문서에 넣지 않는다(undo·dirty 대상이 아니다).

# 난이도 → 폭 프리셋(§4.5). id는 JSON/레코드 키에 쓰는 소문자.
const DIFFS: Array = [
	{"name": "Beginner", "id": "beginner", "perfect": 22.0, "safe": 52.0, "fail": 108.0},
	{"name": "Normal", "id": "normal", "perfect": 18.0, "safe": 42.0, "fail": 90.0},
	{"name": "Expert", "id": "expert", "perfect": 14.0, "safe": 34.0, "fail": 72.0},
	{"name": "Master", "id": "master", "perfect": 12.0, "safe": 28.0, "fail": 60.0},
]
const FABRICS: Array = ["cotton", "denim", "silk", "knit", "wool", "felt", "satin", "leather"]
const DEFAULT_DIFF: String = "normal"
const DEFAULT_FABRIC: String = "cotton"
const DEFAULT_NAME: String = "Custom Track"
const ITEM_TYPES: Array = ["thimble", "autopilot"]
const ITEM_NAMES: Dictionary = {"thimble": "골무", "autopilot": "엄마 찬스"}
const MAX_ITEMS: int = 128  # 허브 게시 상한(TrackLoader.HUB_MAX_ITEMS와 같은 값)
# 서버 게시 제약: 아이템 s ≤ 베이크 길이 − 0.5.
const ITEM_END_MARGIN: float = 0.5
# 아이템 재투영 검토 기준(reproject_items).
const REVIEW_MOVE_LIMIT: float = 12.0  # 이보다 멀리 옮겨지면 검토 필요(월드)
const REVIEW_AMBIG_ARC: float = 60.0  # 이만큼 떨어진 다른 구간이
const REVIEW_AMBIG_EPS: float = 6.0  # 최근접 거리 + 이 값 안에 있으면 다의적


static func make(doc_key: int) -> Dictionary:
	return {
		"path": PackedVector2Array(),
		"closed": false,
		"pre_close": PackedVector2Array(),
		"name": "",
		"difficulty": DEFAULT_DIFF,
		"fabric": DEFAULT_FABRIC,
		"width": preset_width(DEFAULT_DIFF),
		"items": [],
		"local_id": "",
		"doc_key": doc_key,
	}


static func copy(doc: Dictionary) -> Dictionary:
	return doc.duplicate(true)


static func preset_index(diff_id: String) -> int:
	for i in range(DIFFS.size()):
		if str(DIFFS[i]["id"]) == diff_id:
			return i
	return -1


static func preset_width(diff_id: String) -> Dictionary:
	var i: int = preset_index(diff_id)
	var p: Dictionary = DIFFS[i if i >= 0 else 1]
	return {"perfect": float(p["perfect"]), "safe": float(p["safe"]), "fail": float(p["fail"])}


## 폭이 난이도 프리셋과 다르면 true(가져온 사용자 지정 폭).
static func is_custom_width(doc: Dictionary) -> bool:
	var w: Dictionary = doc["width"]
	var p: Dictionary = preset_width(str(doc["difficulty"]))
	for k in ["perfect", "safe", "fail"]:
		if absf(float(w[k]) - float(p[k])) > 0.0005:
			return true
	return false


static func track_name(doc: Dictionary) -> String:
	var n: String = str(doc["name"]).strip_edges()
	return n if not n.is_empty() else DEFAULT_NAME


## 저장 형식(TrackLoader.save_custom_track 입력). 좌표는 0.1 격자(베이크가 점을 더 넣지 않게
## 맞춘 점 열, TrackLoader.snapped_dense_points), 아이템 수치는 0.001 격자.
static func to_track_dict(doc: Dictionary) -> Dictionary:
	var pts: Array = TrackLoader.snapped_dense_points(doc["path"])
	var w: Dictionary = doc["width"]
	var items: Array = []
	for it in doc["items"]:
		items.append(
			{
				"s": snappedf(float(it["s"]), 0.001),
				"type": str(it["type"]),
				"lat": snappedf(float(it.get("lat", 0.0)), 0.001),
			}
		)
	return {
		"track_id": str(doc["local_id"]),
		"name": track_name(doc),
		"difficulty": str(doc["difficulty"]),
		"fabric": str(doc["fabric"]),
		"width": {"perfect": float(w["perfect"]), "safe": float(w["safe"]), "fail": float(w["fail"])},
		"path": [{"type": "polyline", "points": pts, "closed": bool(doc["closed"])}],
		"items": items,
		"modifiers": [],
	}


## "현재 저장 가능한 문서"의 비교용 직렬화(로컬 id 제외). dirty = serial != 마지막 저장 serial.
static func serial(doc: Dictionary) -> String:
	var d: Dictionary = to_track_dict(doc)
	d.erase("track_id")
	return JSON.stringify(d, "", true)


## 기하 검증 결과가 유효한지 가르는 키(경로 + 판정 폭). 이름·원단 변경은 바꾸지 않는다.
static func geom_key(doc: Dictionary) -> String:
	var w: Dictionary = doc["width"]
	return "%d|%.3f|%.3f|%.3f" % [
		hash(doc["path"]), float(w["perfect"]), float(w["safe"]), float(w["fail"])
	]


static func path_length(path: PackedVector2Array) -> float:
	var total: float = 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


## 경로 길이 len 기준으로 남길 수 있는 아이템의 s 상한(서버 게시 제약).
static func item_s_max(length: float) -> float:
	return maxf(0.0, length - ITEM_END_MARGIN)


## 경로 끝이 잘려 길이가 new_len이 됐을 때 잘린 구간(s > 상한)의 아이템을 뺀다.
## 반환 {items, removed(int)}.
static func items_within(items: Array, new_len: float) -> Dictionary:
	var keep: Array = []
	var limit: float = item_s_max(new_len)
	for it in items:
		if float(it["s"]) <= limit:
			keep.append((it as Dictionary).duplicate())
	return {"items": keep, "removed": items.size() - keep.size()}


## 경로 전체가 비례로 늘거나 줄었을 때(길이 맞추기·자동 수정) 진행 비율을 유지해 s를 옮긴다.
static func scale_items(items: Array, old_len: float, new_len: float) -> Array:
	var out: Array = []
	if old_len <= 0.0:
		return out
	var limit: float = item_s_max(new_len)
	for it in items:
		var d: Dictionary = (it as Dictionary).duplicate()
		d["s"] = clampf(float(d["s"]) * new_len / old_len, 0.0, limit)
		out.append(d)
	return out


## 아이템의 월드 좌표(경로를 따라 s만큼 간 점 + 접선 법선 × lat). RaceDirector와 같은 규칙.
static func item_world(path: PackedVector2Array, item: Dictionary) -> Vector2:
	if path.size() < 2:
		return path[0] if path.size() == 1 else Vector2.ZERO
	var s: float = maxf(0.0, float(item["s"]))
	var acc: float = 0.0
	for i in range(1, path.size()):
		var seg: float = path[i - 1].distance_to(path[i])
		if acc + seg >= s or i == path.size() - 1:
			var t: float = clampf((s - acc) / seg, 0.0, 1.0) if seg > 0.0 else 0.0
			var dir: Vector2 = (path[i] - path[i - 1]).normalized()
			return path[i - 1].lerp(path[i], t) + dir.orthogonal() * float(item.get("lat", 0.0))
		acc += seg
	return path[path.size() - 1]


## 점 index까지의 호길이(경로 앞부분만 남길 때의 새 길이).
static func length_to(path: PackedVector2Array, index: int) -> float:
	var total: float = 0.0
	for i in range(1, mini(index + 1, path.size())):
		total += path[i - 1].distance_to(path[i])
	return total


## TrackLoader.prepare_edit_import가 정규화한 track_dict → 편집 문서. 난이도·원단이 에디터가
## 지원하지 않는 값이면 {ok=false, message}. 성공 시 {ok=true, doc}.
static func from_track_dict(track: Dictionary, doc_key: int) -> Dictionary:
	var diff: String = str(track.get("difficulty", DEFAULT_DIFF))
	if preset_index(diff) < 0:
		return {"ok": false, "message": "지원하지 않는 난이도: " + diff.substr(0, 24)}
	var fabric: String = str(track.get("fabric", DEFAULT_FABRIC))
	if not FABRICS.has(fabric):
		return {"ok": false, "message": "지원하지 않는 원단: " + fabric.substr(0, 24)}
	var seg: Dictionary = (track["path"] as Array)[0]
	var path: PackedVector2Array = PackedVector2Array()
	for pt in seg["points"]:
		path.append(Vector2(float(pt[0]), float(pt[1])))
	var w: Dictionary = track["width"]
	var doc: Dictionary = make(doc_key)
	doc["path"] = path
	doc["closed"] = seg.get("closed", false) == true
	doc["name"] = str(track.get("name", ""))
	doc["difficulty"] = diff
	doc["fabric"] = fabric
	doc["width"] = {
		"perfect": float(w["perfect"]), "safe": float(w["safe"]), "fail": float(w["fail"])
	}
	var limit: float = item_s_max(path_length(path))
	var items: Array = []
	for it in track.get("items", []):
		items.append(
			{
				"s": clampf(float(it["s"]), 0.0, limit),
				"type": str(it["type"]),
				"lat": float(it.get("lat", 0.0)),
			}
		)
	doc["items"] = items
	return {"ok": true, "doc": doc}


# --- 아이템 재투영·검토 필요 상태 (3단계) ---
# 검토 필요 아이템은 item["review"]에 사유 문자열을 둔다("moved" 크게 이동 · "ambiguous" 가까운
# 다른 구간과 헷갈림 · "range" 길이 밖). 키가 없거나 빈 문자열이면 정상이다. 저장 형식(to_track_dict)
# 에는 싣지 않고, 하나라도 있으면 저장·테스트를 막는다. 셋째 묶음의 아이템 도구는 선택·이동 뒤
# clear_review(item)로 개별 해결하면 된다.

static func needs_review(item: Dictionary) -> bool:
	return not str(item.get("review", "")).is_empty()


static func review_count(items: Array) -> int:
	var n: int = 0
	for it in items:
		if needs_review(it):
			n += 1
	return n


static func clear_review(item: Dictionary) -> void:
	item.erase("review")


## 점 p를 경로에 투영: 최근접 선분 위 호길이 s와 거리, 다의성(멀리 떨어진 다른 구간이 거의 같은 거리).
static func project_on_path(path: PackedVector2Array, p: Vector2) -> Dictionary:
	var best: Dictionary = {"s": 0.0, "dist": INF, "ambiguous": false}
	if path.size() < 2:
		return best
	var cands: Array = []  # [s, dist]
	var acc: float = 0.0
	for i in range(1, path.size()):
		var a: Vector2 = path[i - 1]
		var b: Vector2 = path[i]
		var ab: Vector2 = b - a
		var seg: float = ab.length()
		var t: float = 0.0
		if seg > 0.0001:
			t = clampf((p - a).dot(ab) / (seg * seg), 0.0, 1.0)
		var d: float = p.distance_to(a + ab * t)
		cands.append([acc + seg * t, d])
		if d < float(best["dist"]):
			best["dist"] = d
			best["s"] = acc + seg * t
		acc += seg
	for c in cands:
		if (
			absf(float(c[0]) - float(best["s"])) > REVIEW_AMBIG_ARC
			and float(c[1]) <= float(best["dist"]) + REVIEW_AMBIG_EPS
		):
			best["ambiguous"] = true
			break
	return best


## 경로가 국소적으로 바뀐 뒤(자동 수정·재샘플) 아이템의 이전 중심선 위치를 새 경로에 투영해 s를
## 다시 정한다. lat은 유지한다. 크게 이동했거나 다의적이거나 길이 밖이면 review 사유를 단다
## (조용히 빼거나 시작점으로 몰지 않는다).
static func reproject_items(
	old_path: PackedVector2Array, new_path: PackedVector2Array, items: Array
) -> Array:
	var out: Array = []
	var limit: float = item_s_max(path_length(new_path))
	for it in items:
		var d: Dictionary = (it as Dictionary).duplicate()
		var base: Vector2 = item_world(old_path, {"s": float(d["s"]), "lat": 0.0})
		var pr: Dictionary = project_on_path(new_path, base)
		var s: float = float(pr["s"])
		var reason: String = str(d.get("review", ""))
		if float(pr["dist"]) > REVIEW_MOVE_LIMIT:
			reason = "moved"
		elif bool(pr["ambiguous"]):
			reason = "ambiguous"
		elif s > limit:
			reason = "range"
		d["s"] = clampf(s, 0.0, limit)
		if reason.is_empty():
			d.erase("review")
		else:
			d["review"] = reason
		out.append(d)
	return out


## 기존 중심선 끝점에서 새 세그먼트까지 ≤step 간격으로 이어 붙인 새 경로(단일 연속 경로 유지).
static func appended(
	path: PackedVector2Array, seg: PackedVector2Array, step: float
) -> PackedVector2Array:
	var out: PackedVector2Array = path.duplicate()
	var a: Vector2 = out[out.size() - 1]
	var b: Vector2 = seg[0]
	var n: int = maxi(1, ceili(a.distance_to(b) / step))
	for m in range(1, n + 1):
		out.append(a.lerp(b, float(m) / float(n)))
	for k in range(1, seg.size()):
		out.append(seg[k])
	return out


## 폭 표시용 숫자(정수면 소수점 없이).
static func fmt(v: Variant) -> String:
	var f: float = float(v)
	return str(int(f)) if is_equal_approx(f, roundf(f)) else "%.1f" % f


## 점 p를 경로에 투영하되 호길이 [s_center − window, s_center + window] 안의 선분만 본다(아이템 드래그가
## 교차·근접 구간에서 다른 갈래로 튀지 않게). 반환 {s, dist}.
static func project_on_path_near(
	path: PackedVector2Array, p: Vector2, s_center: float, window: float
) -> Dictionary:
	var best: Dictionary = {"s": s_center, "dist": INF}
	var acc: float = 0.0
	for i in range(1, path.size()):
		var a: Vector2 = path[i - 1]
		var b: Vector2 = path[i]
		var ab: Vector2 = b - a
		var seg: float = ab.length()
		if acc + seg >= s_center - window and acc <= s_center + window:
			var t: float = 0.0
			if seg > 0.0001:
				t = clampf((p - a).dot(ab) / (seg * seg), 0.0, 1.0)
			var d: float = p.distance_to(a + ab * t)
			if d < float(best["dist"]):
				best = {"s": acc + seg * t, "dist": d}
		acc += seg
	return best


## 판정 폭(fail)이 줄어 |lat| > fail이 된 아이템에 검토 사유 "lat"을 단다(값을 조용히 바꾸지 않는다).
## 표시한 개수를 반환한다.
static func flag_lat_overflow(items: Array, fail: float) -> int:
	var n: int = 0
	for it in items:
		if absf(float(it.get("lat", 0.0))) > fail and not needs_review(it):
			it["review"] = "lat"
			n += 1
	return n


## 검토 사유 한국어 설명.
static func review_text(reason: String) -> String:
	match reason:
		"moved":
			return "경로가 바뀌어 크게 옮겨졌습니다"
		"ambiguous":
			return "가까운 다른 구간과 헷갈립니다"
		"range":
			return "트랙 길이 밖으로 밀렸습니다"
		"lat":
			return "옆 거리가 판정 폭보다 큽니다(확정하면 폭 안으로 맞춥니다)"
	return ""


## 아이템 하나를 저장 가능한 범위(0 ≤ s ≤ 길이 − 0.5, |lat| ≤ fail)로 맞추고 검토 표시를 푼다.
## 검토 사유와 무관하게 같은 규칙을 쓴다(개별 확정·일괄 확정·아이템 도구 이동 공용).
static func resolve_item(it: Dictionary, length: float, fail: float) -> void:
	it["s"] = clampf(float(it.get("s", 0.0)), 0.0, item_s_max(length))
	it["lat"] = clampf(float(it.get("lat", 0.0)), -fail, fail)
	clear_review(it)


## 저장·테스트 게이트용 아이템 제약 검사(허브 게시 제약과 같다): 개수 ≤ MAX_ITEMS, 종류, 0 ≤ s ≤
## 길이 − 0.5, |lat| ≤ fail, 검토 필요 없음. 문제가 없으면 빈 문자열, 있으면 사유.
static func items_problem(items: Array, length: float, fail: float) -> String:
	if items.size() > MAX_ITEMS:
		return "아이템이 %d개로 최대 %d개를 넘습니다." % [items.size(), MAX_ITEMS]
	var limit: float = item_s_max(length)
	for i in range(items.size()):
		var it: Dictionary = items[i]
		var no: int = i + 1
		if not ITEM_TYPES.has(str(it.get("type", ""))):
			return "%d번 아이템의 종류를 지원하지 않습니다." % no
		var s: float = float(it.get("s", -1.0))
		if s < 0.0 or s > limit + 0.0005:
			return "%d번 아이템이 트랙 길이 밖에 있습니다(시작부터 %d)." % [no, roundi(s)]
		if absf(float(it.get("lat", 0.0))) > fail + 0.0005:
			return "%d번 아이템의 옆 거리가 판정 폭(%s)보다 큽니다." % [no, fmt(fail)]
		if needs_review(it):
			return "검토가 필요한 아이템이 있습니다(%d번)." % no
	return ""
