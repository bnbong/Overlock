extends Node
## 조작감 튜닝 파라미터 보유 오토로드 (기획서 §19).
##
## §19 값을 타입 지정 멤버 기본값으로 두고, 존재하면
## res://data/tuning.json 으로 스칼라 값을 오버라이드한다.
## width(perfect/safe/fail)는 트랙별 값이므로 여기가 아니라 트랙 JSON에서 온다.

var min_speed: float = 80.0
var max_speed: float = 300.0
var speed_step_count: int = 5
var speed_table: Array[float] = [80.0, 120.0, 170.0, 230.0, 300.0]  # 단계 1..5 → index 0..4
var steer_charge_rate: float = 3.2  # 입력 조향 누적 속도(구 1.8). 지수 추종과 함께 반전/복귀 민첩화
var steer_return_rate: float = 4.5  # 입력 해제 시 target→0 복귀 속도(구 2.4). 직진 복귀 실효 0.5s
var foot_response_rate: float = 1.1  # (구 move_toward 추종 계수) steer_tau 지수 평활로 대체됨. 미사용
# 지수 평활 추종 시간상수(랙 질감). actual += (target-actual)*(1-exp(-dt/steer_tau)).
# move_toward(선형 고정 속도)를 대체 — 반전 같은 큰 갭에서 즉시 빠르고 목표 근처에서 부드럽다.
var steer_tau: float = 0.16
# 반전 부스트: 입력 부호 ≠ target 부호일 때만 충전 속도에 곱하는 배수(§4.3 누적 유지, 반전만 민첩).
var steer_reversal_boost: float = 2.0
# 서브맥시멀(중간) 조향 완화 곡선(국소화). heading 출력에만 적용한다:
# out = sign(a)*(|a| - s*|a|*(1-|a|)^p), s=steer_expo, p=steer_soft_p. out(±1)=±1 항등이라
# 풀락 기하(회전반경·풀 반전·풀락 도달)는 완전히 불변이다. 완화 항 s*|a|*(1-|a|)^p는
# |a|=1에서 0으로 꺼지고 저·중간 |a|에서 봉긋해져(집중 지수 p) "탭만" 부드럽게 하면서
# 중간 authority는 3차 곡선보다 빨리 회복한다(hold 300ms 조향각을 3차보다 크게 되살림).
# target_steer/actual_steer 자체와 위험도 입력에는 절대 관여하지 않는다(리스크 밴드 보존).
# 설정 화면의 "조향 감도(부드러움)" 슬라이더가 [0.25,0.65]로 구동한다(LeaderboardClient 주입) —
# 엔드포인트 항등이라 슬라이더 전 구간에서 풀락 기하가 불변이라 기록 공정성이 유지된다.
var steer_expo: float = 0.55
var turn_power: float = 4.0  # 회전력. floor와 함께 고속 코너링 완화 재튜닝(구 3.3, §21 v3)
# 회전 각속도의 speed_factor 하한. turn_speed_factor = max(speed/max_speed, floor).
# floor를 4단 비율(230/300=0.767)과 5단 비율(1.0) 사이인 0.825로 두면 1~4단은 floor에
# 고정(factor=0.825)되고 5단만 자기 비율(1.0)을 쓴다. turn_power*floor = 4.0*0.825 = 3.3이라
# 1~4단 회전반경은 구값(24/36/51/70px)과 완전히 동일하고, 5단만 300/4.0 = 75px로 완화된다
# (구 91px). 저속 조작감을 한 틱도 바꾸지 않고 "고속 코너링만" 쉽게 하는 파라미터 전용 해법.
var steer_speed_floor: float = 0.825
# 위험도 재튜닝(지수 추종 도입, 조향 v4). 지수 평활은 target/actual 갭을 예전보다
# 짧게 만들어(반전이 부드럽게 수렴) 갭 적분이 줄었다. 그래서 리스크 파라미터를 다시
# 맞춰 기존 수용 기준을 유지한다: 5단 급반전 1회/4단 2회/3단 경고만(누적 peak~0.48, 부상無)/
# 1~2단 부상 불가/5단 풀조향 유지 경고~0.6s·부상~2.1s.
var risk_gain_rate: float = 3.6  # 위험도 증가 속도(구 2.8). 짧아진 갭을 보상해 상향
var risk_recover_rate: float = 0.65  # 위험도 회복 속도(구 0.5). 3단 급반전 반복이 부상으로 누적되지 않게
var danger_threshold: float = 0.07  # 게이트 임계(구 0.09). 낮춰 3단 급반전의 갭을 게이지에 반영
# 속도 계수 지수: pow(speed_factor, risk_speed_exp). 하향(구 1.5)으로 3단 급반전이 경고 영역까지
# 게이지를 채우게 하되(속도별 위험 분리), threshold가 1~2단 gain을 걸러 1~2단 부상은 불가로 유지.
var risk_speed_exp: float = 1.1
# 바늘 근접 계수 하한: proximity = base + (1-base)*steer_mag (조향 셀수록 손↔바늘 접근).
var risk_proximity_base: float = 0.35
# 조향 지연항의 상시 바이어스: 고속 풀조향 "유지"에도 위험이 쌓여 경고 UI가 뜨게 한다.
# 하향(구 0.14)으로 짧아진 갭 분포에서 5단 풀조향 유지 부상을 ~2.1s로 맞춘다.
var risk_static_bias: float = 0.09
var stun_duration: float = 2.0
var stun_steer_return_rate: float = 1.1  # §19 표에 없음 → foot_response_rate 값 재사용
# 맵 이탈 소프트 리셋 후 조작 잠금 시간(초). 재배치 직후 잘못된 입력이 바로 다시 원단을
# 이탈시키는 것을 막고 방향 재인지 여유를 준다(스턴과 별개 게이트, PlayerController가 참조).
var reset_lockout: float = 1.2

# --- 피벗 드리프트 (v1.0.1) ---
var drift_turn_mult: float = 2.5      # 드리프트 중 조향 각속도 배율(=반경 ÷2.5). g5 반경 75→30px.
var drift_static_bias: float = 0.18   # 드리프트 중 risk_static_bias 대체값(0.09→0.18).
var drift_proximity: float = 1.0      # 드리프트 중 손↔바늘 근접 강제 하한(피벗 손 누름).
var steer_soft_p: float = 2.0         # 국소화 곡선 집중 지수 out=m - s*m*(1-m)^p.


func _ready() -> void:
	_load_overrides()


func _load_overrides() -> void:
	var path: String = "res://data/tuning.json"
	if not FileAccess.file_exists(path):
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("Tuning: tuning.json 파싱 실패, 기본값 사용")
		return
	var dict: Dictionary = parsed
	for key in dict:
		# speed_table 같은 타입 배열은 오버라이드 대상에서 제외(스칼라만 허용).
		if key == "speed_table":
			continue
		if key in self:
			set(key, dict[key])
