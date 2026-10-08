extends Node
## 트랙 JSON 로드 → TrackData 베이크, id별 캐시 오토로드 (아키텍처 §5).
##
## 재시작 시 재베이크를 피하기 위해 track_id로 캐시한다.
## 트랙 목록은 웹 export에서 DirAccess 디렉토리 나열이 불안정하므로 디렉토리
## 스캔 대신 index.json 매니페스트(파일 목록·순서)로 관리한다.

const OFFICIAL_DIR: String = "res://tracks/official/"
const MANIFEST_PATH: String = "res://tracks/official/index.json"
# 감도 체험 데모 트랙: 목록 밖, 이 id만 DEMO_DIR에서 로드(GameState.CALIBRATION_TRACK_ID와 같은 값).
const DEMO_DIR: String = "res://tracks/demo/"
const CALIBRATION_TRACK_ID: String = "steer_calibration"
# 커스텀(유저 자작) 트랙: 쓰기 가능한 user:// 아래. 웹(IDBFS) 포함 전 플랫폼 영속.
# 공식 id(cotton_01…)와 custom_ 접두로 네임스페이스 완전 분리(레코드·로드 충돌 없음).
const CUSTOM_DIR: String = "user://tracks/custom/"
const CUSTOM_PREFIX: String = "custom_"
const EDITOR_VERSION: String = "0.1.0"
# 외부 트랙 불러오기 크기 상한(1MB). 대용량·악의적 입력 방어(§8). 데스크톱 파일·웹 업로드 공용.
const IMPORT_MAX_BYTES: int = 1048576
# 공유 허브 가져오기·게시 형식 상한(서버 community_validation 과 같은 값).
const HUB_MAX_SEGMENTS: int = 64
const HUB_MAX_POINTS: int = 4096
# 좌표 절댓값 상한: 서버 community_validation.MAX_ABS_COORD(16384)와 같게 맞춘다(에디터 클램프 4000보다 넉넉함).
const HUB_MAX_COORD: float = 16384.0
const HUB_MAX_ITEMS: int = 128
const HUB_ITEM_TYPES: Array = ["thimble", "autopilot"]
const HUB_DIFFICULTIES: Array = ["beginner", "normal", "expert", "master"]
const HUB_FABRICS: Array = ["cotton", "denim", "silk", "knit", "wool", "felt", "satin", "leather"]
# 아이템 s 허용 여유(px). 서버는 float64, Godot 베이크는 float32 라 끝점 부근에서 미세하게 다르다.
const HUB_S_SLACK: float = 1.0
# 게시 payload 아이템 s 여유(서버: s ≤ 베이크 길이 − 0.5). float32/float64 베이크 차이와 0.001 격자
# 반올림을 덮으려고 0.02를 더 둔다.
const PUBLISH_S_MARGIN: float = 0.52
# 일반·에디터 가져오기의 베이크 전 원시 길이 상한. 하드 길이 상한(8000)의 2배로, bezier 제어 다각형이
# 실제 호길이보다 길게 나오는 공식 파일과 에디터에서 줄여 쓸 긴 파일은 받되 베이크 점 폭증은 막는다.
const PLAIN_RAW_LEN_MAX: float = 16000.0

# 매니페스트 로드 실패 시에도 게임이 동작하도록 두는 최소 폴백(기본 트랙).
const FALLBACK_TRACKS: Array = [
	{"track_id": "cotton_01", "name": "Cotton Warm-up", "difficulty": "normal"},
]

var _cache: Dictionary = {}
# track_id -> 기록 호환성 지문(record_fingerprint). load_track이 베이크와 함께 채우고 캐시와 같이 무효화한다.
var _fingerprints: Dictionary = {}
var _manifest: Array = []


## 매니페스트의 트랙 목록을 순서대로 반환한다. 각 항목은
## {"track_id", "name", "difficulty"} dict. 결과는 캐시한다.
func list_tracks() -> Array:
	if not _manifest.is_empty():
		return _manifest
	_manifest = _load_manifest()
	return _manifest


func _load_manifest() -> Array:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("TrackLoader: 매니페스트 없음, 폴백 사용 " + MANIFEST_PATH)
		return FALLBACK_TRACKS.duplicate(true)
	var file: FileAccess = FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_warning("TrackLoader: 매니페스트 열기 실패, 폴백 사용 " + MANIFEST_PATH)
		return FALLBACK_TRACKS.duplicate(true)
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("TrackLoader: 매니페스트 파싱 실패, 폴백 사용 " + MANIFEST_PATH)
		return FALLBACK_TRACKS.duplicate(true)
	var raw: Variant = (parsed as Dictionary).get("tracks", [])
	if not (raw is Array) or (raw as Array).is_empty():
		push_warning("TrackLoader: 매니페스트에 tracks 없음, 폴백 사용 " + MANIFEST_PATH)
		return FALLBACK_TRACKS.duplicate(true)
	var result: Array = []
	for item in raw:
		if item is Dictionary and (item as Dictionary).has("track_id"):
			result.append({
				"track_id": str(item.get("track_id", "")),
				"name": str(item.get("name", "")),
				"difficulty": str(item.get("difficulty", "normal")),
			})
	if result.is_empty():
		return FALLBACK_TRACKS.duplicate(true)
	return result


## 공식/커스텀 공용 로드. custom_ 접두면 user:// 커스텀 경로, 아니면 공식 res:// 경로.
func load_track(track_id: String) -> TrackData:
	if _cache.has(track_id):
		return _cache[track_id]
	var path: String
	if track_id.begins_with(CUSTOM_PREFIX):
		path = CUSTOM_DIR + track_id + ".json"
	else:
		path = (DEMO_DIR if track_id == CALIBRATION_TRACK_ID else OFFICIAL_DIR) + track_id + ".json"
	var dict: Dictionary = _read_track_dict(path)
	if dict.is_empty():
		return null
	var data: TrackData = _build_track(dict)
	_cache[track_id] = data
	_fingerprints[track_id] = record_fingerprint(data, _path_closed(dict.get("path", [])))
	return data


## 트랙 내용 지문(기록 엔트리·고스트 헤더의 track_fingerprint, 고스트 유효성 판정용). 실패하면 빈 문자열.
func track_fingerprint(track_id: String) -> String:
	if load_track(track_id) == null:
		return ""
	return str(_fingerprints.get(track_id, ""))


## 실제 플레이 내용 지문(docs/architecture.md §3.2). 베이크 점 열·닫힘·폭·재질은 play_fingerprint 직렬화를
## 재사용하고, 아이템은 그 정렬(문자열) 대신 ItemOrder 정규 순서(s→type→lat)로 이어 붙인다. 메타·modifiers
## (시뮬레이션 미소비)·난이도(키에 따로 있음)는 뺀다. 허브용 fp1(play_fingerprint)은 바꾸지 않는다.
static func record_fingerprint(track: TrackData, closed: bool) -> String:
	var pts: Array = []
	for p in track.points:
		pts.append([p.x, p.y])
	var w: Dictionary = {"perfect": track.perfect, "safe": track.safe, "fail": track.fail}
	var norm: Dictionary = {
		"difficulty": "", "fabric": track.fabric, "width": w, "items": [],
		"path": [{"type": "baked", "closed": closed, "points": pts}],
	}
	var buf: String = play_fingerprint(norm) + "\nitems_in_order="
	for i in ItemOrder.indices(track.items):
		var it: Dictionary = track.items[i] if track.items[i] is Dictionary else {}
		buf += "%.3f|%.3f|%s;" % [_num(it.get("s", 0)), _num(it.get("lat", 0)), str(it.get("type", ""))]
	return "tf2:" + buf.sha256_text()


static func _path_closed(path: Variant) -> bool:
	for seg in path if path is Array else []:
		if seg is Dictionary and (seg as Dictionary).get("closed", false) == true:
			return true
	return false


## 커스텀 트랙 목록: user://tracks/custom/ 디렉토리 스캔(웹 IDBFS 포함 안정).
## 각 항목 {track_id, name, difficulty, is_custom=true}. 이름 오름차순 정렬.
func list_custom_tracks() -> Array:
	var out: Array = []
	_ensure_custom_dir()
	var dir: DirAccess = DirAccess.open(CUSTOM_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var hdr: Dictionary = _read_header(CUSTOM_DIR + f)
		if not hdr.is_empty():
			out.append(hdr)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
	return out


## 커스텀 트랙 저장. track_id가 없거나 비-custom이면 새 id를 발급한다. checksum·length·
## editor_version을 채워 user://tracks/custom/<id>.json에 기록하고 캐시를 무효화한다.
## 반환: 저장된 track_id(실패 시 빈 문자열).
func save_custom_track(track_dict: Dictionary) -> String:
	_ensure_custom_dir()
	var id: String = str(track_dict.get("track_id", ""))
	if not id.begins_with(CUSTOM_PREFIX):
		id = _new_custom_id()
	var data: Dictionary = track_dict.duplicate(true)
	data["track_id"] = id
	data["is_custom"] = true
	data["editor_version"] = EDITOR_VERSION
	data["checksum"] = compute_checksum(data.get("path", []))
	data["length"] = int(round(_path_length(data.get("path", []))))
	var path: String = CUSTOM_DIR + id + ".json"
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("TrackLoader: 커스텀 트랙 저장 실패 " + path)
		return ""
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	_cache.erase(id)  # 재편집 저장 후 다음 로드가 갱신본을 읽게 한다
	_fingerprints.erase(id)
	return id


## 커스텀 트랙 삭제(파일 삭제 + 캐시 무효화). 성공 여부 반환.
func delete_custom_track(track_id: String) -> bool:
	if not track_id.begins_with(CUSTOM_PREFIX):
		return false
	var path: String = CUSTOM_DIR + track_id + ".json"
	if not FileAccess.file_exists(path):
		return false
	var err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		# user:// 상대 경로 삭제 폴백.
		var dir: DirAccess = DirAccess.open(CUSTOM_DIR)
		if dir != null:
			err = dir.remove(track_id + ".json")
	if err == OK:
		_cache.erase(track_id)
		_fingerprints.erase(track_id)
		return true
	push_error("TrackLoader: 커스텀 트랙 삭제 실패 " + path)
	return false


## checksum(경로 좌표 SHA-256) 조회 → 이미 있는 커스텀 트랙 id. 없으면 빈 문자열.
## import 중복 감지용(동일 경로면 재저장 스킵).
func find_by_checksum(checksum: String) -> String:
	if checksum.is_empty():
		return ""
	_ensure_custom_dir()
	var dir: DirAccess = DirAccess.open(CUSTOM_DIR)
	if dir == null:
		return ""
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var hdr: Dictionary = _read_header(CUSTOM_DIR + f)
		if str(hdr.get("checksum", "")) == checksum:
			return str(hdr.get("track_id", ""))
	return ""


## 외부 트랙 JSON 텍스트를 커스텀 트랙으로 들여온다(§8). 데스크톱 파일 다이얼로그/드래그드롭과
## 웹 업로드가 공유하는 단일 진입점. 흐름: 크기 상한 → JSON 파싱 → 폭·아이템·modifiers 검사 →
## 폴리라인 베이크 → TrackValidator 검증 → 폴리라인 정규화 + 로컬 새 custom id → user:// 저장.
## items·사용자 지정 width·closed는 보존한다(조용한 손실 금지). modifiers는 게임이 소비하지 않고
## 서버도 빈 배열만 받으므로 비어 있지 않으면 빼고 가져오되 message·dropped로 명시한다.
## 중복 판정은 경로 체크섬이 아니라 플레이 내용 지문(play_fingerprint: difficulty·fabric·width·
## path·items)이 같은 커스텀 트랙이 있을 때만이다. 경로가 같아도 폭·재질·아이템이 다르면 새로 저장한다.
## 반환 dict: {ok(bool), status(String), track_id(String), name(String), message(String),
##   dropped(Array[String], 제외한 필드 이름)}.
##   status: "ok" | "duplicate" | "too_large" | "parse_error" | "empty_path"
##           | "validation_error" | "save_failed"  (실패 사유를 구분해 UI가 사유별 안내 가능).
func import_custom_from_text(text: String, suggested_name: String = "") -> Dictionary:
	var out: Dictionary = {
		"ok": false, "status": "", "track_id": "", "name": "", "message": "", "dropped": [],
	}
	# 1) 파싱·검증·정규화(실패 사유는 status로 구분). 저장은 아래에서 별도 처리한다.
	var prepared: Dictionary = _prepare_import(text, suggested_name)
	out["name"] = str(prepared.get("name", ""))
	if not bool(prepared["ok"]):
		out["status"] = str(prepared["status"])
		out["message"] = str(prepared["message"])
		return out
	var track_dict: Dictionary = prepared["track_dict"]
	out["dropped"] = prepared.get("dropped", [])
	var note: String = str(prepared.get("note", ""))
	# 2) 중복(플레이 내용 지문) 감지 — 내용이 모두 같으면 재저장 스킵하고 기존 트랙을 가리킨다.
	var existing: String = find_by_fingerprint(import_fingerprint(track_dict))
	if not existing.is_empty():
		out["ok"] = true
		out["status"] = "duplicate"
		out["track_id"] = existing
		out["message"] = "이미 있는 트랙: " + str(out["name"]) + note
		return out
	# 3) 저장(새 id 발급).
	var id: String = save_custom_track(track_dict)
	if id.is_empty():
		out["status"] = "save_failed"
		out["message"] = "저장 실패"
		return out
	out["ok"] = true
	out["status"] = "ok"
	out["track_id"] = id
	out["message"] = "'%s' 트랙을 가져왔습니다" % str(out["name"]) + note
	return out


## 에디터 불러오기용 파싱·정규화. import_custom_from_text와 같은 형식 검사(폭·아이템·modifiers)와
## 정규화를 거치지만 기하 검증으로 거부하지 않는다(에디터에서 고쳐 쓸 수 있어야 한다). 저장하지 않는다.
## 성공 시 {ok=true, name, track_dict, dropped, note}, 실패 시 {ok=false, status, message, name=""}.
func prepare_edit_import(text: String) -> Dictionary:
	return _prepare_import(text, "", false, false)


## 일반 가져오기 중복 비교용 지문. 트랙 dict를 일반 가져오기와 같은 정규화(베이크 → 0.1 격자 조밀 점 열,
## 폭 실수화, 아이템 정규화, modifiers 제외)에 통과시킨 뒤 play_fingerprint를 계산한다. 가져오는 쪽과
## 기존 파일 쪽에 같은 정규화를 적용해, 예전 버전이 저장한 파일(점 간격 6 초과, items 없음 등)을 다시
## 가져와도 같은 트랙으로 판정한다. 허브 매핑이 쓰는 custom_track_fingerprint(fp1 원본 지문)와는 별개다.
## 정규화에 실패하면 빈 문자열.
func import_fingerprint(track: Dictionary) -> String:
	var prep: Dictionary = _prepare_import(JSON.stringify(track), "", false, false)
	if not bool(prep["ok"]):
		return ""
	return play_fingerprint(prep["track_dict"])


## 정규화 지문(import_fingerprint)이 같은 커스텀 트랙 id(없으면 빈 문자열). 일반 가져오기 중복 판정용.
func find_by_fingerprint(fingerprint: String) -> String:
	if fingerprint.is_empty():
		return ""
	_ensure_custom_dir()
	var dir: DirAccess = DirAccess.open(CUSTOM_DIR)
	if dir == null:
		return ""
	for f in dir.get_files():
		if not f.ends_with(".json") or not f.begins_with(CUSTOM_PREFIX):
			continue
		var id: String = f.get_basename()
		var parsed: Variant = JSON.parse_string(read_custom_track_text(id))
		if parsed is Dictionary and import_fingerprint(parsed) == fingerprint:
			return id
	return ""


## import_custom_from_text의 파싱·검증·정규화 단계(반환 수 분리 겸 가독성). 성공 시
## {ok=true, name, track_dict, dropped, note}, 실패 시 {ok=false, status, message, name=""}를 반환한다.
## hub=true(공유 허브 가져오기 전용, import_hub_track)면 베이크 전에 경로·폭·아이템 형식과
## 크기를 검사하고, 폴리라인을 재표본화하지 않고 0.1 격자 좌표 그대로 보존하며, items를
## 검사해 보존한다. hub=false(일반 파일·에디터)는 폭·아이템·modifiers를 검사해 보존하고(modifiers는
## 제외 후 안내), 경로는 베이크 결과를 0.1 격자 폴리라인 1개로 정규화하며 closed를 보존한다.
## validate_geometry=false(에디터 불러오기)면 TrackValidator 기하 검증으로 거부하지 않는다.
func _prepare_import(
	text: String, suggested_name: String, hub: bool = false, validate_geometry: bool = true
) -> Dictionary:
	var parsed: Dictionary = _parse_import_text(text, hub)
	if not bool(parsed["ok"]):
		return parsed
	var dict: Dictionary = parsed["dict"]
	var dropped: Array = []
	if not hub:
		var bad: String = _plain_precheck(dict)
		if not bad.is_empty():
			return {"ok": false, "status": "validation_error", "name": "",
				"message": "검증 실패: " + bad}
		var mods: Variant = dict.get("modifiers", [])
		if not (mods is Array) or not (mods as Array).is_empty():
			dropped.append("modifiers")
	# 폴리라인 베이크(공식 bezier 파일도 여기서 폴리라인으로 표본화된다).
	var td: TrackData = TrackData.new()
	td.bake(dict.get("path", []))
	if td.points.size() < 2:
		return {"ok": false, "status": "empty_path", "name": "", "message": "경로가 비어있음"}
	# 검증(추적 불가 기하 거부). fail 폭은 파일 값 우선, 없으면 Normal 프리셋.
	var width: Dictionary = dict.get("width", {})
	if validate_geometry:
		var res: Dictionary = TrackValidator.new().validate(
			td.points, float(width.get("fail", 90.0))
		)
		if not bool(res["ok"]):
			var msgs: Array = res["messages"]
			var first: String = str(msgs[0]) if not msgs.is_empty() else "기하 부적합"
			return {"ok": false, "status": "validation_error", "name": "",
				"message": "검증 실패: " + first}
	# 폴리라인 정규화(커스텀은 polyline 세그먼트 1개로 저장) + 로컬 새 id는 저장 시 부여.
	# 허브는 서버 경로를 그대로 쓰므로(_hub_finish_import) 기존 스냅만, 일반·에디터는 스냅 후에도
	# 베이크가 점을 더 넣지 않게 맞춘 점 열(snapped_dense_points)을 쓴다(재가져오기 라운드트립 안정).
	var pts: Array = []
	if hub:
		for p in td.points:
			pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	else:
		pts = snapped_dense_points(td.points)
	var name: String = str(dict.get("name", "")).strip_edges()
	if name.is_empty():
		name = suggested_name.strip_edges()
	if name.is_empty():
		name = "Imported"
	var track_dict: Dictionary = {
		"track_id": "",
		"name": name,
		"difficulty": str(dict.get("difficulty", "normal")),
		"fabric": str(dict.get("fabric", "cotton")),
		"width": width if not width.is_empty() else {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
		"path": [{"type": "polyline", "points": pts, "closed": false}],
		"modifiers": [],
	}
	if hub:
		return _hub_finish_import(track_dict, dict, td.length)
	return _plain_finish_import(track_dict, dict, dropped)


## 점 열을 0.1 격자로 맞추고, 격자 스냅 때문에 BAKE_INTERVAL(6px)을 넘은 구간에는 격자 위 중간점을
## 넣어 [[x, y], ...]로 반환한다. 이렇게 저장한 폴리라인은 TrackData.bake가 점을 더 넣지 않으므로
## 저장 → 불러오기 → 저장이 같은 점 열·같은 플레이 지문을 낸다(에디터 저장·일반 가져오기 공용).
static func snapped_dense_points(points: PackedVector2Array) -> Array:
	var out: Array = []
	var prev: Vector2 = Vector2.INF
	for p in points:
		var q: Vector2 = Vector2(snappedf(p.x, 0.1), snappedf(p.y, 0.1))
		if prev != Vector2.INF:
			if prev.distance_to(q) < 0.01:
				continue
			_append_dense(out, prev, q, 0)
		out.append([q.x, q.y])
		prev = q
	return out


## a→b 구간이 베이크 간격을 넘으면 격자 위 중간점을 재귀로 넣는다(a·b 자체는 넣지 않음).
static func _append_dense(out: Array, a: Vector2, b: Vector2, depth: int) -> void:
	if depth > 8 or ceili(a.distance_to(b) / TrackData.BAKE_INTERVAL) <= 1:
		return
	var m: Vector2 = Vector2(snappedf((a.x + b.x) * 0.5, 0.1), snappedf((a.y + b.y) * 0.5, 0.1))
	if m.is_equal_approx(a) or m.is_equal_approx(b):
		return
	_append_dense(out, a, m, depth + 1)
	out.append([m.x, m.y])
	_append_dense(out, m, b, depth + 1)


## 일반(비허브) 가져오기 마무리: 폭을 실수로 정규화해 보존하고, closed(어느 세그먼트든 true면
## true)를 보존하며, items를 정규화한 경로 길이 기준으로 검사해 보존한다. 제외한 필드는 note로 안내.
func _plain_finish_import(track_dict: Dictionary, dict: Dictionary, dropped: Array) -> Dictionary:
	if dict.has("width"):
		var w: Dictionary = dict["width"]
		track_dict["width"] = {
			"perfect": float(w["perfect"]), "safe": float(w["safe"]), "fail": float(w["fail"]),
		}
	var closed: bool = false
	for seg in dict.get("path", []):
		if seg is Dictionary and (seg as Dictionary).get("closed", false) == true:
			closed = true
	var path: Array = track_dict["path"]
	path[0]["closed"] = closed
	var length: float = _path_length(path)
	var fail: float = float(track_dict["width"]["fail"])
	var items: Dictionary = _check_items(dict.get("items", []), length, fail)
	if not bool(items["ok"]):
		return {"ok": false, "status": "validation_error", "name": "",
			"message": "검증 실패: " + str(items["message"])}
	track_dict["items"] = items["items"]
	var note: String = ""
	if dropped.has("modifiers"):
		var mods: Variant = dict.get("modifiers", [])
		var n: int = (mods as Array).size() if mods is Array else 1
		note = " (게임이 쓰지 않는 modifiers %d개는 지원하지 않아 제외했습니다)" % n
	return {
		"ok": true, "name": str(track_dict["name"]), "track_dict": track_dict,
		"dropped": dropped, "note": note,
	}


## 일반 가져오기 형식 검사(베이크 전 방어): 경로(_plain_path_problem), width가 있으면
## 0 < perfect < safe < fail ≤ 1000, items는 배열이고 최대 HUB_MAX_ITEMS개. 문제가 없으면 빈 문자열.
func _plain_precheck(dict: Dictionary) -> String:
	var path_bad: String = _plain_path_problem(dict.get("path", null))
	if not path_bad.is_empty():
		return path_bad
	if dict.has("width"):
		var bad: String = _hub_width_problem(dict["width"])
		if not bad.is_empty():
			return bad
	var items: Variant = dict.get("items", [])
	if not (items is Array) or (items as Array).size() > HUB_MAX_ITEMS:
		return "아이템 형식 오류"
	return ""


## 일반·에디터 가져오기 경로의 베이크 전 형식 검사. 허브 검사(_hub_path_problem)와 같은 상한(세그먼트
## HUB_MAX_SEGMENTS, 점 HUB_MAX_POINTS, 좌표 유한수·절댓값 HUB_MAX_COORD)을 쓰되 공식 파일의 bezier 세그먼트
## (p0~p3, type 생략 시 bezier)도 받는다. 원시 길이(폴리라인은 점 사이 거리, bezier는 제어 다각형 길이로
## 호길이의 상한)는 PLAIN_RAW_LEN_MAX 이하여야 한다(베이크 점 수 폭증 방지). 문제가 없으면 빈 문자열.
func _plain_path_problem(path: Variant) -> String:
	if not (path is Array) or (path as Array).is_empty() or (path as Array).size() > HUB_MAX_SEGMENTS:
		return "경로 형식 오류"
	var total: int = 0
	var raw_len: float = 0.0
	var prev: Vector2 = Vector2.INF
	for seg in path:
		var got: Variant = _plain_seg_points(seg)
		if got is String:
			return got
		var pts: Array = got
		total += pts.size()
		if total > HUB_MAX_POINTS:
			return "경로 점이 너무 많음"
		for pt in pts:
			var v: Vector2 = _hub_point(pt)
			if v == Vector2.INF:
				return "경로 좌표 형식 오류"
			if prev != Vector2.INF:
				raw_len += prev.distance_to(v)
			prev = v
	if raw_len > PLAIN_RAW_LEN_MAX:
		return "경로가 너무 김(원시 길이 %d, 상한 %d)" % [int(raw_len), int(PLAIN_RAW_LEN_MAX)]
	return ""


## 세그먼트 하나의 점(폴리라인 points 또는 bezier 제어점 p0~p3) 배열. 형식이 틀리면 사유 문자열.
func _plain_seg_points(seg: Variant) -> Variant:
	if not (seg is Dictionary):
		return "경로 형식 오류"
	var d: Dictionary = seg
	match str(d.get("type", "bezier")):
		"polyline":
			var raw: Variant = d.get("points", null)
			if not (raw is Array) or (raw as Array).size() < 2:
				return "경로 점 형식 오류"
			return raw
		"bezier":
			return [d.get("p0", null), d.get("p1", null), d.get("p2", null), d.get("p3", null)]
	return "지원하지 않는 경로 형식"


## _prepare_import의 크기 상한·JSON 파싱 단계. hub=true면 베이크 전 형식 검사(_hub_precheck)와
## 0.1 격자 스냅까지 수행한다. 성공 시 {ok=true, dict}, 실패 시 {ok=false, status, message, name=""}.
func _parse_import_text(text: String, hub: bool) -> Dictionary:
	# 크기 상한(UTF-8 바이트). 파싱 전에 방어한다.
	if text.to_utf8_buffer().size() > IMPORT_MAX_BYTES:
		var kb: int = IMPORT_MAX_BYTES / 1024
		return {"ok": false, "status": "too_large", "name": "",
			"message": "파일이 너무 큼 (%dKB 초과)" % kb}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "status": "parse_error", "name": "", "message": "JSON 파싱 실패"}
	var dict: Dictionary = parsed
	if hub:
		var bad: String = _hub_precheck(dict)
		if not bad.is_empty():
			return {"ok": false, "status": "validation_error", "name": "",
				"message": "검증 실패: " + bad}
		# 0.1 격자로 맞춘 경로를 베이크·검증·저장에 똑같이 쓴다(서버 정규화와 같은 격자).
		dict["path"] = _hub_snapped_path(dict["path"])
	return {"ok": true, "dict": dict}


## 허브 가져오기 마무리. 서버 경로는 이미 0.1 격자 폴리라인이다. 재표본화하면 길이가 미세하게
## 달라져 아이템 s가 끝을 넘을 수 있으므로 세그먼트·좌표를 그대로 보존한다(검증은 이 경로의
## 베이크 결과에 적용했고, 로컬 로드도 같은 경로를 같은 방식으로 베이크한다). items는 검사해 보존한다.
func _hub_finish_import(track_dict: Dictionary, dict: Dictionary, length: float) -> Dictionary:
	var width: Dictionary = dict["width"]
	var items: Dictionary = _check_items(dict.get("items", []), length, float(width["fail"]))
	if not bool(items["ok"]):
		return {"ok": false, "status": "validation_error", "name": "",
			"message": "검증 실패: " + str(items["message"])}
	track_dict["path"] = dict["path"]
	track_dict["width"] = {
		"perfect": float(width["perfect"]), "safe": float(width["safe"]),
		"fail": float(width["fail"]),
	}
	track_dict["items"] = items["items"]
	return {"ok": true, "name": str(track_dict["name"]), "track_dict": track_dict}


# --- 공유 허브 가져오기·게시 (계획서 §5) ---


## 공유 허브 게시물 상세를 로컬 커스텀 트랙으로 들여온다. post는 CommunityTrackClient가 형식을
## 검사한 상세 응답({post_id, title, content_hash, track}). 서버 JSON을 파일에 직접 쓰지 않고
## 플레이 필드(difficulty·fabric·width·path·items)만 추려 _prepare_import(hub=true)로 검증·정규화한
## 뒤 save_custom_track으로 저장한다(로컬 id는 항상 새 custom_ id, 서버 id는 파일명에 쓰지 않음).
## 중복 판정은 경로 체크섬이 아니라 게시물 매핑(CommunityStore) + 로컬 파일의 플레이 내용 지문이다.
## 매핑된 파일이 있고 지문과 서버 content_hash가 그대로면 재저장 없이 기존 트랙을 가리키고
## (status "duplicate"), 파일이 없거나 편집돼 지문이 다르면 매핑을 정리하고 새로 저장한다.
## 매핑 저장이 실패하면 방금 저장한 트랙을 지우고 save_failed로 보고한다(플레이 성공 처리 금지).
## 반환 dict는 import_custom_from_text와 같은 형태다.
func import_hub_track(post: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"ok": false, "status": "", "track_id": "", "name": "", "message": "",
	}
	var post_id: String = str(post.get("post_id", ""))
	var content_hash: String = str(post.get("content_hash", ""))
	var title: String = str(post.get("title", "")).strip_edges()
	var raw_track: Variant = post.get("track", null)
	if (
		not CommunityStore.is_valid_post_id(post_id)
		or content_hash.is_empty()
		or content_hash.length() > 128
		or not (raw_track is Dictionary)
	):
		out["status"] = "parse_error"
		out["message"] = "게시물 형식이 올바르지 않음"
		return out
	var track: Dictionary = raw_track
	var clean: Dictionary = {
		"name": title,
		"difficulty": track.get("difficulty", "normal"),
		"fabric": track.get("fabric", "cotton"),
		"width": track.get("width", {}),
		"path": track.get("path", []),
		"items": track.get("items", []),
	}
	var prepared: Dictionary = _prepare_import(JSON.stringify(clean), title, true)
	out["name"] = str(prepared.get("name", ""))
	if not bool(prepared["ok"]):
		out["status"] = str(prepared["status"])
		out["message"] = str(prepared["message"])
		return out
	var downloads: Dictionary = CommunityStore.load_downloads()
	var stale: bool = false
	if downloads.has(post_id):
		var entry: Dictionary = downloads[post_id]
		var local_id: String = str(entry["track_id"])
		if (
			str(entry["content_hash"]) == content_hash
			and custom_track_fingerprint(local_id) == str(entry["fingerprint"])
		):
			out["ok"] = true
			out["status"] = "duplicate"
			out["track_id"] = local_id
			out["message"] = "이미 받은 트랙: " + str(out["name"])
			return out
		# 로컬 파일이 지워졌거나 편집돼 내용이 달라졌다 → 매핑을 정리하고 새로 저장한다.
		downloads.erase(post_id)
		stale = true
	var id: String = save_custom_track(prepared["track_dict"])
	if id.is_empty():
		if stale:
			CommunityStore.save_downloads(downloads)
		out["status"] = "save_failed"
		out["message"] = "저장 실패"
		return out
	var fingerprint: String = custom_track_fingerprint(id)
	downloads[post_id] = {
		"track_id": id,
		"content_hash": content_hash,
		"fingerprint": fingerprint,
		"title": title.substr(0, CommunityStore.TITLE_MAX),
		"downloaded_at": Time.get_datetime_string_from_system(true),
	}
	if fingerprint.is_empty() or not CommunityStore.save_downloads(downloads):
		delete_custom_track(id)
		out["status"] = "save_failed"
		out["message"] = "저장 실패 (다운로드 기록을 쓰지 못함)"
		return out
	out["ok"] = true
	out["status"] = "ok"
	out["track_id"] = id
	out["message"] = "'%s' 트랙을 받았습니다" % str(out["name"])
	return out


## 허브에서 받은 뒤 편집하지 않은 트랙이면 true(매핑이 있고 로컬 지문이 그대로). 트랙 선택
## 화면이 이 트랙에 "공유 허브에 게시" 버튼을 주지 않는 데 쓴다(편집한 사본은 false).
func is_unmodified_hub_download(track_id: String) -> bool:
	var post_id: String = CommunityStore.post_for_local(track_id)
	if post_id.is_empty():
		return false
	var entry: Dictionary = CommunityStore.download_entry(post_id)
	var fp: String = custom_track_fingerprint(track_id)
	return not fp.is_empty() and fp == str(entry.get("fingerprint", ""))


## 커스텀 트랙 파일의 플레이 내용 지문(파일이 없거나 파싱 실패면 빈 문자열).
func custom_track_fingerprint(track_id: String) -> String:
	var text: String = read_custom_track_text(track_id)
	if text.is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return ""
	return play_fingerprint(parsed)


## 플레이에 영향을 주는 내용(difficulty·fabric·width·path·items)을 로컬에서 일관된 문자열로
## 직렬화한 SHA-256. 좌표는 0.1, 폭·아이템 수치는 0.001 단위로 고정 표기하고 아이템은 정렬한다.
## 서버 content_hash와는 계산 방식이 다르며 비교하지 않는다(로컬 파일 편집 감지 전용).
static func play_fingerprint(d: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("difficulty=" + str(d.get("difficulty", "")))
	parts.append("fabric=" + str(d.get("fabric", "")))
	var w: Variant = d.get("width", {})
	var wd: Dictionary = w if w is Dictionary else {}
	parts.append(
		"width=%.3f,%.3f,%.3f"
		% [_num(wd.get("perfect", 0)), _num(wd.get("safe", 0)), _num(wd.get("fail", 0))]
	)
	var path: Variant = d.get("path", [])
	if path is Array:
		for seg in path:
			if not (seg is Dictionary):
				parts.append("seg=?")
				continue
			var seg_d: Dictionary = seg
			var buf: String = "seg=%s,%s:" % [str(seg_d.get("type", "")), str(seg_d.get("closed", false))]
			var pts: Variant = seg_d.get("points", [])
			if pts is Array:
				for pt in pts:
					if pt is Array and (pt as Array).size() >= 2:
						buf += "%.1f,%.1f;" % [_num(pt[0]), _num(pt[1])]
			parts.append(buf)
	var items: Array = []
	var raw_items: Variant = d.get("items", [])
	if raw_items is Array:
		for it in raw_items:
			if it is Dictionary:
				items.append(
					"%.3f|%.3f|%s" % [_num(it.get("s", 0)), _num(it.get("lat", 0)), str(it.get("type", ""))]
				)
	items.sort()
	parts.append("items=" + ";".join(PackedStringArray(items)))
	return "fp1:" + "\n".join(parts).sha256_text()


static func _num(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	return 0.0


## 허브 상세 track의 경로를 미리보기용으로 베이크한다(형식·크기 검사를 통과하지 못하면 빈 배열).
## 파일에 저장하지 않는다.
func hub_preview_points(track: Dictionary) -> PackedVector2Array:
	var path: Variant = track.get("path", null)
	if not _hub_path_problem(path).is_empty():
		return PackedVector2Array()
	var td: TrackData = TrackData.new()
	td.bake(_hub_snapped_path(path))
	return td.points


## 로컬 커스텀 트랙을 공유 허브 게시용 track(서버가 허용하는 필드만)으로 만든다. 로드·베이크·
## TrackValidator 검증을 통과한 저장본만 게시할 수 있다. 반환 {ok, message, track, name}.
## track_id·name·checksum·length 같은 로컬 메타와 아이템의 추가 키(respawn 등)는 싣지 않는다.
func build_publish_track(track_id: String) -> Dictionary:
	var fail_out: Dictionary = {"ok": false, "message": "", "track": {}, "name": ""}
	if not track_id.begins_with(CUSTOM_PREFIX):
		fail_out["message"] = "공식 트랙은 게시할 수 없습니다"
		return fail_out
	var text: String = read_custom_track_text(track_id)
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not (parsed is Dictionary):
		fail_out["message"] = "트랙 파일을 읽지 못했습니다"
		return fail_out
	var dict: Dictionary = parsed
	var bad: String = _hub_precheck(dict)
	if not bad.is_empty():
		fail_out["message"] = "게시할 수 없는 트랙: " + bad
		return fail_out
	var path: Array = _hub_snapped_path(dict["path"])
	var td: TrackData = TrackData.new()
	td.bake(path)
	var width: Dictionary = dict["width"]
	var fail: float = float(width["fail"])
	var res: Dictionary = TrackValidator.new().validate(td.points, fail)
	if not bool(res["ok"]):
		var msgs: Array = res["messages"]
		fail_out["message"] = "검증 실패: " + (str(msgs[0]) if not msgs.is_empty() else "기하 부적합")
		return fail_out
	var items: Dictionary = _check_items(dict.get("items", []), td.length, fail)
	if not bool(items["ok"]):
		fail_out["message"] = "게시할 수 없는 트랙: " + str(items["message"])
		return fail_out
	# 서버는 s ≤ 베이크 길이 − 0.5 만 받는다. 끝점 0.5px 안의 아이템은 게시 payload에서만 그 값으로
	# 맞춰 422를 피한다(로컬 파일·허브 다운로드 보존 동작은 그대로).
	var s_max: float = maxf(0.0, td.length - PUBLISH_S_MARGIN)
	for it in items["items"]:
		it["s"] = minf(float(it["s"]), s_max)
	var track: Dictionary = {
		"difficulty": str(dict.get("difficulty", "normal")),
		"fabric": str(dict.get("fabric", "cotton")),
		"width": {"perfect": float(width["perfect"]), "safe": float(width["safe"]), "fail": fail},
		"path": path,
		"items": items["items"],
		"modifiers": [],
		"editor_version": EDITOR_VERSION,
	}
	return {"ok": true, "message": "", "track": track, "name": str(dict.get("name", "")).strip_edges()}


## 허브 경로·폭·아이템의 형식과 크기 검사(베이크 전 방어). 문제가 없으면 빈 문자열, 있으면 사유.
## 폴리라인 세그먼트만, 점 합계 ≤ HUB_MAX_POINTS, 좌표는 유한수·절댓값 ≤ HUB_MAX_COORD,
## 원시 길이 ≤ 하드 상한 + 1(베이크 점 폭증 방지). 폭은 0 < perfect < safe < fail ≤ 1000.
## 난이도·재질은 에디터·서버가 지원하는 목록만 허용한다.
func _hub_precheck(dict: Dictionary) -> String:
	var bad: String = _hub_path_problem(dict.get("path", null))
	if bad.is_empty():
		bad = _hub_width_problem(dict.get("width", null))
	if bad.is_empty() and not HUB_DIFFICULTIES.has(dict.get("difficulty", "normal")):
		bad = "지원하지 않는 난이도"
	if bad.is_empty() and not HUB_FABRICS.has(dict.get("fabric", "cotton")):
		bad = "지원하지 않는 재질"
	var items: Variant = dict.get("items", [])
	if bad.is_empty() and (not (items is Array) or (items as Array).size() > HUB_MAX_ITEMS):
		bad = "아이템 형식 오류"
	return bad


func _hub_path_problem(path: Variant) -> String:
	if not (path is Array) or (path as Array).is_empty() or (path as Array).size() > HUB_MAX_SEGMENTS:
		return "경로 형식 오류"
	var total: int = 0
	for seg in path:
		if not (seg is Dictionary) or str((seg as Dictionary).get("type", "")) != "polyline":
			return "폴리라인 경로만 지원"
		var pts: Variant = (seg as Dictionary).get("points", null)
		if not (pts is Array) or (pts as Array).size() < 2:
			return "경로 점 형식 오류"
		total += (pts as Array).size()
	if total > HUB_MAX_POINTS:
		return "경로 점이 너무 많음"
	return _hub_points_problem(path)


## 모든 점의 좌표 형식·범위와 원시 길이(베이크 전) 상한 검사.
func _hub_points_problem(path: Array) -> String:
	var raw_len: float = 0.0
	var prev: Vector2 = Vector2.INF
	for seg in path:
		for pt in (seg as Dictionary)["points"]:
			var v: Vector2 = _hub_point(pt)
			if v == Vector2.INF:
				return "경로 좌표 형식 오류"
			if prev != Vector2.INF:
				raw_len += prev.distance_to(v)
			prev = v
	if raw_len > TrackValidator.LEN_HARD_MAX + 1.0:
		return "길이 %dpx: 상한 %dpx 초과" % [int(raw_len), int(TrackValidator.LEN_HARD_MAX)]
	return ""


## [x, y] 유한수·범위 검사 후 Vector2(형식 오류면 Vector2.INF).
func _hub_point(pt: Variant) -> Vector2:
	if not (pt is Array) or (pt as Array).size() != 2:
		return Vector2.INF
	if not _is_num(pt[0]) or not _is_num(pt[1]):
		return Vector2.INF
	var x: float = float(pt[0])
	var y: float = float(pt[1])
	if absf(x) > HUB_MAX_COORD or absf(y) > HUB_MAX_COORD:
		return Vector2.INF
	return Vector2(x, y)


func _hub_width_problem(w: Variant) -> String:
	if not (w is Dictionary):
		return "폭 형식 오류"
	var wd: Dictionary = w
	for key in ["perfect", "safe", "fail"]:
		if not _is_num(wd.get(key, null)) or float(wd[key]) <= 0.0 or float(wd[key]) > 1000.0:
			return "폭 형식 오류"
	if not (float(wd["perfect"]) < float(wd["safe"]) and float(wd["safe"]) < float(wd["fail"])):
		return "폭 순서 오류"
	return ""


## 폴리라인 세그먼트들을 0.1 격자로 맞춘 새 배열(세그먼트 경계·closed 보존). _hub_precheck 통과 전제.
func _hub_snapped_path(path: Array) -> Array:
	var out: Array = []
	for seg in path:
		var seg_d: Dictionary = seg
		var pts: Array = []
		for pt in seg_d["points"]:
			pts.append([snappedf(float(pt[0]), 0.1), snappedf(float(pt[1]), 0.1)])
		out.append({"type": "polyline", "points": pts, "closed": seg_d.get("closed", false) == true})
	return out


## 아이템 검사·정규화(허브·일반 가져오기·게시 공용): {s, type, lat}만 남긴다. type은 HUB_ITEM_TYPES,
## s는 0..length(float32 베이크 길이와 서버 float64 길이 차이는 HUB_S_SLACK 안에서만 length로 맞춤),
## |lat| ≤ fail. 반환 {ok, message, items}.
func _check_items(raw: Variant, length: float, fail: float) -> Dictionary:
	var out: Array = []
	if not (raw is Array):
		return {"ok": false, "message": "아이템 형식 오류", "items": []}
	for it in raw:
		if not (it is Dictionary):
			return {"ok": false, "message": "아이템 형식 오류", "items": []}
		var d: Dictionary = it
		var type: String = str(d.get("type", ""))
		if not HUB_ITEM_TYPES.has(type):
			return {"ok": false, "message": "지원하지 않는 아이템: " + type.substr(0, 32), "items": []}
		var lat_v: Variant = d.get("lat", 0.0)
		if not _is_num(d.get("s", null)) or not _is_num(lat_v):
			return {"ok": false, "message": "아이템 값 형식 오류", "items": []}
		var s: float = float(d["s"])
		var lat: float = float(lat_v)
		if s < 0.0 or s > length + HUB_S_SLACK or absf(lat) > fail:
			return {"ok": false, "message": "아이템 위치가 트랙 범위를 벗어남", "items": []}
		out.append({"s": minf(s, length), "type": type, "lat": lat})
	return {"ok": true, "message": "", "items": out}


static func _is_num(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


## 커스텀 트랙 파일의 원본 JSON 텍스트를 그대로 읽는다(내보내기용). 없으면 빈 문자열.
func read_custom_track_text(track_id: String) -> String:
	if not track_id.begins_with(CUSTOM_PREFIX):
		return ""
	var path: String = CUSTOM_DIR + track_id + ".json"
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


## 트랙명을 파일명에 안전한 형태로 정규화한다(내보내기 파일명 <name>_<id>.json 구성).
## 파일시스템 금지문자·공백만 _로 치환하고 유니코드 글자(한글 등)는 보존한다. 최대 40자.
static func sanitize_filename(name: String) -> String:
	var trimmed: String = name.strip_edges()
	var unsafe: String = "/\\:*?\"<>|"
	var buf: String = ""
	for ch in trimmed:
		if ch == " " or unsafe.contains(ch) or ch.unicode_at(0) < 32:
			buf += "_"
		else:
			buf += ch
	buf = buf.strip_edges()
	if buf.is_empty():
		return "track"
	return buf.substr(0, 40)


func _ensure_custom_dir() -> void:
	if not DirAccess.dir_exists_absolute(CUSTOM_DIR):
		DirAccess.make_dir_recursive_absolute(CUSTOM_DIR)


## 파일에서 헤더 필드만 파싱(전체 bake 없이 목록 표시용).
func _read_header(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var dict: Dictionary = parsed
	if not dict.has("track_id"):
		return {}
	return {
		"track_id": str(dict.get("track_id", "")),
		"name": str(dict.get("name", "")),
		"difficulty": str(dict.get("difficulty", "normal")),
		"checksum": str(dict.get("checksum", "")),
		"is_custom": true,
	}


## 기존 커스텀 파일과 충돌하지 않는 새 custom_<8hex> id.
func _new_custom_id() -> String:
	_ensure_custom_dir()
	for _try in range(64):
		var id: String = "%s%08x" % [CUSTOM_PREFIX, randi()]
		if not FileAccess.file_exists(CUSTOM_DIR + id + ".json"):
			return id
	# 극히 드문 충돌: 시간 기반 폴백.
	return "%s%08x" % [CUSTOM_PREFIX, int(Time.get_unix_time_from_system()) & 0xffffffff]


## 경로 좌표(polyline points)의 SHA-256. import 중복 감지·후속 서버 대비.
func compute_checksum(path_json: Array) -> String:
	var buf: String = ""
	for seg in path_json:
		var seg_dict: Dictionary = seg
		for pt in seg_dict.get("points", []):
			var arr: Array = pt
			buf += "%.1f,%.1f;" % [float(arr[0]), float(arr[1])]
	return "sha256:" + buf.sha256_text()


func _path_length(path_json: Array) -> float:
	var total: float = 0.0
	for seg in path_json:
		var seg_dict: Dictionary = seg
		var prev: Vector2 = Vector2.INF
		for pt in seg_dict.get("points", []):
			var arr: Array = pt
			var v: Vector2 = Vector2(float(arr[0]), float(arr[1]))
			if prev != Vector2.INF:
				total += prev.distance_to(v)
			prev = v
	return total


## 트랙 파일을 읽어 JSON dict로 반환한다(없거나 파싱 실패면 빈 dict).
func _read_track_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("TrackLoader: 트랙 파일 없음 " + path)
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TrackLoader: 트랙 파일 열기 실패 " + path)
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or (parsed as Dictionary).is_empty():
		push_error("TrackLoader: 트랙 JSON 파싱 실패 " + path)
		return {}
	return parsed


func _build_track(dict: Dictionary) -> TrackData:
	var track: TrackData = TrackData.new()
	track.track_id = str(dict.get("track_id", ""))
	track.track_name = str(dict.get("name", ""))
	track.difficulty = str(dict.get("difficulty", "normal"))
	track.fabric = str(dict.get("fabric", ""))
	var width: Dictionary = dict.get("width", {})
	track.perfect = float(width.get("perfect", 18.0))
	track.safe = float(width.get("safe", 42.0))
	track.fail = float(width.get("fail", 90.0))
	var path_json: Array = dict.get("path", [])
	track.bake(path_json)
	track.modifiers = dict.get("modifiers", [])  # MVP는 파싱만, 시뮬레이션에는 미반영
	# 필드 아이템(v1.1.0). 스키마 [{"s","type","lat"}], lat 기본 0(소비 측에서 적용), respawn은
	# 미래용이라 무시. 원본을 그대로 싣고 RaceDirector가 고정 틱에서 소비한다.
	track.items = dict.get("items", [])
	return track
