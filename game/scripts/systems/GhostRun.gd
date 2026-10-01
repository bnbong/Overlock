class_name GhostRun
extends RefCounted
## 개인 최고 기록 고스트의 기록·재생 데이터 (docs/architecture.md §3.3, 계획서 §1 "기록 방식").
##
## 입력 재시뮬레이션이 아니라 위치 스냅샷이다. RaceDirector가 물리 틱에서 on_tick/on_reset/on_finish를
## 부르면 주행 경과 시간(카운트다운 이후, 일시정지 제외)이 SAMPLE_INTERVAL_MS를 넘을 때마다 샘플을
## 남긴다. 샘플 시각은 렌더 FPS가 아니라 물리 경과 시간으로 정하므로 물리 주기가 달라도 같은 50ms
## 격자 근처에 샘플이 놓인다. 출발과 강제 복귀 직후 샘플에는 FLAG_JUMP를, 완주 샘플에는 FLAG_FINISH를
## 붙인다. 재생(state_at)은 인접 샘플을 선형 보간하고 각도는 lerp_angle로 보간하며, 다음 샘플이
## FLAG_JUMP면 보간하지 않고 그 시각에 즉시 옮긴다(복귀 전후를 직선으로 잇지 않는다).
##
## 10구간: 트랙 호길이를 10등분한 경계 1~9는 물리 틱마다 최대 진행도(_max_s)를 넘어선 경계만 이전/현재
## 진행도 사이 선형 보간으로 최초 통과 시각을 정한다(후진·재방문 중복 없음). 복귀로 건너뛴 경계는
## 가상 통과 시각을 만들지 않고 비교 불가(valid=0)로 둔다. 10번째 경계는 RaceDirector의 실제 완주
## 판정 시각(finish_ms)과 최종 패널티(penalty_ms)를 쓴다. 구간 값은 (주행 시간 + 그때까지 누적 패널티)다.
##
## 이 객체는 시뮬레이션 상태를 읽기만 하고 바꾸지 않는다(충돌·아이템·RISK·기록 무관).

const FORMAT_VERSION: int = 1
const SAMPLE_INTERVAL_MS: int = 50  # 20Hz
const STRIDE: int = 6  # t_ms, x, y, heading, s, flag
const MAX_SAMPLES: int = 24000  # 20Hz 기준 약 20분. 이벤트 샘플 포함.
const SPLIT_COUNT: int = 10
const FLAG_NONE: int = 0
const FLAG_JUMP: int = 1
const FLAG_FINISH: int = 2
const SKIP_NOT_STARTED: String = "not_started"
const SKIP_TOO_MANY_SAMPLES: String = "too_many_samples"

# 샘플 열(평면 배열, STRIDE개씩 한 샘플).
var samples: PackedFloat64Array = PackedFloat64Array()
# 구간별 통과 시각(ms)·그때까지 누적 패널티(ms)·유효 여부(1/0). 미통과는 시각 -1.
var split_t: PackedInt64Array = PackedInt64Array()
var split_pen: PackedInt64Array = PackedInt64Array()
var split_valid: PackedByteArray = PackedByteArray()
var finish_ms: int = -1
var header: Dictionary = {}

var _length: float = 0.0
var _started: bool = false
var _finished: bool = false
var _overflow: bool = false
var _next_due: int = 0
var _max_s: float = 0.0
var _prev_s: float = 0.0
var _prev_t: float = 0.0


func setup(track_length: float) -> void:
	_length = maxf(track_length, 0.0)
	samples = PackedFloat64Array()
	split_t = PackedInt64Array()
	split_pen = PackedInt64Array()
	split_valid = PackedByteArray()
	for _i in SPLIT_COUNT:
		split_t.append(-1)
		split_pen.append(0)
		split_valid.append(0)
	finish_ms = -1
	_started = false
	_finished = false
	_overflow = false


# --- 기록 (RaceDirector 물리 틱) ---


## 카운트다운이 끝나 주행이 시작되는 틱(경과 0)에 출발 이벤트 샘플을 남긴다.
func begin(pos: Vector2, heading: float) -> void:
	_started = true
	_next_due = SAMPLE_INTERVAL_MS
	_max_s = 0.0
	_prev_s = 0.0
	_prev_t = 0.0
	_add(0, pos, heading, 0.0, FLAG_JUMP)


## 정상 주행 틱(시뮬·트랙 질의·집계 뒤). 새로 통과한 구간 인덱스(0부터) 배열을 돌려준다.
func on_tick(t_sec: float, pos: Vector2, heading: float, s: float, penalty_sec: float) -> Array:
	if not _started or _finished:
		return []
	var crossed: Array = _cross_splits(t_sec, s, penalty_sec)
	var t_ms: int = int(t_sec * 1000.0)
	if t_ms >= _next_due:
		_add(t_ms, pos, heading, s, FLAG_NONE)
		_next_due = (t_ms / SAMPLE_INTERVAL_MS + 1) * SAMPLE_INTERVAL_MS
	_prev_s = s
	_prev_t = t_sec
	return crossed


## 맵 이탈 강제 복귀. 복귀 직전 위치와 복귀 직후 위치(FLAG_JUMP)를 같은 시각으로 남기고, 복귀로
## 건너뛴 경계(복귀 지점보다 앞인데 아직 통과하지 않은 경계)는 비교 불가로 표시한다.
func on_reset(
	t_sec: float, pre_pos: Vector2, pre_heading: float, pre_s: float,
	post_pos: Vector2, post_heading: float, post_s: float
) -> void:
	if not _started or _finished:
		return
	var t_ms: int = int(t_sec * 1000.0)
	_add(t_ms, pre_pos, pre_heading, pre_s, FLAG_NONE)
	_add(t_ms, post_pos, post_heading, post_s, FLAG_JUMP)
	for k in SPLIT_COUNT - 1:
		if split_t[k] < 0 and split_valid[k] == 0 and _boundary(k) <= post_s:
			split_t[k] = t_ms
			split_pen[k] = 0
			split_valid[k] = 0
	_max_s = maxf(_max_s, post_s)
	_prev_s = post_s
	_prev_t = t_sec
	_next_due = (t_ms / SAMPLE_INTERVAL_MS + 1) * SAMPLE_INTERVAL_MS


## 완주 확정(RunStats.finalize 직후). 남은 경계를 처리하고 10번째 구간을 실제 완주 값으로 채운 뒤
## 완주 샘플을 남긴다. 새로 통과한 구간 인덱스 배열을 돌려준다(마지막은 항상 9).
func on_finish(result: Dictionary, pos: Vector2, heading: float, s: float) -> Array:
	if not _started or _finished:
		return []
	var f_ms: int = int(result.get("finish_ms", 0))
	var p_ms: int = int(result.get("penalty_ms", 0))
	var crossed: Array = _cross_splits(float(f_ms) / 1000.0, maxf(s, _max_s), float(p_ms) / 1000.0)
	var last: int = SPLIT_COUNT - 1
	split_t[last] = f_ms
	split_pen[last] = p_ms
	split_valid[last] = 1
	crossed.append(last)
	finish_ms = f_ms
	_add(f_ms, pos, heading, s, FLAG_FINISH)
	_finished = true
	return crossed


## 저장하지 못하는 이유(빈 문자열이면 저장 가능).
func skip_reason() -> String:
	if not _started or not _finished:
		return SKIP_NOT_STARTED
	if _overflow:
		return SKIP_TOO_MANY_SAMPLES
	return ""


## 저장용 dict(헤더 + 본문). 저장할 수 없으면 빈 dict. run_id는 RecordStore가 저장 직전에 채운다.
func to_ghost(result: Dictionary, meta: Dictionary = {}) -> Dictionary:
	if not skip_reason().is_empty():
		return {}
	var flat: Array = []
	var n: int = samples.size() / STRIDE
	for i in n:
		var b: int = i * STRIDE
		flat.append(int(samples[b]))
		flat.append(snappedf(samples[b + 1], 0.1))
		flat.append(snappedf(samples[b + 2], 0.1))
		flat.append(snappedf(samples[b + 3], 0.001))
		flat.append(snappedf(samples[b + 4], 0.1))
		flat.append(int(samples[b + 5]))
	var splits: Array = []
	for k in SPLIT_COUNT:
		splits.append([split_t[k], split_pen[k], split_valid[k]])
	var out: Dictionary = {
		"format_version": FORMAT_VERSION,
		"run_id": "",
		"track_id": str(result.get("track_id", "")),
		"difficulty": str(result.get("difficulty", "")),
		"track_fingerprint": str(result.get("track_fingerprint", "")),
		"finish_ms": int(result.get("finish_ms", 0)),
		"penalty_ms": int(result.get("penalty_ms", 0)),
		"final_time_ms": int(result.get("final_time_ms", 0)),
		"sample_count": n,
		"meta": meta,
		"samples": flat,
		"splits": splits,
	}
	return out


func sample_count() -> int:
	return samples.size() / STRIDE


func _add(t_ms: int, pos: Vector2, heading: float, s: float, flag: int) -> void:
	if _overflow:
		return
	if sample_count() >= MAX_SAMPLES:
		_overflow = true
		return
	samples.append_array(PackedFloat64Array([float(t_ms), pos.x, pos.y, heading, s, float(flag)]))


func _boundary(k: int) -> float:
	return _length * float(k + 1) / float(SPLIT_COUNT)


## 최대 진행도를 넘어선 경계 1~9의 최초 통과 시각을 이전/현재 진행도 사이 선형 보간으로 정한다.
func _cross_splits(t_sec: float, s: float, penalty_sec: float) -> Array:
	var crossed: Array = []
	if s <= _max_s:
		return crossed
	var span: float = s - _prev_s
	for k in SPLIT_COUNT - 1:
		var b: float = _boundary(k)
		if split_t[k] >= 0 or b <= _max_s or b > s:
			continue
		var frac: float = clampf((b - _prev_s) / span, 0.0, 1.0) if span > 0.0 else 1.0
		var t_cross: float = lerpf(_prev_t, t_sec, frac)
		split_t[k] = int(t_cross * 1000.0)
		split_pen[k] = int(penalty_sec * 1000.0)
		split_valid[k] = 1
		crossed.append(k)
	_max_s = s
	return crossed


# --- 재생 ---


## 검증을 통과한 고스트 dict(GhostStore.validate)로 재생 객체를 만든다.
static func from_dict(d: Dictionary) -> GhostRun:
	var g: GhostRun = GhostRun.new()
	g.setup(0.0)
	g.header = d.duplicate()
	g.header.erase("samples")
	g.header.erase("splits")
	g.samples = PackedFloat64Array(d.get("samples", []))
	var splits: Array = d.get("splits", [])
	for k in mini(splits.size(), SPLIT_COUNT):
		var row: Array = splits[k]
		g.split_t[k] = int(row[0])
		g.split_pen[k] = int(row[1])
		g.split_valid[k] = 1 if int(row[2]) == 1 else 0
	g.finish_ms = int(d.get("finish_ms", 0))
	g._finished = true
	return g


## 주행 경과 t_ms에서의 고스트 상태 {pos, heading, s, arrived, since_finish_ms}. 샘플이 없으면 빈 dict.
## 같은 t_ms면 렌더 FPS·물리 주기와 무관하게 같은 값을 돌려준다(순수 함수).
func state_at(t_ms: float) -> Dictionary:
	var n: int = sample_count()
	if n == 0:
		return {}
	var last_t: float = samples[(n - 1) * STRIDE]
	if t_ms >= last_t:
		return _state_of(n - 1, true, t_ms - last_t)
	var i: int = _index_at(t_ms)
	var a: int = i * STRIDE
	var b: int = a + STRIDE
	if int(samples[b + 5]) == FLAG_JUMP:
		return _state_of(i, false, 0.0)
	var dt: float = samples[b] - samples[a]
	var w: float = clampf((t_ms - samples[a]) / dt, 0.0, 1.0) if dt > 0.0 else 1.0
	return {
		"pos": Vector2(
			lerpf(samples[a + 1], samples[b + 1], w), lerpf(samples[a + 2], samples[b + 2], w)
		),
		"heading": lerp_angle(samples[a + 3], samples[b + 3], w),
		"s": lerpf(samples[a + 4], samples[b + 4], w),
		"arrived": false,
		"since_finish_ms": 0.0,
	}


## 구간 k(0부터)의 비교 값(통과 시각 + 누적 패널티, ms). 비교할 수 없으면 -1.
func split_value(k: int) -> int:
	if k < 0 or k >= SPLIT_COUNT or split_valid[k] != 1 or split_t[k] < 0:
		return -1
	return int(split_t[k] + split_pen[k])


func _state_of(i: int, arrived: bool, since: float) -> Dictionary:
	var a: int = i * STRIDE
	return {
		"pos": Vector2(samples[a + 1], samples[a + 2]),
		"heading": samples[a + 3],
		"s": samples[a + 4],
		"arrived": arrived,
		"since_finish_ms": maxf(since, 0.0),
	}


## samples[i].t <= t_ms 인 가장 큰 i(이진 탐색). 같은 시각의 복귀 쌍이면 뒤(복귀 직후) 샘플을 고른다.
func _index_at(t_ms: float) -> int:
	var lo: int = 0
	var hi: int = sample_count() - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if samples[mid * STRIDE] <= t_ms:
			lo = mid
		else:
			hi = mid - 1
	return lo
