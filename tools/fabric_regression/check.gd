extends Node
## 원단별 주행 특성(FabricProfile) 회귀 검사(사본 프로젝트 전용, run.sh가 실행).
##
## 확인 항목:
##  table/fallback   : 8종 로드·계획 초기값·라벨/에디터/공식 트랙 원단 일치, 미지·빈·혼합 값 면 대체,
##                     파일 손상·범위 밖 배율이면 1.0.
##  identity         : 면 프로필(미설정·명시·fallback)이 v2.2.1 PlayerController와 틱마다 비트 단위로 같음.
##  effective_paths  : reset·기어·부상·이탈 복귀·프로필 후적용의 speed, 조향 지연, 회전 각속도, 위험 속도 계수.
##  risk_gate        : 위험 배율은 danger_threshold를 넘은 틱의 누적률에만, 회복률은 그대로.
##  thimble_cap      : 모든 원단에서 골무 창 안 RISK 0.95 상한·부상 봉인.
##  tuning_invariant : 여러 원단 런 뒤에도 전역 Tuning 값 불변, 새 플레이어는 면.
##  director         : (사본 RaceDirector에 프로필 적용 한 줄이 있을 때) 런 시작 적용, 엄마 찬스 진행 거리,
##                     부상·이탈 복귀 속도, 다음 트랙 비누적.
##  completion       : 8종 × (공식 15개 + 서버 경계 fixture + 최소반경 합성 트랙) 자동 주행 완주.
##  feel             : 원단별 체감 측정 표 출력(+ 실크 1~2단 안전, 데님 저위험, 대칭 등 최소 단언).
## 실패한 assertion이 하나라도 있으면 종료 코드 1.

const Driver = preload("res://fabric_regression/fabric_driver.gd")
const Feel = preload("res://fabric_regression/fabric_feel.gd")
const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const SelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const DT: float = 1.0 / 60.0
const FIXTURE_DIR: String = "res://fabric_regression/fixtures/"
# 계획(docs/personal-ghost-and-fabric-driving-plan.md §2) 첫 밸런스 표. [speed, steer_tau, risk_gain]
const PLAN_TABLE: Dictionary = {
	"cotton": [1.00, 1.00, 1.00],
	"denim": [0.94, 0.90, 0.85],
	"silk": [1.04, 1.15, 1.10],
	"knit": [0.98, 1.08, 0.95],
	"wool": [0.95, 1.00, 0.90],
	"felt": [0.96, 0.88, 0.90],
	"satin": [1.02, 1.10, 1.05],
	"leather": [0.92, 0.95, 0.85],
}
const FABRICS: Array[String] = [
	"cotton", "denim", "silk", "knit", "wool", "felt", "satin", "leather"
]
const MIN_PASSED: int = 400
const SECTIONS: Array[String] = [
	"table",
	"fallback",
	"identity",
	"effective_paths",
	"risk_gate",
	"thimble_cap",
	"director",
	"completion",
	"feel",
	"tuning_invariant",
]
const TUNING_KEYS: Array[String] = [
	"min_speed",
	"max_speed",
	"speed_step_count",
	"steer_tau",
	"risk_gain_rate",
	"risk_recover_rate",
	"danger_threshold",
	"turn_power",
	"steer_speed_floor",
	"risk_speed_exp",
	"risk_static_bias",
	"thimble_duration",
	"autopilot_duration",
	"cut_windup_duration",
	"stun_duration",
	"reset_lockout",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _tuning_before: Dictionary = {}


func _ready() -> void:
	LeaderboardClient.tutorial_seen = true
	_tuning_before = _tuning_snapshot()
	_check_table()
	_check_fallback()
	_check_identity()
	_check_effective_paths()
	_check_risk_gate()
	_check_thimble_cap()
	await _check_director()
	_check_completion()
	_check_feel()
	_check_tuning_invariant()
	_ok(_done == SECTIONS, "all check sections ran (%s)" % [_done])
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("fabric regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


func _prof(f: String) -> Dictionary:
	return FabricProfile.for_fabric(f)


# --- table ---


func _check_table() -> void:
	var n: int = FabricProfile.load_table()
	_ok(n == 8, "fabric_profiles.json loads 8 profiles (%d)" % n)
	var known: Array[String] = FabricProfile.known_fabrics()
	var expect: Array[String] = FABRICS.duplicate()
	expect.sort()
	_ok(known == expect, "known fabrics == 8 ids (%s)" % [known])
	var editor_ids: Array = EditorDoc.FABRICS.duplicate()
	editor_ids.sort()
	_ok(editor_ids == Array(expect), "EditorDoc.FABRICS matches table")
	var select_ids: Array = SelectScript.FABRIC_LABELS.keys()
	select_ids.sort()
	_ok(select_ids == Array(expect), "TrackSelect FABRIC_LABELS keys match table")
	var hub_ids: Array = TrackLoader.HUB_FABRICS.duplicate()
	hub_ids.sort()
	_ok(hub_ids == Array(expect), "TrackLoader.HUB_FABRICS (hub allow-list) matches table")
	var surf_ids: Array = FabricSurface.FABRIC_BASE.keys()
	surf_ids.sort()
	_ok(surf_ids == Array(expect), "FabricSurface.FABRIC_BASE keys match table")
	for f in FABRICS:
		var p: Dictionary = _prof(f)
		var want: Array = PLAN_TABLE[f]
		_ok(
			(
				float(p["speed"]) == float(want[0])
				and float(p["steer_tau"]) == float(want[1])
				and float(p["risk_gain"]) == float(want[2])
			),
			(
				"%s multipliers == plan %s (got %.2f/%.2f/%.2f)"
				% [f, want, float(p["speed"]), float(p["steer_tau"]), float(p["risk_gain"])]
			)
		)
		_ok(not bool(p["is_fallback"]) and str(p["fabric"]) == f, "%s is not fallback" % f)
		var d: String = FabricProfile.describe(f)
		_ok(not d.is_empty() and d.length() <= 40, "%s describe short and non-empty: %s" % [f, d])
		_ok(
			str(p["label"]) == str(SelectScript.FABRIC_LABELS[f]),
			"%s label matches FABRIC_LABELS" % f
		)
	# 공식 트랙 원단이 모두 표에 있는가.
	var dir: DirAccess = DirAccess.open("res://tracks/official")
	var bad: Array = []
	var count: int = 0
	for fn in dir.get_files():
		if not fn.ends_with("_01.json"):
			continue
		var id: String = fn.get_basename()
		var td: TrackData = TrackLoader.load_track(id)
		count += 1
		if td == null or not known.has(td.fabric):
			bad.append(id)
	_ok(
		count == 15 and bad.is_empty(),
		"official tracks (%d) all use known fabrics %s" % [count, bad]
	)
	_done.append("table")


# --- fallback ---


func _check_fallback() -> void:
	for v in ["", "unknown", "cotton,silk", "cotton silk", "Silk", " silk", '["silk"]', "plaid"]:
		var p: Dictionary = _prof(v)
		_ok(
			(
				bool(p["is_fallback"])
				and str(p["fabric"]) == "cotton"
				and float(p["speed"]) == 1.0
				and float(p["steer_tau"]) == 1.0
				and float(p["risk_gain"]) == 1.0
				and str(p["requested"]) == v
			),
			"fallback to cotton for '%s'" % v
		)
		_ok(FabricProfile.describe(v).contains("표준"), "fallback describe mentions 표준 for '%s'" % v)
	_ok(not bool(_prof("cotton")["is_fallback"]), "cotton itself is not a fallback")
	# 파일 손상·범위 밖 배율.
	_ok(FabricProfile.load_table("{not json") == 0, "broken json -> 0 profiles")
	for f in FABRICS:
		var p: Dictionary = _prof(f)
		_ok(
			(
				float(p["speed"]) == 1.0
				and float(p["steer_tau"]) == 1.0
				and float(p["risk_gain"]) == 1.0
			),
			"broken table: %s runs at 1.0" % f
		)
	_ok(not bool(_prof("cotton")["is_fallback"]), "broken table: cotton still official")
	var partial: String = (
		JSON
		. stringify(
			{
				"version": 1,
				"profiles":
				{
					"cotton": {"speed": 1.0, "steer_tau": 1.0, "risk_gain": 1.0},
					"silk": {"speed": 9.0, "steer_tau": 1.0, "risk_gain": 1.0},
					"denim": {"speed": "fast", "steer_tau": 1.0, "risk_gain": 1.0},
					"wool": {"speed": 0.95, "steer_tau": 1.0},
					"felt": {"speed": 0.96, "steer_tau": 0.88, "risk_gain": 0.9},
				}
			}
		)
	)
	_ok(FabricProfile.load_table(partial) == 2, "invalid rows dropped (cotton+felt remain)")
	_ok(bool(_prof("silk")["is_fallback"]), "out-of-range silk row -> fallback")
	_ok(bool(_prof("denim")["is_fallback"]), "non-number denim row -> fallback")
	_ok(bool(_prof("wool")["is_fallback"]), "missing key wool row -> fallback")
	_ok(float(_prof("felt")["speed"]) == 0.96, "valid felt row kept")
	_ok(FabricProfile.describe("felt") == FabricProfile.detail("felt"), "missing desc -> detail")
	_ok(FabricProfile.load_table() == 8, "reload real table")
	# PlayerController의 비정상 배율 방어.
	var p: PlayerController = Driver.make_player(self, {})
	p.set_fabric_profile({"speed": 0.0, "steer_tau": -1.0, "risk_gain": NAN})
	var m: Dictionary = p.fabric_multipliers()
	_ok(
		float(m["speed"]) == 1.0 and float(m["steer_tau"]) == 1.0 and float(m["risk_gain"]) == 1.0,
		"player rejects non-positive / NaN multipliers"
	)
	p.set_fabric_profile({})
	_ok(p.fabric_id == "cotton", "empty profile dict -> cotton id")
	p.queue_free()
	_done.append("fallback")


# --- identity ---


## 기준본(v2.2.1)과 새 컨트롤러를 같은 입력·이벤트로 나란히 돌려 상태를 틱마다 정확히(==) 비교한다.
func _identity_run(seed: int, ticks: int, mode: String) -> Dictionary:
	var a: PlayerControllerV221 = PlayerControllerV221.new()
	var nva: Polygon2D = Polygon2D.new()
	nva.name = "NeedleVisual"
	a.add_child(nva)
	add_child(a)
	var b: PlayerController = Driver.make_player(self, {})
	match mode:
		"explicit":
			b.set_fabric_profile(_prof("cotton"))
		"fallback":
			b.set_fabric_profile(_prof("mystery"))
		"after_reset":
			pass
	a.reset_state(Vector2(10.0, 20.0), 0.3)
	b.reset_state(Vector2(10.0, 20.0), 0.3)
	if mode == "after_reset":
		b.set_fabric_profile(_prof("cotton"))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var steer: float = 0.0
	var drift: bool = false
	var stats: Dictionary = {"cuts": 0, "thimble": 0, "autopilot": 0, "reset": 0, "resolve": 0}
	var mismatch: int = 0
	var first: String = ""
	var ap_pos: Vector2 = Vector2.ZERO
	var ap_head: float = 0.0
	for i in range(ticks):
		if i % 20 == 0:
			var r: float = rng.randf()
			steer = -1.0 if r < 0.4 else (1.0 if r < 0.8 else 0.0)
			drift = rng.randf() < 0.3
		var sd: int = 0
		var rs: float = rng.randf()
		if rs < 0.04:
			sd = 1
		elif rs < 0.05:
			sd = -1
		elif rs < 0.052:
			sd = 3
		var ev: float = rng.randf()
		if ev < 0.002:
			a.grant_thimble()
			b.grant_thimble()
			stats["thimble"] = int(stats["thimble"]) + 1
		elif ev < 0.003:
			a.grant_autopilot()
			b.grant_autopilot()
			stats["autopilot"] = int(stats["autopilot"]) + 1
		elif ev < 0.004:
			var rp: Vector2 = Vector2(rng.randf_range(-500, 500), rng.randf_range(-500, 500))
			var rh: float = rng.randf_range(-PI, PI)
			a.off_fabric_reset(rp, rh)
			b.off_fabric_reset(rp, rh)
			stats["reset"] = int(stats["reset"]) + 1
		elif ev < 0.006 and a.is_cut_pending():
			a.resolve_cut_pending_now()
			b.resolve_cut_pending_now()
			stats["resolve"] = int(stats["resolve"]) + 1
		if a.autopilot_timer > 0.0:
			ap_pos += Vector2(cos(ap_head), sin(ap_head)) * a.speed * DT
			ap_head += 0.01
			a.autopilot_target_pos = ap_pos
			a.autopilot_target_heading = ap_head
			b.autopilot_target_pos = ap_pos
			b.autopilot_target_heading = ap_head
		var inp: InputFrame = InputFrame.new(steer, sd, false, drift)
		a.simulate(inp, DT)
		b.simulate(inp, DT)
		var ca: bool = a.consume_just_cut()
		var cb: bool = b.consume_just_cut()
		if ca:
			stats["cuts"] = int(stats["cuts"]) + 1
		var same: bool = (
			a.position.x == b.position.x
			and a.position.y == b.position.y
			and a.heading == b.heading
			and a.speed == b.speed
			and a.speed_index == b.speed_index
			and a.target_steer == b.target_steer
			and a.actual_steer == b.actual_steer
			and a.risk == b.risk
			and a.stun_timer == b.stun_timer
			and a.offfabric_timer == b.offfabric_timer
			and a.is_drifting == b.is_drifting
			and a.drift_dir == b.drift_dir
			and a.thimble_timer == b.thimble_timer
			and a.autopilot_timer == b.autopilot_timer
			and a.cut_pending_timer == b.cut_pending_timer
			and a.cut_pending_progress() == b.cut_pending_progress()
			and ca == cb
		)
		if not same:
			mismatch += 1
			if first.is_empty():
				first = (
					"tick %d pos %s/%s spd %s/%s risk %s/%s"
					% [i, a.position, b.position, a.speed, b.speed, a.risk, b.risk]
				)
	a.queue_free()
	b.queue_free()
	stats["mismatch"] = mismatch
	stats["first"] = first
	return stats


func _check_identity() -> void:
	var total: Dictionary = {"cuts": 0, "thimble": 0, "autopilot": 0, "reset": 0, "resolve": 0}
	var runs: int = 0
	var ticks: int = 0
	for mode in ["unset", "explicit", "fallback", "after_reset"]:
		for seed in [11, 2026, 90210]:
			var st: Dictionary = _identity_run(seed, 6000, mode)
			runs += 1
			ticks += 6000
			_ok(
				int(st["mismatch"]) == 0,
				(
					"cotton[%s] seed %d bit-identical to v2.2.1 over 6000 ticks %s"
					% [mode, seed, str(st["first"])]
				)
			)
			for k in total.keys():
				total[k] = int(total[k]) + int(st[k])
	print(
		(
			"IDENTITY runs=%d ticks=%d cuts=%d thimble=%d autopilot=%d reset=%d resolve=%d"
			% [
				runs,
				ticks,
				total["cuts"],
				total["thimble"],
				total["autopilot"],
				total["reset"],
				total["resolve"]
			]
		)
	)
	_ok(
		(
			int(total["cuts"]) > 0
			and int(total["thimble"]) > 0
			and int(total["autopilot"]) > 0
			and int(total["reset"]) > 0
		),
		"identity runs covered cuts/thimble/autopilot/reset (%s)" % [total]
	)
	_done.append("identity")


# --- effective paths ---


func _check_effective_paths() -> void:
	var cot: PlayerController = Driver.make_player(self, _prof("cotton"))
	for f in FABRICS:
		var prof: Dictionary = _prof(f)
		var m: float = float(prof["speed"])
		var tm: float = float(prof["steer_tau"])
		var p: PlayerController = Driver.make_player(self, prof)
		p.reset_state(Vector2.ZERO, 0.0)
		_ok(p.speed == Tuning.speed_table[0] * m, "%s reset_state speed = g1 x %.2f" % [f, m])
		_ok(
			(
				p.effective_min_speed() == Tuning.min_speed * m
				and p.effective_max_speed() == Tuning.max_speed * m
			),
			"%s effective min/max speed" % f
		)
		var gear_ok: bool = true
		var move_ok: bool = true
		for g in range(2, 6):
			var before: Vector2 = p.position
			p.simulate(InputFrame.new(0.0, 1, false, false), DT)
			gear_ok = gear_ok and p.speed == Tuning.speed_table[g - 1] * m and p.speed_index == g
			move_ok = move_ok and is_equal_approx(p.position.distance_to(before), p.speed * DT)
		_ok(gear_ok, "%s gear up 2..5 speeds = table x %.2f" % [f, m])
		_ok(move_ok, "%s straight advance per tick = effective speed x dt" % f)
		_ok(p.effective_speed() == p.speed, "%s effective_speed() == speed" % f)
		p.simulate(InputFrame.new(0.0, -4, false, false), DT)
		_ok(p.speed == Tuning.speed_table[0] * m and p.speed_index == 1, "%s gear down to 1" % f)
		# 프로필을 reset_state 뒤(3단)에 적용해도 현재 단계 속도가 맞춰진다.
		var q: PlayerController = Driver.make_player(self, {})
		q.reset_state(Vector2.ZERO, 0.0)
		q.simulate(InputFrame.new(0.0, 2, false, false), DT)
		q.set_fabric_profile(prof)
		_ok(q.speed == Tuning.speed_table[2] * m, "%s profile applied after reset keeps gear 3" % f)
		q.queue_free()
		# 조향 지연: target 1, actual 0에서 한 틱.
		p.target_steer = 1.0
		p.actual_steer = 0.0
		p.simulate(InputFrame.new(1.0, 0, false, false), DT)
		var want_a: float = 1.0 - exp(-DT / (Tuning.steer_tau * tm))
		_ok(is_equal_approx(p.actual_steer, want_a), "%s steer follow uses tau x %.2f" % [f, tm])
		_ok(
			is_equal_approx(p.effective_steer_tau(), Tuning.steer_tau * tm),
			"%s effective_steer_tau" % f
		)
		# 회전 각속도·위험 속도 계수: 같은 단계에서 면과 같다(반경만 속도 배율만큼).
		var turn_ok: bool = true
		var sf_ok: bool = true
		for g in range(1, 6):
			var dh_f: float = _full_lock_dheading(p, g)
			var dh_c: float = _full_lock_dheading(cot, g)
			turn_ok = turn_ok and is_equal_approx(dh_f, dh_c)
			var sf_f: float = inverse_lerp(
				p.effective_min_speed(), p.effective_max_speed(), p.speed
			)
			var sf_c: float = inverse_lerp(
				cot.effective_min_speed(), cot.effective_max_speed(), cot.speed
			)
			sf_ok = sf_ok and is_equal_approx(sf_f, sf_c)
		_ok(turn_ok, "%s full-lock yaw rate per gear == cotton (radius x %.2f)" % [f, m])
		_ok(sf_ok, "%s risk speed factor per gear == cotton" % f)
		# 부상 경로.
		var c: Dictionary = Feel.cut_and_reset(self, prof)
		_ok(float(c["cut_speed"]) == Tuning.speed_table[0] * m, "%s speed after cut = g1 x m" % f)
		_ok(
			float(c["reset_speed"]) == Tuning.speed_table[0] * m,
			"%s speed after off-fabric reset = g1 x m" % f
		)
		# resolve_cut_pending_now 경로(완주 틱 확정).
		var r: PlayerController = Driver.make_player(self, prof)
		r.reset_state(Vector2.ZERO, 0.0)
		r.simulate(InputFrame.new(0.0, 4, false, false), DT)
		for _i in range(900):
			r.simulate(InputFrame.new(1.0, 0, false, true), DT)
			if r.is_cut_pending():
				break
		r.resolve_cut_pending_now()
		_ok(
			r.consume_just_cut() and r.speed == Tuning.speed_table[0] * m,
			"%s resolve_cut_pending_now speed = g1 x m" % f
		)
		r.queue_free()
		p.queue_free()
	cot.queue_free()
	_done.append("effective_paths")


## 기어 g에서 풀락(target=actual=1) 한 틱의 heading 변화량.
func _full_lock_dheading(p: PlayerController, g: int) -> float:
	p.stun_timer = 0.0
	p.offfabric_timer = 0.0
	p.cut_pending_timer = 0.0
	p.simulate(InputFrame.new(0.0, g - p.speed_index, false, false), DT)
	p.target_steer = 1.0
	p.actual_steer = 1.0
	p.risk = 0.0
	var h0: float = p.heading
	p.simulate(InputFrame.new(1.0, 0, false, false), DT)
	return p.heading - h0


# --- risk gate ---


func _check_risk_gate() -> void:
	var cases: Array = [
		["cotton", _prof("cotton")],
		["silk", _prof("silk")],
		["denim", _prof("denim")],
		["risk_only_1.10", {"fabric": "x", "speed": 1.0, "steer_tau": 1.0, "risk_gain": 1.1}],
	]
	var base_up: float = 0.0
	for c in cases:
		var prof: Dictionary = c[1]
		var rm: float = float(prof["risk_gain"])
		# 임계 아래(target·actual 0.5, 입력 없음): 회복만, 원단과 무관하게 같은 양.
		var p: PlayerController = Driver.make_player(self, prof)
		p.reset_state(Vector2.ZERO, 0.0)
		p.simulate(InputFrame.new(0.0, 4, false, false), DT)
		p.target_steer = 0.5
		p.actual_steer = 0.5
		p.risk = 0.3
		p.simulate(InputFrame.new(0.0, 0, false, false), DT)
		_ok(
			is_equal_approx(p.risk, 0.3 - Tuning.risk_recover_rate * DT),
			"%s below threshold: recover rate unchanged (risk %.6f)" % [c[0], p.risk]
		)
		# 임계 위(5단 풀락 유지, gap 0 → gain = static bias): 누적률만 배율.
		p.target_steer = 1.0
		p.actual_steer = 1.0
		p.risk = 0.3
		p.simulate(InputFrame.new(1.0, 0, false, false), DT)
		var up: float = p.risk - 0.3
		var want: float = Tuning.risk_static_bias * Tuning.risk_gain_rate * rm * DT
		_ok(
			is_equal_approx(up, want),
			"%s above threshold: gain x %.2f (delta %.6f want %.6f)" % [c[0], rm, up, want]
		)
		if c[0] == "cotton":
			base_up = up
		else:
			_ok(is_equal_approx(up / base_up, rm), "%s gain ratio vs cotton = %.3f" % [c[0], rm])
		p.queue_free()
	_done.append("risk_gate")


# --- thimble cap ---


func _check_thimble_cap() -> void:
	for f in FABRICS:
		var t: Dictionary = Feel.thimble(self, _prof(f))
		_ok(
			float(t["cap_peak"]) <= PlayerController.THIMBLE_RISK_CAP and not bool(t["cut_in"]),
			"%s thimble caps risk at 0.95, no cut (peak %.3f)" % [f, float(t["cap_peak"])]
		)
		_ok(float(t["after"]) >= 0.0, "%s cut possible again after thimble expiry" % f)
	_done.append("thimble_cap")


# --- tuning invariant ---


func _tuning_snapshot() -> Dictionary:
	var d: Dictionary = {}
	for k in TUNING_KEYS:
		d[k] = Tuning.get(k)
	d["speed_table"] = (Tuning.speed_table as Array).duplicate()
	return d


func _check_tuning_invariant() -> void:
	# 실크 → 가죽 두 런 연속(트랙 완주) 후에도 전역 Tuning 값이 처음과 같다.
	var td: TrackData = TrackLoader.load_track("cotton_01")
	Driver.drive(self, td, _prof("silk"))
	Driver.drive(self, td, _prof("leather"))
	var after: Dictionary = _tuning_snapshot()
	for k in _tuning_before.keys():
		_ok(_tuning_before[k] == after[k], "Tuning.%s unchanged after fabric runs" % k)
	var fresh: PlayerController = Driver.make_player(self, {})
	fresh.reset_state(Vector2.ZERO, 0.0)
	var m: Dictionary = fresh.fabric_multipliers()
	_ok(
		(
			fresh.fabric_id == "cotton"
			and float(m["speed"]) == 1.0
			and float(m["steer_tau"]) == 1.0
			and float(m["risk_gain"]) == 1.0
			and fresh.speed == Tuning.speed_table[0]
		),
		"new player after silk/leather runs is cotton (no carry-over)"
	)
	fresh.queue_free()
	_done.append("tuning_invariant")


# --- director ---


func _spawn(track_id: String) -> Node:
	GameState.track_id = track_id
	var gp: Node = GameplayScene.instantiate()
	get_tree().root.add_child.call_deferred(gp)
	await get_tree().process_frame
	await get_tree().process_frame
	gp.set_physics_process(false)
	gp._state = gp.State.RUNNING
	return gp


func _check_director() -> void:
	var rd_src: String = FileAccess.get_file_as_string("res://scripts/systems/RaceDirector.gd")
	var wired: bool = rd_src.contains("set_fabric_profile")
	print("DIRECTOR wired=%s" % wired)
	_ok(wired, "RaceDirector (copy) applies fabric profile at run start")
	if not wired:
		_done.append("director")
		return
	# 1) 실크 트랙: 런 시작 적용 + 엄마 찬스 진행 거리.
	var gp: Node = await _spawn("basin_01")
	var pl: PlayerController = gp._player
	var sp: Dictionary = _prof("silk")
	_ok(gp._track.fabric == "silk" and pl.fabric_id == "silk", "basin_01 runs with silk profile")
	_ok(pl.speed == Tuning.speed_table[0] * 1.04, "silk run starts at g1 x 1.04 (%.3f)" % pl.speed)
	var mm: Dictionary = pl.fabric_multipliers()
	_ok(
		(
			float(mm["speed"]) == float(sp["speed"])
			and float(mm["steer_tau"]) == float(sp["steer_tau"])
			and float(mm["risk_gain"]) == float(sp["risk_gain"])
		),
		"player multipliers == FabricProfile silk"
	)
	gp._buf_speed_delta = 4
	gp._physics_process(DT)
	_ok(pl.speed == Tuning.speed_table[4] * 1.04, "director gear up: g5 x 1.04")
	gp._slots.append("autopilot")
	gp._buf_use_item = true
	var deltas_ok: bool = true
	var n_ap: int = 0
	var dist: float = 0.0
	var prev_s: float = gp._last_s
	for i in range(240):
		var s0: float = gp._autopilot_s if i > 0 else prev_s
		gp._physics_process(DT)
		if pl.autopilot_timer <= 0.0 and i > 0:
			break
		var ds: float = gp._autopilot_s - s0
		if gp._autopilot_s < gp._track.length - 1.0:
			deltas_ok = deltas_ok and is_equal_approx(ds, pl.effective_speed() * DT)
		dist += ds
		n_ap += 1
	_ok(
		n_ap > 100 and deltas_ok,
		"autopilot advances effective speed x dt per tick (%d ticks)" % n_ap
	)
	print("DIRECTOR silk autopilot g5: %d ticks, %.1f px" % [n_ap, dist])
	# 부상 경로(실제 입력): 5단 드리프트 풀조향.
	Input.action_press("steer_right")
	Input.action_press("drift")
	var cut_seen: bool = false
	for _i in range(1200):
		if pl.stun_timer <= 0.0 and pl.speed_index < 5:
			gp._buf_speed_delta = 5 - pl.speed_index
		var was: bool = pl.stun_timer > 0.0
		gp._physics_process(DT)
		if pl.stun_timer > 0.0 and not was:
			cut_seen = true
			_ok(pl.speed == Tuning.speed_table[0] * 1.04, "director cut -> g1 x 1.04")
			break
	Input.action_release("steer_right")
	Input.action_release("drift")
	_ok(cut_seen, "director cut observed on silk")
	gp.queue_free()
	await get_tree().process_frame
	# 2) 이탈 복귀(가죽 트랙).
	gp = await _spawn("ridge_01")
	pl = gp._player
	_ok(pl.fabric_id == "leather", "ridge_01 runs with leather profile")
	gp._buf_speed_delta = 3
	gp._physics_process(DT)
	pl.position += Vector2(4000.0, 4000.0)
	for _i in range(20):
		gp._physics_process(DT)
		if gp._stats.resets > 0:
			break
	_ok(
		gp._stats.resets == 1 and pl.speed == Tuning.speed_table[0] * 0.92,
		"director off-fabric reset -> g1 x 0.92 (resets %d)" % gp._stats.resets
	)
	gp.queue_free()
	await get_tree().process_frame
	# 3) 다음 트랙(면)으로 넘어가면 배율이 누적되지 않는다.
	gp = await _spawn("cotton_01")
	pl = gp._player
	mm = pl.fabric_multipliers()
	_ok(
		(
			pl.fabric_id == "cotton"
			and float(mm["speed"]) == 1.0
			and float(mm["steer_tau"]) == 1.0
			and float(mm["risk_gain"]) == 1.0
			and pl.speed == Tuning.speed_table[0]
		),
		"cotton_01 after silk/leather runs at 1.0"
	)
	gp.queue_free()
	await get_tree().process_frame
	GameState.track_id = "cotton_01"
	_done.append("director")


# --- completion ---


## 서버 fixture 트랙(JSON의 track 필드)을 TrackData로 굽는다.
func _fixture_track(fn: String) -> TrackData:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_DIR + fn))
	var t: Dictionary = d["track"]
	var td: TrackData = TrackData.new()
	td.bake(t["path"])
	td.perfect = float(t["width"]["perfect"])
	td.safe = float(t["width"]["safe"])
	td.fail = float(t["width"]["fail"])
	td.track_id = fn.get_basename()
	td.fabric = str(t.get("fabric", ""))
	return td


## 최소반경 부근 합성 트랙. esses=false면 직선(150px)으로 이은 좌·우 90도 계단, true면 좌·우 90도
## 호를 직선 없이 붙인 S자(반전 연속)와 직선을 번갈아 둔다. 반경 r.
func _synthetic_track(r: float, esses: bool) -> TrackData:
	var pts: Array = []
	var pos: Vector2 = Vector2.ZERO
	var head: float = 0.0
	pts.append([pos.x, pos.y])
	var segs: Array = [["line", 200.0]]
	for i in range(10):
		var dir: float = 1.0 if i % 2 == 0 else -1.0
		if esses:
			segs.append(["arc", dir])
			segs.append(["arc", -dir])
			segs.append(["line", 160.0])
		else:
			segs.append(["arc", dir])
			segs.append(["line", 150.0])
	for sg in segs:
		if sg[0] == "line":
			var n: int = ceili(float(sg[1]) / 5.0)
			var step: float = float(sg[1]) / float(n)
			for _k in range(n):
				pos += Vector2(cos(head), sin(head)) * step
				pts.append([pos.x, pos.y])
		else:
			var dir2: float = float(sg[1])
			var n2: int = 16
			var center: Vector2 = (
				pos + Vector2(cos(head + dir2 * PI / 2), sin(head + dir2 * PI / 2)) * r
			)
			var a0: float = (pos - center).angle()
			for k in range(1, n2 + 1):
				var a: float = a0 + dir2 * (PI / 2) * float(k) / float(n2)
				pos = center + Vector2(cos(a), sin(a)) * r
				pts.append([pos.x, pos.y])
			head += dir2 * PI / 2
	var td: TrackData = TrackData.new()
	td.bake([{"type": "polyline", "points": pts, "closed": false}])
	# 90도 계단은 모서리 양쪽 다리가 보통 폭(fail 90)의 자기근접 하드 기준에 걸리므로 숙련 폭을 쓴다.
	td.perfect = 18.0 if esses else 14.0
	td.safe = 42.0 if esses else 34.0
	td.fail = 90.0 if esses else 72.0
	td.track_id = "synthetic_%s_r%d" % ["esses" if esses else "stairs", int(r)]
	return td


func _check_completion() -> void:
	var tracks: Array = []
	var dir: DirAccess = DirAccess.open("res://tracks/official")
	var files: Array = Array(dir.get_files())
	files.sort()
	for fn in files:
		if str(fn).ends_with("_01.json"):
			tracks.append(TrackLoader.load_track(str(fn).get_basename()))
	var fx: TrackData = _fixture_track("accept_boundary_radius_offset.json")
	var vfx: Dictionary = TrackValidator.new().validate(fx.points, fx.fail)
	_ok(bool(vfx["ok"]), "server boundary fixture validates (min_radius %.2f)" % vfx["min_radius"])
	tracks.append(fx)
	for esses in [false, true]:
		var syn: TrackData = _synthetic_track(29.0, esses)
		var v: Dictionary = TrackValidator.new().validate(syn.points, syn.fail)
		_ok(
			bool(v["ok"]),
			(
				"%s validates (min_radius %.2f, len %.0f, %s)"
				% [syn.track_id, v["min_radius"], v["length"], v["messages"]]
			)
		)
		tracks.append(syn)
	var header: String = "COMPLETION %-34s" % "track(min_r)"
	for f in FABRICS:
		header += " %9s" % f
	print(header)
	var all_ok: bool = true
	for td in tracks:
		var minr: float = TrackValidator.new().compute_min_radius(
			td.points, TrackValidator.build_arc_lengths(td.points)
		)
		var line: String = "COMPLETION %-34s" % ("%s(%.0f)" % [td.track_id, minr])
		var detail: String = "COMPLETION_DETAIL %s" % td.track_id
		for f in FABRICS:
			var r: Dictionary = Driver.drive(self, td, _prof(f))
			var ok: bool = bool(r["finished"]) and int(r["resets"]) == 0 and int(r["cuts"]) == 0
			all_ok = all_ok and ok
			line += " %9s" % ("%.2f" % float(r["time"]) if ok else "X")
			detail += (
				" | %s fin=%s t=%.2f res=%d cut=%d maxerr=%.0f tear=%d off=%d risk=%.2f g=%s"
				% [
					f,
					r["finished"],
					r["time"],
					r["resets"],
					r["cuts"],
					r["max_err"],
					r["tear_ticks"],
					r["off_seam_ticks"],
					r["max_risk"],
					r["gear_ticks"]
				]
			)
			_ok(ok, "%s completes on %s (t=%.2f)" % [f, td.track_id, float(r["time"])])
		print(line)
		print(detail)
	_ok(all_ok, "every fabric completes every track")
	_done.append("completion")


# --- feel ---


func _fmt(v: float) -> String:
	return "-" if v < 0.0 else "%.2f" % v


func _check_feel() -> void:
	var rows: Array = []
	for f in FABRICS:
		rows.append([f, _prof(f)])
	# 실크 이중 효과 분해용 가상 프로필(speed/tau/risk 중 하나만 실크 값).
	rows.append(
		["silk_tau_only", {"fabric": "x", "speed": 1.0, "steer_tau": 1.15, "risk_gain": 1.0}]
	)
	rows.append(
		["silk_risk_only", {"fabric": "x", "speed": 1.0, "steer_tau": 1.0, "risk_gain": 1.1}]
	)
	rows.append(
		["silk_speed_only", {"fabric": "x", "speed": 1.04, "steer_tau": 1.0, "risk_gain": 1.0}]
	)
	var res: Dictionary = {}
	print(
		"FEEL columns per gear g1..g5: hold_warn/hold_cut | rev_time/rev_peak/rev_cut | flips_to_cut"
	)
	print("FEEL drift_cut per gear | thimble cap/after | cut_speed")
	for row in rows:
		var name: String = row[0]
		var prof: Dictionary = row[1]
		var r: Dictionary = {"hold": [], "hold_l": [], "rev": [], "flips": [], "drift": []}
		for g in range(1, 6):
			r["hold"].append(Feel.hold(self, prof, g, 1.0, false))
			r["hold_l"].append(Feel.hold(self, prof, g, -1.0, false))
			r["rev"].append(Feel.reversal(self, prof, g))
			r["flips"].append(Feel.flips(self, prof, g))
			r["drift"].append(Feel.hold(self, prof, g, 1.0, true))
		r["thimble"] = Feel.thimble(self, prof)
		r["cut"] = Feel.cut_and_reset(self, prof)
		res[name] = r
		var l1: String = "FEEL %-16s hold" % name
		var l2: String = "FEEL %-16s rev " % name
		var l3: String = "FEEL %-16s flip" % name
		var l4: String = "FEEL %-16s drft" % name
		for g in range(5):
			var h: Dictionary = r["hold"][g]
			var rv: Dictionary = r["rev"][g]
			var fl: Dictionary = r["flips"][g]
			var dr: Dictionary = r["drift"][g]
			l1 += "  g%d %s/%s" % [g + 1, _fmt(h["warn"]), _fmt(h["cut"])]
			l2 += "  g%d %s/%.2f/%s" % [g + 1, _fmt(rv["rev"]), rv["peak"], _fmt(rv["cut"])]
			l3 += (
				"  g%d %s(pk %.2f)"
				% [g + 1, str(fl["flips"]) if int(fl["flips"]) >= 0 else "-", fl["peak"]]
			)
			l4 += "  g%d %s" % [g + 1, _fmt(dr["cut"])]
		print(l1)
		print(l2)
		print(l3)
		print(l4)
		var th: Dictionary = r["thimble"]
		print(
			(
				(
					"FEEL %-16s misc thimble_peak %.3f thimble_cut_in %s after_expiry %s"
					+ " cut_speed %.1f reset_speed %.1f autopilot_g3 %.0fpx g5 %.0fpx"
				)
				% [
					name,
					th["cap_peak"],
					th["cut_in"],
					_fmt(th["after"]),
					r["cut"]["cut_speed"],
					r["cut"]["reset_speed"],
					Tuning.speed_table[2] * float(prof["speed"]) * Tuning.autopilot_duration,
					Tuning.speed_table[4] * float(prof["speed"]) * Tuning.autopilot_duration,
				]
			)
		)
	# 최소 단언: 좌우 대칭, 실크 1~2단 안전(면과 같은 결과 범주), 데님 저위험, 실크 고속 위험 증가.
	for f in FABRICS:
		var sym: bool = true
		for g in range(5):
			sym = (
				sym
				and res[f]["hold"][g]["cut"] == res[f]["hold_l"][g]["cut"]
				and res[f]["hold"][g]["warn"] == res[f]["hold_l"][g]["warn"]
			)
		_ok(sym, "%s left/right hold symmetric" % f)
	var cot: Dictionary = res["cotton"]
	var silk: Dictionary = res["silk"]
	var denim: Dictionary = res["denim"]
	for g in range(2):
		for key in ["hold", "rev", "flips", "drift"]:
			var c_cut: bool = _cut_of(cot[key][g], key)
			var s_cut: bool = _cut_of(silk[key][g], key)
			_ok(
				s_cut == c_cut, "silk g%d %s: cut outcome same as cotton (%s)" % [g + 1, key, s_cut]
			)
		_ok(not _cut_of(silk["hold"][g], "hold"), "silk g%d full hold: no cut" % (g + 1))
		_ok(not _cut_of(silk["rev"][g], "rev"), "silk g%d reversal: no cut" % (g + 1))
		_ok(not _cut_of(silk["flips"][g], "flips"), "silk g%d repeated reversal: no cut" % (g + 1))
	_ok(
		float(silk["hold"][4]["cut"]) < float(cot["hold"][4]["cut"]),
		"silk g5 hold cuts sooner than cotton"
	)
	_ok(
		float(denim["hold"][4]["cut"]) > float(cot["hold"][4]["cut"]),
		"denim g5 hold cuts later than cotton"
	)
	_ok(
		float(silk["rev"][4]["peak"]) >= float(cot["rev"][4]["peak"]),
		"silk g5 reversal peak >= cotton"
	)
	_ok(
		float(denim["rev"][3]["peak"]) <= float(cot["rev"][3]["peak"]),
		"denim g4 reversal peak <= cotton"
	)
	_ok(
		float(silk["rev"][2]["rev"]) > float(cot["rev"][2]["rev"]),
		"silk reversal completes slower than cotton (g3)"
	)
	_done.append("feel")


func _cut_of(r: Dictionary, key: String) -> bool:
	if key == "flips":
		return int(r["flips"]) >= 0
	return float(r["cut"]) >= 0.0
