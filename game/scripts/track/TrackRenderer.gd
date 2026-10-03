class_name TrackRenderer
extends Node2D
## 중심선 + perfect/safe/fail 폭 밴드 시각화 (아키텍처 §10).
##
## 밴드는 중심선을 폭만큼 부풀린 외곽 폴리곤(Geometry2D.offset_polyline, 둥근 조인트·평평한 끝)을
## 삼각형으로 나눠 한 번씩 그린다. 폭×2 두께의 draw_polyline으로 그리던 이전 방식은 곡률 반경이 폭보다
## 작은 급커브에서 삼각형 스트립이 접히고, 겹친 삼각형마다 반투명 알파가 두 번 섞여 바닥에 어두운
## 별 모양·이음선이 생겼다. offset_polyline은 Clipper로 겹침을 합친(union) 외곽을 돌려주므로 밴드의
## 모든 픽셀이 한 번만 합성된다. 세그먼트별 오프셋 quad를 draw_colored_polygon()으로 채우던 더 이전
## 방식의 자기교차("triangulation failed") 문제도 없다.
##
## 루프(닫힌 경로)나 경로가 가까이 지나는 트랙은 외곽 안에 구멍(인필드)이 생긴다. 외곽을 4분 트리 칸으로
## 잘라 칸마다 차집합(clip_polygons)을 구하고, 칸 안에 구멍이 통째로 남으면 칸을 4등분해 다시 자른다.
## 그렇게 얻은 단순 폴리곤만 삼각분할한다. 폴리곤 생성은 setup()에서 1회이며, 생성·삼각분할이 실패한
## 밴드는 경고를 남기고 이전 draw_polyline 방식으로 그린다(표현 전용, TrackData·판정 불변).
##
## 피니시 마커는 FinishLine 노드가 그린다(아키텍처 §2.2).

const BAND_FAIL_COLOR: Color = Color(0.20, 0.15, 0.28, 0.45)
const BAND_SAFE_COLOR: Color = Color(0.32, 0.22, 0.46, 0.55)
const BAND_PERFECT_COLOR: Color = Color(0.55, 0.40, 0.82, 0.55)
const CENTER_COLOR: Color = Color(0.82, 0.68, 1.0, 0.95)
## 4분 트리 분할: 칸 한 변이 CELL_SIZE(월드 px) 이하이고 조각 점 수가 MAX_PIECE_POINTS 이하가 될 때까지
## 나눈다(귀 자르기 삼각분할은 점 수의 제곱에 비례). 최대 깊이 12면 4000px 트랙도 1px 칸까지 내려간다.
const CELL_SIZE: float = 512.0
const MAX_PIECE_POINTS: int = 160
const MAX_SPLIT_DEPTH: int = 12
## 오프셋 전에 중심선을 이 오차(월드 px) 안에서 단순화한다(Ramer-Douglas-Peucker). 베이크 점(약 6px 간격)은
## 완만한 곡선에서 필요 이상으로 촘촘해 Clipper 오프셋·분할 비용만 키운다. 0.1px는 2048 바닥 뷰포트에서
## 0.34px로, 밴드 경계 위치에 보이는 차이가 없다.
const SIMPLIFY_TOLERANCE: float = 0.1
## 첫 점과 끝 점이 min(CLOSED_EPSILON, fail × CLOSED_FAIL_RATIO) 이내면 닫힌 경로로 보고 이음매 없이
## 오프셋한다. 베이크 간격(TrackData.BAKE_INTERVAL = 6px) 수준까지는 손으로 되돌아온 경로도 잇는다.
## 에디터 "루프 닫기"(StrokeProcessor.apply_close_gap)는 시작점에서 fail 이상 떨어진 시작/끝 틈을 일부러
## 남기고, 허브 트랙의 closed 플래그는 TrackData가 읽지 않는 의미 표시다. 그래서 그런 트랙과 공식 트랙
## (시작/끝 간격 55px 이상)은 기존처럼 틈이 보이는 열린 경로로 그린다. fail의 절반을 상한으로 두어 폭이
## 아주 좁은 사용자 트랙에서도 의도한 틈(≥ fail)을 잇지 않는다.
const CLOSED_EPSILON: float = TrackData.BAKE_INTERVAL
const CLOSED_FAIL_RATIO: float = 0.5

## 마지막 setup의 폴리곤 생성 시간(마이크로초). 회귀·성능 보고용.
var last_build_usec: int = 0

var _track: TrackData
## 밴드별 삼각형 메시 {"points": PackedVector2Array, "indices": PackedInt32Array}. 빈 사전이면 폴백.
var _band_meshes: Array = []


func setup(track: TrackData) -> void:
	_track = track
	_band_meshes.clear()
	var t0: int = Time.get_ticks_usec()
	if _track != null and _track.points.size() >= 2:
		var line: Dictionary = prepare_centerline(_track.points, close_tolerance(_track.fail))
		for w in [_track.fail, _track.safe, _track.perfect]:
			var mesh: Dictionary = build_band_mesh_from(line, float(w))
			if mesh.is_empty():
				push_warning(
					"TrackRenderer: 밴드(폭 %.1f) 폴리곤 생성 실패, draw_polyline 폴백" % float(w)
				)
			_band_meshes.append(mesh)
	last_build_usec = Time.get_ticks_usec() - t0
	queue_redraw()


## 밴드 메시를 모두 만들었는지(폴백 없이 그리는지). 회귀 확인용.
func uses_polygon_bands() -> bool:
	if _band_meshes.size() != 3:
		return false
	for m in _band_meshes:
		if (m as Dictionary).is_empty():
			return false
	return true


func _draw() -> void:
	if _track == null or _track.points.size() < 2:
		return
	# 넓은 밴드부터(fail → safe → perfect → 중심선) 겹쳐 그린다.
	var widths: Array = [_track.fail, _track.safe, _track.perfect]
	var colors: Array = [BAND_FAIL_COLOR, BAND_SAFE_COLOR, BAND_PERFECT_COLOR]
	for i in range(3):
		var mesh: Dictionary = _band_meshes[i] if i < _band_meshes.size() else {}
		if mesh.is_empty():
			_draw_band_polyline(float(widths[i]), colors[i])
		else:
			_draw_band_mesh(mesh, colors[i])
	draw_polyline(_track.points, CENTER_COLOR, 2.0)


func _draw_band_mesh(mesh: Dictionary, color: Color) -> void:
	var pts: PackedVector2Array = mesh["points"]
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(pts.size())
	cols.fill(color)
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), mesh["indices"], pts, cols)


## 폴백: 중심선을 따라 폭×2 두께로 그은 폴리라인(급커브에서 겹친 부분이 어둡게 보일 수 있다).
func _draw_band_polyline(width: float, color: Color) -> void:
	draw_polyline(_track.points, color, width * 2.0)


## 중심선을 반폭 width만큼 부풀린 밴드를 겹침 없는 삼각형 메시로 만든다. 실패하면 빈 사전.
static func build_band_mesh(points: PackedVector2Array, width: float) -> Dictionary:
	return build_band_mesh_from(prepare_centerline(points, close_tolerance(width)), width)


## 닫힌 경로로 볼 첫 점·끝 점 거리 상한(fail 기준).
static func close_tolerance(fail: float) -> float:
	return minf(CLOSED_EPSILON, maxf(fail, 0.0) * CLOSED_FAIL_RATIO)


## 오프셋 입력 준비(밴드 3개가 공유): 닫힘 판정과 단순화. 첫 점과 끝 점이 tolerance 이내인 경로를 평평한
## 끝으로 두면 양 끝이 맞닿는 곳에 Clipper 합집합의 머리카락 같은 틈이 남는다. 그래서 END_JOINED로 끝 점과
## 첫 점을 이어 닫는다(두 점이 같으면 중복된 마지막 점은 뺀다). 열린 경로는 평평한 끝(END_BUTT)이다.
static func prepare_centerline(points: PackedVector2Array, tolerance: float) -> Dictionary:
	var src: PackedVector2Array = points
	var gap: float = points[0].distance_to(points[points.size() - 1]) if points.size() > 0 else 0.0
	var closed: bool = points.size() >= 4 and gap <= tolerance
	if closed and gap < 0.01:
		src = points.slice(0, points.size() - 1)
	return {"points": simplify_polyline(src, SIMPLIFY_TOLERANCE), "closed": closed}


static func build_band_mesh_from(line: Dictionary, width: float) -> Dictionary:
	var pts: PackedVector2Array = line.get("points", PackedVector2Array())
	if pts.size() < 2 or width <= 0.0:
		return {}
	var end_type: Geometry2D.PolyEndType = (
		Geometry2D.END_JOINED if bool(line.get("closed", false)) else Geometry2D.END_BUTT
	)
	var polys: Array = Geometry2D.offset_polyline(pts, width, Geometry2D.JOIN_ROUND, end_type)
	var outers: Array = []
	var holes: Array = []
	for p in polys:
		var poly: PackedVector2Array = p
		if poly.size() < 3:
			continue
		# Godot(y 아래) 기준 외곽은 반시계(is_polygon_clockwise=false), 구멍은 시계 방향이다.
		if Geometry2D.is_polygon_clockwise(poly):
			holes.append(poly)
		else:
			outers.append(poly)
	if outers.is_empty():
		return {}
	# 구멍이 없어도 4분 트리로 자른다. 외곽 하나(점 수천 개)를 통째로 귀 자르기 삼각분할하면 점 수의 제곱에
	# 비례해 느려지므로(4096점 트랙 1.4초), 작은 조각으로 나눠 삼각분할한다.
	return _build_with_cells(outers, holes)


## Ramer-Douglas-Peucker 단순화(양 끝점 유지, 반복 스택). 결과 점은 원래 점의 부분 집합이다.
static func simplify_polyline(points: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	var n: int = points.size()
	if n <= 2 or tolerance <= 0.0:
		return points
	var keep: PackedByteArray = PackedByteArray()
	keep.resize(n)
	keep.fill(0)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: PackedInt32Array = PackedInt32Array([0, n - 1])
	while not stack.is_empty():
		var hi: int = stack[stack.size() - 1]
		var lo: int = stack[stack.size() - 2]
		stack.resize(stack.size() - 2)
		var a: Vector2 = points[lo]
		var b: Vector2 = points[hi]
		var best: float = -1.0
		var idx: int = -1
		for i in range(lo + 1, hi):
			var q: Vector2 = Geometry2D.get_closest_point_to_segment(points[i], a, b)
			var d: float = points[i].distance_to(q)
			if d > best:
				best = d
				idx = i
		if idx >= 0 and best > tolerance:
			keep[idx] = 1
			stack.append_array(PackedInt32Array([lo, idx, idx, hi]))
	var out: PackedVector2Array = PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(points[i])
	return out


static func _build_with_cells(outers: Array, holes: Array) -> Dictionary:
	var out_pts: PackedVector2Array = PackedVector2Array()
	var out_idx: PackedInt32Array = PackedInt32Array()
	var bounds: Rect2 = _bounds(outers).grow(1.0)
	if not _fill_cell(bounds, outers, holes, 0, out_pts, out_idx):
		return {}
	if out_idx.is_empty():
		return {}
	return {"points": out_pts, "indices": out_idx}


## 칸 하나(4분 트리): polys는 이미 이 칸으로 잘린 외곽 조각이다. 조각에서 구멍을 빼고, 구멍이 조각 안에
## 통째로 남거나(시계 방향 결과) 조각이 너무 크거나(점 MAX_PIECE_POINTS 초과) 칸이 CELL_SIZE보다 크거나
## 삼각분할이 실패하면 칸을 4등분해 자식 칸으로 잘라 내려보낸다. 부모에서 이미 잘린 조각만 다시 자르므로
## 전체 비용이 점 수 × 깊이에 비례한다. 깊이를 넘기면 false.
static func _fill_cell(
	cell: Rect2,
	polys: Array,
	holes: Array,
	depth: int,
	out_pts: PackedVector2Array,
	out_idx: PackedInt32Array
) -> bool:
	if polys.is_empty():
		return true
	var my_holes: Array = []
	for h in holes:
		if _poly_bounds(h).intersects(cell):
			my_holes.append(h)
	var ok: bool = maxf(cell.size.x, cell.size.y) <= CELL_SIZE
	var pieces: Array = polys
	var total: int = 0
	if ok:
		for h in my_holes:
			var next: Array = []
			for piece in pieces:
				for r in Geometry2D.clip_polygons(piece, h):
					if Geometry2D.is_polygon_clockwise(r):
						ok = false
					next.append(r)
			pieces = next
		for piece in pieces:
			total += (piece as PackedVector2Array).size()
		if total > MAX_PIECE_POINTS:
			ok = false
	if ok:
		var mark_pts: int = out_pts.size()
		var mark_idx: int = out_idx.size()
		for piece in pieces:
			if not _append_triangles(piece, out_pts, out_idx):
				ok = false
				out_pts.resize(mark_pts)
				out_idx.resize(mark_idx)
				break
	if ok:
		return true
	if depth >= MAX_SPLIT_DEPTH:
		return false
	var half: Vector2 = cell.size * 0.5
	for q in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var sub: Rect2 = Rect2(cell.position + half * q, half)
		var rect_poly: PackedVector2Array = PackedVector2Array(
			[
				sub.position,
				Vector2(sub.end.x, sub.position.y),
				sub.end,
				Vector2(sub.position.x, sub.end.y),
			]
		)
		# 외곽 조각과 구멍을 모두 자식 칸으로 잘라 내려보낸다(칸 안의 구멍 조각을 빼는 것은 구멍 전체를
		# 빼는 것과 같다). 큰 구멍을 칸마다 통째로 빼지 않으므로 루프 트랙도 점 수 × 깊이 비용이다.
		var child: Array = _clip_to(polys, sub, rect_poly)
		var child_holes: Array = _clip_to(my_holes, sub, rect_poly)
		if not _fill_cell(sub, child, child_holes, depth + 1, out_pts, out_idx):
			return false
	return true


static func _clip_to(polys: Array, sub: Rect2, rect_poly: PackedVector2Array) -> Array:
	var out: Array = []
	for p in polys:
		if not _poly_bounds(p).intersects(sub):
			continue
		for r in Geometry2D.intersect_polygons(p, rect_poly):
			out.append(r)
	return out


static func _append_triangles(
	poly: PackedVector2Array, out_pts: PackedVector2Array, out_idx: PackedInt32Array
) -> bool:
	if poly.size() < 3:
		return true
	var tri: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
	if tri.is_empty():
		return false
	var base: int = out_pts.size()
	out_pts.append_array(poly)
	for i in tri:
		out_idx.append(base + i)
	return true


static func _poly_bounds(poly: PackedVector2Array) -> Rect2:
	var r: Rect2 = Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


static func _bounds(polys: Array) -> Rect2:
	var r: Rect2 = _poly_bounds(polys[0])
	for p in polys:
		r = r.merge(_poly_bounds(p))
	return r
