extends "res://track_editor_regression/check_view.gd"
## 셋째 묶음 검사: 아이템 도구(배치·선택·이동·삭제·종류·undo·제약·교차 구간·검토 해결), 원단·폭 패널,
## 검증 항목 목록·위치 이동, 에디터 UI 경로 라운드트립, 테스트 주행에서 아이템 표시·획득·원단 적용.
## check.gd 가 상속한다.


func _items_of(ed: Control) -> Array:
	return ed._doc["items"]


## 월드 점을 실제 마우스로 누르고(드래그 경로를 거쳐) 뗀다.
func _click_world(ed: Control, w: Vector2, drag_to: Array = []) -> void:
	var cv: DrawCanvas = ed._canvas
	var sp: Vector2 = cv.get_global_transform() * cv.world_to_screen(w)
	_mouse_motion(sp, 0)
	_mouse_button(sp, true)
	var last: Vector2 = sp
	for d in drag_to:
		var dp: Vector2 = cv.get_global_transform() * cv.world_to_screen(d)
		_mouse_motion(dp)
		last = dp
	_mouse_button(last, false)
	await _frames(1)


func _point_at(path: PackedVector2Array, s: float) -> Vector2:
	return EditorDoc.item_world(path, {"s": s, "lat": 0.0})


func _plain_track() -> Dictionary:
	var t: Dictionary = _roundtrip_track()
	t["items"] = []
	return t


func _import(ed: Control, t: Dictionary) -> void:
	ed._import_from_text(JSON.stringify(t))
	if ed._confirm.visible:
		_confirm_accept(ed)
	ed._validate()


func _check_item_tool() -> void:
	var ed: Control = await _new_editor()
	_import(ed, _plain_track())
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	var path: PackedVector2Array = ed._doc["path"]
	var serial0: String = EditorDoc.serial(ed._doc)
	var n_undo: int = ed._undo_stack.size()
	ed._mode_item.emit_signal("pressed")
	_ok(
		ed._canvas.mode == DrawCanvas.Mode.ITEM and ed.get_node("ItemBar").visible,
		"item tool selected"
	)
	# 배치(실제 클릭)
	await _click_world(ed, _point_at(path, 800.0))
	_ok(_items_of(ed).size() == 1, "click on path places item")
	var it: Dictionary = _items_of(ed)[0] if not _items_of(ed).is_empty() else {}
	_ok(str(it.get("type", "")) == "thimble" and float(it.get("lat", 1.0)) == 0.0, "thimble, lat 0")
	_ok(
		absf(float(it.get("s", 0.0)) - 800.0) < 10.0,
		"placed at s≈800 (%.1f)" % float(it.get("s", 0))
	)
	_ok(ed._doc["path"] == path, "item click does not start a stroke")
	_ok(ed._undo_stack.size() == n_undo + 1 and ed._is_dirty(), "place = one undo + dirty")
	_ok(ed._selected_item == -1, "placing does not select (type buttons stay for next item)")
	await _click_world(ed, _point_at(path, 800.0))
	_ok(ed._selected_item == 0 and _items_of(ed).size() == 1, "clicking marker selects, no new item")
	_ok(ed._canvas._item_marks[0]["label"].begins_with("시작부터"), "selected label shows distance")
	# 경로에서 먼 곳 → 배치 안 함, 선택 해제
	await _click_world(ed, _point_at(path, 800.0) + Vector2(0, 400))
	_ok(_items_of(ed).size() == 1 and ed._selected_item == -1, "far click: no item, deselect")
	# 종류: 엄마 찬스로 바꾸고 배치
	ed.get_node("ItemBar/AutopilotType").emit_signal("pressed")
	await _click_world(ed, _point_at(path, 1600.0))
	_ok(str(_items_of(ed)[1]["type"]) == "autopilot", "autopilot placed")
	_ok(str(_items_of(ed)[0]["type"]) == "thimble", "type button did not change unselected item")
	# 선택 아이템 종류 변경(undo 한 단위)
	await _click_world(ed, _point_at(path, 1600.0))
	_ok(ed._selected_item == 1, "select autopilot marker")
	var u: int = ed._undo_stack.size()
	ed.get_node("ItemBar/ThimbleType").emit_signal("pressed")
	_ok(
		str(_items_of(ed)[1]["type"]) == "thimble" and ed._undo_stack.size() == u + 1,
		"type change"
	)
	ed._undo()
	_ok(str(_items_of(ed)[1]["type"]) == "autopilot", "undo type change")
	# 드래그 이동: 뗄 때 undo 한 번
	var drag_pts: Array = []
	for s in range(820, 1201, 20):
		drag_pts.append(_point_at(path, float(s)))
	u = ed._undo_stack.size()
	await _click_world(ed, _point_at(path, 800.0), drag_pts)
	_ok(
		absf(float(_items_of(ed)[0]["s"]) - 1200.0) < 15.0,
		"drag moved to s≈1200 (%.1f)" % float(_items_of(ed)[0]["s"])
	)
	_ok(ed._undo_stack.size() == u + 1 and ed._redo_stack.is_empty(), "drag = one undo on release")
	ed._undo()
	_ok(absf(float(_items_of(ed)[0]["s"]) - 800.0) < 10.0, "undo drag")
	ed._redo()
	_ok(absf(float(_items_of(ed)[0]["s"]) - 1200.0) < 15.0, "redo drag")
	# 삭제: Delete 키(캔버스 포커스), 이름 입력 중에는 가로채지 않음
	ed._selected_item = 0
	ed._name_edit.grab_focus()
	await _frames(1)
	_key(KEY_DELETE)
	await _frames(1)
	_ok(_items_of(ed).size() == 2, "name focus: Delete does not delete item")
	ed._canvas.grab_focus()
	_key(KEY_DELETE)
	await _frames(1)
	_ok(_items_of(ed).size() == 1 and ed._selected_item == -1, "Delete removes selected item")
	ed._undo()
	_ok(_items_of(ed).size() == 2, "undo delete")
	ed._selected_item = 1
	ed.get_node("ItemBar/ItemDelete").emit_signal("pressed")
	_ok(_items_of(ed).size() == 1, "delete button")
	# s 상한: 끝점 클릭 → s ≤ 길이 − 0.5
	await _click_world(ed, path[path.size() - 1])
	var last: Dictionary = _items_of(ed)[_items_of(ed).size() - 1]
	_ok(float(last["s"]) <= EditorDoc.path_length(path) - 0.5 + 0.001, "end click clamps s ≤ L-0.5")
	_ok(ed._status_label.text.contains("출발·도착"), "near-end warning only")
	# 128개 상한
	var many: Array = []
	for i in range(EditorDoc.MAX_ITEMS):
		many.append({"s": 100.0 + i * 15.0, "type": "thimble", "lat": 0.0})
	ed._doc["items"] = many
	ed._selected_item = -1
	ed._refresh()
	await _click_world(ed, _point_at(path, 50.0))
	_ok(_items_of(ed).size() == EditorDoc.MAX_ITEMS, "128 cap: no more placed")
	_ok(ed._status_label.text.contains("128"), "cap message")
	# 아이템 도구를 떠나면 선택 해제, 모드별 Backspace는 기존 동작
	ed._set_mode(DrawCanvas.Mode.DRAW)
	_ok(
		ed._selected_item == -1 and not ed.get_node("ItemBar").visible,
		"leaving item tool deselects"
	)
	ed._doc["items"] = []
	ed._refresh()
	_ok(ed._doc["path"] == path and serial0 != "", "item work never touched the path")
	await _free_editor(ed)
	_done.append("item_tool")


func _check_item_lat_and_cross() -> void:
	# lat≠0 보존(가져온 값, 이동해도 유지)
	var ed: Control = await _new_editor()
	_import(ed, _roundtrip_track())
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	ed._set_mode(DrawCanvas.Mode.ITEM)
	var path: PackedVector2Array = ed._doc["path"]
	var i: int = 1  # s 1200, lat -20
	var start: Vector2 = EditorDoc.item_world(path, _items_of(ed)[i])
	var pts: Array = []
	for s in range(1210, 1401, 15):
		pts.append(_point_at(path, float(s)) + (start - _point_at(path, 1200.0)))
	await _click_world(ed, start, pts)
	_ok(float(_items_of(ed)[i]["lat"]) == -20.0, "drag keeps imported lat -20")
	_ok(
		float(_items_of(ed)[i]["s"]) > 1300.0,
		"lat item moved (%.1f)" % float(_items_of(ed)[i]["s"])
	)
	_ok(float(EditorDoc.to_track_dict(ed._doc)["items"][i]["lat"]) == -20.0, "saved lat kept")
	await _free_editor(ed)
	# 교차 구간: 8자 경로에서 교차점을 지나 끌어도 다른 갈래로 튀지 않는다
	var fig: PackedVector2Array = PackedVector2Array()
	var t: float = 0.15
	while t < TAU - 0.15:
		var den: float = 1.0 + sin(t) * sin(t)
		fig.append(Vector2(700.0 * cos(t) / den, 700.0 * sin(t) * cos(t) / den))
		t += 0.004
	var ed2: Control = await _new_editor()
	ed2._doc["path"] = fig
	ed2._refresh()
	ed2._canvas.set_view(0.5, ed2._canvas.size * 0.5)
	ed2._set_mode(DrawCanvas.Mode.ITEM)
	var cross_s: float = 0.0  # 첫 통과(t≈π/2)의 교차점 s
	var best: float = INF
	var acc: float = 0.0
	for k in range(1, fig.size()):
		acc += fig[k - 1].distance_to(fig[k])
		if fig[k].length() < best and acc < EditorDoc.path_length(fig) * 0.5:
			best = fig[k].length()
			cross_s = acc
	var s0: float = cross_s - 150.0
	await _click_world(ed2, _point_at(fig, s0))
	_ok(_items_of(ed2).size() == 1, "item placed before crossing")
	var jumps: bool = false
	var prev: float = float(_items_of(ed2)[0]["s"])
	var cv: DrawCanvas = ed2._canvas
	var sp: Vector2 = cv.get_global_transform() * cv.world_to_screen(_point_at(fig, s0))
	_mouse_motion(sp, 0)
	_mouse_button(sp, true)
	for s in range(int(s0) + 10, int(cross_s + 150.0), 10):
		var dp: Vector2 = cv.get_global_transform() * cv.world_to_screen(_point_at(fig, float(s)))
		_mouse_motion(dp)
		var cur: float = float(_items_of(ed2)[0]["s"])
		if absf(cur - prev) > 60.0:
			jumps = true
		prev = cur
	_mouse_button(sp, false)
	await _frames(1)
	_ok(not jumps, "drag through crossing stays on the same branch")
	_ok(
		absf(prev - (cross_s + 140.0)) < 25.0,
		"passed crossing along branch (%.1f vs %.1f)" % [prev, cross_s + 140.0]
	)
	await _free_editor(ed2)
	_done.append("item_lat_cross")


func _check_item_review() -> void:
	var ed: Control = await _new_editor()
	_import(ed, _roundtrip_track())
	var path: PackedVector2Array = ed._doc["path"]
	var shifted: PackedVector2Array = path.duplicate()
	var start: int = int(shifted.size() * 0.7)
	for k in range(start, shifted.size()):
		shifted[k] += Vector2(0.0, 40.0 * clampf(float(k - start) / 60.0, 0.0, 1.0))
	ed._apply_path_edit(
		"autofix", shifted, EditorDoc.reproject_items(path, shifted, _items_of(ed)),
		PackedVector2Array()
	)
	var n: int = EditorDoc.review_count(_items_of(ed))
	_ok(n == 2, "two items need review (%d)" % n)
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	ed._set_mode(DrawCanvas.Mode.ITEM)
	var p2: Vector2 = EditorDoc.item_world(shifted, _items_of(ed)[2])
	await _click_world(ed, p2)
	_ok(ed._selected_item == 2, "review item selected")
	_ok(str(ed.get_node("ItemBar/ItemInfo").text).contains("검토 필요"), "panel shows review reason")
	_ok(ed.get_node("ItemBar/ItemConfirm").visible, "confirm-this-item button shown")
	var s_before: float = float(_items_of(ed)[2]["s"])
	await _click_world(ed, p2, [_point_at(shifted, s_before + 30.0)])
	_ok(not EditorDoc.needs_review(_items_of(ed)[2]), "moving resolves that item")
	_ok(EditorDoc.review_count(_items_of(ed)) == 1, "other review remains")
	ed._selected_item = 3
	ed.get_node("ItemBar/ItemConfirm").emit_signal("pressed")
	_ok(EditorDoc.review_count(_items_of(ed)) == 0, "confirm-this-item resolves last")
	_ok(ed._can_commit() == ed._is_validated(), "save gate reopened")
	ed._undo()
	_ok(EditorDoc.review_count(_items_of(ed)) == 1, "undo confirm restores review")
	await _free_editor(ed)
	_done.append("item_review")


func _check_fabric_width() -> void:
	var ed: Control = await _new_editor()
	var fo: OptionButton = ed._fabric_option
	var names: Array = []
	var icons_ok: bool = true
	for k in range(fo.item_count):
		names.append(fo.get_item_text(k))
		if fo.get_item_icon(k) == null:
			icons_ok = false
	_ok(names == ["면", "데님", "실크", "니트", "울", "펠트", "새틴", "가죽"], "Korean fabric names %s" % [names])
	_ok(icons_ok, "each fabric has a swatch icon")
	_ok(ed._diff_option.get_item_text(1).contains("보통"), "difficulty Korean label")
	var sw0: Texture2D = ed._fabric_swatch.texture
	fo.select(2)
	fo.item_selected.emit(2)
	_ok(str(ed._doc["fabric"]) == "silk", "fabric silk selected")
	_ok(ed._fabric_swatch.texture != null and ed._fabric_swatch.texture != sw0, "swatch updates")
	_ok(ed._width_label.text.contains("보통 프리셋"), "preset width label: " + ed._width_label.text)
	# 사용자 지정 폭 → 프리셋 전환 안내, undo
	_import(ed, _roundtrip_track())
	_ok(ed._width_label.text.contains("사용자 지정 폭 15/38/80"), "custom width label")
	ed._diff_option.select(2)
	ed._diff_option.item_selected.emit(2)
	_ok(ed._width_label.text.contains("숙련 프리셋"), "preset applied label")
	_ok(ed._status_label.text.contains("사용자 지정 폭"), "status tells preset replaced custom width")
	ed._undo()
	_ok(EditorDoc.is_custom_width(ed._doc), "undo restores custom width")
	# 폭이 줄어 |lat| > fail → 검토, 확정 시 폭 안으로
	var t: Dictionary = _roundtrip_track()
	t["items"] = [{"s": 900.0, "type": "thimble", "lat": 75.0}]
	_import(ed, t)
	ed._diff_option.select(3)
	ed._diff_option.item_selected.emit(3)
	_ok(str(_items_of(ed)[0].get("review", "")) == "lat", "lat over new fail flagged")
	_ok(float(_items_of(ed)[0]["lat"]) == 75.0, "lat not silently changed")
	ed._validate()
	_ok(not ed._can_commit(), "lat review blocks save")
	ed._set_mode(DrawCanvas.Mode.ITEM)
	ed._selected_item = 0
	ed.get_node("ItemBar/ItemConfirm").emit_signal("pressed")
	_ok(float(_items_of(ed)[0]["lat"]) == 60.0, "confirm clamps lat to fail 60")
	# 저장 → 파일 재질 → 게임 로드 재질
	_import(ed, _plain_track())
	fo.select(7)
	fo.item_selected.emit(7)
	ed._validate()
	_ok(ed._save(), "save leather track")
	var id: String = str(ed._doc["local_id"])
	_ok(str(_file_dict(id)["fabric"]) == "leather", "file fabric leather")
	_ok(TrackLoader.load_track(id).fabric == "leather", "game loader fabric leather")
	await _free_editor(ed)
	_done.append("fabric_width")


func _check_issue_list() -> void:
	var ed: Control = await _new_editor()
	_import(ed, _corner_track())
	var panel: Control = ed.get_node("IssuePanel")
	_ok(panel.visible, "issue panel shown after failed validation")
	var title: String = ed.get_node("IssuePanel/Box/Head/IssueTitle").text
	_ok(title.begins_with("저장 불가"), "title says cannot save: " + title)
	var list: VBoxContainer = ed.get_node("IssuePanel/Box/Scroll/IssueList")
	var goto_btn: Button = null
	for row in list.get_children():
		for c in row.get_children():
			if c is Button and goto_btn == null:
				goto_btn = c
	_ok(goto_btn != null, "hard issue row has a goto button")
	_ok(not ed._status_label.text.contains("px"), "status has no px unit")
	for msg in TrackValidator.new().validate(ed._doc["path"], 90.0)["messages"]:
		_ok(not str(msg).contains("px"), "validator message without px: " + str(msg))
	var serial: String = EditorDoc.serial(ed._doc)
	if goto_btn != null:
		goto_btn.emit_signal("pressed")
		var fp: PackedVector2Array = ed._canvas._focus_points
		_ok(not fp.is_empty(), "goto sets focus marker")
		var c: Vector2 = Vector2.ZERO
		for p in fp:
			c += p
		c /= float(fp.size())
		var sc: Vector2 = ed._canvas.world_to_screen(c)
		_ok(sc.distance_to(ed._canvas.size * 0.5) < 2.0, "goto centers issue position")
		_ok(float(ed._canvas.get_view()["zoom"]) >= 0.6 - 0.001, "goto zooms in to ≥ 0.6")
	_ok(EditorDoc.serial(ed._doc) == serial, "goto keeps path")
	ed.get_node("IssuePanel/Box/Head/IssueToggle").emit_signal("pressed")
	_ok(not ed.get_node("IssuePanel/Box/Scroll").visible, "issue list collapses")
	ed.get_node("IssuePanel/Box/Head/IssueToggle").emit_signal("pressed")
	# 경고가 많은 저장 가능 트랙: 목록 요약
	_import(ed, _roundtrip_track())
	title = ed.get_node("IssuePanel/Box/Head/IssueTitle").text
	_ok(title.begins_with("저장 가능"), "valid track title: " + title)
	var soft: int = EditorIssues.count(ed._issues, "soft")
	_ok(soft > EditorIssues.SOFT_ROWS, "many soft warnings (%d)" % soft)
	_ok(
		list.get_child_count() <= EditorIssues.SOFT_ROWS + 1,
		"soft rows summarized (%d rows)" % list.get_child_count()
	)
	_ok(ed._can_commit(), "soft warnings do not block save")
	await _free_editor(ed)
	_done.append("issue_list")


## 인수 검사 5번을 에디터 UI 경로로: 파일 대화상자 선택 → 아이템 도구로 추가 배치 → 저장 버튼 →
## 내보내기(원본 텍스트) → 다른 에디터에서 파일 선택으로 재가져오기 → 저장 버튼. 필드·아이템·지문 비교.
func _check_roundtrip_ui() -> void:
	var src: Dictionary = _roundtrip_track()
	var in_path: String = "user://rt_ui_in.json"
	var f: FileAccess = FileAccess.open(in_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(src))
	f.close()
	var ed: Control = await _new_editor()
	ed._import_dialog.file_selected.emit(ProjectSettings.globalize_path(in_path))
	_ok(str(ed._doc["name"]) == "Round Trip", "file dialog import")
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	ed._mode_item.emit_signal("pressed")
	ed.get_node("ItemBar/AutopilotType").emit_signal("pressed")
	await _click_world(ed, _point_at(ed._doc["path"], 1800.0))
	_ok(_items_of(ed).size() == 5, "tool adds 5th item")
	ed._validate_button.emit_signal("pressed")
	ed._save_button.emit_signal("pressed")
	var id1: String = str(ed._doc["local_id"])
	_ok(id1.begins_with("custom_") and not ed._is_dirty(), "save button saved")
	var want_items: Array = (ed._doc["items"] as Array).duplicate(true)
	var exported: String = TrackLoader.read_custom_track_text(id1)
	var out_path: String = "user://rt_ui_export.json"
	var g: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	g.store_string(exported)
	g.close()
	await _free_editor(ed)
	var ed2: Control = await _new_editor()
	ed2._import_dialog.file_selected.emit(ProjectSettings.globalize_path(out_path))
	ed2._validate_button.emit_signal("pressed")
	ed2._save_button.emit_signal("pressed")
	var id2: String = str(ed2._doc["local_id"])
	var f1: Dictionary = _file_dict(id1)
	var f2: Dictionary = _file_dict(id2)
	_ok(id2.begins_with("custom_") and id2 != id1, "re-import saved as new local track")
	_ok(_items_equal(f2["items"], want_items), "items equal after UI round trip")
	_ok(_items_equal(f1["items"], want_items), "first save items equal")
	_ok(f2["width"] == src["width"] and bool(f2["path"][0]["closed"]), "width/closed kept")
	_ok(str(f2["fabric"]) == "silk", "fabric kept")
	_ok(TrackLoader.play_fingerprint(f1) == TrackLoader.play_fingerprint(f2), "fingerprint equal")
	var pub: Dictionary = TrackLoader.build_publish_track(id2)
	_ok(bool(pub["ok"]) and (pub["track"]["items"] as Array).size() == 5, "build_publish_track ok")
	await _free_editor(ed2)
	_done.append("roundtrip_ui")


## 테스트 주행: 에디터에서 놓은 아이템이 그 위치에 나타나고 자동주행으로 획득된다. 원단도 적용된다.
func _check_play_items() -> void:
	var ed: Control = await _change_to_editor()
	_import(ed, _plain_track())
	ed._fabric_option.select(2)
	ed._fabric_option.item_selected.emit(2)
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	ed._mode_item.emit_signal("pressed")
	var path: PackedVector2Array = ed._doc["path"]
	await _click_world(ed, _point_at(path, 700.0))
	ed.get_node("ItemBar/AutopilotType").emit_signal("pressed")
	await _click_world(ed, _point_at(path, 1500.0))
	await _click_world(ed, _point_at(path, 700.0))
	var sel_before: int = ed._selected_item
	_ok(sel_before == 0, "marker selected before test")
	var placed: Array = (ed._doc["items"] as Array).duplicate(true)
	var zoom_before: float = float(ed._canvas.get_view()["zoom"])
	ed._validate()
	ed._testplay_button.emit_signal("pressed")
	_confirm_accept(ed)
	await _frames(4)
	var rd: Node = _scene()
	_ok(_scene_path() == GameState.GAMEPLAY_SCENE, "test play entered")
	_ok(rd._items.size() == 2, "race uses 2 placed items")
	var track: TrackData = rd._track
	var ok_pos: bool = true
	for k in range(2):
		var want: Vector2 = EditorDoc.item_world(path, placed[k])
		var got: Vector2 = track.point_at_s(float(rd._items[k]["s"]))
		if want.distance_to(got) > 1.0:
			ok_pos = false
	_ok(ok_pos, "item world positions match editor")
	var fabric_ok: bool = false
	for n in rd.find_children("*", "", true, false):
		if n is FabricSurface:
			fabric_ok = (n as FabricSurface).get_base_color() == FabricSurface.FABRIC_BASE["silk"]
	_ok(fabric_ok, "game fabric surface uses silk")
	# 자동주행(게임 자체 autopilot)으로 끝까지
	var t0: int = Time.get_ticks_msec()
	while int(rd._state) != 1 and Time.get_ticks_msec() - t0 < 8000:
		await _frames(1)
	Engine.time_scale = 4.0
	rd._autopilot_s = 0.0
	while int(rd._state) == 1 and Time.get_ticks_msec() - t0 < 60000:
		rd._player.autopilot_timer = 5.0
		await _frames(1)
	Engine.time_scale = 1.0
	_ok(bool(rd._collected[0]) and bool(rd._collected[1]), "both items collected on the run")
	_ok(int(rd._state) >= 2, "run finished")
	rd._go_to_result()
	await _frames(4)
	_scene()._on_menu_pressed()
	await _frames(4)
	ed = _scene() as Control
	_ok(_items_of(ed).size() == 2, "back in editor with items")
	_ok(
		ed._canvas.mode == DrawCanvas.Mode.ITEM and ed._selected_item == sel_before,
		"tool/selection kept"
	)
	_ok(is_equal_approx(float(ed._canvas.get_view()["zoom"]), zoom_before), "zoom kept")
	get_tree().unload_current_scene()
	await _frames(3)
	_done.append("play_items")

