class_name FabricProfile
extends RefCounted
## 원단별 주행 특성 테이블(v2.3.0, docs/fabric_profiles.md).
##
## res://data/fabric_profiles.json의 원단 id별 배율 3개(speed·steer_tau·risk_gain)를 읽어 런 시작 시
## PlayerController.set_fabric_profile에 넘길 사전을 만든다. 배율은 기본 Tuning 값에 곱하는 런별 값이며
## 전역 Tuning은 바꾸지 않는다. 표에 없는 원단·빈 값·혼합 문자열("cotton,silk" 같은 구간 표기 추정 금지)은
## 면(cotton) 프로필로 대체하고 is_fallback을 켠다. 파일이 없거나 깨졌으면 모든 원단이 배율 1.0(면)이다.
## 서버가 같은 파일을 복사해 시간 하한을 계산하므로 포맷은 단순하게 유지한다:
##   {"version":1, "default":"cotton",
##    "profiles":{"<id>":{"speed","steer_tau","risk_gain","label","desc"}}}

const PATH: String = "res://data/fabric_profiles.json"
const DEFAULT_FABRIC: String = "cotton"
const MULT_KEYS: Array[String] = ["speed", "steer_tau", "risk_gain"]
# 배율 허용 범위. 범위 밖이거나 숫자가 아니면 그 원단 행 전체를 버린다(면 fallback).
const MULT_MIN: float = 0.5
const MULT_MAX: float = 1.5
const DEFAULT_LABEL: String = "면"
const DEFAULT_DESC: String = "표준 조작감"

static var _profiles: Dictionary = {}
static var _loaded: bool = false


## 원단 id의 주행 프로필 사전(복사본). 키: fabric(실제 적용 id), requested(요청 원문), speed, steer_tau,
## risk_gain, label, desc, is_fallback. 표에 없는 값이면 면 프로필에 is_fallback=true.
static func for_fabric(fabric: String) -> Dictionary:
	_ensure_loaded()
	var row: Dictionary = _profiles.get(fabric, {})
	# 면 자체는 표가 비어 있어도(파일 없음·파싱 실패) 내장 기본값으로 정식 적용한다.
	var fallback: bool = row.is_empty() and fabric != DEFAULT_FABRIC
	if row.is_empty():
		row = _profiles.get(DEFAULT_FABRIC, _builtin_default())
	var out: Dictionary = row.duplicate()
	out["fabric"] = DEFAULT_FABRIC if fallback else fabric
	out["requested"] = fabric
	out["is_fallback"] = fallback
	return out


## 화면에 보일 짧은 플레이 차이 문구. 표에 없는 값은 면 특성이 적용된다는 사실을 알린다.
static func describe(fabric: String) -> String:
	var p: Dictionary = for_fabric(fabric)
	if not bool(p["is_fallback"]):
		var desc: String = str(p["desc"])
		# 설명 문구가 빠진 행은 배율 수치로 대신 보여 준다(사실만 표시).
		return desc if not desc.is_empty() else detail(fabric)
	if fabric.strip_edges().is_empty():
		return "원단 미지정 · 표준(면) 특성으로 주행"
	return "알 수 없는 원단 · 표준(면) 특성으로 주행"


## 배율 수치 문구(툴팁·문서 대조용). 예: "속도 ×0.94 · 조향 지연 ×0.90 · 위험 누적 ×0.85".
static func detail(fabric: String) -> String:
	var p: Dictionary = for_fabric(fabric)
	return (
		"속도 ×%.2f · 조향 지연 ×%.2f · 위험 누적 ×%.2f"
		% [float(p["speed"]), float(p["steer_tau"]), float(p["risk_gain"])]
	)


## 표에 정식으로 있는 원단 id 목록(로드 순서 무관, 정렬).
static func known_fabrics() -> Array[String]:
	_ensure_loaded()
	var out: Array[String] = []
	for k in _profiles.keys():
		out.append(str(k))
	out.sort()
	return out


## 표를 다시 읽는다(이름이 Script.reload와 겹치면 클래스 밖 호출이 엔진 메서드로 가므로 load_table).
## text가 비어 있지 않으면 파일 대신 그 텍스트를 쓴다(회귀 검사용). 반환: 읽은 원단 수.
static func load_table(text: String = "") -> int:
	_loaded = true
	_profiles = {}
	var src: String = text
	if src.is_empty():
		if not FileAccess.file_exists(PATH):
			push_warning("FabricProfile: %s 없음, 모든 원단을 면(배율 1.0)으로 처리" % PATH)
			return 0
		src = FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(src)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("profiles") is Dictionary):
		push_warning("FabricProfile: 원단 표 파싱 실패, 모든 원단을 면(배율 1.0)으로 처리")
		return 0
	var rows: Dictionary = (parsed as Dictionary)["profiles"]
	for id in rows.keys():
		var row: Dictionary = _sanitize(rows[id])
		if row.is_empty():
			push_warning("FabricProfile: 원단 '%s' 행이 올바르지 않아 무시" % str(id))
			continue
		_profiles[str(id)] = row
	return _profiles.size()


static func _ensure_loaded() -> void:
	if not _loaded:
		load_table()


## 한 행을 검사해 정규화한다. 배율 3개가 모두 숫자이고 허용 범위 안이어야 한다. 실패하면 빈 사전.
static func _sanitize(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	var out: Dictionary = {}
	for key in MULT_KEYS:
		var v: Variant = d.get(key)
		if not (v is float or v is int):
			return {}
		var f: float = float(v)
		if is_nan(f) or f < MULT_MIN or f > MULT_MAX:
			return {}
		out[key] = f
	out["label"] = str(d.get("label", ""))
	out["desc"] = str(d.get("desc", ""))
	return out


static func _builtin_default() -> Dictionary:
	return {
		"speed": 1.0,
		"steer_tau": 1.0,
		"risk_gain": 1.0,
		"label": DEFAULT_LABEL,
		"desc": DEFAULT_DESC,
	}
