extends "res://track_editor_regression/check_review.gd"
## v2.2.1 구간 지우기 검사: 끝쪽·시작쪽·중간 구간 지우기(실제 포인터 입력), 틈 상태의 저장·테스트·검증 차단,
## 양방향 이어 그리기, 닿지 않은 스트로크, 직선으로 잇기, 뒤쪽 버리기, 아이템 동반 제거와 s 재계산,
## undo/redo 한 단위, dirty, 닫힌 루프, 줌별 브러시 반경, 취소 시 문서 불변, 테스트 복귀 스냅샷,
## 저장 후 라운드트립 지문. check.gd 가 상속한다.


## 지우기 검사용 트랙(라운드트립 트랙과 같은 경로·아이템, closed 지정).
func _erase_track(closed: bool) -> String:
	var t: Dictionary = _roundtrip_track()
	t["path"][0]["closed"] = closed
	t["name"] = "Erase Track"
	return JSON.stringify(t)


func _new_erase_editor(closed: bool = false) -> Control:
	var ed: Control = await _new_editor()
	ed._import_from_text(_erase_track(closed))
	ed._canvas.set_view(ZOOM, ed._canvas.size * 0.5)
	return ed


## 경로에서 호길이 s0..s1 구간의 점(월드). s0 > s1이면 거꾸로.
func _path_span(path: PackedVector2Array, s0: float, s1: float) -> Array:
	var out: Array = []
	for i in range(path.size()):
		var s: float = EditorDoc.length_to(path, i)
		if s >= minf(s0, s1) and s <= maxf(s0, s1):
			out.append(path[i])
	if s0 > s1:
		out.reverse()
	return out


## 아이템 종류+lat → 월드 위치(검사 트랙은 조합이 겹치지 않는다).
func _item_worlds(doc: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for it in doc["items"]:
		out["%s|%.3f" % [str(it["type"]), float(it.get("lat", 0.0))]] = EditorDoc.item_world(
			doc["path"], it
		)
	return out


## after의 모든 아이템이 before의 같은 아이템과 tol 안에 있으면 true.
func _worlds_kept(before: Dictionary, after: Dictionary, tol: float = 0.05) -> bool:
	for k in after:
		if not before.has(k) or (after[k] as Vector2).distance_to(before[k]) > tol:
			return false
	return true


func _max_step(path: PackedVector2Array, skip_gap: int = -1) -> float:
	var m: float = 0.0
	for i in range(1, path.size()):
		if i != skip_gap:
			m = maxf(m, path[i - 1].distance_to(path[i]))
	return m


func _screen(ed: Control, w: Vector2) -> Vector2:
	return ed._canvas.get_global_transform() * ed._canvas.world_to_screen(w)


## 지우기 도구로 world_pts를 따라 문지른다(실제 포인터 입력, 누름 → 이동 → 뗌).
func _rub(ed: Control, world_pts: Array) -> void:
	ed._set_mode(DrawCanvas.Mode.ERASE)
	await _stroke(ed, world_pts)


## 원본 경로에서 현재 틈의 두 끝점 사이 점(끝점 포함). 끝점은 원본 점 그대로다.
func _gap_fill(orig: PackedVector2Array, ed: Control) -> Array:
	var path: PackedVector2Array = ed._doc["path"]
	var g: int = EditorDoc.gap_index(ed._doc)
	var ia: int = orig.find(path[g - 1])
	var ib: int = orig.find(path[g])
	var out: Array = []
	for i in range(ia, ib + 1):
		out.append(orig[i])
	return out


func _check_erase() -> void:
	await _check_erase_end_start()
	await _check_erase_mid_gap()
	await _check_erase_join()
	await _check_erase_loop_zoom()
	await _check_erase_cancel()
	await _check_erase_roundtrip()
	await _check_erase_session()
	await _check_erase_guard()
	await _check_erase_view_jump()


func _check_erase_end_start() -> void:
	var ed: Control = await _new_erase_editor()
	var cv: DrawCanvas = ed._canvas
	var orig: PackedVector2Array = ed._doc["path"]
	var total: float = EditorDoc.path_length(orig)
	var before: String = EditorDoc.serial(ed._doc)
	var worlds: Dictionary = _item_worlds(ed._doc)
	_ok(ed._mode_erase.text == "구간 지우기", "erase tool button in toolbar")
	ed._mode_erase.emit_signal("pressed")
	_ok(cv.mode == DrawCanvas.Mode.ERASE and ed._mode_erase.button_pressed, "erase tool selected")
	_ok(not ed._mode_trim.button_pressed, "trim tool unpressed")
	# 끝에서부터 문지르기: 누르는 동안 빨간 미리보기, 문서 불변
	var span: Array = _path_span(orig, total, total - 300.0)
	var n_undo: int = ed._undo_stack.size()
	_mouse_button(_screen(ed, span[0]), true)
	for w in span.slice(1):
		_mouse_motion(_screen(ed, w))
	await _frames(1)
	_ok(not (cv.erase_preview.get("segs", []) as Array).is_empty(), "rub end: red preview shown")
	_ok(EditorDoc.serial(ed._doc) == before, "rub end: doc unchanged while dragging")
	_ok(
		ed._status_label.text.contains("아이템 1개"),
		"rub end preview counts items: " + ed._status_label.text
	)
	_mouse_button(_screen(ed, span[span.size() - 1]), false)
	await _frames(1)
	var cut: PackedVector2Array = ed._doc["path"]
	var cut_len: float = EditorDoc.path_length(cut)
	_ok(cut[0] == orig[0], "end erase keeps start point")
	_ok(
		cut_len < total - 280.0 and cut_len > total - 400.0,
		"end erase cut ~300 (%d)" % int(total - cut_len)
	)
	_ok(not EditorDoc.has_gap(ed._doc), "end erase makes no gap")
	_ok((ed._doc["items"] as Array).size() == 3, "end erase removed item in section")
	_ok(
		ed._status_label.text.contains("아이템 1개"),
		"end erase reports count: " + ed._status_label.text
	)
	_ok(ed._undo_stack.size() == n_undo + 1, "end erase = one undo unit")
	_ok((cv.erase_preview as Dictionary).is_empty(), "preview cleared after release")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "end erase keeps item positions")
	# 조금 더 문지르기(옛 도구처럼 끝에서 조금씩)
	await _rub(ed, _path_span(cut, cut_len, cut_len - 100.0))
	var cut2: float = EditorDoc.path_length(ed._doc["path"])
	_ok(cut2 < cut_len - 80.0 and cut2 > cut_len - 200.0, "second rub trims a bit more")
	ed._undo()
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "undo x2 restores path + items")
	ed._redo()
	_ok(
		EditorDoc.serial(ed._doc) != before and (ed._doc["items"] as Array).size() == 3,
		"redo erase"
	)
	ed._undo()
	# 시작 쪽 문지르기: 미리보기에 새 시작점, 적용하면 시작점 이동·아이템 s 재계산(월드 위치 유지)
	var head: Array = _path_span(orig, 0.0, 300.0)
	_mouse_button(_screen(ed, head[0]), true)
	for w in head.slice(1):
		_mouse_motion(_screen(ed, w))
	await _frames(1)
	_ok(cv.erase_preview.has("start"), "start rub previews new start point")
	_ok(
		ed._status_label.text.contains("시작점"),
		"start rub announces start move: " + ed._status_label.text
	)
	_mouse_button(_screen(ed, head[head.size() - 1]), false)
	await _frames(1)
	var st: PackedVector2Array = ed._doc["path"]
	_ok(
		st[0] != orig[0] and st[st.size() - 1] == orig[orig.size() - 1],
		"start erase moves start only"
	)
	_ok(not EditorDoc.has_gap(ed._doc), "start erase makes no gap")
	_ok((ed._doc["items"] as Array).size() == 4, "start erase keeps items outside section")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "start erase: items keep world positions")
	var first_s: float = INF
	for it in ed._doc["items"]:
		first_s = minf(first_s, float(it["s"]))
	_ok(first_s < 250.0 and first_s > 100.0, "start erase: s recomputed (%d)" % int(first_s))
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "undo start erase")
	await _free_editor(ed)
	_done.append("erase_end_start")


func _check_erase_mid_gap() -> void:
	var ed: Control = await _new_erase_editor()
	ed._validate()
	_ok(ed._save(), "erase fixture saved")
	_ok(not ed._is_dirty(), "clean before erase")
	var orig: PackedVector2Array = ed._doc["path"]
	var saved: String = EditorDoc.serial(ed._doc)
	var worlds: Dictionary = _item_worlds(ed._doc)
	var n_undo: int = ed._undo_stack.size()
	await _rub(ed, _path_span(orig, 1100.0, 1300.0))
	_ok(EditorDoc.has_gap(ed._doc), "middle erase makes a gap")
	_ok(ed._undo_stack.size() == n_undo + 1, "middle erase = one undo unit")
	_ok((ed._doc["items"] as Array).size() == 3, "middle erase removed item at 1200")
	_ok(ed._status_label.text.contains("아이템 1개"), "middle erase reports count")
	_ok(ed._status_label.text.contains("틈"), "middle erase explains gap: " + ed._status_label.text)
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "gap: tail items keep world positions")
	_ok((ed.get_node("GapRow") as Control).visible, "gap row shown")
	_ok(ed._canvas._gap == EditorDoc.gap_index(ed._doc), "canvas draws the gap")
	_ok(ed._is_dirty(), "gap state is dirty")
	_ok(
		ed._doc_state_label.text.contains("틈 있음"),
		"doc state shows gap: " + ed._doc_state_label.text
	)
	# 틈 상태에서 저장·테스트·검증·루프 닫기·아이템 배치 차단
	_ok(
		ed._save_button.disabled and ed._testplay_button.disabled, "gap: save/test buttons disabled"
	)
	_ok(not ed._save(), "gap: save refused")
	_ok(ed._status_label.text.contains("틈"), "gap: save reason shown: " + ed._status_label.text)
	ed._test_play()
	_ok(not ed._confirm.visible and not GameState.is_editor_test(), "gap: test refused")
	_ok(ed._status_label.text.contains("테스트할 수 없습니다"), "gap: test reason shown")
	ed._validate()
	_ok(not ed._is_validated(), "gap: validation refused")
	_ok(ed._status_label.text.contains("검증할 수 없습니다"), "gap: validate reason shown")
	ed._canvas.grab_focus()
	_key(KEY_C)
	await _frames(1)
	_ok(
		not bool(ed._doc["closed"]) and not ed._close_toggle.button_pressed,
		"gap: loop close refused"
	)
	ed._set_mode(DrawCanvas.Mode.ITEM)
	var n_items: int = (ed._doc["items"] as Array).size()
	ed._item_tool.press(orig[20])
	_ok((ed._doc["items"] as Array).size() == n_items, "gap: item placement refused")
	var gap_serial: String = EditorDoc.serial(ed._doc)
	# 틈이 있는 상태에서 다른 중간 구간 지우기 → 적용하지 않고 안내
	var n2: int = ed._undo_stack.size()
	await _rub(ed, _path_span(orig, 450.0, 560.0))
	_ok(
		EditorDoc.serial(ed._doc) == gap_serial and ed._undo_stack.size() == n2,
		"second gap refused"
	)
	_ok(ed._status_label.text.contains("하나만"), "second gap reason: " + ed._status_label.text)
	# 틈 앞 끝을 더 지우는 것은 틈이 넓어질 뿐이라 허용
	var g: int = EditorDoc.gap_index(ed._doc)
	var a: Vector2 = (ed._doc["path"] as PackedVector2Array)[g - 1]
	var ia: int = orig.find(a)
	await _rub(ed, [orig[ia - 12], a])
	_ok(EditorDoc.has_gap(ed._doc) and EditorDoc.gap_index(ed._doc) < g, "widening gap allowed")
	ed._undo()
	# 저장 파일에 틈을 쓰지 않는다(to_track_dict에 gap 없음)
	_ok(not EditorDoc.to_track_dict(ed._doc).has("gap"), "track dict has no gap state")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == saved and not ed._is_dirty(), "undo gap: clean again")
	_ok(not (ed.get_node("GapRow") as Control).visible, "gap row hidden after undo")
	ed._redo()
	_ok(EditorDoc.has_gap(ed._doc) and ed._is_dirty(), "redo gap: gap + dirty")
	# 뒤쪽 버리기
	var n3: int = ed._undo_stack.size()
	(ed.get_node("GapRow/GapDropButton") as Button).emit_signal("pressed")
	_ok(not EditorDoc.has_gap(ed._doc), "drop tail removes gap")
	_ok(ed._undo_stack.size() == n3 + 1, "drop tail = one undo unit")
	var dropped: PackedVector2Array = ed._doc["path"]
	_ok(dropped[dropped.size() - 1] == a, "drop tail ends at gap front end")
	_ok((ed._doc["items"] as Array).size() == 1, "drop tail removed tail items")
	_ok(
		ed._status_label.text.contains("아이템 2개"),
		"drop tail reports count: " + ed._status_label.text
	)
	ed._undo()
	_ok(EditorDoc.has_gap(ed._doc), "undo drop tail restores gap")
	# 끝부분 자르기 도구와 Backspace도 틈 뒤 조각 끝에서 동작
	var len_gap: int = (ed._doc["path"] as PackedVector2Array).size()
	ed._canvas.grab_focus()
	_key(KEY_BACKSPACE)
	await _frames(1)
	_ok(
		(
			EditorDoc.has_gap(ed._doc)
			and (ed._doc["path"] as PackedVector2Array).size() == len_gap - 8
		),
		"Backspace trims tail end, gap kept"
	)
	ed._undo()
	ed._cut_to(EditorDoc.gap_index(ed._doc) + 1)
	_ok(not EditorDoc.has_gap(ed._doc), "trim into tail's first point drops tail")
	ed._undo()
	await _free_editor(ed)
	_done.append("erase_mid_gap")


func _check_erase_join() -> void:
	var ed: Control = await _new_erase_editor()
	var orig: PackedVector2Array = ed._doc["path"]
	var worlds: Dictionary = _item_worlds(ed._doc)
	await _rub(ed, _path_span(orig, 1100.0, 1300.0))
	var gap_serial: String = EditorDoc.serial(ed._doc)
	var fill: Array = _gap_fill(orig, ed)
	# 앞 끝점 → 뒤 끝점 스트로크로 잇기
	ed._set_mode(DrawCanvas.Mode.DRAW)
	var n_undo: int = ed._undo_stack.size()
	await _stroke(ed, fill)
	var joined: PackedVector2Array = ed._doc["path"]
	_ok(not EditorDoc.has_gap(ed._doc), "stroke A->B joins the gap")
	_ok(ed._undo_stack.size() == n_undo + 1, "join = one undo unit")
	_ok(
		joined[0] == orig[0] and joined[joined.size() - 1] == orig[orig.size() - 1],
		"join keeps ends"
	)
	_ok(_max_step(joined) <= 13.0, "joined path continuous (max step %.1f)" % _max_step(joined))
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "join keeps item world positions")
	_ok(
		absf(EditorDoc.path_length(joined) - EditorDoc.path_length(orig)) < 40.0,
		(
			"join restores length (%d vs %d)"
			% [EditorDoc.path_length(joined), EditorDoc.path_length(orig)]
		)
	)
	ed._validate()
	_ok(ed._is_validated(), "joined path validates: " + ed._status_label.text)
	_ok(not ed._save_button.disabled, "joined: save enabled")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == gap_serial, "undo join restores gap")
	ed._redo()
	_ok(not EditorDoc.has_gap(ed._doc), "redo join")
	ed._undo()
	# 뒤 끝점 → 앞 끝점(반대 방향)으로 그려도 경로 진행 방향으로 잇는다
	var rev: Array = fill.duplicate()
	rev.reverse()
	await _stroke(ed, rev)
	var joined2: PackedVector2Array = ed._doc["path"]
	_ok(not EditorDoc.has_gap(ed._doc), "stroke B->A joins the gap")
	_ok(
		joined2[0] == orig[0] and joined2[joined2.size() - 1] == orig[orig.size() - 1],
		"reverse join keeps direction"
	)
	_ok(_max_step(joined2) <= 13.0, "reverse join continuous")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "reverse join keeps item positions")
	ed._undo()
	# 앞 끝점에서 시작해 뒤 끝점에 닿지 않은 스트로크: 앞 조각만 늘고 틈은 남는다
	var g0: int = EditorDoc.gap_index(ed._doc)
	var half: Array = fill.slice(0, fill.size() / 2)
	await _stroke(ed, half)
	_ok(EditorDoc.has_gap(ed._doc), "partial from A: gap remains")
	_ok(EditorDoc.gap_index(ed._doc) > g0, "partial from A: front extended")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "partial from A: tail items keep positions")
	_ok(
		_max_step(ed._doc["path"], EditorDoc.gap_index(ed._doc)) <= 13.0,
		"partial from A continuous"
	)
	# 이어서 남은 틈을 채우면 이어진다
	var p1: PackedVector2Array = ed._doc["path"]
	var rest: Array = [p1[EditorDoc.gap_index(ed._doc) - 1]]
	rest.append_array(fill.slice(fill.size() / 2))
	await _stroke(ed, rest)
	_ok(not EditorDoc.has_gap(ed._doc), "second stroke closes remaining gap")
	ed._undo()
	ed._undo()
	# 뒤 끝점에서 거꾸로 그리다 만 스트로크: 뒤 조각이 앞으로 늘고 틈은 남는다
	var back: Array = fill.slice(fill.size() / 2)
	back.reverse()
	var n_before: int = (ed._doc["path"] as PackedVector2Array).size()
	await _stroke(ed, back)
	_ok(EditorDoc.has_gap(ed._doc), "partial from B: gap remains")
	_ok(EditorDoc.gap_index(ed._doc) == g0, "partial from B: front unchanged")
	_ok((ed._doc["path"] as PackedVector2Array).size() > n_before, "partial from B: tail extended")
	var pb: PackedVector2Array = ed._doc["path"]
	_ok(pb[pb.size() - 1] == orig[orig.size() - 1], "partial from B keeps path end")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "partial from B: tail items keep positions")
	_ok(_max_step(pb, EditorDoc.gap_index(ed._doc)) <= 13.0, "partial from B continuous")
	ed._undo()
	# 틈 끝점에서 먼 스트로크는 경로를 바꾸지 않고 안내
	await _stroke(ed, [Vector2(-900, 380), Vector2(-700, 390)])
	_ok(EditorDoc.serial(ed._doc) == gap_serial, "far stroke in gap state: no change")
	_ok(ed._status_label.text.contains("틈"), "far stroke explains gap: " + ed._status_label.text)
	# 직선으로 잇기
	var n4: int = ed._undo_stack.size()
	(ed.get_node("GapRow/GapJoinButton") as Button).emit_signal("pressed")
	var straight: PackedVector2Array = ed._doc["path"]
	_ok(
		not EditorDoc.has_gap(ed._doc) and ed._undo_stack.size() == n4 + 1,
		"straight join, one undo unit"
	)
	_ok(_max_step(straight) <= 13.0, "straight join continuous (6 spacing)")
	_ok(_worlds_kept(worlds, _item_worlds(ed._doc)), "straight join keeps item positions")
	_ok(ed._status_label.text.contains("직선"), "straight join status: " + ed._status_label.text)
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == gap_serial, "undo straight join")
	await _free_editor(ed)
	_done.append("erase_join")


func _check_erase_loop_zoom() -> void:
	var ed: Control = await _new_erase_editor(true)
	var cv: DrawCanvas = ed._canvas
	_ok(bool(ed._doc["closed"]), "loop fixture closed")
	var orig: PackedVector2Array = ed._doc["path"]
	var before: String = EditorDoc.serial(ed._doc)
	await _rub(ed, _path_span(orig, 1100.0, 1300.0))
	_ok(
		not bool(ed._doc["closed"]) and not ed._close_toggle.button_pressed, "loop erase opens loop"
	)
	_ok(EditorDoc.has_gap(ed._doc), "loop middle erase makes gap")
	_ok(ed._status_label.text.contains("루프"), "loop erase explains: " + ed._status_label.text)
	ed._undo()
	_ok(
		EditorDoc.serial(ed._doc) == before and bool(ed._doc["closed"]), "undo restores closed loop"
	)
	_ok(ed._close_toggle.button_pressed, "undo restores close toggle")
	var total: float = EditorDoc.path_length(orig)
	await _rub(ed, _path_span(orig, total, total - 200.0))
	_ok(
		not bool(ed._doc["closed"]) and not EditorDoc.has_gap(ed._doc),
		"loop end erase opens + trims"
	)
	ed._undo()
	await _free_editor(ed)
	# 줌별 브러시 반경(world_radius 규칙)
	ed = await _new_editor()
	cv = ed._canvas
	var expect: Dictionary = {0.04: 450.0, 0.15: 120.0, 1.0: 22.0}
	for z in expect:
		cv.set_view(z, cv.size * 0.5)
		_ok(
			is_equal_approx(ed._erase_tool.brush_radius(), float(expect[z])),
			(
				"erase brush @%.2f = %d world (%.1f)"
				% [z, int(expect[z]), ed._erase_tool.brush_radius()]
			)
		)
	await _free_editor(ed)
	ed = await _new_erase_editor()
	cv = ed._canvas
	var path: PackedVector2Array = ed._doc["path"]
	var mid: Vector2 = path[path.size() / 2]
	var serial: String = EditorDoc.serial(ed._doc)
	cv.set_view(1.0, cv.size * 0.5 - mid)
	await _rub(ed, [mid + Vector2(0, 60), mid + Vector2(1, 60)])
	_ok(EditorDoc.serial(ed._doc) == serial, "zoom 1.0: 60 world away misses")
	cv.set_view(0.15, cv.size * 0.5 - mid * 0.15)
	await _rub(ed, [mid + Vector2(0, 100), mid + Vector2(2, 100)])
	_ok(EditorDoc.has_gap(ed._doc), "zoom 0.15: 100 world away hits (tap makes gap)")
	ed._undo()
	cv.set_view(0.04, cv.size * 0.5 - mid * 0.04)
	await _rub(ed, [mid + Vector2(0, 400), mid + Vector2(10, 400)])
	_ok(EditorDoc.serial(ed._doc) != serial, "zoom 0.04: 400 world away hits")
	ed._undo()
	await _free_editor(ed)
	_done.append("erase_loop_zoom")


func _check_erase_cancel() -> void:
	var ed: Control = await _new_erase_editor()
	var cv: DrawCanvas = ed._canvas
	var cr: Rect2 = cv.get_global_rect()
	var orig: PackedVector2Array = ed._doc["path"]
	var serial: String = EditorDoc.serial(ed._doc)
	var n_undo: int = ed._undo_stack.size()
	var span: Array = _path_span(orig, 1100.0, 1300.0)
	ed._set_mode(DrawCanvas.Mode.ERASE)
	# 포커스 상실 → 취소
	_mouse_button(_screen(ed, span[0]), true)
	for w in span.slice(1):
		_mouse_motion(_screen(ed, w))
	_ok(cv.is_busy() and not (cv.erase_preview as Dictionary).is_empty(), "erase in progress")
	ed._name_edit.grab_focus()
	await _frames(1)
	_ok(
		not cv.is_busy() and (cv.erase_preview as Dictionary).is_empty(), "focus loss cancels erase"
	)
	_mouse_button(_screen(ed, span[span.size() - 1]), false)
	await _frames(1)
	_ok(
		EditorDoc.serial(ed._doc) == serial and ed._undo_stack.size() == n_undo,
		"focus loss: doc unchanged"
	)
	# 그리기 영역 밖에서 뗌 → 취소
	ed._canvas.grab_focus()
	_mouse_button(_screen(ed, span[0]), true)
	for w in span.slice(1):
		_mouse_motion(_screen(ed, w))
	var outside: Vector2 = Vector2(cr.get_center().x, cr.end.y + 40.0)
	_mouse_motion(outside)
	_mouse_button(outside, false)
	await _frames(1)
	_ok(not cv.is_busy(), "release outside: no erase state")
	_ok(
		EditorDoc.serial(ed._doc) == serial and ed._undo_stack.size() == n_undo,
		"release outside: doc unchanged"
	)
	# 뗌 누락(버튼 없이 이동) → 취소
	_mouse_button(_screen(ed, span[0]), true)
	for w in span.slice(1):
		_mouse_motion(_screen(ed, w))
	_mouse_motion(_screen(ed, span[span.size() - 1]) + Vector2(5, 5), 0)
	await _frames(1)
	_ok(not cv.is_busy(), "missed release: erase finished")
	_ok(
		EditorDoc.serial(ed._doc) == serial and ed._undo_stack.size() == n_undo,
		"missed release: doc unchanged"
	)
	# 도구 전환·실행취소 → 취소
	_mouse_button(_screen(ed, span[0]), true)
	_mouse_motion(_screen(ed, span[3]))
	ed._set_mode(DrawCanvas.Mode.DRAW)
	_ok(
		not cv.is_busy() and (cv.erase_preview as Dictionary).is_empty(),
		"tool switch cancels erase"
	)
	_mouse_button(_screen(ed, span[3]), false)
	await _frames(1)
	_ok(EditorDoc.serial(ed._doc) == serial, "tool switch: doc unchanged")
	ed._set_mode(DrawCanvas.Mode.ERASE)
	# 영역 밖으로 나갔다 들어온 구간은 브러시로 잇지 않는다
	var far_a: Vector2 = _screen(ed, orig[5])
	_mouse_button(far_a, true)
	_mouse_motion(Vector2(far_a.x, cr.end.y + 30.0))
	_mouse_motion(_screen(ed, orig[orig.size() - 6]))
	_mouse_button(_screen(ed, orig[orig.size() - 6]), false)
	await _frames(1)
	_ok(
		(ed._doc["path"] as PackedVector2Array).size() > orig.size() - 40,
		"re-entering the canvas does not sweep the whole path"
	)
	await _free_editor(ed)
	_done.append("erase_cancel")


func _check_erase_roundtrip() -> void:
	var ed: Control = await _new_erase_editor()
	var orig: PackedVector2Array = ed._doc["path"]
	var total: float = EditorDoc.path_length(orig)
	await _rub(ed, _path_span(orig, total, total - 150.0))
	await _rub(ed, _path_span(orig, 0.0, 120.0))
	ed._validate()
	_ok(ed._is_validated(), "erased track validates: " + ed._status_label.text)
	_ok(ed._save(), "erased track saved")
	var id1: String = str(ed._doc["local_id"])
	var f1: Dictionary = _file_dict(id1)
	_ok(
		not f1.has("gap") and not (f1["path"][0] as Dictionary).has("gap"),
		"saved file has no gap key"
	)
	var exported: String = TrackLoader.read_custom_track_text(id1)
	await _free_editor(ed)
	var ed2: Control = await _new_editor()
	ed2._import_from_text(exported)
	ed2._validate()
	_ok(ed2._save(), "erased track re-import save")
	var f2: Dictionary = _file_dict(str(ed2._doc["local_id"]))
	_ok(_items_equal(f1["items"], f2["items"]), "erased track items round trip")
	_ok(
		TrackLoader.play_fingerprint(f1) == TrackLoader.play_fingerprint(f2),
		"erased track play_fingerprint equal after round trip"
	)
	var pub: Dictionary = TrackLoader.build_publish_track(str(ed2._doc["local_id"]))
	_ok(bool(pub["ok"]), "erased track publishable: " + str(pub["message"]))
	await _free_editor(ed2)
	_done.append("erase_roundtrip")


## 틈을 만들고 이은 기록이 테스트 복귀 스냅샷에 남는다(undo로 틈 상태까지 돌아간다).
func _check_erase_session() -> void:
	var ed: Control = await _change_to_editor()
	ed._canvas.set_view(ZOOM, ed._canvas.size * 0.5)
	ed._import_from_text(_erase_track(false))
	ed._canvas.set_view(ZOOM, ed._canvas.size * 0.5)
	var orig: PackedVector2Array = ed._doc["path"]
	await _rub(ed, _path_span(orig, 1100.0, 1300.0))
	var gap_serial: String = EditorDoc.serial(ed._doc)
	ed._set_mode(DrawCanvas.Mode.DRAW)
	await _stroke(ed, _gap_fill(orig, ed))
	_ok(not EditorDoc.has_gap(ed._doc), "session: joined")
	ed._validate()
	ed._set_mode(DrawCanvas.Mode.ERASE)
	ed._test_play()
	_confirm_accept(ed)
	_ok(GameState.is_editor_test(), "session: test started after join")
	var snap: Dictionary = GameState.editor_session.duplicate(true)
	await _frames(3)
	var rd: Node = _scene()
	rd._toggle_pause()
	rd._to_menu()
	await _frames(3)
	ed = _scene() as Control
	_ok(_scene_path() == GameState.EDITOR_SCENE, "session: back in editor")
	_ok(ed._undo_stack.size() == (snap["undo"] as Array).size(), "session: undo restored")
	_ok(ed._canvas.mode == DrawCanvas.Mode.ERASE, "session: erase tool restored")
	ed._undo()
	_ok(
		EditorDoc.has_gap(ed._doc) and EditorDoc.serial(ed._doc) == gap_serial,
		"session: undo back to gap"
	)
	_ok(
		(ed.get_node("GapRow") as Control).visible and ed._save_button.disabled,
		"session: gap gates restored"
	)
	ed._redo()
	_ok(not EditorDoc.has_gap(ed._doc) and not ed._is_dirty(), "session: redo join, clean")
	# 메뉴 화면으로 나가지 않고 에디터 씬만 내린다(다음 검사에 입력을 가리지 않게).
	GameState.clear_editor_test()
	get_tree().unload_current_scene()
	await _frames(3)
	_done.append("erase_session")


## 진행 중 지우기 드래그를 시작한다(누름 + 이동, 떼지 않음). world_pts는 월드 좌표.
func _rub_hold(ed: Control, world_pts: Array) -> void:
	ed._set_mode(DrawCanvas.Mode.ERASE)
	ed._canvas.grab_focus()
	_mouse_button(_screen(ed, world_pts[0]), true)
	for w in world_pts.slice(1):
		_mouse_motion(_screen(ed, w))
	await _frames(1)


## 교차 리뷰 1: 드래그 중 경로·문서를 바꾸는 단축키·버튼은 진행 중 제스처를 먼저 취소한다.
func _check_erase_guard() -> void:
	var ed: Control = await _new_erase_editor()
	var cv: DrawCanvas = ed._canvas
	var orig: PackedVector2Array = ed._doc["path"]
	var total: float = EditorDoc.path_length(orig)
	# 지우기 중 Backspace: 끝 8점만 잘리고 지우기는 버려진다(짧아진 경로에 옛 index 적용 금지)
	var tail: Array = _path_span(orig, total, total - 120.0)
	var n_undo: int = ed._undo_stack.size()
	await _rub_hold(ed, tail)
	_ok(cv.is_busy() and ed._erase_tool.is_active(), "guard: erase in progress")
	_key(KEY_BACKSPACE)
	await _frames(1)
	_ok(not cv.is_busy() and not ed._erase_tool.is_active(), "guard: Backspace cancels erase")
	_mouse_button(_screen(ed, tail[tail.size() - 1]), false)
	await _frames(1)
	_ok(
		(ed._doc["path"] as PackedVector2Array).size() == orig.size() - 8,
		"guard: only Backspace trim applied (%d)" % (ed._doc["path"] as PackedVector2Array).size()
	)
	_ok(ed._undo_stack.size() == n_undo + 1, "guard: Backspace = one undo, no erase undo")
	ed._undo()
	# 지우기 중 C(루프 닫기): 닫기만 적용
	var mid_span: Array = _path_span(orig, 1100.0, 1300.0)
	await _rub_hold(ed, mid_span)
	_key(KEY_C)
	await _frames(1)
	_ok(not cv.is_busy(), "guard: C cancels erase")
	var closed_path: PackedVector2Array = ed._doc["path"]
	_mouse_button(_screen(ed, mid_span[mid_span.size() - 1]), false)
	await _frames(1)
	_ok(bool(ed._doc["closed"]) and not EditorDoc.has_gap(ed._doc), "guard: only close applied")
	_ok(ed._doc["path"] == closed_path, "guard: closed path untouched by stale erase")
	ed._undo()
	# 지우기 중 Enter(검증)·Delete(새로 그리기 확인창)·자동 수정·길이 조절·불러오기 버튼·도구 버튼
	var before: String = EditorDoc.serial(ed._doc)
	var actions: Array = [
		["Enter", func() -> void: _key(KEY_ENTER)],
		["Delete", func() -> void: _key(KEY_DELETE)],
		["autofix", func() -> void: ed._auto_fix()],
		["length", func() -> void: ed._open_length_dialog()],
		["import", func() -> void: ed._on_import_pressed()],
		["difficulty", func() -> void: ed._on_diff_changed(2)],
		["review", func() -> void: ed._confirm_reviews()],
		["tool button", func() -> void: ed._mode_draw.emit_signal("pressed")],
	]
	for a in actions:
		await _rub_hold(ed, mid_span)
		(a[1] as Callable).call()
		await _frames(1)
		_ok(not cv.is_busy() and not ed._erase_tool.is_active(), "guard: %s cancels erase" % a[0])
		_mouse_button(_screen(ed, mid_span[mid_span.size() - 1]), false)
		await _frames(1)
		_ok(not EditorDoc.has_gap(ed._doc), "guard: %s leaves no stale erase" % a[0])
		if ed._confirm.visible:
			_confirm_cancel(ed)
		if ed._length_dialog.visible:
			ed._length_dialog.hide()
		if ed._import_dialog.visible:
			ed._import_dialog.hide()
		while EditorDoc.serial(ed._doc) != before and not ed._undo_stack.is_empty():
			ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "guard: actions restored")
	# 틈 상태에서 뒤 조각을 문지르는 중 직선으로 잇기/뒤쪽 버리기: 잇기만 적용
	await _rub(ed, mid_span)
	_ok(EditorDoc.has_gap(ed._doc), "guard: gap made")
	var n_gap: int = ed._undo_stack.size()
	await _rub_hold(ed, _path_span(orig, 1900.0, 2000.0))
	(ed.get_node("GapRow/GapJoinButton") as Button).emit_signal("pressed")
	_ok(not cv.is_busy(), "guard: straight join cancels erase")
	_mouse_button(_screen(ed, orig[orig.size() - 1]), false)
	await _frames(1)
	_ok(
		not EditorDoc.has_gap(ed._doc) and ed._undo_stack.size() == n_gap + 1,
		"guard: only join applied"
	)
	ed._undo()
	await _rub_hold(ed, _path_span(orig, 1900.0, 2000.0))
	(ed.get_node("GapRow/GapDropButton") as Button).emit_signal("pressed")
	_ok(not cv.is_busy(), "guard: drop tail cancels erase")
	_mouse_button(_screen(ed, orig[orig.size() - 1]), false)
	await _frames(1)
	_ok(ed._undo_stack.size() == n_gap + 1, "guard: only drop tail applied")
	ed._undo()
	ed._undo()
	# 끝부분 자르기 중 C: 자르기 대상 index가 버려진다
	ed._set_mode(DrawCanvas.Mode.TRIM)
	var tp: Vector2 = _screen(ed, orig[orig.size() / 2])
	_mouse_button(tp, true)
	_mouse_motion(tp + Vector2(1, 0))
	_ok(ed._trim_tool.hit >= 0, "guard: trim in progress")
	_key(KEY_C)
	await _frames(1)
	_ok(not cv.is_busy() and ed._trim_tool.hit < 0, "guard: C cancels trim")
	var cp: PackedVector2Array = ed._doc["path"]
	_mouse_button(tp + Vector2(1, 0), false)
	await _frames(1)
	_ok(ed._doc["path"] == cp and bool(ed._doc["closed"]), "guard: no stale trim after close")
	ed._undo()
	# 아이템 드래그 중 Backspace(아이템 도구에서는 선택 아이템 삭제): 드래그를 먼저 되돌린 뒤 삭제한다
	ed._set_mode(DrawCanvas.Mode.ITEM)
	var it0: Dictionary = (ed._doc["items"] as Array)[0]
	var ip: Vector2 = _screen(ed, EditorDoc.item_world(orig, it0))
	var s0: float = float(it0["s"])  # 드래그 전 위치
	_mouse_button(ip, true)
	for k in range(1, 12):
		_mouse_motion(ip + Vector2(k * 4.0, 0))
	_ok(ed._item_tool._moved, "guard: item drag in progress")
	_key(KEY_BACKSPACE)
	await _frames(1)
	_ok(not cv.is_busy() and not ed._item_tool._dragging, "guard: Backspace cancels item drag")
	_mouse_button(ip + Vector2(44, 0), false)
	await _frames(1)
	_ok((ed._doc["items"] as Array).size() == 3, "guard: Backspace deleted the selected item")
	ed._undo()
	_ok(
		is_equal_approx(float((ed._doc["items"] as Array)[0]["s"]), s0),
		"guard: undo restores pre-drag position (drag was reverted, not committed)"
	)
	# 범위 검사·경로 변경 방어: 옛 index로는 지우지 않는다
	_ok(
		ed._erase_tool.plan([orig.size() + 50, -3]).is_empty(),
		"guard: out-of-range indices ignored"
	)
	var n2: int = ed._undo_stack.size()
	ed._erase_tool.begin(orig[orig.size() - 2])
	ed._doc["path"] = orig.slice(0, orig.size() - 20)
	ed._erase_tool.end()
	_ok(
		(
			ed._undo_stack.size() == n2
			and (ed._doc["path"] as PackedVector2Array).size() == orig.size() - 20
		),
		"guard: erase dropped when path changed under it"
	)
	await _free_editor(ed)
	_done.append("erase_guard")


## 교차 리뷰 2: 드래그 중 뷰가 바뀌면(포인터 아래 월드 점이 바뀌면) 이전 위치와 보간하지 않는다.
func _check_erase_view_jump() -> void:
	var ed: Control = await _new_erase_editor()
	var cv: DrawCanvas = ed._canvas
	var orig: PackedVector2Array = ed._doc["path"]
	var p1: Vector2 = Vector2(-500.0, 250.0 * sin(0.75 * PI))
	var p2: Vector2 = Vector2(-166.0, 250.0 * sin(1.25 * PI))
	var mid_i: int = 0
	for i in range(orig.size()):
		if absf(orig[i].x + 333.0) < absf(orig[mid_i].x + 333.0):
			mid_i = i
	var midp: Vector2 = orig[mid_i]
	ed._set_mode(DrawCanvas.Mode.ERASE)
	cv.grab_focus()
	var s1: Vector2 = _screen(ed, p1)
	_mouse_button(s1, true)
	_mouse_motion(s1 + Vector2(1, 0))
	# 카메라만 옮겨 같은 화면 위치가 p2를 가리키게 한다(키·버튼·휠·전체 보기와 같은 경로: set_view)
	var z: float = float(cv.get_view()["zoom"])
	var local: Vector2 = cv.get_global_transform().affine_inverse() * s1
	cv.set_view(z, local - p2 * z)
	_mouse_motion(s1 + Vector2(2, 0))
	_mouse_button(s1 + Vector2(2, 0), false)
	await _frames(1)
	_ok((ed._doc["path"] as PackedVector2Array).has(midp), "view jump: un-rubbed middle not erased")
	await _free_editor(ed)
	# + 키 줌(중앙 기준)도 같은 규칙
	ed = await _new_erase_editor()
	cv = ed._canvas
	var before: String = EditorDoc.serial(ed._doc)
	ed._set_mode(DrawCanvas.Mode.ERASE)
	cv.grab_focus()
	var a: Vector2 = _screen(ed, orig[8])
	_mouse_button(a, true)
	_mouse_motion(a + Vector2(1, 0))
	_key(KEY_MINUS)
	await _frames(1)
	_ok(cv.is_busy(), "view jump: zoom key keeps erase alive")
	_ok(cv._erase_outside, "view jump: zoom key makes next move discontinuous")
	_mouse_motion(a + Vector2(2, 0))
	var pv: Dictionary = cv.erase_preview
	var segs: Array = pv.get("segs", [])
	var red_len: float = 0.0
	for sg in segs:
		red_len += EditorDoc.path_length(sg)
	_mouse_button(a + Vector2(2, 0), false)
	await _frames(1)
	var r: float = ed._erase_tool.brush_radius()
	_ok(red_len < r * 6.0 + 200.0, "view jump: zoom key does not sweep (%d)" % int(red_len))
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "view jump: undo")
	# 휠 줌(포인터 기준)은 포인터 아래 점이 그대로라 이어서 문지른다
	cv.set_view(ZOOM, cv.size * 0.5)
	var span: Array = _path_span(orig, 1100.0, 1300.0)
	ed._set_mode(DrawCanvas.Mode.ERASE)
	cv.grab_focus()
	var w0: Vector2 = _screen(ed, span[0])
	_mouse_button(w0, true)
	_mouse_motion(w0 + Vector2(1, 0))
	var wheel: InputEventMouseButton = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = w0 + Vector2(1, 0)
	wheel.global_position = wheel.position
	wheel.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(wheel, true)
	_ok(not cv._erase_outside, "view jump: pivot wheel zoom stays continuous")
	_mouse_button(w0 + Vector2(1, 0), false)
	await _frames(1)
	ed._undo()
	await _free_editor(ed)
	# 그리기 스트로크: 뷰가 바뀌어 포인터 아래 점이 바뀌면 그때까지 그린 스트로크로 마무리한다
	ed = await _new_editor()
	cv = ed._canvas
	var d0: Vector2 = _screen(ed, Vector2(-300, 0))
	_mouse_button(d0, true)
	for k in range(1, 26):
		_mouse_motion(d0 + Vector2(k * 4.0, 0))
	var zz: float = float(cv.get_view()["zoom"])
	var loc: Vector2 = cv.get_global_transform().affine_inverse() * (d0 + Vector2(100, 0))
	cv.set_view(zz, loc - Vector2(900, 400) * zz)
	for k in range(1, 20):
		_mouse_motion(d0 + Vector2(100 + k * 4.0, 0))
	_mouse_button(d0 + Vector2(176, 0), false)
	await _frames(1)
	var dp: PackedVector2Array = ed._doc["path"]
	var far: float = 0.0
	for p in dp:
		far = maxf(far, p.distance_to(Vector2(-300, 0)))
	_ok(
		dp.size() >= 2 and far < 400.0,
		"view jump: stroke ends at jump, no straight jump line (%d)" % int(far)
	)
	_ok(not cv.is_busy(), "view jump: no drawing state left")
	await _free_editor(ed)
	_done.append("erase_view_jump")
