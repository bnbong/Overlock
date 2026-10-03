extends Node
## 드리프트 주름 화면 캡처 드라이버(검증 사본 전용 autoload, 저장소 game/에는 넣지 않는다).
##
## run_capture.sh가 사본 project.godot에 autoload로 등록하고 Gameplay.tscn을 메인 씬으로 실행한다.
## 게임 상태는 읽기만 하고 조작은 Input 액션(steer_left/right·drift)과 속도 버퍼로 넣는다. 일시정지·
## 재시작은 RaceDirector의 실제 경로(_toggle_pause·_restart = reload_current_scene)를 그대로 부른다.
## --fixed-fps 60으로 실행하면 렌더 1프레임 = 물리 1틱이라 같은 시나리오가 같은 장면을 만든다.
## 인자(-- 뒤): --out=<dir> --scenario=main|fabric|mobile|compare --track=<id>
## 출력: <out>/*.png, <out>/seq_*/NNN.png(연속 프레임), <out>/frames.csv, <out>/events.txt

const DT: float = 1.0 / 60.0
# 이전 코드 사본(주름 클래스 없음)에서도 같은 드라이버가 돌도록 새 클래스는 런타임에만 조회한다.
const SHAPE_PATH: String = "res://scripts/presentation/DriftFoldShape.gd"
const LAYER_PATH: String = "res://scripts/presentation/DriftFoldLayer.gd"

var out_dir: String = ""
var scenario: String = "main"
var track: String = "tee_01"
var auto: bool = false
var hide_fg: bool = false
var legacy_place: bool = false
var frame: int = 0
var _log: FileAccess = null
var _events: FileAccess = null
var _cap_queue: Array = []
var _seq_prefix: String = ""
var _seq_left: int = 0
var _seq_idx: int = 0
# 실패 누적(화면 비교 실패·누락 캡처·알 수 없는 시나리오). 0이 아니면 종료 코드 1로 끝낸다.
var _failures: int = 0
var _expected_caps: PackedStringArray = PackedStringArray()
# flatcheck 허용 최대 픽셀 차이(/255). 실패 전달을 시험할 때 음수로 강제 실패시킬 수 있다.
var _flat_max_diff: float = 2.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--scenario="):
			scenario = a.substr(11)
		elif a.begins_with("--track="):
			track = a.substr(8)
		elif a.begins_with("--flat-max-diff="):
			_flat_max_diff = float(a.substr(16))
		elif a == "--legacy-place":
			legacy_place = true
		elif a == "--hide-fg":
			hide_fg = true
	if out_dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	LeaderboardClient.tutorial_seen = true
	GameState.track_id = track
	GameState.difficulty = "normal"
	_log = FileAccess.open(out_dir + "/frames.csv", FileAccess.WRITE)
	_log.store_line(
		(
			"frame,state,drifting,drift_dir,pos_x,pos_y,heading,paused,near,full,active,cands,"
			+ "verts,build_usec,fx_time,max_lift_px,stroke"
		)
	)
	_events = FileAccess.open(out_dir + "/events.txt", FileAccess.WRITE)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	_main.call_deferred()


func _ev(msg: String) -> void:
	var line: String = "[f%05d] %s" % [frame, msg]
	print("FOLDCAP ", line)
	if _events != null:
		_events.store_line(line)
		_events.flush()


func _g() -> Node:
	return get_tree().current_scene


func _player() -> PlayerController:
	var g: Node = _g()
	if g == null or not ("_player" in g):
		return null
	return g._player


func _skid() -> Node:
	var g: Node = _g()
	return null if g == null else g.get_node_or_null("SimHost/FabricSource/World/DriftSkid")


func _folds() -> Node:
	var g: Node = _g()
	return null if g == null else g.get_node_or_null("FabricLayer/DriftFolds")


func _presenter() -> Node:
	var g: Node = _g()
	return null if g == null else g.get_node_or_null("Presenter")


# ---------------------------------------------------------------- 입력


func _steer(dir: int) -> void:
	if dir < 0:
		Input.action_press(&"steer_left")
		Input.action_release(&"steer_right")
	elif dir > 0:
		Input.action_press(&"steer_right")
		Input.action_release(&"steer_left")
	else:
		Input.action_release(&"steer_left")
		Input.action_release(&"steer_right")


func _drift(on: bool) -> void:
	if on:
		Input.action_press(&"drift")
	else:
		Input.action_release(&"drift")


func _gear(target: int) -> void:
	var p: PlayerController = _player()
	if p != null:
		_g()._buf_speed_delta = target - p.speed_index


## 순수 추종(tools/fabric_regression/fabric_driver.gd와 같은 식)으로 디지털 조향.
func _auto_steer() -> void:
	_steer(_pursuit_dir())


## 순수 추종이 원하는 조향 키(-1/0/1).
func _pursuit_dir() -> int:
	var g: Node = _g()
	var p: PlayerController = _player()
	if p == null or g._track == null:
		return 0
	var tr: TrackData = g._track
	var s: float = float(g._last_s)
	var v: float = maxf(p.speed, 1.0)
	var ld: float = clampf(v * 0.22, 16.0, 70.0)
	var to: Vector2 = tr.point_at_s(minf(s + ld, tr.length)) - p.position
	var fwd: Vector2 = Vector2(cos(p.heading), sin(p.heading))
	var alpha: float = fwd.angle_to(to)
	var dist: float = maxf(to.length(), 1.0)
	var k: float = 2.0 * sin(alpha) / dist
	var w_max: float = (
		Tuning.turn_power * maxf(v / p.effective_max_speed(), Tuning.steer_speed_floor)
	)
	var a_des: float = clampf(k * v / w_max, -1.0, 1.0)
	var e: float = a_des - p.target_steer
	return 1 if e > 0.05 else (-1 if e < -0.05 else 0)


## 앞 구간(s+20..s+110)의 회전 방향 부호(+1=오른쪽)와 크기(rad).
func _curve_ahead() -> float:
	var g: Node = _g()
	var tr: TrackData = g._track
	var s: float = float(g._last_s)
	var a: Vector2 = tr.tangent_at_s(minf(s + 20.0, tr.length))
	var b: Vector2 = tr.tangent_at_s(minf(s + 110.0, tr.length))
	return a.angle_to(b)


## 자동 주행하다가 dir 방향 커브가 다가오면 반환한다(최대 limit 틱).
func _wait_curve(dir: int, limit: int = 900) -> void:
	auto = true
	for i in limit:
		if _curve_ahead() * float(dir) > 0.5:
			_ev("curve %d found after %d ticks" % [dir, i])
			return
		await get_tree().physics_frame
	_ev("curve %d not found in %d ticks" % [dir, limit])


## 한 방향 드리프트로 커브를 따라간다: 추종이 반대 방향을 원하면 키를 떼기만 해 drift_dir 부호를 유지한다.
func _drift_follow(dir: int, n: int, cap_at: Dictionary = {}) -> void:
	auto = false
	_drift(true)
	for i in n:
		var want: int = _pursuit_dir()
		_steer(dir if want != -dir or i < 6 else 0)
		await get_tree().physics_frame
		if cap_at.has(i):
			await _cap(cap_at[i])
	_drift(false)
	_steer(0)


func _physics_process(_delta: float) -> void:
	if out_dir.is_empty():
		return
	frame += 1
	if legacy_place and _skid() != null:
		_skid().debug_ignore_tip = true
	if hide_fg and _g() != null:
		for n in ["ForegroundLayer", "HUD"]:
			var c: CanvasLayer = _g().get_node_or_null(n)
			if c != null:
				c.visible = false
	if frame > 14000:
		_ev("watchdog quit")
		get_tree().quit(2)
		return
	if auto and not get_tree().paused:
		_auto_steer()
	_log_frame()


func _log_frame() -> void:
	var p: PlayerController = _player()
	if p == null or _log == null:
		return
	var g: Node = _g()
	var sk: Node = _skid()
	var fl: Node = _folds()
	var st: Dictionary = fl.last_stats() if fl != null and fl.has_method("last_stats") else {}
	var near_n: int = (
		sk.get_near_folds().size() if sk != null and sk.has_method("get_near_folds") else -1
	)
	var full_n: int = sk.get_full_marks().size() if sk != null else -1
	var pr: Node = _presenter()
	var fx: float = float(pr.get("_fx_time")) if pr != null and pr.get("_fx_time") != null else -1.0
	var stroke: int = sk.stroke_id() if sk != null and sk.has_method("stroke_id") else -1
	(
		_log
		. store_line(
			(
				"%d,%d,%s,%.3f,%.2f,%.2f,%.4f,%s,%d,%d,%d,%d,%d,%d,%.4f,%.2f,%d"
				% [
					frame,
					int(g._state),
					p.is_drifting,
					p.drift_dir,
					p.position.x,
					p.position.y,
					p.heading,
					get_tree().paused,
					near_n,
					full_n,
					int(st.get("active", -1)),
					int(st.get("candidates", -1)),
					int(st.get("verts", -1)),
					int(st.get("usec", -1)),
					fx,
					_max_lift(),
					stroke,
				]
			)
		)
	)


func _shape() -> Script:
	return load(SHAPE_PATH) if ResourceLoader.exists(SHAPE_PATH) else null


func _layer_script() -> Script:
	return load(LAYER_PATH) if ResourceLoader.exists(LAYER_PATH) else null


## 지금 화면에서 가장 높이 솟은 패치의 픽셀 높이(1280×720 캔버스 기준).
func _max_lift() -> float:
	var fl: Node = _folds()
	var sk: Node = _skid()
	var p: PlayerController = _player()
	if fl == null or sk == null or p == null or not sk.has_method("get_near_folds"):
		return -1.0
	if _shape() == null:
		return -1.0
	var pr: Node = _presenter()
	var now: float = float(pr.get("_fx_time"))
	var best: float = 0.0
	var fwd: Vector2 = Vector2(cos(p.heading), sin(p.heading))
	for rec in sk.get_near_folds():
		var a: float = _shape().amp01(float(rec["born"]), float(rec["relax"]), now)
		var depth: float = (
			(Vector2(rec["pos"]) - p.position).dot(fwd) + PresentationController.CAM_BACK
		)
		if depth < 48.0 or depth > 420.0:
			continue
		var px: float = (
			float(rec["amp"]) * a * _layer_script().lift_px_per_unit(depth, Vector2(1280, 720))
		)
		best = maxf(best, px)
	return best


# ---------------------------------------------------------------- 캡처


func _cap(name: String) -> void:
	_expected_caps.append(name)
	_cap_queue.append(name)
	while _cap_queue.has(name):
		await get_tree().process_frame


func _seq(prefix: String, count: int) -> void:
	_seq_prefix = prefix
	_seq_left = count
	_seq_idx = 0
	DirAccess.make_dir_recursive_absolute(out_dir + "/" + prefix)


func _on_post_draw() -> void:
	if _cap_queue.is_empty() and _seq_left <= 0:
		return
	var img: Image = get_viewport().get_texture().get_image()
	while not _cap_queue.is_empty():
		var name: String = _cap_queue.pop_front()
		img.save_png("%s/%s.png" % [out_dir, name])
		_ev("capture %s" % name)
	if _seq_left > 0:
		img.save_png("%s/%s/%03d.png" % [out_dir, _seq_prefix, _seq_idx])
		_seq_idx += 1
		_seq_left -= 1


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _wait_racing() -> void:
	while true:
		var g: Node = _g()
		if g != null and g.has_method("is_racing") and g.is_racing():
			return
		if g != null and "_state" in g and int(g._state) == 1:
			return
		await get_tree().physics_frame


func _wait_scene_change(old: Node) -> void:
	while _g() == old or _g() == null:
		await get_tree().process_frame
	await _ticks(2)


## 드리프트 한 번: dir 방향으로 조향 + 드리프트를 n틱 유지한 뒤 뗀다.
func _drift_burst(dir: int, n: int, cap_at: Dictionary = {}) -> void:
	auto = false
	_steer(dir)
	_drift(true)
	for i in n:
		await get_tree().physics_frame
		if cap_at.has(i):
			await _cap(cap_at[i])
	_drift(false)
	_steer(0)


# ---------------------------------------------------------------- 시나리오


func _main() -> void:
	await _ticks(10)
	_ev("start scenario=%s track=%s window=%s" % [scenario, track, DisplayServer.window_get_size()])
	match scenario:
		"main":
			await _scenario_main()
		"fabric":
			await _scenario_fabric()
		"mobile":
			await _scenario_mobile()
		"compare":
			await _scenario_compare()
		"flatcheck":
			await _scenario_flatcheck()
		"perf":
			await _scenario_perf()
		"heightcmp":
			await _scenario_heightcmp()
		"longdrift":
			await _scenario_longdrift()
		_:
			_fail("unknown scenario %s" % scenario)
	for name in _expected_caps:
		if not FileAccess.file_exists("%s/%s.png" % [out_dir, name]):
			_fail("missing capture %s" % name)
	_ev("done failures=%d" % _failures)
	if _log != null:
		_log.flush()
	await _ticks(2)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(msg: String) -> void:
	_failures += 1
	_ev("FAIL " + msg)


func _start_run(gear: int, warm: int) -> void:
	await _wait_racing()
	auto = true
	_gear(gear)
	await _ticks(warm)


## 같은 장면 before/after 비교(기존 평면 스키드 코드 사본과 같은 입력).
func _scenario_compare() -> void:
	await _start_run(3, 120)
	await _wait_curve(1)
	await _drift_burst(1, 22, {8: "cmp_right_t8", 14: "cmp_right_t14", 21: "cmp_right_t21"})
	await _ticks(6)
	await _cap("cmp_right_after6")
	await _ticks(14)
	await _cap("cmp_right_after20")
	await _recover()
	await _wait_curve(-1)
	await _drift_burst(-1, 22, {8: "cmp_left_t8", 14: "cmp_left_t14", 21: "cmp_left_t21"})
	await _ticks(6)
	await _cap("cmp_left_after6")
	await _ticks(14)
	await _cap("cmp_left_after20")


## 드리프트 뒤 자동 조향으로 재봉선에 다시 올라탄다(오차·진행각 차이가 작아질 때까지).
func _recover(limit: int = 600) -> void:
	auto = true
	var g: Node = _g()
	for i in limit:
		await get_tree().physics_frame
		var p: PlayerController = _player()
		var tr: TrackData = g._track
		var tan: Vector2 = tr.tangent_at_s(float(g._last_s))
		var herr: float = absf(Vector2(cos(p.heading), sin(p.heading)).angle_to(tan))
		var q: Dictionary = tr.query(p.position, int(g._hint))
		if i > 30 and herr < 0.15 and float(q["error"]) < tr.safe:
			return


func _scenario_main() -> void:
	await _ticks(60)
	await _cap("01_countdown")
	await _start_run(3, 120)
	await _wait_curve(1)
	await _cap("02_before_drift")
	# 우 드리프트: 평면 → 솟음 → 완화 연속 프레임.
	_seq("seq_right_rise_relax", 84)
	await _ticks(4)
	await _drift_burst(1, 26, {3: "03_right_rise_t3", 7: "03_right_rise_t7", 20: "03_right_peak"})
	auto = true
	await _ticks(10)
	await _cap("03_right_relax_t10")
	await _ticks(30)
	await _cap("03_right_relax_t40")
	# 좌 드리프트 + 완화 도중 일시정지.
	await _wait_curve(-1, 400)
	_seq("seq_left_rise_relax", 40)
	await _ticks(4)
	await _drift_burst(-1, 26, {7: "04_left_rise_t7", 20: "04_left_peak"})
	auto = true
	await _ticks(8)
	await _cap("04_left_relax_t8")
	_g()._toggle_pause()
	_ev("pause on")
	await _ticks(2)
	await _cap("07_pause_a")
	await _ticks(60)
	await _cap("07_pause_b")
	_g()._toggle_pause()
	_ev("pause off")
	await _ticks(2)
	await _cap("07_resume")
	await _recover()
	# 급반전: 우 → 좌(드리프트 유지).
	await _wait_curve(1, 400)
	auto = false
	_drift(true)
	_steer(1)
	await _ticks(16)
	await _cap("05_reverse_before")
	_steer(-1)
	await _ticks(10)
	await _cap("05_reverse_t10")
	await _ticks(10)
	await _cap("05_reverse_t20")
	_drift(false)
	_steer(0)
	await _recover()
	# 연속 드리프트: 짧은 드리프트를 끊어서 여러 번(우·우·좌), 사이사이 자동 조향으로 복귀.
	for i in 3:
		await _drift_burst(1 if i < 2 else -1, 14)
		await _cap("06_continuous_%d" % i)
		auto = true
		await _ticks(12)
	await _cap("06_continuous_after")
	await _recover()
	# 강제 복귀: 우 드리프트 → 조향 후 직진으로 이탈.
	await _drift_burst(1, 18)
	auto = false
	_steer(-1)
	await _ticks(20)
	_steer(0)
	var p: PlayerController = _player()
	var guard: int = 0
	while is_instance_valid(p) and p.offfabric_timer <= 0.0 and guard < 900:
		await get_tree().physics_frame
		guard += 1
	_ev("offfabric reset after %d ticks" % guard)
	await _cap("08_reset_t0")
	await _ticks(20)
	await _cap("08_reset_t20")
	await _ticks(50)
	await _recover()
	await _drift_burst(-1, 20, {16: "08_after_reset_new_stroke"})
	auto = true
	await _ticks(30)
	# 재시작(R 경로 = reload_current_scene).
	var old: Node = _g()
	_ev("restart")
	old._restart()
	await _wait_scene_change(old)
	await _ticks(30)
	await _cap("09_restart_countdown")
	var sk: Node = _skid()
	if sk != null:
		_ev(
			(
				"after restart near=%d full=%d"
				% [sk.get_near_folds().size(), sk.get_full_marks().size()]
			)
		)
	# 2회차 완주(중간중간 드리프트) → 줌아웃.
	await _start_run(4, 60)
	await _cap("09_restart_running")
	await _lap_to_finish()


func _lap_to_finish() -> void:
	var g: Node = _g()
	var n: int = 0
	var fv: CanvasItem = g.get_node_or_null("FinishViewLayer/FinishView")
	var tr: TrackData = g._track
	var last_capped: bool = false
	auto = true
	while not fv.visible and n < 7000:
		n += 1
		var c: float = _curve_ahead()
		if absf(c) > 0.6 and n % 90 == 0 and float(g._last_s) < tr.length - 200.0:
			await _drift_follow(1 if c > 0.0 else -1, 20)
			auto = true
			n += 20
			continue
		if float(g._last_s) > tr.length - 200.0 and absf(c) > 0.3 and int(g._state) == 1:
			# 결승 직전: 커브 방향으로 드리프트를 유지한 채 결승선을 넘긴다(완주 순간 주름 전환 확인).
			auto = false
			_drift(true)
			var want: int = _pursuit_dir()
			_steer(want if want == (1 if c > 0.0 else -1) else 0)
		else:
			_drift(false)
			auto = true
		await get_tree().physics_frame
		if not fv.visible and not last_capped and float(g._last_s) > tr.length - 30.0:
			last_capped = true
			await _cap("10_last_gameplay")
	_drift(false)
	_steer(0)
	_ev("finish view visible after %d ticks" % n)
	await _cap("10_finish_t0")
	await _ticks(9)
	await _cap("10_finish_t015")
	await _ticks(15)
	await _cap("10_finish_t040")
	await _ticks(36)
	await _cap("10_finish_t100")
	await _ticks(60)
	await _cap("10_finish_t200")


## 원단별: 재봉선 위(중심선 근처) / 재봉선 밖(코리도 바깥)에서 드리프트.
func _scenario_fabric() -> void:
	await _start_run(3, 120)
	await _wait_curve(1)
	await _drift_follow(1, 26, {18: "fab_on_seam_peak"})
	auto = true
	await _ticks(4)
	await _cap("fab_on_seam_relax4")
	await _ticks(100)
	# 바깥으로 벗어나 원단 위에서 드리프트.
	await _wait_curve(-1)
	auto = false
	_steer(1)
	await _ticks(8)
	_steer(0)
	await _ticks(24)
	await _cap("fab_off_seam_before")
	await _drift_follow(-1, 26, {18: "fab_off_seam_peak"})
	auto = true
	await _ticks(4)
	await _cap("fab_off_seam_relax4")


## 가로 모바일 비율(844×390 창): 좌/우 드리프트와 완화.
func _scenario_mobile() -> void:
	await _start_run(3, 120)
	await _wait_curve(1)
	_seq("seq_mobile_right", 60)
	await _drift_follow(1, 28, {18: "m_right_peak"})
	auto = true
	await _ticks(10)
	await _cap("m_right_relax10")
	await _wait_curve(-1)
	await _drift_follow(-1, 28, {18: "m_left_peak"})
	auto = true
	await _ticks(10)
	await _cap("m_left_relax10")


## h=0 화면 검증: 같은 프레임(일시정지)에서 (A) 모든 패치를 높이 0·불투명으로, (B) 주름 레이어를 끄고,
## (C) 평소대로 그린 화면을 찍는다. A와 B가 같아야 한다(투영·월드 UV가 바닥과 일치). 패치 화면 범위는
## events.txt에 남긴다.
func _scenario_flatcheck() -> void:
	hide_fg = true
	await _start_run(3, 120)
	await _wait_curve(1)
	await _drift_burst(1, 14)
	await _ticks(2)
	var pr: Node = _presenter()
	var fl: Node = _folds()
	var p: PlayerController = _player()
	get_tree().paused = true
	var now: float = float(pr._fx_time)
	await _ticks(2)
	fl.update_view(now, p.position, p.heading)
	await _ticks(2)
	await _cap("flat_C_normal")
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = Vector2(-INF, -INF)
	for rec in fl.active_records():
		for q in fl.debug_project_patch(rec, Vector2(1280, 720)):
			mn = mn.min(q)
			mx = mx.max(q)
	_ev("flat patches=%d bbox=%s..%s" % [fl.active_records().size(), mn, mx])
	fl.debug_flat = true
	fl.update_view(now, p.position, p.heading)
	await _ticks(3)
	await _cap("flat_A_h0_opaque")
	fl.debug_flat = false
	fl.enabled = false
	fl.update_view(now, p.position, p.heading)
	await _ticks(3)
	await _cap("flat_B_layer_off")
	fl.enabled = true
	get_tree().paused = false
	var ia: Image = Image.load_from_file(out_dir + "/flat_A_h0_opaque.png")
	var ib: Image = Image.load_from_file(out_dir + "/flat_B_layer_off.png")
	var ic: Image = Image.load_from_file(out_dir + "/flat_C_normal.png")
	var worst: float = 0.0
	var over: int = 0
	var fold_px: int = 0
	for y in range(ia.get_height()):
		for x in range(ia.get_width()):
			var a: Color = ia.get_pixel(x, y)
			var b: Color = ib.get_pixel(x, y)
			var dmax: float = maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) * 255.0
			worst = maxf(worst, dmax)
			if dmax > 8.0:
				over += 1
			var c: Color = ic.get_pixel(x, y)
			if maxf(maxf(absf(c.r - b.r), absf(c.g - b.g)), absf(c.b - b.b)) * 255.0 > 8.0:
				fold_px += 1
	var ok: bool = worst <= _flat_max_diff and fold_px > 1000
	if not ok:
		_fail(
			(
				"flatcheck: max diff %.1f (limit %.1f), raised-fold pixels %d"
				% [worst, _flat_max_diff, fold_px]
			)
		)
	_ev(
		(
			"flatcheck %s: h0 vs floor max diff %.1f/255, pixels>8 %d, raised-fold pixels %d"
			% ["PASS" if ok else "FAIL", worst, over, fold_px]
		)
	)


## 비용 측정: 활성 패치 12개 + 완주 버퍼 400개 상태에서 렌더 시간(CPU/GPU, 루트·바닥 SubViewport)과
## 주름 갱신 CPU 시간을 연출 ON/OFF로 각각 240프레임 잰다.
func _scenario_perf() -> void:
	await _start_run(3, 60)
	var g: Node = _g()
	var pr: Node = _presenter()
	var sk: Node = _skid()
	var fl: Node = _folds()
	var p: PlayerController = _player()
	get_tree().paused = true
	var now: float = float(pr._fx_time)
	# 완주 버퍼 400개: 멀리 떨어진 직선 경로에 스트로크를 번갈아 쌓는다(근경 링 120개도 가득 참).
	var q: Vector2 = p.position + Vector2(-4000, -4000)
	var i: int = 0
	while sk.get_full_marks().size() < 384 or i < 3000:
		q += Vector2(9.0, 0.0)
		sk.call(
			"push", q, 0.9 if (i / 40) % 2 == 0 else -0.9, 0.9, now - 30.0 + float(i) * 0.002, 0.0
		)
		i += 1
		if i > 20000:
			break
	sk.call("end_stroke", now - 20.0)
	# 바늘 주변 활성 패치(각각 새 스트로크, 막 솟은 상태).
	var fwd: Vector2 = Vector2(cos(p.heading), sin(p.heading))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	for k in 16:
		var at: Vector2 = (
			p.position - fwd * float(k % 4) * 14.0 + rgt * (-30.0 + float(k / 4) * 20.0)
		)
		sk.call("end_stroke", now - 0.2)
		sk.call("push", at, 1.0 if k % 2 == 0 else -1.0, 1.0, now - 0.2, p.heading)
	sk.call("end_stroke", now - 0.2)
	# 같은 시각에 끊어 만든 패치는 솟지 않으므로(완화가 생성 시각에 시작), 측정용 패치는 눌린 상태로 둔다.
	for rec in sk.get_near_folds().slice(-16):
		rec["relax"] = now + 100.0
	var vp: RID = get_viewport().get_viewport_rid()
	var sub: RID = g.get_node("SimHost/FabricSource").get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	RenderingServer.viewport_set_measure_render_time(sub, true)
	# 수직 동기를 끄고 프레임 사이 실제 경과 시간(벽시계)을 ON/OFF 블록을 번갈아 잰다.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await get_tree().process_frame
	var wall: Dictionary = {"on": 0.0, "off": 0.0}
	var wall_n: Dictionary = {"on": 0, "off": 0}
	for block in 8:
		var m: String = "on" if block % 2 == 0 else "off"
		fl.enabled = m == "on"
		sk.visible = m == "on"
		await get_tree().process_frame
		var t_prev: int = Time.get_ticks_usec()
		for f in 150:
			fl.update_view(now, p.position, p.heading + 0.0005 * float(f))
			await get_tree().process_frame
			var t_now: int = Time.get_ticks_usec()
			wall[m] += float(t_now - t_prev)
			wall_n[m] += 1
			t_prev = t_now
	_ev(
		(
			"perf wall (vsync off, 4x150 frames each): on %.3f ms/frame, off %.3f ms/frame"
			% [wall["on"] / wall_n["on"] / 1000.0, wall["off"] / wall_n["off"] / 1000.0]
		)
	)
	for mode in ["on", "off"]:
		fl.enabled = mode == "on"
		sk.visible = mode == "on"
		var acc: Dictionary = {
			"cpu": 0.0, "gpu": 0.0, "sub_cpu": 0.0, "sub_gpu": 0.0, "upd": 0.0, "proc": 0.0
		}
		var active: int = 0
		var frames: int = 240
		for f in frames:
			fl.update_view(now, p.position, p.heading + 0.0005 * float(f))
			await get_tree().process_frame
			acc["cpu"] += RenderingServer.viewport_get_measured_render_time_cpu(vp)
			acc["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			acc["sub_cpu"] += RenderingServer.viewport_get_measured_render_time_cpu(sub)
			acc["sub_gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(sub)
			acc["upd"] += float(fl.last_stats()["usec"])
			acc["proc"] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			active = maxi(active, int(fl.last_stats()["active"]))
		_ev(
			(
				(
					"perf %s: active=%d near=%d full=%d | root render cpu %.3f ms gpu %.3f ms | "
					+ "fabric subviewport cpu %.3f ms gpu %.3f ms | fold update cpu %.1f us | "
					+ "frame process %.3f ms (avg of %d)"
				)
				% [
					mode,
					active,
					sk.get_near_folds().size(),
					sk.get_full_marks().size(),
					acc["cpu"] / frames,
					acc["gpu"] / frames,
					acc["sub_cpu"] / frames,
					acc["sub_gpu"] / frames,
					acc["upd"] / frames,
					acc["proc"] / frames,
					frames,
				]
			)
		)
	await _cap("perf_state_on")
	fl.enabled = true
	sk.visible = true
	get_tree().paused = false


## 같은 장면(일시정지한 같은 프레임)을 높이 비교 모드로 다시 그려 찍는다.
## a=이전 3.3 공식(실제 강도, 상한 36px), b=새 기본값(보통 강도 0.6 → FOLD_HEIGHT), c=강한 드리프트 정점(강도 1).
func _cap_height_modes(prefix: String) -> void:
	var pr: Node = _presenter()
	var fl: Node = _folds()
	var p: PlayerController = _player()
	if fl == null or not ("debug_height_mode" in fl):
		_fail("height modes unavailable")
		return
	get_tree().paused = true
	var now: float = float(pr._fx_time)
	for pair in [[4, "a_prev33"], [3, "b_new"], [2, "c_peak"]]:
		fl.debug_height_mode = pair[0]
		fl.update_view(now, p.position, p.heading)
		await _ticks(2)
		await _cap("%s_%s" % [prefix, pair[1]])
	fl.debug_height_mode = 0
	fl.update_view(now, p.position, p.heading)
	get_tree().paused = false


func _height_drift(dir: int, tag: String) -> void:
	auto = false
	_steer(dir)
	_drift(true)
	for i in 22:
		await get_tree().physics_frame
		if i == 20:
			await _cap_height_modes("hc_%s_t21" % tag)
	_drift(false)
	_steer(0)
	auto = true
	await _ticks(6)
	await _cap_height_modes("hc_%s_relax6" % tag)


## 높이 비교: 좌/우 드리프트 각각 드리프트 중(21틱)과 완화 중(놓은 뒤 6틱)을 세 높이 모드로.
## compare 시나리오와 같은 커브·입력이라 같은 카메라에서 비교할 수 있다.
func _scenario_heightcmp() -> void:
	await _start_run(3, 120)
	await _wait_curve(1)
	await _height_drift(1, "right")
	await _recover()
	await _wait_curve(-1)
	await _height_drift(-1, "left")


## 드리프트 유지(Shift를 누른 채): drift_dir이 keep 아래로 내려가면 조향 키를 누르고 넘으면 뗀다. 같은 방향
## 스트로크가 끊기지 않게 유지하면서 회전 반경을 키운다(keep이 클수록 급한 곡선).
func _drift_hold(dir: int, n: int, keep: float, cap_at: Dictionary = {}) -> void:
	auto = false
	_drift(true)
	var p: PlayerController = _player()
	for i in n:
		_steer(dir if p.drift_dir * float(dir) < keep else 0)
		await get_tree().physics_frame
		if cap_at.has(i):
			var nm: String = cap_at[i]
			if nm.begins_with("LAYERS_"):
				await _cap_layers(nm.substr(7))
			else:
				await _cap(nm)
	_drift(false)
	_steer(0)


## 같은 프레임(일시정지)을 주름 레이어·바닥 잔여 흔적을 켜고 끄며 찍는다(어느 층이 그린 것인지 확인용).
func _cap_layers(prefix: String) -> void:
	var pr: Node = _presenter()
	var fl: Node = _folds()
	var sk: Node = _skid()
	var p: PlayerController = _player()
	get_tree().paused = true
	var now: float = float(pr._fx_time)
	for v in [[true, true, "all"], [false, true, "no_layer"], [true, false, "no_residue"]]:
		fl.enabled = v[0]
		sk.visible = v[1]
		fl.update_view(now, p.position, p.heading)
		await _ticks(3)
		await _cap("%s_%s" % [prefix, v[2]])
	fl.enabled = true
	sk.visible = true
	fl.update_view(now, p.position, p.heading)
	get_tree().paused = false


## 긴 드리프트(2.5초 유지) 좌/우 + 짧은 드리프트 + 급한 곡선 드리프트 + 급반전. 긴 드리프트는 연속 프레임과
## 놓은 뒤 완화까지 남긴다.
func _scenario_longdrift() -> void:
	await _start_run(3, 120)
	for pair in [[1, "right"], [-1, "left"]]:
		var dir: int = pair[0]
		var tag: String = pair[1]
		await _wait_curve(dir, 400)
		_seq("seq_long_%s" % tag, 200)
		await _ticks(4)
		await _drift_hold(
			dir,
			150,
			0.35,
			{
				30: "ld_%s_t030" % tag,
				50: "LAYERS_ld_%s_t050" % tag,
				75: "ld_%s_t075" % tag,
				96: "LAYERS_ld_%s_t096" % tag,
				149: "ld_%s_t150" % tag
			}
		)
		auto = true
		await _ticks(10)
		await _cap("ld_%s_release10" % tag)
		await _ticks(30)
		await _cap("ld_%s_release40" % tag)
		await _recover()
	# 짧은 드리프트.
	await _wait_curve(1, 400)
	await _drift_burst(1, 8, {7: "sd_short_t8"})
	auto = true
	await _ticks(10)
	await _cap("sd_short_release10")
	await _recover()
	# 급한 곡선 드리프트(조향을 강하게 유지).
	await _wait_curve(-1, 400)
	_seq("seq_curve_left", 120)
	await _drift_hold(-1, 90, 0.85, {45: "cd_curve_t045", 89: "cd_curve_t090"})
	auto = true
	await _ticks(10)
	await _cap("cd_curve_release10")
	await _recover()
	# 급반전(드리프트 유지, 우 → 좌).
	await _wait_curve(1, 400)
	auto = false
	_drift(true)
	_steer(1)
	await _ticks(24)
	await _cap("rv_before")
	_steer(-1)
	await _ticks(12)
	await _cap("rv_t12")
	await _ticks(12)
	await _cap("rv_t24")
	_drift(false)
	_steer(0)
	auto = true
