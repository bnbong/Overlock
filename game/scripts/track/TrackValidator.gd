class_name TrackValidator
extends RefCounted
## 커스텀 트랙 기하 검증 (track_editor.md §6). 입력은 재샘플된 폴리라인 + 판정 폭.
##
## 세 축을 본다:
##  1) 최소 곡률반경 — 3점 Menger 곡률(±스팬 스텐실로 픽셀 노이즈 억제). 하드.
##  2) 길이 — 권장 2500~4500, 극단은 하드.
##  3) 자기근접 — 호길이-차(Δs) 3단 분류(면제/하드/소프트). 공간 해시로 O(n) 근사.
##
## 임계는 추적 윈도 상수(TrackData.FWD_WIN·RELOCALIZE_FWD_WIN·BAKE_INTERVAL)에서
## 유도된다. 느슨하면 그린 트랙에서 s 순간이동·피니시 미발동 버그가 재현된다(§6.3).
##
## 판정만 하고 좌표는 바꾸지 않는다. 자동 필렛/스케일은 StrokeProcessor가 수행한다.

# --- 곡률 ---
const MIN_RADIUS: float = 28.0  # 하드: 1단 회전반경 24px < 28 → 최저 기어로 주행 가능(여유)
const RADIUS_RECOMMEND: float = 45.0  # 소프트 권장
const CURV_SPAN: float = 15.0  # Menger 스텐실 반경(px). 단일 인접점(≈6px)은 지터에 취약

# --- 길이 ---
const LEN_MIN: float = 2500.0
const LEN_MAX: float = 4500.0
const LEN_HARD_MIN: float = 1500.0
const LEN_HARD_MAX: float = 8000.0

# --- 자기근접 (§6.3) ---
const ARC_EXEMPT: float = 110.0  # ≈ π·MIN_RADIUS·1.2 : 합법 최소반경 U턴 이웃 면제
const RELOCALIZE_REACH: float = 300.0  # ≈ RELOCALIZE_FWD_WIN(40)·BAKE(6)=240 + 여유

# --- 최소 점 수 ---
const MIN_POINTS: int = 8


## 폴리라인 전체를 검증한다. fail = 자기근접 임계(난이도 프리셋 fail 폭).
## 반환 dict(주요 필드):
##   ok(bool) · hard(int) · soft(int) · length(float) · min_radius(float)
##   curvature(Array[{i,radius}]) · proximity(Array[{i,j,kind,d}])
##   length_status(String) · messages(Array[String])
func validate(pts: PackedVector2Array, fail: float) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"hard": 0,
		"soft": 0,
		"length": 0.0,
		"min_radius": INF,
		"curvature": [],
		"proximity": [],
		"length_status": "ok",
		"messages": [],
	}
	if pts.size() < MIN_POINTS:
		result["messages"].append("너무 짧음 (점 %d개, 최소 %d개)" % [pts.size(), MIN_POINTS])
		result["hard"] = int(result["hard"]) + 1
		return result

	var s_arr: PackedFloat32Array = build_arc_lengths(pts)
	var total_len: float = s_arr[s_arr.size() - 1]
	result["length"] = total_len

	# 1) 곡률
	var curv: Array = check_curvature(pts, s_arr)
	result["curvature"] = curv
	var hard_curv: int = 0
	for v in curv:
		if str(v["kind"]) == "hard":
			hard_curv += 1
	# 보고용 최소반경은 위반 여부와 무관하게 전 구간 실제 최솟값을 쓴다(완만한 트랙도 유한값).
	result["min_radius"] = compute_min_radius(pts, s_arr)

	# 2) 길이
	var len_status: String = "ok"
	var len_hard: int = 0
	if total_len < LEN_HARD_MIN:
		len_status = "too_short"
		len_hard = 1
	elif total_len > LEN_HARD_MAX:
		len_status = "too_long"
		len_hard = 1
	elif total_len < LEN_MIN:
		len_status = "short_warn"
	elif total_len > LEN_MAX:
		len_status = "long_warn"
	result["length_status"] = len_status

	# 3) 자기근접
	var prox: Array = _dedupe_pairs(check_self_proximity(pts, s_arr, fail))
	result["proximity"] = prox
	var hard_prox: int = 0
	var soft_prox: int = 0
	for p in prox:
		if str(p["kind"]) == "hard":
			hard_prox += 1
		else:
			soft_prox += 1

	# --- 집계 ---
	var soft_curv: int = 0
	if float(result["min_radius"]) < RADIUS_RECOMMEND and hard_curv == 0:
		soft_curv = 1
	var hard: int = hard_curv + hard_prox + len_hard
	var soft: int = soft_prox + soft_curv
	if len_status == "short_warn" or len_status == "long_warn":
		soft += 1
	result["hard"] = hard
	result["soft"] = soft
	result["ok"] = hard == 0

	_build_messages(result)
	return result


## 각 점까지의 누적 호길이(첫 점 0).
static func build_arc_lengths(pts: PackedVector2Array) -> PackedFloat32Array:
	var s_arr: PackedFloat32Array = PackedFloat32Array()
	s_arr.resize(pts.size())
	if pts.is_empty():
		return s_arr
	s_arr[0] = 0.0
	for i in range(1, pts.size()):
		s_arr[i] = s_arr[i - 1] + pts[i - 1].distance_to(pts[i])
	return s_arr


## 최소 곡률반경 검사(Menger, ±CURV_SPAN 스텐실). 위반/권장 미달 정점 목록을
## 인접 클러스터로 묶어 반환한다({i, radius, kind}). kind: hard(<MIN) / soft(<RECOMMEND).
func check_curvature(pts: PackedVector2Array, s_arr: PackedFloat32Array) -> Array:
	var raw: Array = []
	var n: int = pts.size()
	for i in range(n):
		var kb: int = _span_index(s_arr, i, -1)
		var kf: int = _span_index(s_arr, i, 1)
		if kb < 0 or kf < 0:
			continue  # 끝단: 스팬 부족 → 건너뜀
		var r: float = menger_radius(pts[kb], pts[i], pts[kf])
		if r < RADIUS_RECOMMEND:
			var kind: String = "hard" if r < MIN_RADIUS else "soft"
			raw.append({"i": i, "radius": r, "kind": kind})
	return _cluster_curvature(raw)


## 전 구간 실제 최소 곡률반경(±CURV_SPAN 스텐실). 유효 스팬이 없으면 INF.
func compute_min_radius(pts: PackedVector2Array, s_arr: PackedFloat32Array) -> float:
	var min_r: float = INF
	for i in range(pts.size()):
		var kb: int = _span_index(s_arr, i, -1)
		var kf: int = _span_index(s_arr, i, 1)
		if kb < 0 or kf < 0:
			continue
		min_r = minf(min_r, menger_radius(pts[kb], pts[i], pts[kf]))
	return min_r


## 세 점 A,B,C의 외접원 반경(Menger). 거의 일직선이면 INF.
static func menger_radius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab: float = a.distance_to(b)
	var bc: float = b.distance_to(c)
	var ca: float = c.distance_to(a)
	var cross: float = absf((b - a).cross(c - a))
	if cross < 0.0001:
		return INF
	return (ab * bc * ca) / (2.0 * cross)


## i에서 dir(±1) 방향으로 호길이 CURV_SPAN 만큼 떨어진 점의 인덱스. 없으면 -1.
static func _span_index(s_arr: PackedFloat32Array, i: int, dir: int) -> int:
	var n: int = s_arr.size()
	var j: int = i
	while j > 0 and j < n - 1:
		j += dir
		if absf(s_arr[j] - s_arr[i]) >= CURV_SPAN:
			return j
	# 끝에 닿았지만 스팬을 충분히 확보했으면 그 끝점을 쓴다.
	if j >= 0 and j < n and absf(s_arr[j] - s_arr[i]) >= CURV_SPAN * 0.6:
		return j
	return -1


## 인접(인덱스 근접) 곡률 위반을 하나의 코너로 묶어 최소 반경 정점만 남긴다.
func _cluster_curvature(raw: Array) -> Array:
	if raw.is_empty():
		return raw
	var out: Array = []
	var cur: Dictionary = raw[0]
	var last_i: int = int(raw[0]["i"])
	for k in range(1, raw.size()):
		var v: Dictionary = raw[k]
		if int(v["i"]) - last_i <= 6:
			if float(v["radius"]) < float(cur["radius"]):
				cur = v
		else:
			out.append(cur)
			cur = v
		last_i = int(v["i"])
	out.append(cur)
	return out


## 자기근접 검사(§6.3). 공간 해시(셀=1.5·fail)로 근접 후보쌍만 Δs 3단 분류한다.
func check_self_proximity(pts: PackedVector2Array, s_arr: PackedFloat32Array, fail: float) -> Array:
	var out: Array = []
	if fail <= 0.0:
		return out
	var cell: float = fail * 1.5
	var reach2: float = cell * cell
	var grid: Dictionary = {}
	for i in range(pts.size()):
		var c: Vector2i = _cell(pts[i], cell)
		if not grid.has(c):
			grid[c] = PackedInt32Array()
		grid[c].append(i)
	for i in range(pts.size()):
		var ci: Vector2i = _cell(pts[i], cell)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var key: Vector2i = ci + Vector2i(dx, dy)
				if not grid.has(key):
					continue
				for j in grid[key]:
					if j <= i:
						continue
					var d2: float = pts[i].distance_squared_to(pts[j])
					if d2 > reach2:
						continue
					var ds: float = absf(s_arr[i] - s_arr[j])
					if ds <= ARC_EXEMPT:
						continue  # 합법 급커브(U턴)의 양쪽 → 면제
					var d: float = sqrt(d2)
					if ds <= RELOCALIZE_REACH and d < fail:
						out.append({"i": i, "j": j, "kind": "hard", "d": d})
					elif d < fail * 1.5:
						out.append({"i": i, "j": j, "kind": "soft", "d": d})
	return out


static func _cell(p: Vector2, cell: float) -> Vector2i:
	return Vector2i(floori(p.x / cell), floori(p.y / cell))


## 같은 교차/근접 구역에서 쏟아지는 다수 쌍을 인덱스 버킷으로 묶어 대표(최소거리)만 남긴다.
func _dedupe_pairs(viol: Array) -> Array:
	var best: Dictionary = {}
	for v in viol:
		var bi: int = int(v["i"]) / 16
		var bj: int = int(v["j"]) / 16
		var key: String = "%d_%d_%s" % [bi, bj, str(v["kind"])]
		if not best.has(key) or float(v["d"]) < float(best[key]["d"]):
			best[key] = v
	return best.values()


func _build_messages(result: Dictionary) -> void:
	var msgs: Array = result["messages"]
	var hard_curv: int = 0
	for v in result["curvature"]:
		if str(v["kind"]) == "hard":
			hard_curv += 1
	if hard_curv > 0:
		msgs.append("곡률 위반 %d곳 (반경 < %dpx)" % [hard_curv, int(MIN_RADIUS)])
	var hard_prox: int = 0
	var soft_prox: int = 0
	for p in result["proximity"]:
		if str(p["kind"]) == "hard":
			hard_prox += 1
		else:
			soft_prox += 1
	if hard_prox > 0:
		msgs.append("자기근접 위반 %d곳 (s 점프 위험)" % hard_prox)
	if soft_prox > 0:
		msgs.append("자기근접 경고 %d곳 (코리도 겹침)" % soft_prox)
	match str(result["length_status"]):
		"too_short":
			msgs.append("길이 %dpx — 하한 %dpx 미만" % [int(result["length"]), int(LEN_HARD_MIN)])
		"too_long":
			msgs.append("길이 %dpx — 상한 %dpx 초과" % [int(result["length"]), int(LEN_HARD_MAX)])
		"short_warn":
			msgs.append("길이 %dpx — 권장 %d~%dpx 보다 짧음" % [int(result["length"]), int(LEN_MIN), int(LEN_MAX)])
		"long_warn":
			msgs.append("길이 %dpx — 권장 %d~%dpx 보다 김" % [int(result["length"]), int(LEN_MIN), int(LEN_MAX)])
