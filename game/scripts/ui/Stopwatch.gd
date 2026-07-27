class_name Stopwatch
extends Label
## 인게임 경과 시간 표시 (아키텍처 §10, presentation.md §4.3).
##
## 인게임 HUD는 SS.cc(초.센티초) 포맷을 쓴다. 기존 MM:SS.mmm(format_time)은
## 결과 화면 등에서 쓰일 수 있으므로 보존한다(결과 화면은 ResultScreen._format_ms
## 별도 사용 — 이 변경과 무관).


func set_time(seconds: float) -> void:
	text = format_race_time(seconds)


## 인게임 HUD 전용 SS.cc 포맷(presentation.md §4.3). 예: 88.24
static func format_race_time(seconds: float) -> String:
	var cs: int = int(round(maxf(seconds, 0.0) * 100.0))  # 센티초
	return "%d.%02d" % [cs / 100, cs % 100]


static func format_time(seconds: float) -> String:
	var total_ms: int = int(round(maxf(seconds, 0.0) * 1000.0))
	var minutes: int = total_ms / 60000
	var secs: int = (total_ms / 1000) % 60
	var millis: int = total_ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
