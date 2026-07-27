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
var steer_charge_rate: float = 1.8
var steer_return_rate: float = 2.4
var foot_response_rate: float = 1.1  # steer_charge_rate > foot_response_rate → 조향 지연 발생
var turn_power: float = 4.0  # 회전력. floor와 함께 고속 코너링 완화 재튜닝(구 3.3, §21 v3)
# 회전 각속도의 speed_factor 하한. turn_speed_factor = max(speed/max_speed, floor).
# floor를 4단 비율(230/300=0.767)과 5단 비율(1.0) 사이인 0.825로 두면 1~4단은 floor에
# 고정(factor=0.825)되고 5단만 자기 비율(1.0)을 쓴다. turn_power*floor = 4.0*0.825 = 3.3이라
# 1~4단 회전반경은 구값(24/36/51/70px)과 완전히 동일하고, 5단만 300/4.0 = 75px로 완화된다
# (구 91px). 저속 조작감을 한 틱도 바꾸지 않고 "고속 코너링만" 쉽게 하는 파라미터 전용 해법.
var steer_speed_floor: float = 0.825
var risk_gain_rate: float = 2.8  # 위험도 증가 속도. 부상 빈도 상향 피드백 반영 재튜닝(구 2.4)
var risk_recover_rate: float = 0.5  # 위험도 회복 속도(구 0.65)
var danger_threshold: float = 0.09  # §19 표에 없음 → v2 리스크 공식 기준 재튜닝(구 0.15)
# 속도 계수 지수: pow(speed_factor, risk_speed_exp). 하향(구 2.0)으로 3~4단 위험을 키워 부상
# 빈도를 올리되, threshold(0.09)가 2단 gain을 계속 걸러내 1~2단 부상은 사실상 불가로 유지.
var risk_speed_exp: float = 1.5
# 바늘 근접 계수 하한: proximity = base + (1-base)*steer_mag (조향 셀수록 손↔바늘 접근).
var risk_proximity_base: float = 0.35
# 조향 지연항의 상시 바이어스: 고속 풀조향 "유지"에도 위험이 쌓여 경고 UI가 뜨게 한다.
# 상향(구 0.10)으로 5단 풀조향 유지 부상을 3.3s→2.0s로 앞당긴다.
var risk_static_bias: float = 0.14
var stun_duration: float = 2.0
var stun_steer_return_rate: float = 1.1  # §19 표에 없음 → foot_response_rate 값 재사용


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
