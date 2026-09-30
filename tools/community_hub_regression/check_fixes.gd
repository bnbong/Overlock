extends "res://community_hub_regression/check_server.gd"
## 교차 리뷰 수정 항목 회귀 검사(fixes 구획). check.gd 가 상속한다(run.sh 가 사본에만 복사).
##  - 저장소 내구성: 임시 파일 검증, 임시 파일 복구, 손상·버전 불일치·읽기 불가 파일 보존(.bak)
##  - 요청 헤더(Content-Type 은 POST 에만), 목록 응답 잘라내기·클램프, 표시 문자열 정리(bidi·제로폭)
##  - 합성 응답: 게시 201 형식 오류(부분 성공·게시 여부 불명), 요청 종류별 404·401·403 처리
##  - 허브 화면: 저장하지 못한 토큰 재표시·재시도·확인, 업로드 중 이탈 차단, 더 보기 offset,
##    작성자 표시명 Label 분리
## 메모리에만 있던(저장하지 못한) 토큰은 TOKEN_LOG 에 적어 run.sh 가 Godot 로그 누출을 검사하게 한다.

const TOKEN_LOG: String = "user://regression_unsaved_tokens.txt"
const W = preload("res://scripts/ui/CommunityHubWidgets.gd")

# 이 구획이 메모리 보관 토큰으로 쓴 가짜 토큰들(로그 누출 검사 대상에 더한다).
var _seen_tokens: PackedStringArray = PackedStringArray()


func _check_fixes() -> void:
	LeaderboardClient.base_url = str(_args.get("api", ""))
	_fix_store_durability()
	_fix_headers_and_parsing()
	await _fix_synthetic_responses()
	await _fix_unsaved_token_ui()
	await _fix_upload_blocks_leaving()
	await _fix_list_paging_and_rows()
	_write_token_log()
	LeaderboardClient.base_url = str(_args.get("api", ""))
	_done.append("fixes")


# --- 도우미 ---


func _put(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## community 디렉터리에서 <파일 이름>.bak* 백업 파일 이름 목록.
func _baks(path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var base: String = path.get_file() + ".bak"
	for f in DirAccess.get_files_at(CommunityStore.DIR):
		if f.begins_with(base):
			out.append(f)
	return out


func _bak_with(path: String, needle: String) -> bool:
	for f in _baks(path):
		if FileAccess.get_file_as_string(CommunityStore.DIR + f).contains(needle):
			return true
	return false


func _block_community() -> String:
	var abs_dir: String = ProjectSettings.globalize_path("user://community")
	DirAccess.rename_absolute(abs_dir, abs_dir + "_moved")
	_put("user://community", "blocker")
	return abs_dir


func _unblock_community(abs_dir: String) -> void:
	DirAccess.remove_absolute(abs_dir)
	DirAccess.rename_absolute(abs_dir + "_moved", abs_dir)


func _inject(kind: String, code: int, body: String, ctx: Dictionary) -> Dictionary:
	var id: int = CommunityTrackClient._new_id()
	CommunityTrackClient._active[kind] = {"id": id, "http": null}
	CommunityTrackClient._on_http_done(
		HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(), body.to_utf8_buffer(), kind, id, ctx
	)
	return await _wait_result(id, 2.0)


func _raw_item(n: int, author: String = "author") -> Dictionary:
	return {
		"id": _uuid(n),
		"title": "Item %d" % n,
		"author_name": author,
		"difficulty": "normal",
		"fabric": "silk",
		"length": 2000,
		"created_at": "2026-09-30T00:00:00+00:00",
	}


func _list_result(items: Array, count: int, total: int) -> Dictionary:
	return {
		"kind": "list",
		"request_id": 0,
		"ok": true,
		"status": "ok",
		"code": 200,
		"message": "",
		"errors": [],
		"data": {"items": items, "count": count, "total": total, "offset": 0, "q": ""},
	}


func _new_screen() -> Control:
	var screen: Control = HubScene.instantiate()
	add_child(screen)
	return screen


func _write_token_log() -> void:
	var lines: PackedStringArray = PackedStringArray()
	for e in CommunityTrackClient.unsaved_tokens:
		lines.append(str(e["delete_token"]))
	lines.append_array(_seen_tokens)
	_put(TOKEN_LOG, "\n".join(lines) + "\n")


# --- 저장소 내구성 ---


func _fix_store_durability() -> void:
	var pub: String = CommunityStore.PUBLISHED_PATH
	var dl: String = CommunityStore.DOWNLOADS_PATH
	var keep_pub: String = FileAccess.get_file_as_string(pub)
	var keep_dl: String = FileAccess.get_file_as_string(dl)
	var tok: String = "DurableTok_abc123"
	# 손상 → .bak 보존 후 새로 쓰기
	var n0: int = _baks(pub).size()
	_put(pub, "{broken json")
	_ok(
		str(CommunityStore.read_state(pub)["state"]) == "corrupt",
		"corrupt published -> state corrupt"
	)
	_ok(CommunityStore.remember_published(_uuid(31), tok, "D", "", ""), "write after corrupt ok")
	_ok(
		_baks(pub).size() == n0 + 1 and _bak_with(pub, "{broken json"),
		"corrupt file preserved as .bak"
	)
	_ok(CommunityStore.token_for(_uuid(31)) == tok, "new published file valid after preserve")
	# 버전 불일치 → 이전 백업을 덮지 않고 다른 이름으로 보존
	_put(pub, JSON.stringify({"version": 99, "posts": {_uuid(32): {"delete_token": "OldTok_1"}}}))
	_ok(
		str(CommunityStore.read_state(pub)["state"]) == "version",
		"version mismatch -> state version"
	)
	_ok(CommunityStore.load_published().is_empty(), "version mismatch reads as empty")
	_ok(
		CommunityStore.remember_published(_uuid(31), tok, "D", "", ""),
		"write after version mismatch"
	)
	_ok(
		(
			_baks(pub).size() == n0 + 2
			and _bak_with(pub, "OldTok_1")
			and _bak_with(pub, "{broken json")
		),
		"version-mismatch file preserved without overwriting earlier .bak"
	)
	# 읽기 불가(권한 000) → 보존
	var pub_abs: String = ProjectSettings.globalize_path(pub)
	OS.execute("chmod", ["000", pub_abs])
	var unreadable: String = str(CommunityStore.read_state(pub)["state"])
	_ok(unreadable == "unreadable", "chmod 000 -> state unreadable (%s)" % unreadable)
	_ok(CommunityStore.remember_published(_uuid(33), tok, "D", "", ""), "write after unreadable ok")
	_ok(_baks(pub).size() == n0 + 3, "unreadable file preserved (not overwritten)")
	for f in _baks(pub):
		OS.execute("chmod", ["644", ProjectSettings.globalize_path(CommunityStore.DIR + f)])
	# 파일 없음 → 백업 없이 새로 만든다
	DirAccess.remove_absolute(pub)
	_ok(str(CommunityStore.read_state(pub)["state"]) == "missing", "missing file -> state missing")
	_ok(CommunityStore.remember_published(_uuid(34), tok, "D", "", ""), "write when missing ok")
	_ok(_baks(pub).size() == n0 + 3, "missing file -> no backup")
	# 본 파일 없음 + 유효한 임시 파일 → 임시 파일 채택
	var tmp: String = pub + ".tmp"
	_put(tmp, JSON.stringify({"version": 1, "posts": {_uuid(35): {"delete_token": "TmpTok_9"}}}))
	DirAccess.remove_absolute(pub)
	_ok(
		CommunityStore.token_for(_uuid(35)) == "TmpTok_9",
		"valid tmp adopted when main file missing"
	)
	_ok(FileAccess.file_exists(pub) and not FileAccess.file_exists(tmp), "tmp renamed into place")
	# 본 파일 없음 + 손상된 임시 파일 → 빈 저장소(임시 파일 채택 안 함)
	_put(tmp, "{nope")
	DirAccess.remove_absolute(pub)
	_ok(CommunityStore.load_published().is_empty(), "corrupt tmp not adopted")
	DirAccess.remove_absolute(tmp)
	# 임시 파일 검증
	_put(tmp, '{"a": 1}')
	_ok(CommunityStore.verify_written(tmp, '{"a": 1}'), "verify_written accepts identical JSON")
	_ok(not CommunityStore.verify_written(tmp, '{"a": 2}'), "verify_written rejects mismatch")
	_put(tmp, "not json")
	_ok(not CommunityStore.verify_written(tmp, "not json"), "verify_written rejects non-JSON")
	DirAccess.remove_absolute(tmp)
	# 임시 파일을 쓸 수 없으면 기존 파일 유지
	CommunityStore.remember_published(_uuid(36), tok, "D", "", "")
	var before: String = FileAccess.get_file_as_string(pub)
	DirAccess.make_dir_absolute(tmp)
	_ok(
		not CommunityStore.remember_published(_uuid(37), tok, "D", "", ""),
		"tmp write failure -> false"
	)
	_ok(FileAccess.get_file_as_string(pub) == before, "tmp write failure keeps existing file")
	DirAccess.remove_absolute(tmp)
	# downloads.json 도 같은 규칙
	var d0: int = _baks(dl).size()
	_put(dl, "{bad downloads")
	_ok(CommunityStore.save_downloads({}), "downloads write after corrupt ok")
	_ok(
		_baks(dl).size() == d0 + 1 and _bak_with(dl, "{bad downloads"),
		"corrupt downloads.json preserved as backup"
	)
	_put(pub, keep_pub)
	_put(dl, keep_dl)


# --- 헤더·목록 정리·표시 문자열·좌표 상한 ---


func _fix_headers_and_parsing() -> void:
	var cl: Object = CommunityTrackClient
	var g: String = "|".join(cl.request_headers(HTTPClient.METHOD_GET, PackedStringArray()))
	var d: String = "|".join(
		cl.request_headers(HTTPClient.METHOD_DELETE, PackedStringArray(["Authorization: Bearer x"]))
	)
	var p: String = "|".join(cl.request_headers(HTTPClient.METHOD_POST, PackedStringArray()))
	_ok(not g.contains("Content-Type") and g.contains("Accept"), "GET has no Content-Type")
	_ok(
		not d.contains("Content-Type") and d.contains("Authorization"), "DELETE has no Content-Type"
	)
	_ok(p.contains("Content-Type: application/json"), "POST has Content-Type")
	# 목록: limit 초과 항목 잘라내기, total/offset 클램프
	var many: Array = []
	for i in range(80):
		many.append(_raw_item(100 + i))
	var r: Dictionary = cl._parse_list({"total": 80, "offset": 0, "items": many}, 20, 0)
	_ok(
		(r["data"]["items"] as Array).size() == 20 and int(r["data"]["count"]) == 20,
		"list items truncated to requested limit"
	)
	r = cl._parse_list({"total": 80, "offset": 0, "items": many}, 500, 0)
	_ok(int(r["data"]["count"]) == 50, "limit clamped to 50")
	r = cl._parse_list({"total": -5, "offset": -3, "items": many.slice(0, 3)}, 20, 40)
	_ok(
		int(r["data"]["total"]) == 43 and int(r["data"]["offset"]) == 0,
		"negative total/offset clamped (total >= offset+count)"
	)
	r = cl._parse_list({"total": 1e15, "offset": 1e15, "items": []}, 20, 0)
	_ok(
		(
			int(r["data"]["total"]) == CommunityTrackClient.LIST_COUNT_MAX
			and int(r["data"]["offset"]) == CommunityTrackClient.LIST_COUNT_MAX
		),
		"huge total/offset clamped"
	)
	var bad_mix: Array = [_raw_item(1), {"id": "../x"}, "junk", _raw_item(2)]
	r = cl._parse_list({"total": 4, "items": bad_mix}, 20, 0)
	_ok(
		(r["data"]["items"] as Array).size() == 2 and int(r["data"]["count"]) == 4,
		"invalid items dropped but counted for offset"
	)
	# 표시 문자열 정리
	var hidden: String = "a\u202Eb\u200Bc\uFEFFd\u2066e\u061Cf\u0085g\u200Fh\u2069i"
	_ok(
		cl._plain(hidden, 80) == "abcdefghi",
		"bidi/zero-width/C1 chars removed: " + cl._plain(hidden, 80)
	)
	_ok(cl._plain("x\ny\tz", 80) == "x y z", "C0 controls -> spaces in single-line text")
	_ok(cl._multiline("l1\nl2\u202E\r", 100) == "l1\nl2", "multiline keeps newline, strips bidi")
	var big: String = "가".repeat(2000000)
	var t0: int = Time.get_ticks_msec()
	var clipped: String = cl._plain(big, 32)
	var ms: int = Time.get_ticks_msec() - t0
	_ok(clipped.length() == 32 and ms < 500, "_plain clips before filtering (%d ms)" % ms)
	var s: Dictionary = cl._summary(_raw_item(3, "\u202Eevil\u2066 name"))
	_ok(str(s["author_name"]) == "evil name", "summary author cleaned")
	var d422: Array = []
	for i in range(25):
		d422.append({"loc": [], "msg": "err\u202E%d" % i, "type": "x"})
	var v: Dictionary = cl.classify(
		HTTPRequest.RESULT_SUCCESS, 422, JSON.stringify({"detail": d422}), "publish"
	)
	_ok(
		(v["errors"] as Array).size() == 20 and str(v["errors"][0]) == "err0",
		"422 detail: up to 20 msgs, cleaned"
	)
	# 좌표 상한은 서버와 같은 16384
	_ok(TrackLoader._hub_point([16384.0, -16384.0]) != Vector2.INF, "coord 16384 accepted")
	_ok(TrackLoader._hub_point([16384.5, 0.0]) == Vector2.INF, "coord > 16384 rejected")


# --- 합성 응답(요청 종류별 처리) ---


func _fix_synthetic_responses() -> void:
	var cl: Object = CommunityTrackClient
	# 201: id·토큰은 유효, 상세 필드 누락 → 게시 성공 + 토큰 저장 + partial
	var body: String = JSON.stringify(
		{"id": _uuid(41), "delete_token": "PartialTok_123", "title": "Partial \u202Eone"}
	)
	var r: Dictionary = await _inject(
		"publish", 201, body, {"title": "Partial", "source_track_id": ""}
	)
	_ok(
		bool(r.get("ok", false)) and bool(r["data"].get("partial", false)),
		"201 partial -> ok+partial"
	)
	_ok(bool(r.get("token_saved", false)), "201 partial -> token saved")
	_ok(CommunityStore.token_for(_uuid(41)) == "PartialTok_123", "partial publish token in store")
	_ok(str(r["data"]["title"]) == "Partial one", "partial title cleaned")
	CommunityStore.forget_published(_uuid(41))
	# 201: 해석 불가 → 게시 여부 불명(재게시 금지 안내)
	var n_unsaved: int = cl.unsaved_tokens.size()
	r = await _inject("publish", 201, "<html>oops", {"title": "X"})
	_ok(
		not bool(r.get("ok", true)) and bool(r.get("maybe_published", false)),
		"201 garbage -> maybe_published"
	)
	_ok(str(r["message"]).contains("다시 게시하지"), "maybe_published message warns against re-post")
	r = await _inject(
		"publish", 201, JSON.stringify({"id": _uuid(42), "delete_token": "bad token!"}), {}
	)
	_ok(bool(r.get("maybe_published", false)), "201 with bad token -> maybe_published")
	_ok(cl.unsaved_tokens.size() == n_unsaved, "no unsaved entry without a valid token")
	# 게시 201 + 저장 실패(화면 없음) → 오토로드가 메모리에 토큰 보관
	var abs_dir: String = _block_community()
	body = JSON.stringify({"id": _uuid(43), "delete_token": "MemTok_777", "title": "Mem"})
	r = await _inject("publish", 201, body, {"title": "Mem"})
	_unblock_community(abs_dir)
	_seen_tokens.append("MemTok_777")
	_ok(not bool(r.get("token_saved", true)), "blocked store -> token_saved false")
	var found: bool = false
	for e in cl.unsaved_tokens:
		if str(e["post_id"]) == _uuid(43) and str(e["delete_token"]) == "MemTok_777":
			found = true
	_ok(found, "unsaved token kept in autoload memory")
	# 상세 404 는 토큰 유지, 삭제 404 는 토큰 삭제
	CommunityStore.remember_published(_uuid(44), "KeepTok_1", "K", "", "")
	r = await _inject("detail", 404, '{"detail":"x"}', {"post_id": _uuid(44)})
	_ok(str(r["status"]) == "not_found" and str(r["message"]).contains("삭제되었거나"), "detail 404 text")
	_ok(CommunityStore.token_for(_uuid(44)) == "KeepTok_1", "detail 404 keeps token")
	r = await _inject("delete", 200, "", {"post_id": _uuid(44)})
	_ok(not bool(r["ok"]), "delete non-204 2xx not treated as deleted")
	_ok(CommunityStore.token_for(_uuid(44)) == "KeepTok_1", "delete 200 keeps token")
	r = await _inject("delete", 403, '{"detail":"x"}', {"post_id": _uuid(44)})
	_ok(str(r["message"]).contains("삭제 권한"), "delete 403 -> delete permission text")
	_ok(CommunityStore.token_for(_uuid(44)) == "KeepTok_1", "delete 403 keeps token")
	r = await _inject("delete", 404, '{"detail":"x"}', {"post_id": _uuid(44)})
	_ok(str(r["message"]).contains("이미 삭제"), "delete 404 text")
	_ok(CommunityStore.token_for(_uuid(44)).is_empty(), "delete 404 forgets token")
	# 목록·상세의 404/401/403 문구
	r = await _inject("list", 404, "", {"limit": 20, "offset": 0})
	_ok(str(r["message"]).contains("허브를 사용할 수 없는"), "list 404 -> hub unavailable text")
	r = await _inject("list", 403, "", {"limit": 20, "offset": 0})
	_ok(
		str(r["message"]).contains("거부") and not str(r["message"]).contains("삭제"),
		"list 403 -> generic access text"
	)
	r = await _inject("detail", 401, "", {"post_id": _uuid(45)})
	_ok(not str(r["message"]).contains("삭제 권한"), "detail 401 not delete-permission text")
	_ok(
		W.status_text(r) == str(r["message"]),
		"screen uses client message for forbidden (kind-aware)"
	)
	# 목록 200 이 limit 보다 많은 항목을 주면 잘라낸다
	var many: Array = []
	for i in range(60):
		many.append(_raw_item(200 + i))
	r = await _inject(
		"list", 200, JSON.stringify({"total": 60, "items": many}), {"limit": 20, "offset": 0}
	)
	_ok((r["data"]["items"] as Array).size() == 20, "oversized list response truncated end-to-end")


# --- 저장하지 못한 토큰 재표시 ---


func _fix_unsaved_token_ui() -> void:
	var cl: Object = CommunityTrackClient
	var first: Dictionary = cl.first_unsaved_token()
	_ok(not first.is_empty(), "autoload has unsaved token before hub re-entry")
	if first.is_empty():
		return
	var screen: Control = _new_screen()
	await get_tree().process_frame
	var edit: LineEdit = screen.get("_token_edit")
	_ok(
		str(screen.get("_view")) == "done" and bool(screen.get("_recovery")),
		"hub re-entry shows unsaved token view"
	)
	_ok((screen.get("_token_box") as Control).visible, "token box visible on re-entry")
	_ok(edit.text == str(first["delete_token"]), "unsaved token shown for copying")
	_ok((screen.get("_title_label") as Label).text.contains("저장하지 못한"), "recovery title shown")
	# 저장이 계속 실패하면 그대로 남는다
	var abs_dir: String = _block_community()
	screen.call("_on_token_retry")
	_unblock_community(abs_dir)
	_ok((screen.get("_token_box") as Control).visible, "retry failure keeps token box")
	_ok(
		cl.first_unsaved_token().get("post_id", "") == first["post_id"], "retry failure keeps entry"
	)
	# 저장 재시도 성공 → 메모리에서 비우고 저장소에 기록
	var n: int = cl.unsaved_tokens.size()
	screen.call("_on_token_retry")
	_ok(cl.unsaved_tokens.size() == n - 1, "retry success clears the entry")
	_ok(
		CommunityStore.token_for(str(first["post_id"])) == str(first["delete_token"]),
		"retry success stores token"
	)
	# 남은 항목(있다면)은 사용자가 확인하면 비운다
	while not cl.unsaved_tokens.is_empty():
		_ok(str(screen.get("_view")) == "done", "next unsaved token shown")
		var pid: String = str(cl.first_unsaved_token()["post_id"])
		screen.call("_on_token_ack")
		_ok(cl.first_unsaved_token().get("post_id", "") != pid, "ack clears the entry")
	_ok(str(screen.get("_view")) == "list", "after all tokens resolved -> list view")
	screen.queue_free()
	await get_tree().process_frame
	# 확인 후 원래 진입(게시 양식)으로 이어진다
	(
		cl
		. unsaved_tokens
		. append(
			{
				"post_id": _uuid(51),
				"delete_token": "AckTok_51",
				"title": "Ack",
				"published_at": "",
				"source_track_id": "",
			}
		)
	)
	_seen_tokens.append("AckTok_51")
	var own: Dictionary = _hub_track({}, [])
	own["name"] = "Resume Form"
	own["track_id"] = ""
	var own_id: String = TrackLoader.save_custom_track(own)
	cl.pending_publish_track_id = own_id
	screen = _new_screen()
	await get_tree().process_frame
	_ok(str(screen.get("_view")) == "done", "unsaved token shown before publish form")
	screen.call("_on_token_ack")
	_ok(cl.unsaved_tokens.is_empty(), "ack empties unsaved tokens")
	_ok(
		str(screen.get("_view")) == "form" and str(screen.get("_publish_track_id")) == own_id,
		"after ack -> resumes publish form"
	)
	screen.queue_free()
	await get_tree().process_frame


# --- 업로드 중 이탈 차단, 게시 응답 형식 오류 화면 처리 ---


func _fix_upload_blocks_leaving() -> void:
	var own: Dictionary = _hub_track({}, [{"s": 700.0, "type": "thimble", "lat": 0.0}])
	own["name"] = "Upload Block"
	own["track_id"] = ""
	var own_id: String = TrackLoader.save_custom_track(own)
	CommunityTrackClient.pending_publish_track_id = own_id
	var screen: Control = _new_screen()
	await get_tree().process_frame
	_ok(str(screen.get("_view")) == "form", "form opened for upload-block test")
	(screen.get("_author_edit") as LineEdit).text = "tester"
	screen.call("_do_publish")
	var req: int = int(screen.get("_publish_req"))
	var cancel_btn: Button = screen.get("_form_cancel")
	var submit_btn: Button = screen.get("_form_submit")
	_ok(
		req > 0 and cancel_btn.disabled and submit_btn.disabled, "upload disables cancel and submit"
	)
	var esc: InputEventAction = InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	screen.call("_input", esc)
	screen.call("_go_back")
	_ok(
		screen.is_inside_tree() and str(screen.get("_view")) == "form",
		"Esc/_go_back ignored while uploading"
	)
	_ok(
		(screen.get("_form_status") as Label).text.contains("떠날 수 없습니다"),
		"upload-in-progress notice shown"
	)
	await _wait_result(req)
	await get_tree().process_frame
	_ok(not cancel_btn.disabled, "cancel re-enabled after upload finished")
	_ok(str(screen.get("_view")) == "done", "upload finished -> done view")
	# 게시 여부 불명 응답: 제출 버튼을 다시 켜지 않는다
	screen.call("_show_view", "form")
	submit_btn.disabled = true
	screen.set("_publish_req", 9999)
	(
		screen
		. call(
			"_on_publish_done",
			{
				"kind": "publish",
				"request_id": 9999,
				"ok": false,
				"status": "server_error",
				"code": 201,
				"message": "게시되었을 수 있으니 다시 게시하지 말고 목록에서 확인하세요.",
				"errors": [],
				"data": {},
				"maybe_published": true,
			}
		)
	)
	_ok(submit_btn.disabled and not cancel_btn.disabled, "maybe_published keeps submit disabled")
	_ok(
		(screen.get("_form_status") as Label).text.contains("다시 게시하지"),
		"maybe_published notice shown"
	)
	# 부분 성공(상세 필드 없음): "게시물 보기"는 서버에서 다시 조회한다
	screen.set("_publish_req", 9998)
	(
		screen
		. call(
			"_on_publish_done",
			{
				"kind": "publish",
				"request_id": 9998,
				"ok": true,
				"status": "ok",
				"code": 201,
				"message": "",
				"errors": [],
				"token_saved": true,
				"data": {"id": _uuid(61), "title": "Partial", "created_at": "", "partial": true},
			}
		)
	)
	_ok(str(screen.get("_view")) == "done", "partial publish -> done view")
	screen.call("_on_done_view")
	_ok(
		str(screen.get("_view")) == "detail" and int(screen.get("_detail_req")) > 0,
		"partial publish -> detail re-fetched by id"
	)
	CommunityTrackClient.cancel_reads()
	screen.queue_free()
	await get_tree().process_frame


# --- 더 보기 offset, 행·상세 Label 분리 ---


func _fix_list_paging_and_rows() -> void:
	LeaderboardClient.base_url = ""  # 화면의 첫 목록 요청은 오프라인으로 바로 실패시킨다.
	var screen: Control = _new_screen()
	await _sleep(0.2)
	screen.set("_list_append", false)
	screen.set("_list_offset_req", 0)
	var a: Dictionary = CommunityTrackClient._summary(_raw_item(301))
	var b: Dictionary = CommunityTrackClient._summary(_raw_item(302))
	var c: Dictionary = CommunityTrackClient._summary(_raw_item(303))
	screen.call("_on_list_done", _list_result([a, b, a], 3, 6))
	_ok((screen.get("_items") as Array).size() == 2, "duplicate id within one response added once")
	_ok(int(screen.get("_server_offset")) == 3, "server offset advances by response count")
	_ok((screen.get("_more_btn") as Button).visible, "more visible while offset < total")
	screen.call("_request_list", true)
	_ok(
		int(screen.get("_list_offset_req")) == 3, "more requests use server offset (not item count)"
	)
	await _sleep(0.2)  # 오프라인 실패 응답을 흘려 보낸다.
	screen.set("_list_append", true)
	screen.set("_list_offset_req", 3)
	screen.call("_on_list_done", _list_result([b], 1, 6))
	_ok(int(screen.get("_server_offset")) == 4, "all-duplicate page still advances offset")
	_ok((screen.get("_more_btn") as Button).visible, "no stall: more still offered")
	screen.set("_list_offset_req", 4)
	screen.call("_on_list_done", _list_result([], 0, 6))
	_ok(not (screen.get("_more_btn") as Button).visible, "empty page hides more")
	screen.set("_list_offset_req", 4)
	screen.call("_on_list_done", _list_result([c], 1, 6))
	var off_before: int = int(screen.get("_server_offset"))
	screen.call("_remove_item", str(c["id"]))
	_ok(
		int(screen.get("_server_offset")) == off_before - 1,
		"removing an item rewinds offset by one"
	)
	# 작성자 표시명은 메타 정보와 다른 Label
	var evil: Dictionary = CommunityTrackClient._summary(_raw_item(304, "\u202Eevil\u200B"))
	var row: Button = screen.call("_make_row", evil)
	var author: Label = row.find_child("AuthorLabel", true, false)
	var meta: Label = row.find_child("MetaLabel", true, false)
	_ok(author != null and meta != null and author != meta, "row has separate author/meta labels")
	if author != null and meta != null:
		_ok(
			author.text.contains("evil") and not author.text.contains("px"),
			"author label only author"
		)
		_ok(meta.text.contains("px") and not meta.text.contains("evil"), "meta label has no author")
		_ok(not author.text.contains("\u202E"), "bidi override stripped from row")
		_ok(author.clip_text and meta.clip_text, "row labels clip long text")
	row.free()
	var long_title: String = "W".repeat(80)
	var detail: Dictionary = evil.duplicate()
	detail["title"] = long_title
	detail["description"] = "D".repeat(1000)
	detail["content_hash"] = "sha256:x"
	detail["track"] = _hub_track({}, [])
	screen.call("_render_detail", detail)
	var d_author: Label = screen.get("_detail_author")
	var d_meta: Label = screen.get("_detail_meta")
	var d_title: Label = screen.get("_detail_title")
	var d_desc: Label = screen.get("_detail_desc")
	_ok(d_author != d_meta and not d_meta.text.contains("evil"), "detail author separate from meta")
	_ok(
		(
			d_title.autowrap_mode != TextServer.AUTOWRAP_OFF
			and d_desc.autowrap_mode != TextServer.AUTOWRAP_OFF
			and d_meta.autowrap_mode != TextServer.AUTOWRAP_OFF
			and d_author.clip_text
		),
		"detail long strings wrap or clip"
	)
	var done_info: Label = screen.get("_done_info")
	_ok(done_info.autowrap_mode != TextServer.AUTOWRAP_OFF, "done info wraps")
	screen.queue_free()
	await get_tree().process_frame
