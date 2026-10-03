extends Node
## 로컬 최고 기록·개인 고스트 연결 저장 오토로드 (docs/architecture.md §3.1~§3.3).
##
## 개인 최고 키는 "track_id|difficulty" 하나다. 같은 키 안에서 재봉 등급(S>A>B>C>D)이 높으면 신기록이고,
## 같은 등급이면 final_time_ms(패널티 포함)가 더 작을 때 신기록이다(온라인 리더보드 정렬과 같은 의미).
## 같은 등급·같은 시간이면 기존 기록을 유지한다(is_better). 원단 물리 등 게임 규칙이 바뀌어도 기록을 규칙별로 나누지
## 않는다. 개발용 res://data/tuning.json이 물리에 쓰이는 Tuning 값을 실제로 바꾸면(is_practice) 정식
## 기록과 섞지 않도록 "track_id|difficulty|practice" 키로 따로 저장한다.
##
## track_fingerprint(TrackLoader.track_fingerprint: 베이크 점 열·닫힘·폭·재질·아이템 순서)는 고스트 유효성
## 판정에만 쓴다. 기록 엔트리에 저장된 지문이 현재 트랙 지문과 다르면(트랙을 편집한 경우) 기록은 그대로
## 최고로 두고 그 기록의 고스트만 비활성화한다(STATE_TRACK_CHANGED). 개인 최고를 갱신하면 새 지문으로
## 새 고스트가 생긴다.
##
## records.json(FORMAT_VERSION 2): {"format_version": 2, "records": {key: entry}}. 엔트리는 결과 dict에
## track_fingerprint·ghost_run_id·ghost_file·ghost_note·practice·saved_at을 더한 것이다. 형식 버전이 없는
## 예전 파일(v1, "id|diff" → 결과)은 records.json.bak으로 복사한 뒤 그 기록을 그대로 현재 최고로 옮긴다
## (고스트 참조 필드만 비어 있다). 백업 성공이 교체의 선행조건이며, 실패하면 원본을 두고 메모리 읽기만 한다.
## 읽을 수 없거나 미지원 버전인 파일은 빈 저장소로 읽되 처음 쓰기 전에 .bak으로 옮겨 보존한다.
##
## 저장 순서(submit_run): 새 고스트 임시 파일 → 검사 → 교체 → 기록 엔트리에 run_id·파일 연결 →
## records.json 임시 → 교체 → 그 뒤에만 이전 고스트 삭제. 기록 저장이 실패하면 메모리를 되돌리고 방금 쓴
## 고스트를 지운다(기존 최고·고스트 유지). 고아 고스트 파일은 다음 실행(_ready)에서 정리한다.

const SAVE_PATH: String = "user://records.json"
const SETTINGS_PATH: String = "user://ghost_settings.json"
const FORMAT_VERSION: int = 2
const PRACTICE_SUFFIX: String = "practice"
## 등급 문자 → 비교 티어(클수록 상위). 서버 grade.py의 _LETTER_TIER와 같은 순서다.
const GRADE_TIERS: Dictionary = {"S": 5, "A": 4, "B": 3, "C": 2, "D": 1}
const TUNING_OVERRIDE_PATH: String = "res://data/tuning.json"
## practice 판정에서 비교하는 Tuning 키: PlayerController·RaceDirector가 물리·판정에 실제로 읽는 키다.
## steer_expo는 시작 시 LeaderboardClient가 사용자 설정값으로 덮어 tuning.json 값이 쓰이지 않고(허용된
## 사용자 선택), speed_table은 _load_overrides가 오버라이드하지 않으므로 뺀다. foot_response_rate처럼
## 소비되지 않는 키는 바꿔도 물리가 같으므로 practice가 아니다. 소비 코드가 새 키를 읽으면 여기에 더한다
## (tools/ghost_regression이 두 파일의 Tuning.<키> 참조가 이 목록에 있는지 확인한다).
const PHYSICS_TUNING_KEYS: Array[String] = [
	"min_speed", "max_speed", "speed_step_count", "steer_charge_rate", "steer_return_rate",
	"steer_tau", "steer_reversal_boost", "steer_soft_p", "turn_power", "steer_speed_floor",
	"risk_gain_rate", "risk_recover_rate", "danger_threshold", "risk_speed_exp",
	"risk_proximity_base", "risk_static_bias", "stun_duration", "cut_windup_duration",
	"stun_steer_return_rate", "reset_lockout", "drift_turn_mult", "drift_static_bias",
	"drift_proximity", "thimble_duration", "autopilot_duration", "autopilot_handoff_curvature",
	"autopilot_handoff_max_grace", "item_pickup_radius",
]
# 결과 dict에서 기록 엔트리로 옮기지 않는 화면 전용 키.
const TRANSIENT_KEYS: Array[String] = [
	"is_new_record", "editor_test", "ghost_status", "ghost_reason", "prev_best_ms",
	"ghost_track_changed", "prev_best_grade",
]
# submit_run의 ghost_status 값.
const GHOST_SAVED: String = "saved"
const GHOST_FAILED: String = "failed"
const GHOST_NONE: String = "none"
const GHOST_UNCHANGED: String = "unchanged"
# ghost_state 값(트랙 선택 화면 문구용).
const STATE_READY: String = "ready"
const STATE_NO_RECORD: String = "no_record"
const STATE_NO_GHOST: String = "no_ghost"
const STATE_TRACK_CHANGED: String = "track_changed"

## 읽기 결과: missing | ok | migrated | migrated_readonly | corrupt | version | unreadable(검사·표시용).
## migrated_readonly는 v1 백업에 실패해 원본을 그대로 두고 메모리 읽기만 하는 상태다(다음 기동에 재시도).
var load_state: String = "missing"

var _records: Dictionary = {}
var _ghost_enabled: bool = true
var _override_state: int = -1  # -1 미판정, 0 정식, 1 practice
var _preserve_before_save: bool = false
# 원본을 덮으면 안 되는 상태(v1 백업 실패·일시 읽기 실패)에서는 이번 실행의 기록 쓰기를 보류한다.
var _writes_blocked: bool = false


func _ready() -> void:
	_load()
	_load_settings()
	# 참조 목록을 정상으로 읽었다고 확정한 경우(ok)에만 고아 고스트를 정리한다. 손상·미지원 버전·
	# 읽기 실패·마이그레이션 직후·백업 실패 상태에서 정리하면 유효한 고스트까지 지울 수 있다.
	if load_state == "ok":
		GhostStore.cleanup_orphans(_referenced_ghosts())


# --- practice·지문 ---


## 개발용 튜닝 오버라이드가 물리에 쓰이는 값을 실제로 바꾸는가(연습 기록으로 따로 저장).
func is_practice() -> bool:
	if _override_state < 0:
		_override_state = 1 if _detect_tuning_override() else 0
	return _override_state == 1


func fingerprint_for(track_id: String) -> String:
	return TrackLoader.track_fingerprint(track_id)


static func record_key(id: String, diff: String, practice: bool = false) -> String:
	return "%s|%s|%s" % [id, diff, PRACTICE_SUFFIX] if practice else "%s|%s" % [id, diff]


# --- 조회 ---


## 개인 최고 기록(없으면 빈 dict). practice 실행이면 연습 기록을 돌려준다.
func best_for(id: String, diff: String) -> Dictionary:
	return _records.get(record_key(id, diff, is_practice()), {})


## 트랙 선택 화면용 고스트 상태(STATE_*). 고스트가 있는데 기록 당시 지문이 현재 트랙과 다르면
## STATE_TRACK_CHANGED(기록은 유지, 고스트만 비활성).
func ghost_state(id: String, diff: String) -> String:
	var best: Dictionary = best_for(id, diff)
	if best.is_empty():
		return STATE_NO_RECORD
	var path: String = str(best.get("ghost_file", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		return STATE_NO_GHOST
	if not _same_track(best, id):
		return STATE_TRACK_CHANGED
	return STATE_READY


## 개인 최고 기록의 고스트를 읽는다. 반환 {ok, run(GhostRun 또는 null), reason}.
## reason: no_record | no_ghost | track_changed | GhostStore.R_*.
func load_ghost(id: String, diff: String) -> Dictionary:
	var best: Dictionary = best_for(id, diff)
	if best.is_empty():
		return {"ok": false, "run": null, "reason": STATE_NO_RECORD}
	var path: String = str(best.get("ghost_file", ""))
	if path.is_empty():
		return {"ok": false, "run": null, "reason": STATE_NO_GHOST}
	if not _same_track(best, id):
		return {"ok": false, "run": null, "reason": STATE_TRACK_CHANGED}
	var expect: Dictionary = {
		"track_id": id,
		"difficulty": diff,
		"track_fingerprint": fingerprint_for(id),
		"run_id": str(best.get("ghost_run_id", "")),
		"final_time_ms": int(best.get("final_time_ms", 0)),
	}
	return GhostStore.load_checked(path, expect)


## 기록 엔트리의 지문이 현재 트랙 지문과 같은가(트랙을 편집하지 않았는가).
func _same_track(entry: Dictionary, id: String) -> bool:
	var fp: String = fingerprint_for(id)
	return not fp.is_empty() and str(entry.get("track_fingerprint", "")) == fp


## 개인 최고 기록이 있고 고스트를 가졌는데 기록 당시 트랙과 지금 트랙이 다른가(결과 화면 안내용).
func track_changed_since_best(id: String, diff: String) -> bool:
	return ghost_state(id, diff) == STATE_TRACK_CHANGED


# --- 저장 ---


## 하위 호환 진입점: 고스트 없이 기록만 제출한다. 신기록이면서 디스크 저장까지 성공했을 때만 true.
func submit(result: Dictionary) -> bool:
	return bool(submit_run(result)["is_best"])


## 완주 결과(+고스트)를 제출한다. result에 track_fingerprint가 없으면 현재 트랙 지문으로 채운다.
## 신기록 판정은 지문과 무관하게 같은 키(track_id|difficulty, practice면 |practice)의 기록과 비교한다.
## ghost는 GhostRun.to_ghost 결과(빈 dict면 고스트 없음), ghost_skip은 고스트를 만들지 못한 사유.
## 반환 {is_best, ghost_status(saved|failed|none|unchanged), ghost_reason}.
func submit_run(result: Dictionary, ghost: Dictionary = {}, ghost_skip: String = "") -> Dictionary:
	var out: Dictionary = {"is_best": false, "ghost_status": GHOST_UNCHANGED, "ghost_reason": ""}
	var id: String = str(result.get("track_id", ""))
	var diff: String = str(result.get("difficulty", ""))
	var practice: bool = bool(result.get("practice", is_practice()))
	var fp: String = str(result.get("track_fingerprint", fingerprint_for(id)))
	if id.is_empty() or fp.is_empty():
		out["ghost_reason"] = "no_fingerprint"
		return out
	var key: String = record_key(id, diff, practice)
	var prev: Dictionary = _records.get(key, {})
	if not is_better(result, prev):
		out["ghost_reason"] = "not_best"
		return out
	var entry: Dictionary = _entry_from(result, practice, fp)
	var new_path: String = _write_entry_ghost(entry, ghost, ghost_skip, out)
	_records[key] = entry
	if not _save():
		if prev.is_empty():
			_records.erase(key)
		else:
			_records[key] = prev
		GhostStore.remove(new_path)
		out["ghost_status"] = GHOST_UNCHANGED
		out["ghost_reason"] = "record_save_failed"
		return out
	out["is_best"] = true
	var old_path: String = str(prev.get("ghost_file", ""))
	if not old_path.is_empty() and old_path != new_path:
		GhostStore.remove(old_path)
	return out


## track_id에 걸린 모든 기록(정식·연습)을 지우고 연결된 고스트 파일도 정리한다
## (커스텀 트랙 삭제, §7.4). 지운 항목이 있으면서 저장까지 성공했을 때만 true. 저장 실패면 되돌린다.
func purge(track_id: String) -> bool:
	var prefix: String = track_id + "|"
	var saved_records: Dictionary = _records.duplicate(true)
	var ghost_paths: Array = []
	for key in _records.keys():
		if str(key).begins_with(prefix):
			ghost_paths.append(str(_records[key].get("ghost_file", "")))
			_records.erase(key)
	if _records.size() == saved_records.size():
		return false
	if not _save():
		_records = saved_records
		return false
	for p in ghost_paths:
		GhostStore.remove(p)
	return true


## 기록의 재봉 등급 문자. 완주 때 RunStats.finalize가 저장한 grade를 쓰고, 없으면(예전 기록) 저장된
## accuracy·perfect_rate·cuts로 RunStats.grade_from_metrics(서버 grade.py와 같은 식·임계값)를 계산한다.
## 어느 쪽도 없으면 빈 문자열.
static func grade_of(entry: Dictionary) -> String:
	var g: String = str(entry.get("grade", ""))
	if GRADE_TIERS.has(g):
		return g
	for k in ["accuracy", "perfect_rate", "cuts"]:
		var v: Variant = entry.get(k)
		if not (v is int or v is float):
			return ""
	return RunStats.grade_from_metrics(
		float(entry["accuracy"]), float(entry["perfect_rate"]), int(entry["cuts"])
	)


## new가 prev보다 나은 개인 최고인가: 등급이 높으면 참, 같은 등급이면 final_time_ms가 작을 때 참(동률은
## 기존 유지). prev가 비면 참. 한쪽 등급을 알 수 없으면 기존 기록을 유지하되, 둘 다 모르면 시간만 비교한다.
static func is_better(new: Dictionary, prev: Dictionary) -> bool:
	if prev.is_empty():
		return true
	var tn: int = int(GRADE_TIERS.get(grade_of(new), 0))
	var tp: int = int(GRADE_TIERS.get(grade_of(prev), 0))
	if (tn == 0) != (tp == 0):
		return false
	if tn != tp:
		return tn > tp
	return int(new.get("final_time_ms", 0)) < int(prev.get("final_time_ms", 0))


## 커스텀 트랙 삭제 전 정리용. 지울 기록이 없거나 지우고 저장까지 성공하면 true, 저장에 실패하면
## false(기록·고스트 유지). 트랙 선택 화면은 true일 때만 트랙 파일을 지운다.
func purge_for_delete(track_id: String) -> bool:
	var prefix: String = track_id + "|"
	var any: bool = false
	for key in _records.keys():
		if str(key).begins_with(prefix):
			any = true
			break
	return not any or purge(track_id)


# --- 고스트 표시 설정 ---


func ghost_enabled() -> bool:
	return _ghost_enabled


## 트랙 선택 화면의 "개인 고스트" 토글. user://ghost_settings.json에 영속한다. 저장 성공 여부를 반환한다.
func set_ghost_enabled(value: bool) -> bool:
	_ghost_enabled = value
	var text: String = JSON.stringify({"version": 1, "ghost_enabled": value})
	return GhostStore.write_atomic(SETTINGS_PATH, text, "ghost_settings")


# --- 내부 ---


func _entry_from(result: Dictionary, practice: bool, fp: String) -> Dictionary:
	var entry: Dictionary = result.duplicate(true)
	for k in TRANSIENT_KEYS:
		entry.erase(k)
	entry.erase("physics_ruleset")
	entry["practice"] = practice
	var grade: String = grade_of(entry)
	if not grade.is_empty():
		entry["grade"] = grade
	entry["track_fingerprint"] = fp
	entry["ghost_run_id"] = ""
	entry["ghost_file"] = ""
	entry["ghost_note"] = ""
	entry["saved_at"] = Time.get_datetime_string_from_system(true)
	return entry


## 엔트리에 고스트를 연결한다(저장 성공 시 run_id·파일, 실패·없음이면 사유). 새 파일 경로를 반환한다.
func _write_entry_ghost(
	entry: Dictionary, ghost: Dictionary, skip: String, out: Dictionary
) -> String:
	if ghost.is_empty():
		out["ghost_status"] = GHOST_FAILED if not skip.is_empty() else GHOST_NONE
		out["ghost_reason"] = skip
		entry["ghost_note"] = skip
		return ""
	var g: Dictionary = ghost.duplicate()
	g["run_id"] = GhostStore.new_run_id()
	g["track_fingerprint"] = entry["track_fingerprint"]
	var saved: Dictionary = GhostStore.save(g)
	if not bool(saved["ok"]):
		out["ghost_status"] = GHOST_FAILED
		out["ghost_reason"] = str(saved["reason"])
		entry["ghost_note"] = str(saved["reason"])
		return ""
	entry["ghost_run_id"] = g["run_id"]
	entry["ghost_file"] = str(saved["path"])
	out["ghost_status"] = GHOST_SAVED
	return str(saved["path"])


func _referenced_ghosts() -> Dictionary:
	var keep: Dictionary = {}
	for key in _records:
		var p: String = str(_records[key].get("ghost_file", ""))
		if not p.is_empty():
			keep[p] = true
	return keep


func _load() -> void:
	_records = {}
	_preserve_before_save = false
	_writes_blocked = false
	load_state = "missing"
	# 교체 도중 중단된 흔적 정리: 본 파일 우선, 없으면 참조 고스트가 모두 있는 완전한 .tmp, 아니면 .prev.
	GhostStore.recover_pending(SAVE_PATH, _accept_records_tmp)
	if not FileAccess.file_exists(SAVE_PATH):
		return
	_parse_into(SAVE_PATH)


## 본 파일 없이 남은 records.json.tmp를 채택해도 되는가: v2 형식으로 완전히 읽히고, 참조하는 고스트
## 파일이 모두 실제로 있어야 한다(실패한 트랜잭션이 지운 새 고스트를 가리키는 기록을 채택하지 않는다).
func _accept_records_tmp(text: String) -> bool:
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not (parsed is Dictionary) or not (parsed as Dictionary).get("records") is Dictionary:
		return false
	var ver: Variant = parsed.get("format_version")
	if not (ver is int or ver is float) or int(ver) != FORMAT_VERSION:
		return false
	for entry in (parsed["records"] as Dictionary).values():
		var gp: String = str(entry.get("ghost_file", "")) if entry is Dictionary else ""
		if not gp.is_empty() and not FileAccess.file_exists(gp):
			return false
	return true


## 파일을 읽어 메모리에 채운다. 정상(v2)·마이그레이션(v1)이면 true.
func _parse_into(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		# 일시적인 읽기 실패일 수 있으므로 보존·덮어쓰기 없이 이번 실행의 쓰기를 보류한다.
		load_state = "unreadable"
		_writes_blocked = true
		return false
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not (parsed is Dictionary):
		load_state = "corrupt"
		_preserve_before_save = true
		return false
	var root: Dictionary = parsed
	if not root.has("format_version"):
		_migrate_v1(root)
		return true
	var ver: Variant = root["format_version"]
	if not (ver is int or ver is float) or int(ver) != FORMAT_VERSION:
		load_state = "version"
		_preserve_before_save = true
		return false
	_records = _merge_dev_keys(_dict_entries(root.get("records", {})), root.get("legacy", {}))
	load_state = "ok"
	return true


## 형식 버전 없는 예전 파일: .bak으로 복사한 뒤 모든 항목을 그대로 현재 최고 기록으로 옮기고 v2로 저장한다
## (기존 키 "id|diff"와 결과 필드를 유지하며, 고스트 참조 필드는 비어 있어 "고스트 없음"으로 보인다).
## 백업 성공이 교체의 선행조건이다. 백업에 실패하면 원본을 그대로 두고 메모리 읽기만 하며(쓰기 보류),
## 다음 기동에서 다시 시도한다.
func _migrate_v1(root: Dictionary) -> void:
	_records = _dict_entries(root)
	var bak: String = SAVE_PATH + ".bak"
	if FileAccess.file_exists(bak):
		bak = "%s.bak-%d" % [SAVE_PATH, int(Time.get_unix_time_from_system())]
	var copied: bool = (
		not GhostStore.faults.has("backup") and DirAccess.copy_absolute(SAVE_PATH, bak) == OK
	)
	if not copied or FileAccess.get_file_as_string(bak) != FileAccess.get_file_as_string(SAVE_PATH):
		push_warning("RecordStore: 예전 기록 백업 실패, 원본을 유지하고 쓰기를 보류합니다 " + bak)
		load_state = "migrated_readonly"
		_writes_blocked = true
		return
	load_state = "migrated"
	_save()


## 개발 중(v2.3.0 미출시) 잠시 쓰던 규칙 분리 키("id|diff|규칙|지문")와 "legacy" 묶음을 현재 키로 합친다.
## 같은 키로 모이면 is_better 기준(등급 우선, 같은 등급이면 빠른 시간)으로 나은 엔트리를 남긴다.
static func _merge_dev_keys(records: Dictionary, legacy: Variant) -> Dictionary:
	var out: Dictionary = {}
	var pool: Array = []
	for k in records:
		pool.append([str(k), records[k]])
	for k in _dict_entries(legacy):
		pool.append([str(k), legacy[k]])
	for pair in pool:
		var parts: PackedStringArray = str(pair[0]).split("|")
		if parts.size() < 2:
			continue
		var practice: bool = parts.size() >= 3 and parts[2] == PRACTICE_SUFFIX
		var key: String = record_key(parts[0], parts[1], practice)
		var e: Dictionary = pair[1]
		if not out.has(key) or is_better(e, out[key]):
			out[key] = e
	return out


static func _dict_entries(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Dictionary:
		for k in v:
			if v[k] is Dictionary:
				out[str(k)] = v[k]
	return out


## records.json을 임시 파일 → 교체로 저장한다. 성공 여부를 반환한다.
func _save() -> bool:
	if _writes_blocked:
		push_warning("RecordStore: 원본 보존 상태라 기록 쓰기를 보류합니다(" + load_state + ")")
		return false
	if _preserve_before_save and FileAccess.file_exists(SAVE_PATH):
		var bak: String = "%s.bak-%d" % [SAVE_PATH, int(Time.get_unix_time_from_system())]
		if DirAccess.rename_absolute(SAVE_PATH, bak) != OK:
			push_error("RecordStore: 읽을 수 없는 기록 파일을 보존하지 못해 쓰지 않습니다")
			return false
	_preserve_before_save = false
	var text: String = JSON.stringify(
		{"format_version": FORMAT_VERSION, "records": _records}
	)
	if not GhostStore.write_atomic(SAVE_PATH, text, "records"):
		push_error("RecordStore: 저장 실패 " + SAVE_PATH)
		return false
	return true


func _load_settings() -> void:
	_ghost_enabled = true
	GhostStore.recover_pending(SETTINGS_PATH, _is_json_dict)
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if parsed is Dictionary and (parsed as Dictionary).get("ghost_enabled") is bool:
		_ghost_enabled = bool(parsed["ghost_enabled"])


## 개발용 tuning.json이 물리·판정에 쓰이는 Tuning 값(PHYSICS_TUNING_KEYS)을 실제로 바꾸는가. 파일 값과
## 스크립트 기본값(새 인스턴스, _ready 미실행)을 비교한다. text가 비어 있으면 TUNING_OVERRIDE_PATH를 읽는다.
func _detect_tuning_override(text: String = "") -> bool:
	if text.is_empty():
		if not FileAccess.file_exists(TUNING_OVERRIDE_PATH):
			return false
		text = FileAccess.get_file_as_string(TUNING_OVERRIDE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var script: Script = Tuning.get_script()
	if script == null:
		return false
	var defaults: Object = script.new()
	var changed: bool = false
	for key in parsed:
		if not (str(key) in PHYSICS_TUNING_KEYS) or not (key in defaults):
			continue
		if not _same_value(defaults.get(key), parsed[key]):
			changed = true
			break
	if defaults is Node:
		(defaults as Node).free()
	return changed


static func _is_json_dict(text: String) -> bool:
	return JSON.parse_string(text) is Dictionary


static func _same_value(a: Variant, b: Variant) -> bool:
	var a_num: bool = a is int or a is float
	var b_num: bool = b is int or b is float
	if a_num and b_num:
		return is_equal_approx(float(a), float(b))
	return a == b
