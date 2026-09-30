extends "res://track_editor_regression/check_items.gd"
## 교차 리뷰 수정 검사: 일괄 확정·저장 게이트의 실제 아이템 제약, undo/redo 선택·진행 중 제스처,
## 일반 가져오기 베이크 전 방어, 루프 닫기와 자동 수정·길이 조절, 예전 저장본 중복 판정, 긴 트랙 전체
## 보기와 최저 배율, 저장될 경로 기준 검증. check.gd 가 상속한다.


func _check_fix_bulk_resolve() -> void:
	var ed: Control = await _new_editor()
	var t: Dictionary = _roundtrip_track()
	t["items"] = [
		{"s": 600.0, "type": "thimble", "lat": 75.0},
		{"s": 1500.0, "type": "autopilot", "lat": -70.0},
		{"s": 2000.0, "type": "thimble", "lat": 0.0},
	]
	_import(ed, t)
	ed._diff_option.select(3)  # master, fail 60
	ed._diff_option.item_selected.emit(3)
	# 다른 사유(moved)가 먼저 붙은 아이템도 lat이 범위 밖이다
	_items_of(ed)[1]["review"] = "moved"
	ed._refresh()
	ed._validate()
	_ok(not ed._can_commit(), "review blocks save")
	ed._review_button.emit_signal("pressed")
	var lat_ok: bool = true
	for it in _items_of(ed):
		if absf(float(it["lat"])) > 60.0 or EditorDoc.needs_review(it):
			lat_ok = false
	_ok(lat_ok, "bulk confirm clamps lat to fail for every reason: %s" % [_items_of(ed)])
	_ok(ed._can_commit() and ed._save(), "save after bulk confirm")
	var pub: Dictionary = TrackLoader.build_publish_track(str(ed._doc["local_id"]))
	_ok(bool(pub["ok"]), "saved track publishable: " + str(pub["message"]))
	# 검토 표시가 없어도 실제 제약 위반은 저장·테스트를 막는다
	_items_of(ed)[2]["lat"] = 70.0
	ed._refresh()
	_ok(not ed._can_commit() and ed._save_button.disabled, "lat > fail blocks without review flag")
	_ok(not ed._save() and ed._status_label.text.contains("옆 거리"), "save reports lat reason")
	ed._test_play()
	_ok(not ed._confirm.visible and not GameState.is_editor_test(), "lat > fail blocks test")
	_items_of(ed)[2]["lat"] = 0.0
	_items_of(ed)[2]["s"] = EditorDoc.path_length(ed._doc["path"])
	ed._refresh()
	_ok(not ed._can_commit(), "s > L-0.5 blocks save")
	_items_of(ed)[2]["s"] = 2000.0
	var many: Array = []
	for i in range(EditorDoc.MAX_ITEMS + 1):
		many.append({"s": 100.0 + i * 10.0, "type": "thimble", "lat": 0.0})
	ed._doc["items"] = many
	ed._refresh()
	_ok(not ed._can_commit(), "129 items block save")
	ed._doc["items"] = [{"s": 500.0, "type": "rocket", "lat": 0.0}]
	ed._refresh()
	_ok(not ed._can_commit(), "unknown type blocks save")
	await _free_editor(ed)
	_done.append("fix_bulk_resolve")


func _check_fix_undo_selection() -> void:
	var ed: Control = await _new_editor()
	var t: Dictionary = _roundtrip_track()
	t["items"] = [
		{"s": 500.0, "type": "thimble", "lat": 0.0},
		{"s": 1200.0, "type": "autopilot", "lat": 0.0},
		{"s": 2000.0, "type": "thimble", "lat": 0.0},
	]
	_import(ed, t)
	ed._canvas.set_view(0.5, ed._canvas.size * 0.5)
	ed._set_mode(DrawCanvas.Mode.ITEM)
	var path: PackedVector2Array = ed._doc["path"]
	await _click_world(ed, _point_at(path, 500.0))
	ed._canvas.grab_focus()
	_key(KEY_DELETE)
	await _frames(1)
	_ok(_items_of(ed).size() == 2, "A deleted")
	await _click_world(ed, _point_at(path, 1200.0))
	_ok(ed._selected_item == 0, "B selected at index 0")
	_key(KEY_Z, true)
	await _frames(1)
	_ok(_items_of(ed).size() == 3 and ed._selected_item == -1, "undo clears selection")
	_key(KEY_DELETE)
	await _frames(1)
	_ok(_items_of(ed).size() == 3, "Delete after undo does not hit A")
	_ok(not ed._confirm.visible, "Delete without selection in item tool opens nothing")
	await _click_world(ed, _point_at(path, 1200.0))
	_key(KEY_Z, true, true)
	await _frames(1)
	_ok(_items_of(ed).size() == 2 and ed._selected_item == -1, "redo clears selection")
	ed._undo()
	# 드래그 도중 undo: 드래그를 취소(문서 불변)한 뒤 history를 적용하고, 뗄 때 늦은 스냅샷이 없다
	var n_undo: int = ed._undo_stack.size()
	var n_redo: int = ed._redo_stack.size()
	var before_drag: String = EditorDoc.serial(ed._doc)
	var cv: DrawCanvas = ed._canvas
	var sp: Vector2 = cv.get_global_transform() * cv.world_to_screen(_point_at(path, 1200.0))
	_mouse_motion(sp, 0)
	_mouse_button(sp, true)
	for s in range(1210, 1400, 20):
		_mouse_motion(cv.get_global_transform() * cv.world_to_screen(_point_at(path, float(s))))
	_ok(float(_items_of(ed)[1]["s"]) > 1300.0, "drag in progress moved item")
	ed._undo()
	_ok(
		ed._undo_stack.size() == n_undo - 1 and ed._redo_stack.size() == n_redo + 1,
		"undo during drag"
	)
	_ok(not cv.is_busy(), "drag cancelled by undo")
	ed._redo()
	_ok(EditorDoc.serial(ed._doc) == before_drag, "redo returns to pre-drag doc (drag discarded)")
	_mouse_button(sp, false)
	await _frames(1)
	_ok(
		ed._undo_stack.size() == n_undo and ed._redo_stack.size() == n_redo,
		"no late drag snapshot"
	)
	# 그리기 도중 undo: 스트로크는 버려진다
	ed._set_mode(DrawCanvas.Mode.DRAW)
	var end: Vector2 = path[path.size() - 1]
	var ep: Vector2 = cv.get_global_transform() * cv.world_to_screen(end)
	_mouse_button(ep, true)
	for k in range(1, 20):
		_mouse_motion(ep + Vector2(k * 6.0, k * 2.0))
	var r_before: int = ed._redo_stack.size()
	ed._undo()
	var after_undo: PackedVector2Array = ed._doc["path"]
	_mouse_button(ep + Vector2(120, 40), false)
	await _frames(1)
	_ok(ed._doc["path"] == after_undo, "released stroke not appended after undo")
	_ok(not cv.is_busy() and cv._active_raw.is_empty(), "stroke cancelled by undo")
	_ok(ed._redo_stack.size() == r_before + 1, "stroke release after undo adds nothing")
	await _free_editor(ed)
	_done.append("fix_undo_selection")


func _check_fix_import_guard() -> void:
	var bad_texts: Array = [
		{"path": [{"type": "polyline", "points": [[0, 0], [1000000000, 0]]}]},
		{"path": [{"type": "polyline", "points": [[0, 0], [16000, 0], [-16000, 0]]}]},
		{"path": "abc"},
		{"path": [5]},
		{"path": [{"type": "polyline", "points": [["a", 1], [2, 3]]}]},
		{"path": [{"type": "polyline", "points": [[0, 0]]}]},
		{"path": [{"type": "bezier", "p0": [0, 0], "p1": [1, 1], "p3": [2, 2]}]},
		{"path": [{"type": "spline", "points": [[0, 0], [1, 1]]}]},
	]
	var all_fail: bool = true
	var t0: int = Time.get_ticks_msec()
	for d in bad_texts:
		var r: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(d), "bad")
		var e: Dictionary = TrackLoader.prepare_edit_import(JSON.stringify(d))
		if bool(r["ok"]) or bool(e["ok"]) or str(r["message"]).is_empty():
			all_fail = false
			print("guard miss: %s -> %s / %s" % [d, r, e])
	var ms: int = Time.get_ticks_msec() - t0
	_ok(all_fail, "malformed/huge paths rejected with a message")
	_ok(ms < 2000, "rejected before baking (%d ms)" % ms)
	var r1: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(bad_texts[0]), "bad")
	_ok(str(r1["status"]) == "validation_error", "huge coordinate -> validation_error")
	# 에디터 불러오기: 문서 불변
	var ed: Control = await _new_editor()
	await _draw_valid(ed)
	var before: String = EditorDoc.serial(ed._doc)
	ed._import_from_text(JSON.stringify(bad_texts[1]))
	_ok(
		EditorDoc.serial(ed._doc) == before and ed._status_label.text.contains("너무 김"),
		"editor import rejects long raw path"
	)
	await _free_editor(ed)
	# 공식 bezier·polyline 파일은 모두 통과
	var official_ok: bool = true
	for entry in TrackLoader.list_tracks():
		var id: String = str(entry["track_id"])
		var text: String = EditorSession.track_text(id)
		if not bool(TrackLoader.prepare_edit_import(text)["ok"]):
			official_ok = false
			print("official rejected: " + id)
	_ok(official_ok, "all official tracks pass the pre-bake check")
	_done.append("fix_import_guard")


func _check_fix_close_autofix() -> void:
	var ed: Control = await _new_editor()
	var t: Dictionary = _corner_track()
	_import(ed, t)
	ed._set_closed(true)
	_ok(
		bool(ed._doc["closed"]) and (ed._doc["pre_close"] as PackedVector2Array).size() > 2,
		"closed"
	)
	var closed_serial: String = EditorDoc.serial(ed._doc)
	ed._auto_fix()
	_confirm_accept(ed)
	var fixed: PackedVector2Array = ed._doc["path"]
	_ok((ed._doc["pre_close"] as PackedVector2Array).is_empty(), "auto fix invalidates pre_close")
	var items_fixed: Array = (_items_of(ed) as Array).duplicate(true)
	ed._set_closed(false)
	_ok(ed._doc["path"] == fixed and not bool(ed._doc["closed"]), "unclose keeps fixed path")
	_ok(_items_equal(_items_of(ed), items_fixed, 0.01), "unclose keeps items on the fixed path")
	ed._undo()
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == closed_serial, "undo x2 back to closed pre-fix")
	# 닫기 → 해제(편집 없음): 경로는 닫기 전으로, 아이템 s는 그대로이고 검토 없음
	var items_closed: Array = (_items_of(ed) as Array).duplicate(true)
	ed._set_closed(false)
	_ok(
		(ed._doc["path"] as PackedVector2Array).size() > fixed.size() - 50,
		"unclose restores pre-close path"
	)
	_ok(
		_items_equal(_items_of(ed), items_closed, 0.01) and EditorDoc.review_count(_items_of(ed)) == 0,
		"unclose without edits keeps items"
	)
	ed._undo()
	# 닫힌 상태에서 길이 조절 → 해제: pre_close도 같은 배율, 아이템 제약 유지
	_import(ed, _roundtrip_track())
	_ok(bool(ed._doc["closed"]), "roundtrip track closed")
	ed._set_closed(false)
	ed._set_closed(true)
	ed._open_length_dialog()
	ed._length_dialog.set_target(3200.0)
	ed._length_dialog.hide()
	ed._length_dialog.confirmed.emit()
	var len_closed: float = EditorDoc.path_length(ed._doc["path"])
	var pre_len: float = EditorDoc.path_length(ed._doc["pre_close"])
	_ok(
		pre_len >= len_closed - 1.0,
		"pre_close scaled with path (%.0f >= %.0f)" % [pre_len, len_closed]
	)
	ed._set_closed(false)
	var len_open: float = EditorDoc.path_length(ed._doc["path"])
	var gate: String = EditorDoc.items_problem(
		_items_of(ed), len_open, float(ed._doc["width"]["fail"])
	)
	_ok(
		gate.is_empty() or EditorDoc.review_count(_items_of(ed)) > 0,
		"items valid or flagged after unclose"
	)
	await _free_editor(ed)
	_done.append("fix_close_autofix")


func _check_fix_dup_legacy() -> void:
	# 예전 버전 저장본: 점 간격 12(재표본화 전), items 키 없음
	var pts: Array = []
	for v in _sine_points(12.0):
		pts.append([snappedf(v.x, 0.1), snappedf(v.y, 0.1)])
	var legacy: Dictionary = {
		"track_id": "",
		"name": "Legacy",
		"difficulty": "normal",
		"fabric": "denim",
		"width": {"perfect": 18, "safe": 42, "fail": 90},
		"path": [{"type": "polyline", "points": pts, "closed": false}],
		"modifiers": [],
	}
	var id: String = TrackLoader.save_custom_track(legacy)
	var text: String = TrackLoader.read_custom_track_text(id)
	_ok(not (JSON.parse_string(text) as Dictionary).has("items"), "legacy file has no items key")
	var r: Dictionary = TrackLoader.import_custom_from_text(text, "legacy")
	_ok(
		str(r["status"]) == "duplicate" and str(r["track_id"]) == id,
		"legacy re-import -> duplicate %s" % r
	)
	# 간격이 6을 조금 넘는(4.3, 4.2) 점 열
	var odd: Array = []
	for k in range(420):
		odd.append([snappedf(k * 4.3, 0.1), snappedf(k * 4.2, 0.1)])
	var t2: Dictionary = legacy.duplicate(true)
	t2["path"] = [{"type": "polyline", "points": odd, "closed": false}]
	var id2: String = TrackLoader.save_custom_track(t2)
	var r2: Dictionary = TrackLoader.import_custom_from_text(
		TrackLoader.read_custom_track_text(id2), "odd"
	)
	_ok(
		str(r2["status"]) == "duplicate" and str(r2["track_id"]) == id2,
		"6.01-gap file -> duplicate"
	)
	# 같은 경로라도 아이템이 다르면 새 트랙
	var t3: Dictionary = JSON.parse_string(text)
	t3["items"] = [{"s": 700.0, "type": "thimble", "lat": 0.0}]
	var r3: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(t3), "legacy+item")
	_ok(str(r3["status"]) == "ok" and str(r3["track_id"]) != id, "different items -> new track")
	_done.append("fix_dup_legacy")


func _straight_track(vertical: bool, length: float) -> Dictionary:
	var pts: Array = []
	var y: float = 0.0
	while y <= length + 0.001:
		pts.append([0.0, snappedf(y, 0.1)] if vertical else [snappedf(y, 0.1), 0.0])
		y += 6.0
	var t: Dictionary = _plain_track()
	t["path"] = [{"type": "polyline", "points": pts, "closed": false}]
	t["difficulty"] = "beginner"
	t["width"] = {"perfect": 22.0, "safe": 52.0, "fail": 108.0}
	return t


func _check_fix_fit_zoom() -> void:
	for vertical in [true, false]:
		var ed: Control = await _new_editor()
		_import(ed, _straight_track(vertical, 7998.0))
		var label: String = "vertical" if vertical else "horizontal"
		_ok(_path_visible(ed, 108.0), "%s 8000 straight fits after import" % label)
		# 844×390 터치 레이아웃의 그리기 영역(기준 해상도 약 1264×454)에서도 들어간다
		var cv: DrawCanvas = ed._canvas
		var real: Vector2 = cv.size
		cv.size = Vector2(1264.0, 454.0)
		ed._fit_view()
		_ok(
			_path_visible(ed, 108.0),
			"%s 8000 fits the touch canvas (zoom %.3f)" % [label, float(cv.get_view()["zoom"])]
		)
		cv.size = real
		await _free_editor(ed)
	var ed2: Control = await _new_editor_raw()
	_ok(
		is_equal_approx(float(ed2._canvas.get_view()["zoom"]), DrawCanvas.ZOOM_DEFAULT),
		"new doc still 0.15"
	)
	for _i in range(20):
		ed2._zoom_out_button.emit_signal("pressed")
	_ok(
		is_equal_approx(float(ed2._canvas.get_view()["zoom"]), DrawCanvas.ZOOM_MIN),
		"manual zoom-out reaches ZOOM_MIN"
	)
	_ok(
		is_equal_approx(ed2._canvas.world_radius(ed2.SNAP_PX, ed2.SNAP_RADIUS), 600.0),
		"snap @0.04 = 600 world (24px)"
	)
	await _free_editor(ed2)
	# 최저 배율에서 그린 곡선 품질(0.25와 비교)
	var big: Array = []
	var x: float = -2400.0
	while x <= 2400.001:
		big.append(Vector2(x, 700.0 * sin((x + 2400.0) / 4800.0 * 3.0 * PI)))
		x += 4.0
	var res: Dictionary = {}
	for z in [0.25, DrawCanvas.ZOOM_MIN]:
		var e: Control = await _new_editor_raw()
		e._canvas.set_view(z, e._canvas.size * 0.5)
		await _stroke(e, big)
		res[z] = e._doc["path"]
		await _free_editor(e)
	var v: TrackValidator = TrackValidator.new()
	var r_ref: Dictionary = v.validate(res[0.25], 90.0)
	var r_min: Dictionary = v.validate(res[DrawCanvas.ZOOM_MIN], 90.0)
	print("zoom-min quality: ref minR=%.1f hard=%d | 0.04 minR=%.1f hard=%d dev=%.1f" % [
		float(r_ref["min_radius"]), _hard(r_ref), float(r_min["min_radius"]), _hard(r_min),
		_max_dev(res[DrawCanvas.ZOOM_MIN], res[0.25])
	])
	_ok(_max_spacing(res[DrawCanvas.ZOOM_MIN]) <= 6.05, "spacing ≤ 6 at zoom 0.04")
	_ok(_hard(r_min) == 0, "no hard curvature at zoom 0.04")
	_ok(
		_max_dev(res[DrawCanvas.ZOOM_MIN], res[0.25]) <= 2.0 / DrawCanvas.ZOOM_MIN,
		"0.04 shape within 2px"
	)
	_done.append("fix_fit_zoom")


## 편집 경로는 통과하지만 0.1 격자로 저장될 경로는 하한(1500) 아래가 되는 트랙과, 저장될 경로 길이
## 기준으로 s 상한을 넘는 아이템.
func _check_fix_saved_path() -> void:
	var ed: Control = await _new_editor()
	var jit: PackedVector2Array = PackedVector2Array()
	var k: int = 0
	var x: float = 0.0
	while x < 1494.001:
		jit.append(Vector2(x, 0.04 if k % 2 == 0 else -0.04))
		x += 6.0
		k += 1
	jit.append(Vector2(1499.9, 0.0))
	ed._doc["path"] = jit
	ed._refresh()
	ed._validate()
	var edit_len: float = EditorDoc.path_length(jit)
	_ok(ed._is_validated() and edit_len >= 1500.0, "edit path passes (%.3f)" % edit_len)
	_ok(not ed._save(), "save blocked when saved path fails")
	_ok(ed._status_label.text.contains("저장될 경로"), "reason shown: " + ed._status_label.text)
	# 아이템 s: 편집 길이 기준으로는 허용, 저장될 경로 길이 기준으로는 초과
	var jit2: PackedVector2Array = PackedVector2Array()
	k = 0
	x = 0.0
	while x < 2600.001:
		jit2.append(Vector2(x, 0.04 if k % 2 == 0 else -0.04))
		x += 6.0
		k += 1
	ed._doc["path"] = jit2
	var l2: float = EditorDoc.path_length(jit2)
	ed._doc["items"] = [{"s": l2 - 0.5, "type": "thimble", "lat": 0.0}]
	ed._refresh()
	ed._validate()
	_ok(ed._can_commit(), "edit-length gate passes")
	_ok(
		not ed._save() and ed._status_label.text.contains("저장될 경로 기준"),
		"saved-length item bound: " + ed._status_label.text
	)
	ed._doc["items"] = [{"s": 1000.0, "type": "thimble", "lat": 0.0}]
	ed._refresh()
	_ok(ed._save(), "valid saved path saves")
	await _free_editor(ed)
	_done.append("fix_saved_path")
