extends RefCounted
## 원단 체감 측정 시나리오(사본 프로젝트 전용, check.gd가 preload).
##
## PlayerController를 트랙 없이 직접 구동해 기어별 풀조향 유지·반전·연속 반전·드리프트·골무 시나리오의
## RISK 누적 시간과 반전 완료 시간을 잰다. 시간은 모두 물리 틱(1/60초) 단위로 센 값이다.
## "부상까지"는 RISK 1.0 도달로 부상 사전 연출(pending)이 시작되는 시점이다(-1이면 제한 시간 안에 없음).

const Driver = preload("res://fabric_regression/fabric_driver.gd")
const DT: float = 1.0 / 60.0
const HOLD_LIMIT: float = 10.0
const FLIP_INTERVAL: float = 0.6
const MAX_FLIPS: int = 30


## 기어 g로 올린 새 플레이어(위험 0, 직진 상태).
static func _player_at(host: Node, profile: Dictionary, g: int) -> PlayerController:
	var p: PlayerController = Driver.make_player(host, profile)
	p.reset_state(Vector2.ZERO, 0.0)
	p.simulate(InputFrame.new(0.0, g - 1, false, false), DT)
	return p


## 풀조향(dir) 유지. 반환: warn(RISK 0.5 도달 초), cut(pending 시작 초), peak.
static func hold(host: Node, profile: Dictionary, g: int, dir: float, drift: bool) -> Dictionary:
	var p: PlayerController = _player_at(host, profile, g)
	var warn: float = -1.0
	var cut: float = -1.0
	var peak: float = 0.0
	var n: int = roundi(HOLD_LIMIT / DT)
	for i in range(n):
		p.simulate(InputFrame.new(dir, 0, false, drift), DT)
		peak = maxf(peak, p.risk)
		var t: float = float(i + 1) * DT
		if warn < 0.0 and p.risk >= 0.5:
			warn = t
		if p.is_cut_pending():
			cut = t
			break
	p.queue_free()
	return {"warn": warn, "cut": cut, "peak": peak}


## 단일 반전: 오른쪽 풀조향을 0.8초 유지한 뒤 왼쪽 풀조향 1.2초. 반환: rev(반전 시작부터
## actual_steer가 -0.9 이하가 될 때까지 초), peak(전체 최대 RISK), cut(반전 뒤 pending 시작 초, 없으면 -1),
## pre(반전 직전 RISK).
static func reversal(host: Node, profile: Dictionary, g: int) -> Dictionary:
	var p: PlayerController = _player_at(host, profile, g)
	var peak: float = 0.0
	var cut: float = -1.0
	for i in range(roundi(0.8 / DT)):
		p.simulate(InputFrame.new(1.0, 0, false, false), DT)
		peak = maxf(peak, p.risk)
		if p.is_cut_pending() and cut < 0.0:
			cut = 0.0
	var pre: float = p.risk
	var rev: float = -1.0
	for i in range(roundi(1.2 / DT)):
		p.simulate(InputFrame.new(-1.0, 0, false, false), DT)
		peak = maxf(peak, p.risk)
		var t: float = float(i + 1) * DT
		if rev < 0.0 and p.actual_steer <= -0.9:
			rev = t
		if cut < 0.0 and p.is_cut_pending():
			cut = t
	p.queue_free()
	return {"rev": rev, "peak": peak, "cut": cut, "pre": pre}


## 연속 반전: FLIP_INTERVAL마다 방향을 바꾼다. 반환: flips(pending까지 반전 횟수, 없으면 -1), peak, time.
static func flips(host: Node, profile: Dictionary, g: int) -> Dictionary:
	var p: PlayerController = _player_at(host, profile, g)
	var per: int = roundi(FLIP_INTERVAL / DT)
	var dir: float = 1.0
	var peak: float = 0.0
	var tick: int = 0
	for f in range(MAX_FLIPS + 1):
		for _i in range(per):
			p.simulate(InputFrame.new(dir, 0, false, false), DT)
			tick += 1
			peak = maxf(peak, p.risk)
			if p.is_cut_pending():
				p.queue_free()
				return {"flips": f, "peak": peak, "time": float(tick) * DT}
		dir = -dir
	p.queue_free()
	return {"flips": -1, "peak": peak, "time": -1.0}


## 골무: 5단 드리프트 풀조향을 유지하면서 시작 틱에 골무를 받는다. 반환: cap_peak(골무 창 안 최대 RISK),
## cut_in(골무 창 안 pending 발생 여부), after(골무 만료 뒤 pending까지 초, 없으면 -1).
static func thimble(host: Node, profile: Dictionary) -> Dictionary:
	var p: PlayerController = _player_at(host, profile, 5)
	p.grant_thimble()
	var cap_peak: float = 0.0
	var cut_in: bool = false
	var after: float = -1.0
	var t_exp: float = -1.0
	for i in range(roundi((Tuning.thimble_duration + HOLD_LIMIT) / DT)):
		p.simulate(InputFrame.new(1.0, 0, false, true), DT)
		# 상한은 이번 틱 simulate의 위험 단계 시점에 골무가 남아 있었는지(감소 후 > 0)로 적용된다.
		var active: bool = p.thimble_timer > 0.0
		var t: float = float(i + 1) * DT
		if active:
			cap_peak = maxf(cap_peak, p.risk)
			if p.is_cut_pending():
				cut_in = true
		elif t_exp < 0.0:
			t_exp = t
		if not active and p.is_cut_pending():
			after = t - t_exp
			break
	p.queue_free()
	return {"cap_peak": cap_peak, "cut_in": cut_in, "after": after}


## 부상·이탈 복귀 뒤 속도와 잠금: 5단 드리프트로 부상시킨 뒤 속도, 이탈 복귀 뒤 속도.
static func cut_and_reset(host: Node, profile: Dictionary) -> Dictionary:
	var p: PlayerController = _player_at(host, profile, 5)
	var cut_speed: float = -1.0
	for _i in range(roundi(HOLD_LIMIT / DT)):
		p.simulate(InputFrame.new(1.0, 0, false, true), DT)
		if p.consume_just_cut():
			cut_speed = p.speed
			break
	var p2: PlayerController = _player_at(host, profile, 4)
	p2.off_fabric_reset(Vector2(5.0, 5.0), 0.5)
	var reset_speed: float = p2.speed
	p.queue_free()
	p2.queue_free()
	return {"cut_speed": cut_speed, "reset_speed": reset_speed}
