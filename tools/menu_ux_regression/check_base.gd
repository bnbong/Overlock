extends Node
## 메뉴 UX 회귀 검사·캡처 공용 도우미(사본 프로젝트 전용). 화면 상태 준비(_state)는 검사(check.gd)와
## 캡처(capture.gd)가 함께 쓴다. 입력은 뷰포트 push_input 으로 넣는다(데스크톱 모사이며 실기 터치가 아니다).
## 이 파일은 수정 전 코드에서도 파싱되도록 새 API 를 get/call 로만 부른다(수정 전 실패 확인용).

const MAIN: String = "res://scenes/Main.tscn"
const KIND: String = "res://scenes/TrackKindSelect.tscn"
const SELECT: String = "res://scenes/TrackSelect.tscn"
const SETTINGS: String = "res://scenes/Settings.tscn"
const LEADERBOARD: String = "res://scenes/Leaderboard.tscn"
const HUB: String = "res://scenes/CommunityHub.tscn"
const RESULT: String = "res://scenes/Result.tscn"
const TrackSelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const LONG_NICK: String = "WWWWWWWWWWWWWWWW"
const LONG_TRACK: String = "아주아주 긴 한국어 트랙 이름 Stitch Marathon Grand Tour 2026"
const LONG_TITLE: String = "공유 허브 게시물 제목이 아주 길어서 한 줄에 다 들어가지 않는 경우 Very Long Title"

var _passed: int = 0
var _failed: int = 0
var _args: Dictionary = {}
var _own_id: String = ""
var _hub_track: Dictionary = {}


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
		elif a.begins_with("--"):
			_args[a.substr(2)] = "1"


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: " + label)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _sleep(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


func _scene() -> Node:
	return get_tree().current_scene


func _wait_scene(path: String, frames: int = 90) -> bool:
	for _i in range(frames):
		var s: Node = _scene()
		if s != null and s.scene_file_path == path and s.is_node_ready():
			await _frames(3)
			return true
		await get_tree().process_frame
	return false


func _goto(path: String) -> bool:
	get_tree().change_scene_to_file(path)
	return await _wait_scene(path)


func _key(keycode: Key, shift: bool = false) -> void:
	for pressed in [true, false]:
		var ev: InputEventKey = InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.shift_pressed = shift
		ev.pressed = pressed
		get_tree().root.push_input(ev, true)
		await get_tree().process_frame


func _mouse(pos: Vector2, pressed: bool, move_only: bool = false) -> void:
	if move_only:
		var mv: InputEventMouseMotion = InputEventMouseMotion.new()
		mv.position = pos
		mv.global_position = pos
		mv.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		get_tree().root.push_input(mv, true)
		return
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.position = pos
	ev.global_position = pos
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_tree().root.push_input(ev, true)


func _click(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	_mouse(pos, false, true)
	await get_tree().process_frame
	_mouse(pos, true)
	await get_tree().process_frame
	_mouse(pos, false)
	await get_tree().process_frame


## 로컬 스텁 서버 제어 요청(GET). 본문을 dict 로 돌려준다(실패 시 빈 dict).
func _http_get(url: String) -> Dictionary:
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	if http.request(url) != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if data is Dictionary else {}


func _plan(query: String) -> void:
	await _http_get(str(_args.get("stub", "")) + "/__plan?" + query)


func _font_px(c: Control) -> int:
	return c.get_theme_font_size("font_size")


func _inside(c: Control) -> bool:
	return Rect2(Vector2.ZERO, Vector2(1280, 720)).grow(0.5).encloses(c.get_global_rect())


func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


## 보이는 Control 자손(Window 내부·숨은 가지 제외)을 모은다.
func _visible_of(root: Node, type_name: String) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is Window:
			continue
		if child is CanvasItem and not (child as CanvasItem).is_visible_in_tree():
			continue
		if child.is_class(type_name):
			out.append(child)
		out.append_array(_visible_of(child, type_name))
	return out


func _in_scroll(c: Node) -> bool:
	var p: Node = c.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false


## 버튼 식별 키(이름이 자동 생성이면 글자로).
func _key_of(b: Button) -> String:
	var n: String = str(b.name)
	return ("~" + b.text) if n.begins_with("@") else n


# --- 화면 상태 준비(검사·캡처 공용) ---


## 로컬 커스텀 트랙(긴 이름)과 허브 게시 형식 트랙을 만든다(한 번만).
func _make_fixtures() -> void:
	if not _own_id.is_empty():
		return
	var src: Dictionary = JSON.parse_string(_read_text("res://tracks/official/cotton_01.json"))
	src["name"] = LONG_TRACK
	var own: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(src), LONG_TRACK)
	_own_id = str(own.get("track_id", ""))
	var tmp: Dictionary = TrackLoader.import_custom_from_text(
		_read_text("res://tracks/official/heart_01.json"), "Temp Heart"
	)
	var built: Dictionary = TrackLoader.build_publish_track(str(tmp["track_id"]))
	TrackLoader.delete_custom_track(str(tmp["track_id"]))
	_hub_track = built.get("track", {})


## 빈 유저 트랙 목록 상태를 위해 앞선 실행이 남긴 커스텀 트랙을 지운다(격리 user dir 안).
func _clear_custom_tracks() -> void:
	for t in TrackLoader.list_custom_tracks():
		TrackLoader.delete_custom_track(str(t["track_id"]))
	_own_id = ""


func _hub_item(i: int) -> Dictionary:
	return {
		"id": "00000000-0000-4000-8000-%012d" % (i + 1),
		"title": LONG_TITLE if i == 0 else "허브 트랙 %d" % (i + 1),
		"author_name": "작성자이름이꽤긴사람 %d" % i,
		"difficulty": "normal",
		"fabric": "denim",
		"length": 3100 + i * 17,
		"created_at": "2026-09-30T09:36:36.772183+00:00",
	}


## 상태 이름대로 화면을 연다. 성공하면 true. 열린 화면은 _scene()(대화상자는 그 자식)이다.
func _state(state_name: String) -> bool:
	LeaderboardClient.base_url = str(_args.get("stub", "http://127.0.0.1:9"))
	LeaderboardClient.health_known = false
	GameState.clear_editor_test()
	LeaderboardClient.nickname = "" if state_name == "nick_first" else LONG_NICK
	var ok: bool = false
	match state_name:
		"main", "nick_first", "nick_edit", "profile":
			ok = await _goto(MAIN)
			LeaderboardClient.nickname = LONG_NICK
			if state_name == "nick_edit":
				_scene().call("_open_nickname_dialog")
			elif state_name == "profile":
				_scene().call("_open_profile_dialog")
			await _frames(4)
		"kind":
			ok = await _goto(KIND)
		"select_official", "select_empty", "select_user":
			var user: bool = state_name != "select_official"
			if state_name == "select_user":
				_make_fixtures()
				LeaderboardClient.last_track_id = _own_id
			elif state_name == "select_empty":
				_clear_custom_tracks()
			TrackSelectScript.pending_mode = (
				TrackSelectScript.MODE_USER if user else TrackSelectScript.MODE_OFFICIAL
			)
			ok = await _goto(SELECT)
		"settings":
			ok = await _goto(SETTINGS)
		"leaderboard", "leaderboard_fail":
			await _plan(
				"codes=%s&count=12" % ("500" if state_name == "leaderboard_fail" else "200")
			)
			LeaderboardClient.set_view_target("", "normal", "")
			ok = await _goto(LEADERBOARD)
			await _sleep(0.6)
		"hub_list_fail":
			ok = await _goto(HUB)
			await _sleep(0.6)
		"hub_list", "hub_detail", "hub_form", "hub_done", "hub_confirm":
			ok = await _hub_state(state_name)
		"result", "result_test":
			ok = await _result_state(state_name == "result_test")
	return ok


func _hub_state(state_name: String) -> bool:
	_make_fixtures()
	if not await _goto(HUB):
		return false
	var hub: Node = _scene()
	await _sleep(0.3)
	match state_name:
		"hub_list":
			var items: Array = []
			for i in range(8):
				items.append(_hub_item(i))
			hub.set("_list_req", 0)
			hub.call(
				"_on_list_done", {"ok": true, "data": {"items": items, "total": 25, "count": 8}}
			)
			(hub.get("_retry_btn") as Control).visible = false  # 앞선 스텁 404 실패의 다시 시도 버튼
		"hub_detail":
			var d: Dictionary = _hub_item(0)
			d["description"] = "설명 문장입니다. ".repeat(12)
			d["track"] = _hub_track
			d["content_hash"] = "hash-menu-ux"
			hub.call("_render_detail", d)
		"hub_form", "hub_confirm":
			hub.call("_open_form", _own_id)
			if state_name == "hub_confirm":
				hub.call("_ask", str(hub.get("PUBLIC_NOTICE")) + "\n\n게시할까요?", Callable(), "게시하기")
		"hub_done":
			hub.call("_open_form", _own_id)
			var created: Dictionary = {"id": "00000000-0000-4000-8000-000000000099"}
			created["title"] = LONG_TITLE
			created["delete_token"] = "tok-0123456789abcdef0123456789abcdef"
			hub.call("_on_publish_done", {"ok": true, "data": created, "token_saved": false})
	await _frames(4)
	return true


func _result_state(editor_test: bool) -> bool:
	_make_fixtures()
	var r: Dictionary = {
		"track_id": _own_id if editor_test else "cotton_01",
		"difficulty": "normal",
		"grade": "A",
		"final_time_ms": 83456,
		"penalty_ms": 1200,
		"accuracy": 98.5,
		"perfect_rate": 90.1,
		"cuts": 2,
		"is_new_record": not editor_test,
	}
	if editor_test:
		r["editor_test"] = true
		GameState.run_source = GameState.SOURCE_EDITOR_TEST
	GameState.last_result = r
	var ok: bool = await _goto(RESULT)
	await _frames(6)
	return ok
