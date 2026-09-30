extends Node
## 트랙 에디터 회귀 검사 공용 상태·도우미(check.gd 가 상속한다, run.sh 가 사본에만 복사).

const EditorScene: PackedScene = preload("res://scenes/TrackEditor.tscn")
const ZOOM: float = 0.5  # 검사용 그리기 배율(월드 2000px 폭의 곡선이 화면 안에 들어오게)

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: " + label)


func _frames(n: int = 2) -> void:
	for _i in range(n):
		await get_tree().process_frame


## 새 에디터 인스턴스(현재 씬이 아니라 이 노드의 자식으로 붙인다).
func _new_editor() -> Control:
	var ed: Control = EditorScene.instantiate()
	add_child(ed)
	await _frames(2)
	ed._canvas.set_view(ZOOM, ed._canvas.size * 0.5)
	return ed


func _free_editor(ed: Control) -> void:
	if is_instance_valid(ed):
		ed.queue_free()
	await _frames(2)


## 완만한 사인 곡선(월드 좌표). x -1000..1000, 진폭 250, 1.5주기 → 길이 약 2600, 최소반경 약 180.
func _sine_points(step: float, x0: float = -1000.0, x1: float = 1000.0) -> Array:
	var out: Array = []
	var x: float = x0
	while x <= x1 + 0.001:
		out.append(Vector2(x, 250.0 * sin((x + 1000.0) / 2000.0 * 3.0 * PI)))
		x += step
	return out


## 캔버스에 실제 마우스 이벤트(누름 → 이동 → 뗌)를 주입해 스트로크를 그린다(월드 좌표 목록).
func _stroke(ed: Control, world_pts: Array) -> void:
	var cv: DrawCanvas = ed._canvas
	var screen: Array = []
	for w in world_pts:
		screen.append(cv.get_global_transform() * cv.world_to_screen(w))
	_mouse_button(screen[0], true)
	for i in range(1, screen.size()):
		var a: Vector2 = screen[i - 1]
		var b: Vector2 = screen[i]
		var n: int = maxi(1, ceili(a.distance_to(b) / 3.0))
		for k in range(1, n + 1):
			_mouse_motion(a.lerp(b, float(k) / float(n)))
	_mouse_button(screen[screen.size() - 1], false)
	await _frames(1)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(ev, true)


func _mouse_motion(pos: Vector2, mask: int = MOUSE_BUTTON_MASK_LEFT) -> void:
	var ev: InputEventMouseMotion = InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = mask
	get_viewport().push_input(ev, true)


func _key(code: Key, ctrl: bool = false, shift: bool = false) -> void:
	for pressed in [true, false]:
		var ev: InputEventKey = InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		ev.ctrl_pressed = ctrl
		ev.meta_pressed = false
		ev.shift_pressed = shift
		if code == KEY_BACKSPACE or code == KEY_DELETE:
			ev.unicode = 0
		get_viewport().push_input(ev, true)


## 유효한 트랙을 그리고(실제 포인터 입력) 검증까지 마친다.
func _draw_valid(ed: Control) -> void:
	await _stroke(ed, _sine_points(40.0))
	ed._validate()


## 라운드트립용 트랙 JSON: 사용자 지정 폭, closed, 골무·엄마 찬스 여러 개(lat ≠ 0 포함).
func _roundtrip_track() -> Dictionary:
	var pts: Array = []
	for v in _sine_points(12.0):
		pts.append([snappedf(v.x, 0.1), snappedf(v.y, 0.1)])
	return {
		"name": "Round Trip",
		"difficulty": "normal",
		"fabric": "silk",
		"width": {"perfect": 15.0, "safe": 38.0, "fail": 80.0},
		"path": [{"type": "polyline", "points": pts, "closed": true}],
		"items": [
			{"s": 500.0, "type": "thimble", "lat": 0.0},
			{"s": 1200.0, "type": "autopilot", "lat": -20.0},
			{"s": 2000.0, "type": "thimble", "lat": 12.5},
			{"s": 2400.0, "type": "autopilot", "lat": 0.0},
		],
		"modifiers": [],
	}


func _file_dict(track_id: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(TrackLoader.read_custom_track_text(track_id))
	return parsed if parsed is Dictionary else {}


func _items_equal(a: Array, b: Array, tol: float = 0.002) -> bool:
	if a.size() != b.size():
		return false
	var sa: Array = a.duplicate(true)
	var sb: Array = b.duplicate(true)
	var by_s: Callable = func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["s"]) < float(y["s"])
	sa.sort_custom(by_s)
	sb.sort_custom(by_s)
	for i in range(sa.size()):
		if str(sa[i]["type"]) != str(sb[i]["type"]):
			return false
		if absf(float(sa[i]["s"]) - float(sb[i]["s"])) > tol:
			return false
		if absf(float(sa[i].get("lat", 0.0)) - float(sb[i].get("lat", 0.0))) > tol:
			return false
	return true


func _confirm_accept(ed: Control) -> void:
	_ok(ed._confirm.visible, "confirm dialog shown")
	ed._on_confirm_ok()
	if is_instance_valid(ed):
		ed._confirm.hide()


func _confirm_cancel(ed: Control) -> void:
	_ok(ed._confirm.visible, "confirm dialog shown (cancel)")
	ed._confirm.hide()
	ed._pending = Callable()


func _scene() -> Node:
	return get_tree().current_scene


func _scene_path() -> String:
	var s: Node = _scene()
	return s.scene_file_path if s != null else ""


func _change_to_editor() -> Control:
	get_tree().change_scene_to_file(GameState.EDITOR_SCENE)
	await _frames(3)
	return _scene() as Control
