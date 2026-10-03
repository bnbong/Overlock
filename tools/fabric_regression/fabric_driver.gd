extends RefCounted
## 원단 회귀용 자동 주행 드라이버(사본 프로젝트 전용, check.gd가 preload).
##
## PlayerController를 직접 만들어 RaceDirector와 같은 순서(시뮬 → 트랙 질의 → 이탈 복귀 → 완주)로
## 60Hz 고정 틱을 돌린다. 조향은 디지털 입력(-1/0/1)만 쓴다: 순수 추종(pure pursuit)으로 필요한
## 조향량을 구하고 target_steer가 그 값을 따라가도록 키를 누르거나 뗀다. 기어는 앞 구간 곡률에서
## 필요한 조향량이 GEAR_STEER_LIMIT 이하인 가장 높은 단계를 고르고, RISK가 높으면 한 단계 내린다.
## 사람 플레이를 흉내 낸 스크립트 조향이며 최적 주행이 아니다.

const DT: float = 1.0 / 60.0
# RaceDirector와 같은 이탈 복귀·완주 상수(RaceDirector.RESET_* / FINISH_MARGIN).
const RESET_ABS: float = 300.0
const RESET_FAIL_MULT: float = 3.5
const RESET_DWELL: float = 0.12
const FINISH_MARGIN: float = 1.0
# 기어 선택: 앞 구간 최대 곡률에서 필요한 조향 출력이 이 비율 이하인 단계까지만 올린다.
const GEAR_STEER_LIMIT: float = 0.62
# 이 RISK 이상이면 한 단계 내린다(경고 게이지를 보고 감속하는 플레이).
const RISK_DOWNSHIFT: float = 0.45
# target_steer 추종 데드밴드(키를 떼면 target이 0으로 돌아가므로 이 폭 안에서 떼었다 눌렀다 한다).
const STEER_DEADBAND: float = 0.05


## NeedleVisual 자식을 가진 독립 PlayerController를 host 아래에 만든다. profile이 비어 있지 않으면 적용.
static func make_player(host: Node, profile: Dictionary) -> PlayerController:
	var p: PlayerController = PlayerController.new()
	var nv: Polygon2D = Polygon2D.new()
	nv.name = "NeedleVisual"
	p.add_child(nv)
	host.add_child(p)
	if not profile.is_empty():
		p.set_fabric_profile(profile)
	return p


## 트랙을 처음부터 끝까지 자동 주행한다. 반환: finished, time, resets, cuts, max_err, tear_ticks,
## off_seam_ticks, ticks, gear_ticks(단계별 틱 수 배열), max_risk.
static func drive(host: Node, track: TrackData, profile: Dictionary) -> Dictionary:
	var p: PlayerController = make_player(host, profile)
	p.reset_state(track.points[0], track.start_heading())
	var hint: int = 0
	var last_good: int = 0
	var dwell: float = 0.0
	var t: float = 0.0
	var s: float = 0.0
	var out: Dictionary = {
		"finished": false,
		"time": 0.0,
		"resets": 0,
		"cuts": 0,
		"max_err": 0.0,
		"tear_ticks": 0,
		"off_seam_ticks": 0,
		"ticks": 0,
		"gear_ticks": [0, 0, 0, 0, 0],
		"max_risk": 0.0,
	}
	var limit: float = track.length / p.effective_speed_for_index(1) * 3.0 + 20.0
	var gear: int = 1
	var tick: int = 0
	while t < limit:
		if tick % 3 == 0:
			gear = pick_gear(p, track, s)
		var steer: float = steer_input(p, track, s)
		p.simulate(InputFrame.new(steer, gear - p.speed_index, false, false), DT)
		t += DT
		tick += 1
		if p.consume_just_cut():
			out["cuts"] = int(out["cuts"]) + 1
		out["max_risk"] = maxf(float(out["max_risk"]), p.risk)
		var gi: int = clampi(p.speed_index, 1, 5) - 1
		out["gear_ticks"][gi] = int(out["gear_ticks"][gi]) + 1
		var probe: Dictionary = track.query(p.position, hint)
		hint = int(probe["idx"])
		var err: float = float(probe["error"])
		s = float(probe["s"])
		out["max_err"] = maxf(float(out["max_err"]), err)
		if err > track.fail:
			out["tear_ticks"] = int(out["tear_ticks"]) + 1
		elif err > track.safe:
			out["off_seam_ticks"] = int(out["off_seam_ticks"]) + 1
		if err <= track.safe:
			last_good = hint
		if err > maxf(RESET_ABS, track.fail * RESET_FAIL_MULT):
			dwell += DT
			if dwell >= RESET_DWELL:
				p.off_fabric_reset(track.points[last_good], heading_at(track, last_good))
				hint = last_good
				s = float(track.s_arr[last_good])
				out["resets"] = int(out["resets"]) + 1
				dwell = 0.0
				continue
		else:
			dwell = 0.0
		if s >= track.length - FINISH_MARGIN:
			out["finished"] = true
			break
	out["time"] = t
	out["ticks"] = tick
	p.queue_free()
	return out


## 앞 구간 곡률로 고른 목표 기어(1..5).
static func pick_gear(p: PlayerController, track: TrackData, s: float) -> int:
	var best: int = 1
	for g in range(1, Tuning.speed_step_count + 1):
		var v: float = p.effective_speed_for_index(g)
		var w_max: float = (
			Tuning.turn_power * maxf(v / p.effective_max_speed(), Tuning.steer_speed_floor)
		)
		var kmax: float = max_curvature(track, s - 12.0, s + v * 0.7 + 30.0)
		if kmax * v <= w_max * GEAR_STEER_LIMIT:
			best = g
		else:
			break
	if p.risk >= RISK_DOWNSHIFT:
		best = maxi(1, mini(best, p.speed_index - 1))
	return best


## 순수 추종 조향 입력(-1/0/1).
static func steer_input(p: PlayerController, track: TrackData, s: float) -> float:
	var v: float = p.speed
	var ld: float = clampf(v * 0.22, 16.0, 70.0)
	var to: Vector2 = track.point_at_s(s + ld) - p.position
	var fwd: Vector2 = Vector2(cos(p.heading), sin(p.heading))
	var alpha: float = fwd.angle_to(to)
	var dist: float = maxf(to.length(), 1.0)
	var k: float = 2.0 * sin(alpha) / dist
	var w_max: float = (
		Tuning.turn_power * maxf(v / p.effective_max_speed(), Tuning.steer_speed_floor)
	)
	var a_des: float = clampf(k * v / w_max, -1.0, 1.0)
	var e: float = a_des - p.target_steer
	if e > STEER_DEADBAND:
		return 1.0
	if e < -STEER_DEADBAND:
		return -1.0
	return 0.0


## [s0, s1] 구간의 최대 곡률(rad/px). 6px 간격, 24px 유한차분.
static func max_curvature(track: TrackData, s0: float, s1: float) -> float:
	var k: float = 0.0
	var x: float = maxf(s0, 0.0)
	var end: float = minf(s1, track.length)
	while x <= end:
		k = maxf(k, track.curvature_at_s(x, 24.0))
		x += 6.0
	return k


## 폴리라인 인덱스의 진행 방향(RaceDirector._heading_at과 같은 규칙).
static func heading_at(track: TrackData, idx: int) -> float:
	var n: int = track.points.size()
	if n < 2:
		return 0.0
	var i: int = clampi(idx, 0, n - 2)
	return (track.points[i + 1] - track.points[i]).angle()
