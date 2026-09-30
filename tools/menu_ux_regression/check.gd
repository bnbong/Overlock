extends "res://menu_ux_regression/check_prefs.gd"
## 메뉴 UX 회귀 검사(v2.2.1 P1: 모바일 메뉴 터치 배치, 설정 저장/취소, 리더보드 오래된 응답).
## run.sh 가 사본 프로젝트에서 두 번 실행한다: 데스크톱(배치 불변·설정·닉네임·리더보드)과
## `-- --touch-controls`(터치 배치). 리더보드는 127.0.0.1 지연 스텁(stub_server.py)에만 요청한다.
## 인자: --stub=<URL> --baseline=<desktop_baseline.json> [--only=lb|prefs|nick|layout]
##   [--dump-layout=<path>]
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const SECTIONS_DESKTOP: Array[String] = ["layout", "prefs", "nick", "lb"]

var _driver: bool = false
var _done: Array[String] = []


func _ready() -> void:
	if not _driver:
		var d: Node = get_script().new()
		d.set("_driver", true)
		d.name = "MenuUxDriver"
		get_tree().root.add_child.call_deferred(d)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()
	LeaderboardClient.tutorial_seen = true
	await _frames(3)
	if _args.has("dump-layout"):
		await _dump_layout(str(_args["dump-layout"]))
		get_tree().quit(0)
		return
	var touch: bool = TouchControls.should_show()
	var only: String = str(_args.get("only", ""))
	if touch:
		await _check_layout_touch()
		_done.append("layout")
	else:
		for sec in SECTIONS_DESKTOP:
			if only.is_empty() or only == sec:
				await _run_section(sec)
				_done.append(sec)
	var mode: String = "touch" if touch else "desktop"
	print("menu ux regression (%s): %d passed, %d failed" % [mode, _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run_section(sec: String) -> void:
	match sec:
		"layout":
			await _check_layout_desktop()
		"prefs":
			await _check_settings_autosave()
			await _check_settings_nickname()
		"nick":
			await _check_nickname_dialog()
		"lb":
			await _check_leaderboard()


func _dump_layout(path: String) -> void:
	var now: Dictionary = await _collect_desktop()
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(now, "\t", true))
	f.close()
	print("dumped %d desktop button rects to %s" % [now.size(), path])


# --- 리더보드: 빠른 전환·재진입·다시 시도 ---


func _row_names() -> Array:
	var out: Array = []
	var list: Node = _scene().get_node_or_null("Panel/Scroll/List")
	if list == null:
		return out
	for row in list.get_children():
		if row.is_queued_for_deletion():
			continue
		var box: Node = row.get_child(0) if row is PanelContainer else row
		out.append((box.get_child(1) as Label).text)
	return out


func _all_from(names: Array, prefix: String) -> bool:
	if names.is_empty():
		return false
	for n in names:
		if not str(n).begins_with(prefix):
			return false
	return true


func _lb_status() -> Label:
	return _scene().get_node_or_null("Panel/StatusLabel")


func _retry_button() -> Button:
	return _scene().find_child("RetryButton", true, false) as Button


func _check_leaderboard() -> void:
	LeaderboardClient.base_url = str(_args.get("stub", ""))
	var official: Array = TrackLoader.list_tracks()
	_ok(official.size() >= 3, "at least 3 official tracks")
	if official.size() < 3:
		return
	var a: String = str(official[0]["track_id"])
	var c: String = str(official[2]["track_id"])
	# A→B→C 를 빠르게 바꾸고 응답은 C, B, A 순서(역순)로 도착시킨다.
	await _plan("delays=1.6,1.0,0.3")
	LeaderboardClient.set_view_target(a, "normal", "")
	_ok(await _goto(LEADERBOARD), "leaderboard opens (A)")
	await _key(KEY_RIGHT)
	await _key(KEY_RIGHT)
	_ok(LeaderboardClient.view_track_id == c, "view switched to C")
	await _sleep(0.7)
	_ok(_all_from(_row_names(), c + "#"), "C response shown first: " + str(_row_names()))
	await _sleep(1.4)
	var names: Array = _row_names()
	_ok(_all_from(names, c + "#"), "late B/A responses ignored, only C rows: " + str(names))
	var sub: Label = _scene().get_node("Panel/TrackNav/SubLabel")
	_ok(LeaderboardClient.view_track_name in sub.text, "title still C")
	# 재진입: 이전 화면의 느린 응답이 새 화면에 섞이지 않는다.
	await _plan("delays=1.2,0.2")
	LeaderboardClient.set_view_target(a, "normal", "")
	_ok(await _goto(LEADERBOARD), "leaderboard opens (slow A)")
	_ok(await _goto(MAIN), "leave to main")
	var b2: String = str(official[1]["track_id"])
	LeaderboardClient.set_view_target(b2, "normal", "")
	_ok(await _goto(LEADERBOARD), "leaderboard re-entered (B)")
	await _sleep(0.6)
	_ok(_all_from(_row_names(), b2 + "#"), "re-entered screen shows B: " + str(_row_names()))
	await _sleep(1.0)
	names = _row_names()
	_ok(_all_from(names, b2 + "#"), "old A response not mixed after re-entry: " + str(names))
	# 실패 → 다시 시도.
	await _plan("codes=500,200")
	_ok(await _goto(LEADERBOARD), "leaderboard opens (500)")
	await _sleep(0.5)
	var status: Label = _lb_status()
	_ok(
		status != null and "500" in status.text,
		"HTTP 500 shown: " + (status.text if status else "")
	)
	var retry: Button = _retry_button()
	_ok(retry != null and retry.is_visible_in_tree(), "retry button visible after failure")
	if retry != null:
		await _click(retry)
		await _sleep(0.5)
		_ok(not _row_names().is_empty(), "retry loads rows: " + str(_row_names()))
		_ok(not retry.is_visible_in_tree(), "retry hidden after success")
	# 시간 초과 → 다시 시도 노출(요청 제한 5초).
	await _plan("delays=6.5")
	_ok(await _goto(LEADERBOARD), "leaderboard opens (timeout)")
	await _sleep(5.8)
	status = _lb_status()
	_ok(
		status != null and "타임아웃" in status.text,
		"timeout shown: " + (status.text if status else "")
	)
	retry = _retry_button()
	_ok(retry != null and retry.is_visible_in_tree(), "retry button visible after timeout")
	await _check_leaderboard_sync_fail()
	_ok(await _goto(MAIN), "leave leaderboard")


## 요청 시작 즉시 실패(형식이 잘못된 주소로 HTTPRequest.request 가 바로 오류): 결과가 조회 번호를
## 받기 전에 동기로 방출되면 화면이 "불러오는 중..."에 멈춘다. 실패 문구와 다시 시도가 보여야 한다.
func _check_leaderboard_sync_fail() -> void:
	LeaderboardClient.base_url = "ftp://invalid.example"
	_ok(LeaderboardClient.is_online_enabled(), "malformed base_url counts as online")
	_ok(await _goto(LEADERBOARD), "leaderboard opens (sync request failure)")
	await _frames(5)
	var status: Label = _lb_status()
	var text: String = status.text if status != null else ""
	_ok(status != null and not ("불러오는 중" in text), "sync failure not stuck loading: " + text)
	var retry: Button = _retry_button()
	_ok(retry != null and retry.is_visible_in_tree(), "retry visible after sync request failure")
	# 다시 시도도 같은 경로로 실패를 보여야 한다(두 번째 조회 번호).
	if retry != null and retry.is_visible_in_tree():
		await _click(retry)
		await _frames(5)
		status = _lb_status()
		text = status.text if status != null else "(no status)"
		_ok(not ("불러오는 중" in text), "retry sync failure not stuck loading: " + text)
	LeaderboardClient.base_url = str(_args.get("stub", ""))
