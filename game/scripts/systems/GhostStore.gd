class_name GhostStore
extends RefCounted
## 개인 고스트 파일 저장소와 안전한 파일 교체 도우미 (docs/architecture.md §3.3).
##
## 고스트 파일은 user://ghosts/<run_id>.json 하나씩이며 compact JSON(숫자 배열)이다. 저장은
## 임시 파일(<path>.tmp)에 쓰고 다시 읽어 내용·구조를 확인한 뒤 rename으로 교체한다(write_atomic).
## records.json도 같은 도우미로 쓴다(RecordStore). 웹(IDBFS)은 기존 저장 코드와 같은 관례를 따른다:
## 엔진이 쓰기 모드로 연 user:// 파일을 닫을 때 동기화 필요 표시를 세우고 메인 루프에서 동기화하므로
## 명시적 sync를 부르지 않는다(CommunityStore 머리말 참고).
##
## 읽기는 크기 상한 → JSON 파싱 → 구조·시각 단조성 검사(validate) → 기록 엔트리와의 일치 검사 순이다.
## 하나라도 어긋나면 고스트만 비활성화하고(사유 문자열 반환) 기록이나 게임 진입에는 손대지 않는다.

const DIR: String = "user://ghosts/"
const MAX_BYTES: int = 2 * 1024 * 1024
## 마지막(완주) 샘플 시각과 헤더 finish_ms의 허용 차이(ms). 기록기는 같은 int 값을 쓰므로 0이지만
## 부동소수 → 정수 변환 차이를 1ms까지 허용한다.
const FINISH_TOLERANCE_MS: float = 1.0
const HEADER_KEYS: Array[String] = [
	"format_version", "run_id", "track_id", "difficulty", "track_fingerprint", "finish_ms",
	"penalty_ms", "final_time_ms", "sample_count",
]
# 실패 사유(결과 화면·트랙 선택 문구가 이 값으로 안내를 고른다).
const R_TOO_LARGE: String = "too_large"
const R_WRITE_FAILED: String = "write_failed"
const R_INVALID: String = "invalid"
const R_MISSING: String = "missing"
const R_CORRUPT: String = "corrupt"
const R_UNSUPPORTED: String = "unsupported"
const R_MISMATCH: String = "mismatch"

## 회귀 검사용 고장 주입. 이 집합에 든 이름의 쓰기(write_atomic의 fault_key)는 임시 파일 단계에서
## 실패한다. 제품 코드는 비워 둔다. 예: "ghost", "records", "ghost_settings".
static var faults: Dictionary = {}


static func path_for(run_id: String) -> String:
	return DIR + run_id + ".json"


## 고유 run_id(g + 시각 + 난수 16진). 파일 이름으로 쓰므로 영숫자만.
static func new_run_id() -> String:
	var t: int = int(Time.get_unix_time_from_system())
	return "g%x%06x%08x" % [t, Time.get_ticks_usec() & 0xffffff, randi()]


static func is_valid_run_id(run_id: String) -> bool:
	if run_id.length() < 2 or run_id.length() > 40 or not run_id.begins_with("g"):
		return false
	for ch in run_id:
		var c: int = ch.unicode_at(0)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 122)):
			return false
	return true


## 고스트 dict를 검사·직렬화해 저장한다. 반환 {ok, path, reason}. 실패하면 파일을 남기지 않는다.
static func save(ghost: Dictionary) -> Dictionary:
	var run_id: String = str(ghost.get("run_id", ""))
	var bad: String = validate(ghost)
	if not is_valid_run_id(run_id):
		bad = R_INVALID
	if not bad.is_empty():
		return {"ok": false, "path": "", "reason": bad}
	var text: String = JSON.stringify(ghost)
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return {"ok": false, "path": "", "reason": R_TOO_LARGE}
	if not _ensure_dir():
		return {"ok": false, "path": "", "reason": R_WRITE_FAILED}
	var path: String = path_for(run_id)
	if not write_atomic(path, text, "ghost"):
		return {"ok": false, "path": "", "reason": R_WRITE_FAILED}
	return {"ok": true, "path": path, "reason": ""}


## 고스트 파일을 읽어 검사한다. expect의 키(track_id·difficulty·track_fingerprint·run_id·final_time_ms)가
## 헤더와 모두 같아야 한다. 반환 {ok, run(GhostRun 또는 null), reason}.
static func load_checked(path: String, expect: Dictionary) -> Dictionary:
	var fail: Dictionary = {"ok": false, "run": null, "reason": R_MISSING}
	if path.is_empty() or not FileAccess.file_exists(path):
		return fail
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return fail
	if file.get_length() > MAX_BYTES:
		file.close()
		fail["reason"] = R_TOO_LARGE
		return fail
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		fail["reason"] = R_CORRUPT
		return fail
	var d: Dictionary = parsed
	if not _is_num(d.get("format_version")) or int(d["format_version"]) != GhostRun.FORMAT_VERSION:
		fail["reason"] = R_UNSUPPORTED
		return fail
	var bad: String = validate(d)
	if not bad.is_empty():
		fail["reason"] = bad
		return fail
	for key in expect:
		var want: Variant = expect[key]
		var got: Variant = d.get(key)
		var same: bool = (
			int(got) == int(want) if _is_num(want) and _is_num(got) else str(got) == str(want)
		)
		if not same:
			fail["reason"] = R_MISMATCH
			return fail
	return {"ok": true, "run": GhostRun.from_dict(d), "reason": ""}


## 구조·크기·시각 단조성 검사. 문제가 없으면 빈 문자열, 있으면 사유(R_INVALID/R_UNSUPPORTED).
static func validate(d: Dictionary) -> String:
	for key in HEADER_KEYS:
		if not d.has(key):
			return R_INVALID
	if not _is_num(d["format_version"]) or int(d["format_version"]) != GhostRun.FORMAT_VERSION:
		return R_UNSUPPORTED
	for key in ["finish_ms", "penalty_ms", "final_time_ms", "sample_count"]:
		if not _is_num(d[key]) or float(d[key]) < 0.0:
			return R_INVALID
	var finish: int = int(d["finish_ms"])
	if finish + int(d["penalty_ms"]) != int(d["final_time_ms"]):
		return R_INVALID
	var n: int = int(d["sample_count"])
	var flat: Variant = d.get("samples")
	if not (flat is Array) or n < 2 or n > GhostRun.MAX_SAMPLES:
		return R_INVALID
	if (flat as Array).size() != n * GhostRun.STRIDE:
		return R_INVALID
	var bad: String = _samples_problem(flat, finish)
	if not bad.is_empty():
		return bad
	return _splits_problem(d.get("splits"), finish, int(d["penalty_ms"]))


static func _samples_problem(flat: Array, finish: int) -> String:
	var prev_t: float = -1.0
	var stride: int = GhostRun.STRIDE
	for i in flat.size() / stride:
		var b: int = i * stride
		for j in stride:
			if not _is_num(flat[b + j]) or not is_finite(float(flat[b + j])):
				return R_INVALID
		var t: float = float(flat[b])
		if t < prev_t or t > float(finish) + 1.0:
			return R_INVALID
		prev_t = t
	if float(flat[0]) != 0.0:
		return R_INVALID
	# 마지막 샘플은 완주 샘플이며 시각이 헤더 finish_ms와 같아야 한다(허용 오차 FINISH_TOLERANCE_MS).
	# 짧은 샘플 열에 긴 finish_ms를 붙인 손상 파일이 조기 도착을 표시하지 않게 한다.
	if int(flat[flat.size() - 1]) != GhostRun.FLAG_FINISH:
		return R_INVALID
	if absf(float(flat[flat.size() - GhostRun.STRIDE]) - float(finish)) > FINISH_TOLERANCE_MS:
		return R_INVALID
	return ""


## 구간 10개: 각 행은 [t_ms, pen_ms, valid]. valid는 0/1, t는 -1(미통과) 또는 0..finish, pen은 0..penalty.
## 시각이 있는 행의 시각과 유효 행의 누적 패널티는 단조 증가해야 하고, 마지막 구간은 유효하며 헤더의
## finish_ms·penalty_ms와 같아야 한다(마지막 구간 값 = final_time_ms).
static func _splits_problem(splits: Variant, finish: int, penalty: int) -> String:
	if not (splits is Array) or (splits as Array).size() != GhostRun.SPLIT_COUNT:
		return R_INVALID
	var prev_t: int = -1
	var prev_pen: int = 0
	for row in splits:
		if not (row is Array) or (row as Array).size() != 3:
			return R_INVALID
		for v in row:
			if not _is_num(v) or not is_finite(float(v)):
				return R_INVALID
		var t: int = int(row[0])
		var pen: int = int(row[1])
		var valid: int = int(row[2])
		if valid != 0 and valid != 1:
			return R_INVALID
		if t < -1 or t > finish or pen < 0 or pen > penalty or (valid == 1 and t < 0):
			return R_INVALID
		if t >= 0:
			if t < prev_t:
				return R_INVALID
			prev_t = t
		if valid == 1:
			if pen < prev_pen:
				return R_INVALID
			prev_pen = pen
	var last: Array = splits[GhostRun.SPLIT_COUNT - 1]
	if int(last[2]) != 1 or int(last[0]) != finish or int(last[1]) != penalty:
		return R_INVALID
	return ""


static func remove(path: String) -> void:
	if path.begins_with(DIR) and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## keep(경로 → true)에 없는 고스트 파일과 남은 임시 파일을 지운다(중간 종료로 생긴 고아 정리).
## 고스트 이름 형식(g….json, g….json.tmp)인 파일만 건드린다. 지운 개수를 돌려준다.
static func cleanup_orphans(keep: Dictionary) -> int:
	var dir: DirAccess = DirAccess.open(DIR)
	if dir == null:
		return 0
	var removed: int = 0
	for f in dir.get_files():
		var base: String = f.trim_suffix(".tmp").trim_suffix(".json")
		if not is_valid_run_id(base) or not (f.ends_with(".json") or f.ends_with(".json.tmp")):
			continue
		var path: String = DIR + f
		if f.ends_with(".json") and keep.has(path):
			continue
		if DirAccess.remove_absolute(path) == OK:
			removed += 1
	return removed


## 임시 파일에 쓰고 다시 읽어 같은지·JSON인지 확인한 뒤 rename으로 교체한다. 기존 파일 위로의 rename이
## 실패하는 플랫폼에서는 기존 파일을 <path>.prev로 옮긴 뒤 rename하고, 그것도 실패하면 .prev를 되돌린다.
## 기존 파일을 지우는 경로는 없다. 실패하면 false이며 기존 파일은 그대로이고 .tmp·.prev는 남기지 않는다
## (되돌리기마저 실패한 극단적인 경우에만 .prev가 남고, 다음 로드의 recover_pending이 복원한다).
static func write_atomic(path: String, text: String, fault_key: String = "") -> bool:
	var tmp: String = path + ".tmp"
	if faults.has(fault_key):
		push_warning("GhostStore: 회귀 검사 고장 주입으로 쓰기 실패 " + path)
		return false
	var file: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("GhostStore: 임시 파일 쓰기 실패 " + tmp)
		return false
	file.store_string(text)
	var err: int = file.get_error()
	file.close()
	if err != OK or not _verify_written(tmp, text):
		DirAccess.remove_absolute(tmp)
		push_error("GhostStore: 임시 파일 검증 실패 " + tmp)
		return false
	var rename_fault: bool = faults.has(fault_key + "_rename")
	if not rename_fault and DirAccess.rename_absolute(tmp, path) == OK:
		return true
	if not FileAccess.file_exists(path):
		DirAccess.remove_absolute(tmp)
		push_error("GhostStore: 파일 교체 실패 " + path)
		return false
	var prev: String = path + ".prev"
	if FileAccess.file_exists(prev):
		DirAccess.remove_absolute(prev)
	if DirAccess.rename_absolute(path, prev) != OK:
		DirAccess.remove_absolute(tmp)
		push_error("GhostStore: 파일 교체 실패(기존 파일 유지) " + path)
		return false
	if not rename_fault and DirAccess.rename_absolute(tmp, path) == OK:
		DirAccess.remove_absolute(prev)
		return true
	DirAccess.remove_absolute(tmp)
	if DirAccess.rename_absolute(prev, path) != OK:
		push_error("GhostStore: 이전 파일 복원 실패(다음 로드에서 .prev 복원) " + path)
	else:
		push_error("GhostStore: 파일 교체 실패(기존 파일 유지) " + path)
	return false


## 교체 도중 중단된 흔적을 정리한다(로드 직전 호출). 본 파일이 있으면 그것이 확정본이므로 .tmp·.prev를
## 지운다. 본 파일이 없으면 accept_tmp(텍스트 → bool)가 받아들이는 완전한 .tmp를 채택하고, 아니면 .prev를
## 복원한다. 실패한 트랜잭션은 write_atomic이 .tmp를 남기지 않으므로 여기서 채택되는 .tmp는 rename 직전에
## 중단된 경우뿐이다. 반환: "main" | "tmp" | "prev" | "none".
static func recover_pending(path: String, accept_tmp: Callable) -> String:
	var tmp: String = path + ".tmp"
	var prev: String = path + ".prev"
	if FileAccess.file_exists(path):
		for p in [tmp, prev]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
		return "main"
	if FileAccess.file_exists(tmp):
		var text: String = FileAccess.get_file_as_string(tmp)
		if bool(accept_tmp.call(text)) and DirAccess.rename_absolute(tmp, path) == OK:
			if FileAccess.file_exists(prev):
				DirAccess.remove_absolute(prev)
			return "tmp"
		DirAccess.remove_absolute(tmp)
	if FileAccess.file_exists(prev) and DirAccess.rename_absolute(prev, path) == OK:
		return "prev"
	return "none"


static func _verify_written(tmp: String, expected: String) -> bool:
	var file: FileAccess = FileAccess.open(tmp, FileAccess.READ)
	if file == null:
		return false
	var got: String = file.get_as_text()
	file.close()
	return got == expected and JSON.parse_string(got) is Dictionary


static func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(DIR):
		return true
	return DirAccess.make_dir_recursive_absolute(DIR) == OK


static func _is_num(v: Variant) -> bool:
	return v is int or v is float
