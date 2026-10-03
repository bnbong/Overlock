extends "res://ghost_regression/check_base.gd"
## 첫째 묶음: 기록 키(track_id|difficulty, 연습은 |practice)·지문에 따른 고스트 무효화, records.json
## 마이그레이션(v1 기록 = 현재 최고), 저장 순서와 실패 처리,
## 고아 정리·손상 파일·용량 상한, 고스트 샘플링·보간·복귀 즉시 이동·FPS 독립, 10구간 규칙. check.gd 가 상속한다.


func _check_ruleset() -> void:
	_ok(
		RecordStore.get("PHYSICS_RULESET") == null,
		"no physics ruleset constant (records not split)"
	)
	_ok(not RecordStore.has_method("current_ruleset"), "no current_ruleset API")
	if _mode == "practice":
		_ok(RecordStore.is_practice(), "practice: tuning override detected")
	else:
		# 저장소에 들어 있는 tuning.json 은 기본값과 같아야 한다(정식 기록이 practice 로 새지 않게).
		_ok(not RecordStore.is_practice(), "shipped tuning.json is not an override")
	_reset_store()
	var res: Dictionary = _result(60000)
	var out: Dictionary = RecordStore.submit_run(res)
	_ok(bool(out["is_best"]), "keys: first submit is best")
	var practice: bool = _mode == "practice"
	var key: String = RecordStore.record_key(TRACK, DIFF, practice)
	_ok(key == (TRACK + "|" + DIFF + ("|practice" if practice else "")), "keys: key " + key)
	var disk: Variant = _read_json(RecordStore.SAVE_PATH)
	_ok(disk is Dictionary and (disk["records"] as Dictionary).has(key), "keys: key on disk")
	_ok(disk is Dictionary and not (disk as Dictionary).has("legacy"), "keys: no legacy bucket")
	# practice 기록은 정식 키와 섞이지 않는다(반대 모드의 결과를 넣어도 현재 최고는 그대로).
	var foreign: Dictionary = _result(1000)
	foreign["practice"] = not practice
	RecordStore.submit_run(foreign)
	_ok(
		int(RecordStore.best_for(TRACK, DIFF)["final_time_ms"]) == 60000, "keys: practice not mixed"
	)
	_done.append("ruleset")


## 트랙을 편집해 지문이 바뀌면 기록은 그대로 최고로 두고 고스트만 비활성화한다. 이름만 바꾸면 고스트도 유효.
func _check_fingerprint() -> void:
	_reset_store()
	var fp: String = TrackLoader.track_fingerprint(TRACK)
	_ok(fp.begins_with("tf2:") and fp.length() > 20, "official fingerprint " + fp.left(16))
	TrackLoader._cache.erase(TRACK)
	TrackLoader._fingerprints.erase(TRACK)
	_ok(TrackLoader.track_fingerprint(TRACK) == fp, "official fingerprint stable after reload")
	_ok(TrackLoader.track_fingerprint("star_01") != fp, "different official tracks differ")
	var base: Dictionary = {
		"track_id": "",
		"name": "Ghost FP",
		"difficulty": DIFF,
		"fabric": "cotton",
		"width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
		"path": [{"type": "polyline", "closed": false, "points": [[0, 0], [400, 0], [800, 120]]}],
		"items": [{"s": 200.0, "lat": 0.0, "type": "thimble"}],
	}
	var id: String = TrackLoader.save_custom_track(base)
	base["track_id"] = id
	var fp0: String = TrackLoader.track_fingerprint(id)
	_ok(not fp0.is_empty(), "custom fingerprint")
	var sub: Dictionary = _result(30000, 0, id)
	RecordStore.submit_run(sub, _synthetic_ghost(sub, 800.0).to_ghost(sub))
	_ok(str(RecordStore.best_for(id, DIFF).get("track_fingerprint", "")) == fp0, "entry stores fp")
	_ok(RecordStore.ghost_state(id, DIFF) == "ready", "custom ghost ready")
	var renamed: Dictionary = base.duplicate(true)
	renamed["name"] = "Renamed Only"
	TrackLoader.save_custom_track(renamed)
	_ok(TrackLoader.track_fingerprint(id) == fp0, "rename keeps fingerprint")
	_ok(bool(RecordStore.load_ghost(id, DIFF)["ok"]), "rename: ghost still usable")
	var moved: Array = [[0, 0], [400, 10], [800, 120]]
	var orig: Array = [[0, 0], [400, 0], [800, 120]]
	var cases: Dictionary = {
		"path": ["path", [{"type": "polyline", "closed": false, "points": moved}]],
		"closed": ["path", [{"type": "polyline", "closed": true, "points": orig}]],
		"fabric": ["fabric", "silk"],
		"width": ["width", {"perfect": 18.0, "safe": 42.0, "fail": 80.0}],
		"items": ["items", [{"s": 260.0, "lat": 0.0, "type": "thimble"}]],
	}
	for label in cases:
		var edited: Dictionary = base.duplicate(true)
		edited[cases[label][0]] = cases[label][1]
		TrackLoader.save_custom_track(edited)
		_ok(TrackLoader.track_fingerprint(id) != fp0, "edit %s changes fingerprint" % label)
		var best: Dictionary = RecordStore.best_for(id, DIFF)
		_ok(int(best.get("final_time_ms", 0)) == 30000, "edit %s: record kept as best" % label)
		var lg: Dictionary = RecordStore.load_ghost(id, DIFF)
		_ok(
			not bool(lg["ok"]) and str(lg["reason"]) == "track_changed",
			"edit %s: old ghost disabled (track_changed)" % label
		)
		_ok(RecordStore.ghost_state(id, DIFF) == "track_changed", "edit %s: state" % label)
	# 편집된 트랙에서 더 느린 완주는 신기록이 아니므로 고스트가 생기지 않는다.
	var slow: Dictionary = _result(35000, 0, id)
	var o_slow: Dictionary = RecordStore.submit_run(
		slow, _synthetic_ghost(slow, 800.0).to_ghost(slow)
	)
	_ok(not bool(o_slow["is_best"]), "edited track: slower run not best")
	_ok(RecordStore.ghost_state(id, DIFF) == "track_changed", "edited track: still no ghost")
	# 최고를 갱신하면 새 지문으로 새 고스트가 생긴다.
	var fast: Dictionary = _result(25000, 0, id)
	RecordStore.submit_run(fast, _synthetic_ghost(fast, 800.0).to_ghost(fast))
	_ok(RecordStore.ghost_state(id, DIFF) == "ready", "edited track: new best -> new ghost ready")
	_ok(
		(
			str(RecordStore.best_for(id, DIFF)["track_fingerprint"])
			== TrackLoader.track_fingerprint(id)
		),
		"edited track: entry fp updated"
	)
	TrackLoader.save_custom_track(base)
	_ok(RecordStore.ghost_state(id, DIFF) == "track_changed", "revert edit: newer ghost now stale")
	TrackLoader.delete_custom_track(id)
	RecordStore.purge(id)
	_done.append("fingerprint")


## v1 records.json: 백업 후 기록을 그대로 현재 최고로 옮긴다(고스트 참조만 비어 있음).
func _check_migration() -> void:
	_reset_store()
	var v1: Dictionary = {
		TRACK + "|" + DIFF: _result(50000),
		"star_01|normal": _result(70000, 0, "star_01"),
	}
	var v1_text: String = JSON.stringify(v1)
	_write_text(RecordStore.SAVE_PATH, v1_text)
	RecordStore._load()
	_ok(RecordStore.load_state == "migrated", "migration: state migrated")
	var bak: String = RecordStore.SAVE_PATH + ".bak"
	_ok(FileAccess.get_file_as_string(bak) == v1_text, "migration: .bak holds original bytes")
	var disk: Variant = _read_json(RecordStore.SAVE_PATH)
	_ok(
		disk is Dictionary and int(disk.get("format_version", 0)) == 2,
		"migration: file rewritten as v2"
	)
	_ok(
		disk is Dictionary and (disk["records"] as Dictionary).size() == 2,
		"migration: both v1 records kept"
	)
	_ok(
		int(RecordStore.best_for(TRACK, DIFF).get("final_time_ms", 0)) == 50000,
		"v1 is current best"
	)
	_ok(int(RecordStore.best_for("star_01", DIFF).get("final_time_ms", 0)) == 70000, "v1 star best")
	_ok(RecordStore.ghost_state(TRACK, DIFF) == "no_ghost", "migration: v1 best has no ghost")
	var slow: Dictionary = _result(65000)
	var out: Dictionary = RecordStore.submit_run(slow, _ghost_of(slow))
	_ok(not bool(out["is_best"]), "migration: slower run does not beat v1 best")
	_ok(_ghost_files().is_empty(), "migration: no ghost from slower run")
	var fast: Dictionary = _result(48000)
	var o2: Dictionary = RecordStore.submit_run(fast, _ghost_of(fast))
	_ok(bool(o2["is_best"]) and str(o2["ghost_status"]) == "saved", "migration: faster run + ghost")
	_ok(RecordStore.ghost_state(TRACK, DIFF) == "ready", "migration: ghost ready after new best")
	RecordStore._load()
	_ok(RecordStore.load_state == "ok", "migration: reload v2 ok (restart)")
	_ok(int(RecordStore.best_for(TRACK, DIFF)["final_time_ms"]) == 48000, "restart: best persists")
	_ok(int(RecordStore.best_for("star_01", DIFF)["final_time_ms"]) == 70000, "restart: v1 kept")
	# 개발 중 잠시 쓰던 규칙 분리 v2 파일("id|diff|규칙|지문" + legacy)은 현재 키로 합친다.
	_reset_store()
	var dev: Dictionary = {
		"format_version": 2,
		"records":
		{
			TRACK + "|" + DIFF + "|fabric-v1|tf2:x": _result(52000),
			TRACK + "|" + DIFF + "|practice|tf2:x": _result(40000),
		},
		"legacy": {TRACK + "|" + DIFF: _result(51000)},
	}
	_write_text(RecordStore.SAVE_PATH, JSON.stringify(dev))
	RecordStore._load()
	var keys: Array = RecordStore._records.keys()
	keys.sort()
	_ok(keys == [TRACK + "|" + DIFF, TRACK + "|" + DIFF + "|practice"], "dev keys merged %s" % keys)
	_ok(
		int(RecordStore._records[TRACK + "|" + DIFF]["final_time_ms"]) == 51000,
		"dev merge keeps min"
	)
	# 손상 파일: 빈 저장소로 읽고, 첫 쓰기 전에 .bak-* 로 보존한다.
	_reset_store()
	_write_text(RecordStore.SAVE_PATH, "{broken")
	RecordStore._load()
	_ok(RecordStore.load_state == "corrupt", "corrupt records: state corrupt")
	RecordStore.submit(_result(61000))
	_ok(_bak_with("{broken"), "corrupt records preserved before overwrite")
	# 미지원(미래) 형식 버전.
	_reset_store()
	var future: String = JSON.stringify({"format_version": 9, "records": {}})
	_write_text(RecordStore.SAVE_PATH, future)
	RecordStore._load()
	_ok(RecordStore.load_state == "version", "future version: not read")
	RecordStore.submit(_result(61000))
	_ok(_bak_with(future), "future version preserved before overwrite")
	_done.append("migration")


func _bak_with(text: String) -> bool:
	var root: DirAccess = DirAccess.open("user://")
	for f in root.get_files():
		if (
			f.begins_with("records.json.bak")
			and FileAccess.get_file_as_string("user://" + f) == text
		):
			return true
	return false


func _ghost_of(res: Dictionary) -> Dictionary:
	return _synthetic_ghost(res).to_ghost(res, {"steer_expo": 0.55})


## 저장 순서·실패 처리: 미갱신·갱신·고스트 쓰기 실패·기록 저장 실패·고아 정리·손상·미지원·불일치.
func _check_save_flow() -> void:
	_reset_store()
	var r1: Dictionary = _result(60000)
	var o1: Dictionary = RecordStore.submit_run(r1, _ghost_of(r1))
	var best1: Dictionary = RecordStore.best_for(TRACK, DIFF)
	var path1: String = str(best1.get("ghost_file", ""))
	_ok(bool(o1["is_best"]) and str(o1["ghost_status"]) == "saved", "flow: first best + ghost")
	_ok(FileAccess.file_exists(path1), "flow: ghost file exists")
	var hdr: Variant = _read_json(path1)
	_ok(
		hdr is Dictionary and str(hdr["run_id"]) == str(best1["ghost_run_id"]),
		"flow: run_id linked"
	)
	_ok(bool(RecordStore.load_ghost(TRACK, DIFF)["ok"]), "flow: ghost loads")
	_ok(RecordStore.ghost_state(TRACK, DIFF) == "ready", "flow: ghost state ready")
	# 미갱신(느림·동률): 기록·고스트 그대로.
	for ms in [62000, 60000]:
		var rs: Dictionary = _result(ms)
		var os: Dictionary = RecordStore.submit_run(rs, _ghost_of(rs))
		_ok(
			not bool(os["is_best"]) and str(os["ghost_reason"]) == "not_best",
			"flow: %d not best" % ms
		)
		_ok(
			str(RecordStore.best_for(TRACK, DIFF)["ghost_file"]) == path1,
			"flow: %d keeps ghost" % ms
		)
	_ok(_ghost_files().size() == 1, "flow: no stray ghost after non-best")
	# 갱신: 새 고스트, 이전 고스트 삭제.
	var r2: Dictionary = _result(58000)
	RecordStore.submit_run(r2, _ghost_of(r2))
	var path2: String = str(RecordStore.best_for(TRACK, DIFF)["ghost_file"])
	_ok(path2 != path1 and FileAccess.file_exists(path2), "flow: improved best has new ghost")
	_ok(not FileAccess.file_exists(path1), "flow: previous ghost removed after record saved")
	# 고스트 쓰기 실패: 기록은 저장, 고스트 없음 표시, 이전 고스트를 새 최고처럼 보이지 않음.
	GhostStore.faults["ghost"] = true
	var r3: Dictionary = _result(57000)
	var o3: Dictionary = RecordStore.submit_run(r3, _ghost_of(r3))
	GhostStore.faults.clear()
	_ok(bool(o3["is_best"]), "ghost write fail: record still saved")
	_ok(
		str(o3["ghost_status"]) == "failed" and str(o3["ghost_reason"]) == "write_failed",
		"fail status"
	)
	_ok(
		str(RecordStore.best_for(TRACK, DIFF)["ghost_file"]).is_empty(), "ghost write fail: no link"
	)
	_ok(RecordStore.ghost_state(TRACK, DIFF) == "no_ghost", "ghost write fail: state no_ghost")
	_ok(
		str(RecordStore.load_ghost(TRACK, DIFF)["reason"]) == "no_ghost",
		"old ghost not shown as new"
	)
	_ok(_ghost_files().is_empty(), "ghost write fail: no files left")
	# 다시 고스트가 있는 최고를 만든 뒤 기록 저장 실패: 기존 최고·고스트 유지, 새 고스트 파일 안 남김.
	var r4: Dictionary = _result(56000)
	RecordStore.submit_run(r4, _ghost_of(r4))
	var path4: String = str(RecordStore.best_for(TRACK, DIFF)["ghost_file"])
	GhostStore.faults["records"] = true
	var r5: Dictionary = _result(50000)
	var o5: Dictionary = RecordStore.submit_run(r5, _ghost_of(r5))
	GhostStore.faults.clear()
	_ok(not bool(o5["is_best"]) and str(o5["ghost_reason"]) == "record_save_failed", "record fail")
	_ok(
		int(RecordStore.best_for(TRACK, DIFF)["final_time_ms"]) == 56000,
		"record fail: memory restored"
	)
	RecordStore._load()
	_ok(
		int(RecordStore.best_for(TRACK, DIFF)["final_time_ms"]) == 56000,
		"record fail: disk unchanged"
	)
	_ok(_ghost_files() == [path4.get_file()], "record fail: only previous ghost remains")
	_ok(bool(RecordStore.load_ghost(TRACK, DIFF)["ok"]), "record fail: previous ghost still loads")
	_check_orphans(path4)
	_check_bad_files(path4)
	_done.append("save_flow")


## 중간 종료로 남은 고아 파일·임시 파일은 다음 실행 정리에서 지우고 참조 파일·다른 파일은 둔다.
func _check_orphans(keep_path: String) -> void:
	_write_text(GhostStore.DIR + "g1234abcd.json", "{}")
	_write_text(GhostStore.DIR + "g99887766.json.tmp", "{")
	_write_text(GhostStore.DIR + "notes.txt", "keep")
	var removed: int = GhostStore.cleanup_orphans(RecordStore._referenced_ghosts())
	_ok(removed == 2, "orphans: removed 2 (%d)" % removed)
	_ok(FileAccess.file_exists(keep_path), "orphans: referenced ghost kept")
	_ok(FileAccess.file_exists(GhostStore.DIR + "notes.txt"), "orphans: unrelated file kept")
	DirAccess.remove_absolute(GhostStore.DIR + "notes.txt")


## 손상·미지원·불일치 고스트는 고스트만 비활성화하고 기록은 그대로 둔다.
func _check_bad_files(path: String) -> void:
	var good: String = FileAccess.get_file_as_string(path)
	var variants: Dictionary = {
		"corrupt": "{oops", "unsupported": "", "mismatch": "", "invalid": ""
	}
	var d: Dictionary = JSON.parse_string(good)
	var v2: Dictionary = d.duplicate(true)
	v2["format_version"] = 2
	variants["unsupported"] = JSON.stringify(v2)
	var mm: Dictionary = d.duplicate(true)
	mm["track_fingerprint"] = "tf1:other"
	variants["mismatch"] = JSON.stringify(mm)
	var bad: Dictionary = d.duplicate(true)
	var samples: Array = bad["samples"]
	samples[GhostRun.STRIDE] = 999999.0  # 시각 단조성 위반
	variants["invalid"] = JSON.stringify(bad)
	for reason in variants:
		_write_text(path, variants[reason])
		var lg: Dictionary = RecordStore.load_ghost(TRACK, DIFF)
		_ok(not bool(lg["ok"]) and str(lg["reason"]) == reason, "bad ghost %s detected" % reason)
		_ok(not RecordStore.best_for(TRACK, DIFF).is_empty(), "bad ghost %s: record kept" % reason)
	_write_text(path, good)
	_ok(bool(RecordStore.load_ghost(TRACK, DIFF)["ok"]), "restored ghost loads again")


## 용량 상한: 샘플 24000개 초과면 그 런의 고스트를 만들지 않고(잘린 파일 없음) 기록은 저장한다.
## 파일 2MiB 초과도 저장하지 않는다.
func _check_capacity() -> void:
	_reset_store()
	var g: GhostRun = GhostRun.new()
	g.setup(1000.0)
	g.begin(Vector2.ZERO, 0.0)
	var t: float = 0.0
	while g.sample_count() < GhostRun.MAX_SAMPLES:
		t += 0.05
		g.on_tick(t, Vector2(t, 0.0), 0.0, minf(t, 999.0), 0.0)
	_ok(not g._overflow, "capacity: exactly at limit is not overflow yet")
	t += 0.2
	g.on_tick(t, Vector2(t, 0.0), 0.0, 999.0, 0.0)
	var res: Dictionary = _result(int(t * 1000.0) + 50)
	g.on_finish(res, Vector2.ZERO, 0.0, 1000.0)
	_ok(g.skip_reason() == "too_many_samples", "capacity: over limit -> too_many_samples")
	_ok(g.to_ghost(res).is_empty(), "capacity: no truncated ghost dict")
	var out: Dictionary = RecordStore.submit_run(res, g.to_ghost(res), g.skip_reason())
	_ok(bool(out["is_best"]), "capacity: record still saved")
	_ok(str(out["ghost_reason"]) == "too_many_samples", "capacity: reason reported")
	_ok(_ghost_files().is_empty(), "capacity: no ghost file written")
	var r2: Dictionary = _result(30000)
	var pad: Dictionary = {"pad": "x".repeat(GhostStore.MAX_BYTES)}
	var big: Dictionary = _synthetic_ghost(r2).to_ghost(r2, pad)
	var o2: Dictionary = RecordStore.submit_run(r2, big)
	_ok(str(o2["ghost_reason"]) == "too_large" and bool(o2["is_best"]), "capacity: >2MiB rejected")
	_ok(_ghost_files().is_empty(), "capacity: no oversized file")
	_done.append("capacity")


## 샘플링·보간·복귀 즉시 이동·각도 보간·FPS 독립.
func _check_playback() -> void:
	# 물리 주기 30/60/120Hz로 같은 등속 운동을 기록하면 샘플이 같은 50ms 격자 근처에 놓이고,
	# 같은 시각의 재생 위치가 서로 같다(렌더 FPS·물리 주기에 샘플링이 묶이지 않음).
	var runs: Array = []
	for hz in [30, 60, 120]:
		var g: GhostRun = GhostRun.new()
		g.setup(1000.0)
		g.begin(Vector2.ZERO, 0.0)
		var dt: float = 1.0 / float(hz)
		var steps: int = hz * 4
		for i in steps:
			var tt: float = float(i + 1) * dt
			g.on_tick(tt, Vector2(100.0 * tt, 0.0), 0.0, 100.0 * tt, 0.0)
		var res: Dictionary = _result(4000)
		g.on_finish(res, Vector2(400.0, 0.0), 0.0, 400.0)
		runs.append(GhostRun.from_dict(g.to_ghost(res)))
	var worst: float = 0.0
	for q in [130.0, 777.0, 1999.0, 3050.0]:
		var p30: Vector2 = runs[0].state_at(q)["pos"]
		for r in runs:
			worst = maxf(
				worst, (r.state_at(q)["pos"] as Vector2).distance_to(Vector2(q * 0.1, 0.0))
			)
			worst = maxf(worst, (r.state_at(q)["pos"] as Vector2).distance_to(p30))
	_ok(worst < 0.3, "fps: 30/60/120Hz recordings agree (max err %.3f px)" % worst)
	var counts: Array = runs.map(func(r: GhostRun) -> int: return r.sample_count())
	_ok(
		absi(counts[0] - counts[2]) <= 2,
		"fps: sample count independent of tick rate %s" % str(counts)
	)
	# 같은 물리 시간이면 렌더 프레임 수와 무관하게 같은 위치(순수 함수).
	var gp: GhostRun = runs[1]
	var acc: Array = []
	for hz in [30, 60, 120]:
		var e: float = 0.0
		for i in hz:
			e += 1.0 / float(hz)
		acc.append(gp.state_at(e * 1000.0)["pos"])
	_ok(
		acc[0].distance_to(acc[2]) < 0.01 and acc[1].distance_to(acc[2]) < 0.01,
		"fps: same time same pos"
	)
	# 각도 보간(±π 경계).
	var ga: GhostRun = GhostRun.new()
	ga.setup(100.0)
	ga.begin(Vector2.ZERO, 3.1)
	ga.on_tick(0.1, Vector2(1, 0), -3.1, 1.0, 0.0)
	var rr: Dictionary = _result(200)
	ga.on_finish(rr, Vector2(2, 0), -3.1, 100.0)
	var mid: float = GhostRun.from_dict(ga.to_ghost(rr)).state_at(50.0)["heading"]
	_ok(absf(absf(mid) - PI) < 0.05, "angle lerp across ±pi (%.3f)" % mid)
	# 복귀 이벤트: 복귀 직전까지는 이전 구간을 보간하고, 복귀 시각에 즉시 이동한다(중간 위치 없음).
	var gr: GhostRun = GhostRun.new()
	gr.setup(1000.0)
	gr.begin(Vector2.ZERO, 0.0)
	for i in 60:
		var tt: float = float(i + 1) / 60.0
		gr.on_tick(tt, Vector2(300.0 * tt, 0.0), 0.0, 300.0 * tt, 0.0)
	gr.on_reset(1.0 + DT, Vector2(320, 80), 0.5, 320.0, Vector2(200, 0), 0.0, 200.0)
	for i in 60:
		var tt: float = 1.0 + DT + float(i + 1) / 60.0
		gr.on_tick(tt, Vector2(200.0 + 100.0 * (tt - 1.0), 0.0), 0.0, 200.0, 0.0)
	var rres: Dictionary = _result(2100)
	gr.on_finish(rres, Vector2(310, 0), 0.0, 1000.0)
	var pr: GhostRun = GhostRun.from_dict(gr.to_ghost(rres))
	var reset_ms: float = float(int((1.0 + DT) * 1000.0))
	var after: Vector2 = pr.state_at(reset_ms)["pos"]
	_ok(after.distance_to(Vector2(200, 0)) < 0.2, "reset: jumps to post position at reset time")
	var crossed_mid: bool = false
	for k in 40:
		var p: Vector2 = pr.state_at(reset_ms - 40.0 + float(k))["pos"]
		if p.x < 280.0 and p.x > 210.0:
			crossed_mid = true
	_ok(not crossed_mid, "reset: no interpolation across the discontinuity")
	_done.append("playback")


## 10구간: 최초 통과·후진 중복 없음·선형 보간·복귀로 건너뛴 구간 비교 불가·최종 구간 = 실제 완주.
func _check_splits() -> void:
	var g: GhostRun = GhostRun.new()
	g.setup(1000.0)
	g.begin(Vector2.ZERO, 0.0)
	var c1: Array = g.on_tick(1.0, Vector2.ZERO, 0.0, 90.0, 0.0)
	var c2: Array = g.on_tick(2.0, Vector2.ZERO, 0.0, 110.0, 0.5)
	_ok(c1.is_empty() and c2 == [0], "split 1 crossed once between 90 and 110")
	_ok(g.split_t[0] == 1500 and g.split_pen[0] == 500, "split 1 interpolated t=1500 pen=500")
	g.on_tick(3.0, Vector2.ZERO, 0.0, 80.0, 0.5)
	var c3: Array = g.on_tick(4.0, Vector2.ZERO, 0.0, 120.0, 0.5)
	_ok(c3.is_empty() and g.split_t[0] == 1500, "backtrack + re-cross does not re-record")
	var c4: Array = g.on_tick(5.0, Vector2.ZERO, 0.0, 190.0, 0.5)
	var c5: Array = g.on_tick(6.0, Vector2.ZERO, 0.0, 210.0, 0.5)
	_ok(c4.is_empty() and c5 == [1] and g.split_t[1] == 5500, "split 2 uses prev/cur progress lerp")
	g.on_reset(6.5, Vector2.ZERO, 0.0, 220.0, Vector2.ZERO, 0.0, 350.0)
	_ok(
		g.split_valid[2] == 0 and g.split_value(2) == -1,
		"split 3 skipped by reset -> not comparable"
	)
	var c6: Array = g.on_tick(7.0, Vector2.ZERO, 0.0, 420.0, 1.0)
	_ok(c6 == [3] and g.split_valid[3] == 1, "split 4 after reset valid (interpolated from post)")
	var res: Dictionary = _result(30000, 4000)
	var c7: Array = g.on_finish(res, Vector2.ZERO, 0.0, 999.5)
	_ok(9 in c7 and g.split_value(9) == 30000, "final split = finish_ms + penalty_ms")
	_ok(
		g.split_valid[4] == 1 and g.split_valid[8] == 1,
		"remaining boundaries crossed on finish tick"
	)
	# 순수 주행은 빠르지만 패널티 포함 느린 런: 기록은 갱신하지 않고 구간 차이는 양수(느림).
	_reset_store()
	var ghost_res: Dictionary = _result(60000, 0)
	RecordStore.submit_run(ghost_res, _ghost_of(ghost_res))
	var run_res: Dictionary = _result(63000, 8000)  # 주행 55.0s + 패널티 8.0s
	var mine: GhostRun = _synthetic_ghost(run_res)
	var theirs: GhostRun = RecordStore.load_ghost(TRACK, DIFF)["run"]
	var mid_t: float = 27000.0
	_ok(
		(mine.state_at(mid_t)["s"] as float) > (theirs.state_at(mid_t)["s"] as float),
		"pure-faster run: own marker ahead of ghost at same time"
	)
	_ok(
		mine.split_value(4) - theirs.split_value(4) > 0,
		"pure-faster run: split delta slower (penalty)"
	)
	var out: Dictionary = RecordStore.submit_run(run_res, mine.to_ghost(run_res))
	_ok(not bool(out["is_best"]), "pure-faster but penalized run is not a new best")
	# 고스트가 먼저 완주: 결승 위치에 멈추고 도착 표시.
	var st: Dictionary = theirs.state_at(61000.0)
	_ok(
		bool(st["arrived"]) and (st["pos"] as Vector2).distance_to(Vector2(1000, 0)) < 0.2,
		"ghost arrived"
	)
	_ok(absf(float(st["since_finish_ms"]) - 1000.0) < 0.5, "ghost arrival time since finish")
	_done.append("splits")
