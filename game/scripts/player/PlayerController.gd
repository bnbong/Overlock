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
	_just_cut = false
	if _needle_visual != null:
		_needle_visual.rotation = heading


## RaceDirector가 매 물리 틱에 호출하는 시뮬레이션 진입점.
func simulate(input: InputFrame, delta: float) -> void:
	_apply_speed_change(input.speed_delta)
	_update_steering(input, delta)
	_update_movement(delta)
	_update_risk(delta)


## RaceDirector가 이번 틱의 부상 발생 여부를 소비한다(집계용).
func consume_just_cut() -> bool:
	var value: bool = _just_cut
	_just_cut = false
	return value


func _apply_speed_change(delta_step: int) -> void:
	# 부상(스턴) 중에는 조작 잠금(기획서 §7.5): 속도 증감 입력을 무시한다.
	# 강제 1단 하락은 _trigger_cut()이 별도로 수행한다.
	if delta_step == 0 or stun_timer > 0.0:
		return
	speed_index = clampi(speed_index + delta_step, 1, Tuning.speed_step_count)
	speed = Tuning.speed_table[speed_index - 1]


func _update_steering(input: InputFrame, delta: float) -> void:
	if stun_timer > 0.0:
		stun_timer -= delta
		if stun_timer < 0.0:
			stun_timer = 0.0
		# 부상 중 조작 잠금: 입력 무시하고 조향을 0으로 복귀.
		target_steer = move_toward(target_steer, 0.0, Tuning.stun_steer_return_rate * delta)
	elif input.steer < 0.0:
		target_steer -= Tuning.steer_charge_rate * delta
	elif input.steer > 0.0:
		target_steer += Tuning.steer_charge_rate * delta
	else:
		target_steer = move_toward(target_steer, 0.0, Tuning.steer_return_rate * delta)
	target_steer = clampf(target_steer, -1.0, 1.0)
	# 지연 추종: actual이 target을 느리게 따라감(charge_rate > foot_response_rate).
	actual_steer = move_toward(actual_steer, target_steer, Tuning.foot_response_rate * delta)


func _update_movement(delta: float) -> void:
	# 조향 회전율(각속도)은 저속에서도 유지되도록 speed_factor에 하한(steer_speed_floor)을 둔다.
	# floor=1.0이면 회전각속도가 속도와 무관 → 회전반경 ∝ 속도(저속=급회전, 고속=완만한 큰 호).
	# 이는 저속에서도 코너를 못 도는 구(舊) "전 속도 동일 최소반경(≈136px)" 문제를 해소한다.
	# 조향 지연(charge_rate > foot_response_rate)이라는 핵심 기믹(§4.3)은 그대로 살아 있다.
	var turn_speed_factor: float = maxf(speed / Tuning.max_speed, Tuning.steer_speed_floor)
	heading += actual_steer * Tuning.turn_power * turn_speed_factor * delta
	var forward: Vector2 = Vector2(cos(heading), sin(heading))
	position += forward * speed * delta
	if _needle_visual != null:
		_needle_visual.rotation = heading  # 시각만 회전(노드 본체는 0 유지)


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
	var gain: float = speed_gate * steer_mag * proximity * (steer_gap + Tuning.risk_static_bias)
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


func _finger_proximity(steer_mag: float) -> float:
	# 조향 편향(steer_mag)이 클수록 손이 바늘에 가까워진다 — 연출의 손↔바늘 접근 기믹과 서사 일치.
	# 확장 시 실제 손 위치 모델로 교체하는 지점.
	return Tuning.risk_proximity_base + (1.0 - Tuning.risk_proximity_base) * steer_mag
