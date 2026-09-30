extends "res://community_hub_regression/check_base.gd"
## 공유 허브 회귀 검사의 서버 연동 구획(server, limited). check.gd 가 상속한다.


func _check_server() -> void:
	var api: String = str(_args.get("api", ""))
	_ok(not api.is_empty(), "api url given")
	LeaderboardClient.base_url = api
	# 게시
	var p1: Dictionary = await _publish_own("Regression Alpha")
	_ok(
		bool(p1.get("ok", false)) and int(p1["code"]) == 201,
		"publish 201: %s" % p1.get("message", "")
	)
	_ok(bool(p1.get("token_saved", false)), "token saved on publish")
	var post1: String = str(p1["data"].get("id", ""))
	_ok(not (p1["data"] as Dictionary).has("delete_token"), "result drops token after saving")
	_ok(not CommunityStore.token_for(post1).is_empty(), "published store has token for post")
	_ok(
		str(CommunityStore.load_published()[post1]["source_track_id"]) == str(p1["local_id"]),
		"published store keeps source id"
	)
	_ok(
		str(p1["data"]["description"]).contains("<b>bold</b>"),
		"description returned verbatim (rendered as plain text)"
	)
	# 목록·검색·상세
	var lr: Dictionary = await _wait_result(CommunityTrackClient.list())
	_ok(bool(lr.get("ok", false)) and int(lr["data"]["total"]) >= 1, "list ok")
	var found: bool = false
	for it in lr["data"]["items"]:
		if str(it["id"]) == post1:
			found = true
			_ok(
				not (it as Dictionary).has("track") and not (it as Dictionary).has("delete_token"),
				"list item has no track/token"
			)
	_ok(found, "list contains published post")
	var sr: Dictionary = await _wait_result(CommunityTrackClient.list("alpha"))
	_ok(bool(sr["ok"]) and (sr["data"]["items"] as Array).size() == 1, "search 'alpha' finds 1")
	var sr2: Dictionary = await _wait_result(CommunityTrackClient.list("zzz-no-such"))
	_ok(
		(
			bool(sr2["ok"])
			and (sr2["data"]["items"] as Array).is_empty()
			and int(sr2["data"]["total"]) == 0
		),
		"search no results"
	)
	var long_q: String = "가".repeat(120)
	var sr3: Dictionary = await _wait_result(CommunityTrackClient.list(long_q))
	_ok(bool(sr3["ok"]), "over-long query clipped to 80 chars client-side")
	var dr: Dictionary = await _wait_result(CommunityTrackClient.detail(post1))
	_ok(bool(dr["ok"]) and dr["data"]["track"] is Dictionary, "detail ok with track")
	_ok(str(dr["data"]["content_hash"]).begins_with("sha256:"), "detail content_hash opaque string")
	var imp: Dictionary = (
		TrackLoader
		. import_hub_track(
			{
				"post_id": post1,
				"title": dr["data"]["title"],
				"content_hash": dr["data"]["content_hash"],
				"track": dr["data"]["track"],
			}
		)
	)
	_ok(bool(imp["ok"]), "import from real detail ok: %s" % imp.get("message", ""))
	var imp_saved: Dictionary = JSON.parse_string(_file_text(str(imp["track_id"])))
	_ok((imp_saved["items"] as Array).size() == 1, "real detail items preserved")
	var imp2: Dictionary = (
		TrackLoader
		. import_hub_track(
			{
				"post_id": post1,
				"title": dr["data"]["title"],
				"content_hash": dr["data"]["content_hash"],
				"track": dr["data"]["track"],
			}
		)
	)
	_ok(str(imp2["status"]) == "duplicate", "real re-download -> duplicate")
	var nf: Dictionary = await _wait_result(
		CommunityTrackClient.detail("11111111-2222-4333-8444-555555555555")
	)
	_ok(str(nf.get("status", "")) == "not_found", "unknown id -> not_found")
	var nf2: Dictionary = await _wait_result(CommunityTrackClient.detail("../../etc"))
	_ok(str(nf2.get("status", "")) == "not_found", "malformed id -> not_found without request")
	# 422
	var bad_track: Dictionary = TrackLoader.build_publish_track(str(p1["local_id"]))["track"]
	bad_track["difficulty"] = "impossible"
	var vr: Dictionary = await _wait_result(
		CommunityTrackClient.publish("Bad", "tester", "", bad_track)
	)
	_ok(
		str(vr.get("status", "")) == "validation_error" and not (vr["errors"] as Array).is_empty(),
		"422 validation_error with msgs: %s" % [vr.get("errors", [])]
	)
	var lv: Dictionary = await _wait_result(
		CommunityTrackClient.publish("", "tester", "", bad_track)
	)
	_ok(str(lv.get("status", "")) == "validation_error", "empty title rejected locally")
	# 413(실제 1MiB 초과 본문)
	var big: String = JSON.stringify(
		{"title": "x", "author_name": "y", "description": "z".repeat(1100000), "track": {}}
	)
	var br: Dictionary = await _wait_result(
		CommunityTrackClient._start(
			"publish",
			HTTPClient.METHOD_POST,
			CommunityTrackClient._url(""),
			big,
			PackedStringArray(),
			{}
		)
	)
	_ok(str(br.get("status", "")) == "too_large", "413 too_large: %s" % br.get("status", ""))
	# 연타: 게시 두 번 연속 → 두 번째는 0
	var total_before: int = int((await _wait_result(CommunityTrackClient.list()))["data"]["total"])
	var built2: Dictionary = TrackLoader.build_publish_track(str(p1["local_id"]))
	var q1: int = CommunityTrackClient.publish("Double", "tester", "", built2["track"])
	var q2: int = CommunityTrackClient.publish("Double", "tester", "", built2["track"])
	_ok(q1 > 0 and q2 == 0, "second publish while busy refused")
	var d1: Dictionary = await _wait_result(q1)
	_ok(bool(d1.get("ok", false)), "first of double publish ok")
	var total_after: int = int((await _wait_result(CommunityTrackClient.list()))["data"]["total"])
	_ok(
		total_after == total_before + 1,
		"double press created exactly one post (%d -> %d)" % [total_before, total_after]
	)
	var post_double: String = str(d1["data"]["id"])
	# 페이지(더 보기): offset 을 달리한 두 페이지는 서로 다른 게시물을 준다.
	var pg1: Dictionary = await _wait_result(CommunityTrackClient.list("", 0, 1))
	var pg2: Dictionary = await _wait_result(CommunityTrackClient.list("", 1, 1))
	_ok(
		(pg1["data"]["items"] as Array).size() == 1 and (pg2["data"]["items"] as Array).size() == 1,
		"paged list returns one item per page"
	)
	_ok(
		str(pg1["data"]["items"][0]["id"]) != str(pg2["data"]["items"][0]["id"]),
		"offset pages are distinct"
	)
	# 목록 대체(늦은 응답 폐기)
	var n_list: int = _count_kind("list")
	var l1: int = CommunityTrackClient.list("a")
	var l2: int = CommunityTrackClient.list("b")
	var r2: Dictionary = await _wait_result(l2)
	await _sleep(0.6)
	_ok(not r2.is_empty() and _count_kind("list") == n_list + 1, "superseded list never emits")
	_ok(
		_results.filter(func(x: Dictionary) -> bool: return int(x["request_id"]) == l1).is_empty(),
		"first list response discarded"
	)
	# 취소
	var n_detail: int = _count_kind("detail")
	CommunityTrackClient.detail(post1)
	_ok(CommunityTrackClient.cancel("detail"), "cancel detail returns true")
	await _sleep(1.0)
	_ok(_count_kind("detail") == n_detail, "cancelled detail never emits")
	_ok(not CommunityTrackClient.cancel("publish"), "publish is not cancellable")
	# 삭제: 잘못된 토큰 403 → 올바른 토큰 204 → 상세 404 → 목록 제외 → 다시 삭제는 토큰 없음
	var real_token: String = CommunityStore.token_for(post_double)
	CommunityStore.remember_published(post_double, "wrongTokenValue123", "Double", "", "")
	var fr: Dictionary = await _wait_result(CommunityTrackClient.delete_post(post_double))
	_ok(str(fr.get("status", "")) == "forbidden", "wrong token -> forbidden (403)")
	_ok(
		CommunityStore.token_for(post_double) == "wrongTokenValue123",
		"forbidden keeps local record"
	)
	CommunityStore.remember_published(post_double, real_token, "Double", "", "")
	var del_a: int = CommunityTrackClient.delete_post(post_double)
	var del_b: int = CommunityTrackClient.delete_post(post_double)
	_ok(del_a > 0 and del_b == 0, "second delete while busy refused")
	var okd: Dictionary = await _wait_result(del_a)
	_ok(bool(okd.get("ok", false)) and int(okd["code"]) == 204, "delete 204")
	_ok(CommunityStore.token_for(post_double).is_empty(), "token record removed after delete")
	var gone: Dictionary = await _wait_result(CommunityTrackClient.detail(post_double))
	_ok(str(gone.get("status", "")) == "not_found", "deleted post detail -> not_found")
	var after_del: Dictionary = await _wait_result(CommunityTrackClient.list())
	var still: bool = false
	for it in after_del["data"]["items"]:
		if str(it["id"]) == post_double:
			still = true
	_ok(not still, "deleted post not listed")
	var again: Dictionary = await _wait_result(CommunityTrackClient.delete_post(post_double))
	_ok(
		str(again.get("status", "")) == "forbidden",
		"delete without local token -> forbidden, no request"
	)
	CommunityStore.remember_published(post_double, real_token, "Double", "", "")
	var gone_del: Dictionary = await _wait_result(CommunityTrackClient.delete_post(post_double))
	_ok(str(gone_del.get("status", "")) == "not_found", "delete already-deleted -> not_found")
	_ok(CommunityStore.token_for(post_double).is_empty(), "stale token removed after 404")
	# 토큰 저장 실패 → 결과에 토큰 유지(재업로드 없음)
	var abs_dir: String = ProjectSettings.globalize_path("user://community")
	DirAccess.rename_absolute(abs_dir, abs_dir + "_moved")
	var fb: FileAccess = FileAccess.open("user://community", FileAccess.WRITE)
	fb.store_string("blocker")
	fb.close()
	var n_pub: int = _count_kind("publish")
	var tf: Dictionary = await _wait_result(
		CommunityTrackClient.publish("Token Fail", "tester", "", built2["track"])
	)
	await _sleep(0.5)
	DirAccess.remove_absolute(abs_dir)
	DirAccess.rename_absolute(abs_dir + "_moved", abs_dir)
	_ok(
		bool(tf.get("ok", false)) and not bool(tf.get("token_saved", true)),
		"token save failure reported"
	)
	_ok(
		CommunityStore.is_valid_token(str(tf["data"].get("delete_token", ""))),
		"unsaved token kept in result for copying"
	)
	_ok(_count_kind("publish") == n_pub + 1, "no automatic re-upload after token save failure")
	_ok(
		CommunityTrackClient.first_unsaved_token().get("delete_token", "") == tf["data"]["delete_token"],
		"unsaved token also kept in autoload memory"
	)
	# 허브 화면: 상세 요청 중 목록으로 돌아가면 늦은 상세 응답은 반영되지 않는다.
	# 위에서 저장하지 못한 토큰은 화면이 먼저 재표시하므로(fixes 구획에서 검사) 이 검사 동안만 비켜 둔다.
	var stashed_unsaved: Array = CommunityTrackClient.unsaved_tokens.duplicate(true)
	CommunityTrackClient.unsaved_tokens.clear()
	var screen: Control = HubScene.instantiate()
	add_child(screen)
	await _sleep(0.8)
	_ok(str(screen.get("_view")) == "list", "hub screen starts in list view")
	_ok((screen.get("_items") as Array).size() >= 1, "hub screen list loaded from server")
	screen.call("_open_detail", post1)
	screen.call("_back_to_list")
	await _sleep(1.0)
	_ok(
		str(screen.get("_view")) == "list" and (screen.get("_detail") as Dictionary).is_empty(),
		"late detail response discarded after leaving detail"
	)
	screen.call("_open_detail", post1)
	await _sleep(1.0)
	_ok(
		(
			str(screen.get("_view")) == "detail"
			and not (screen.get("_detail") as Dictionary).is_empty()
		),
		"detail renders when awaited"
	)
	_ok((screen.get("_delete_btn") as Button).visible, "own post shows delete button")
	var desc_label: Label = screen.get("_detail_desc")
	_ok(
		desc_label is Label and desc_label.text.contains("<b>bold</b>"),
		"description drawn as plain Label text"
	)
	screen.queue_free()
	await get_tree().process_frame
	CommunityTrackClient.unsaved_tokens.append_array(stashed_unsaved)
	var n_after_free: int = _results.size()
	CommunityTrackClient.list()
	await _sleep(0.8)
	_ok(_results.size() == n_after_free + 1, "client keeps working after screen freed")
	# 네트워크 오류·타임아웃·오프라인
	LeaderboardClient.base_url = "http://127.0.0.1:9"
	var ne: Dictionary = await _wait_result(CommunityTrackClient.list())
	_ok(
		str(ne.get("status", "")) == "network_error",
		"connection refused -> network_error: %s" % ne.get("status", "")
	)
	LeaderboardClient.base_url = str(_args.get("api-silent", ""))
	CommunityTrackClient.read_timeout = 1.5
	var to: Dictionary = await _wait_result(CommunityTrackClient.list(), 10.0)
	_ok(
		str(to.get("status", "")) == "timeout",
		"silent server -> timeout: %s" % to.get("status", "")
	)
	CommunityTrackClient.read_timeout = CommunityTrackClient.READ_TIMEOUT
	LeaderboardClient.base_url = ""
	var off: Dictionary = await _wait_result(CommunityTrackClient.list())
	_ok(str(off.get("status", "")) == "offline", "empty base url -> offline")
	LeaderboardClient.base_url = api
	_done.append("server")


func _check_limited() -> void:
	var api: String = str(_args.get("api-limited", ""))
	_ok(not api.is_empty(), "limited api url given")
	LeaderboardClient.base_url = api
	var a: Dictionary = await _publish_own("Limited One")
	_ok(bool(a.get("ok", false)), "first publish on limited server ok")
	var n_pub: int = _count_kind("publish")
	var b: Dictionary = await _publish_own("Limited Two")
	_ok(
		str(b.get("status", "")) == "rate_limited",
		"second publish -> rate_limited (429): %s" % b.get("status", "")
	)
	await _sleep(1.0)
	_ok(_count_kind("publish") == n_pub + 1, "no automatic retry after 429")
	var lst: Dictionary = await _wait_result(CommunityTrackClient.list())
	_ok(
		bool(lst.get("ok", false)) and int(lst["data"]["total"]) == 1,
		"limited server has exactly one post"
	)
	LeaderboardClient.base_url = ""
	_done.append("limited")
