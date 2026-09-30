extends "res://track_editor_regression/check_base.gd"
## 편집 문서 검사: dirty/undo/redo, 단축키 비가로채기, 먼 곳 스트로크, 끝부분 자르기, 가져오기,
## 라운드트립, 트랙 열기(사본). check.gd 가 상속한다.


func _check_dirty_undo() -> void:
	var ed: Control = await _new_editor()
	_ok(not ed._is_dirty(), "new doc not dirty")
	# 이름: 연속 입력은 undo 한 단위
	for t in ["A", "AB", "ABC"]:
		ed._name_edit.text = t
		ed._name_edit.text_changed.emit(t)
	_ok(ed._is_dirty(), "name change -> dirty")
	_ok(ed._undo_stack.size() == 1, "consecutive name typing = one undo unit")
	ed._undo()
	_ok(ed._name_edit.text == "" and not ed._is_dirty(), "undo name -> clean")
	ed._redo()
	_ok(ed._name_edit.text == "ABC" and ed._is_dirty(), "redo name -> dirty again")
	ed._undo()
	# 그리기 → 검증 → 저장
	await _draw_valid(ed)
	_ok(ed._is_validated(), "drawn sine validates: " + ed._status_label.text)
	_ok(ed._is_dirty(), "drawn path -> dirty")
	_ok(ed._redo_stack.is_empty(), "new edit clears redo")
	ed._name_edit.text = "Dirty Track"
	ed._name_edit.text_changed.emit("Dirty Track")
	_ok(ed._save(), "save ok")
	var id: String = str(ed._doc["local_id"])
	_ok(id.begins_with("custom_") and not ed._is_dirty(), "saved -> clean, id " + id)
	# 이름·원단: dirty만, 검증 유지
	ed._name_edit.focus_exited.emit()
	ed._name_edit.text = "Renamed"
	ed._name_edit.text_changed.emit("Renamed")
	_ok(ed._is_dirty() and ed._is_validated(), "rename -> dirty, still validated")
	_ok(not ed._save_button.disabled, "save stays enabled after rename")
	ed._fabric_option.select(2)
	ed._fabric_option.item_selected.emit(2)
	_ok(str(ed._doc["fabric"]) == "silk" and ed._is_validated(), "fabric -> silk, still validated")
	ed._undo()
	ed._undo()
	_ok(not ed._is_dirty(), "undo fabric+rename -> clean")
	_ok(ed._fabric_option.selected == 0 and ed._name_edit.text == "Dirty Track", "widgets restored")
	# 난이도: dirty + 검증 무효화, undo로 복원
	ed._diff_option.select(2)
	ed._diff_option.item_selected.emit(2)
	_ok(ed._is_dirty() and not ed._is_validated(), "difficulty -> dirty + needs validation")
	_ok(ed._save_button.disabled and ed._testplay_button.disabled, "save/test gated after difficulty")
	_ok(float(ed._doc["width"]["fail"]) == 72.0, "difficulty applies preset width")
	ed._undo()
	_ok(not ed._is_dirty() and ed._is_validated(), "undo difficulty -> clean + validated")
	# 새로 그리기(확인 후 경로·아이템 지움, undo 복원)
	var before: String = EditorDoc.serial(ed._doc)
	ed._on_new_pressed()
	_confirm_cancel(ed)
	_ok(EditorDoc.serial(ed._doc) == before, "new-draw cancel keeps doc")
	ed._on_new_pressed()
	_confirm_accept(ed)
	_ok((ed._doc["path"] as PackedVector2Array).is_empty() and ed._is_dirty(), "new-draw clears path")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before and not ed._is_dirty(), "undo new-draw restores")
	# 저장 후 undo 해도 같은 파일에 저장(계보 id 유지)
	ed._undo_stack.clear()
	await _free_editor(ed)
	_done.append("dirty_undo")


func _check_shortcuts() -> void:
	var ed: Control = await _new_editor()
	await _draw_valid(ed)
	var n_undo: int = ed._undo_stack.size()
	var pts: int = (ed._doc["path"] as PackedVector2Array).size()
	ed._name_edit.grab_focus()
	await _frames(1)
	_key(KEY_Z, true)
	_key(KEY_Z, true, true)
	_key(KEY_BACKSPACE)
	_key(KEY_DELETE)
	_key(KEY_C)
	await _frames(1)
	_ok(ed._undo_stack.size() == n_undo, "name focus: Ctrl+Z/Backspace not intercepted")
	_ok((ed._doc["path"] as PackedVector2Array).size() == pts, "name focus: path untouched")
	_ok(not ed._confirm.visible and not bool(ed._doc["closed"]), "name focus: Delete/C ignored")
	# 확인창이 떠 있을 때도 가로채지 않는다
	ed._canvas.grab_focus()
	ed._on_new_pressed()
	_key(KEY_Z, true)
	_key(KEY_BACKSPACE)
	await _frames(1)
	_ok(
		ed._undo_stack.size() == n_undo and (ed._doc["path"] as PackedVector2Array).size() == pts,
		"confirm open: shortcuts ignored"
	)
	_confirm_cancel(ed)
	# 포커스가 캔버스면 단축키가 동작(양성 대조)
	ed._canvas.grab_focus()
	_key(KEY_BACKSPACE)
	await _frames(1)
	_ok((ed._doc["path"] as PackedVector2Array).size() < pts, "canvas focus: Backspace trims")
	_key(KEY_Z, true)
	await _frames(1)
	_ok((ed._doc["path"] as PackedVector2Array).size() == pts, "canvas focus: Ctrl+Z undoes")
	_key(KEY_Z, true, true)
	await _frames(1)
	_ok((ed._doc["path"] as PackedVector2Array).size() < pts, "canvas focus: Ctrl+Shift+Z redoes")
	await _free_editor(ed)
	_done.append("shortcuts")


func _check_far_stroke() -> void:
	var ed: Control = await _new_editor()
	await _stroke(ed, _sine_points(40.0, -1000.0, 0.0))
	var path: PackedVector2Array = ed._doc["path"]
	_ok(path.size() > 10, "first stroke drawn (%d pts)" % path.size())
	var n_undo: int = ed._undo_stack.size()
	# 끝점에서 먼 곳에서 시작한 스트로크 → 교체하지 않고 안내
	await _stroke(ed, [Vector2(-800, -350), Vector2(-400, -350), Vector2(0, -330)])
	_ok(ed._doc["path"] == path, "far stroke does not replace path")
	_ok(ed._undo_stack.size() == n_undo, "far stroke adds no undo")
	_ok(ed._status_label.text.contains("끝점"), "far stroke hint shown: " + ed._status_label.text)
	# 끝점에서 이어 그리기 → 이어 붙음
	await _stroke(ed, _sine_points(40.0, 0.0, 1000.0))
	var joined: PackedVector2Array = ed._doc["path"]
	_ok(joined.size() > path.size() and joined[0] == path[0], "continue from end appends")
	ed._validate()
	_ok(ed._is_validated(), "joined path validates: " + ed._status_label.text)
	await _free_editor(ed)
	_done.append("far_stroke")


func _check_trim() -> void:
	var ed: Control = await _new_editor()
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	var path: PackedVector2Array = ed._doc["path"]
	_ok((ed._doc["items"] as Array).size() == 4, "trim fixture has 4 items")
	# s ≈ 1500 지점 찾기
	var k: int = 0
	while k < path.size() and EditorDoc.length_to(path, k) < 1500.0:
		k += 1
	var before: String = EditorDoc.serial(ed._doc)
	ed._set_mode(DrawCanvas.Mode.TRIM)
	ed._on_trim_hover(path[k])
	var hit: int = ed._canvas._trim_from
	_ok(hit >= 0 and hit <= k, "hover previews trim from %d" % hit)
	_ok(ed._status_label.text.contains("아이템 2개"), "hover announces 2 items: " + ed._status_label.text)
	_ok(EditorDoc.serial(ed._doc) == before, "hover does not change doc")
	ed._on_trim_hover_exit()
	_ok(ed._canvas._trim_from == -1, "hover exit clears preview")
	# 실제 포인터 입력으로 자르기
	var cv: DrawCanvas = ed._canvas
	var sp: Vector2 = cv.get_global_transform() * cv.world_to_screen(path[k])
	_mouse_button(sp, true)
	_mouse_motion(sp + Vector2(2, 0))
	_mouse_button(sp + Vector2(2, 0), false)
	await _frames(1)
	var cut: PackedVector2Array = ed._doc["path"]
	_ok(cut.size() < path.size() and cut.size() >= k - 6, "pointer trim cut path (%d)" % cut.size())
	_ok((ed._doc["items"] as Array).size() == 2, "trim removed 2 items in cut section")
	_ok(ed._status_label.text.contains("아이템 2개"), "trim reports removed count")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "undo trim restores path + items")
	ed._redo()
	_ok((ed._doc["items"] as Array).size() == 2, "redo trim")
	ed._undo()
	await _free_editor(ed)
	_done.append("trim")


func _check_import() -> void:
	var ed: Control = await _new_editor()
	await _draw_valid(ed)
	ed._name_edit.text = "Mine"
	ed._name_edit.text_changed.emit("Mine")
	ed._save()
	var id: String = str(ed._doc["local_id"])
	var before: String = EditorDoc.serial(ed._doc)
	var n_undo: int = ed._undo_stack.size()
	var view: Dictionary = ed._canvas.get_view()
	# 실패: 기존 문서·ID·화면·undo 불변
	var bad_items: Dictionary = _roundtrip_track()
	bad_items["items"] = [{"s": 100.0, "type": "rocket", "lat": 0.0}]
	var bad_width: Dictionary = _roundtrip_track()
	bad_width["width"] = {"perfect": 50.0, "safe": 40.0, "fail": 30.0}
	for text in ["{not json", "[]", JSON.stringify(bad_items), JSON.stringify(bad_width)]:
		ed._import_from_text(text)
		_ok(
			(
				EditorDoc.serial(ed._doc) == before
				and str(ed._doc["local_id"]) == id
				and ed._undo_stack.size() == n_undo
				and ed._canvas.get_view() == view
				and not ed._confirm.visible
			),
			"failed import leaves doc/id/view: " + ed._status_label.text
		)
	# 저장된 상태면 확인 없이 교체, undo 한 단위로 복원
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	_ok(str(ed._doc["name"]) == "Round Trip" and str(ed._doc["local_id"]) == "", "import replaces")
	_ok(ed._is_dirty(), "imported doc is unsaved")
	_ok(str(ed._doc["fabric"]) == "silk" and ed._fabric_option.selected == 2, "import fabric silk")
	_ok(
		EditorDoc.is_custom_width(ed._doc) and ed._width_label.text.contains("사용자 지정"),
		"custom width shown"
	)
	_ok(bool(ed._doc["closed"]) and ed._close_toggle.button_pressed, "import keeps closed")
	ed._undo()
	_ok(
		EditorDoc.serial(ed._doc) == before and str(ed._doc["local_id"]) == id and not ed._is_dirty(),
		"undo import restores name/meta/id"
	)
	# 미저장 상태에서 가져오기 → 확인. 취소하면 그대로
	ed._name_edit.text = "Mine2"
	ed._name_edit.text_changed.emit("Mine2")
	var dirty_serial: String = EditorDoc.serial(ed._doc)
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	_confirm_cancel(ed)
	_ok(EditorDoc.serial(ed._doc) == dirty_serial, "import cancel keeps unsaved doc")
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	_confirm_accept(ed)
	_ok(str(ed._doc["name"]) == "Round Trip", "import confirm replaces")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == dirty_serial, "undo import restores unsaved doc")
	# modifiers: 제외하고 명시 안내
	var mods: Dictionary = _roundtrip_track()
	mods["modifiers"] = [{"s": 900, "type": "slippery", "duration": 300, "strength": 0.4}]
	ed._import_from_text(JSON.stringify(mods))
	_confirm_accept(ed)
	_ok(
		ed._status_label.text.contains("modifiers"),
		"modifiers drop announced: " + ed._status_label.text
	)
	await _free_editor(ed)
	_done.append("import")


## 가져오기 → 저장 → 내보내기 → 재가져오기 → 저장. 필드·아이템·지문 일치, 게시 형식 통과.
func _check_roundtrip() -> void:
	var src: Dictionary = _roundtrip_track()
	var ed: Control = await _new_editor()
	ed._import_from_text(JSON.stringify(src))
	ed._validate()
	_ok(ed._is_validated(), "roundtrip track validates: " + ed._status_label.text)
	_ok(ed._save(), "roundtrip save 1")
	var id1: String = str(ed._doc["local_id"])
	var f1: Dictionary = _file_dict(id1)
	_ok(f1.get("width", {}) == src["width"], "saved width preserved %s" % str(f1.get("width")))
	_ok(bool(f1["path"][0]["closed"]), "saved closed preserved")
	_ok(str(f1["fabric"]) == "silk" and str(f1["difficulty"]) == "normal", "saved meta preserved")
	_ok(_items_equal(f1.get("items", []), src["items"]), "saved items preserved")
	var exported: String = TrackLoader.read_custom_track_text(id1)
	await _free_editor(ed)
	var ed2: Control = await _new_editor()
	ed2._import_from_text(exported)
	ed2._validate()
	_ok(ed2._save(), "roundtrip save 2")
	var id2: String = str(ed2._doc["local_id"])
	var f2: Dictionary = _file_dict(id2)
	_ok(id2 != id1, "re-import saves as new local track")
	_ok(_items_equal(f2.get("items", []), src["items"]), "re-imported items preserved")
	_ok(f2["width"] == f1["width"] and bool(f2["path"][0]["closed"]), "re-imported width/closed")
	_ok(
		TrackLoader.play_fingerprint(f1) == TrackLoader.play_fingerprint(f2),
		"play_fingerprint equal after round trip"
	)
	var loaded: TrackData = TrackLoader.load_track(id2)
	var max_s: float = 0.0
	for it in loaded.items:
		max_s = maxf(max_s, float(it["s"]))
	_ok(loaded.items.size() == 4 and max_s <= loaded.length - 0.5, "loaded items within length")
	var pub: Dictionary = TrackLoader.build_publish_track(id2)
	_ok(bool(pub["ok"]), "build_publish_track ok: " + str(pub["message"]))
	if bool(pub["ok"]):
		_ok(_items_equal(pub["track"]["items"], src["items"]), "publish payload items")
		_ok(pub["track"]["width"] == src["width"], "publish payload width")
	await _free_editor(ed2)
	# 일반 가져오기(TrackLoader)도 같은 필드를 보존하고 지문이 같을 때만 duplicate
	var r1: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(src), "rt")
	var g1: Dictionary = _file_dict(str(r1["track_id"]))
	_ok(bool(r1["ok"]), "plain import ok: %s" % str(r1["message"]))
	_ok(_items_equal(g1.get("items", []), src["items"]), "plain import keeps items")
	_ok(g1.get("width", {}) == src["width"] and bool(g1["path"][0]["closed"]), "plain width/closed")
	var r2: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(src), "rt")
	_ok(
		str(r2["status"]) == "duplicate" and r2["track_id"] == r1["track_id"],
		"same content -> duplicate"
	)
	var diff_items: Dictionary = src.duplicate(true)
	(diff_items["items"] as Array).pop_back()
	var r3: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(diff_items), "rt")
	_ok(
		str(r3["status"]) == "ok" and r3["track_id"] != r1["track_id"],
		"same path, other items -> new"
	)
	var mods: Dictionary = src.duplicate(true)
	mods["modifiers"] = [{"s": 900, "type": "slippery"}]
	mods["fabric"] = "wool"
	var r4: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(mods), "rt")
	_ok(
		(
			bool(r4["ok"])
			and (r4["dropped"] as Array).has("modifiers")
			and str(r4["message"]).contains("modifiers")
		),
		"plain import drops modifiers with notice: " + str(r4["message"])
	)
	_ok((_file_dict(str(r4["track_id"]))["modifiers"] as Array).is_empty(), "saved modifiers empty")
	_done.append("roundtrip")


## 공식·허브 트랙을 열면 원본을 두고 사본으로 편집한다. 로컬 트랙은 그 파일을 편집한다.
func _check_open() -> void:
	GameState.editor_open_id = "harbor_01"
	var ed: Control = await _new_editor()
	_ok(GameState.editor_open_id == "", "open id consumed")
	_ok(str(ed._doc["local_id"]) == "" and not ed._is_dirty(), "official opens as clean copy")
	_ok((ed._doc["items"] as Array).size() == 4, "official items kept (4)")
	_ok(EditorDoc.is_custom_width(ed._doc), "harbor width kept as custom width")
	_ok(ed._needs_save(), "copy needs save before test")
	await _free_editor(ed)
	# 허브에서 받은 트랙(미편집) → 사본
	var post: Dictionary = {
		"post_id": "00000000-0000-4000-8000-000000000077",
		"title": "Hub Copy",
		"content_hash": "sha256:hubcopy",
		"track": _roundtrip_track(),
	}
	var hub: Dictionary = TrackLoader.import_hub_track(post)
	_ok(bool(hub["ok"]), "hub import for open: " + str(hub["message"]))
	var hub_id: String = str(hub["track_id"])
	GameState.editor_open_id = hub_id
	var ed2: Control = await _new_editor()
	_ok(str(ed2._doc["local_id"]) == "", "hub download opens as copy")
	ed2._validate()
	ed2._name_edit.text = "Hub Edited"
	ed2._name_edit.text_changed.emit("Hub Edited")
	_ok(ed2._save(), "hub copy saved")
	_ok(str(ed2._doc["local_id"]) != hub_id, "hub copy got new id")
	_ok(TrackLoader.is_unmodified_hub_download(hub_id), "hub original untouched")
	var own_id: String = str(ed2._doc["local_id"])
	await _free_editor(ed2)
	# 로컬 트랙은 제자리 편집
	GameState.editor_open_id = own_id
	var ed3: Control = await _new_editor()
	_ok(str(ed3._doc["local_id"]) == own_id and not ed3._is_dirty(), "own track opens in place")
	_ok((ed3._doc["items"] as Array).size() == 4, "own track items loaded")
	await _free_editor(ed3)
	_done.append("open")
