extends Toast
## toast_check 용 기록 전용 토스트. PresentationController 의 push·push_immediate 호출(대사·초상화)만
## 모은다. "immediate" 는 push_immediate 로 들어온 호출인지.

var calls: Array[Dictionary] = []
var dismissed: int = 0  # dismiss() 호출 수(완주 줌아웃 진입 정리)


func push(message: String, portrait: Texture2D = null) -> void:
	calls.append({"text": message, "portrait": portrait, "immediate": false})


func push_immediate(message: String, portrait: Texture2D = null) -> void:
	calls.append({"text": message, "portrait": portrait, "immediate": true})


func dismiss() -> void:
	dismissed += 1
