extends "res://community_hub_regression/check_fixes.gd"
## 공유 허브 클라이언트 회귀 검사(사본 프로젝트 전용, run.sh 가 실행한다).
##
## 구획:
##  fixtures : server/tests/fixtures/community_tracks/*.json 을 TrackData.bake +
##             TrackValidator.validate 로 판정해 expect·reject_reasons·expected_length 와
##             대조(허브 가져오기 판정도 같은지 확인).
##  import   : 기존 import_custom_from_text 기본 동작 보존(경로가 같으면 duplicate).
##  hub      : 허브 가져오기(아이템 보존, 재다운로드 재저장 없음, 같은 경로·다른 폭/아이템, 로컬 삭제·
##             편집 후 매핑 정리, 손상 manifest, 저장 실패, 형식 오류 거부, 로컬 id 발급).
##  records  : 같은 경로·다른 내용 트랙의 로컬 기록 키 분리.
##  publish  : 게시 payload 허용 필드만, 토큰이 트랙 JSON·내보내기·payload·manifest 에 없음.
##  restart  : 새 TrackLoader 노드로 목록·매핑 유지 확인.
##  classify : 상태 분류 순수 함수(401/403/404/413/422/429/5xx/타임아웃/연결 실패).
##  server   : 로컬 서버로 게시·목록·검색·상세·삭제·404·422·413·403·연타·대체·취소·네트워크 오류·
##             타임아웃·오프라인·토큰 저장 실패·허브 화면 늦은 응답 폐기.
##  fixes    : 교차 리뷰 수정 항목(check_fixes.gd): 저장소 내구성(.tmp 검증·복구, .bak 보존), 헤더,
##             목록 잘라내기·클램프, bidi 문자 제거, 201 형식 오류, 종류별 404·401·403, 저장하지 못한
##             토큰 재표시, 업로드 중 이탈 차단, 더 보기 offset, 작성자 Label 분리, 좌표 상한.
##  limited  : 게시 분당 1회 서버로 429 와 자동 재시도 없음 확인.
## 인자(-- 뒤): --fixtures=<dir> --api=<url> --api-limited=<url> --api-silent=<url>
## 실패한 assertion 이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const SECTIONS: Array[String] = [
	"fixtures", "import", "hub", "records", "publish", "restart", "classify", "server", "fixes",
	"limited"
]
const MIN_PASSED: int = 120
const ResultScene: PackedScene = preload("res://scenes/Result.tscn")


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
	CommunityTrackClient.completed.connect(func(r: Dictionary) -> void: _results.append(r))
	await get_tree().process_frame
	_check_fixtures()
	_check_import_default()
	_check_hub_import()
	_check_records()
	_check_publish_payload()
	_check_restart()
	_check_classify()
	await _check_server()
	await _check_fixes()
	await _check_limited()
	for s in SECTIONS:
		_ok(_done.has(s), "section completed: " + s)
	_ok(_passed >= MIN_PASSED, "at least %d assertions ran (got %d)" % [MIN_PASSED, _passed])
	print("community hub regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check_fixtures() -> void:
	var dir: DirAccess = DirAccess.open(_args.get("fixtures", ""))
	_ok(dir != null, "fixture dir opens")
	if dir == null:
		return
	var count: int = 0
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var fx: Variant = _read_json(_args["fixtures"] + "/" + f)
		if not (fx is Dictionary):
			_ok(false, "fixture parses: " + f)
			continue
		count += 1
		var track: Dictionary = fx["track"]
		var td: TrackData = TrackData.new()
		td.bake(track["path"])
		var fail: float = float(track["width"]["fail"])
		var res: Dictionary = TrackValidator.new().validate(td.points, fail)
		var accept: bool = str(fx["expect"]) == "accept"
		_ok(
			bool(res["ok"]) == accept,
			"%s: ok=%s expect=%s %s" % [f, res["ok"], fx["expect"], res["messages"]]
		)
		var tol: float = float(fx["length_tolerance"])
		var got_len: float = float(res["length"])
		_ok(
			absf(got_len - float(fx["expected_length"])) <= tol,
			"%s: length %.2f vs %.2f" % [f, got_len, float(fx["expected_length"])]
		)
		var reasons: Array = []
		if td.points.size() < TrackValidator.MIN_POINTS:
			reasons.append("min_points")
		else:
			if str(res["length_status"]) in ["too_short", "too_long"]:
				reasons.append("length")
			for v in res["curvature"]:
				if str(v["kind"]) == "hard" and not reasons.has("curvature"):
					reasons.append("curvature")
			for p in res["proximity"]:
				if str(p["kind"]) == "hard" and not reasons.has("proximity"):
					reasons.append("proximity")
		var want: Array = fx["reject_reasons"]
		reasons.sort()
		want = want.duplicate()
		want.sort()
		_ok(reasons == want, "%s: reasons %s vs %s" % [f, reasons, want])
		print(
			(
				(
					"fixture %s expect=%s godot_ok=%s length=%.2f expected=%.2f"
					+ " baked=%d expected_baked=%d reasons=%s"
				)
				% [
					f,
					fx["expect"],
					res["ok"],
					got_len,
					float(fx["expected_length"]),
					td.points.size(),
					int(fx["expected_baked_points"]),
					reasons
				]
			)
		)
		# 허브 가져오기 판정(형식 검사 + 스냅 경로 보존)도 같은 결론이어야 한다.
		var prep: Dictionary = TrackLoader._prepare_import(JSON.stringify(track), "fx", true)
		_ok(
			bool(prep["ok"]) == accept,
			"%s: hub prepare ok=%s (%s)" % [f, prep["ok"], prep.get("message", "")]
		)
	_ok(count >= 10, "at least 10 fixtures (got %d)" % count)
	_done.append("fixtures")


# --- 기존 가져오기 보존 ---


func _check_import_default() -> void:
	var fx: Dictionary = _fixture("accept_stadium_expert")
	var text: String = JSON.stringify(fx["track"])
	var r1: Dictionary = TrackLoader.import_custom_from_text(text, "stadium")
	_ok(bool(r1["ok"]) and str(r1["status"]) == "ok", "default import ok: %s" % r1)
	var r2: Dictionary = TrackLoader.import_custom_from_text(text, "stadium")
	_ok(
		str(r2["status"]) == "duplicate" and r2["track_id"] == r1["track_id"],
		"same path -> duplicate"
	)
	var t2: Dictionary = (fx["track"] as Dictionary).duplicate(true)
	t2["width"] = {"perfect": 10, "safe": 30, "fail": 70}
	t2["fabric"] = "silk"
	var r3: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(t2), "stadium2")
	_ok(
		str(r3["status"]) == "duplicate",
		"default import keeps path-only duplicate rule (width differs)"
	)
	var saved: Variant = JSON.parse_string(_file_text(str(r1["track_id"])))
	_ok(
		saved is Dictionary and not (saved as Dictionary).has("items"), "default import drops items"
	)
	_done.append("import")


# --- 허브 가져오기 ---


func _check_hub_import() -> void:
	var items: Array = [
		{"s": 1200.0, "type": "thimble", "lat": 0.0, "respawn": 5, "evil": "x"},
		{"s": 2694.9, "type": "autopilot", "lat": -10.0},
		{"s": 300.0, "type": "thimble"},
	]
	var t_a: Dictionary = _hub_track({}, items)
	t_a["track_id"] = "../../evil"
	t_a["checksum"] = "sha256:bogus"
	t_a["is_custom"] = false
	var files0: int = _custom_files().size()
	var ra: Dictionary = TrackLoader.import_hub_track(_post(_uuid(1), t_a, "sha256:aaa", "Hub A"))
	_ok(bool(ra["ok"]) and str(ra["status"]) == "ok", "hub import A ok: %s" % ra)
	var id_a: String = str(ra["track_id"])
	_ok(CommunityStore.is_valid_local_id(id_a), "hub import issues fresh custom_ id: " + id_a)
	_ok(
		not id_a.contains(_uuid(1)) and not id_a.contains("evil"),
		"local id ignores server id/track_id"
	)
	_ok(_custom_files().size() == files0 + 1, "one new file for A")
	var saved: Dictionary = JSON.parse_string(_file_text(id_a))
	_ok(str(saved["track_id"]) == id_a and bool(saved["is_custom"]), "saved header uses local id")
	_ok((saved["items"] as Array).size() == 3, "items preserved (3)")
	var item_keys_ok: bool = true
	for it in saved["items"]:
		for k in (it as Dictionary).keys():
			if not (k in ["s", "type", "lat"]):
				item_keys_ok = false
	_ok(item_keys_ok, "items keep only s/type/lat")
	_ok(float(saved["items"][2]["lat"]) == 0.0, "missing lat filled with 0")
	var loaded: TrackData = TrackLoader.load_track(id_a)
	_ok(loaded != null and loaded.items.size() == 3, "loaded track exposes items")
	var max_s: float = 0.0
	for it in loaded.items:
		max_s = maxf(max_s, float(it["s"]))
	_ok(
		loaded != null and max_s <= loaded.length,
		"item s within baked length (%.3f <= %.3f)" % [max_s, loaded.length]
	)
	var src_pts: Array = t_a["path"][0]["points"]
	var got_pts: Array = saved["path"][0]["points"]
	var same_pts: bool = src_pts.size() == got_pts.size()
	for i in range(mini(src_pts.size(), got_pts.size())):
		if (
			absf(float(src_pts[i][0]) - float(got_pts[i][0])) > 0.051
			or absf(float(src_pts[i][1]) - float(got_pts[i][1])) > 0.051
		):
			same_pts = false
	_ok(same_pts, "hub import keeps server polyline without resampling (%d pts)" % got_pts.size())
	var fx: Dictionary = _fixture("accept_sparse_s_curve")
	_ok(
		absf(loaded.length - float(fx["expected_length"])) <= 1.0,
		"hub track length matches fixture"
	)
	var entry: Dictionary = CommunityStore.download_entry(_uuid(1))
	_ok(
		(
			str(entry.get("track_id", "")) == id_a
			and str(entry.get("content_hash", "")) == "sha256:aaa"
		),
		"manifest maps post->local"
	)
	_ok(TrackLoader.is_unmodified_hub_download(id_a), "A counts as unmodified download")

	# 재다운로드 → 재저장 없음
	var before_text: String = _file_text(id_a)
	var ra2: Dictionary = TrackLoader.import_hub_track(_post(_uuid(1), t_a, "sha256:aaa", "Hub A"))
	_ok(
		str(ra2["status"]) == "duplicate" and str(ra2["track_id"]) == id_a,
		"re-download same post -> duplicate"
	)
	_ok(
		_custom_files().size() == files0 + 1 and _file_text(id_a) == before_text,
		"re-download does not re-save"
	)

	# 같은 경로·다른 폭 / 다른 아이템 → 서로 다른 로컬 트랙
	var t_b: Dictionary = _hub_track(
		{"perfect": 12.0, "safe": 30.0, "fail": 70.0}, items.slice(0, 2)
	)
	var rb: Dictionary = TrackLoader.import_hub_track(_post(_uuid(2), t_b, "sha256:bbb", "Hub B"))
	var t_c: Dictionary = _hub_track({}, [{"s": 500.0, "type": "autopilot", "lat": 5.0}])
	var rc: Dictionary = TrackLoader.import_hub_track(_post(_uuid(3), t_c, "sha256:ccc", "Hub C"))
	_ok(bool(rb["ok"]) and bool(rc["ok"]), "B and C import ok")
	var ids: Dictionary = {id_a: true, str(rb["track_id"]): true, str(rc["track_id"]): true}
	_ok(ids.size() == 3, "same path with different width/items -> 3 distinct local tracks")
	_ok(_custom_files().size() == files0 + 3, "3 files for A/B/C")
	var saved_b: Dictionary = JSON.parse_string(_file_text(str(rb["track_id"])))
	_ok(float(saved_b["width"]["fail"]) == 70.0, "B keeps its own width")
	# 기존 기본 가져오기는 허브 트랙이 있어도 자기 규칙(재표본화 경로 체크섬)대로 중복 판정한다.
	var def1: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(t_c), "plain")
	var def2: Dictionary = TrackLoader.import_custom_from_text(JSON.stringify(t_b), "plain2")
	_ok(str(def1["status"]) == "ok", "default import of hub-shaped JSON saves its own copy")
	_ok(
		str(def2["status"]) == "duplicate" and def2["track_id"] == def1["track_id"],
		"default import keeps path-only duplicate rule next to hub copies"
	)
	_ok(
		TrackLoader.is_unmodified_hub_download(str(rc["track_id"])),
		"hub copy C untouched by default import"
	)

	# 서버 content_hash 가 매핑과 다르면 새로 저장
	var rc2: Dictionary = TrackLoader.import_hub_track(_post(_uuid(3), t_c, "sha256:ccc2", "Hub C"))
	_ok(
		str(rc2["status"]) == "ok" and str(rc2["track_id"]) != str(rc["track_id"]),
		"different content_hash -> new save"
	)
	_ok(
		str(CommunityStore.download_entry(_uuid(3))["track_id"]) == str(rc2["track_id"]),
		"mapping follows new save"
	)

	# 로컬 파일 삭제 → 매핑 정리 후 재다운로드
	TrackLoader.delete_custom_track(id_a)
	_ok(
		not TrackLoader.is_unmodified_hub_download(id_a),
		"deleted file no longer counts as download"
	)
	var ra3: Dictionary = TrackLoader.import_hub_track(_post(_uuid(1), t_a, "sha256:aaa", "Hub A"))
	_ok(
		str(ra3["status"]) == "ok" and str(ra3["track_id"]) != id_a,
		"after local delete -> re-saved with new id"
	)
	_ok(
		str(CommunityStore.download_entry(_uuid(1))["track_id"]) == str(ra3["track_id"]),
		"mapping replaced after delete"
	)

	# 로컬 편집(폭 변경) → 지문 불일치 → 새로 저장, 편집본은 게시 가능한 내 트랙으로 남음
	var id_b: String = str(rb["track_id"])
	var edited: Dictionary = JSON.parse_string(_file_text(id_b))
	edited["width"] = {"perfect": 14.0, "safe": 34.0, "fail": 80.0}
	TrackLoader.save_custom_track(edited)
	_ok(not TrackLoader.is_unmodified_hub_download(id_b), "edited download is not 'unmodified'")
	var rb2: Dictionary = TrackLoader.import_hub_track(_post(_uuid(2), t_b, "sha256:bbb", "Hub B"))
	_ok(
		str(rb2["status"]) == "ok" and str(rb2["track_id"]) != id_b,
		"edited local copy -> fresh download saved"
	)
	_ok(FileAccess.file_exists(TrackLoader.CUSTOM_DIR + id_b + ".json"), "edited copy kept")
	_ok(
		TrackLoader.is_unmodified_hub_download(str(rb2["track_id"])),
		"fresh copy is unmodified download"
	)

	# 손상된 manifest → 무시하고 재생성
	var f: FileAccess = FileAccess.open(CommunityStore.DOWNLOADS_PATH, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	_ok(CommunityStore.load_downloads().is_empty(), "corrupt manifest reads as empty")
	var n_before: int = _custom_files().size()
	var rc3: Dictionary = TrackLoader.import_hub_track(_post(_uuid(3), t_c, "sha256:ccc2", "Hub C"))
	_ok(str(rc3["status"]) == "ok", "import after corrupt manifest ok")
	_ok(_custom_files().size() == n_before + 1, "corrupt manifest -> saved again (mapping lost)")
	_ok(
		_read_json(CommunityStore.DOWNLOADS_PATH) is Dictionary,
		"manifest regenerated as valid JSON"
	)
	# 형식이 틀린 항목(경로 조작 id, 버전 불일치)은 무시
	var bad: Dictionary = {
		"version": 1,
		"posts":
		{
			_uuid(9): {"track_id": "custom_../../x", "content_hash": "h", "fingerprint": "f"},
			"bad id!": {"track_id": "custom_abc", "content_hash": "h", "fingerprint": "f"},
			_uuid(8): {"track_id": "custom_abcd1234", "content_hash": "h", "fingerprint": "f"},
		},
	}
	f = FileAccess.open(CommunityStore.DOWNLOADS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(bad))
	f.close()
	var loaded_bad: Dictionary = CommunityStore.load_downloads()
	_ok(loaded_bad.size() == 1 and loaded_bad.has(_uuid(8)), "invalid manifest entries dropped")
	f = FileAccess.open(CommunityStore.DOWNLOADS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 99, "posts": bad["posts"]}))
	f.close()
	_ok(CommunityStore.load_downloads().is_empty(), "unknown manifest version ignored")
	CommunityStore.save_downloads({})

	# 저장 실패 1: manifest 디렉터리 자리에 파일 → 매핑 저장 실패 → 트랙도 되돌림
	var abs_dir: String = ProjectSettings.globalize_path("user://community")
	DirAccess.rename_absolute(abs_dir, abs_dir + "_moved")
	f = FileAccess.open("user://community", FileAccess.WRITE)
	f.store_string("blocker")
	f.close()
	var n0: int = _custom_files().size()
	var rf: Dictionary = TrackLoader.import_hub_track(_post(_uuid(4), t_c, "sha256:ddd", "Hub D"))
	_ok(
		not bool(rf["ok"]) and str(rf["status"]) == "save_failed",
		"manifest write failure -> save_failed: %s" % rf
	)
	_ok(_custom_files().size() == n0, "failed download leaves no track file")
	DirAccess.remove_absolute(abs_dir)
	DirAccess.rename_absolute(abs_dir + "_moved", abs_dir)
	_ok(DirAccess.dir_exists_absolute("user://community"), "community dir restored")
	# 저장 실패 2: 트랙 디렉터리 쓰기 금지
	var tracks_abs: String = ProjectSettings.globalize_path(TrackLoader.CUSTOM_DIR)
	OS.execute("chmod", ["555", tracks_abs])
	var rg: Dictionary = TrackLoader.import_hub_track(_post(_uuid(5), t_c, "sha256:eee", "Hub E"))
	OS.execute("chmod", ["755", tracks_abs])
	_ok(
		not bool(rg["ok"]) and str(rg["status"]) == "save_failed",
		"track write failure -> save_failed"
	)
	_ok(CommunityStore.download_entry(_uuid(5)).is_empty(), "no mapping after failed track write")

	# 형식 오류 거부
	var t_bad_s: Dictionary = _hub_track({}, [{"s": 5000.0, "type": "thimble", "lat": 0.0}])
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_bad_s, "h1"))["status"])
			== "validation_error"
		),
		"item s past end rejected"
	)
	var t_bad_type: Dictionary = _hub_track({}, [{"s": 50.0, "type": "rocket", "lat": 0.0}])
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_bad_type, "h1"))["status"])
			== "validation_error"
		),
		"unknown item type rejected"
	)
	var t_bez: Dictionary = _hub_track()
	t_bez["path"] = [{"type": "bezier", "points": [[0, 0], [10, 0], [20, 0], [30, 0]]}]
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_bez, "h1"))["status"])
			== "validation_error"
		),
		"bezier path rejected"
	)
	var t_far: Dictionary = _hub_track()
	t_far["path"] = [{"type": "polyline", "points": [[0, 0], [1e9, 0]], "closed": false}]
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_far, "h1"))["status"])
			== "validation_error"
		),
		"huge coordinates rejected before bake"
	)
	var t_w: Dictionary = _hub_track({"perfect": 50.0, "safe": 40.0, "fail": 90.0})
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_w, "h1"))["status"])
			== "validation_error"
		),
		"bad width order rejected"
	)
	var t_geo: Dictionary = (_fixture("reject_hairpin_proximity")["track"] as Dictionary).duplicate(
		true
	)
	_ok(
		(
			str(TrackLoader.import_hub_track(_post(_uuid(6), t_geo, "h1"))["status"])
			== "validation_error"
		),
		"geometry reject via TrackValidator"
	)
	_ok(
		str(TrackLoader.import_hub_track(_post("../x", t_c, "h1"))["status"]) == "parse_error",
		"bad post id rejected"
	)
	var t_diff: Dictionary = _hub_track()
	t_diff["difficulty"] = "x".repeat(500)
	_ok(
		str(TrackLoader.import_hub_track(_post(_uuid(6), t_diff, "h1"))["status"]) == "validation_error",
		"unsupported difficulty rejected"
	)
	var t_fab: Dictionary = _hub_track()
	t_fab["fabric"] = "plastic"
	_ok(
		str(TrackLoader.import_hub_track(_post(_uuid(6), t_fab, "h1"))["status"]) == "validation_error",
		"unsupported fabric rejected"
	)
	_ok(CommunityStore.download_entry(_uuid(6)).is_empty(), "rejected imports leave no mapping")
	_done.append("hub")


# --- 기록 분리 ---


func _check_records() -> void:
	var t1: Dictionary = _hub_track({}, [])
	var t2: Dictionary = _hub_track({"perfect": 12.0, "safe": 30.0, "fail": 70.0}, [])
	var r1: Dictionary = TrackLoader.import_hub_track(_post(_uuid(11), t1, "sha256:r1", "Rec 1"))
	var r2: Dictionary = TrackLoader.import_hub_track(_post(_uuid(12), t2, "sha256:r2", "Rec 2"))
	var id1: String = str(r1["track_id"])
	var id2: String = str(r2["track_id"])
	_ok(id1 != id2 and not id1.is_empty() and not id2.is_empty(), "record tracks distinct")
	var diff: String = "normal"
	RecordStore.submit({"track_id": id1, "difficulty": diff, "final_time_ms": 50000})
	RecordStore.submit({"track_id": id2, "difficulty": diff, "final_time_ms": 70000})
	_ok(
		int(RecordStore.best_for(id1, diff).get("final_time_ms", 0)) == 50000,
		"record key 1 separate"
	)
	_ok(
		int(RecordStore.best_for(id2, diff).get("final_time_ms", 0)) == 70000,
		"record key 2 separate"
	)
	_ok(
		LeaderboardClient.track_checksum(id1) == "",
		"custom track has no official checksum (no leaderboard submit)"
	)
	_ok(
		id1.begins_with(LeaderboardClient.CUSTOM_PREFIX),
		"hub track uses custom_ prefix (ResultScreen hides submit)"
	)
	_ok(
		(
			not RecordStore.best_for("cotton_01", diff).has("track_id")
			or str(RecordStore.best_for("cotton_01", diff)["track_id"]) == "cotton_01"
		),
		"official record untouched"
	)
	_ok(
		FileAccess.file_exists("res://tracks/official/cotton_01.json"), "official track file intact"
	)
	# 결과 화면: 허브에서 받은 트랙은 제출 버튼 없이 로컬 기록 전용 안내를 보인다.
	GameState.last_result = {
		"track_id": id1, "difficulty": diff, "final_time_ms": 50000, "grade": "B", "accuracy": 90.0
	}
	var result_screen: Control = ResultScene.instantiate()
	add_child(result_screen)
	var submit_btn: Button = result_screen.get_node("Panel/Info/SubmitButton")
	var status: Label = result_screen.get_node("Panel/Info/SubmitStatusLabel")
	_ok(not submit_btn.visible, "result screen hides leaderboard submit for hub track")
	_ok(status.visible and status.text.contains("로컬 기록만"), "result screen shows local-only notice")
	result_screen.queue_free()
	_done.append("records")


# --- 게시 payload·토큰 격리 ---


func _check_publish_payload() -> void:
	var own: Dictionary = _hub_track(
		{},
		[
			{"s": 700.0, "type": "thimble", "lat": 3.0, "respawn": 4.0, "note": "x"},
		]
	)
	own["name"] = "My Own"
	own["track_id"] = ""
	own["extra_field"] = {"deep": true}
	var id: String = TrackLoader.save_custom_track(own)
	_ok(not id.is_empty(), "own track saved")
	var built: Dictionary = TrackLoader.build_publish_track(id)
	_ok(bool(built["ok"]), "own track builds publish payload: %s" % built.get("message", ""))
	var t: Dictionary = built["track"]
	var keys: Array = t.keys()
	keys.sort()
	var want: Array = [
		"difficulty", "editor_version", "fabric", "items", "modifiers", "path", "width"
	]
	_ok(keys == want, "payload track has only allowed keys: %s" % [keys])
	_ok(
		(t["items"] as Array).size() == 1 and (t["items"][0] as Dictionary).keys().size() == 3,
		"payload items only s/type/lat"
	)
	_ok(str(built["name"]) == "My Own", "payload reports local name")
	_ok(
		not bool(TrackLoader.build_publish_track("cotton_01")["ok"]),
		"official track cannot be published"
	)
	# 토큰 격리
	var token: String = "TOKENabc_def-1234567890SECRETxyz"
	_ok(
		CommunityStore.remember_published(
			_uuid(21), token, "My Own", "2026-09-30T00:00:00+00:00", id
		),
		"token stored"
	)
	_ok(CommunityStore.token_for(_uuid(21)) == token, "token readable from store")
	var leak: bool = false
	for fname in _custom_files():
		var tx: String = FileAccess.get_file_as_string(TrackLoader.CUSTOM_DIR + fname)
		if tx.contains(token):
			leak = true
	_ok(not leak, "token not in any track JSON")
	_ok(not TrackLoader.read_custom_track_text(id).contains(token), "token not in export text")
	_ok(
		not JSON.stringify(TrackLoader.build_publish_track(id)).contains(token),
		"token not in publish payload"
	)
	_ok(
		not FileAccess.get_file_as_string(CommunityStore.DOWNLOADS_PATH).contains(token),
		"token not in downloads manifest"
	)
	_ok(
		FileAccess.get_file_as_string(CommunityStore.PUBLISHED_PATH).contains(token),
		"token only in published store"
	)
	_ok(
		not CommunityStore.remember_published(_uuid(22), "bad token\r\nX: y", "t", "", ""),
		"header-injection token refused"
	)
	_ok(
		(
			CommunityStore.forget_published(_uuid(21))
			and CommunityStore.token_for(_uuid(21)).is_empty()
		),
		"token forgotten"
	)
	# 받은 트랙은 그대로 게시 대상 아님, 편집본은 허용(트랙 선택 화면 조건)
	var r: Dictionary = TrackLoader.import_hub_track(
		_post(_uuid(23), _hub_track(), "sha256:p", "Pub")
	)
	_ok(
		TrackLoader.is_unmodified_hub_download(str(r["track_id"])),
		"downloaded -> publish button hidden"
	)
	_ok(not TrackLoader.is_unmodified_hub_download(id), "own track -> publish button shown")
	_done.append("publish")


# --- 재시작 ---


func _check_restart() -> void:
	var before_dl: Dictionary = CommunityStore.load_downloads()
	var fresh: Node = TrackLoaderScript.new()
	add_child(fresh)
	var listed: Dictionary = {}
	for e in fresh.list_custom_tracks():
		listed[str(e["track_id"])] = true
	var all_listed: bool = true
	var all_unmodified: bool = true
	for post_id in before_dl:
		var lid: String = str(before_dl[post_id]["track_id"])
		if not listed.has(lid):
			all_listed = false
		if not fresh.is_unmodified_hub_download(lid):
			all_unmodified = false
	_ok(before_dl.size() >= 3, "manifest has entries before restart (%d)" % before_dl.size())
	_ok(all_listed, "fresh loader lists all downloaded tracks")
	_ok(all_unmodified, "fresh loader keeps download mapping")
	_ok(CommunityStore.load_downloads() == before_dl, "manifest identical after reload")
	fresh.queue_free()
	_done.append("restart")


# --- 상태 분류 ---


func _check_classify() -> void:
	var cl: Object = CommunityTrackClient
	_ok(str(cl.classify(HTTPRequest.RESULT_SUCCESS, 200, "{}")["status"]) == "ok", "200 ok")
	_ok(str(cl.classify(HTTPRequest.RESULT_SUCCESS, 204, "")["status"]) == "ok", "204 ok")
	_ok(
		(
			str(cl.classify(HTTPRequest.RESULT_SUCCESS, 401, '{"detail":"x"}')["status"])
			== "forbidden"
		),
		"401 forbidden"
	)
	_ok(
		(
			str(cl.classify(HTTPRequest.RESULT_SUCCESS, 403, '{"detail":"x"}')["status"])
			== "forbidden"
		),
		"403 forbidden"
	)
	_ok(
		(
			str(cl.classify(HTTPRequest.RESULT_SUCCESS, 404, '{"detail":"x"}')["status"])
			== "not_found"
		),
		"404 not_found"
	)
	_ok(
		(
			str(cl.classify(HTTPRequest.RESULT_SUCCESS, 413, '{"detail":"x"}')["status"])
			== "too_large"
		),
		"413 too_large"
	)
	_ok(
		(
			str(cl.classify(HTTPRequest.RESULT_SUCCESS, 429, '{"detail":"x"}')["status"])
			== "rate_limited"
		),
		"429 rate_limited"
	)
	_ok(
		str(cl.classify(HTTPRequest.RESULT_SUCCESS, 500, "oops")["status"]) == "server_error",
		"500 server_error"
	)
	var v: Dictionary = (
		cl
		. classify(
			HTTPRequest.RESULT_SUCCESS,
			422,
			'{"detail":[{"loc":["body","title"],"msg":"제목 오류","type":"x"},{"loc":[],"msg":"둘째","type":"y"}]}'
		)
	)
	_ok(
		str(v["status"]) == "validation_error" and v["errors"] == ["제목 오류", "둘째"],
		"422 detail msgs extracted"
	)
	_ok(str(cl.classify(HTTPRequest.RESULT_TIMEOUT, 0, "")["status"]) == "timeout", "timeout")
	_ok(
		str(cl.classify(HTTPRequest.RESULT_CANT_CONNECT, 0, "")["status"]) == "network_error",
		"cant connect"
	)
	_ok(
		str(cl.classify(HTTPRequest.RESULT_CONNECTION_ERROR, 0, "")["status"]) == "network_error",
		"connection error"
	)
	_done.append("classify")

# --- 서버 연동 ---
