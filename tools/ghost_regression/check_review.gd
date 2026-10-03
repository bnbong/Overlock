extends "res://ghost_regression/check_store.gd"
## 둘째 묶음: 교차 리뷰 수정 검사. check.gd 가 상속한다.
##  review_cleanup : records.json 이 손상·미지원 버전이면 기동 정리가 고스트를 지우지 않음(정상이면 고아만 정리).
##  review_rename  : 교체(rename) 실패 시 기존 records.json·고스트 유지, .tmp·.prev 미잔류, 재기동 후 이전 최고.
##                   중단 복구: 본 파일 우선, 본 파일이 없으면 참조 고스트가 모두 있는 완전한 .tmp, 아니면 .prev.
##  review_delete  : 커스텀 삭제는 기록 정리(purge)가 성공해야 트랙 파일을 지움(실패 시 트랙·기록 유지, 재시도 가능).
##  review_backup  : v1 백업 실패 시 원본을 덮지 않고 메모리 읽기만(쓰기 보류), 다음 기동에 재시도.
##  review_validate: 마지막 샘플 시각 = finish_ms(±1ms), 구간 범위·단조성·마지막 구간 = 헤더 완주·패널티.
##  review_items   : 같은 기록 지문(아이템 s 순서 정규화)이면 배열 순서가 달라도 슬롯 적재 순서가 같음.
##  review_result_fit: 결과 화면에 가장 긴 고스트 문구 조합(신기록·저장 실패·트랙 변경·연습)이 떠도
##                   카드·버튼이 1280×720 캔버스 안에 들어감(키보드·터치).
##  grade_best     : 개인 최고·고스트는 등급 우선(S>A>B>C>D), 같은 등급이면 패널티 포함 시간(동률 유지).
##                   등급 없는 v1 기록은 저장된 accuracy·perfect_rate·cuts로 계산, 계산 불가면 기존 유지.
##  review_practice: practice 판정은 물리·판정이 소비하는 Tuning 키만 비교(미사용 키·steer_expo 제외).

const TrackSelectScene: PackedScene = preload("res://scenes/TrackSelect.tscn")
const TrackSelectScript: GDScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const ResultScene2: PackedScene = preload("res://scenes/Result.tscn")
const ResultScene2Script: GDScript = preload("res://scripts/ui/ResultScreen.gd")


func _ghosted_best(ms: int) -> String:
	var r: Dictionary = _result(ms)
	RecordStore.submit_run(r, _ghost_of(r))
	return str(RecordStore.best_for(TRACK, DIFF).get("ghost_file", ""))


func _check_review_cleanup() -> void:
	_reset_store()
	var path: String = _ghosted_best(60000)
	var good: String = FileAccess.get_file_as_string(RecordStore.SAVE_PATH)
	for bad in ["{broken", JSON.stringify({"format_version": 9, "records": {}})]:
		_write_text(RecordStore.SAVE_PATH, bad)
		RecordStore._ready()
		_ok(
			FileAccess.file_exists(path),
			"cleanup skipped on unreadable records (%s)" % bad.left(12)
		)
	_write_text(RecordStore.SAVE_PATH, good)
	_write_text(GhostStore.DIR + "g0badc0de.json", "{}")
	RecordStore._ready()
	_ok(RecordStore.load_state == "ok", "cleanup: good records reload ok")
	_ok(FileAccess.file_exists(path), "cleanup: referenced ghost kept on ok load")
	_ok(
		not FileAccess.file_exists(GhostStore.DIR + "g0badc0de.json"),
		"cleanup: orphan removed on ok"
	)
	_done.append("review_cleanup")


func _check_review_rename() -> void:
	_reset_store()
	var path_a: String = _ghosted_best(60000)
	var before: String = FileAccess.get_file_as_string(RecordStore.SAVE_PATH)
	GhostStore.faults["records_rename"] = true
	var r: Dictionary = _result(55000)
	var out: Dictionary = RecordStore.submit_run(r, _ghost_of(r))
	GhostStore.faults.clear()
	_ok(not bool(out["is_best"]), "rename fail: not reported as saved")
	_ok(str(out["ghost_reason"]) == "record_save_failed", "rename fail: reason record_save_failed")
	_ok(
		FileAccess.get_file_as_string(RecordStore.SAVE_PATH) == before,
		"rename fail: records.json intact"
	)
	var p: String = RecordStore.SAVE_PATH
	_ok(not FileAccess.file_exists(p + ".tmp"), "rename fail: no .tmp left")
	_ok(not FileAccess.file_exists(p + ".prev"), "rename fail: no .prev left")
	_ok(_ghost_files() == [path_a.get_file()], "rename fail: only previous ghost remains")
	RecordStore._ready()
	_ok(
		int(RecordStore.best_for(TRACK, DIFF).get("final_time_ms", 0)) == 60000, "restart: old best"
	)
	_ok(bool(RecordStore.load_ghost(TRACK, DIFF)["ok"]), "restart: previous ghost loads")
	# 중단 복구 시나리오.
	var other: Dictionary = JSON.parse_string(before)
	var rec: Dictionary = other["records"]
	for k in rec:
		rec[k]["final_time_ms"] = 50000
		rec[k]["ghost_file"] = GhostStore.DIR + "gmissing00.json"
	var tmp_missing: String = JSON.stringify(other)
	# (a) 본 파일이 있으면 .tmp 는 무시·정리한다.
	_write_text(p + ".tmp", tmp_missing)
	RecordStore._ready()
	_ok(
		_best_ms() == 60000 and not FileAccess.file_exists(p + ".tmp"),
		"recover: main wins, tmp removed"
	)
	# (b) 본 파일이 없고 .tmp 가 없는 고스트를 참조하면 .prev 를 복원한다.
	DirAccess.rename_absolute(p, p + ".prev")
	_write_text(p + ".tmp", tmp_missing)
	RecordStore._ready()
	_ok(_best_ms() == 60000, "recover: tmp with missing ghost rejected, .prev restored")
	_ok(FileAccess.file_exists(path_a), "recover: previous ghost not removed as orphan")
	_ok(
		FileAccess.file_exists(p) and not FileAccess.file_exists(p + ".prev"),
		"recover: main restored"
	)
	# (c) 본 파일이 없고 완전한 .tmp 의 참조 고스트가 모두 있으면 .tmp 를 채택한다.
	for k in rec:
		rec[k]["ghost_file"] = path_a
	DirAccess.rename_absolute(p, p + ".prev")
	_write_text(p + ".tmp", JSON.stringify(other))
	RecordStore._ready()
	_ok(_best_ms() == 50000, "recover: complete tmp with existing ghost adopted")
	_ok(not FileAccess.file_exists(p + ".prev"), "recover: stale .prev removed after adoption")
	# (d) 깨진 .tmp 는 채택하지 않는다.
	_write_text(p, before)
	DirAccess.rename_absolute(p, p + ".prev")
	_write_text(p + ".tmp", '{"format_version": 2, "rec')
	RecordStore._ready()
	_ok(_best_ms() == 60000, "recover: partial tmp rejected, .prev restored")
	_done.append("review_rename")


func _best_ms() -> int:
	return int(RecordStore.best_for(TRACK, DIFF).get("final_time_ms", 0))


func _check_review_delete() -> void:
	_reset_store()
	var id: String = (
		TrackLoader
		. save_custom_track(
			{
				"name": "Delete Me",
				"difficulty": DIFF,
				"fabric": "cotton",
				"width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
				"path": [{"type": "polyline", "closed": false, "points": [[0, 0], [700, 0]]}],
			}
		)
	)
	var r: Dictionary = _result(20000, 0, id)
	RecordStore.submit_run(r, _synthetic_ghost(r, 700.0).to_ghost(r))
	var gpath: String = str(RecordStore.best_for(id, DIFF).get("ghost_file", ""))
	var sel: Control = TrackSelectScene.instantiate()
	get_tree().root.add_child(sel)
	await _frames(3)
	sel._mode = TrackSelectScript.MODE_USER
	sel._apply_mode()
	sel._rebuild_tracks()
	sel._select_track(id)
	GhostStore.faults["records"] = true
	sel._do_delete()
	GhostStore.faults.clear()
	_ok(
		not TrackLoader.read_custom_track_text(id).is_empty(), "delete: purge fail keeps track file"
	)
	_ok(not RecordStore.best_for(id, DIFF).is_empty(), "delete: purge fail keeps record")
	_ok(FileAccess.file_exists(gpath), "delete: purge fail keeps ghost")
	sel._select_track(id)
	sel._do_delete()
	_ok(TrackLoader.read_custom_track_text(id).is_empty(), "delete: retry removes track")
	TrackLoader._cache.erase(id)
	_ok(RecordStore._records.size() == 0, "delete: retry removes record")
	_ok(not FileAccess.file_exists(gpath), "delete: retry removes ghost")
	sel.queue_free()
	await _frames(2)
	_done.append("review_delete")


func _check_review_backup() -> void:
	_reset_store()
	var v1_text: String = JSON.stringify({TRACK + "|" + DIFF: _result(50000)})
	_write_text(RecordStore.SAVE_PATH, v1_text)
	GhostStore.faults["backup"] = true
	RecordStore._load()
	_ok(
		FileAccess.get_file_as_string(RecordStore.SAVE_PATH) == v1_text,
		"backup fail: original kept"
	)
	_ok(not FileAccess.file_exists(RecordStore.SAVE_PATH + ".bak"), "backup fail: no .bak")
	_ok(
		int(RecordStore.best_for(TRACK, DIFF).get("final_time_ms", 0)) == 50000,
		"backup fail: v1 readable"
	)
	var out: Dictionary = RecordStore.submit_run(_result(61000))
	_ok(not bool(out["is_best"]), "backup fail: writes deferred")
	_ok(FileAccess.get_file_as_string(RecordStore.SAVE_PATH) == v1_text, "backup fail: still v1")
	GhostStore.faults.clear()
	RecordStore._load()
	_ok(RecordStore.load_state == "migrated", "backup retry next start: migrated")
	_ok(
		FileAccess.get_file_as_string(RecordStore.SAVE_PATH + ".bak") == v1_text,
		"retry: .bak written"
	)
	_done.append("review_backup")


func _check_review_validate() -> void:
	var r: Dictionary = _result(60000, 2000)
	var good: Dictionary = _ghost_of(r)
	good["run_id"] = "gtest"
	_ok(GhostStore.validate(good).is_empty(), "validate: good ghost passes")
	var early: Dictionary = _ghost_of(_result(1000))
	early["finish_ms"] = 58000
	early["penalty_ms"] = 2000
	early["final_time_ms"] = 60000
	var ls: Array = early["splits"]
	ls[9] = [58000, 2000, 1]
	var bad_cases: Dictionary = {"early finish sample": early}
	var c1: Dictionary = good.duplicate(true)
	(c1["splits"] as Array)[9] = [0, 0, 1]
	bad_cases["last split != header"] = c1
	var c2: Dictionary = good.duplicate(true)
	(c2["splits"] as Array)[3] = [100, 0, 1]
	bad_cases["split time decreasing"] = c2
	var c3: Dictionary = good.duplicate(true)
	(c3["splits"] as Array)[2] = [(c3["splits"] as Array)[2][0], 9000, 1]
	bad_cases["split penalty > header"] = c3
	var c4: Dictionary = good.duplicate(true)
	(c4["splits"] as Array)[1] = [(c4["splits"] as Array)[1][0], 0, 2]
	bad_cases["split valid flag 2"] = c4
	var c5: Dictionary = good.duplicate(true)
	(c5["splits"] as Array)[4] = [99999, 0, 1]
	bad_cases["split after finish"] = c5
	for label in bad_cases:
		_ok(GhostStore.validate(bad_cases[label]) == "invalid", "validate rejects " + label)
	_done.append("review_validate")


func _check_review_items() -> void:
	_reset_store()
	var items_a: Array = [
		{"s": 200.0, "lat": 0.0, "type": "thimble"}, {"s": 200.0, "lat": 0.0, "type": "autopilot"}
	]
	var items_b: Array = [items_a[1], items_a[0]]
	var slots: Array = []
	var fps: Array = []
	for items in [items_a, items_b]:
		var id: String = (
			TrackLoader
			. save_custom_track(
				{
					"name": "Item Order",
					"difficulty": DIFF,
					"fabric": "cotton",
					"width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
					"path": [{"type": "polyline", "closed": false, "points": [[0, 0], [900, 0]]}],
					"items": items,
				}
			)
		)
		fps.append(TrackLoader.track_fingerprint(id))
		GameState.track_id = id
		var g: Node = GameplayScene.instantiate()
		get_tree().root.add_child(g)
		await _frames(2)
		g.set_physics_process(false)
		g._countdown_time = 0.0001
		_step(g, 1)
		g._player.position = g._track.point_at_s(200.0)
		g._hint = int(g._track.query(g._player.position, 0)["idx"])
		_step(g, 1)
		slots.append(g.item_slots())
		await _free_game(g)
		TrackLoader.delete_custom_track(id)
	GameState.track_id = TRACK
	_ok(
		fps[0] == fps[1] and fps[0].begins_with("tf2:"),
		"items: array order normalized in fingerprint"
	)
	_ok(
		slots[0].size() == 2 and slots[0] == slots[1],
		"items: same fingerprint -> same slot order %s" % str(slots)
	)
	var hub_a: String = TrackLoader.play_fingerprint({"items": items_a})
	_ok(
		hub_a == TrackLoader.play_fingerprint({"items": items_b}),
		"items: hub fp1 contract unchanged"
	)
	_done.append("review_items")


func _check_review_practice() -> void:
	var keys: Variant = RecordStore.get("PHYSICS_TUNING_KEYS")
	_ok(keys is Array and (keys as Array).size() > 10, "practice: explicit physics key list")
	if keys is Array:
		for f in [
			"res://scripts/player/PlayerController.gd", "res://scripts/systems/RaceDirector.gd"
		]:
			var re: RegEx = RegEx.create_from_string("Tuning\\.([a-z_]+)")
			for m in re.search_all(FileAccess.get_file_as_string(f)):
				var k: String = m.get_string(1)
				var allowed: bool = k in keys or k in ["steer_expo", "speed_table", "get_script"]
				_ok(allowed, "practice: %s key %s covered" % [f.get_file(), k])
	var base: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/tuning.json")
	)
	var cases: Dictionary = {
		"foot_response_rate": [99.0, false],
		"steer_expo": [0.3, false],
		"steer_tau": [0.3, true],
	}
	for k in cases:
		var d: Dictionary = base.duplicate()
		d[k] = cases[k][0]
		var got: Variant = RecordStore.call("_detect_tuning_override", JSON.stringify(d))
		_ok(
			str(got) == str(cases[k][1]),
			"practice: change %s -> override %s" % [k, str(cases[k][1])]
		)
	_done.append("review_practice")


func _check_review_result_fit() -> void:
	var splits: Array = [-420, 130, null, -2210, 1050, -30, 880, null, -1240, -4000]
	# 가장 긴 두 조합: 신기록+고스트 저장 실패, 미갱신+트랙 변경 안내(둘 다 연습). 옛 split_deltas 키를
	# 넣어도 결과 화면은 구간 줄을 보이지 않아야 한다.
	var combos: Array = [
		{
			"ghost_status": "failed",
			"ghost_reason": "too_many_samples",
			"is_new_record": true,
			"prev_best_ms": 65000,
		},
		{
			"ghost_status": "unchanged",
			"ghost_reason": "not_best",
			"is_new_record": false,
			"prev_best_ms": 59000,
			"ghost_track_changed": true,
		},
	]
	for k in combos.size():
		var res: Dictionary = _result(61000, 3000)
		res.merge(combos[k], true)
		res["practice"] = true
		res["split_deltas"] = splits
		GameState.last_result = res
		var scr: Control = ResultScene2.instantiate()
		get_tree().root.add_child(scr)
		await _frames(6)
		var screen: Rect2 = Rect2(Vector2.ZERO, Vector2(1280, 720))
		var card: Rect2 = scr.get_node("PanelBg").get_global_rect()
		var safe: Rect2 = screen.grow(-ResultScene2Script.CARD_MARGIN)
		_ok(safe.encloses(card), "%s: long result %d fits with margin %s" % [_mode, k, card])
		for b in [scr._retry_button, scr._menu_button, scr._track_label, scr._ghost_label]:
			var r: Rect2 = (b as Control).get_global_rect()
			_ok(card.encloses(r), "%s: combo %d %s inside card %s" % [_mode, k, b.name, r])
		var txt: String = scr._ghost_label.text
		_ok(not txt.contains("구간") and not txt.contains("-0.42"), "%s: no split line" % _mode)
		_ok(txt.contains("등급 우선"), "%s: best rule line kept" % _mode)
		if k == 1:
			_ok(scr._ghost_label.text.contains("트랙"), "%s: track changed hint shown" % _mode)
		scr.queue_free()
		await _frames(2)
	_done.append("review_result_fit")


func _graded(ms: int, grade: String) -> Dictionary:
	var r: Dictionary = _result(ms)
	r["grade"] = grade
	return r


func _check_grade_best() -> void:
	_reset_store()
	var a: Dictionary = _graded(60000, "A")
	RecordStore.submit_run(a, _ghost_of(a))
	var path_a: String = str(RecordStore.best_for(TRACK, DIFF)["ghost_file"])
	var b: Dictionary = _graded(55000, "B")
	var ob: Dictionary = RecordStore.submit_run(b, _ghost_of(b))
	_ok(not bool(ob["is_best"]), "grade: faster but lower grade is not best")
	_ok(
		str(RecordStore.best_for(TRACK, DIFF)["ghost_file"]) == path_a,
		"grade: ghost kept (lower grade)"
	)
	_ok(_ghost_files() == [path_a.get_file()], "grade: no ghost for lower grade run")
	var s1: Dictionary = _graded(65000, "S")
	var os1: Dictionary = RecordStore.submit_run(s1, _ghost_of(s1))
	_ok(
		bool(os1["is_best"]) and str(os1["ghost_status"]) == "saved",
		"grade: higher grade slower is best"
	)
	_ok(not FileAccess.file_exists(path_a), "grade: previous ghost replaced")
	_ok(str(RecordStore.best_for(TRACK, DIFF).get("grade", "")) == "S", "grade: entry stores grade")
	var s2: Dictionary = _graded(64000, "S")
	_ok(
		bool(RecordStore.submit_run(s2, _ghost_of(s2))["is_best"]),
		"grade: same grade faster is best"
	)
	var s3: Dictionary = _graded(64000, "S")
	_ok(
		not bool(RecordStore.submit_run(s3)["is_best"]),
		"grade: same grade same time keeps existing"
	)
	var s4: Dictionary = _graded(64500, "S")
	_ok(not bool(RecordStore.submit_run(s4)["is_best"]), "grade: same grade slower not best")
	# 등급 필드 없는 v1 기록: 저장된 메트릭으로 같은 식(RunStats.grade_from_metrics) 계산.
	_reset_store()
	var v1: Dictionary = {
		"track_id": TRACK,
		"difficulty": DIFF,
		"finish_ms": 50000,
		"penalty_ms": 0,
		"final_time_ms": 50000,
		"accuracy": 99.0,
		"perfect_rate": 99.0,
		"cuts": 0,
	}
	_write_text(RecordStore.SAVE_PATH, JSON.stringify({TRACK + "|" + DIFF: v1}))
	RecordStore._load()
	var g1: String = str(RecordStore.call("grade_of", RecordStore.best_for(TRACK, DIFF)))
	_ok(g1 == "S", "grade: v1 metrics -> S")
	_ok(
		not bool(RecordStore.submit_run(_graded(40000, "A"))["is_best"]),
		"grade: v1 S beats faster A"
	)
	_ok(bool(RecordStore.submit_run(_graded(49000, "S"))["is_best"]), "grade: faster S beats v1 S")
	# 등급도 메트릭도 없는 기록은 비교할 수 없으므로 기존 기록을 유지한다.
	_reset_store()
	var bare: Dictionary = {"track_id": TRACK, "difficulty": DIFF, "final_time_ms": 50000}
	_write_text(RecordStore.SAVE_PATH, JSON.stringify({TRACK + "|" + DIFF: bare}))
	RecordStore._load()
	var g2: String = str(RecordStore.call("grade_of", RecordStore.best_for(TRACK, DIFF)))
	_ok(g2 == "", "grade: bare record unknown")
	_ok(not bool(RecordStore.submit_run(_graded(40000, "S"))["is_best"]), "grade: unknown kept")
	# 연습 기록도 같은 규칙.
	_reset_store()
	var pa: Dictionary = _graded(60000, "A")
	pa["practice"] = true
	RecordStore.submit_run(pa)
	var pb: Dictionary = _graded(50000, "B")
	pb["practice"] = true
	_ok(not bool(RecordStore.submit_run(pb)["is_best"]), "grade: practice uses same rule")
	# 결과 화면 문구.
	var low: Dictionary = _graded(55000, "B")
	low.merge({"ghost_status": "unchanged", "ghost_reason": "not_best", "prev_best_ms": 60000})
	low["prev_best_grade"] = "A"
	var t_low: String = ResultScene2Script.ghost_summary(low)
	_ok(t_low.contains("등급이 낮아"), "grade result: lower grade message")
	_ok(t_low.contains("등급 우선"), "grade result: policy line")
	var up: Dictionary = _graded(65000, "S")
	up.merge({"ghost_status": "saved", "is_new_record": true, "prev_best_ms": 60000})
	up["prev_best_grade"] = "A"
	_ok(ResultScene2Script.ghost_summary(up).contains("A → S"), "grade result: grade up message")
	var same: Dictionary = _graded(62000, "A")
	same.merge({"ghost_status": "unchanged", "ghost_reason": "not_best", "prev_best_ms": 60000})
	same["prev_best_grade"] = "A"
	_ok(
		ResultScene2Script.ghost_summary(same).contains("2.00초 느림"),
		"grade result: same grade slower"
	)
	_done.append("grade_best")
