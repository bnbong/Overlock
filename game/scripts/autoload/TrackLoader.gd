extends Node
## 트랙 JSON 로드 → TrackData 베이크, id별 캐시 오토로드 (아키텍처 §5).
##
## 재시작 시 재베이크를 피하기 위해 track_id로 캐시한다.
## 트랙 목록은 웹 export에서 DirAccess 디렉토리 나열이 불안정하므로 디렉토리
## 스캔 대신 index.json 매니페스트(파일 목록·순서)로 관리한다.

const OFFICIAL_DIR: String = "res://tracks/official/"
const MANIFEST_PATH: String = "res://tracks/official/index.json"

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


## 트랙 id 목록만 순서대로 반환한다(편의 API).
func track_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	for entry in list_tracks():
		ids.append(str(entry.get("track_id", "")))
	return ids


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


func load_track(track_id: String) -> TrackData:
	if _cache.has(track_id):
		return _cache[track_id]
	var path: String = OFFICIAL_DIR + track_id + ".json"
	var data: TrackData = _load_from_file(path)
	if data != null:
		_cache[track_id] = data
	return data


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
