extends Toast
## toast_check 용 기록 전용 토스트. PresentationController 의 push 호출(대사·초상화)만 모은다.

var calls: Array[Dictionary] = []


func push(message: String, portrait: Texture2D = null) -> void:
	calls.append({"text": message, "portrait": portrait})
