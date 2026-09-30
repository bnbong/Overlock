extends "res://menu_ux_regression/check_layout.gd"
## 설정 자동 저장(소리·조향)과 닉네임 명시 저장/취소 검사. 디스크 쓰기 실패는 user://settings.json 자리에
## 같은 이름의 디렉터리를 만들어 실제로 재현한다(격리 user dir 안에서만).

const SETTINGS_FILE: String = "user://settings.json"
## 자동 저장 지연(SettingsScreen.SAVE_DELAY 0.4초)보다 넉넉한 대기.
const AFTER_DEBOUNCE: float = 0.8


func _settings_file() -> Dictionary:
	var d: Variant = JSON.parse_string(_read_text(SETTINGS_FILE))
	return d if d is Dictionary else {}


func _writes() -> int:
	var v: Variant = LeaderboardClient.get("settings_writes")
	return int(v) if v != null else -1


## 설정 파일 쓰기를 실패하게 만든다(파일 자리에 디렉터리).
func _break_settings() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))


func _fix_settings() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))


func _approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.006


func _settings_status() -> String:
	var l: Label = _scene().get("_status_label")
	return l.text if l != null else ""


func _click_named(root: Node, node_name: String) -> void:
	var b: Control = root.find_child(node_name, true, false)
	_ok(b != null, "button exists: " + node_name)
	if b != null:
		await _click(b)


func _check_settings_autosave() -> void:
	LeaderboardClient.nickname = "tester"
	LeaderboardClient.save_volumes(1.0, 0.5, 1.0)
	_ok(await _goto(SETTINGS), "settings opens")
	var s: Node = _scene()
	var master: HSlider = s.get("_master_slider")
	var bgm: HSlider = s.get("_bgm_slider")
	var steer: HSlider = s.get("_steer_slider")
	# 1) 키보드: 여러 번 눌러도 지연 뒤 한 번만 쓴다.
	var w0: int = _writes()
	master.grab_focus()
	for _i in range(5):
		await _key(KEY_LEFT)
	_ok(int(master.value) == 95, "keyboard lowers master to 95 (got %d)" % int(master.value))
	_ok(_approx(float(_settings_file().get("volume_master", -1)), 1.0), "not written per key press")
	await _sleep(AFTER_DEBOUNCE)
	_ok(
		_approx(float(_settings_file().get("volume_master", -1)), 0.95), "keyboard change autosaved"
	)
	_ok(_writes() - w0 == 1, "5 key presses -> 1 disk write (got %d)" % (_writes() - w0))
	var w1: int = _writes()
	for _i in range(30):
		await _key(KEY_LEFT)
	await _sleep(AFTER_DEBOUNCE)
	_ok(_writes() - w1 == 1, "30 key presses -> 1 disk write (got %d)" % (_writes() - w1))
	_ok(_approx(float(_settings_file().get("volume_master", -1)), 0.65), "30 presses saved 0.65")
	# 2) 바꾼 직후 뒤로: 기다리지 않아도 떠날 때 반영한다.
	master.grab_focus()
	await _key(KEY_RIGHT)
	await _key(KEY_RIGHT)
	await _click(s.get("_back_button"))
	_ok(await _wait_scene(MAIN), "back leaves settings")
	var flushed: float = float(_settings_file().get("volume_master", -1))
	_ok(_approx(flushed, 0.67), "pending write flushed on back")
	LeaderboardClient.call("_load_settings")
	_ok(_approx(LeaderboardClient.volume_master, 0.67), "reload keeps 0.67")
	_ok(await _goto(SETTINGS), "settings reopens")
	s = _scene()
	master = s.get("_master_slider")
	bgm = s.get("_bgm_slider")
	steer = s.get("_steer_slider")
	_ok(int(master.value) == 67, "new SettingsScreen shows 67 (got %d)" % int(master.value))
	# 3) 마우스(터치 에뮬레이션과 같은 경로) 드래그: 손을 떼면 바로 쓴다.
	var r: Rect2 = bgm.get_global_rect()
	var from: Vector2 = Vector2(r.position.x + r.size.x * 0.5, r.get_center().y)
	var to: Vector2 = Vector2(r.position.x + r.size.x * 0.2, r.get_center().y)
	_mouse(from, false, true)
	await _frames(1)
	_mouse(from, true)
	await _frames(1)
	for k in range(1, 6):
		_mouse(from.lerp(to, k / 5.0), true, true)
		await _frames(1)
	_mouse(to, false)
	await _frames(2)
	var dragged: float = bgm.value / 100.0
	_ok(bgm.value < 45.0, "drag lowered bgm (got %.0f)" % bgm.value)
	_ok(
		_approx(float(_settings_file().get("volume_bgm", -1)), dragged),
		"drag release saved at once"
	)
	# 4) 값 직접 변경(스크립트·접근성 경로): 지연 뒤 저장.
	bgm.value = 33
	await _sleep(AFTER_DEBOUNCE)
	_ok(
		_approx(float(_settings_file().get("volume_bgm", -1)), 0.33),
		"direct value change autosaved"
	)
	# 5) 조향 감도도 같은 규칙.
	steer.grab_focus()
	var steer_before: float = steer.value
	await _key(KEY_LEFT)
	await _sleep(AFTER_DEBOUNCE)
	var span: float = LeaderboardClient.STEER_EXPO_MAX - LeaderboardClient.STEER_EXPO_MIN
	var want_expo: float = LeaderboardClient.STEER_EXPO_MIN + (steer_before - 1.0) / 100.0 * span
	_ok(
		_approx(float(_settings_file().get("steer_expo", -1)), want_expo),
		"steer keyboard autosaved"
	)
	# 6) 저장 실패 표시, 뒤로 한 번은 머물며 알림, 두 번째에 나간다.
	_break_settings()
	master.grab_focus()
	await _key(KEY_LEFT)
	await _sleep(AFTER_DEBOUNCE)
	_ok("저장하지 못" in _settings_status(), "autosave failure shown: " + _settings_status())
	await _click(s.get("_back_button"))
	await _frames(3)
	_ok(_scene() == s, "first back after failure stays on settings")
	_ok("다시" in _settings_status(), "leave warning shown: " + _settings_status())
	_fix_settings()
	master.grab_focus()
	await _key(KEY_LEFT)
	await _sleep(AFTER_DEBOUNCE)
	_ok(not ("저장하지 못" in _settings_status()), "failure notice clears after a good write")
	_ok(_approx(float(_settings_file().get("volume_master", -1)), 0.65), "retry wrote latest value")
	_ok(_auto_marked(s), "auto-save marker shown")


func _auto_marked(s: Node) -> bool:
	for l in _visible_of(s, "Label"):
		if "자동 저장" in (l as Label).text:
			return true
	return false


func _check_settings_nickname() -> void:
	LeaderboardClient.save_nickname("tester")
	_ok(await _goto(SETTINGS), "settings opens (nick)")
	var s: Node = _scene()
	var edit: LineEdit = s.get("_nick_edit")
	edit.text = "Renamed"
	edit.text_changed.emit("Renamed")
	await _frames(2)
	await _click(s.get("_back_button"))
	_ok(await _wait_scene(MAIN), "back leaves settings (nick)")
	_ok(LeaderboardClient.nickname == "tester", "unsaved nickname edit cancelled on back (memory)")
	_ok(str(_settings_file().get("nickname", "")) == "tester", "unsaved nickname edit not on disk")
	_ok(await _goto(SETTINGS), "settings reopens (nick)")
	s = _scene()
	edit = s.get("_nick_edit")
	edit.text = "Renamed"
	await _click(s.get("_save_button"))
	_ok(LeaderboardClient.nickname == "Renamed", "save button saves nickname")
	_ok(str(_settings_file().get("nickname", "")) == "Renamed", "saved nickname on disk")
	_break_settings()
	edit.text = "Other"
	await _click(s.get("_save_button"))
	_ok("실패" in _settings_status(), "nickname save failure shown: " + _settings_status())
	_ok(LeaderboardClient.nickname == "Renamed", "failed save keeps previous nickname in memory")
	_fix_settings()
	LeaderboardClient.save_nickname("tester")


func _dialog() -> Node:
	var s: Node = _scene()
	if s == null:
		return null
	for c in s.get_children():
		if c is NicknameDialog and not c.is_queued_for_deletion():
			return c
	return null


func _button_with_text(root: Node, text: String) -> Button:
	for b in _visible_of(root, "Button"):
		if (b as Button).text == text:
			return b
	return null


func _check_nickname_dialog() -> void:
	LeaderboardClient.save_nickname("tester")
	_ok(await _goto(MAIN), "main opens (dialog)")
	# 기존 이름 수정 중 Esc = 취소.
	_scene().call("_open_nickname_dialog")
	await _frames(3)
	var dlg: Node = _dialog()
	_ok(dlg != null, "edit dialog opens")
	var edit: LineEdit = dlg.get_node("Panel/NickEdit")
	edit.text = "Changed"
	await _key(KEY_ESCAPE)
	await _frames(2)
	_ok(_dialog() == null, "Esc closes edit dialog")
	_ok(LeaderboardClient.nickname == "tester", "Esc cancels edit (memory)")
	_ok(str(_settings_file().get("nickname", "")) == "tester", "Esc cancels edit (disk)")
	# 저장 버튼 = 저장.
	_scene().call("_open_nickname_dialog")
	await _frames(3)
	dlg = _dialog()
	dlg.get_node("Panel/NickEdit").text = "Changed"
	var save: Button = _button_with_text(dlg, "저장")
	_ok(save != null, "edit dialog has 저장 button")
	_ok(_button_with_text(dlg, "취소") != null, "edit dialog has 취소 button")
	if save != null:
		await _click(save)
	await _frames(2)
	_ok(_dialog() == null and LeaderboardClient.nickname == "Changed", "save closes and saves")
	# 빈 이름은 저장하지 않고 머문다.
	_scene().call("_open_nickname_dialog")
	await _frames(3)
	dlg = _dialog()
	dlg.get_node("Panel/NickEdit").text = "   "
	await _key(KEY_ENTER)
	await _frames(2)
	_ok(_dialog() != null, "empty name keeps dialog open")
	# 저장 실패: 닫지 않고 알리며 이전 이름을 유지한다.
	_break_settings()
	dlg.get_node("Panel/NickEdit").text = "Fail1"
	save = _button_with_text(dlg, "저장")
	if save != null:
		await _click(save)
	await _frames(2)
	_ok(_dialog() != null, "save failure keeps dialog open")
	_ok("저장하지 못" in (dlg.get_node("Panel/HintLabel") as Label).text, "save failure message shown")
	_ok(LeaderboardClient.nickname == "Changed", "save failure keeps previous nickname")
	_fix_settings()
	if save != null:
		await _click(save)
	await _frames(2)
	_ok(_dialog() == null and LeaderboardClient.nickname == "Fail1", "retry after fix saves")
	await _check_first_visit()


func _check_first_visit() -> void:
	# 최초 방문: 기본 닉네임으로 시작은 별도 선택.
	LeaderboardClient.save_nickname("")
	_ok(await _goto(MAIN), "main opens (first visit)")
	var dlg: Node = _dialog()
	_ok(dlg != null, "first visit opens nickname dialog")
	var start: Button = _button_with_text(dlg, "기본 닉네임으로 시작") if dlg != null else null
	_ok(start != null, "first visit offers 기본 닉네임으로 시작")
	if start != null:
		await _click(start)
	await _frames(2)
	_ok(LeaderboardClient.nickname.begins_with("Stitcher-"), "default nickname chosen explicitly")
	_ok(
		str(_settings_file().get("nickname", "")).begins_with("Stitcher-"), "default nickname saved"
	)
	# 최초 방문에서 직접 입력 후 Enter.
	LeaderboardClient.save_nickname("")
	_ok(await _goto(MAIN), "main opens (first visit 2)")
	dlg = _dialog()
	if dlg != null:
		dlg.get_node("Panel/NickEdit").text = "Alice"
		await _key(KEY_ENTER)
	await _frames(2)
	_ok(LeaderboardClient.nickname == "Alice", "first visit typed name saved with Enter")
	# 최초 방문 Esc = 기본 닉네임으로 시작(항상 닉네임 보장).
	LeaderboardClient.save_nickname("")
	_ok(await _goto(MAIN), "main opens (first visit 3)")
	await _key(KEY_ESCAPE)
	await _frames(2)
	_ok(_dialog() == null, "first visit Esc closes")
	_ok(LeaderboardClient.nickname.begins_with("Stitcher-"), "first visit Esc starts with default")
	LeaderboardClient.save_nickname("tester")
