extends Node
## 트랙 밴드(TrackRenderer) 렌더 회귀 검사. 비-headless 전용(실제 렌더 결과를 읽는다).
##
## 단색 바닥 위에 TrackRenderer만 그린 SubViewport를 트랙마다 렌더하고 두 가지를 잰다.
##  (A) 겹침: 화면의 모든 픽셀이 "바닥 / fail / fail+safe / fail+safe+perfect 합성색"(+중심선) 중 하나여야
##      한다. 반투명 밴드가 겹쳐 두 번 합성된 픽셀(급커브의 별 모양·이음선)은 어느 합성색과도 맞지 않는다.
##  (B) 영역: 중심선까지의 거리로 정한 기대 영역(바닥/fail/safe/perfect)과 실제 픽셀의 합성색 분류가 같아야
##      한다. 구멍(인필드) 누락, 튀는 삼각형, 밴드 누락을 잡는다. 경계 근처(±1.5px)·중심선 근처·양 끝
##      (평평한 끝 처리) 근처는 제외한다.
## 회전과 무관한 정지 렌더라 드리프트 피벗 방향에 좌우되지 않는다. 폴리곤 생성 시간과 폴백 여부도 확인한다.
## 인자(-- 뒤): --fixtures=<dir> --out=<dir>(선택, 렌더 PNG 저장) --legacy-ok(이전 렌더러 측정용: 실패를 보고만)

const OFFICIAL_INDEX: String = "res://tracks/official/index.json"
const OFFICIAL_DIR: String = "res://tracks/official/"
const VP_SIZE: int = 1024
const FLOOR: Color = Color(0.62, 0.58, 0.25, 1.0)
const TOL: int = 4  # 채널 허용 오차(/255)
const MAX_INVALID_RATIO: float = 0.00003  # (A) 합성색에 맞지 않는 픽셀 비율 상한(약 30px/1M)
const MAX_MISMATCH_RATIO: float = 0.00002  # (B) 기대 영역과 다른 표본 비율 상한(약 5개/25만)
const SAMPLE_STRIDE: int = 2
const MAX_BUILD_MS: float = 60.0  # 트랙 1개(밴드 3개) 폴리곤 생성 시간 상한
const MIN_PASSED: int = 80

var _passed: int = 0
var _failed: int = 0
var _fixtures: String = ""
var _out: String = ""
var _legacy: bool = false
var _vp: SubViewport
var _world: Node2D
var _cam: Camera2D
var _bg: Polygon2D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fixtures="):
			_fixtures = a.substr(11)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a == "--legacy-ok":
			_legacy = true
	if not _out.is_empty():
		DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _run() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_world = Node2D.new()
	_vp.add_child(_world)
	_bg = Polygon2D.new()
	_bg.color = FLOOR
	_world.add_child(_bg)
	_cam = Camera2D.new()
	_world.add_child(_cam)
	_cam.make_current()
	var cases: Array = _official_cases() + _fixture_cases() + _synthetic_cases()
	_ok(cases.size() >= 15 + 5 + 4 + 3, "case count %d" % cases.size())
	for c in cases:
		await _check_case(c)
	if _passed < MIN_PASSED:
		_failed += 1
		print("FAIL: too few assertions (%d < %d)" % [_passed, MIN_PASSED])
	print("track band regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ------------------------------------------------------------------ cases


static func _track_from_dict(d: Dictionary) -> TrackData:
	var t: TrackData = TrackData.new()
	var w: Dictionary = d.get("width", {})
	t.perfect = float(w.get("perfect", 18.0))
	t.safe = float(w.get("safe", 42.0))
	t.fail = float(w.get("fail", 90.0))
	t.bake(d.get("path", []))
	return t


func _official_cases() -> Array:
	var out: Array = []
	var idx: Variant = JSON.parse_string(FileAccess.get_file_as_string(OFFICIAL_INDEX))
	for e in (idx as Dictionary).get("tracks", []):
		var id: String = str(e["track_id"])
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(OFFICIAL_DIR + id + ".json"))
		out.append({"name": id, "track": _track_from_dict(d)})
	return out


func _fixture_cases() -> Array:
	var out: Array = []
	if _fixtures.is_empty():
		return out
	var dir: DirAccess = DirAccess.open(_fixtures)
	if dir == null:
		return out
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for n in names:
		if not n.ends_with(".json"):
			continue
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_fixtures + "/" + n))
		if d is Dictionary and (d as Dictionary).has("track"):
			out.append({"name": n.get_basename(), "track": _track_from_dict(d["track"])})
	return out


static func _synthetic(name: String, pts: PackedVector2Array, w: Vector3) -> Dictionary:
	var t: TrackData = TrackData.new()
	t.points = pts
	t.perfect = w.x
	t.safe = w.y
	t.fail = w.z
	return {"name": name, "track": t}


## 닫힌 원(인필드 구멍), 8자 교차, 최소 반경 지그재그, 4096점 긴 트랙.
func _synthetic_cases() -> Array:
	var out: Array = []
	var ring: PackedVector2Array = PackedVector2Array()
	for i in 315:
		var a: float = TAU * float(i) / 314.0
		ring.append(Vector2(cos(a), sin(a)) * 300.0)
	out.append(_synthetic("synthetic_closed_ring", ring, Vector3(18, 42, 90)))
	var eight: PackedVector2Array = PackedVector2Array()
	for i in 629:
		var a: float = TAU * float(i) / 628.0
		eight.append(Vector2(sin(a) * 400.0, sin(2.0 * a) * 200.0))
	out.append(_synthetic("synthetic_figure_eight", eight, Vector3(14, 34, 72)))
	# 반경 28(TrackValidator.MIN_RADIUS) 반원 U턴을 직선으로 이은 지그재그. fail 90 >> 반경.
	var zig: PackedVector2Array = PackedVector2Array()
	var x0: float = 0.0
	for k in 6:
		var top: bool = k % 2 == 0
		var y_from: float = 0.0 if top else 300.0
		var y_to: float = 300.0 if top else 0.0
		var steps: int = 50
		for j in steps:
			zig.append(Vector2(x0, lerpf(y_from, y_to, float(j) / steps)))
		var cy: float = y_to
		for j in 15:
			var a: float = PI * float(j) / 15.0
			var sgn: float = 1.0 if top else -1.0
			zig.append(Vector2(x0 + 28.0 - cos(a) * 28.0, cy + sgn * sin(a) * 28.0))
		x0 += 56.0
	out.append(_synthetic("synthetic_min_radius_zigzag", zig, Vector3(18, 42, 90)))
	# 4096점(간격 약 2px) 닫힌 물결 루프: 생성 시간 측정용(첫 점 = 끝 점).
	var big: PackedVector2Array = PackedVector2Array()
	for i in 4096:
		var a: float = TAU * float(i) / 4095.0
		var r: float = 1200.0 + 260.0 * sin(a * 14.0)
		big.append(Vector2(cos(a), sin(a)) * r)
	out.append(_synthetic("synthetic_4096_points", big, Vector3(14, 34, 72)))
	out.append_array(_loop_cases())
	return out


## 루프 닫기·closed 트랙. 저장(JSON) → 로드(TrackData.bake) 왕복을 거친 점 열로 검사한다.
##  - editor_loop_close: 에디터 경로 처리(StrokeProcessor.apply_close_gap)로 루프를 닫고 EditorDoc.to_track_dict로
##    저장한 트랙. 루프 닫기는 시작점에서 fail 이상 떨어진 시작/끝 틈을 일부러 남기므로 열린 경로로 그려야
##    한다(틈을 잇지 않음).
##  - hub_closed_exact: closed=true이고 끝 점이 첫 점으로 정확히 돌아오는 트랙(허브·수작업 JSON). 이음매 없이
##    닫아야 한다.
##  - hub_closed_near: closed=true이고 끝 점이 첫 점에서 3px 떨어진 트랙. 베이크 간격 이내라 이어서 닫는다.
## 닫힌 경로로 그리는 경우는 양 끝 제외 영역 없이 영역 검사를 하므로 이음매 틈 픽셀이 있으면 실패한다.
func _loop_cases() -> Array:
	var out: Array = []
	var w: Dictionary = EditorDoc.preset_width("normal")
	var fail: float = float(w["fail"])
	# 시작점을 조금 지나쳐 그린(꼬리가 시작점 fail 반경 안으로 들어온) 타원 스트로크. 루프 닫기가 꼬리를 걷어낸다.
	var stroke: PackedVector2Array = PackedVector2Array()
	for i in 326:
		var a: float = TAU * float(i) / 320.0
		stroke.append(Vector2(cos(a) * 420.0, sin(a) * 300.0))
	var doc: Dictionary = EditorDoc.make(1)
	doc["local_id"] = "custom_band_loop"
	doc["width"] = w
	doc["path"] = StrokeProcessor.new().apply_close_gap(stroke, fail)
	doc["closed"] = true
	var saved: String = JSON.stringify(EditorDoc.to_track_dict(doc))
	var loaded: Dictionary = JSON.parse_string(saved)
	out.append(
		{
			"name": "editor_loop_close_roundtrip",
			"track": _track_from_dict(loaded),
			"expect_closed": false,
			"min_gap": fail,
			"saved_closed": loaded["path"][0].get("closed", false) == true,
		}
	)
	for spec in [["hub_closed_exact", 0.0], ["hub_closed_near", 3.0]]:
		var pts: Array = []
		for i in 300:
			var a: float = TAU * float(i) / 300.0
			pts.append([snappedf(cos(a) * 380.0, 0.1), snappedf(sin(a) * 260.0, 0.1)])
		pts.append([380.0, -float(spec[1])])
		var d: Dictionary = {
			"width": w, "path": [{"type": "polyline", "points": pts, "closed": true}]
		}
		var back: Dictionary = JSON.parse_string(JSON.stringify(d))
		out.append(
			{"name": spec[0], "track": _track_from_dict(back), "expect_closed": true}
		)
	return out


# ------------------------------------------------------------------ check


func _check_case(c: Dictionary) -> void:
	var name: String = c["name"]
	var t: TrackData = c["track"]
	if t.points.size() < 2:
		_ok(false, "%s: no points" % name)
		return
	var bb: Rect2 = Rect2(t.points[0], Vector2.ZERO)
	for p in t.points:
		bb = bb.expand(p)
	bb = bb.grow(t.fail + 20.0)
	var scale: float = float(VP_SIZE) / maxf(bb.size.x, bb.size.y)
	_cam.position = bb.get_center()
	_cam.zoom = Vector2(scale, scale)
	var big: Rect2 = bb.grow(maxf(bb.size.x, bb.size.y))
	_bg.polygon = PackedVector2Array(
		[big.position, Vector2(big.end.x, big.position.y), big.end, Vector2(big.position.x, big.end.y)]
	)
	var tr: TrackRenderer = TrackRenderer.new()
	_world.add_child(tr)
	tr.setup(t)
	await _frames(3)
	var img: Image = _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	if not _out.is_empty():
		img.save_png("%s/%s.png" % [_out, name])
	var build_ms: float = -1.0
	if "last_build_usec" in tr:
		build_ms = float(tr.get("last_build_usec")) / 1000.0
	var poly_ok: bool = tr.has_method("uses_polygon_bands") and bool(tr.call("uses_polygon_bands"))
	tr.queue_free()
	await get_tree().process_frame
	var tol: float = TrackRenderer.close_tolerance(t.fail)
	var closed: bool = bool(TrackRenderer.prepare_centerline(t.points, tol)["closed"])
	var res: Dictionary = _measure(img, t, bb, scale, closed)
	print(
		(
			"BAND %-34s pts=%5d build_ms=%7.2f polygon=%s invalid=%.5f mismatch=%.5f (n=%d)"
			% [name, t.points.size(), build_ms, poly_ok, res["invalid"], res["mismatch"], res["samples"]]
		)
	)
	if _legacy:
		return
	if c.has("expect_closed"):
		_ok(closed == bool(c["expect_closed"]), "%s: closed=%s" % [name, closed])
	if c.has("min_gap"):
		var gap: float = t.points[0].distance_to(t.points[t.points.size() - 1])
		_ok(gap >= float(c["min_gap"]), "%s: start/finish gap %.1f >= fail" % [name, gap])
		_ok(bool(c.get("saved_closed", false)), "%s: saved closed flag" % name)
	_ok(poly_ok, "%s: polygon bands (no draw_polyline fallback)" % name)
	_ok(build_ms >= 0.0 and build_ms <= MAX_BUILD_MS, "%s: build %.2f ms" % [name, build_ms])
	_ok(res["invalid"] <= MAX_INVALID_RATIO, "%s: double-blend pixels %.5f" % [name, res["invalid"]])
	_ok(res["mismatch"] <= MAX_MISMATCH_RATIO, "%s: region mismatch %.5f" % [name, res["mismatch"]])


static func _over(src: Color, dst: Vector3i) -> Vector3i:
	return Vector3i(
		roundi((src.r * src.a) * 255.0 + float(dst.x) * (1.0 - src.a)),
		roundi((src.g * src.a) * 255.0 + float(dst.y) * (1.0 - src.a)),
		roundi((src.b * src.a) * 255.0 + float(dst.z) * (1.0 - src.a))
	)


## 픽셀 분류: 0=바닥 1=fail 2=fail+safe 3=fail+safe+perfect, 4=중심선, -1=어느 합성색에도 맞지 않음.
static func _classify(c: Vector3i, refs: Array) -> int:
	for k in refs.size():
		var r: Vector3i = refs[k][0]
		if absi(c.x - r.x) <= TOL and absi(c.y - r.y) <= TOL and absi(c.z - r.z) <= TOL:
			return int(refs[k][1])
	return -1


func _measure(img: Image, t: TrackData, bb: Rect2, scale: float, closed: bool) -> Dictionary:
	var c0: Vector3i = Vector3i(
		roundi(FLOOR.r * 255.0), roundi(FLOOR.g * 255.0), roundi(FLOOR.b * 255.0)
	)
	var f: Vector3i = _over(TrackRenderer.BAND_FAIL_COLOR, c0)
	var fs: Vector3i = _over(TrackRenderer.BAND_SAFE_COLOR, f)
	var fsp: Vector3i = _over(TrackRenderer.BAND_PERFECT_COLOR, fs)
	var refs: Array = [[c0, 0], [f, 1], [fs, 2], [fsp, 3]]
	# 중심선(폭 2 draw_polyline)은 경로가 스스로 교차·겹치는 곳에서 두 번 합성될 수 있다. 밴드 겹침만 보려고
	# 중심선 위 중심선도 유효색으로 둔다.
	for base in [c0, f, fs, fsp]:
		var once: Vector3i = _over(TrackRenderer.CENTER_COLOR, base)
		refs.append([once, 4])
		refs.append([_over(TrackRenderer.CENTER_COLOR, once), 4])
	var data: PackedByteArray = img.get_data()
	var w: int = img.get_width()
	var h: int = img.get_height()
	# (A) 모든 픽셀이 유효 합성색인지.
	var invalid: int = 0
	var n: int = w * h
	for i in n:
		var o: int = i * 4
		if _classify(Vector3i(data[o], data[o + 1], data[o + 2]), refs) < 0:
			invalid += 1
	# (B) 거리 기반 기대 영역과 비교(표본).
	var cell: float = t.fail + 4.0
	var dpts: PackedVector2Array = t.points.duplicate()
	if closed:
		dpts.append(t.points[0])
	var bins: Dictionary = _bin_segments(dpts, cell)
	var margin: float = 1.5 / scale
	var origin: Vector2 = bb.get_center() - Vector2(w, h) * 0.5 / scale
	var p_first: Vector2 = t.points[0]
	var p_last: Vector2 = t.points[t.points.size() - 1]
	# 닫힌 경로는 끝 처리가 없으므로 양 끝 제외 영역을 두지 않는다(이음매 틈도 잡는다). 닫힌 경로로 이은
	# 끝 점과 첫 점 사이의 짧은 구간은 중심선 거리에 포함한다.
	var widths: Array = [t.perfect, t.safe, t.fail]
	var samples: int = 0
	var mismatch: int = 0
	for py in range(0, h, SAMPLE_STRIDE):
		for px in range(0, w, SAMPLE_STRIDE):
			var wp: Vector2 = origin + (Vector2(px, py) + Vector2(0.5, 0.5)) / scale
			if (
				not closed
				and (wp.distance_to(p_first) < t.fail + 3.0 or wp.distance_to(p_last) < t.fail + 3.0)
			):
				continue
			var d: float = _dist(wp, dpts, bins, cell)
			if d < 1.0 + margin * 2.0:
				continue
			var expect: int = 0
			var near_edge: bool = false
			for k in 3:
				if absf(d - float(widths[k])) < margin:
					near_edge = true
			if near_edge:
				continue
			if d < t.perfect:
				expect = 3
			elif d < t.safe:
				expect = 2
			elif d < t.fail:
				expect = 1
			var o: int = (py * w + px) * 4
			var got: int = _classify(Vector3i(data[o], data[o + 1], data[o + 2]), refs)
			samples += 1
			if got != expect and got != 4:
				mismatch += 1
	return {
		"invalid": float(invalid) / float(n),
		"mismatch": float(mismatch) / float(maxi(samples, 1)),
		"samples": samples,
	}


static func _bin_segments(pts: PackedVector2Array, cell: float) -> Dictionary:
	var bins: Dictionary = {}
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var x0: int = floori(minf(a.x, b.x) / cell)
		var x1: int = floori(maxf(a.x, b.x) / cell)
		var y0: int = floori(minf(a.y, b.y) / cell)
		var y1: int = floori(maxf(a.y, b.y) / cell)
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var key: Vector2i = Vector2i(gx, gy)
				if not bins.has(key):
					bins[key] = PackedInt32Array()
				var arr: PackedInt32Array = bins[key]
				arr.append(i)
				bins[key] = arr
	return bins


## 중심선까지의 거리(cell 이내만 정확, 그 밖은 큰 값).
static func _dist(p: Vector2, pts: PackedVector2Array, bins: Dictionary, cell: float) -> float:
	var gx: int = floori(p.x / cell)
	var gy: int = floori(p.y / cell)
	var best: float = 1e9
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key: Vector2i = Vector2i(gx + dx, gy + dy)
			if not bins.has(key):
				continue
			for i in bins[key]:
				var q: Vector2 = Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
				best = minf(best, p.distance_to(q))
	return best
