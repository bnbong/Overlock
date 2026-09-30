class_name EditorIssues
extends RefCounted
## 검증 결과 → 항목별 안내 목록 (track-editor-ux 6단계 후반). TrackValidator의 기준·판정은 그대로 두고
## 기존 결과(curvature·proximity·length_status·length·min_radius)에서 UI용 항목을 꺼낸다.
##
## 항목: {severity("hard" 저장 불가 | "soft" 권장), kind, text, hint, points(월드, 비면 위치 없음)}.
## 권장 경고가 많을 때(자기근접 경고 수십 곳) 목록이 화면을 덮지 않게 SOFT_ROWS개까지만 따로 적고
## 나머지는 한 줄로 요약한다.

const SOFT_ROWS: int = 6


## 검증 항목 목록 패널(IssuePanel). 저장 가능(하드 통과)과 권장 경고를 나눠 제목에 적는다.
static func show(ed: Control, issues: Array) -> void:
	var panel: Control = ed.get_node("IssuePanel")
	var title: Label = panel.get_node("Box/Head/IssueTitle")
	var hard: int = count(issues, "hard")
	var soft: int = count(issues, "soft")
	ed._canvas.set_focus(PackedVector2Array())
	panel.visible = not issues.is_empty()
	populate(
		panel.get_node("Box/Scroll/IssueList"), issues, goto.bind(ed), TouchControls.should_show()
	)
	if hard > 0:
		title.text = "저장 불가 · 고칠 곳 %d · 권장 경고 %d" % [hard, soft]
		title.add_theme_color_override("font_color", ed.FAIL_COLOR)
	else:
		title.text = "저장 가능 · 권장 경고 %d" % soft
		title.add_theme_color_override("font_color", ed.OK_COLOR)
	# 저장 가능(권장 경고만)이면 목록을 접어 그리기 영역을 가리지 않고, 고칠 곳이 있으면 펼친다.
	ed._issues_collapsed = hard == 0
	_apply_collapse(ed)


static func toggle(ed: Control) -> void:
	ed._issues_collapsed = not ed._issues_collapsed
	_apply_collapse(ed)


static func _apply_collapse(ed: Control) -> void:
	var collapsed: bool = ed._issues_collapsed
	(ed.get_node("IssuePanel/Box/Scroll") as Control).visible = not collapsed
	(ed.get_node("IssuePanel/Box/Head/IssueToggle") as Button).text = "펼치기" if collapsed else "접기"
	EditorSkin.place_overlays.call_deferred(ed)


## "위치로": 카메라만 옮기고 해당 위치를 강조한다(경로는 바뀌지 않는다).
static func goto(points: PackedVector2Array, ed: Control) -> void:
	if points.is_empty():
		return
	var c: Vector2 = Vector2.ZERO
	for p in points:
		c += p
	ed._canvas.center_on(c / float(points.size()), 0.6)
	ed._canvas.set_focus(points)


static func build(res: Dictionary, path: PackedVector2Array) -> Array:
	var hard: Array = []
	var soft: Array = []
	if int(res.get("hard", 0)) > 0 and path.size() < TrackValidator.MIN_POINTS:
		hard.append(_issue("hard", "points", "경로가 너무 짧습니다(점 %d개)." % path.size(),
			"더 길게 그리세요.", []))
	for v in res.get("curvature", []):
		var i: int = int(v["i"])
		var r: float = float(v["radius"])
		if str(v["kind"]) == "hard":
			hard.append(_issue("hard", "curvature",
				"급한 곡선: 반경 %d (최소 %d)" % [roundi(r), int(TrackValidator.MIN_RADIUS)],
				"곡선을 더 크게 그리거나 '자동 수정…'을 써 보세요.", _pts(path, [i])))
		else:
			soft.append(_issue("soft", "curvature",
				"조금 급한 곡선: 반경 %d (권장 %d 이상)" % [roundi(r), int(TrackValidator.RADIUS_RECOMMEND)],
				"그대로 저장할 수 있습니다.", _pts(path, [i])))
	for p in res.get("proximity", []):
		var pts: Array = _pts(path, [int(p["i"]), int(p["j"])])
		if str(p["kind"]) == "hard":
			hard.append(_issue("hard", "proximity",
				"경로 두 구간이 너무 가깝습니다: 거리 %d" % roundi(float(p["d"])),
				"한쪽을 끝부분 자르기로 지우고 떨어뜨려 다시 그리세요.", pts))
		else:
			soft.append(_issue("soft", "proximity",
				"두 구간의 판정 폭이 겹칩니다: 거리 %d" % roundi(float(p["d"])),
				"그대로 저장할 수 있습니다.", pts))
	var length: int = roundi(float(res.get("length", 0.0)))
	match str(res.get("length_status", "ok")):
		"too_short":
			hard.append(_issue("hard", "length",
				"트랙 길이 %d: 최소 %d보다 짧습니다" % [length, int(TrackValidator.LEN_HARD_MIN)],
				"'트랙 길이 조절…'로 늘리거나 이어 그리세요.", []))
		"too_long":
			hard.append(_issue("hard", "length",
				"트랙 길이 %d: 최대 %d보다 깁니다" % [length, int(TrackValidator.LEN_HARD_MAX)],
				"'트랙 길이 조절…'로 줄이거나 끝부분을 자르세요.", []))
		"short_warn", "long_warn":
			soft.append(_issue("soft", "length",
				"트랙 길이 %d: 권장 %d~%d 밖" % [
					length, int(TrackValidator.LEN_MIN), int(TrackValidator.LEN_MAX)
				],
				"그대로 저장할 수 있습니다.", []))
	return hard + soft


static func _issue(sev: String, kind: String, text: String, hint: String, pts: Array) -> Dictionary:
	return {"severity": sev, "kind": kind, "text": text, "hint": hint, "points": pts}


static func _pts(path: PackedVector2Array, idx: Array) -> Array:
	var out: Array = []
	for i in idx:
		if int(i) >= 0 and int(i) < path.size():
			out.append(path[int(i)])
	return out


static func count(issues: Array, sev: String) -> int:
	var n: int = 0
	for it in issues:
		if str(it["severity"]) == sev:
			n += 1
	return n


## 목록 UI 채우기. 저장 불가 항목은 모두, 권장 경고는 SOFT_ROWS개까지 적고 나머지는 한 줄 요약.
## 위치가 있는 항목에는 "위치로" 버튼(goto(points))을 붙인다. 반환: 만든 행 수.
static func populate(box: VBoxContainer, issues: Array, goto: Callable, touch: bool) -> int:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var soft_shown: int = 0
	var soft_total: int = count(issues, "soft")
	var rows: int = 0
	for it in issues:
		var hard: bool = str(it["severity"]) == "hard"
		if not hard:
			if soft_shown >= SOFT_ROWS:
				continue
			soft_shown += 1
		box.add_child(_row(it, goto, touch))
		rows += 1
	if soft_total > soft_shown:
		var more: Label = Label.new()
		more.text = "권장 경고 %d곳 더 있음(저장에는 영향 없음)" % (soft_total - soft_shown)
		more.add_theme_font_size_override("font_size", 13)
		more.add_theme_color_override("font_color", Color(0.85, 0.78, 0.6))
		box.add_child(more)
		rows += 1
	return rows


static func _row(it: Dictionary, goto: Callable, touch: bool) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var hard: bool = str(it["severity"]) == "hard"
	var l: Label = Label.new()
	l.text = ("✕ " if hard else "△ ") + str(it["text"]) + "\n   " + str(it["hint"])
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(250, 0)
	l.add_theme_font_size_override("font_size", 16 if touch else 13)
	l.add_theme_color_override(
		"font_color", Color(1.0, 0.55, 0.5) if hard else Color(0.98, 0.82, 0.5)
	)
	row.add_child(l)
	var pts: Array = it["points"]
	if not pts.is_empty():
		var b: Button = Button.new()
		b.text = "위치로"
		b.custom_minimum_size = Vector2(64, 44 if touch else 28)
		b.pressed.connect(goto.bind(PackedVector2Array(pts)))
		EditorSkin.skin_button(b)
		row.add_child(b)
	return row
