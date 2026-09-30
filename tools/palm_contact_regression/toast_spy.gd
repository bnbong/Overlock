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


## toast_check 용 보조(v2.2.1): 표시 중인 말풍선을 터치 모드 배치로 다시 놓고 말풍선+초상화 사각형을
## 잰 뒤 원래(키보드) 배치로 되돌린다. 키보드 모드에는 터치 버튼이 없어 버튼 겹침은 이 배치로 검사한다.
static func touch_alert(t: Toast) -> Rect2:
	var prev: bool = t._touch_layout
	var tex: Texture2D = t._portrait.texture
	t._touch_layout = true
	t._apply_style(tex)
	t._reposition()
	var rect: Rect2 = t._panel.get_global_rect().merge(t._portrait.get_global_rect())
	t._touch_layout = prev
	t._apply_style(tex)
	t._reposition()
	return rect
