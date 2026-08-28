class_name TrackData
extends RefCounted
## 베이크된 트랙 폴리라인과 판정 폭, 최근접 질의 (아키텍처 §5).
##
## JSON cubic bezier들을 수동 De Casteljau로 균일 근사 샘플링해 하나의
## 폴리라인으로 잇고, 각 점의 누적 호길이 s를 함께 보관한다.
## query()는 직전 프레임 hint 주변 윈도만 검사하는 최근접 탐색이다.

const BAKE_INTERVAL: float = 6.0  # 목표 점 간격(px)
const BACK_WIN: int = 6
const FWD_WIN: int = 12  # max_speed(300)/60fps ≈ 5px, BAKE 6px 대비 여유
# 방어 재로컬라이즈 윈도(아키텍처 §5.3). 정상 윈도가 앞끝에서 크게 이탈했을 때만
# hint 주변을 한계 내에서 넓게 다시 탐색한다. 전역 스캔이 아니라 인덱스 한계를 둔
# 확장 윈도라, 닫힌·자기근접 윤곽(heart_01·star_01: 시작/끝 55~103px)에서 기하적으로
# 가깝지만 s가 먼 다른 가지로 s를 순간이동시키지 않는다. 앞쪽은 코너 컷 따라잡기를
# 허용하도록 넉넉히, 뒤쪽은 s 역행(다른 가지로의 후퇴)을 막도록 좁게 둔다.
const RELOCALIZE_BACK_WIN: int = 12  # ≈72px
const RELOCALIZE_FWD_WIN: int = 40  # ≈240px

var points: PackedVector2Array = PackedVector2Array()
var s_arr: PackedFloat32Array = PackedFloat32Array()
var length: float = 0.0
var perfect: float = 18.0
var safe: float = 42.0
var fail: float = 90.0
var track_id: String = ""
var track_name: String = ""
var difficulty: String = "normal"
var fabric: String = ""
var modifiers: Array = []
# 필드 아이템 (v1.1.0). 스키마 [{"s":640,"type":"thimble","lat":0}, ...]. TrackLoader가 파일에서
# 그대로 싣고, RaceDirector가 고정 틱에서 소비한다(월드 좌표 = point_at_s(s) + lat*접선법선).
var items: Array = []


## path 세그먼트를 폴리라인으로 베이크한다. type별 분기(가산적 확장):
## bezier(공식 트랙)는 기존 De Casteljau 근사, polyline(커스텀 트랙)은 ≤6px 세분.
## 두 타입은 같은 배열 안에 공존할 수 있으며 s는 항상 선형으로 이어붙인다.
func bake(path_json: Array) -> void:
	points = PackedVector2Array()
	s_arr = PackedFloat32Array()
	for seg in path_json:
		var seg_dict: Dictionary = seg
		match str(seg_dict.get("type", "bezier")):
			"polyline":
				_bake_polyline(seg_dict)
			_:
				_bake_bezier(seg_dict)
	if s_arr.size() > 0:
		length = s_arr[s_arr.size() - 1]
	else:
		length = 0.0


## cubic bezier 1개를 균일 근사 샘플링해 폴리라인에 잇는다(기존 동작 불변).
func _bake_bezier(seg: Dictionary) -> void:
	var p0: Vector2 = _to_vec(seg["p0"])
	var p1: Vector2 = _to_vec(seg["p1"])
	var p2: Vector2 = _to_vec(seg["p2"])
	var p3: Vector2 = _to_vec(seg["p3"])
	var rough: float = p0.distance_to(p1) + p1.distance_to(p2) + p2.distance_to(p3)
	var steps: int = maxi(2, ceili(rough / BAKE_INTERVAL))
	for j in range(steps + 1):
		if j == 0 and points.size() > 0:
			continue  # 이전 세그먼트 끝점과 공유 → 중복 제거
		var t: float = float(j) / float(steps)
		_append(_bezier(p0, p1, p2, p3, t))


## polyline 세그먼트를 ≤BAKE_INTERVAL(6px)로 세분해 잇는다(아키텍처 §5.3의 윈도
## 추적은 점 간격 ≈6px를 전제하므로 성긴 폴리라인은 반드시 잘게 나눠 넣는다).
func _bake_polyline(seg: Dictionary) -> void:
	var raw: Array = seg.get("points", [])
	for k in range(raw.size()):
		var q: Vector2 = _to_vec(raw[k])
		if points.is_empty():
			_append(q)
			continue
		var last: Vector2 = points[points.size() - 1]
		if k == 0 and last.distance_to(q) < 0.01:
			continue  # 이전 세그먼트 끝점과 공유 → 중복 제거
		var n: int = maxi(1, ceili(last.distance_to(q) / BAKE_INTERVAL))
		for m in range(1, n):
			_append(last.lerp(q, float(m) / float(n)))
		_append(q)


func start_heading() -> float:
	if points.size() >= 2:
		return (points[1] - points[0]).angle()
	return 0.0


## 아크길이 s에서의 중심선 점(s_arr 이진탐색 + 세그먼트 선형보간). 결정론. s는 [0,length]로 클램프.
func point_at_s(s: float) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	if points.size() == 1:
		return points[0]
	var sc: float = clampf(s, 0.0, length)
	var i: int = _seg_index_at_s(sc)
	var seg_len: float = s_arr[i + 1] - s_arr[i]
	var t: float = 0.0
	if seg_len > 0.0:
		t = (sc - s_arr[i]) / seg_len
	return points[i].lerp(points[i + 1], t)


## 아크길이 s에서의 단위 접선(진행 방향) 벡터. 세그먼트가 없거나 퇴화하면 +X. 결정론.
func tangent_at_s(s: float) -> Vector2:
	if points.size() < 2:
		return Vector2.RIGHT
	var sc: float = clampf(s, 0.0, length)
	var i: int = _seg_index_at_s(sc)
	var dir: Vector2 = points[i + 1] - points[i]
	if dir.length_squared() <= 0.0:
		return Vector2.RIGHT
	return dir.normalized()


## 아크길이 s 부근의 곡률(rad/px = 1/반경). s±ds/2에서 접선 각차를 span(ds)으로 나눈 유한차분
## 근사다(접선이 세그먼트별 상수라 근사). 결정론. 오토파일럿 핸드오프 게이트가 소비한다.
func curvature_at_s(s: float, ds: float = 12.0) -> float:
	if length <= 0.0 or ds <= 0.0:
		return 0.0
	var half: float = ds * 0.5
	var t0: Vector2 = tangent_at_s(s - half)
	var t1: Vector2 = tangent_at_s(s + half)
	return absf(t0.angle_to(t1)) / ds


## s_arr[i] <= s <= s_arr[i+1]를 만족하는 세그먼트 인덱스 i(이진탐색, 결과는 [0, size-2]).
func _seg_index_at_s(s: float) -> int:
	var n: int = s_arr.size()
	if n < 2:
		return 0
	var lo: int = 0
	var hi: int = n - 2
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if s_arr[mid] <= s:
			lo = mid
		else:
			hi = mid - 1
	return lo


## pos에 대해 hint 주변 윈도에서 최근접 폴리라인 점을 찾는다.
## 반환: {"error": float, "s": float, "idx": int}
func query(pos: Vector2, hint: int) -> Dictionary:
	var last_seg: int = points.size() - 2
	if last_seg < 0:
		return {"error": 0.0, "s": 0.0, "idx": 0}
	var h: int = clampi(hint, 0, last_seg)
	var lo: int = maxi(h - BACK_WIN, 0)
	var hi: int = mini(h + FWD_WIN, last_seg)
	var result: Dictionary = _nearest_in_range(pos, lo, hi)
	# 방어 재로컬라이즈(아키텍처 §5.3): 최근접이 정상 윈도 앞끝(hi)에 걸리고 오차가
	# fail 폭을 넘으면(코너 컷으로 윈도를 앞질렀거나 크게 이탈) hint 주변을 한계 내에서
	# 넓게 재탐색한다. 인덱스 한계(RELOCALIZE_*) 덕에 원거리 가지로는 절대 넘어가지
	# 않아, 닫힌 윤곽에서 s가 다른 가지로 순간이동하는 일이 없다(피니시·미니맵 정합 보존).
	if int(result["idx"]) == hi and float(result["error"]) > fail:
		var wlo: int = maxi(h - RELOCALIZE_BACK_WIN, 0)
		var whi: int = mini(h + RELOCALIZE_FWD_WIN, last_seg)
		result = _nearest_in_range(pos, wlo, whi)
	return result


## [lo, hi] 세그먼트 범위에서 pos에 대한 최근접 폴리라인 점을 찾는다.
func _nearest_in_range(pos: Vector2, lo: int, hi: int) -> Dictionary:
	var best_d2: float = INF
	var best_i: int = lo
	var best_s: float = s_arr[lo]
	for i in range(lo, hi + 1):
		var a: Vector2 = points[i]
		var ab: Vector2 = points[i + 1] - a
		var len2: float = ab.length_squared()
		var t: float = 0.0
		if len2 > 0.0:
			t = clampf((pos - a).dot(ab) / len2, 0.0, 1.0)
		var proj: Vector2 = a + ab * t
		var d2: float = pos.distance_squared_to(proj)
		if d2 < best_d2:
			best_d2 = d2
			best_i = i
			best_s = s_arr[i] + sqrt(len2) * t
	return {"error": sqrt(best_d2), "s": best_s, "idx": best_i}


func _append(q: Vector2) -> void:
	if points.is_empty():
		s_arr.append(0.0)
	else:
		var last: Vector2 = points[points.size() - 1]
		s_arr.append(s_arr[s_arr.size() - 1] + last.distance_to(q))
	points.append(q)


static func _bezier(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: float) -> Vector2:
	var u: float = 1.0 - t
	return (u * u * u) * a + (3.0 * u * u * t) * b + (3.0 * u * t * t) * c + (t * t * t) * d


static func _to_vec(raw: Variant) -> Vector2:
	var arr: Array = raw
	return Vector2(float(arr[0]), float(arr[1]))
