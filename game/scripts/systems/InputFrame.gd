class_name InputFrame
extends RefCounted
## 한 물리 틱의 입력 스냅샷 (아키텍처 §6.1).
##
## 실시간 입력과 (향후) 리플레이 입력의 공통 표현. RaceDirector가 만들어
## PlayerController.simulate()에 주입한다.

var steer: float = 0.0  # -1.0 왼쪽, +1.0 오른쪽, 0.0 없음
var speed_delta: int = 0  # -1 하락, 0 유지, +1 상승 (이산 입력 소비 결과)
var restart: bool = false


func _init(p_steer: float = 0.0, p_speed_delta: int = 0, p_restart: bool = false) -> void:
	steer = p_steer
	speed_delta = p_speed_delta
	restart = p_restart
