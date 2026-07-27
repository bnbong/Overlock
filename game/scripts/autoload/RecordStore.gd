extends Node
## 로컬 최고 기록 저장/조회 오토로드 (아키텍처 §3).
##
## user://records.json 에 "track_id|difficulty" -> 결과 dict 형태로 보관하고,
## final_time_ms 기준으로 신기록을 판정한다.

const SAVE_PATH: String = "user://records.json"

var _data: Dictionary = {}


func _ready() -> void:
	_load()


func best_for(id: String, diff: String) -> Dictionary:
	return _data.get(_key(id, diff), {})


## 신기록이면서 디스크 저장까지 성공했을 때만 true 반환.
func submit(result: Dictionary) -> bool:
	var key: String = _key(str(result.get("track_id", "")), str(result.get("difficulty", "")))
	var prev: Dictionary = _data.get(key, {})
	var new_time: int = int(result.get("final_time_ms", 0))
	var is_best: bool = prev.is_empty() or new_time < int(prev.get("final_time_ms", 0))
	if not is_best:
		return false
	_data[key] = result.duplicate(true)
	if _save():
		return true
	# 저장 실패: 인메모리 갱신을 되돌려 신기록 표시와 실제 저장 상태를 일치시킨다.
	if prev.is_empty():
		_data.erase(key)
	else:
		_data[key] = prev
	return false


func _key(id: String, diff: String) -> String:
	return id + "|" + diff


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		_data = parsed


## 저장 성공 여부를 반환한다.
func _save() -> bool:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("RecordStore: 저장 실패 " + SAVE_PATH)
		return false
	file.store_string(JSON.stringify(_data))
	file.close()
	return true
