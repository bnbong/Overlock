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


func bake(path_json: Array) -> void:
	points = PackedVector2Array()
	s_arr = PackedFloat32Array()
	for seg in path_json:
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
	if s_arr.size() > 0:
		length = s_arr[s_arr.size() - 1]
	else:
		length = 0.0


func start_heading() -> float:
	if points.size() >= 2:
		return (points[1] - points[0]).angle()
	return 0.0


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
