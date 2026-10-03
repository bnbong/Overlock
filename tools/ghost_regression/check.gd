extends "res://ghost_regression/check_review.gd"
## 개인 고스트·기록 호환성 회귀 검사(사본 프로젝트 전용, run.sh 가 실행한다).
## run.sh 가 세 모드로 실행한다: 키보드(인자 없음), 터치(--touch-controls), practice(사본의 tuning.json 을
## 기본값과 다르게 바꾼 뒤 실행). 데스크톱 헤드리스 모사이며 실제 기기·웹(IDBFS) 검증이 아니다.
##
## 구획:
##  ruleset     : 규칙 분리 없음(PHYSICS_RULESET·current_ruleset 없음),
##                키 track_id|difficulty(연습은 |practice),
##                저장소 tuning.json 비오버라이드(practice 모드는 감지), 연습·정식 기록 분리.
##  fingerprint : 공식 트랙 지문 안정성, 같은 custom ID 의 경로·닫힘·원단·폭·아이템 수정 시 기록은 유지하고
##                옛 고스트만 비활성(track_changed), 이름만 바꾸면 고스트 유효, 최고 갱신 시 새 고스트.
##  migration   : v1 records.json 백업(.bak 원본 바이트)·v1 기록을 그대로 현재 최고로(더 느린 완주는 미갱신),
##                개발 중 규칙 분리 키 병합,
##                재실행 유지, 손상·미래 버전 파일 보존 후 덮어쓰기.
##  save_flow   : 최고 미갱신(느림·동률)·갱신·고스트 쓰기 실패·기록 저장 실패·고아 정리·손상/미지원/불일치.
##  capacity    : 샘플 24000개 초과·2MiB 초과 시 고스트 미저장(잘린 파일 없음)·기록은 저장.
##  playback    : 30/60/120Hz 기록·재생 위치 일치, 같은 물리 시간 같은 위치, 각도 보간, 복귀 즉시 이동.
##  splits      : 구간 최초 통과·후진 중복 없음·보간·복귀로 건너뛴 구간 비교 불가·최종 구간 = 실제 완주,
##                순수 주행은 빠르지만 패널티 포함 느린 런, 고스트 선완주.
##  game_flow   : 실제 Gameplay 주행 → 완주 → 기록·고스트 저장, 다음 런에서 고스트 재생(구간은 데이터로만 기록).
##  determinism : 고스트 ON/OFF 에서 같은 입력의 틱별 위치·RISK·아이템·패널티·결과 동일.
##  no_overwrite: 테스트 플레이·재시작·중도 포기는 최고·고스트를 덮지 않음.
##  hud_layout  : 출발 안내 배너가 미니맵·진행 막대·TIME·RISK·아이템 슬롯·효과 카드·부상 말풍선·터치
##                버튼과 겹치지 않음(1280×720 캔버스, aspect keep), 미니맵 고스트 마커·라벨.
##  select_ui   : 트랙 선택 고스트 토글(기본 켜기·영속)·상태 문구(첫 완주/고스트 없음/준비됨/트랙 변경, 데스크톱
##                한 줄)·v1 기록이 Best.
##  result_ui   : 결과 화면 고스트 저장 성공/실패 사유·미갱신·기록 저장 실패·트랙 변경 안내·연습 표시.
##  purge       : 커스텀 트랙 삭제 + purge 가 기록과 고스트 파일을 함께 정리.

const ToastScene: PackedScene = preload("res://scenes/Toast.tscn")
const ResultScene: PackedScene = preload("res://scenes/Result.tscn")
const ResultScript: GDScript = preload("res://scripts/ui/ResultScreen.gd")
const B := TouchControls.Btn


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	LeaderboardClient.tutorial_seen = true
	if TouchControls.is_forced():
		_mode = "touch"
	elif RecordStore.is_practice():
		_mode = "practice"
	await get_tree().process_frame
	var sections: Array[String] = ["ruleset"]
	_check_ruleset()
	if _mode == "practice":
		sections.append("practice_flow")
		await _check_practice_flow()
	else:
		sections.append_array(["fingerprint", "migration", "save_flow", "capacity", "playback"])
		sections.append_array(["splits", "game_flow", "determinism", "no_overwrite", "hud_layout"])
		sections.append_array(
			["select_ui", "result_ui", "purge", "minimap_countdown", "field_ghost"]
		)
		sections.append_array(["review_cleanup", "review_rename", "review_delete", "review_backup"])
		sections.append_array(
			["review_validate", "review_items", "review_practice", "review_result_fit"]
		)
		sections.append("grade_best")
		_check_fingerprint()
		_check_migration()
		_check_save_flow()
		_check_capacity()
		_check_playback()
		_check_splits()
		await _check_game_flow()
		await _check_determinism()
		await _check_no_overwrite()
		await _check_hud_layout()
		await _check_select_ui()
		await _check_result_ui()
		_check_purge()
		await _check_minimap_countdown()
		await _check_field_ghost()
		_check_review_cleanup()
		_check_review_rename()
		await _check_review_delete()
		_check_review_backup()
		_check_review_validate()
		await _check_review_items()
		_check_review_practice()
		await _check_review_result_fit()
		_check_grade_best()
	for s in sections:
		_ok(s in _done, "section completed: " + s)
	_reset_store()
	print("ghost regression (%s): %d passed, %d failed" % [_mode, _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## practice 모드: 결과·기록이 연습 키(track_id|difficulty|practice)로 저장되고 정식 키와 섞이지 않는다.
func _check_practice_flow() -> void:
	_reset_store()
	var g: Node = await _new_game()
	_drive(g, 120)
	var res: Dictionary = _finish(g)
	_ok(bool(res["practice"]) and not res.has("physics_ruleset"), "practice: result flag practice")
	_ok(bool(res["is_new_record"]) and str(res["ghost_status"]) == "saved", "practice: saved")
	var best: Dictionary = RecordStore.best_for(TRACK, DIFF)
	_ok(bool(best.get("practice", false)), "practice: entry practice flag")
	var hdr: Variant = _read_json(str(best.get("ghost_file", "")))
	_ok(
		hdr is Dictionary and not (hdr as Dictionary).has("physics_ruleset"), "practice: no ruleset"
	)
	_ok(
		RecordStore._records.has(TRACK + "|" + DIFF + "|practice"), "practice: practice key written"
	)
	_ok(not RecordStore._records.has(TRACK + "|" + DIFF), "practice: no formal key written")
	_ok(ResultScript.ghost_summary(res).contains("연습"), "practice: result screen notes practice")
	await _free_game(g)
	_done.append("practice_flow")


## 실제 주행 → 완주: 기록·고스트 저장. 다음 런은 고스트를 재생하고 구간 통과는 데이터로만 기록한다.
func _check_game_flow() -> void:
	_reset_store()
	var g: Node = await _new_game()
	_ok(g.ghost_playback() == null, "flow: no ghost before first finish")
	_drive(g, 300)
	var res: Dictionary = _finish(g)
	_ok(bool(res["is_new_record"]), "flow: first finish is new record")
	_ok(str(res["ghost_status"]) == "saved", "flow: ghost saved (%s)" % str(res["ghost_reason"]))
	_ok(
		not bool(res["practice"]) and not res.has("physics_ruleset"),
		"flow: no ruleset, not practice"
	)
	_ok(str(res["track_fingerprint"]) == TrackLoader.track_fingerprint(TRACK), "flow: fingerprint")
	var best: Dictionary = RecordStore.best_for(TRACK, DIFF)
	for k in RecordStore.TRANSIENT_KEYS:
		_ok(not best.has(k), "flow: transient key not stored: " + k)
	var lg: Dictionary = RecordStore.load_ghost(TRACK, DIFF)
	_ok(bool(lg["ok"]), "flow: saved ghost validates and loads")
	if bool(lg["ok"]):
		var run: GhostRun = lg["run"]
		_ok(run.finish_ms == int(res["finish_ms"]), "flow: ghost finish_ms matches result")
		_ok(run.split_value(9) == int(res["final_time_ms"]), "flow: final split = final time")
		_ok(absi(run.sample_count() - (int(res["finish_ms"]) / 50 + 2)) <= 3, "flow: ~20Hz samples")
	await _free_game(g)
	# 다음 런: 같은 입력이면 같은 경로라 고스트가 플레이어와 겹친다. 주행 중 구간 팝업은 뜨지 않고
	# 구간 통과는 기록만 된다. 필드 마커는 플레이어와 겹치면 숨는다(근접 숨김).
	g = await _new_game()
	_ok(g.ghost_playback() != null, "flow: ghost loaded on next run")
	var mm: MiniMap = g._hud._minimap
	var shown: Array = []
	for t in 300:
		_drive_input(t)
		_step(g, 1)
		var txt: String = g._hud._ghost_banner.notice_text()
		if not txt.is_empty() and not (txt in shown):
			shown.append(txt)
		if t == 100:
			var fm: Dictionary = g.ghost_field().marker()
			_ok(not bool(fm["visible"]), "flow: field marker hidden when overlapping player")
			var m: Dictionary = mm.ghost_marker()
			_ok(bool(m["visible"]) and bool(m["inside"]), "flow: minimap ghost marker inside")
			_ok(
				(m["pos"] as Vector2).distance_to(mm.size * 0.5) < 2.0,
				"flow: same path -> marker on player"
			)
	_release_all()
	_ok(shown.is_empty(), "flow: no split popup while driving %s" % str(shown))
	_ok(g._ghost_rec.split_t[0] >= 0, "flow: split still recorded as data")
	_ok(g.ghost_field() != null, "flow: field ghost layer built")
	await _free_game(g)
	_done.append("game_flow")


## 고스트 ON/OFF 에서 같은 입력이면 틱별 시뮬레이션 상태와 결과가 같다(고스트는 읽기 전용).
func _check_determinism() -> void:
	RecordStore.set_ghost_enabled(true)
	var g: Node = await _new_game()
	var on_loaded: bool = g.ghost_playback() != null and g.ghost_field() != null
	var a: Array = _drive(g, 420)
	var ra: Dictionary = g._stats.finalize(g._elapsed, g._track.safe, TRACK, DIFF)
	var ghost_drawn: bool = bool(g._hud._minimap.ghost_marker()["visible"])
	await _free_game(g)
	RecordStore.set_ghost_enabled(false)
	g = await _new_game()
	var off_loaded: bool = g.ghost_playback() != null or g.ghost_field() != null
	var b: Array = _drive(g, 420)
	var rb: Dictionary = g._stats.finalize(g._elapsed, g._track.safe, TRACK, DIFF)
	var off_drawn: bool = bool(g._hud._minimap.ghost_marker()["visible"])
	await _free_game(g)
	RecordStore.set_ghost_enabled(true)
	_ok(on_loaded and ghost_drawn, "determinism: ghost ON loaded and drawn")
	_ok(not off_loaded and not off_drawn, "determinism: ghost OFF not loaded")
	_ok(a.size() == 420 and a == b, "determinism: tick-by-tick identical ON vs OFF")
	_ok(ra == rb, "determinism: results identical ON vs OFF")
	_done.append("determinism")


## 테스트 플레이·재시작·중도 포기는 최고·고스트를 덮지 않는다.
func _check_no_overwrite() -> void:
	var before: Dictionary = RecordStore.best_for(TRACK, DIFF).duplicate(true)
	var files: Array = _ghost_files()
	_ok(not before.is_empty() and files.size() == 1, "no_overwrite: baseline record + ghost")
	GameState.run_source = GameState.SOURCE_EDITOR_TEST
	var g: Node = await _new_game()
	_ok(g.ghost_playback() == null, "editor test: no ghost playback")
	_drive(g, 30)
	var res: Dictionary = _finish(g)
	_ok(
		bool(res.get("editor_test", false)) and not bool(res["is_new_record"]), "editor test result"
	)
	_ok(not res.has("ghost_status"), "editor test: no ghost save attempted")
	await _free_game(g)
	GameState.clear_editor_test()
	_ok(RecordStore.best_for(TRACK, DIFF) == before, "editor test: best unchanged")
	_ok(_ghost_files() == files, "editor test: ghost files unchanged")
	# 재시작: 씬을 다시 불러오면 이전 런 기록기는 버려진다.
	g = await _new_game()
	_drive(g, 30)
	get_tree().current_scene = g
	g._restart()
	await _frames(3)
	var ng: Node = get_tree().current_scene
	_ok(ng != null and ng != g and ng.has_method("ghost_playback"), "restart: new gameplay")
	if ng != null and ng.has_method("ghost_playback"):
		ng.set_physics_process(false)
		_ok(ng._ghost_rec.sample_count() == 0, "restart: new recorder empty")
		get_tree().current_scene = self
		await _free_game(ng)
	else:
		get_tree().current_scene = self
	# 중도 포기: 완주 없이 런을 버린다(메뉴 복귀와 같은 결과 — 저장 경로 없음).
	g = await _new_game()
	_drive(g, 30)
	get_tree().paused = true
	await _free_game(g)
	_ok(RecordStore.best_for(TRACK, DIFF) == before, "restart/abandon: best unchanged")
	_ok(_ghost_files() == files, "restart/abandon: ghost files unchanged")
	_done.append("no_overwrite")


## 배너·미니맵 마커 배치와 HUD 겹침(현재 모드: 키보드 또는 터치).
func _check_hud_layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_ok(vp == Vector2(1280, 720), "layout: canvas 1280x720 (aspect keep for 844x390/932x430)")
	var g: Node = await _new_game()
	var hud: HUD = g._hud
	hud._thimble_card.visible = true
	hud._autopilot_card.visible = true
	_ok(not hud.has_method("show_split"), "layout: no split popup API (removed)")
	var banner: GhostNoticeBanner = hud._ghost_banner
	# 출발 한 줄 안내(트랙 변경·손상·불일치·파일 없음)가 배너 폭 안에 들어간다.
	for reason in ["track_changed", "missing", "mismatch", "corrupt"]:
		var text: String = RD.ghost_notice_text(reason)
		_ok(not text.is_empty() and not text.contains("\n"), "notice %s is one line" % reason)
		hud.show_ghost_notice(text)
		await _frames(1)
		var mw: float = banner.text_width()
		_ok(mw <= GhostNoticeBanner.RECT.size.x - 16.0, "notice %s fits (%.0f)" % [reason, mw])
	await _frames(1)
	var br: Rect2 = banner.get_global_rect()
	_ok(br.is_equal_approx(GhostNoticeBanner.RECT), "layout: banner rect %s" % br)
	var others: Dictionary = {
		"minimap": hud.get_node("MiniMap").get_global_rect(),
		"progress": hud.get_node("ProgressBar").get_global_rect(),
		"time": hud.get_node("TimePanel").get_global_rect(),
		"risk": hud.get_node("RiskMeter").get_global_rect(),
		"speed": hud.get_node("SpeedPanel").get_global_rect(),
		"slots": hud._item_slots.get_global_rect(),
		"effects": hud._effect_box.get_global_rect(),
		"status": _label_text_rect(hud.get_node("StatusLabel")),
	}
	var toast: Toast = ToastScene.instantiate()
	get_tree().root.add_child(toast)
	await _frames(1)
	toast.push_immediate("이녀석, 제대로 해야지!", load("res://icon.png"))
	await _frames(3)
	others["scold"] = toast._panel.get_global_rect()
	others["portrait"] = toast._portrait.get_global_rect()
	if hud._touch != null:
		var tc: TouchControls = hud._touch
		for b in [
			B.STEER_LEFT, B.STEER_RIGHT, B.SPEED_UP, B.SPEED_DOWN, B.DRIFT, B.PAUSE, B.USE_ITEM
		]:
			others["touch_%d" % b] = tc.button_rect(b).grow(TouchControls.HIT_PAD)
	for k in others:
		var r: Rect2 = others[k]
		_ok(r.size.x > 0.0 and not br.intersects(r), "%s: banner clear of %s %s" % [_mode, k, r])
	toast.queue_free()
	# 미니맵 고스트 마커: 플레이어와 같은 변환, 밖이면 경계 방향 표시.
	var mm: MiniMap = hud._minimap
	var player: Vector2 = g._player.position
	mm.set_ghost({"pos": player, "heading": 0.0, "arrived": false, "since_finish_ms": 0.0})
	var m0: Dictionary = mm.ghost_marker()
	_ok(
		bool(m0["inside"]) and (m0["pos"] as Vector2).distance_to(mm.size * 0.5) < 0.01,
		"marker same xf"
	)
	_ok(str(m0["label"]) == "고스트", "marker label (shape + label, not color only)")
	mm.set_ghost({"pos": player + Vector2(5000, 0), "heading": 0.0, "arrived": false})
	var m1: Dictionary = mm.ghost_marker()
	var inner: Rect2 = Rect2(Vector2.ONE * 15.9, mm.size - Vector2.ONE * 31.8)
	_ok(bool(m1["visible"]) and not bool(m1["inside"]), "far ghost: edge indicator")
	_ok(inner.has_point(m1["pos"]), "far ghost: indicator clamped inside minimap")
	mm.set_ghost({"pos": player, "heading": 0.0, "arrived": true, "since_finish_ms": 500.0})
	_ok(str(mm.ghost_marker()["label"]) == "고스트 도착", "arrived label shown")
	mm.set_ghost({"pos": player, "heading": 0.0, "arrived": true, "since_finish_ms": 4000.0})
	_ok(str(mm.ghost_marker()["label"]) == "고스트", "arrived label fades after 3s")
	await _free_game(g)
	_done.append("hud_layout")


## 라벨 글자가 실제로 차지하는 가운데 영역(가로 전체 앵커 라벨의 폭 대신).
func _label_text_rect(l: Label) -> Rect2:
	var r: Rect2 = l.get_global_rect()
	var w: float = 360.0
	return Rect2(r.position.x + (r.size.x - w) * 0.5, r.position.y, w, r.size.y)


func _check_select_ui() -> void:
	_reset_store()
	var sel: Control = TrackSelectScene.instantiate()
	get_tree().root.add_child(sel)
	await _frames(3)
	sel._select_track(TRACK)
	var row: GhostSelectRow = sel._ghost_row
	_ok(row != null and row.is_visible_in_tree(), "select: ghost row visible")
	_ok(row.toggle().button_pressed, "select: toggle default on")
	_ok(row.status_text() == "첫 완주 후 고스트가 생깁니다", "select: no record text")
	_ok(row._policy.text.contains("등급 우선"), "select: grade-first policy text")
	_ok(not row._policy.text.contains("패널티 포함 시간 기준이고"), "select: old policy gone")
	var v1: Dictionary = {TRACK + "|" + DIFF: _result(50000)}
	_write_text(RecordStore.SAVE_PATH, JSON.stringify(v1))
	RecordStore._load()
	sel._refresh()
	_ok(row.status_text().contains("고스트가 없습니다"), "select: v1 best without ghost text")
	_ok(sel._best_time_label.text == "Best: A 00:50.000", "select: v1 record is current best")
	_ok(not sel._best_time_label.text.contains("이전"), "select: no previous-version wording")
	await _check_status_one_line(row, "no_ghost")
	var r: Dictionary = _result(48000)
	RecordStore.submit_run(r, _ghost_of(r))
	sel._refresh()
	_ok(row.status_text().contains("함께 달립니다"), "select: ready text")
	_ok(sel._best_time_label.text == "Best: A 00:48.000", "select: current best")
	await _check_status_one_line(row, "ready")
	# 기록 당시와 트랙 지문이 다르면(편집) 고스트를 쓸 수 없다는 문구.
	RecordStore._records[TRACK + "|" + DIFF]["track_fingerprint"] = "tf2:old"
	sel._refresh()
	_ok(row.status_text().contains("트랙이 바뀌어"), "select: track changed text")
	_ok(row.status_text().contains("갱신"), "select: track changed tells how to get a new ghost")
	await _check_status_one_line(row, "track_changed")
	RecordStore._load()
	sel._refresh()
	row.toggle().button_pressed = false
	await _frames(1)
	_ok(not RecordStore.ghost_enabled(), "select: toggle off applied")
	RecordStore._load_settings()
	_ok(not RecordStore.ghost_enabled(), "select: toggle persisted (restart)")
	_ok(row.status_text().contains("끄면"), "select: off text")
	await _check_status_one_line(row, "off")
	row.toggle().button_pressed = true
	await _frames(1)
	var panel: Control = sel.get_node("Panel")
	var pr: Rect2 = panel.get_global_rect()
	var content: Rect2 = Rect2(pr.position, panel.get_combined_minimum_size())
	_ok(
		Rect2(Vector2.ZERO, Vector2(1280, 720)).encloses(content),
		"%s: select panel fits %s" % [_mode, content]
	)
	_ok(
		Rect2(Vector2.ZERO, Vector2(1280, 720)).encloses(row.get_global_rect()),
		"select: row on screen"
	)
	sel.queue_free()
	await _frames(2)
	_done.append("select_ui")


## 데스크톱 배치는 상태 문구가 한 줄이어야 버튼 위치(menu_ux 기준선)가 상태에 따라 바뀌지 않는다.
func _check_status_one_line(row: GhostSelectRow, label: String) -> void:
	if _mode == "touch":
		return
	await get_tree().process_frame
	var lines: int = row._status.get_line_count()
	_ok(lines == 1, "select: %s status on one line (%d) '%s'" % [label, lines, row.status_text()])


func _check_result_ui() -> void:
	var base: Dictionary = _result(61000)
	var cases: Array = [
		[
			{"ghost_status": "saved", "is_new_record": true, "prev_best_ms": 62000},
			"새 개인 최고 고스트를 저장"
		],
		[
			{"ghost_status": "failed", "ghost_reason": "too_many_samples", "is_new_record": true},
			"24000"
		],
		[
			{"ghost_status": "failed", "ghost_reason": "write_failed", "is_new_record": true},
			"쓰지 못했"
		],
		[{"ghost_status": "unchanged", "ghost_reason": "record_save_failed"}, "이전 최고 기록과 고스트를 유지"],
		[
			{"ghost_status": "unchanged", "ghost_reason": "not_best", "prev_best_ms": 60000},
			"1.00초 느림"
		],
		[
			{"ghost_status": "unchanged", "ghost_reason": "not_best", "ghost_track_changed": true},
			"트랙이 바뀌어 이전 고스트를 쓸 수 없습니다 · 개인 최고를 갱신하면 새 고스트가 생깁니다"
		],
		[{"ghost_status": "saved", "practice": true}, "연습 기록"],
	]
	for c in cases:
		var res: Dictionary = base.duplicate()
		res.merge(c[0], true)
		var text: String = ResultScript.ghost_summary(res)
		_ok(text.contains(c[1]), "result summary contains '%s'" % c[1])
	# 결과 화면은 구간 차이를 보이지 않는다(데스크톱·터치 요약 모두, 옛 split_deltas 키가 있어도).
	var sp: Dictionary = base.duplicate()
	sp.merge({"ghost_status": "saved", "split_deltas": [-420, null, 130]})
	for compact in [false, true]:
		var t: String = ResultScript.ghost_summary(sp, compact)
		_ok(
			not t.contains("구간") and not t.contains("-0.42"), "result: no split line (%s)" % compact
		)
	var et: Dictionary = base.duplicate()
	et["editor_test"] = true
	et["ghost_status"] = "saved"
	_ok(ResultScript.ghost_summary(et).is_empty(), "result: editor test shows nothing")
	var shown: Dictionary = base.duplicate()
	shown.merge({"ghost_status": "failed", "ghost_reason": "write_failed", "is_new_record": true})
	GameState.last_result = shown
	var scr: Control = ResultScene.instantiate()
	get_tree().root.add_child(scr)
	await _frames(4)
	var lbl: Label = scr._ghost_label
	var want: String = "고스트 없음: 파일 쓰기 실패" if _mode == "touch" else "고스트는 없습니다"
	_ok(
		lbl != null and lbl.is_visible_in_tree() and lbl.text.contains(want),
		"result label: " + want
	)
	_ok(
		Rect2(Vector2.ZERO, Vector2(1280, 720)).encloses(lbl.get_global_rect()),
		"result label on screen"
	)
	scr.queue_free()
	await _frames(2)
	_done.append("result_ui")


func _check_purge() -> void:
	_reset_store()
	var id: String = (
		TrackLoader
		. save_custom_track(
			{
				"name": "Purge Me",
				"difficulty": DIFF,
				"fabric": "denim",
				"width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
				"path": [{"type": "polyline", "closed": false, "points": [[0, 0], [600, 0]]}],
			}
		)
	)
	var r: Dictionary = _result(20000, 0, id)
	RecordStore.submit_run(r, _synthetic_ghost(r, 600.0).to_ghost(r))
	var keep: Dictionary = _result(30000)
	RecordStore.submit_run(keep, _ghost_of(keep))
	var path: String = str(RecordStore.best_for(id, DIFF).get("ghost_file", ""))
	_ok(FileAccess.file_exists(path), "purge: custom ghost exists")
	_ok(TrackLoader.delete_custom_track(id) and RecordStore.purge(id), "purge: delete + purge")
	_ok(not FileAccess.file_exists(path), "purge: custom ghost removed")
	_ok(_ghost_files().size() == 1, "purge: other track ghost kept")
	_ok(not RecordStore.best_for(TRACK, DIFF).is_empty(), "purge: other record kept")
	_done.append("purge")


## 카운트다운 첫 프레임부터 미니맵이 주행 시작 위치·방향과 같은 변환으로 그린다(출발점이 마커 위,
## 주행 첫 틱과의 화면 위치 차이 < 1px). 원점이 아닌 곳에서 출발하는 트랙으로 검사한다.
func _check_minimap_countdown() -> void:
	for track_id in ["star_01", "ridge_01"]:
		GameState.track_id = track_id
		var g: Node = GameplayScene.instantiate()
		get_tree().root.add_child(g)
		await _frames(2)
		g.set_physics_process(false)
		var mm: MiniMap = g._hud._minimap
		var start: Vector2 = g._track.points[0]
		var p0: Vector2 = _map_point(mm, start)
		var center: Vector2 = mm.size * 0.5
		_ok(
			p0.distance_to(center) < 1.0,
			"%s countdown: start under marker (%.1fpx)" % [track_id, p0.distance_to(center)]
		)
		var ahead: Vector2 = _map_point(mm, g._track.point_at_s(60.0))
		_ok(
			ahead.y < center.y - 5.0 and absf(ahead.x - center.x) < 3.0,
			"%s countdown: path goes up" % track_id
		)
		# 첫 스텝은 카운트다운 → 주행 전환, 둘째 스텝이 주행 첫 틱(update_frame)이다.
		g._countdown_time = 0.0001
		_step(g, 2)
		await _frames(1)
		var p1: Vector2 = _map_point(mm, start)
		_ok(
			p1.distance_to(p0) < 1.0,
			"%s: first running tick moves start < 1px (%.2f)" % [track_id, p1.distance_to(p0)]
		)
		await _free_game(g)
	GameState.track_id = TRACK
	_done.append("minimap_countdown")


## 미니맵이 월드 점을 그리는 위치(_draw_route와 같은 변환).
func _map_point(mm: MiniMap, world: Vector2) -> Vector2:
	var preview: float = maxf(mm._display_speed * 4.0, 1.0)
	var scale_factor: float = (mm.size.x * 0.5) / preview
	var rot: float = -mm._heading - PI * 0.5
	return mm.size * 0.5 + (world - mm._player_pos).rotated(rot) * scale_factor


## 필드 위 고스트 마커: Mode 7 역투영 위치·크기, 뒤·근접·수평선 숨김, 도착 후 잠시 표시, 레이어 순서,
## 렌더 프레임과 무관한 위치(같은 물리 시각이면 같은 마커).
func _check_field_ghost() -> void:
	_reset_store()
	var r: Dictionary = _result(60000)
	RecordStore.submit_run(r, _ghost_of(r))
	var g: Node = await _new_game()
	var f: GhostFieldLayer = g.ghost_field()
	_ok(f != null, "field: layer built when ghost exists")
	if f == null:
		await _free_game(g)
		return
	var item_layer: CanvasLayer = g.get_node("ItemLayer")
	_ok(f.get_parent() == item_layer and f.get_index() == 0, "field: under item billboards")
	var fg: CanvasLayer = g.get_node("ForegroundLayer")
	_ok(
		item_layer.layer < fg.layer and fg.layer < g._hud.layer, "field: below hands/needle and HUD"
	)
	var p: PlayerController = g._player
	var fwd: Vector2 = Vector2.from_angle(p.heading)
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	var pc := PresentationController
	f.set_state({"pos": p.position + fwd * 200.0, "heading": p.heading, "arrived": false})
	var m: Dictionary = f.marker()
	var depth: float = 200.0 + pc.CAM_BACK
	var want: Vector2 = Vector2(640.0, (pc.HORIZON + pc.DEPTH_SCALE / depth) * 720.0)
	_ok(
		bool(m["visible"]) and (m["ground"] as Vector2).distance_to(want) < 0.5,
		"field: ahead projection %s" % m["ground"]
	)
	_ok(
		absf(float(m["scale"]) - GhostFieldLayer.SCALE * pc.CAM_BACK / depth) < 1e-4,
		"field: scale ∝ 1/depth"
	)
	_ok(
		absf(float(m["alpha"]) - GhostFieldLayer.BASE_ALPHA) < 1e-3,
		"field: full ghost alpha at 200"
	)
	f.set_state({"pos": p.position + fwd * 200.0 + rgt * 120.0, "heading": p.heading})
	_ok((f.marker()["ground"] as Vector2).x > 700.0, "field: side offset projects right")
	f.set_state({"pos": p.position - fwd * 60.0, "heading": p.heading})
	_ok(not bool(f.marker()["visible"]), "field: behind player hidden")
	f.set_state({"pos": p.position + fwd * 30.0, "heading": p.heading})
	_ok(not bool(f.marker()["visible"]), "field: overlapping player hidden (<40)")
	f.set_state({"pos": p.position + fwd * 65.0, "heading": p.heading})
	var mid: float = float(f.marker()["alpha"])
	_ok(mid > 0.0 and mid < GhostFieldLayer.BASE_ALPHA, "field: near player faded (%.2f)" % mid)
	f.set_state({"pos": p.position + fwd * 6000.0, "heading": p.heading})
	_ok(not bool(f.marker()["visible"]), "field: near horizon clipped")
	var arr: Dictionary = {"pos": p.position + fwd * 200.0, "heading": p.heading, "arrived": true}
	arr["since_finish_ms"] = 1000.0
	f.set_state(arr)
	_ok(bool(f.marker()["visible"]), "field: arrived ghost stays at finish briefly")
	arr["since_finish_ms"] = 1800.0
	f.set_state(arr.duplicate())
	_ok(float(f.marker()["alpha"]) < GhostFieldLayer.BASE_ALPHA, "field: arrival fades out")
	arr["since_finish_ms"] = 2500.0
	f.set_state(arr.duplicate())
	_ok(not bool(f.marker()["visible"]), "field: arrived ghost disappears")
	# 실제 주행: 레이어 상태 = 같은 물리 시각의 state_at, 렌더 프레임이 지나도 마커 불변.
	_drive(g, 90)
	var expect: Dictionary = g.ghost_playback().state_at(g._elapsed * 1000.0)
	_ok(f._state == expect, "field: state = state_at(physics elapsed), same as minimap")
	_ok(g._hud._minimap._ghost == expect, "field: minimap got the same state")
	var m0: Dictionary = f.marker()
	await _frames(3)
	_ok(f.marker() == m0, "field: render frames do not move marker (FPS independent)")
	await _free_game(g)
	_done.append("field_ghost")
