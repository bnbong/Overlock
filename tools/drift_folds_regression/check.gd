extends "res://drift_folds_regression/check_game.gd"
## 드리프트 원단 주름 회귀 검사(사본 프로젝트 전용, run.sh가 실행).
##
## 확인 항목:
##  projection : h=0 투영이 바닥 Mode 7 셰이더의 역식·ItemBillboardLayer 식과 같음, 높이·원근 방향,
##               수평선·카메라 뒤 클리핑(유한·유계), 셰이더 상수 일치.
##  time_model : 솟음·유지·완화·잔여 시간 범위와 단조성.
##  strokes    : 스트로크 시작·간격·종료·반전·순간이동 끊김, 좌우 부호, 버퍼 상한, clear.
##  layer      : 활성 패치 상한(12), 원경·카메라 뒤 컬링, CPU 비용(패치 12개·흔적 400개).
##  game_*     : Gameplay 씬 수동 틱. 연출 ON/OFF 시뮬 동일, 카운트다운·완주 전환 생성 없음, 완주 뷰
##               레코드 공유, 일시정지 정지, 강제 복귀·순간이동 끊김, 좌/우 부호와 손 누름, 재시작 초기화.
## 실패한 assertion이 하나라도 있으면 종료 코드 1.


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	LeaderboardClient.tutorial_seen = true
	_run.call_deferred()


func _run() -> void:
	_ok(DriftFoldShape.ensure(), "shape: height map loaded")
	_check_projection()
	_check_shader_constants()
	_check_time_model()
	await _check_strokes()
	await _check_layer()
	await _check_game_on_off()
	await _check_game_gates()
	await _check_game_breaks()
	await _check_game_sign()
	await _check_game_pause()
	await _check_game_restart()
	if _passed < MIN_PASSED:
		_failed += 1
		print("FAIL: too few assertions (%d < %d)" % [_passed, MIN_PASSED])
	print("drift folds regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------- projection


## fabric_mode7.gdshader fragment의 화면 uv → 월드 오프셋(GDScript 재현, 클램프 포함).
func _mode7_world_off(uv: Vector2, heading: float) -> Vector2:
	var dy: float = maxf(uv.y - PresentationController.HORIZON, 1e-3)
	var depth: float = PresentationController.DEPTH_SCALE / dy
	var lateral: float = (uv.x - 0.5) * depth * PresentationController.SPREAD
	var forward: float = depth - PresentationController.CAM_BACK
	var fwd: Vector2 = Vector2(cos(heading), sin(heading))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	return fwd * forward + rgt * lateral


func _check_projection() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var max_err: float = 0.0
	var max_bb: float = 0.0
	for i in 400:
		var heading: float = rng.randf_range(-PI, PI)
		var ppos: Vector2 = Vector2(rng.randf_range(-800, 800), rng.randf_range(-800, 800))
		var fwd: Vector2 = Vector2(cos(heading), sin(heading))
		var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
		# 화면에 보이는 바닥 범위(depth 48..400, |lateral| < depth*spread/2).
		var depth: float = rng.randf_range(48.0, 400.0)
		var lat: float = rng.randf_range(-0.45, 0.45) * depth * PresentationController.SPREAD
		var p: Vector2 = ppos + fwd * (depth - PresentationController.CAM_BACK) + rgt * lat
		var pr: Vector3 = DriftFoldLayer.project(p, 0.0, ppos, heading, SCREEN)
		var uv: Vector2 = Vector2(pr.x / SCREEN.x, pr.y / SCREEN.y)
		var back: Vector2 = _mode7_world_off(uv, heading)
		max_err = maxf(max_err, back.distance_to(p - ppos))
		# ItemBillboardLayer 접지 좌표 식(같은 투영 단일 소스).
		var d: Vector2 = p - ppos
		var bd: float = d.dot(fwd) + PresentationController.CAM_BACK
		var gx: float = (0.5 + d.dot(rgt) / (bd * PresentationController.SPREAD)) * SCREEN.x
		var gy: float = (
			(PresentationController.HORIZON + PresentationController.DEPTH_SCALE / bd) * SCREEN.y
		)
		max_bb = maxf(max_bb, Vector2(gx, gy).distance_to(Vector2(pr.x, pr.y)))
	print(
		(
			"projection: h=0 max world error %.6f px, billboard max screen diff %.6f px"
			% [max_err, max_bb]
		)
	)
	_ok(max_err < 1e-3, "projection: h=0 matches Mode 7 inverse (%.6f)" % max_err)
	_ok(max_bb < 1e-3, "projection: h=0 matches billboard ground formula (%.6f)" % max_bb)
	# 높이: 위로 솟고(화면 y 감소), 같은 높이라도 멀수록 덜 솟는다.
	var near_p: Vector3 = DriftFoldLayer.project(Vector2(-60, 0), 0.0, Vector2.ZERO, 0.0, SCREEN)
	var near_h: Vector3 = DriftFoldLayer.project(Vector2(-60, 0), 2.0, Vector2.ZERO, 0.0, SCREEN)
	var far_p: Vector3 = DriftFoldLayer.project(Vector2(150, 0), 0.0, Vector2.ZERO, 0.0, SCREEN)
	var far_h: Vector3 = DriftFoldLayer.project(Vector2(150, 0), 2.0, Vector2.ZERO, 0.0, SCREEN)
	_ok(near_h.y < near_p.y and far_h.y < far_p.y, "projection: height lifts upward")
	_ok(near_p.y - near_h.y > far_p.y - far_h.y, "projection: nearer lifts more")
	_ok(is_equal_approx(near_h.x, near_p.x), "projection: height keeps screen x")
	var lift: float = near_p.y - near_h.y
	var expect: float = 2.0 * DriftFoldLayer.lift_px_per_unit(80.0, SCREEN)
	_ok(absf(lift - expect) < 1e-3, "projection: lift_px_per_unit consistent")
	var row_px: float = DriftFoldLayer.lift_px_per_unit(PresentationController.CAM_BACK, SCREEN)
	print(
		(
			"projection: 1 world unit lifts %.2f px at the needle row (depth %.0f)"
			% [row_px, PresentationController.CAM_BACK]
		)
	)
	_ok(row_px > 9.0 and row_px < 11.5, "projection: ~10px per unit at needle row")
	# 수평선·카메라 뒤 클리핑: 깊이 -400..3000 전 구간에서 유한하고 화면 아래로 무한히 튀지 않는다.
	var finite: bool = true
	var bounded: bool = true
	var ymax: float = (
		(
			PresentationController.HORIZON
			+ PresentationController.DEPTH_SCALE / DriftFoldLayer.NEAR_CLIP
		)
		* SCREEN.y
	)
	for k in range(-400, 3000, 7):
		for z in [0.0, 3.0, 12.0]:
			var q: Vector3 = DriftFoldLayer.project(
				Vector2(float(k) - PresentationController.CAM_BACK, 37.0),
				z,
				Vector2.ZERO,
				0.0,
				SCREEN
			)
			if not (is_finite(q.x) and is_finite(q.y)):
				finite = false
			if q.y > ymax + 0.001 or absf(q.x) > 1e6:
				bounded = false
	_ok(finite, "clip: projection finite for every depth incl. behind camera")
	_ok(bounded, "clip: near-clip bounds screen y (<= %.0f)" % ymax)
	var hz: Vector3 = DriftFoldLayer.project(Vector2(5000, 0), 0.0, Vector2.ZERO, 0.0, SCREEN)
	_ok(hz.y > PresentationController.HORIZON * SCREEN.y, "clip: far ground stays below horizon")


func _check_shader_constants() -> void:
	var f: FileAccess = FileAccess.open("res://shaders/drift_fold.gdshader", FileAccess.READ)
	_ok(f != null, "shader: file readable")
	if f == null:
		return
	var src: String = f.get_as_text()
	# 리뷰 5: 깊이 하한(NEAR_CLIP)으로 눌린 정점은 근경 감쇠 구간보다 가까워 표면 알파가 0이어야 한다.
	_ok(
		src.contains("force_flat ? 1.0 : COLOR.b * near_k"),
		"near clip: surface alpha fades with near_k (clamped vertices invisible)"
	)
	_ok(
		DriftFoldLayer.NEAR_CLIP < DriftFoldLayer.NEAR_FADE_LO and DriftFoldLayer.NEAR_CLIP >= 24.0,
		"near clip: clamp depth raised and below the fade band"
	)
	_ok(
		src.contains("const float GRAD_RANGE = %.1f;" % DriftFoldLayer.GRAD_RANGE),
		"shader: GRAD_RANGE matches"
	)
	_ok(src.contains("(1.0 - z / cam_height)"), "shader: same height projection term")
	_ok(
		src.contains("max_lift_px / max(px_per_unit, 1e-4)"),
		"shader: same screen lift cap as GDScript"
	)
	_ok(src.contains("vec2(0.5) + (v_wd / v_id) / coverage"), "shader: world UV like Mode 7 source")
	_ok(not src.contains("source_color"), "shader: no source_color hint (data sampling)")
	var imp: String = FileAccess.get_file_as_string(
		"res://assets/gfx/drift_folds/fold_height.png.import"
	)
	_ok(imp.contains("compress/mode=0"), "asset: lossless import")
	_ok(imp.contains("mipmaps/generate=false"), "asset: no mipmaps")
	_ok(imp.contains("detect_3d/compress_to=0"), "asset: never auto-VRAM compressed")


# ---------------------------------------------------------------- time model


func _check_time_model() -> void:
	_ok(DriftFoldShape.RISE >= 0.08 and DriftFoldShape.RISE <= 0.15, "time: rise in 0.08..0.15 s")
	_ok(
		DriftFoldShape.RELAX >= 0.35 and DriftFoldShape.RELAX <= 0.65, "time: relax in 0.35..0.65 s"
	)
	var born: float = 10.0
	var relax: float = born + 0.35  # 0.35초 드리프트 후 종료
	_ok(DriftFoldShape.amp01(born, relax, born) == 0.0, "time: flat at birth")
	_ok(DriftFoldShape.amp01(born, relax, born - 1.0) == 0.0, "time: nothing before birth")
	_ok(
		DriftFoldShape.amp01(born, relax, born + DriftFoldShape.RISE) > 0.999,
		"time: risen after RISE"
	)
	var mono: bool = true
	var prev: float = -1.0
	for i in range(0, 13):
		var a: float = DriftFoldShape.amp01(
			born, relax, born + DriftFoldShape.RISE * float(i) / 12.0
		)
		if a < prev - 1e-6:
			mono = false
		prev = a
	_ok(mono, "time: rise monotonic")
	var dec: bool = true
	prev = 2.0
	for i in range(0, 41):
		var a2: float = DriftFoldShape.amp01(born, relax, relax + 4.0 * float(i) / 40.0)
		if a2 > prev + 1e-6:
			dec = false
		prev = a2
	_ok(dec, "time: relax monotonic")
	var res: float = DriftFoldShape.amp01(born, relax, relax + DriftFoldShape.RELAX)
	_ok(absf(res - DriftFoldShape.RESIDUE) < 1e-4, "time: residue height after relax")
	var gone: float = DriftFoldShape.amp01(born, relax, DriftFoldShape.amp_end_time(relax) + 0.01)
	_ok(gone == 0.0, "time: mesh height gone after residue fade")
	# 리뷰 1: 솟음(RISE) 전에 드리프트가 끝나면 종료 시점에 도달한 높이에서 낮아지기만 해야 한다.
	var early: float = born + 0.02
	var at_end: float = DriftFoldShape.amp01(born, early, early)
	var never_up: bool = true
	var worst_after: float = 0.0
	for i in range(1, 121):
		var tt: float = early + 2.0 * float(i) / 120.0
		var a3: float = DriftFoldShape.amp01(born, early, tt)
		worst_after = maxf(worst_after, a3)
		if a3 > at_end + 1e-6:
			never_up = false
	print(
		"time: early end (+0.02s) height at end %.3f, max afterwards %.3f" % [at_end, worst_after]
	)
	_ok(never_up, "time: early drift end never rises after release")


# ---------------------------------------------------------------- strokes


func _new_skid() -> DriftSkid:
	var s: DriftSkid = DriftSkid.new()
	add_child(s)
	return s


## heading 방향 직선을 step px 간격으로 n번 push한다. 반환: 마지막 위치.
func _push_line(
	s: DriftSkid, start: Vector2, heading: float, dir: float, n: int, t0: float, step: float = 4.0
) -> Vector2:
	var fwd: Vector2 = Vector2(cos(heading), sin(heading))
	var p: Vector2 = start
	for i in n:
		p = start + fwd * step * float(i)
		s.push(p, dir, absf(dir), t0 + float(i) / 60.0, heading)
	return p


func _check_strokes() -> void:
	var s: DriftSkid = _new_skid()
	await _frames(1)
	# 시작 즉시 패치 1개, 이후 경로 FOLD_SPACING마다.
	s.push(Vector2.ZERO, 0.8, 0.8, 1.0, 0.0)
	_ok(s.get_near_folds().size() == 1, "stroke: patch at drift start")
	_ok(s.is_stroke_active() and s.stroke_id() == 1, "stroke: stroke 1 active")
	var last: Vector2 = _push_line(s, Vector2.ZERO, 0.0, 0.8, 60, 1.0)
	var expect: int = 1 + int(floor(last.x / DriftSkid.FOLD_SPACING))
	var n1: int = s.get_near_folds().size()
	_ok(absi(n1 - expect) <= 1, "stroke: one patch per FOLD_SPACING (%d vs %d)" % [n1, expect])
	var all_same: bool = true
	for rec in s.get_near_folds():
		if int(rec["stroke"]) != 1 or float(rec["side"]) != 1.0:
			all_same = false
	_ok(all_same, "stroke: same stroke & side")
	# 좌우 부호: dir>0이면 진행 방향 오른쪽(rgt = (-fwd.y, fwd.x))에 패치 중심.
	var r0: Dictionary = s.get_near_folds()[0]
	var rgt0: Vector2 = Vector2(0.0, 1.0)
	_ok(
		(Vector2(r0["pos"]) - Vector2.ZERO).dot(rgt0) > DriftSkid.FLAT_HALF,
		"sign: right drift folds on right"
	)
	# 재봉선 평평 구간: 패치 안쪽 가장자리가 진행선에서 FLAT_HALF 떨어져 있다.
	var inner: float = (Vector2(r0["c"][0]) + Vector2(r0["n"][0]) * float(r0["off"])).y
	_ok(absf(inner - DriftSkid.FLAT_HALF) < 1e-3, "flat: inner edge at FLAT_HALF from seam")
	# 패치 높이 0 경계: 격자 테두리 높이가 0.
	var edge_zero: bool = true
	var gh: PackedFloat32Array = DriftFoldShape.grid_h
	var w: int = DriftFoldShape.NU + 1
	for j in range(DriftFoldShape.NV + 1):
		for i in [0, DriftFoldShape.NU]:
			if gh[j * w + i] > 1e-4:
				edge_zero = false
	for i in range(w):
		if gh[i] > 1e-4 or gh[DriftFoldShape.NV * w + i] > 1e-4:
			edge_zero = false
	_ok(edge_zero, "shape: patch border height is 0")
	# 능선 개수와 폭: 높이 봉우리 행에서 u 방향 극대(높이 0.2 이상)와 반높이 폭(셀).
	var row: int = int(round(DriftFoldShape.PEAK_V * DriftFoldShape.NV))
	var peaks: int = 0
	var min_width: int = 999
	for i in range(1, DriftFoldShape.NU):
		var c0: float = gh[row * w + i]
		if c0 >= 0.2 and c0 >= gh[row * w + i - 1] and c0 > gh[row * w + i + 1]:
			peaks += 1
			var half: float = c0 * 0.5
			var lo: int = i
			var hi: int = i
			while lo > 0 and gh[row * w + lo - 1] >= half:
				lo -= 1
			while hi < DriftFoldShape.NU and gh[row * w + hi + 1] >= half:
				hi += 1
			min_width = mini(min_width, hi - lo + 1)
	print(
		(
			"shape: %d ridges at the peak row, narrowest half-height width %d lateral cells"
			% [peaks, min_width]
		)
	)
	_ok(peaks >= 2 and peaks <= 3, "shape: 2..3 broad ridges")
	_ok(min_width >= 3, "shape: each ridge spans >= 3 lateral cells")
	# 종료: relax ≤ 종료 시각, 다음 push는 새 스트로크.
	s.end_stroke(3.0)
	var relaxed: bool = true
	for rec in s.get_near_folds():
		if float(rec["relax"]) > 3.0 + 1e-6:
			relaxed = false
	_ok(relaxed, "stroke: end_stroke starts relaxing")
	_ok(not s.is_stroke_active(), "stroke: inactive after end")
	s.push(last + Vector2(30, 0), 0.8, 0.8, 3.1, 0.0)
	_ok(s.stroke_id() == 2, "stroke: restart after end -> new stroke")
	# 반전: 부호가 바뀌면 새 스트로크, 이전 패치 방향은 그대로.
	var before: int = s.get_near_folds().size()
	var p2: Vector2 = last + Vector2(30, 0)
	s.push(p2 + Vector2(10, 0), -0.7, 0.7, 3.2, 0.0)
	_ok(s.stroke_id() == 3, "reverse: sign flip -> new stroke")
	var recs: Array = s.get_near_folds()
	_ok(recs.size() == before + 1, "reverse: new patch for new direction")
	_ok(float(recs[recs.size() - 1]["side"]) == -1.0, "reverse: new patch on left")
	_ok(float(recs[recs.size() - 2]["side"]) == 1.0, "reverse: old patch not flipped")
	_ok(float(recs[recs.size() - 2]["relax"]) <= 3.2 + 1e-6, "reverse: old stroke relaxing")
	var rl: Dictionary = recs[recs.size() - 1]
	_ok(
		(Vector2(rl["pos"]) - (p2 + Vector2(10, 0))).dot(Vector2(0, 1)) < 0.0,
		"sign: left drift folds on left"
	)
	# 순간이동: 간격이 STROKE_JUMP를 넘으면 새 스트로크, 패치는 두 위치를 잇지 않는다.
	var sid: int = s.stroke_id()
	s.push(p2 + Vector2(500, 0), -0.7, 0.7, 3.3, 0.0)
	_ok(s.stroke_id() == sid + 1, "teleport: jump -> new stroke")
	var span_ok: bool = true
	for rec in s.get_near_folds():
		var cs: PackedVector2Array = rec["c"]
		var span: float = cs[0].distance_to(cs[cs.size() - 1])
		if absf(span - (DriftSkid.FOLD_LEN + DriftSkid.FOLD_AHEAD)) > 1e-3:
			span_ok = false
	_ok(span_ok, "teleport: every patch has fixed span (no bridge between strokes)")
	# 방향 없는 드리프트는 기록하지 않는다.
	var cnt: int = s.get_near_folds().size()
	s.push(p2 + Vector2(600, 0), 0.01, 0.01, 3.4, 0.0)
	_ok(s.get_near_folds().size() == cnt, "stroke: |dir| < DIR_MIN ignored")
	# 리뷰 2: 드리프트 유지 + 조향 중립(|dir| < DIR_MIN)은 스트로크를 끊고, 48px 안에서 같은 방향으로
	# 다시 조향하면 새 스트로크가 시작되며 첫 패치가 바로 생긴다. 중립 구간 이동은 간격에 합산되지 않는다.
	var nb: DriftSkid = _new_skid()
	await _frames(1)
	var q0: Vector2 = Vector2(0, 500)
	_push_line(nb, q0, 0.0, 0.8, 8, 20.0, 4.0)  # 28px, 패치 1개(시작)
	var sid0: int = nb.stroke_id()
	var n0: int = nb.get_near_folds().size()
	for k in 3:
		nb.push(q0 + Vector2(36.0 + 8.0 * float(k), 0), 0.02, 0.02, 20.2 + 0.02 * float(k), 0.0)
	_ok(not nb.is_stroke_active(), "neutral: |dir| < DIR_MIN ends the stroke")
	var restart_at: Vector2 = q0 + Vector2(60.0, 0)
	nb.push(restart_at, 0.8, 0.8, 20.3, 0.0)
	_ok(nb.stroke_id() == sid0 + 1, "neutral: re-steer within 48px starts a new stroke")
	var recs_nb: Array = nb.get_near_folds()
	var newest: Dictionary = recs_nb[recs_nb.size() - 1]
	_ok(int(newest["stroke"]) == sid0 + 1, "neutral: first patch of the new stroke created at once")
	var front_new: Vector2 = Vector2(newest["c"][DriftFoldShape.NV])
	var axis_new: Vector2 = Vector2(newest["tan"])
	var anchor: Vector2 = front_new - axis_new * DriftSkid.FOLD_AHEAD
	_ok(anchor.distance_to(restart_at) < 1e-3, "neutral: new patch anchored at the re-steer point")
	# 다음 패치는 재조향 지점에서 FOLD_SPACING만큼 간 뒤에 생긴다(중립 구간 거리 미합산).
	var before_n: int = nb.get_near_folds().size()
	var travelled: float = 0.0
	var qq: Vector2 = restart_at
	while nb.get_near_folds().size() == before_n and travelled < 100.0:
		qq += Vector2(8.0, 0)
		travelled += 8.0
		nb.push(qq, 0.8, 0.8, 20.3 + travelled / 600.0, 0.0)
	_ok(
		travelled >= DriftSkid.FOLD_SPACING - 0.01,
		"neutral: next patch after FOLD_SPACING from re-steer (%.0f px)" % travelled
	)
	_ok(n0 >= 1, "neutral: setup made patches before neutral")
	nb.queue_free()
	await _check_long_stroke()
	# 버퍼 상한과 데시메이션(전체 span 보존).
	s.clear()
	_ok(s.get_near_folds().is_empty() and s.get_full_marks().is_empty(), "clear: empties buffers")
	_ok(not s.is_stroke_active(), "clear: no active stroke")
	var first_pos: Vector2 = Vector2.INF
	var p: Vector2 = Vector2.ZERO
	var t: float = 10.0
	for i in 6000:
		p += Vector2(9.0, 0.0)
		t += 1.0 / 60.0
		s.push(p, 0.9 if (i / 300) % 2 == 0 else -0.9, 0.9, t, 0.0)
		if first_pos == Vector2.INF and not s.get_full_marks().is_empty():
			first_pos = Vector2(s.get_full_marks()[0]["pos"])
	_ok(
		s.get_near_folds().size() <= DriftSkid.MAX_SKIDS, "buffer: near <= %d" % DriftSkid.MAX_SKIDS
	)
	_ok(
		s.get_full_marks().size() <= DriftSkid.MAX_FULL_SKIDS,
		"buffer: full <= %d" % DriftSkid.MAX_FULL_SKIDS
	)
	_ok(Vector2(s.get_full_marks()[0]["pos"]) == first_pos, "buffer: decimation keeps first patch")
	var keys_ok: bool = true
	for rec in s.get_full_marks():
		for key in ["pos", "dir", "intensity", "tan", "c", "n", "rv", "ru", "born", "relax"]:
			if not rec.has(key):
				keys_ok = false
	_ok(keys_ok, "buffer: full records carry FinishView keys")
	# 표현 전용 RNG: 같은 입력이면 같은 변형(전역 난수열 미사용).
	var a: DriftSkid = _new_skid()
	var b: DriftSkid = _new_skid()
	await _frames(1)
	# 리뷰 4: 주름을 만들지 않은 기준 경로의 다음 전역 난수와, 주름을 만든 경로의 다음 난수가 같아야 한다.
	seed(1234)
	var g_base: float = randf()
	seed(1234)
	_push_line(a, Vector2.ZERO, 0.3, 0.6, 50, 1.0)
	a.end_stroke(2.0)
	var g1: float = randf()
	_ok(g1 == g_base, "rng: fold generation does not consume the global RNG")
	seed(1234)
	_push_line(b, Vector2.ZERO, 0.3, 0.6, 50, 1.0)
	var same_amp: bool = a.get_near_folds().size() == b.get_near_folds().size()
	for i in range(mini(a.get_near_folds().size(), b.get_near_folds().size())):
		if float(a.get_near_folds()[i]["amp"]) != float(b.get_near_folds()[i]["amp"]):
			same_amp = false
	_ok(same_amp, "rng: fixed-seed variation is reproducible")
	for n in [s, a, b]:
		n.queue_free()
	await _frames(1)


# ---------------------------------------------------------------- layer


func _check_layer() -> void:
	var host: Node2D = Node2D.new()
	add_child(host)
	var skid: DriftSkid = DriftSkid.new()
	host.add_child(skid)
	var layer: DriftFoldLayer = DriftFoldLayer.new()
	host.add_child(layer)
	await _frames(1)
	var img: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	layer.setup(skid, ImageTexture.create_from_image(img))
	# 플레이어 (0,0), heading 0. 바늘 근처를 짧게 지나며 패치 30개(모두 근경).
	var t: float = 5.0
	for i in 30:
		var y: float = -40.0 + float(i % 6) * 16.0
		skid.end_stroke(t)
		skid.push(Vector2(-20.0, y), 1.0, 1.0, t, 0.0)
		t += 0.001
	_hold_all(skid, t + 100.0)
	var now: float = t + DriftFoldShape.RISE
	layer.update_view(now, Vector2.ZERO, 0.0)
	var st: Dictionary = layer.last_stats()
	print(
		"layer: candidates %d, active %d, cpu %d us" % [st["candidates"], st["active"], st["usec"]]
	)
	_ok(int(st["candidates"]) >= 30, "layer: all patches are candidates")
	_ok(
		int(st["active"]) == DriftFoldLayer.MAX_ACTIVE,
		"layer: active capped at %d" % DriftFoldLayer.MAX_ACTIVE
	)
	_ok(layer.active_records().size() == DriftFoldLayer.MAX_ACTIVE, "layer: slots used == cap")
	# 활성 패치 정점이 모두 유한하고 화면 근처에 있다.
	var finite: bool = true
	for rec in layer.active_records():
		for q in layer.debug_project_patch(rec, SCREEN):
			if not (is_finite(q.x) and is_finite(q.y)) or q.y < -2000.0 or q.y > 4000.0:
				finite = false
	_ok(finite, "layer: active patch vertices finite and bounded")
	# 화면 솟음 상한과 실제 픽셀 높이(바늘에서 막 생긴 강도 1 패치, 1280×720).
	var worst_lift: float = 0.0
	for rec in layer.active_records():
		var lifted: PackedVector2Array = layer.debug_project_patch(rec, SCREEN)
		var ground: PackedVector2Array = DriftFoldLayer.patch_world_grid(rec)
		for k in range(lifted.size()):
			var g0: Vector3 = DriftFoldLayer.project(ground[k], 0.0, Vector2.ZERO, 0.0, SCREEN)
			worst_lift = maxf(worst_lift, g0.y - lifted[k].y)
	_ok(
		worst_lift <= DriftFoldLayer.MAX_LIFT_PX + 1e-3,
		"layer: screen lift capped (%.1f px)" % worst_lift
	)
	var probe: DriftSkid = DriftSkid.new()
	host.add_child(probe)
	probe.push(Vector2.ZERO, 1.0, 1.0, 1.0, 0.0)
	var pr0: Dictionary = probe.get_near_folds()[0]
	pr0["amp"] = DriftSkid.FOLD_HEIGHT
	var row_lift: float = 0.0
	var all_lift: float = 0.0
	var wg: PackedVector2Array = DriftFoldLayer.patch_world_grid(pr0)
	for k in range(wg.size()):
		var z: float = DriftFoldLayer.capped_amp(DriftSkid.FOLD_HEIGHT, wg[k], Vector2.ZERO, 0.0)
		var lift_k: float = (
			DriftFoldLayer.project(wg[k], 0.0, Vector2.ZERO, 0.0, SCREEN).y
			- (
				DriftFoldLayer
				. project(wg[k], z * DriftFoldShape.grid_h[k], Vector2.ZERO, 0.0, SCREEN)
				. y
			)
		)
		all_lift = maxf(all_lift, lift_k)
		if absf(wg[k].x) < 20.0:
			row_lift = maxf(row_lift, lift_k)
	print(
		(
			"lift: fresh full-intensity patch peak %.1f px overall, %.1f px within 20px of the needle row"
			% [all_lift, row_lift]
		)
	)
	probe.queue_free()
	# 카메라 뒤·원경 패치는 메시 후보에서 빠진다.
	skid.clear()
	skid.end_stroke(t)
	skid.push(Vector2(-400.0, 0.0), 1.0, 1.0, t, 0.0)  # 카메라 뒤
	skid.end_stroke(t)
	skid.push(Vector2(600.0, 0.0), 1.0, 1.0, t, 0.0)  # 수평선 근처(멀다)
	layer.update_view(now, Vector2.ZERO, 0.0)
	_ok(int(layer.last_stats()["active"]) == 0, "clip: behind-camera and horizon patches culled")
	# 비용: 활성 12개 + full 400개 상태에서 매 프레임 갱신 CPU 시간.
	skid.clear()
	var p: Vector2 = Vector2(-3000, 0)
	for i in 2000:
		p += Vector2(9.0, 0.0)
		skid.push(p, 0.9 if (i / 40) % 2 == 0 else -0.9, 0.9, 1.0 + float(i) / 600.0, 0.0)
	for i in 30:
		var y2: float = -40.0 + float(i % 6) * 16.0
		skid.end_stroke(t)
		skid.push(Vector2(-20.0, y2), 1.0, 1.0, t, 0.0)
	_hold_all(skid, t + 100.0)
	_ok(skid.get_full_marks().size() <= DriftSkid.MAX_FULL_SKIDS, "perf: full buffer bounded")
	var total: int = 0
	var worst: int = 0
	for f in 120:
		layer.update_view(
			now + 0.001 * float(f), Vector2(0.0, float(f % 3) * 0.1), 0.001 * float(f)
		)
		var us: int = int(layer.last_stats()["usec"])
		total += us
		worst = maxi(worst, us)
	print(
		(
			"perf: update_view with %d active / %d full records: avg %.1f us, worst %d us"
			% [layer.last_stats()["active"], skid.get_full_marks().size(), total / 120.0, worst]
		)
	)
	_ok(int(layer.last_stats()["active"]) == DriftFoldLayer.MAX_ACTIVE, "perf: measured at cap")
	_ok(total / 120.0 < 4000.0, "perf: update_view under 4 ms average (headless desktop)")
	# 리뷰 6: 정상 상태(업로드 없음) 프레임의 셰이더 파라미터 설정 호출 수.
	layer.update_view(now + 0.2, Vector2(0.0, 0.1), 0.0)
	layer.update_view(now + 0.2 + 1.0 / 60.0, Vector2(0.0, 0.2), 0.0)
	var params: int = int(layer.last_stats().get("params", 9999))
	print("perf: shader parameter sets per steady frame %d" % params)
	_ok(params <= 8, "perf: <= 8 shader parameter sets per steady frame (%d)" % params)
	# 리뷰 7: 높이맵 베이크는 한 번만 하고(정적 캐시) 비용을 잰다.
	var shape: RefCounted = DriftFoldShape.new()
	var bake_us: int = int(shape.call("bake_usec")) if shape.has_method("bake_usec") else -1
	var bakes: int = int(shape.call("bake_count")) if shape.has_method("bake_count") else -1
	print("perf: height map bake %d us, bake count %d" % [bake_us, bakes])
	_ok(bakes == 1, "bake: baked exactly once per process")
	_ok(bake_us >= 0 and bake_us < 40000, "bake: under 40 ms on headless desktop (%d us)" % bake_us)
	layer.enabled = false
	layer.update_view(now, Vector2.ZERO, 0.0)
	_ok(int(layer.last_stats()["active"]) == 0, "layer: disabled draws nothing")
	host.queue_free()
	await _frames(2)


## 검사용: 근경 패치를 모두 아직 눌린 상태로 둔다(같은 시각에 스트로크를 끊어 만든 패치는 솟지 않으므로).
func _hold_all(skid: DriftSkid, until: float) -> void:
	for rec in skid.get_near_folds():
		rec["relax"] = until


## 패치 rec이 월드 점 p에서 만드는 정규화 높이(패치 밖이면 0). 휜 패치도 행별 기준점·법선으로 국소 좌표를 구한다.
func _patch_height_at(rec: Dictionary, p: Vector2) -> float:
	var cs: PackedVector2Array = rec["c"]
	var ns: PackedVector2Array = rec["n"]
	var best: float = INF
	var v_best: float = -1.0
	var lat_best: float = 0.0
	for k in range(cs.size() - 1):
		var seg: Vector2 = cs[k + 1] - cs[k]
		var t: float = clampf((p - cs[k]).dot(seg) / maxf(seg.length_squared(), 1e-6), 0.0, 1.0)
		var base: Vector2 = cs[k].lerp(cs[k + 1], t)
		var nrm: Vector2 = ns[k].lerp(ns[k + 1], t).normalized()
		var lat: float = (p - base).dot(nrm)
		var along: float = absf((p - base).dot(Vector2(nrm.y, -nrm.x)))
		if along < best:
			best = along
			v_best = (float(k) + t) / float(cs.size() - 1)
			lat_best = lat
	var u: float = (lat_best - float(rec["off"])) / float(rec["w"])
	if best > 1.0 or u < 0.0 or u > 1.0 or v_best < 0.0:
		return 0.0
	return DriftFoldShape.height_at(u, v_best)


## 긴 드리프트(사용자 피드백): 스트로크가 살아 있는 동안 모든 패치가 완화 없이 유지되고, 끝나면 함께
## 완화를 시작하며, 겹친 패치들이 능선을 따라 높이가 끊기지 않는 하나의 긴 주름을 만든다.
func _check_long_stroke() -> void:
	var ls: DriftSkid = _new_skid()
	await _frames(1)
	_ok(
		DriftSkid.FOLD_LEN + DriftSkid.FOLD_AHEAD >= DriftSkid.FOLD_SPACING * 1.6,
		"long: patch length >= 1.6 x spacing"
	)
	# 3초 직진 드리프트(170px/s).
	var p: Vector2 = Vector2(0, 1500)
	var t: float = 30.0
	for i in 180:
		p += Vector2(170.0 / 60.0, 0.0)
		t += 1.0 / 60.0
		ls.push(p, 0.9, 0.9, t, 0.0)
	var recs: Array = ls.get_near_folds()
	var held: bool = recs.size() > 10
	for rec in recs:
		if float(rec["relax"]) < DriftFoldShape.HELD:
			held = false
	_ok(held, "long: all patches held while the stroke is alive (%d patches)" % recs.size())
	var first_amp: float = DriftFoldShape.amp01(float(recs[0]["born"]), float(recs[0]["relax"]), t)
	_ok(first_amp > 0.999, "long: oldest patch still at full height after 3 s (%.3f)" % first_amp)
	# 능선(가운데 행에서 가장 높은 u) 위를 따라 높이가 끊기지 않는가.
	var w: int = DriftFoldShape.NU + 1
	var row: int = int(round(DriftFoldShape.PEAK_V * DriftFoldShape.NV))
	var best_u: int = 0
	for i in range(w):
		if DriftFoldShape.grid_h[row * w + i] > DriftFoldShape.grid_h[row * w + best_u]:
			best_u = i
	var u_r: float = float(best_u) / float(DriftFoldShape.NU)
	var r0: Dictionary = recs[2]
	var lat: float = float(r0["off"]) + float(r0["w"]) * u_r
	var n0: Vector2 = Vector2(r0["n"][0])
	var x0: float = Vector2(recs[2]["c"][0]).x + 20.0
	var x1: float = Vector2(recs[recs.size() - 3]["c"][DriftFoldShape.NV]).x - 20.0
	var lo: float = 1.0
	var hi: float = 0.0
	var x: float = x0
	while x < x1:
		var q: Vector2 = Vector2(x, Vector2(r0["c"][0]).y) + n0 * lat
		var mh: float = 0.0
		for rec in recs:
			mh = maxf(mh, _patch_height_at(rec, q))
		lo = minf(lo, mh)
		hi = maxf(hi, mh)
		x += 2.0
	print("long: ridge height along a 3 s straight stroke min %.2f max %.2f" % [lo, hi])
	_ok(lo >= 0.8 * hi and hi > 0.5, "long: overlapping patches form one continuous ridge")
	# 곡선(피벗) 스트로크: 이웃 패치의 능선 가운데가 다음 패치에도 덮이는가(벌어짐 확인).
	var cs: DriftSkid = _new_skid()
	await _frames(1)
	var hd: float = 0.0
	var cp: Vector2 = Vector2(0, -1500)
	t = 40.0
	for i in 120:
		hd += 2.5 / 60.0  # 초당 2.5rad 회전
		cp += Vector2(cos(hd), sin(hd)) * (170.0 / 60.0)
		t += 1.0 / 60.0
		cs.push(cp, 0.9, 0.9, t, hd)
	var crecs: Array = cs.get_near_folds()
	var worst: float = 1.0
	for k in range(1, crecs.size() - 1):
		var a: Dictionary = crecs[k]
		var mid: Vector2 = (
			Vector2(a["c"][DriftFoldShape.NV / 2])
			+ Vector2(a["n"][0]) * (float(a["off"]) + float(a["w"]) * u_r)
		)
		var cover: float = maxf(
			_patch_height_at(crecs[k - 1], mid), _patch_height_at(crecs[k + 1], mid)
		)
		worst = minf(worst, cover / maxf(_patch_height_at(a, mid), 0.001))
	print(
		"long: curve stroke (2.5 rad/s) neighbour cover of ridge centre, worst ratio %.2f" % worst
	)
	_ok(worst >= 0.3, "long: curve stroke patches overlap their neighbours (no gaps)")
	# 끝나면 함께 완화한다.
	ls.end_stroke(t + 0.1)
	var together: bool = true
	for rec in ls.get_near_folds():
		if absf(float(rec["relax"]) - (t + 0.1)) > 1e-6:
			together = false
	_ok(together, "long: every patch of the stroke starts relaxing at stroke end")
	ls.queue_free()
	cs.queue_free()
