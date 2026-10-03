extends "res://menu_ux_regression/check_base.gd"
## 배치 검사. 터치 실행(-- --touch-controls)에서는 화면마다 보이는 버튼이 논리 높이 82 이상(844×390에서
## 약 44px), 1280×720 캔버스 안, 서로 겹치지 않음, 글자 하한을 확인한다. 데스크톱 실행에서는 같은 화면의
## 버튼 사각형을 수정 전 코드에서 뽑은 기준(desktop_baseline.json)과 비교해 배치가 바뀌지 않았는지 본다.

const STATES: Array[String] = [
	"main",
	"nick_first",
	"nick_edit",
	"profile",
	"kind",
	"select_official",
	"select_empty",
	"select_user",
	"settings",
	"leaderboard",
	"leaderboard_fail",
	"hub_list_fail",
	"hub_list",
	"hub_detail",
	"hub_form",
	"hub_done",
	"hub_confirm",
	"result",
	"result_test",
]
## 터치 목표: 버튼 논리 높이(×0.5414 ≈ 44px), 버튼 글자(≈ 12px), 본문 글자(≈ 12px).
const TOUCH_MIN_H: float = 82.0
const TOUCH_BUTTON_FONT: int = 22
const TOUCH_TEXT_FONT: int = 22
## 터치 배치에서도 글자 하한 검사를 하지 않는 라벨: 키보드 단축키 안내(문구·표시 정리는 P3 항목이라 두었다).
const TEXT_EXEMPT: Array[String] = ["HintLabel"]
## v2.3.0 트랙 선택 화면의 개인 고스트 줄(GhostToggle) 추가는 비교에서 빼지 않고, select_official·select_user
## 기준선을 그 코드로 다시 뽑아 desktop_baseline.json 에 반영했다(다른 상태의 기준선은 그대로).
## P1 설정·닉네임 저장/취소 변경으로 데스크톱 배치가 의도적으로 바뀌는 상태(비교 제외).
const DESKTOP_REDESIGNED: Array[String] = ["nick_first", "nick_edit"]
## P1 리더보드 "다시 시도" 버튼 추가로 실패 상태에서만 달라지는 키.
const DESKTOP_ADDED: Array[String] = ["leaderboard_fail|RetryButton", "leaderboard_fail|BackButton"]


## 모달 상태에서 검사 범위를 모달로 좁힌다(뒤쪽 화면 버튼과의 겹침은 의도된 것).
func _state_root(state_name: String) -> Node:
	var s: Node = _scene()
	match state_name:
		"nick_first", "nick_edit":
			for c in s.get_children():
				if c is NicknameDialog:
					return c
		"profile":
			for c in s.get_children():
				if c is ProfileDialog:
					return c
		"hub_confirm":
			return s.get("_overlay")
	return s


func _free_buttons(root: Node) -> Array:
	var out: Array = []
	for b in _visible_of(root, "Button"):
		if not _in_scroll(b):
			out.append(b)
	return out


func _check_layout_touch() -> void:
	_ok(TouchControls.should_show(), "touch layout active with --touch-controls")
	for st in STATES:
		_ok(await _state(st), st + ": state opens")
		await _frames(4)
		var root: Node = _state_root(st)
		_ok(root != null, st + ": state root found")
		if root == null:
			continue
		var all_buttons: Array = _visible_of(root, "Button")
		_ok(not all_buttons.is_empty(), st + ": has visible buttons")
		for b in all_buttons:
			var r: Rect2 = (b as Control).get_global_rect()
			if (b as Button).text.is_empty() and (b as Button).icon == null:
				# 글자 없는 카드·목록 행 버튼: 안쪽 라벨이 라벨 검사를 받는다(높이는 아래에서 본다).
				_ok(r.size.y >= TOUCH_MIN_H, "%s: %s card height" % [st, _key_of(b)])
				continue
			_ok(
				r.size.y >= TOUCH_MIN_H,
				"%s: %s height %.0f >= %.0f" % [st, _key_of(b), r.size.y, TOUCH_MIN_H]
			)
			_ok(
				_font_px(b) >= TOUCH_BUTTON_FONT,
				"%s: %s font %d >= %d" % [st, _key_of(b), _font_px(b), TOUCH_BUTTON_FONT]
			)
		var free: Array = _free_buttons(root)
		for b in free:
			_ok(
				_inside(b), "%s: %s inside 1280x720 %s" % [st, _key_of(b), str(b.get_global_rect())]
			)
		for i in range(free.size()):
			for j in range(i + 1, free.size()):
				var a: Rect2 = (free[i] as Control).get_global_rect().grow(-1.0)
				var c: Rect2 = (free[j] as Control).get_global_rect().grow(-1.0)
				_ok(
					not a.intersects(c),
					"%s: %s does not overlap %s" % [st, _key_of(free[i]), _key_of(free[j])]
				)
		for e in _visible_of(root, "LineEdit"):
			_ok(e.get_global_rect().size.y >= TOUCH_MIN_H, "%s: LineEdit %s height" % [st, e.name])
			_ok(_inside(e), "%s: LineEdit %s inside" % [st, e.name])
		for l in _visible_of(root, "Label"):
			if str(l.name) in TEXT_EXEMPT or (l as Label).text.strip_edges().is_empty():
				continue
			_ok(
				_font_px(l) >= TOUCH_TEXT_FONT,
				"%s: label '%s' font %d >= %d" % [st, _short(l), _font_px(l), TOUCH_TEXT_FONT]
			)
			if not _in_scroll(l):
				_ok(
					_inside(l),
					"%s: label '%s' inside %s" % [st, _short(l), str(l.get_global_rect())]
				)
		for s in _visible_of(root, "HSlider"):
			_ok(s.get_global_rect().size.y >= 60.0, "%s: slider %s height >= 60" % [st, s.name])
		_check_state_extras(st, root)


## 긴 닉네임·트랙 이름 같은 화면별 추가 확인.
func _check_state_extras(st: String, root: Node) -> void:
	match st:
		"main":
			var bar: Node = root.get_node_or_null("IdentityBar")
			var tag: Button = bar.get_child(0) if bar != null else null
			_ok(tag != null and LONG_NICK in tag.text, "main: long nickname shown in tag")
		"select_user":
			var label: Label = root.get("_track_label")
			var prev: Control = root.get("_prev_button")
			var next: Control = root.get("_next_button")
			_ok(label.text == LONG_TRACK, "select_user: long track selected")
			_ok(
				(
					not label.get_global_rect().intersects(prev.get_global_rect())
					and not label.get_global_rect().intersects(next.get_global_rect())
				),
				"select_user: long track name does not overlap arrows"
			)
		"result_test":
			var status: Label = root.get("_submit_status")
			_ok(status.visible and _inside(status), "result_test: test-play notice visible inside")


func _short(l: Label) -> String:
	var t: String = l.text.replace("\n", " ")
	return t.substr(0, 24)


## 데스크톱: 상태별 버튼 사각형 사전(state|key → [x, y, w, h]).
func _collect_desktop() -> Dictionary:
	var out: Dictionary = {}
	for st in STATES:
		var opened: bool = await _state(st)
		_ok(opened, st + ": state opens (desktop)")
		await _frames(4)
		var root: Node = _state_root(st)
		if root == null:
			continue
		for b in _free_buttons(root):
			var r: Rect2 = (b as Control).get_global_rect()
			out[st + "|" + _key_of(b)] = [r.position.x, r.position.y, r.size.x, r.size.y]
	return out


func _check_layout_desktop() -> void:
	_ok(not TouchControls.should_show(), "desktop run is not in touch layout")
	var now: Dictionary = await _collect_desktop()
	var base_path: String = str(_args.get("baseline", ""))
	var base_text: String = _read_text(base_path)
	var base: Variant = JSON.parse_string(base_text)
	_ok(base is Dictionary and not (base as Dictionary).is_empty(), "desktop baseline loaded")
	if not (base is Dictionary):
		return
	var compared: int = 0
	for k in base:
		var st: String = str(k).get_slice("|", 0)
		if st in DESKTOP_REDESIGNED or str(k) in DESKTOP_ADDED:
			continue
		var want: Array = base[k]
		var got: Variant = now.get(k, null)
		var same: bool = got is Array
		if same:
			for i in range(4):
				same = same and absf(float(got[i]) - float(want[i])) <= 0.5
		_ok(same, "desktop unchanged: %s %s -> %s" % [k, str(want), str(got)])
		compared += 1
	for k in now:
		var st2: String = str(k).get_slice("|", 0)
		if st2 in DESKTOP_REDESIGNED or str(k) in DESKTOP_ADDED:
			continue
		_ok((base as Dictionary).has(k), "desktop: no unexpected new button " + str(k))
	_ok(compared >= 60, "desktop compared %d buttons" % compared)
	print("desktop layout compared buttons: %d" % compared)
