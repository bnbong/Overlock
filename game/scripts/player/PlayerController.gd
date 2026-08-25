class_name PlayerController
extends Node2D
## 노루발(플레이어) 운동학 상태와 시뮬레이션 (기획서 §7, 아키텍처 §6).
##
## 자체 _physics_process를 두지 않는다. RaceDirector가 매 물리 틱마다
## simulate(input, delta)를 정해진 순서로 호출한다. 노드 본체의 rotation은
## 항상 0으로 두고 heading은 자식 NeedleVisual에만 반영한다(카메라 회전 방지).

var heading: float = 0.0
var speed: float = 80.0
var speed_index: int = 1  # 1..5
var target_steer: float = 0.0
var actual_steer: float = 0.0
var risk: float = 0.0
var stun_timer: float = 0.0
# 맵 이탈 소프트 리셋 후 조작 잠금 타이머(초). >0이면 스턴과 동일하게 조작을 잠근다
# (RaceDirector가 off_fabric_reset로 세팅). 부상(cut)과 별개라 _just_cut은 건드리지 않는다.
var offfabric_timer: float = 0.0

# 피벗 드리프트 상태(v1.0.1). is_drifting은 이번 틱에 드리프트가 실제로 걸렸는지(입력 눌림 +
# 스턴/이탈 잠금 아님), drift_dir은 그때의 조향 방향(actual_steer, 아니면 0.0)이다. 표현·리플레이
# 계층이 소비하는 읽기 전용 계약 — 시뮬은 이 두 값을 매 틱 simulate()에서 확정한다.
var is_drifting: bool = false
var drift_dir: float = 0.0

var _just_cut: bool = false

@onready var _needle_visual: Polygon2D = $NeedleVisual


func reset_state(start_pos: Vector2, start_heading: float) -> void:
	position = start_pos
	heading = start_heading
	speed_index = 1
	speed = Tuning.speed_table[0]
	target_steer = 0.0
	actual_steer = 0.0
	risk = 0.0
	stun_timer = 0.0
	offfabric_timer = 0.0
	is_drifting = false
	drift_dir = 0.0
	_just_cut = false
	if _needle_visual != null:
		_needle_visual.rotation = heading


## RaceDirector가 매 물리 틱에 호출하는 시뮬레이션 진입점.
func simulate(input: InputFrame, delta: float) -> void:
	# 드리프트 판정은 스턴/이탈 타이머가 이번 틱에 감소하기 전 값으로 확정한다(_update_steering이
	# 두 타이머를 깎으므로 반드시 최상단에서). 눌림 + 잠금 아님일 때만 드리프트가 걸린다.
	is_drifting = input.drift and stun_timer <= 0.0 and offfabric_timer <= 0.0
	_apply_speed_change(input.speed_delta)
	_update_steering(input, delta)
	_update_movement(delta)
	_update_risk(delta)
	# 이번 틱 드리프트 방향(표현·리플레이 소비용). 드리프트가 아니면 0.0.
	drift_dir = actual_steer if is_drifting else 0.0


## RaceDirector가 이번 틱의 부상 발생 여부를 소비한다(집계용).
func consume_just_cut() -> bool:
	var value: bool = _just_cut
	_just_cut = false
	return value


func _apply_speed_change(delta_step: int) -> void:
	# 부상(스턴)·맵 이탈 리셋 잠금 중에는 조작 잠금(기획서 §7.5): 속도 증감 입력을 무시한다.
	# 강제 1단 하락은 _trigger_cut()/off_fabric_reset()이 별도로 수행한다.
	if delta_step == 0 or stun_timer > 0.0 or offfabric_timer > 0.0:
		return
	speed_index = clampi(speed_index + delta_step, 1, Tuning.speed_step_count)
	speed = Tuning.speed_table[speed_index - 1]


func _update_steering(input: InputFrame, delta: float) -> void:
	if stun_timer > 0.0 or offfabric_timer > 0.0:
		# 부상(스턴)·맵 이탈 리셋 잠금: 두 타이머를 각각 감소시키고, 입력을 무시한 채
		# 조향을 0으로 복귀한다(두 게이트는 별개 원인이라 독립적으로 감소).
		if stun_timer > 0.0:
			stun_timer -= delta
			if stun_timer < 0.0:
				stun_timer = 0.0
		if offfabric_timer > 0.0:
			offfabric_timer -= delta
			if offfabric_timer < 0.0:
				offfabric_timer = 0.0
		target_steer = move_toward(target_steer, 0.0, Tuning.stun_steer_return_rate * delta)
	elif input.steer != 0.0:
		# 반전 부스트(§4.3 "누적" 유지 + 반전만 민첩): 입력 부호가 현재 target 부호와
		# 반대일 때만 충전을 가속해, 잠긴 방향을 빠르게 풀고 새 방향은 평소 속도로 쌓는다.
		var rate: float = Tuning.steer_charge_rate
		if input.steer * target_steer < 0.0:
			rate *= Tuning.steer_reversal_boost
		target_steer += signf(input.steer) * rate * delta
	else:
		target_steer = move_toward(target_steer, 0.0, Tuning.steer_return_rate * delta)
	target_steer = clampf(target_steer, -1.0, 1.0)
	# 지연 추종: 지수 평활(갭 비례 속도)로 actual이 target을 부드럽게 따라간다.
	# steer_tau가 랙의 질감(≈시간지연)을 정한다. move_toward(선형 고정 속도) 대비
	# 반전 같은 큰 갭에서 즉시 빠르게 움직이고 목표 근처에서 부드럽게 수렴한다(§4.3 지연 유지).
	# 60Hz 고정 스텝에서 follow_alpha는 상수라 결정론 불변.
	var follow_alpha: float = 1.0 - exp(-delta / Tuning.steer_tau)
	actual_steer += (target_steer - actual_steer) * follow_alpha


func _update_movement(delta: float) -> void:
	# 조향 회전율(각속도)은 저속에서도 유지되도록 speed_factor에 하한(steer_speed_floor)을 둔다.
	# floor=1.0이면 회전각속도가 속도와 무관 → 회전반경 ∝ 속도(저속=급회전, 고속=완만한 큰 호).
	# 이는 저속에서도 코너를 못 도는 구(舊) "전 속도 동일 최소반경(≈136px)" 문제를 해소한다.
	# 조향 지연(steer_tau 지수 추종)이라는 핵심 기믹(§4.3)은 그대로 살아 있다.
	var turn_speed_factor: float = maxf(speed / Tuning.max_speed, Tuning.steer_speed_floor)
	# 드리프트 중에는 조향 각속도에 drift_turn_mult를 곱해 회전반경을 1/배율로 줄인다(피벗 드리프트).
	# 각속도만 스케일하므로 조향 입력/지연(target/actual_steer)과 속도는 불변 — 반경만 작아진다.
	var drift_mult: float = Tuning.drift_turn_mult if is_drifting else 1.0
	# heading 출력에만 expo 완화 곡선을 적용한다(서브맥시멀 조향만 부드럽게). _expo(±1)=±1
	# 항등이라 풀락 회전 기하는 불변이고, target/actual_steer·위험도 입력은 여기서 건드리지 않는다.
	heading += _expo(actual_steer) * Tuning.turn_power * turn_speed_factor * drift_mult * delta
	var forward: Vector2 = Vector2(cos(heading), sin(heading))
	position += forward * speed * delta
	if _needle_visual != null:
		_needle_visual.rotation = heading  # 시각만 회전(노드 본체는 0 유지)


## heading 출력용 국소화 완화 곡선. out = sign(a)*(m - s*m*(1-m)^p),
## m=|a|, s=Tuning.steer_expo, p=Tuning.steer_soft_p. s<=0이면 항등(선형).
## out(±1)=±1 항등(풀락 기하 불변) — 완화 항은 |a|=1에서 0으로 꺼지고 저·중간 |a|에서만 봉긋해져
## 탭만 완화·중간 authority를 회복한다(3차 대비 중간 조향각을 크게 되살림).
func _expo(a: float) -> float:
	var s: float = Tuning.steer_expo
	if s <= 0.0:
		return a
	var m: float = absf(a)
	return signf(a) * (m - s * m * pow(1.0 - m, Tuning.steer_soft_p))


func _update_risk(delta: float) -> void:
	# 기획서 §7.5: 위험도 = 속도 계수 × 조향 입력량 × 조향 지연 × 바늘 근접 계수.
	# 구(舊) 공식은 조향 입력량으로 |target_steer|를 써, 좌↔우 급반전 때 그 값이 0을 지나며
	# gain이 죽었다(→ 최고속 급반전으로도 부상 불가). 아래로 교정한다:
	#  - 조향 입력량 steer_mag = max(|target|,|actual|): 반전 중에도 0으로 죽지 않는다.
	#  - 바늘 근접 proximity = base + (1-base)*steer_mag: 조향이 셀수록 손이 바늘에 접근(동적 승격).
	#  - 조향 지연 (steer_gap + static_bias): 반전은 유지보다 gap 적분이 ~4배 → 자연히 훨씬 위험.
	#    static_bias는 고속 "풀조향 유지"의 상시 위험을 더해 경고 UI(0.5~)가 실제로 뜨게 한다.
	#  - 속도 계수는 pow(_, risk_speed_exp)로 저속을 강하게 억제 → 1~2단은 사실상 무해.
	var steer_gap: float = absf(target_steer - actual_steer)
	var speed_factor: float = inverse_lerp(Tuning.min_speed, Tuning.max_speed, speed)
	var speed_gate: float = pow(speed_factor, Tuning.risk_speed_exp)
	var steer_mag: float = maxf(absf(target_steer), absf(actual_steer))
	var proximity: float = _finger_proximity(steer_mag)
	var bias: float = Tuning.risk_static_bias
	# 드리프트 중에는 손을 바늘에 강제로 눌러(근접 하한) 상시 바이어스를 올린다 — 유지만 해도 위험이
	# 더 빨리 쌓여 오래 무는 드리프트가 부상으로 이어진다. speed_gate·gain_rate·recover·threshold는 불변.
	if is_drifting:
		proximity = maxf(proximity, Tuning.drift_proximity)
		bias = Tuning.drift_static_bias
	var gain: float = speed_gate * steer_mag * proximity * (steer_gap + bias)
	if gain > Tuning.danger_threshold:
		risk += gain * Tuning.risk_gain_rate * delta
	else:
		risk = move_toward(risk, 0.0, Tuning.risk_recover_rate * delta)
	if risk >= 1.0 and stun_timer <= 0.0:
		_trigger_cut()


func _trigger_cut() -> void:
	risk = 0.0
	stun_timer = Tuning.stun_duration  # 조작 잠금
	speed_index = 1  # 1단으로 강제 하락
	speed = Tuning.speed_table[0]
	_just_cut = true  # RaceDirector가 이번 틱에 소비 → cuts += 1


## 맵(원단) 이탈 소프트 리셋: 마지막 정상 지점으로 재배치하고 조작을 잠근다(RaceDirector 호출).
## 부상이 아니므로 _just_cut은 건드리지 않는다(부상 카운트 오발동 금지). 조향/위험도는 0으로
## 초기화하고 1단으로 강등하며, offfabric_timer(=reset_lockout) 동안 입력을 잠근다.
func off_fabric_reset(reset_pos: Vector2, reset_heading: float) -> void:
	position = reset_pos
	heading = reset_heading
	speed_index = 1
	speed = Tuning.speed_table[0]
	target_steer = 0.0
	actual_steer = 0.0
	risk = 0.0
	offfabric_timer = Tuning.reset_lockout
	is_drifting = false
	drift_dir = 0.0
	if _needle_visual != null:
		_needle_visual.rotation = heading  # needle 시각 회전을 새 heading에 동기


func _finger_proximity(steer_mag: float) -> float:
	# 조향 편향(steer_mag)이 클수록 손이 바늘에 가까워진다 — 연출의 손↔바늘 접근 기믹과 서사 일치.
	# 확장 시 실제 손 위치 모델로 교체하는 지점.
	return Tuning.risk_proximity_base + (1.0 - Tuning.risk_proximity_base) * steer_mag
