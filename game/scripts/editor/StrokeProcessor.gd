class_name StrokeProcessor
extends RefCounted
## 자유곡선 원시 점 → 저장 가능한 polyline (track_editor.md §5, §9).
##
## 파이프라인: 정규화 → 코너 검출/보존 → 평활 → RDP 데시메이트 → 균일 ≤6px 재샘플.
## 손 떨림(픽셀 지터)은 지우되 별 꼭짓점 같은 의도된 급전환점은 코너로 표시해
## 평활·재샘플이 뭉개지 않게 강제 보존한다.
##
## 좌표는 항상 월드 단위. 순수 결정론 함수(입력 고정 → 동일 출력).

const BAKE_INTERVAL: float = 6.0  # TrackData와 동일 재샘플 간격
const MIN_SEG: float = 1.5  # 정규화 시 최소 세그먼트 거리(px)
const QUANTIZE: float = 0.1  # 좌표 반올림 격자(파일·checksum 안정)
const COORD_CLAMP: float = 4000.0  # 좌표 절대 상한(퇴화/악의 입력 차단)
const MAX_RAW_POINTS: int = 20000  # 원시 점 수 상한

const CORNER_ANGLE: float = 0.87  # ≈50° 이상 방향 전환 → 코너 후보
const CORNER_SPAN: float = 12.0  # 코너 각 측정 스팬(px). 단일 인접점은 지터에 취약
const SMOOTH_HALF: int = 2  # 이동평균 반창(창=5)
const SMOOTH_PASSES: int = 2
const RDP_EPS: float = 2.0  # 데시메이트 허용 편차(px)
const CLOSE_GAP: float = 90.0  # 루프 닫기 시 시작점과 남길 갭(§9)
# 줌아웃 정규화: 캔버스는 화면 4px마다 점을 받으므로 zoom 0.15에서는 원시 점 간격이 약 26.7 월드다.
# 이 간격이 DENSIFY_TRIGGER를 넘으면 Catmull-Rom으로 DENSIFY_STEP 간격까지 채우고, 평활 창도 원시
# 간격에 비례해 넓혀(손떨림 파장은 원시 점 간격 단위) zoom 1.0에서 그린 것과 같은 품질을 낸다.
const DENSIFY_STEP: float = 4.0  # zoom 1.0의 원시 점 간격(4px = 4 월드)
const DENSIFY_TRIGGER: float = 6.0
const SMOOTH_HALF_MAX: int = 16


## 원시 점 → polyline. closed면 끝을 시작 근처로(작은 갭) 트림한다. raw_step은 원시 점의 월드
## 간격(캔버스 MIN_SAMPLE_PX / zoom). 0이면 zoom 1.0과 같다고 본다(기존 동작).
func process(
	raw: PackedVector2Array, closed: bool = false, gap: float = CLOSE_GAP, raw_step: float = 0.0
) -> PackedVector2Array:
	if raw.size() < 2:
		return raw.duplicate()
	var n: PackedVector2Array = normalize(raw)
	if n.size() < 2:
		return n
	var half: int = SMOOTH_HALF
	if raw_step > DENSIFY_TRIGGER:
		n = densify(n, DENSIFY_STEP)
		half = clampi(roundi(SMOOTH_HALF * raw_step / DENSIFY_STEP), SMOOTH_HALF, SMOOTH_HALF_MAX)
	var corners: Dictionary = detect_corners(n)  # index -> true
	var s: PackedVector2Array = smooth(n, corners, half)
	var dec: Dictionary = decimate(s, corners, RDP_EPS)
	var r: PackedVector2Array = resample(dec["points"], dec["corners"], BAKE_INTERVAL)
	if closed:
		r = apply_close_gap(r, gap)
	return r


## 0) 정규화: 좌표 클램프 → 중복/근접점 제거 → quantize. 상한 초과 시 앞에서 자른다.
func normalize(raw: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for k in range(mini(raw.size(), MAX_RAW_POINTS)):
		var p: Vector2 = raw[k]
		p.x = clampf(p.x, -COORD_CLAMP, COORD_CLAMP)
		p.y = clampf(p.y, -COORD_CLAMP, COORD_CLAMP)
		p = _quantize(p)
		if out.is_empty() or out[out.size() - 1].distance_to(p) >= MIN_SEG:
			out.append(p)
	return out


## 1) 코너 검출: 스팬 기반 방향 전환각이 임계 이상인 정점을 지역 최댓값으로 표시.
func detect_corners(pts: PackedVector2Array) -> Dictionary:
	var corners: Dictionary = {}
	var n: int = pts.size()
	if n < 3:
		return corners
	var angles: PackedFloat32Array = PackedFloat32Array()
	angles.resize(n)
	for i in range(n):
		angles[i] = 0.0
	for i in range(1, n - 1):
		var bi: int = _span_reach(pts, i, -1)
		var fi: int = _span_reach(pts, i, 1)
		if bi < 0 or fi < 0:
			continue
		var v0: Vector2 = pts[i] - pts[bi]
		var v1: Vector2 = pts[fi] - pts[i]
		if v0.length() < 0.001 or v1.length() < 0.001:
			continue
		var turn: float = absf(v0.angle_to(v1))
		if turn >= CORNER_ANGLE:
			angles[i] = turn
	# 지역 최댓값만 코너로(연속 후보 뭉침 방지).
	for i in range(1, n - 1):
		if angles[i] <= 0.0:
			continue
		if angles[i] >= angles[i - 1] and angles[i] >= angles[i + 1]:
			corners[i] = true
	return corners


## 0.5) 줌아웃 정규화: 간격이 DENSIFY_TRIGGER를 넘는 구간을 Catmull-Rom(원시 점을 지나는 곡선)으로
## step 간격까지 채운다. 결정론 순수 함수.
func densify(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var n: int = pts.size()
	if n < 2:
		return pts.duplicate()
	var out: PackedVector2Array = PackedVector2Array([pts[0]])
	for i in range(n - 1):
		var p1: Vector2 = pts[i]
		var p2: Vector2 = pts[i + 1]
		var d: float = p1.distance_to(p2)
		if d > DENSIFY_TRIGGER:
			var p0: Vector2 = pts[i - 1] if i > 0 else p1 * 2.0 - p2
			var p3: Vector2 = pts[i + 2] if i + 2 < n else p2 * 2.0 - p1
			var m: int = ceili(d / step)
			for k in range(1, m):
				out.append(_quantize(_catmull_rom(p0, p1, p2, p3, float(k) / float(m))))
		out.append(p2)
	return out


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (p2 - p0) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3
	)


## 2) 평활: 코너를 넘지 않는 이동평균(코너·끝점은 고정). 곡률 측정이 의도를 반영하게 한다.
## half는 이동평균 반창(기본 SMOOTH_HALF, 줌아웃 스트로크는 원시 간격에 비례해 넓힌다).
func smooth(
	pts: PackedVector2Array, corners: Dictionary, half: int = SMOOTH_HALF
) -> PackedVector2Array:
	var n: int = pts.size()
	var cur: PackedVector2Array = pts.duplicate()
	for _pass in range(SMOOTH_PASSES):
		var nxt: PackedVector2Array = cur.duplicate()
		for i in range(1, n - 1):
			if corners.has(i):
				continue
			var acc: Vector2 = cur[i]
			var cnt: int = 1
			for w in range(1, half + 1):
				var li: int = i - w
				if li < 0 or corners.has(li):
					break
				acc += cur[li]
				cnt += 1
			for w in range(1, half + 1):
				var ri: int = i + w
				if ri >= n or corners.has(ri):
					break
				acc += cur[ri]
				cnt += 1
			nxt[i] = acc / float(cnt)
		cur = nxt
	return cur


## 3) RDP 데시메이트: 코너 인덱스에서 구간을 나눠 각 구간을 RDP한다(코너 강제 보존).
## 반환 {points, corners(bool 배열)}.
func decimate(pts: PackedVector2Array, corners: Dictionary, eps: float) -> Dictionary:
	var n: int = pts.size()
	var bounds: Array = [0]
	var ck: Array = corners.keys()
	ck.sort()
	for c in ck:
		if c > 0 and c < n - 1:
			bounds.append(c)
	bounds.append(n - 1)
	var out_pts: PackedVector2Array = PackedVector2Array()
	var out_corner: PackedInt32Array = PackedInt32Array()
	for b in range(bounds.size() - 1):
		var lo: int = bounds[b]
		var hi: int = bounds[b + 1]
		var kept: Array = _rdp_indices(pts, lo, hi, eps)
		for k in range(kept.size()):
			if not out_pts.is_empty() and k == 0:
				continue  # 이전 구간 끝과 공유되는 경계점
			var gi: int = kept[k]
			out_pts.append(pts[gi])
			out_corner.append(1 if corners.has(gi) else 0)
	return {"points": out_pts, "corners": out_corner}


## 4) 균일 재샘플: 코너 구간별로 나눠 각 구간을 ≤step 등간격으로(양 끝 포함) 재샘플한다.
func resample(
	pts: PackedVector2Array, corner_flags: PackedInt32Array, step: float
) -> PackedVector2Array:
	var n: int = pts.size()
	if n < 2:
		return pts.duplicate()
	var bounds: Array = [0]
	for i in range(1, n - 1):
		if corner_flags[i] == 1:
			bounds.append(i)
	bounds.append(n - 1)
	var out: PackedVector2Array = PackedVector2Array()
	for b in range(bounds.size() - 1):
		var run: PackedVector2Array = pts.slice(bounds[b], bounds[b + 1] + 1)
		var rr: PackedVector2Array = _resample_run(run, step)
		for k in range(rr.size()):
			if not out.is_empty() and k == 0:
				continue
			out.append(rr[k])
	return out


## 5) 닫기 갭(§9): 끝을 시작점 근처로 트림하되 gap 간격을 남긴다. 끝→시작을 잇지 않는다.
## open path를 유지해 s 단조 증가·피니시 판정(s ≥ length−1)을 보존한다.
func apply_close_gap(r: PackedVector2Array, gap: float = CLOSE_GAP) -> PackedVector2Array:
	if r.size() < 3:
		return r.duplicate()
	var start: Vector2 = r[0]
	var i: int = r.size() - 1
	# 끝에서부터 시작점과 gap 미만인 점들을 걷어낸다(이미 닫힌 그림의 꼬리 트림).
	while i > 1 and start.distance_to(r[i]) < gap:
		i -= 1
	return r.slice(0, i + 1)


## 자동 필렛(스무딩으로 자동 보정, §6.2): 반경 < min_radius 정점 주변만 국소 평활을
## 반복 적용해 너무 뾰족한 코너를 최소반경으로 둥글린다. 코너 보존과 상보적이다.
func relax_curvature(
	pts: PackedVector2Array, min_radius: float, max_iter: int = 12
) -> PackedVector2Array:
	var cur: PackedVector2Array = pts.duplicate()
	var n: int = cur.size()
	if n < 5:
		return cur
	for _iter in range(max_iter):
		var tight: Array = []
		for i in range(2, n - 2):
			var r: float = TrackValidator.menger_radius(cur[i - 2], cur[i], cur[i + 2])
			if r < min_radius:
				tight.append(i)
		if tight.is_empty():
			break
		var nxt: PackedVector2Array = cur.duplicate()
		for i in tight:
			# 3점 국소 평균(끝점 제외)으로 코너를 살짝 둥글린다.
			nxt[i] = (cur[i - 1] + cur[i] * 2.0 + cur[i + 1]) * 0.25
		cur = nxt
	return cur


## 트랙 길이 조절(3단계): 경로 중심(점 평균) 기준 등방 스케일 후 BAKE_INTERVAL 등간격으로 재샘플하고,
## 재샘플로 생긴 길이 오차를 목표 ±0.5 안에 들 때까지(최대 4회) 보정한다. 좌표는 0.1 격자. 반환 {path, pre_close, center, length}.
## pre_close(루프 닫기 전 경로)도 같은 중심·배율로 옮겨 닫기 해제가 원래 배율로 돌아가지 않게 한다.
func scale_to_length(
	pts: PackedVector2Array, target: float, pre_close: PackedVector2Array = PackedVector2Array()
) -> Dictionary:
	var c: Vector2 = centroid(pts)
	var cur: PackedVector2Array = pts
	var total: float = 1.0
	for _pass in range(4):
		var length: float = _length(cur)
		if length < 0.001 or (_pass > 0 and absf(length - target) < 0.5):
			break
		var f: float = target / length
		total *= f
		cur = _resample_run(scale_about(cur, c, f), BAKE_INTERVAL)
	var q: PackedVector2Array = PackedVector2Array()
	for p in cur:
		q.append(_quantize(p))
	var pre: PackedVector2Array = PackedVector2Array()
	if pre_close.size() >= 2:
		pre = _resample_run(scale_about(pre_close, c, total), BAKE_INTERVAL)
	return {"path": q, "pre_close": pre, "center": c, "length": _length(q), "factor": total}


static func centroid(pts: PackedVector2Array) -> Vector2:
	var c: Vector2 = Vector2.ZERO
	if pts.is_empty():
		return c
	for p in pts:
		c += p
	return c / float(pts.size())


static func scale_about(pts: PackedVector2Array, c: Vector2, factor: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(pts.size())
	for i in range(pts.size()):
		out[i] = c + (pts[i] - c) * factor
	return out


static func _length(pts: PackedVector2Array) -> float:
	var total: float = 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total


## centroid 기준 등방 스케일(곡률반경도 ×k). 재샘플하지 않는다(scale_to_length 사용 권장).
func scale_about_centroid(pts: PackedVector2Array, factor: float) -> PackedVector2Array:
	if pts.is_empty():
		return pts.duplicate()
	var c: Vector2 = Vector2.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(pts.size())
	for i in range(pts.size()):
		out[i] = c + (pts[i] - c) * factor
	return out


# --- 내부 헬퍼 ---


func _quantize(p: Vector2) -> Vector2:
	return Vector2(round(p.x / QUANTIZE) * QUANTIZE, round(p.y / QUANTIZE) * QUANTIZE)


## i에서 dir(±1) 방향으로 호길이 CORNER_SPAN 만큼 떨어진 점 인덱스. 없으면 -1.
static func _span_reach(pts: PackedVector2Array, i: int, dir: int) -> int:
	var n: int = pts.size()
	var acc: float = 0.0
	var j: int = i
	while j + dir >= 0 and j + dir < n:
		var nj: int = j + dir
		acc += pts[j].distance_to(pts[nj])
		j = nj
		if acc >= CORNER_SPAN:
			return j
	if acc >= CORNER_SPAN * 0.5:
		return j
	return -1


## [lo,hi] 구간의 RDP 유지 인덱스(정렬, 양 끝 포함). 반복(스택) 구현.
static func _rdp_indices(pts: PackedVector2Array, lo: int, hi: int, eps: float) -> Array:
	if hi <= lo + 1:
		return [lo, hi] if hi > lo else [lo]
	var keep: Dictionary = {lo: true, hi: true}
	var stack: Array = [[lo, hi]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var a: int = seg[0]
		var b: int = seg[1]
		if b <= a + 1:
			continue
		var p0: Vector2 = pts[a]
		var p1: Vector2 = pts[b]
		var max_d: float = -1.0
		var max_i: int = -1
		for i in range(a + 1, b):
			var d: float = _point_seg_dist(pts[i], p0, p1)
			if d > max_d:
				max_d = d
				max_i = i
		if max_d > eps and max_i > 0:
			keep[max_i] = true
			stack.append([a, max_i])
			stack.append([max_i, b])
	var out: Array = keep.keys()
	out.sort()
	return out


static func _point_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	if len2 < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 폴리라인 run을 ≤step 등간격으로 재샘플(양 끝 포함).
static func _resample_run(run: PackedVector2Array, step: float) -> PackedVector2Array:
	var n: int = run.size()
	if n < 2:
		return run.duplicate()
	var cum: PackedFloat32Array = PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + run[i - 1].distance_to(run[i])
	var total: float = cum[n - 1]
	if total < 0.0001:
		return PackedVector2Array([run[0], run[n - 1]])
	var m: int = maxi(1, ceili(total / step))
	var out: PackedVector2Array = PackedVector2Array()
	var seg: int = 0
	for k in range(m + 1):
		var target: float = total * float(k) / float(m)
		while seg < n - 2 and cum[seg + 1] < target:
			seg += 1
		var span: float = cum[seg + 1] - cum[seg]
		var t: float = 0.0 if span < 0.0001 else (target - cum[seg]) / span
		out.append(run[seg].lerp(run[seg + 1], t))
	return out
