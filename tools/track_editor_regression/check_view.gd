extends "res://track_editor_regression/check_doc.gd"
## 둘째 묶음 검사: 화면 도구·줌·히트 영역·입력 상태, 줌아웃 곡선 품질, 트랙 길이 조절, 자동 수정 미리보기,
## 아이템 재투영·검토 필요, 게시 s 클램프, 트랙 선택 "편집" 진입. check.gd 가 상속한다.

const LENGTH_TOL: float = 1.5  # 길이 조절 결과 허용 오차(월드). 재샘플 후 한 번 보정한다.
const SelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")


func _new_editor_raw() -> Control:
	var ed: Control = EditorScene.instantiate()
	add_child(ed)
	await _frames(3)
	return ed


## 경로의 모든 점(+ margin)이 캔버스 화면 안에 보이면 true.
func _path_visible(ed: Control, margin: float = 0.0) -> bool:
	var cv: DrawCanvas = ed._canvas
	var r: Rect2 = Rect2(Vector2.ZERO, cv.size).grow(0.5)
	for p in ed._doc["path"]:
		var sp: Vector2 = cv.world_to_screen(p)
		if not r.has_point(sp):
			return false
		if margin > 0.0 and not r.grow(-margin * float(cv.get_view()["zoom"]) + 1.0).has_point(sp):
			return false
	return true


func _check_view() -> void:
	var ed: Control = await _new_editor_raw()
	var cv: DrawCanvas = ed._canvas
	_ok(
		is_equal_approx(float(cv.get_view()["zoom"]), DrawCanvas.ZOOM_DEFAULT),
		"new doc zoom = 0.15"
	)
	_ok(ed._zoom_label.text == "15%", "zoom label 15%: " + ed._zoom_label.text)
	# 그리기 영역: 툴바·상태줄 아래, 안내줄·하단 패널 위
	var cr: Rect2 = cv.get_global_rect()
	var tb: Rect2 = (ed.get_node("ToolbarBg") as Control).get_global_rect()
	var st: Rect2 = ed._status_label.get_global_rect()
	var meta: Rect2 = (ed.get_node("MetaBg") as Control).get_global_rect()
	var hint: Rect2 = (ed.get_node("HintLabel") as Control).get_global_rect()
	_ok(
		cr.position.y >= tb.end.y and cr.position.y >= st.end.y,
		"canvas below toolbar/status %s" % cr
	)
	_ok(
		cr.end.y <= meta.position.y and cr.end.y <= hint.position.y,
		"canvas above hint/meta %s" % cr
	)
	_ok(cr.size.y > 300.0, "canvas keeps drawing height (%d)" % int(cr.size.y))
	var vb: Rect2 = (ed.get_node("ViewBar") as Control).get_global_rect()
	_ok(cr.encloses(vb), "view bar inside canvas area")
	var tbar: Control = ed.get_node("Toolbar")
	_ok(tbar.get_global_rect().end.x <= 1280.0 + 0.5, "toolbar within 1280")
	_ok(tbar.size.y < 60.0, "toolbar is one row at 1280 (%d)" % int(tbar.size.y))
	# 열기(공식 큰 트랙) → 전체 보기
	await _free_editor(ed)
	GameState.editor_open_id = "harbor_01"
	ed = await _new_editor_raw()
	cv = ed._canvas
	_ok(_path_visible(ed, float(ed._doc["width"]["fail"])), "harbor open: path + fail inside view")
	_ok(float(cv.get_view()["zoom"]) > DrawCanvas.ZOOM_DEFAULT, "harbor fit zoom > min")
	# 불러오기 → 전체 보기
	cv.set_view(2.0, Vector2(-3000, -3000))
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	if ed._confirm.visible:
		_confirm_accept(ed)
	_ok(_path_visible(ed, 80.0), "import: path + fail inside view")
	# 화면 조작 전후 경로 좌표 불변, undo 없음
	var serial: String = EditorDoc.serial(ed._doc)
	var n_undo: int = ed._undo_stack.size()
	var z0: float = float(cv.get_view()["zoom"])
	ed._zoom_in_button.emit_signal("pressed")
	_ok(
		is_equal_approx(float(cv.get_view()["zoom"]), z0 * DrawCanvas.ZOOM_BUTTON_STEP),
		"+ button zooms in"
	)
	_ok(
		ed._zoom_label.text == "%d%%" % roundi(z0 * 140.0),
		"zoom label follows: " + ed._zoom_label.text
	)
	ed._zoom_out_button.emit_signal("pressed")
	ed._zoom_out_button.emit_signal("pressed")
	_ok(float(cv.get_view()["zoom"]) < z0, "- button zooms out")
	for _i in range(20):
		ed._zoom_out_button.emit_signal("pressed")
	_ok(
		is_equal_approx(float(cv.get_view()["zoom"]), DrawCanvas.ZOOM_MIN),
		"zoom-out clamps at ZOOM_MIN 0.04"
	)
	ed._fit_button.emit_signal("pressed")
	_ok(_path_visible(ed, 80.0), "fit button: path inside view")
	# 화면 이동 도구(실제 드래그)
	ed._mode_pan.emit_signal("pressed")
	_ok(cv.mode == DrawCanvas.Mode.PAN and ed._mode_pan.button_pressed, "pan tool selected")
	var pan0: Vector2 = cv.get_view()["pan"]
	var c: Vector2 = cr.get_center()
	_mouse_button(c, true)
	_mouse_motion(c + Vector2(40, 25))
	_mouse_motion(c + Vector2(80, 50))
	_mouse_button(c + Vector2(80, 50), false)
	await _frames(1)
	_ok(
		(cv.get_view()["pan"] as Vector2).is_equal_approx(pan0 + Vector2(80, 50)),
		"pan tool drag moves camera %s" % str(cv.get_view()["pan"])
	)
	_ok(
		EditorDoc.serial(ed._doc) == serial and ed._undo_stack.size() == n_undo,
		"camera ops keep path coords and add no undo"
	)
	_ok(not cv.is_busy(), "pan drag leaves no input state")
	# 키보드 +/−/F
	ed._canvas.grab_focus()
	var z1: float = float(cv.get_view()["zoom"])
	_key(KEY_EQUAL)
	await _frames(1)
	_ok(float(cv.get_view()["zoom"]) > z1, "= key zooms in")
	_key(KEY_F)
	await _frames(1)
	_ok(_path_visible(ed, 80.0), "F key fits")
	await _free_editor(ed)
	_done.append("view")


func _check_hit_zoom() -> void:
	var ed: Control = await _new_editor_raw()
	var cv: DrawCanvas = ed._canvas
	_ok(
		is_equal_approx(cv.world_radius(ed.SNAP_PX, ed.SNAP_RADIUS), 160.0),
		"snap @0.15 = 160 world"
	)
	_ok(
		is_equal_approx(cv.world_radius(ed.TRIM_PX, ed.TRIM_RADIUS), 120.0),
		"trim @0.15 = 120 world"
	)
	cv.set_view(1.0, cv.size * 0.5)
	_ok(is_equal_approx(cv.world_radius(ed.SNAP_PX, ed.SNAP_RADIUS), 28.0), "snap @1.0 = 28 world")
	_ok(is_equal_approx(cv.world_radius(ed.TRIM_PX, ed.TRIM_RADIUS), 22.0), "trim @1.0 = 22 world")
	# zoom 0.15: 끝점에서 100 월드(화면 15px) 떨어져 시작해도 이어 그린다
	cv.set_view(DrawCanvas.ZOOM_DEFAULT, cv.size * 0.5)
	await _stroke(ed, _sine_points(40.0, -1000.0, 0.0))
	var n0: int = (ed._doc["path"] as PackedVector2Array).size()
	var end0: Vector2 = (ed._doc["path"] as PackedVector2Array)[n0 - 1]
	await _stroke(ed, [end0 + Vector2(60, 80), end0 + Vector2(600, 80), end0 + Vector2(1200, 0)])
	_ok(
		(ed._doc["path"] as PackedVector2Array).size() > n0,
		"zoom 0.15: 100-world gap still continues"
	)
	# zoom 1.0: 같은 100 월드 간격은 거부
	ed._undo()
	cv.set_view(1.0, cv.size * 0.5 - end0)
	await _stroke(ed, [end0 + Vector2(60, 80), end0 + Vector2(300, 80), end0 + Vector2(500, 60)])
	_ok((ed._doc["path"] as PackedVector2Array).size() == n0, "zoom 1.0: 100-world gap rejected")
	# 자르기 히트: zoom 0.15에서 경로 옆 80 월드(화면 12px)도 잡힌다, zoom 1.0에서는 안 잡힌다
	var mid: Vector2 = (ed._doc["path"] as PackedVector2Array)[n0 / 2]
	cv.set_view(DrawCanvas.ZOOM_DEFAULT, cv.size * 0.5)
	_ok(ed._trim_hit_index(mid + Vector2(0, 80)) >= 0, "zoom 0.15: trim hit within 12px")
	cv.set_view(1.0, cv.size * 0.5 - mid)
	_ok(ed._trim_hit_index(mid + Vector2(0, 80)) < 0, "zoom 1.0: trim miss at 80 world")
	await _free_editor(ed)
	_done.append("hit_zoom")


func _check_pointer_release() -> void:
	var ed: Control = await _new_editor()
	var cv: DrawCanvas = ed._canvas
	var cr: Rect2 = cv.get_global_rect()
	# 그리기 영역 밖(하단 패널 위)에서 떼도 스트로크가 마무리되고 상태가 남지 않는다
	var a: Vector2 = cv.get_global_transform() * cv.world_to_screen(Vector2(-600, 0))
	_mouse_button(a, true)
	for k in range(1, 60):
		_mouse_motion(a + Vector2(k * 8.0, k * 5.0))
	var outside: Vector2 = Vector2(a.x + 480.0, cr.end.y + 40.0)
	_mouse_motion(outside)
	_mouse_button(outside, false)
	await _frames(1)
	_ok(not cv.is_busy() and cv._active_raw.is_empty(), "release outside: no drawing state")
	_ok((ed._doc["path"] as PackedVector2Array).size() > 10, "release outside: stroke committed")
	# 뗌 이벤트 누락(버튼 없이 이동) → 마무리
	ed._undo()
	_mouse_button(a, true)
	for k in range(1, 40):
		_mouse_motion(a + Vector2(k * 8.0, 0))
	_mouse_motion(a + Vector2(400, 20), 0)
	await _frames(1)
	_ok(not cv.is_busy(), "missed release: finished on buttonless motion")
	# 포커스를 잃으면 진행 중 그리기를 버린다(문서 불변)
	ed._undo()
	var serial: String = EditorDoc.serial(ed._doc)
	_mouse_button(a, true)
	for k in range(1, 30):
		_mouse_motion(a + Vector2(k * 8.0, 0))
	_ok(cv.is_busy(), "drawing in progress")
	ed._name_edit.grab_focus()
	await _frames(1)
	_ok(not cv.is_busy() and cv._active_raw.is_empty(), "focus loss cancels drawing")
	_mouse_button(a + Vector2(240, 0), false)
	await _frames(1)
	_ok(EditorDoc.serial(ed._doc) == serial, "cancelled stroke leaves doc unchanged")
	# 확인창이 뜨면 진행 중 입력을 버린다
	ed._canvas.grab_focus()
	await _stroke(ed, _sine_points(40.0))
	_mouse_button(a, true)
	_mouse_motion(a + Vector2(30, 0))
	ed._on_new_pressed()
	_ok(not cv.is_busy(), "confirm dialog cancels drawing")
	_confirm_cancel(ed)
	_mouse_button(a + Vector2(30, 0), false)
	await _free_editor(ed)
	_done.append("pointer_release")


## 두 번째 사인: x -600..600, 진폭 200, 1.5주기(최소반경 약 81, 길이 약 1900).
func _sine_small(step: float) -> Array:
	var out: Array = []
	var x: float = -600.0
	while x <= 600.001:
		out.append(Vector2(x, 200.0 * sin((x + 600.0) / 1200.0 * 3.0 * PI)))
		x += step
	return out


func _max_spacing(path: PackedVector2Array) -> float:
	var m: float = 0.0
	for i in range(1, path.size()):
		m = maxf(m, path[i - 1].distance_to(path[i]))
	return m


## a의 각 점에서 폴리라인 b까지 최대 거리.
func _max_dev(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var m: float = 0.0
	for p in a:
		m = maxf(m, float(EditorDoc.project_on_path(b, p)["dist"]))
	return m


func _draw_at_zoom(zoom: float) -> PackedVector2Array:
	var ed: Control = await _new_editor_raw()
	ed._canvas.set_view(zoom, ed._canvas.size * 0.5)
	await _stroke(ed, _sine_small(2.0))
	var path: PackedVector2Array = ed._doc["path"]
	await _free_editor(ed)
	return path


func _check_stroke_quality() -> void:
	var p1: PackedVector2Array = await _draw_at_zoom(1.0)
	var p015: PackedVector2Array = await _draw_at_zoom(DrawCanvas.ZOOM_DEFAULT)
	var v: TrackValidator = TrackValidator.new()
	var r1: Dictionary = v.validate(p1, 90.0)
	var r015: Dictionary = v.validate(p015, 90.0)
	# 개선 전 동작(원시 간격 정규화 없음)을 같은 원시 입력으로 재현해 비교 기록한다.
	var raw: PackedVector2Array = PackedVector2Array()
	var step: float = DrawCanvas.MIN_SAMPLE_PX / DrawCanvas.ZOOM_DEFAULT
	var acc: float = 0.0
	var pts: Array = _sine_small(2.0)
	raw.append(pts[0])
	for i in range(1, pts.size()):
		acc += (pts[i] as Vector2).distance_to(pts[i - 1])
		if acc >= step:
			raw.append(pts[i])
			acc = 0.0
	var old: PackedVector2Array = StrokeProcessor.new().process(raw, false)
	var r_old: Dictionary = v.validate(old, 90.0)
	print(
		(
			"stroke quality: zoom1 pts=%d len=%.1f minR=%.1f hardCurv=%d"
			+ " | zoom0.15 pts=%d len=%.1f minR=%.1f hardCurv=%d maxdev=%.2f"
			+ " | old@0.15 minR=%.1f hardCurv=%d"
		)
		% [
			p1.size(), float(r1["length"]), float(r1["min_radius"]), _hard(r1),
			p015.size(), float(r015["length"]), float(r015["min_radius"]), _hard(r015),
			_max_dev(p015, p1), float(r_old["min_radius"]), _hard(r_old)
		]
	)
	_ok(_max_spacing(p1) <= 6.05 and _max_spacing(p015) <= 6.05, "point spacing ≤ 6 at both zooms")
	_ok(_hard(r1) == 0 and _hard(r015) == 0, "no hard curvature at either zoom")
	_ok(
		absf(float(r015["length"]) - float(r1["length"])) <= float(r1["length"]) * 0.02,
		"lengths within 2%"
	)
	_ok(
		float(r015["min_radius"]) >= float(r1["min_radius"]) * 0.75,
		"zoom 0.15 min radius ≥ 75% of zoom 1.0"
	)
	# 12 월드 = zoom 0.15에서 화면 1.8px(그릴 때 손 떨림보다 작다).
	_ok(_max_dev(p015, p1) <= 12.0, "zoom 0.15 shape within 12 world of zoom 1.0")
	_check_jitter_quality()
	_done.append("stroke_quality")


## 손떨림 모사: 화면 기준 ±1px 흔들림(zoom 0.15에서는 ±6.7 월드)을 넣은 같은 곡선을 원시 간격 4px로
## 샘플해 처리한다. 정규화(원시 간격 전달)가 있으면 zoom 0.15 결과도 zoom 1.0 수준의 곡률을 유지해야 한다.
func _check_jitter_quality() -> void:
	var v: TrackValidator = TrackValidator.new()
	var proc: StrokeProcessor = StrokeProcessor.new()
	var res: Dictionary = {}
	var dev: Dictionary = {}
	var truth: PackedVector2Array = PackedVector2Array(_sine_small(1.0))
	for z in [1.0, DrawCanvas.ZOOM_DEFAULT]:
		var raw: PackedVector2Array = _jitter_raw(z)
		var step: float = DrawCanvas.MIN_SAMPLE_PX / z
		var pn: PackedVector2Array = proc.process(raw, false, StrokeProcessor.CLOSE_GAP, step)
		var po: PackedVector2Array = proc.process(raw, false)
		res[str(z) + "new"] = v.validate(pn, 90.0)
		res[str(z) + "old"] = v.validate(po, 90.0)
		dev[str(z) + "new"] = _max_dev(pn, truth)
		dev[str(z) + "old"] = _max_dev(po, truth)
	var k1: String = str(1.0) + "new"
	var kn: String = str(DrawCanvas.ZOOM_DEFAULT) + "new"
	var ko: String = str(DrawCanvas.ZOOM_DEFAULT) + "old"
	print(
		(
			"jitter quality: zoom1 minR=%.1f hard=%d dev=%.2f | zoom0.15 minR=%.1f hard=%d dev=%.2f"
			+ " | old@0.15 minR=%.1f hard=%d dev=%.2f"
		)
		% [
			float(res[k1]["min_radius"]), _hard(res[k1]), float(dev[k1]),
			float(res[kn]["min_radius"]), _hard(res[kn]), float(dev[kn]),
			float(res[ko]["min_radius"]), _hard(res[ko]), float(dev[ko])
		]
	)
	_ok(_hard(res[kn]) == 0, "jittered zoom 0.15 stroke: no hard curvature")
	_ok(
		float(res[kn]["min_radius"]) >= float(res[k1]["min_radius"]) * 0.6,
		"jittered zoom 0.15 min radius comparable to zoom 1.0"
	)
	# 이전 파이프라인은 줌아웃에서 이동평균이 원시 점 단위(26.7 월드 간격)로 걸려 곡선을 더 뭉개므로
	# 반경은 커 보여도 의도한 곡선에서 더 멀어진다. 정규화 결과가 의도 곡선에 더 가까워야 한다.
	_ok(float(dev[kn]) < float(dev[ko]), "zoom 0.15 closer to intended curve than old pipeline")
	_ok(
		float(dev[kn]) <= 2.0 * DrawCanvas.ZOOM_DEFAULT ** -1.0,
		"zoom 0.15 deviation within 2px jitter"
	)


func _jitter_raw(zoom: float) -> PackedVector2Array:
	var step: float = DrawCanvas.MIN_SAMPLE_PX / zoom
	var pts: Array = _sine_small(0.5)
	var raw: PackedVector2Array = PackedVector2Array([pts[0]])
	var acc: float = 0.0
	var k: int = 0
	for i in range(1, pts.size()):
		acc += (pts[i] as Vector2).distance_to(pts[i - 1])
		if acc >= step:
			k += 1
			var jx: float = fposmod(sin(k * 12.9898) * 43758.5453, 1.0) * 2.0 - 1.0
			var jy: float = fposmod(sin(k * 78.233) * 12543.123, 1.0) * 2.0 - 1.0
			raw.append((pts[i] as Vector2) + Vector2(jx, jy) / zoom)
			acc = 0.0
	return raw


func _hard(res: Dictionary) -> int:
	var n: int = 0
	for c in res["curvature"]:
		if str(c["kind"]) == "hard":
			n += 1
	return n


func _check_length() -> void:
	var ed: Control = await _new_editor()
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	ed._validate()
	var dlg: EditorLengthDialog = ed._length_dialog
	var before: String = EditorDoc.serial(ed._doc)
	var len0: float = EditorDoc.path_length(ed._doc["path"])
	ed._length_button.emit_signal("pressed")
	_ok(dlg.visible, "length dialog opens")
	_ok(is_equal_approx(dlg.target(), roundf(len0)), "default target = current length")
	_ok(
		dlg.result.is_empty() and dlg.get_ok_button().disabled,
		"unchanged target: nothing to apply"
	)
	_ok(not dlg._suggest_button.visible, "no stretch suggestion for 2560 track")
	for t in [1500.0, 2500.0, 4500.0, 6000.0, 8000.0]:
		dlg.set_target(t)
		var got: float = float(dlg.result.get("length", -1.0))
		_ok(absf(got - t) <= LENGTH_TOL, "target %d -> %.2f (±%.1f)" % [int(t), got, LENGTH_TOL])
		_ok(_max_spacing(dlg.result["path"]) <= 6.15, "target %d resampled ≤ 6" % int(t))
		_ok(ed._canvas._preview.size() >= 2, "target %d previewed on canvas" % int(t))
		_ok(EditorDoc.serial(ed._doc) == before, "target %d preview keeps doc" % int(t))
	dlg.set_target(8000.0)
	_ok(dlg._check_label.text.contains("예상 검증"), "preview shows expected validation")
	dlg.set_target(1200.0)
	_ok(not bool(dlg.result["validation"]["ok"]), "1200 preview predicts failure")
	_ok(
		dlg._check_label.text.contains("실패"),
		"failure shown before apply: " + dlg._check_label.text
	)
	# 취소 → 불변
	dlg.hide()
	dlg.canceled.emit()
	_ok(EditorDoc.serial(ed._doc) == before and ed._canvas._preview.is_empty(), "cancel keeps doc")
	# 6000 적용
	var items0: Array = (ed._doc["items"] as Array).duplicate(true)
	ed._open_length_dialog()
	dlg.set_target(6000.0)
	dlg.hide()
	dlg.confirmed.emit()
	var len1: float = EditorDoc.path_length(ed._doc["path"])
	_ok(absf(len1 - 6000.0) <= LENGTH_TOL, "apply 6000 -> %.2f" % len1)
	_ok(bool(ed._doc["closed"]), "closed preserved")
	var ratio_ok: bool = true
	for i in range(items0.size()):
		var it: Dictionary = ed._doc["items"][i]
		if absf(float(it["s"]) / len1 - float(items0[i]["s"]) / len0) > 0.001:
			ratio_ok = false
		if float(it["lat"]) != float(items0[i]["lat"]) or str(it["type"]) != str(items0[i]["type"]):
			ratio_ok = false
	_ok(ratio_ok and (ed._doc["items"] as Array).size() == 4, "items keep progress ratio/lat/type")
	_ok(ed._is_validated(), "6000 track validates (long warning only): " + ed._status_label.text)
	_ok(not ed._save_button.disabled, "6000 track can be saved")
	# 6000은 자동 축소되지 않는다: 다시 열면 기본값 6000, 그대로 두면 적용할 것 없음
	ed._open_length_dialog()
	_ok(absf(dlg.target() - roundf(len1)) < 0.5 and dlg.result.is_empty(), "6000 not auto-shrunk")
	dlg.hide()
	dlg.canceled.emit()
	_ok(absf(EditorDoc.path_length(ed._doc["path"]) - len1) < 0.01, "6000 unchanged after reopen")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "undo length = one step back")
	await _free_editor(ed)
	# 짧은 트랙: 권장 길이로 늘리기 제안
	var short: Dictionary = _roundtrip_track()
	var pts: Array = []
	for v in _sine_points(12.0, -1000.0, -200.0):
		pts.append([snappedf(v.x, 0.1), snappedf(v.y, 0.1)])
	short["path"] = [{"type": "polyline", "points": pts, "closed": false}]
	short["items"] = []
	var ed2: Control = await _new_editor()
	ed2._import_from_text(JSON.stringify(short))
	ed2._open_length_dialog()
	var d2: EditorLengthDialog = ed2._length_dialog
	_ok(d2._suggest_button.visible, "short track: stretch suggestion shown")
	d2._suggest_button.emit_signal("pressed")
	_ok(is_equal_approx(d2.target(), TrackValidator.LEN_MIN), "suggestion sets 2500")
	d2.hide()
	d2.canceled.emit()
	await _free_editor(ed2)
	_done.append("length")


## 급한 모서리(90°)가 있는 트랙 + 아이템.
func _corner_track() -> Dictionary:
	var pts: Array = []
	for i in range(0, 201):
		pts.append([-1200.0 + i * 6.0, 0.0])
	for i in range(1, 201):
		pts.append([0.0, i * 6.0])
	return {
		"name": "Corner",
		"difficulty": "normal",
		"fabric": "cotton",
		"width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
		"path": [{"type": "polyline", "points": pts, "closed": false}],
		"items": [
			{"s": 300.0, "type": "thimble", "lat": 5.0},
			{"s": 1203.0, "type": "autopilot", "lat": 0.0},
			{"s": 2000.0, "type": "thimble", "lat": -8.0},
		],
		"modifiers": [],
	}


func _check_autofix_review() -> void:
	var ed: Control = await _new_editor()
	ed._import_from_text(JSON.stringify(_corner_track()))
	ed._validate()
	_ok(not ed._autofix_button.disabled, "corner track offers auto fix: " + ed._status_label.text)
	var before: String = EditorDoc.serial(ed._doc)
	ed._autofix_button.emit_signal("pressed")
	_ok(ed._confirm.visible and ed._confirm.dialog_text.contains("미리보기"), "auto fix previews first")
	_ok(ed._canvas._preview.size() >= 2, "auto fix preview path on canvas")
	_ok(EditorDoc.serial(ed._doc) == before, "preview does not change doc")
	ed._confirm.hide()
	ed._on_confirm_cancel()
	_ok(EditorDoc.serial(ed._doc) == before and ed._canvas._preview.is_empty(), "cancel auto fix")
	ed._auto_fix()
	_confirm_accept(ed)
	_ok(EditorDoc.serial(ed._doc) != before, "auto fix applied")
	_ok((ed._doc["items"] as Array).size() == 3, "auto fix keeps all items")
	var lats_ok: bool = true
	for i in range(3):
		if float(ed._doc["items"][i]["lat"]) != float(_corner_track()["items"][i]["lat"]):
			lats_ok = false
	_ok(lats_ok, "auto fix keeps lat")
	ed._undo()
	_ok(EditorDoc.serial(ed._doc) == before, "undo auto fix = one step")
	# 재투영 순수 검사: 같은 경로면 그대로, 멀리 옮겨지면 moved, 겹친 구간이면 ambiguous
	var path: PackedVector2Array = ed._doc["path"]
	var items: Array = ed._doc["items"]
	var same: Array = EditorDoc.reproject_items(path, path, items)
	var same_ok: bool = EditorDoc.review_count(same) == 0
	for i in range(items.size()):
		if absf(float(same[i]["s"]) - float(items[i]["s"])) > 0.05:
			same_ok = false
	_ok(same_ok, "reproject onto same path keeps s, no review")
	var hair: PackedVector2Array = PackedVector2Array()
	for i in range(0, 101):
		hair.append(Vector2(i * 6.0, 0.0))
	for i in range(0, 101):
		hair.append(Vector2(600.0 - i * 6.0, 4.0))
	var amb: Array = EditorDoc.reproject_items(
		hair, hair, [{"s": 300.0, "type": "thimble", "lat": 0.0}]
	)
	_ok(str(amb[0].get("review", "")) == "ambiguous", "near-overlapping branch -> ambiguous")
	await _free_editor(ed)
	# 유효한 트랙의 뒤쪽을 완만하게 40 옮긴 편집 → 그 구간 아이템은 검토 필요, 저장·테스트 차단
	ed = await _new_editor()
	ed._import_from_text(JSON.stringify(_roundtrip_track()))
	ed._validate()
	path = ed._doc["path"]
	items = ed._doc["items"]
	var shifted: PackedVector2Array = path.duplicate()
	var start: int = int(shifted.size() * 0.7)
	for i in range(start, shifted.size()):
		shifted[i] += Vector2(0.0, 40.0 * clampf(float(i - start) / 60.0, 0.0, 1.0))
	var re: Array = EditorDoc.reproject_items(path, shifted, items)
	ed._apply_path_edit("autofix", shifted, re, PackedVector2Array())
	var n_rev: int = EditorDoc.review_count(ed._doc["items"])
	_ok(n_rev >= 1 and (ed._doc["items"] as Array).size() == 4, "moved items flagged (%d)" % n_rev)
	_ok(str(ed._doc["items"][3].get("review", "")) == "moved", "far item flagged 'moved'")
	var s0: float = float(ed._doc["items"][0]["s"])
	_ok(
		absf(s0 - 500.0) < 0.5 and not EditorDoc.needs_review(ed._doc["items"][0]),
		"near item kept"
	)
	ed._validate()
	_ok(ed._is_validated() and not ed._can_commit(), "geometry valid but review pending")
	_ok(ed._review_row.visible, "review row visible")
	_ok(
		ed._save_button.disabled and ed._testplay_button.disabled,
		"review blocks save/test buttons"
	)
	_ok(not ed._save(), "review blocks save()")
	ed._test_play()
	_ok(not ed._confirm.visible and not GameState.is_editor_test(), "review blocks test play")
	var saved_file: Dictionary = EditorDoc.to_track_dict(ed._doc)
	_ok(not str(saved_file["items"]).contains("review"), "review flag never serialized")
	ed._review_button.emit_signal("pressed")
	_ok(
		EditorDoc.review_count(ed._doc["items"]) == 0 and not ed._review_row.visible,
		"confirm clears"
	)
	_ok(ed._can_commit() == ed._is_validated(), "save gate back to validation only")
	ed._undo()
	_ok(EditorDoc.review_count(ed._doc["items"]) == n_rev, "undo restores review flags")
	await _free_editor(ed)
	_done.append("autofix_review")


func _check_publish_clamp() -> void:
	var t: Dictionary = _roundtrip_track()
	var td: TrackData = TrackData.new()
	td.bake(t["path"])
	t["items"] = [{"s": td.length - 0.2, "type": "thimble", "lat": 0.0}]
	t["track_id"] = ""
	var id: String = TrackLoader.save_custom_track(t)
	var built: Dictionary = TrackLoader.build_publish_track(id)
	_ok(bool(built["ok"]), "publish build ok: " + str(built["message"]))
	var s: float = float(built["track"]["items"][0]["s"]) if bool(built["ok"]) else INF
	var baked: TrackData = TrackLoader.load_track(id)
	_ok(
		s <= baked.length - 0.5,
		"publish item s clamped to length-0.5 (%.3f / %.3f)" % [s, baked.length]
	)
	_ok(
		absf(float(_file_dict(id)["items"][0]["s"]) - (td.length - 0.2)) < 0.01,
		"local file item s untouched"
	)
	_done.append("publish_clamp")


func _check_edit_button() -> void:
	var t: Dictionary = _roundtrip_track()
	t["name"] = "Edit Me"
	t["track_id"] = ""
	var id: String = TrackLoader.save_custom_track(t)
	SelectScript.pending_mode = SelectScript.MODE_OFFICIAL
	get_tree().change_scene_to_file(SelectScript.SELF_SCENE)
	await _frames(4)
	var sel: Node = get_tree().current_scene
	_ok(not (sel._edit_button as Button).is_visible_in_tree(), "official mode: edit hidden")
	SelectScript.pending_mode = SelectScript.MODE_USER
	get_tree().change_scene_to_file(SelectScript.SELF_SCENE)
	await _frames(4)
	sel = get_tree().current_scene
	sel._select_track(id)
	await _frames(2)
	var eb: Button = sel._edit_button
	_ok(eb.is_visible_in_tree(), "user mode: edit visible for custom track")
	_ok(sel.get_node("Panel/ActionRow").get_child_count() == 4, "action row keeps 4 buttons")
	var row: Control = sel.get_node("Panel/HubRow")
	var inside: bool = true
	for b in row.get_children():
		var r: Rect2 = (b as Control).get_global_rect()
		if (b as Control).visible and (r.position.x < 0.0 or r.end.x > 1280.0 or r.size.x < 60.0):
			inside = false
	_ok(inside, "hub row (edit) buttons inside 1280 and wide enough")
	eb.emit_signal("pressed")
	await _frames(4)
	var ed: Control = get_tree().current_scene
	_ok(get_tree().current_scene.scene_file_path == GameState.EDITOR_SCENE, "edit opens editor")
	_ok(str(ed._doc["local_id"]) == id and not ed._is_dirty(), "editor opened the same file clean")
	_ok(SelectScript.pending_mode == SelectScript.MODE_USER, "edit keeps user mode for return")
	ed._name_edit.text = "Edited Name"
	ed._name_edit.text_changed.emit("Edited Name")
	ed._validate()
	_ok(ed._save() and str(ed._doc["local_id"]) == id, "save writes same id")
	_ok(str(_file_dict(id)["name"]) == "Edited Name", "same file updated")
	_ok(_items_equal(_file_dict(id)["items"], t["items"]), "items survive edit+save")
	ed._on_back()
	await _frames(4)
	_ok(get_tree().current_scene.scene_file_path == SelectScript.SELF_SCENE, "back to track select")
	_ok(
		str(get_tree().current_scene.call("current_mode")) == SelectScript.MODE_USER,
		"user mode kept"
	)
	get_tree().unload_current_scene()
	await _frames(3)
	_done.append("edit_button")
