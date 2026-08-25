extends Node
## 입력 액션 런타임 등록 오토로드 (기획서 §11.1, 아키텍처 §7).
##
## project.godot의 [input] 섹션에 InputEventKey를 손으로 직렬화하는 방식은
## 매우 취약하므로 코드로 InputMap에 등록한다. 물리 키코드를 사용해
## 키보드 레이아웃과 무관하게 동작하게 한다.


func _ready() -> void:
	_bind(&"steer_left", [KEY_LEFT, KEY_A])
	_bind(&"steer_right", [KEY_RIGHT, KEY_D])
	_bind(&"speed_up", [KEY_UP, KEY_W])
	_bind(&"speed_down", [KEY_DOWN, KEY_S])
	_bind(&"drift", [KEY_SHIFT])
	_bind(&"restart", [KEY_R])
	_bind(&"pause", [KEY_ESCAPE])
	_bind(&"to_menu", [KEY_M])


func _bind(action: StringName, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for key in keys:
		var event: InputEventKey = InputEventKey.new()
		event.physical_keycode = int(key)
		InputMap.action_add_event(action, event)
