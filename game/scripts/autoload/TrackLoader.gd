extends Node
## 트랙 JSON 로드 → TrackData 베이크, id별 캐시 오토로드 (아키텍처 §5).
##
## 재시작 시 재베이크를 피하기 위해 track_id로 캐시한다.
## 트랙 목록은 웹 export에서 DirAccess 디렉토리 나열이 불안정하므로 디렉토리
## 스캔 대신 index.json 매니페스트(파일 목록·순서)로 관리한다.

const OFFICIAL_DIR: String = "res://tracks/official/"
const MANIFEST_PATH: String = "res://tracks/official/index.json"
# 커스텀(유저 자작) 트랙: 쓰기 가능한 user:// 아래. 웹(IDBFS) 포함 전 플랫폼 영속.
# 공식 id(cotton_01…)와 custom_ 접두로 네임스페이스 완전 분리(레코드·로드 충돌 없음).
const CUSTOM_DIR: String = "user://tracks/custom/"
const CUSTOM_PREFIX: String = "custom_"
const EDITOR_VERSION: String = "0.1.0"

# 매니페스트 로드 실패 시에도 게임이 동작하도록 두는 최소 폴백(기본 트랙).
const FALLBACK_TRACKS: Array = [
	{"track_id": "cotton_01", "name": "Cotton Warm-up", "difficulty": "normal"},
]

var _cache: Dictionary = {}
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
		path = OFFICIAL_DIR + track_id + ".json"
	var data: TrackData = _load_from_file(path)
	if data != null:
		_cache[track_id] = data
	return data


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


func _load_from_file(path: String) -> TrackData:
	if not FileAccess.file_exists(path):
		push_error("TrackLoader: 트랙 파일 없음 " + path)
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TrackLoader: 트랙 파일 열기 실패 " + path)
		return null
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("TrackLoader: 트랙 JSON 파싱 실패 " + path)
		return null
	var dict: Dictionary = parsed
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
	return track
