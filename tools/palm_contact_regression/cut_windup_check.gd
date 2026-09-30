extends Node
## 부상 사전 연출(windup) 시뮬 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## PlayerController 를 직접 만들어 simulate(input, dt)로 물리 틱을 구동하는 헤드리스 검사다.
## RISK 1.0 도달 → pending(사전 연출) → windup 종료 틱에 기존 부상 1회 → 중복 없음 순서와,
## 골무·엄마 찬스·이탈 리셋·reset_state 해제 경로, 입력 반영, 결정론, RaceDirector 집계를 확인한다.
## 실제 입력 플레이가 아니라 상태 주입·가상 입력 구동이다.
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const DT: float = 1.0 / 60.0
# 한 번의 위험 누적이 pending 까지 걸리는 최대 틱(5단 드리프트 풀조향은 약 1.5초).
const MAX_RAMP_TICKS: int = 900
# 전체 실행 시 통과해야 하는 최소 검사 수. 검사가 의도치 않게 빠지거나 분기를 건너뛰면 실패로 잡는다
# (검사를 추가해 수가 늘면 이 값도 함께 올린다).
const MIN_PASSED: int = 227
# 끝까지 실행된 검사 구획 이름. 스크립트 오류로 함수가 중간에 끊기면 이름이 남지 않아 실패로 잡힌다.
const SECTIONS: Array[String] = [
	"contract",
	"pending_sequence",
	"repeat_cuts",
	"thimble",
	"autopilot",
	"reset_paths",
	"inputs_during_pending",
	"zero_windup",
	"determinism",
	"director_counts",
	"director_offfabric",
	"director_finish",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _windup_ticks: int = 0


func _ready() -> void:
	LeaderboardClient.tutorial_seen = true
	_windup_ticks = roundi(Tuning.cut_windup_duration / DT)
	_check_contract()
	_check_pending_sequence()
	_check_repeat_cuts()
	_check_thimble()
	_check_autopilot()
	_check_reset_paths()
	_check_inputs_during_pending()
	_check_zero_windup()
	_check_determinism()
	await _check_director_counts()
	await _check_director_offfabric()
	await _check_director_finish()
	_ok(_done == SECTIONS, "all check sections ran to completion (%s)" % [_done])
	# 이 가드 자신도 통과로 세므로 +1.
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("cut windup regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


## 독립 PlayerController(NeedleVisual 자식 포함)를 만들어 트리에 붙이고 초기화한다.
func _new_player() -> PlayerController:
	var p: PlayerController = PlayerController.new()
	var nv: Polygon2D = Polygon2D.new()
	nv.name = "NeedleVisual"
	p.add_child(nv)
	add_child(p)
	p.reset_state(Vector2.ZERO, 0.0)
	return p


## 5단 + 드리프트 + 오른쪽 풀조향(가장 빨리 위험이 쌓이는 정상 입력).
func _danger() -> InputFrame:
	return InputFrame.new(1.0, 0, false, true)


## 조향·드리프트 없음(위험 회복 입력).
func _idle() -> InputFrame:
	return InputFrame.new(0.0, 0, false, false)


## 한 틱 진행하고 이번 틱 부상 여부를 소비해 돌려준다.
func _tick(p: PlayerController, input: InputFrame) -> bool:
	p.simulate(input, DT)
	return p.consume_just_cut()


## 5단으로 올린 뒤 위험 입력으로 pending 이 시작될 때까지 진행한다. 시작 전에 부상이 나거나
## 제한 틱 안에 pending 이 시작되지 않으면 false.
func _ramp_to_pending(p: PlayerController, tag: String) -> bool:
	p.simulate(InputFrame.new(0.0, 4, false, false), DT)
	var early_cut: bool = p.consume_just_cut()
	for i in range(MAX_RAMP_TICKS):
		if _tick(p, _danger()):
			early_cut = true
		if p.is_cut_pending():
			_ok(not early_cut, "%s: no cut before pending start (tick %d)" % [tag, i])
			return true
	_ok(false, "%s: pending started within %d ticks" % [tag, MAX_RAMP_TICKS])
	return false


## pending 시작 직후부터 부상 틱까지 진행하며 매 틱 pending 규칙을 확인한다. 부상까지 걸린 틱 수
## (시작 틱 기준)를 돌려주고, 부상이 없으면 -1.
func _run_windup(p: PlayerController, tag: String, input: InputFrame) -> int:
	var sidx: int = p.speed_index
	var prev_prog: float = p.cut_pending_progress()
	var ok_pending: bool = true
	var detail: String = ""
	for n in range(1, _windup_ticks + 30):
		var cut: bool = _tick(p, input)
		if cut:
			_ok(ok_pending, "%s: pending ticks held rules %s" % [tag, detail])
			return n
		var prog: float = p.cut_pending_progress()
		var tick_ok: bool = (
			p.is_cut_pending()
			and p.stun_timer == 0.0
			and p.risk == 1.0
			and p.speed_index == sidx
			and prog > prev_prog
			and prog <= 1.0
		)
		if not tick_ok and ok_pending:
			ok_pending = false
			detail = (
				"(first break at +%d: pending=%s stun=%.3f risk=%.3f sidx=%d prog=%.3f prev=%.3f)"
				% [n, p.is_cut_pending(), p.stun_timer, p.risk, p.speed_index, prog, prev_prog]
			)
		prev_prog = prog
	_ok(false, "%s: cut fired after windup" % tag)
	return -1


## 부상 틱 직후 상태가 기존 _trigger_cut 패널티와 같은지.
func _expect_cut_state(p: PlayerController, tag: String) -> void:
	_ok(p.stun_timer == Tuning.stun_duration, "%s: stun_timer == stun_duration" % tag)
	_ok(p.speed_index == 1, "%s: speed_index == 1 (got %d)" % [tag, p.speed_index])
	_ok(p.speed == Tuning.speed_table[0], "%s: speed == speed_table[0]" % tag)
	_ok(p.risk == 0.0, "%s: risk == 0 (got %.3f)" % [tag, p.risk])
	_ok(not p.is_cut_pending(), "%s: pending cleared on cut tick" % tag)
	_ok(p.cut_pending_progress() == 0.0, "%s: progress 0 after cut" % tag)


## 1) 공개 계약: 기본값, windup 길이, 60Hz 틱 수.
func _check_contract() -> void:
	var p: PlayerController = _new_player()
	_ok(Tuning.cut_windup_duration == 0.20, "Tuning.cut_windup_duration == 0.20")
	_ok(_windup_ticks == 12, "windup is 12 ticks at 60Hz (got %d)" % _windup_ticks)
	_ok(p.cut_pending_timer == 0.0, "cut_pending_timer starts at 0")
	_ok(not p.is_cut_pending(), "not pending at start")
	_ok(p.cut_pending_progress() == 0.0, "progress 0 when not pending")
	p.queue_free()
	_done.append("contract")


## 2) 도달 틱 → windup 동안 부상 없음 → 종료 틱에 정확히 1회 → 이후 중복 없음.
func _check_pending_sequence() -> void:
	var p: PlayerController = _new_player()
	# 도달 틱을 직접 확인하기 위해 틱 단위로 진행한다.
	p.simulate(InputFrame.new(0.0, 4, false, false), DT)
	p.consume_just_cut()
	_ok(p.speed_index == 5, "speed up to 5")
	var start_tick: int = -1
	var cut_before: bool = false
	for i in range(MAX_RAMP_TICKS):
		var before_risk: float = p.risk
		var cut: bool = _tick(p, _danger())
		cut_before = cut_before or cut
		if p.is_cut_pending():
			start_tick = i
			_ok(before_risk < 1.0, "risk below 1.0 before reach tick (%.3f)" % before_risk)
			break
	_ok(start_tick >= 0, "pending started on reach tick (tick %d)" % start_tick)
	_ok(not cut_before, "reach tick: consume_just_cut false")
	_ok(p.stun_timer == 0.0, "reach tick: stun_timer == 0")
	_ok(p.speed_index == 5, "reach tick: speed_index unchanged (5)")
	_ok(p.risk == 1.0, "reach tick: risk fixed at 1.0")
	_ok(
		is_equal_approx(p.cut_pending_timer, Tuning.cut_windup_duration),
		"reach tick: cut_pending_timer == windup (%.4f)" % p.cut_pending_timer
	)
	_ok(p.cut_pending_progress() == 0.0, "reach tick: progress 0")
	var n: int = _run_windup(p, "first cut", _danger())
	_ok(n == _windup_ticks, "cut exactly %d ticks after reach (got %d)" % [_windup_ticks, n])
	_expect_cut_state(p, "first cut")
	# 부상 틱 이후: 스턴 동안 중복 부상·재-pending 없음.
	var extra_cuts: int = 0
	var repending: int = 0
	var ticks: int = 0
	while p.stun_timer > 0.0 and ticks < 1000:
		if _tick(p, _danger()):
			extra_cuts += 1
		if p.is_cut_pending():
			repending += 1
		ticks += 1
	_ok(extra_cuts == 0, "no duplicate cut during stun (%d)" % extra_cuts)
	_ok(repending == 0, "no re-pending during stun (%d)" % repending)
	# 스턴 감소는 기존 규칙(delta 누적) 그대로라 부동소수 잔여로 1틱 길어질 수 있다(기존 동작).
	_ok(
		absi(ticks - roundi(Tuning.stun_duration / DT)) <= 1,
		"stun lasts about stun_duration (%d ticks)" % ticks
	)
	p.queue_free()
	_done.append("pending_sequence")


## 3) 스턴 종료 뒤 다시 위험을 올리면 새 pending → 12틱 → 부상. 2~5번째 부상도 같은 순서.
func _check_repeat_cuts() -> void:
	var p: PlayerController = _new_player()
	var total_cuts: int = 0
	for k in range(1, 6):
		var tag: String = "cut #%d" % k
		if not _ramp_to_pending(p, tag):
			break
		_ok(p.risk == 1.0 and p.stun_timer == 0.0, "%s: pending start state" % tag)
		var n: int = _run_windup(p, tag, _danger())
		_ok(n == _windup_ticks, "%s: windup %d ticks (got %d)" % [tag, _windup_ticks, n])
		if n > 0:
			total_cuts += 1
		_expect_cut_state(p, tag)
		# 다음 틱: 스턴 게이트로 재-pending·중복 없음.
		var again: bool = _tick(p, _danger())
		_ok(not again and not p.is_cut_pending(), "%s: next tick no cut/pending" % tag)
		var dup: int = 0
		while p.stun_timer > 0.0:
			if _tick(p, _danger()):
				dup += 1
			if p.is_cut_pending():
				dup += 1
		_ok(dup == 0, "%s: stun window clean (%d)" % [tag, dup])
	_ok(total_cuts == 5, "five sequential cuts (got %d)" % total_cuts)
	p.queue_free()
	_done.append("repeat_cuts")


## 4) 골무: pending 중 획득 → 해제·부상 없음(만료 직후 포함). 활성 중 pending 시작 없음.
func _check_thimble() -> void:
	# (a) pending 중 획득 후 위험 회복 입력: 골무 창 + 만료 뒤 1초 동안 부상·pending 없음.
	var p: PlayerController = _new_player()
	if _ramp_to_pending(p, "thimble a"):
		for i in range(4):
			_ok(not _tick(p, _danger()), "thimble a: pending tick %d no cut" % i)
		p.grant_thimble()
		_ok(not p.is_cut_pending(), "thimble a: pending cleared on grant")
		_ok(p.cut_pending_timer == 0.0, "thimble a: timer 0 on grant")
		_ok(p.risk <= PlayerController.THIMBLE_RISK_CAP, "thimble a: risk capped %.3f" % p.risk)
		_ok(not p.consume_just_cut(), "thimble a: no cut flag on grant")
		var cuts: int = 0
		var pend: int = 0
		var total: int = roundi((Tuning.thimble_duration + 1.0) / DT)
		for i in range(total):
			if _tick(p, _idle()):
				cuts += 1
			if p.is_cut_pending():
				pend += 1
		_ok(p.thimble_timer == 0.0, "thimble a: thimble expired")
		_ok(cuts == 0, "thimble a: no delayed cut through expiry (%d)" % cuts)
		_ok(pend == 0, "thimble a: no pending through expiry (%d)" % pend)
		_ok(p.stun_timer == 0.0, "thimble a: never stunned")
	p.queue_free()
	# (b) pending 중 획득 후 위험 입력 유지: 골무 활성 중에는 pending 없음·risk<=0.95,
	#     만료 뒤에는 risk 가 다시 1.0 에 닿아야 새 pending(진행률 0부터)이 시작되고 12틱 뒤 부상.
	p = _new_player()
	if _ramp_to_pending(p, "thimble b"):
		_tick(p, _danger())
		p.grant_thimble()
		_ok(not p.is_cut_pending(), "thimble b: pending cleared on grant")
		var bad: int = 0
		var max_risk: float = 0.0
		while p.thimble_timer > 0.0:
			if _tick(p, _danger()):
				bad += 1
			if p.is_cut_pending():
				bad += 1
			# 만료 틱(simulate 첫머리에서 0이 됨)에는 상한이 이미 풀리므로 활성 틱만 잰다.
			if p.thimble_timer > 0.0:
				max_risk = maxf(max_risk, p.risk)
		_ok(bad == 0, "thimble b: no pending/cut while thimble active (%d)" % bad)
		_ok(max_risk <= 0.95, "thimble b: risk <= 0.95 while active (%.3f)" % max_risk)
		# 만료 틱에는 risk 가 0.95 였으므로 새로 1.0 에 도달하는 틱에서만 pending 이 시작된다.
		var start: int = -1
		var early: bool = false
		for i in range(MAX_RAMP_TICKS):
			var before: float = p.risk
			if _tick(p, _danger()):
				early = true
			if p.is_cut_pending():
				start = i
				_ok(before < 1.0, "thimble b: new pending from fresh reach (%.3f)" % before)
				break
		_ok(start >= 0 and not early, "thimble b: fresh pending after expiry (tick %d)" % start)
		_ok(p.cut_pending_progress() == 0.0, "thimble b: new pending progress starts at 0")
		var n: int = _run_windup(p, "thimble b", _danger())
		_ok(n == _windup_ticks, "thimble b: new windup %d ticks (got %d)" % [_windup_ticks, n])
	p.queue_free()
	# (c) 골무를 먼저 켠 뒤 위험 입력: 창 동안 pending 없음.
	p = _new_player()
	p.grant_thimble()
	p.simulate(InputFrame.new(0.0, 4, false, false), DT)
	var pend_c: int = 0
	var cuts_c: int = 0
	while p.thimble_timer > 0.0:
		if _tick(p, _danger()):
			cuts_c += 1
		if p.is_cut_pending():
			pend_c += 1
	_ok(
		pend_c == 0 and cuts_c == 0,
		"thimble c: active thimble blocks pending (%d/%d)" % [pend_c, cuts_c]
	)
	p.queue_free()
	_done.append("thimble")


## 5) 엄마 찬스: pending 중 획득 → 해제·부상 없음, 오토파일럿 경로에서 타이머가 멈춘 채 남지 않음.
func _check_autopilot() -> void:
	var p: PlayerController = _new_player()
	if _ramp_to_pending(p, "autopilot"):
		_tick(p, _danger())
		p.grant_autopilot()
		_ok(not p.is_cut_pending(), "autopilot: pending cleared on grant")
		_ok(p.cut_pending_timer == 0.0, "autopilot: timer 0 on grant")
		var stuck: int = 0
		var cuts: int = 0
		var prev_risk: float = p.risk
		var recovering: bool = true
		while p.autopilot_timer > 0.0:
			p.autopilot_target_pos = p.position + Vector2(5.0, 0.0)
			p.autopilot_target_heading = 0.0
			if _tick(p, _danger()):
				cuts += 1
			if p.cut_pending_timer != 0.0:
				stuck += 1
			if p.risk > prev_risk:
				recovering = false
			prev_risk = p.risk
		_ok(stuck == 0, "autopilot: pending never set during autopilot (%d)" % stuck)
		_ok(cuts == 0, "autopilot: no cut during autopilot (%d)" % cuts)
		_ok(recovering, "autopilot: risk only recovers")
		_ok(p.risk < 1.0, "autopilot: risk below 1.0 at handoff (%.3f)" % p.risk)
		# 복귀 직후 위험 회복 입력: 뒤늦은 부상 없음.
		var late: int = 0
		for i in range(60):
			if _tick(p, _idle()):
				late += 1
			if p.is_cut_pending():
				late += 1
		_ok(late == 0, "autopilot: no delayed cut after handoff (%d)" % late)
	p.queue_free()
	_done.append("autopilot")


## 6) 이탈 리셋·reset_state: pending 해제, 부상 없음.
func _check_reset_paths() -> void:
	var p: PlayerController = _new_player()
	if _ramp_to_pending(p, "off-fabric"):
		for i in range(5):
			_tick(p, _danger())
		p.off_fabric_reset(Vector2(10.0, 20.0), 0.5)
		_ok(not p.is_cut_pending(), "off-fabric: pending cleared")
		_ok(p.cut_pending_timer == 0.0, "off-fabric: timer 0")
		_ok(p.risk == 0.0, "off-fabric: risk 0")
		_ok(not p.consume_just_cut(), "off-fabric: _just_cut false")
		_ok(p.stun_timer == 0.0, "off-fabric: no stun")
		_ok(p.offfabric_timer == Tuning.reset_lockout, "off-fabric: lockout set")
		var late: int = 0
		for i in range(_windup_ticks * 3):
			if _tick(p, _danger()):
				late += 1
		_ok(late == 0, "off-fabric: no cut after reset (%d)" % late)
	p.queue_free()
	p = _new_player()
	if _ramp_to_pending(p, "reset_state"):
		_tick(p, _danger())
		p.reset_state(Vector2(1.0, 2.0), 0.25)
		_ok(p.cut_pending_timer == 0.0 and not p.is_cut_pending(), "reset_state: pending cleared")
		_ok(p.cut_pending_progress() == 0.0, "reset_state: progress 0")
		_ok(p.risk == 0.0 and p.stun_timer == 0.0, "reset_state: risk/stun 0")
		_ok(p.speed_index == 1 and p.thimble_timer == 0.0, "reset_state: speed 1, no thimble")
		_ok(p.autopilot_timer == 0.0 and p.offfabric_timer == 0.0, "reset_state: timers 0")
		_ok(not p.consume_just_cut(), "reset_state: _just_cut false")
		var late: int = 0
		for i in range(_windup_ticks * 3):
			if _tick(p, _idle()):
				late += 1
		_ok(late == 0, "reset_state: no cut after reset (%d)" % late)
	p.queue_free()
	_done.append("reset_paths")


## 두 플레이어의 운동학 상태가 같은지.
func _same_kinematics(a: PlayerController, b: PlayerController) -> bool:
	return (
		a.position == b.position
		and a.heading == b.heading
		and a.target_steer == b.target_steer
		and a.actual_steer == b.actual_steer
		and a.speed_index == b.speed_index
		and a.speed == b.speed
		and a.is_drifting == b.is_drifting
		and a.drift_dir == b.drift_dir
	)


func _copy_kinematics(src: PlayerController, dst: PlayerController) -> void:
	dst.position = src.position
	dst.heading = src.heading
	dst.target_steer = src.target_steer
	dst.actual_steer = src.actual_steer
	dst.speed_index = src.speed_index
	dst.speed = src.speed
	dst.is_drifting = src.is_drifting
	dst.drift_dir = src.drift_dir


## 7) pending 중 입력(조향·속도·드리프트)이 기존 규칙대로 반영된다: 부상이 봉인된 기준 플레이어
##    (골무로 risk 경로만 다름)와 매 틱 운동학 상태가 같아야 한다.
func _check_inputs_during_pending() -> void:
	var p: PlayerController = _new_player()
	var ref: PlayerController = _new_player()
	if _ramp_to_pending(p, "inputs"):
		_copy_kinematics(p, ref)
		ref.thimble_timer = 1000.0
		var seq: Array[InputFrame] = [
			InputFrame.new(-1.0, 0, false, false),
			InputFrame.new(-1.0, -1, false, false),
			InputFrame.new(-1.0, 0, false, true),
			InputFrame.new(0.0, 0, false, true),
			InputFrame.new(1.0, 1, false, false),
			InputFrame.new(1.0, 0, false, true),
			InputFrame.new(0.0, -1, false, false),
			InputFrame.new(-1.0, 0, false, true),
			InputFrame.new(0.0, 0, false, false),
			InputFrame.new(1.0, 0, false, false),
			InputFrame.new(1.0, -1, false, true),
		]
		var first_diff: int = -1
		var changed_speed: bool = false
		var saw_drift: bool = false
		var saw_no_drift: bool = false
		for i in range(seq.size()):
			var cut: bool = _tick(p, seq[i])
			ref.simulate(seq[i], DT)
			ref.consume_just_cut()
			_ok(not cut and p.is_cut_pending(), "inputs: tick %d still pending" % i)
			_ok(p.risk == 1.0, "inputs: tick %d risk stays 1.0 (recover input)" % i)
			if first_diff < 0 and not _same_kinematics(p, ref):
				first_diff = i
			if p.speed_index != 5:
				changed_speed = true
			saw_drift = saw_drift or p.is_drifting
			saw_no_drift = saw_no_drift or not p.is_drifting
		_ok(
			first_diff < 0,
			"inputs: kinematics match reference every tick (diff at %d)" % first_diff
		)
		_ok(changed_speed, "inputs: speed change applied during pending")
		_ok(saw_drift and saw_no_drift, "inputs: drift toggles during pending")
		# 12번째 틱(시작 기준)에 부상. 속도 하락 입력이 있었어도 부상은 1단으로 내린다.
		var cut_last: bool = _tick(p, _idle())
		_ok(cut_last, "inputs: cut fires on tick %d despite recovery input" % _windup_ticks)
		_expect_cut_state(p, "inputs")
	p.queue_free()
	ref.queue_free()
	_done.append("inputs_during_pending")


## 8) windup 0 이하 튜닝: 예전처럼 도달 틱에 즉시 부상(하위 호환).
func _check_zero_windup() -> void:
	var saved: float = Tuning.cut_windup_duration
	Tuning.cut_windup_duration = 0.0
	var p: PlayerController = _new_player()
	p.simulate(InputFrame.new(0.0, 4, false, false), DT)
	var cut_tick: int = -1
	var pend: int = 0
	for i in range(MAX_RAMP_TICKS):
		if _tick(p, _danger()):
			cut_tick = i
			break
		if p.is_cut_pending():
			pend += 1
	_ok(cut_tick >= 0 and pend == 0, "zero windup: immediate cut, no pending (%d)" % cut_tick)
	_expect_cut_state(p, "zero windup")
	Tuning.cut_windup_duration = saved
	p.queue_free()
	_done.append("zero_windup")


## 결정론 검사용 입력 시퀀스(틱 인덱스의 순수 함수).
func _scripted_input(i: int) -> InputFrame:
	var phase: int = i % 360
	var sd: int = 4 if phase == 0 else 0
	var steer: float = 1.0 if int(i / 45.0) % 2 == 0 else -1.0
	if phase > 330:
		steer = 0.0
	return InputFrame.new(steer, sd, false, phase > 120)


func _run_scripted(ticks: int) -> Array:
	var p: PlayerController = _new_player()
	var rows: Array = []
	for i in range(ticks):
		var cut: bool = _tick(p, _scripted_input(i))
		var row: Array = [
			p.position,
			p.heading,
			p.risk,
			p.stun_timer,
			p.cut_pending_timer,
			p.speed_index,
			p.target_steer,
			p.actual_steer,
			cut,
		]
		rows.append(row)
	p.queue_free()
	return rows


## 9) 같은 입력 시퀀스를 두 번 돌리면 매 틱 상태가 같다(부상 여러 번 포함).
func _check_determinism() -> void:
	var a: Array = _run_scripted(2400)
	var b: Array = _run_scripted(2400)
	var first_diff: int = -1
	var starts: Array[int] = []
	var cut_ticks: Array[int] = []
	var prev_pending: bool = false
	for i in range(a.size()):
		if first_diff < 0 and a[i] != b[i]:
			first_diff = i
		var pending: bool = float(a[i][4]) > 0.0
		if pending and not prev_pending:
			starts.append(i)
		if bool(a[i][8]):
			cut_ticks.append(i)
		prev_pending = pending
	_ok(
		a.size() == b.size() and first_diff < 0,
		"determinism: identical per-tick state (first diff %d)" % first_diff
	)
	_ok(cut_ticks.size() >= 2, "determinism: run includes multiple cuts (%d)" % cut_ticks.size())
	# 끝에 아직 부상 전인 pending 하나는 허용한다(시퀀스가 windup 도중에 끝난 경우).
	var paired: bool = (
		starts.size() == cut_ticks.size()
		or (starts.size() == cut_ticks.size() + 1 and starts[-1] > a.size() - 1 - _windup_ticks)
	)
	_ok(paired, "determinism: every pending start pairs with one cut (%s/%s)" % [starts, cut_ticks])
	for k in range(mini(starts.size(), cut_ticks.size())):
		_ok(
			cut_ticks[k] - starts[k] == _windup_ticks,
			"determinism: cut %d after %d ticks" % [k + 1, cut_ticks[k] - starts[k]]
		)
	_done.append("determinism")


## Gameplay 씬을 붙이고 RUNNING 상태로 둔다. 물리 처리는 검사가 _physics_process 를 직접 부른다.
func _spawn_gameplay() -> Node:
	var gp: Node = GameplayScene.instantiate()
	get_tree().root.add_child.call_deferred(gp)
	await get_tree().process_frame
	await get_tree().process_frame
	gp.set_physics_process(false)
	gp._state = gp.State.RUNNING
	return gp


func _release_inputs() -> void:
	Input.action_release("steer_right")
	Input.action_release("steer_left")
	Input.action_release("drift")


## 10) RaceDirector 경로 집계: 렌더 1회당 물리 4틱(저 FPS 모사)으로 구동하며 pending 시작 틱에는
##     cuts 불변, 부상 틱에만 정확히 +1. 일시정지 중에는 pending 이 진행하지 않는다.
func _check_director_counts() -> void:
	var gp: Node = await _spawn_gameplay()
	var player: PlayerController = gp._player
	var stats: RunStats = gp._stats
	_ok(player.cut_pending_timer == 0.0, "director: fresh scene has no pending (restart path)")
	Input.action_press("steer_right")
	Input.action_press("drift")
	var cut_ticks: Array[int] = []
	var start_ticks: Array[int] = []
	var bad_count: int = 0
	var paused_checked: bool = false
	var tick: int = 0
	while cut_ticks.size() < 3 and tick < 6000:
		for _k in range(4):
			if player.stun_timer <= 0.0 and player.speed_index < 5:
				gp._buf_speed_delta = 5 - player.speed_index
			var cuts_before: int = stats.cuts
			var was_pending: bool = player.is_cut_pending()
			var was_stun: bool = player.stun_timer > 0.0
			gp._physics_process(DT)
			if player.is_cut_pending() and not was_pending:
				start_ticks.append(tick)
				if stats.cuts != cuts_before:
					bad_count += 1
			var stun_edge: bool = player.stun_timer > 0.0 and not was_stun
			if stun_edge:
				cut_ticks.append(tick)
				if stats.cuts != cuts_before + 1:
					bad_count += 1
			elif stats.cuts != cuts_before:
				bad_count += 1
			tick += 1
			# 첫 pending 도중 일시정지: 물리 틱을 불러도 타이머가 멈춰 있어야 한다.
			if not paused_checked and player.is_cut_pending() and start_ticks.size() == 1:
				paused_checked = true
				var t0: float = player.cut_pending_timer
				get_tree().paused = true
				for _j in range(20):
					gp._physics_process(DT)
				_ok(player.cut_pending_timer == t0, "director: pending frozen while paused")
				get_tree().paused = false
		await get_tree().process_frame
	_release_inputs()
	_ok(cut_ticks.size() == 3, "director: three cuts observed (%d)" % cut_ticks.size())
	_ok(start_ticks.size() == 3, "director: three pending starts (%d)" % start_ticks.size())
	_ok(
		bad_count == 0,
		"director: cuts +1 only on cut ticks, none on pending start (%d)" % bad_count
	)
	_ok(stats.cuts == cut_ticks.size(), "director: stats.cuts == observed cuts (%d)" % stats.cuts)
	_ok(stats.resets == 0, "director: scenario had no off-fabric reset (%d)" % stats.resets)
	for i in range(mini(cut_ticks.size(), start_ticks.size())):
		_ok(
			cut_ticks[i] - start_ticks[i] == _windup_ticks,
			"director: cut %d windup %d ticks" % [i + 1, cut_ticks[i] - start_ticks[i]]
		)
	_ok(paused_checked, "director: pause check ran")
	gp.queue_free()
	await get_tree().process_frame
	_done.append("director_counts")


## 11) 이탈 리셋 분기: (a) pending 중 리셋 → 부상 없음, (b) 부상과 리셋이 같은 틱 → 그 틱에 정확히
##     1회 집계(다음 틱으로 밀리거나 중복되지 않음).
func _check_director_offfabric() -> void:
	var gp: Node = await _spawn_gameplay()
	var player: PlayerController = gp._player
	var stats: RunStats = gp._stats
	var far: Vector2 = Vector2(1.0e5, 1.0e5)
	# (a) pending 중 리셋.
	player.risk = 1.0
	player.cut_pending_timer = 0.1
	player.position = far
	gp._offfabric_dwell = gp.RESET_DWELL
	gp._physics_process(DT)
	_ok(stats.resets == 1, "director off-fabric a: reset happened (%d)" % stats.resets)
	_ok(not player.is_cut_pending(), "director off-fabric a: pending cleared")
	_ok(stats.cuts == 0 and player.stun_timer == 0.0, "director off-fabric a: no cut")
	for i in range(_windup_ticks * 2):
		gp._physics_process(DT)
	_ok(stats.cuts == 0, "director off-fabric a: no delayed cut (%d)" % stats.cuts)
	# (b) 부상 실행 틱 == 리셋 틱.
	player.offfabric_timer = 0.0
	player.risk = 1.0
	player.cut_pending_timer = DT * 0.5
	player.position = far
	gp._offfabric_dwell = gp.RESET_DWELL
	gp._physics_process(DT)
	_ok(stats.resets == 2, "director off-fabric b: reset happened (%d)" % stats.resets)
	_ok(player.stun_timer == Tuning.stun_duration, "director off-fabric b: cut executed")
	_ok(stats.cuts == 1, "director off-fabric b: cut counted on the same tick (%d)" % stats.cuts)
	_ok(not player.consume_just_cut(), "director off-fabric b: no leftover cut flag")
	gp._physics_process(DT)
	_ok(stats.cuts == 1, "director off-fabric b: not re-counted next tick (%d)" % stats.cuts)
	gp.queue_free()
	await get_tree().process_frame
	_done.append("director_offfabric")


## 12) 완주: (a) pending 중 완주 → 부상을 즉시 확정해 정확히 1회 집계(패널티·등급 반영, pending 해제),
##     (b) 부상 틱 == 완주 틱 → 그 부상 1회만 집계(이중 집계 없음), (c) 물리 틱 경로에서 pending 중
##     완주 → 결과에 부상 1회. 완주 뒤 FINISH_VIEW 틱에서는 상태가 더 바뀌지 않는다.
func _check_director_finish() -> void:
	# (a) _finish 직접 호출(pending 남은 채 완주 확정).
	var gp: Node = await _spawn_gameplay()
	var player: PlayerController = gp._player
	var stats: RunStats = gp._stats
	player.risk = 1.0
	player.speed_index = 5
	player.speed = Tuning.speed_table[4]
	player.cut_pending_timer = 0.1
	gp._finish()
	var res: Dictionary = gp._pending_result
	_ok(gp._state == gp.State.FINISH_VIEW, "director finish a: FINISH_VIEW")
	_ok(not player.is_cut_pending(), "director finish a: pending resolved on finish")
	_ok(player.cut_pending_progress() == 0.0, "director finish a: progress 0 after finish")
	_ok(player.stun_timer == Tuning.stun_duration, "director finish a: cut executed on finish")
	_ok(player.speed_index == 1 and player.risk == 0.0, "director finish a: cut penalty state")
	_ok(not player.consume_just_cut(), "director finish a: cut flag consumed by director")
	_ok(stats.cuts == 1, "director finish a: stats.cuts == 1 (%d)" % stats.cuts)
	_ok(int(res.get("cuts", -1)) == 1, "director finish a: result cuts == 1 (%s)" % res.get("cuts"))
	var pen_ms: int = int(RunStats.CUT_PENALTY * 1000.0)
	_ok(
		int(res.get("penalty_ms", -1)) == pen_ms,
		"director finish a: penalty_ms == %d (%s)" % [pen_ms, res.get("penalty_ms")]
	)
	_ok(
		int(res.get("final_time_ms", -1)) == int(res.get("finish_ms", 0)) + pen_ms,
		"director finish a: final_time includes cut penalty"
	)
	var expect_grade: String = RunStats.grade_from_metrics(
		float(res.get("accuracy", 0.0)), float(res.get("perfect_rate", 0.0)), 1
	)
	_ok(str(res.get("grade", "")) == expect_grade, "director finish a: grade counts the cut")
	# FINISH_VIEW 틱(유예 이내)을 더 돌려도 집계·상태가 바뀌지 않는다.
	for i in range(10):
		gp._physics_process(DT)
	_ok(stats.cuts == 1 and not player.is_cut_pending(), "director finish a: stable after finish")
	_ok(player.stun_timer == Tuning.stun_duration, "director finish a: sim frozen after finish")
	gp.queue_free()
	await get_tree().process_frame
	# (b) 부상 실행 틱 == 완주 틱.
	gp = await _spawn_gameplay()
	player = gp._player
	stats = gp._stats
	_place_at_finish(gp, player)
	player.risk = 1.0
	player.cut_pending_timer = DT * 0.5
	gp._physics_process(DT)
	_ok(gp._state == gp.State.FINISH_VIEW, "director finish b: finished on this tick")
	_ok(player.stun_timer == Tuning.stun_duration, "director finish b: cut executed on finish tick")
	_ok(stats.cuts == 1, "director finish b: counted once (%d)" % stats.cuts)
	_ok(
		int(gp._pending_result.get("cuts", -1)) == 1,
		"director finish b: result counts the cut once (%s)" % gp._pending_result.get("cuts", -1)
	)
	gp.queue_free()
	await get_tree().process_frame
	# (c) 물리 틱 경로: pending 이 남은 채 완주 틱을 맞는다.
	gp = await _spawn_gameplay()
	player = gp._player
	stats = gp._stats
	_place_at_finish(gp, player)
	player.risk = 1.0
	player.cut_pending_timer = 0.1
	gp._physics_process(DT)
	_ok(gp._state == gp.State.FINISH_VIEW, "director finish c: finished on this tick")
	_ok(not player.is_cut_pending(), "director finish c: pending resolved")
	_ok(player.stun_timer == Tuning.stun_duration, "director finish c: cut executed")
	_ok(stats.cuts == 1, "director finish c: counted once (%d)" % stats.cuts)
	_ok(
		int(gp._pending_result.get("cuts", -1)) == 1,
		"director finish c: result counts the cut (%s)" % gp._pending_result.get("cuts", -1)
	)
	gp.queue_free()
	await get_tree().process_frame
	_done.append("director_finish")


## 플레이어를 트랙 끝점에 놓아 다음 물리 틱에 완주하게 한다.
func _place_at_finish(gp: Node, player: PlayerController) -> void:
	var track: TrackData = gp._track
	var n: int = track.points.size()
	player.position = track.points[n - 1]
	player.heading = (track.points[n - 1] - track.points[n - 2]).angle()
	gp._hint = n - 2
