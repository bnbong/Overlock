extends "res://menu_ux_regression/check_prefs.gd"
## v2.3.1 모바일 닉네임 입력 가상 키보드 검사(docs/mobile.md §5.1.1).
## 웹 템플릿은 export 옵션 html/experimental_virtual_keyboard가 꺼져 있으면 LineEdit에 가상 키보드를 쓰지 않고,
## IME용 숨은 contenteditable div를 100ms 타이머로 focus()한다. 모바일 브라우저는 사용자 제스처(터치 이벤트
## 처리기) 밖의 focus()에는 키보드를 띄우지 않으므로 닉네임을 입력할 수 없었다. 옵션을 켜면 LineEdit이 포커스를
## 얻는 순간(그리고 포커스된 칸을 다시 탭할 때) 엔진이 숨은 <input>을 focus()한다.
## 웹 4.6.1은 터치를 그 터치 처리기 안에서 바로 처리한다(브라우저 모바일 에뮬레이션에서 확인). 데스크톱은 입력을
## 모아 다음 프레임에 처리하므로, 터치 검사 동안 Input.use_accumulated_input 을 꺼서 웹 조건을 흉내 내고
## Input.parse_input_event 로 넣은 "그 호출 안에서" 포커스·편집 상태가 되는지 본다.
## 수정 전 코드에서도 파싱되도록 새 API 는 get/call 로만 부른다. 데스크톱 헤드리스 모사이며 실기 검증이 아니다.

const EXPORT_PRESETS: String = "res://export_presets.cfg"


## 터치 한 번(누름·뗌)을 Input 경로로 넣는다. 프레임을 기다리지 않는다.
func _tap_now(c: Control) -> void:
	var pos: Vector2 = get_tree().root.get_final_transform() * c.get_global_rect().get_center()
	for pressed in [true, false]:
		var t: InputEventScreenTouch = InputEventScreenTouch.new()
		t.index = 0
		t.position = pos
		t.pressed = pressed
		Input.parse_input_event(t)


func _settle() -> void:
	Input.flush_buffered_events()
	await _frames(3)


func _nick_tag() -> Button:
	var bar: Node = _scene().get_node_or_null("IdentityBar")
	return bar.get_child(0) as Button if bar != null else null


## Web 프리셋이 가상 키보드를 켠다(꺼져 있으면 웹에서 LineEdit이 키보드를 요청하지 못한다).
func _check_export_keyboard() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	_ok(cfg.load(EXPORT_PRESETS) == OK, "kbd: export_presets.cfg loads")
	var found: bool = false
	for sec in cfg.get_sections():
		if str(cfg.get_value(sec, "platform", "")) == "Web":
			found = true
			var opt: String = sec + ".options"
			var on: bool = bool(cfg.get_value(opt, "html/experimental_virtual_keyboard", false))
			_ok(on, "kbd: Web preset enables html/experimental_virtual_keyboard")
	_ok(found, "kbd: Web preset found")


func _check_touch_keyboard() -> void:
	_check_export_keyboard()
	var prev_accum: bool = Input.use_accumulated_input
	Input.use_accumulated_input = false
	LeaderboardClient.save_nickname("tester")
	_ok(await _goto(MAIN), "kbd: main opens")
	var tag: Button = _nick_tag()
	_ok(tag != null, "kbd: nickname tag found")
	if tag != null:
		await _check_tag_tap(tag)
	await _check_settings_keyboard()
	Input.use_accumulated_input = prev_accum


func _check_tag_tap(tag: Button) -> void:
	# 닉네임 태그 탭 → 같은 터치 처리 안에서 대화상자가 열리고 입력 칸이 포커스·편집 상태가 된다.
	_tap_now(tag)
	var dlg: Node = _dialog()
	var edit: LineEdit = dlg.get_node("Panel/NickEdit") if dlg != null else null
	_ok(dlg != null, "kbd: tag tap opens dialog within the same touch event")
	_ok(
		edit != null and edit.has_focus() and edit.is_editing(),
		"kbd: dialog LineEdit focused and editing within the tag tap"
	)
	await _settle()
	dlg = _dialog()
	if dlg == null:
		return
	edit = dlg.get_node("Panel/NickEdit")
	# 포커스된 입력 칸을 다시 탭해도 터치가 LineEdit 까지 닿고 편집 상태가 유지된다(엔진이 키보드를 다시 요청).
	var got: Array = []
	var probe: Callable = func(ev: InputEvent) -> void: got.append(ev.get_class())
	edit.gui_input.connect(probe)
	_tap_now(edit)
	_ok(
		"InputEventMouseButton" in got and "InputEventScreenTouch" in got,
		"kbd: LineEdit re-tap reaches gui_input within the event: " + str(got)
	)
	_ok(edit.has_focus() and edit.is_editing(), "kbd: LineEdit stays focused and editing")
	edit.gui_input.disconnect(probe)
	await _settle()
	_check_keyboard_lift(dlg)
	await _check_suggest_button(dlg)


## 가상 키보드가 아래를 가릴 때 대화상자를 위로 올린다(웹은 키보드 높이를 알 수 없어 고정 위치).
func _check_keyboard_lift(dlg: Node) -> void:
	_ok(dlg.has_method("_set_keyboard_lift"), "kbd: dialog has keyboard lift")
	if not dlg.has_method("_set_keyboard_lift"):
		return
	var bg: Control = dlg.get_node("PanelBg")
	var edit: LineEdit = dlg.get_node("Panel/NickEdit")
	var rest: Rect2 = bg.get_global_rect()
	dlg.call("_set_keyboard_lift", true)
	var lifted: Rect2 = bg.get_global_rect()
	_ok(lifted.position.y >= 0.0, "kbd: lifted panel stays on screen %s" % str(lifted))
	_ok(lifted.position.y < rest.position.y, "kbd: panel moves up while keyboard is expected")
	_ok(
		edit.get_global_rect().end.y <= 360.0,
		"kbd: lifted LineEdit in upper half %s" % str(edit.get_global_rect())
	)
	for b in _visible_of(dlg, "Button"):
		_ok(_inside(b), "kbd: lifted %s inside 1280x720" % b.name)
	dlg.call("_set_keyboard_lift", false)
	_ok(bg.get_global_rect().is_equal_approx(rest), "kbd: panel returns when keyboard is gone")


## 키보드 없이도 바꿀 수 있는 "추천 이름으로 바꾸기" → "저장".
func _check_suggest_button(dlg: Node) -> void:
	var sug: Button = dlg.find_child("SuggestButton", true, false) as Button
	_ok(sug != null and sug.is_visible_in_tree(), "kbd: suggest button visible in touch dialog")
	if sug == null:
		return
	var edit: LineEdit = dlg.get_node("Panel/NickEdit")
	var old: String = edit.text
	_tap_now(sug)
	await _settle()
	var picked: String = edit.text
	_ok(
		picked != old and picked.begins_with("Stitcher-"),
		"kbd: suggest replaces name: %s -> %s" % [old, picked]
	)
	_ok(LeaderboardClient.nickname == "tester", "kbd: suggest alone does not save")
	_tap_now(dlg.get_node("Panel/ConfirmButton"))
	await _settle()
	_ok(_dialog() == null, "kbd: save closes dialog after suggest")
	_ok(LeaderboardClient.nickname == picked, "kbd: suggested name saved: " + picked)
	_ok(str(_settings_file().get("nickname", "")) == picked, "kbd: suggested name on disk")
	LeaderboardClient.save_nickname("tester")


## 설정 화면 닉네임 칸: 처음에는 포커스 없음(키보드가 슬라이더를 가리지 않게), 탭하면 그 터치 안에서 편집.
func _check_settings_keyboard() -> void:
	_ok(await _goto(SETTINGS), "kbd: settings opens")
	var se: LineEdit = _scene().get("_nick_edit")
	_ok(not se.has_focus(), "kbd: settings does not auto-focus nickname on touch")
	_tap_now(se)
	_ok(se.has_focus() and se.is_editing(), "kbd: settings nickname tap focuses within the event")
	await _settle()
	_ok(await _goto(MAIN), "kbd: back to main")


## 데스크톱: 닉네임 대화상자·설정 포커스가 그대로다.
func _check_keyboard_desktop() -> void:
	LeaderboardClient.save_nickname("tester")
	_ok(await _goto(MAIN), "kbd desktop: main opens")
	_scene().call("_open_nickname_dialog")
	await _frames(3)
	var dlg: Node = _dialog()
	_ok(dlg != null, "kbd desktop: dialog opens")
	if dlg == null:
		return
	var names: Array = []
	for b in _visible_of(dlg, "Button"):
		names.append(str(b.name))
	_ok(names == ["ConfirmButton", "SecondaryButton"], "kbd desktop: dialog buttons " + str(names))
	var bg: Control = dlg.get_node("PanelBg")
	var box: Array = [bg.offset_left, bg.offset_top, bg.offset_right, bg.offset_bottom]
	_ok(box == [-240.0, -178.0, 240.0, 178.0], "kbd desktop: dialog panel unchanged " + str(box))
	var edit: LineEdit = dlg.get_node("Panel/NickEdit")
	_ok(edit.has_focus(), "kbd desktop: dialog focuses edit")
	await _key(KEY_ESCAPE)
	_ok(await _goto(SETTINGS), "kbd desktop: settings opens")
	var se: LineEdit = _scene().get("_nick_edit")
	_ok(se.has_focus(), "kbd desktop: settings still auto-focuses nickname")
	_ok(await _goto(MAIN), "kbd desktop: back to main")
