extends Node
## 메인 Start → 트랙 종류 선택(TrackKindSelect) → 맵 선택(TrackSelect) 공식/유저 모드 진입 흐름 회귀
## 검사(사본 프로젝트 전용, run.sh 가 실행). 실제 씬 전환(change_scene_to_file)을 따라가며 화면마다
## 버튼 가시성·목록 내용·포커스·뒤로 가기 경로를 확인한다. 키 입력과 마우스 클릭은 뷰포트에
## push_input 으로 넣는다(데스크톱 헤드리스 모사이며 실제 기기 터치 검증이 아니다).
## 서버에 닿지 않도록 base_url 을 닫힌 로컬 포트로 바꿔 둔다.
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const MAIN: String = "res://scenes/Main.tscn"
const KIND: String = "res://scenes/TrackKindSelect.tscn"
const SELECT: String = "res://scenes/TrackSelect.tscn"
const HUB: String = "res://scenes/CommunityHub.tscn"
const GAMEPLAY: String = "res://scenes/Gameplay.tscn"
const RESULT: String = "res://scenes/Result.tscn"
const EDITOR: String = "res://scenes/TrackEditor.tscn"
const TrackSelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const KindScript = preload("res://scripts/ui/TrackKindSelectScreen.gd")
# 844×390 창(canvas_items + keep)에서의 캔버스 배율(docs/mobile.md §4.5 실측 0.5414).
const PHONE_SCALE: float = 0.5414
const SECTIONS: Array[String] = [
	"main_to_kind",
	"kind_layout",
	"kind_back",
	"official_mode",
	"official_back",
	"user_empty",
	"user_back",
	"hub_back",
	"calibration_first_start",
	"calibration_panel",
	"calibration_reenter_and_lap",
	"calibration_menu_exit",
	"calibration_existing_install",
	"user_tracks",
	"user_import_drop",
	"result_return_custom",
	"result_return_official",
	"leaderboard_return",
	"editor_return",
	"layout_fit",
]
const MIN_PASSED: int = 335

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _driver: bool = false
var _own_id: String = ""
var _hub_id: String = ""


func _ready() -> void:
	if not _driver:
		# 씬 전환이 이 노드(현재 씬)를 지우므로, 루트에 붙는 별도 드라이버 인스턴스로 검사한다.
		var d: Node = get_script().new()
		d.set("_driver", true)
		d.name = "StartFlowDriver"
		get_tree().root.add_child.call_deferred(d)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	LeaderboardClient.base_url = "http://127.0.0.1:9"
	LeaderboardClient.nickname = "tester"
	LeaderboardClient.tutorial_seen = true
	LeaderboardClient.last_track_id = ""
	await _frames(3)
	await _run()
	for s in SECTIONS:
		_ok(s in _done, "section completed: " + s)
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("start flow regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	await _check_main_to_kind()
	await _check_kind_layout()
	await _check_kind_back()
	await _check_official_mode()
	await _check_official_back()
	await _check_user_empty()
	await _check_user_back()
	await _check_hub_back()
	# 감도 체험 섹션은 기록·고스트 파일이 아직 없는 이 시점(일반 플레이 결과 섹션 앞)에 돌린다.
	await _check_calibration_first_start()
	await _check_calibration_panel()
	await _check_calibration_reenter_and_lap()
	await _check_calibration_menu_exit()
	await _check_calibration_existing_install()
	_make_tracks()
	await _check_user_tracks()
	await _check_user_import_drop()
	await _check_result_return_custom()
	await _check_result_return_official()
	await _check_leaderboard_return()
	await _check_editor_return()


# --- 도우미 ---


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: " + label)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _scene() -> Node:
	return get_tree().current_scene


func _scene_path() -> String:
	var s: Node = _scene()
	return s.scene_file_path if s != null else ""


## path 씬이 현재 씬이 될 때까지(최대 frames 프레임) 기다린다.
func _wait_scene(path: String, frames: int = 60) -> bool:
	for _i in range(frames):
		if _scene_path() == path and _scene().is_node_ready():
			await _frames(2)
			return true
		await get_tree().process_frame
	return false


func _goto(path: String) -> bool:
	get_tree().change_scene_to_file(path)
	return await _wait_scene(path)


func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var ev: InputEventKey = InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.pressed = pressed
		get_tree().root.push_input(ev, true)
		await get_tree().process_frame


## 컨트롤 중앙을 마우스 왼쪽 버튼으로 누르고 뗀다(터치 에뮬레이션과 같은 GUI 경로).
func _click(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	var move: InputEventMouseMotion = InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	get_tree().root.push_input(move, true)
	await get_tree().process_frame
	for pressed in [true, false]:
		var ev: InputEventMouseButton = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.position = pos
		ev.global_position = pos
		ev.pressed = pressed
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		get_tree().root.push_input(ev, true)
		await get_tree().process_frame


func _focus_owner() -> Control:
	return get_viewport().gui_get_focus_owner()


func _sel(prop: String) -> Variant:
	return _scene().get(prop)


func _vis(prop: String) -> bool:
	var c: Control = _sel(prop)
	return c != null and c.is_visible_in_tree()


func _ids() -> Array:
	var out: Array = []
	for t in _sel("_tracks"):
		out.append(str(t.get("track_id", "")))
	return out


func _official_ids() -> Array:
	var out: Array = []
	for t in TrackLoader.list_tracks():
		out.append(str(t["track_id"]))
	return out


func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


func _viewport_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(1280, 720))


## 컨트롤이 1280×720 캔버스 안에 들어가는지(반 픽셀 여유).
func _inside(c: Control) -> bool:
	return _viewport_rect().grow(0.5).encloses(c.get_global_rect())


func _font_px(c: Control) -> int:
	return c.get_theme_font_size("font_size")


# --- 조향 감도 체험(데모) ---


func _read_settings() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read_text("user://settings.json"))
	return parsed if parsed is Dictionary else {}


func _find_tutorial() -> Node:
	var hud: Node = _scene().get_node_or_null("HUD")
	if hud == null:
		return null
	for c in hud.get_children():
		if c is TutorialDialog and not c.is_queued_for_deletion():
			return c
	return null


func _find_nickname_dialog() -> Node:
	for c in _scene().get_children():
		if c is NicknameDialog and not c.is_queued_for_deletion():
			return c
	return null


func _close_tutorial() -> void:
	var t: Node = _find_tutorial()
	if t != null:
		(t.get_node("CloseButton") as Button).emit_signal("pressed")
	await _frames(3)


func _panel() -> Node:
	return _scene().get_node_or_null("HUD/SteerCalibrationPanel")


func _check_calibration_first_start() -> void:
	LeaderboardClient.nickname = ""
	LeaderboardClient.calibration_intro_pending = false
	_ok(await _goto(MAIN), "calibration: main loads without nickname")
	await _frames(3)
	var dlg: Node = _find_nickname_dialog()
	_ok(dlg != null, "calibration: nickname dialog shown on first run")
	if dlg != null:
		(dlg.get("_edit") as LineEdit).text = "tester"
		(dlg.get("_confirm") as Button).emit_signal("pressed")
	await _frames(3)
	_ok(LeaderboardClient.nickname == "tester", "calibration: nickname saved")
	_ok(_find_nickname_dialog() == null, "calibration: nickname dialog closed")
	_ok(LeaderboardClient.calibration_intro_pending, "calibration: intro pending set after first nickname")
	_ok(_read_settings().get("calibration_intro_pending", null) == true, "calibration: pending persisted true")
	await _click(_scene().get_node("Menu/StartButton"))
	_ok(await _wait_scene(GAMEPLAY, 120), "calibration: first Start goes to gameplay")
	_ok(GameState.is_calibration(), "calibration: source is calibration")
	_ok(GameState.track_id == "steer_calibration", "calibration: track id")
	_ok(not LeaderboardClient.calibration_intro_pending, "calibration: pending consumed in memory")
	_ok(_read_settings().get("calibration_intro_pending", null) == false, "calibration: pending persisted false")
	var tut: Node = _find_tutorial()
	_ok(tut != null, "calibration: tutorial shown although tutorial_seen")
	_ok(tut != null and bool(tut.get("demo_mode")), "calibration: tutorial demo_mode")
	await _close_tutorial()
	_ok(_find_tutorial() == null, "calibration: tutorial closed")
	_ok(_panel() != null, "calibration: panel exists under HUD")
	_done.append("calibration_first_start")


func _check_calibration_panel() -> void:
	# 종류 선택의 기본 포커스는 마지막 모드를 따른다(앞 섹션이 유저 모드로 끝났으므로 공식으로 되돌린다).
	TrackSelectScript.last_mode = TrackSelectScript.MODE_OFFICIAL
	var panel: Node = _panel()
	if panel == null:
		_ok(false, "calibration panel: missing")
		return
	var Panel = panel.get_script()
	var pct0: float = roundf(Panel.expo_to_percent(Tuning.steer_expo))
	panel.call("nudge", 3)
	_ok(
		is_equal_approx(Tuning.steer_expo, Panel.percent_to_expo(pct0 + 3.0)),
		"calibration panel: nudge +3 -> expo for %d%%" % int(pct0 + 3.0)
	)
	await _key(KEY_BRACKETRIGHT)
	_ok(is_equal_approx(Tuning.steer_expo, Panel.percent_to_expo(pct0 + 4.0)), "calibration panel: ] is +1%")
	await _key(KEY_BRACKETLEFT)
	_ok(is_equal_approx(Tuning.steer_expo, Panel.percent_to_expo(pct0 + 3.0)), "calibration panel: [ is -1%")
	var writes: int = LeaderboardClient.settings_writes
	_ok(panel.call("flush_save") == true, "calibration panel: flush_save succeeds")
	_ok(LeaderboardClient.settings_writes == writes + 1, "calibration panel: one write per flush")
	_ok(
		is_equal_approx(float(_read_settings().get("steer_expo", -1.0)), Tuning.steer_expo),
		"calibration panel: settings.json steer_expo matches Tuning"
	)
	panel.call("flush_save")
	_ok(LeaderboardClient.settings_writes == writes + 1, "calibration panel: clean flush writes nothing")
	# 레이아웃: 패치가 캔버스 안, 미니맵·TIME 패널과 겹치지 않는다.
	var patch: Control = panel.get("_patch")
	var rect: Rect2 = patch.get_global_rect()
	_ok(patch.is_visible_in_tree() and _viewport_rect().grow(0.5).encloses(rect), "calibration panel: inside 1280x720 " + str(rect))
	for n in ["HUD/MiniMap", "HUD/TimePanel"]:
		var other: Control = _scene().get_node_or_null(n)
		_ok(other != null and not rect.intersects(other.get_global_rect()), "calibration panel: no overlap with " + n)
	var nodes: Array = panel.find_children("*", "Button", true, false)
	nodes.append_array(panel.find_children("*", "HSlider", true, false))
	_ok(nodes.size() >= 3, "calibration panel: has buttons and slider (%d)" % nodes.size())
	for c in nodes:
		_ok((c as Control).focus_mode == Control.FOCUS_NONE, "calibration panel: no focus on " + str(c.name))
	var finish: Button = null
	for b in panel.find_children("*", "Button", true, false):
		if (b as Button).text == "나가기":
			finish = b
	_ok(finish != null, "calibration panel: finish button found")
	if finish != null:
		finish.emit_signal("pressed")
	_ok(await _wait_scene(KIND, 120), "calibration panel: finish returns to kind select")
	_ok(_focus_owner() == _scene().get("_official_card"), "calibration panel: kind select focuses official card")
	_ok(not GameState.is_calibration(), "calibration panel: source cleared")
	_done.append("calibration_panel")


func _physics_ticks(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame


func _check_calibration_reenter_and_lap() -> void:
	var before_result: Dictionary = GameState.last_result.duplicate(true)
	var cal: Button = _scene().get("_calibration_button")
	_ok(cal != null, "calibration reenter: button exists")
	cal.emit_signal("pressed")
	_ok(await _wait_scene(GAMEPLAY, 120), "calibration reenter: button enters gameplay")
	_ok(GameState.is_calibration(), "calibration reenter: source calibration")
	_ok(_find_tutorial() != null, "calibration reenter: tutorial shown again")
	await _close_tutorial()
	# R 재시작: 출처 유지, 튜토리얼 재표시 없음(의도).
	await _key(KEY_R)
	await _frames(10)
	_ok(await _wait_scene(GAMEPLAY, 120), "calibration restart: still gameplay")
	_ok(GameState.is_calibration(), "calibration restart: source kept")
	_ok(_find_tutorial() == null, "calibration restart: tutorial not shown again")
	_ok(_panel() != null, "calibration restart: panel rebuilt")
	await _frames(5)
	# 무한 주행(랩 되감기): 데모 트랙은 닫힌 순환 코스, 전체 궤적·고스트 녹화 없음.
	var rd: Node = _scene()
	var track: TrackData = rd.get("_track")
	var stitch: StitchTrail = rd.get("_stitch")
	_ok(track != null and stitch != null, "calibration lap: track and stitch exist")
	_ok(not stitch.keep_full, "calibration lap: stitch keep_full off")
	_ok(
		track.points[0].distance_to(track.points[track.points.size() - 1]) < 1.0,
		"calibration lap: demo track is closed"
	)
	rd.set("_countdown_time", 0.01)
	await _physics_ticks(60)
	_ok(int(rd.get("_state")) == rd.State.RUNNING, "calibration lap: running after countdown")
	_ok(stitch.get_full_points().size() == 0, "calibration lap: no full trail accumulated")
	_ok((rd.get("_ghost_rec") as GhostRun).samples.size() / GhostRun.STRIDE <= 1, "calibration lap: ghost not recorded")
	# 결승 직전으로 옮겨 한 틱 돌리면 랩이 되감긴다.
	var player: Node2D = rd.get("_player")
	var s_near: float = track.length - 0.5
	player.position = track.point_at_s(s_near)
	player.heading = track.tangent_at_s(s_near).angle()
	rd.set("_hint", track.points.size() - 2)
	var before_laps: int = int(rd.get("_calib_laps"))
	rd.call("_tick_running", 1.0 / 60.0)
	_ok(int(rd.get("_calib_laps")) == before_laps + 1 and before_laps == 0, "calibration lap: laps == 1")
	_ok(int(rd.get("_hint")) == 0, "calibration lap: hint reset")
	_ok(float(rd.get("_last_s")) == 0.0, "calibration lap: last_s reset")
	_ok(int(rd.get("_state")) == rd.State.RUNNING, "calibration lap: still running")
	_ok(_scene_path() == GAMEPLAY, "calibration lap: still gameplay after rewind")
	var bar: Node = (rd.get("_hud") as Node).get("_progress")
	_ok(bar != null and is_zero_approx(float(bar.get("_progress"))), "calibration lap: HUD progress bar 0")
	# 실제 물리로 더 진행해도 이중 되감기·재로컬라이즈 튐이 없다.
	await _physics_ticks(10)
	_ok(_scene_path() == GAMEPLAY, "calibration lap: gameplay after 10 more ticks")
	_ok(int(rd.get("_calib_laps")) == 1, "calibration lap: no double rewind")
	_ok(float(rd.get("_last_s")) < 200.0, "calibration lap: no relocalize jump (s=%s)" % str(rd.get("_last_s")))
	# 패널의 나가기로만 끝난다.
	var finish: Button = null
	for b in _panel().find_children("*", "Button", true, false):
		if (b as Button).text == "나가기":
			finish = b
	_ok(finish != null, "calibration lap: exit button found")
	if finish != null:
		finish.emit_signal("pressed")
	_ok(await _wait_scene(KIND, 120), "calibration exit: returns to kind select, not result")
	_ok(not GameState.is_calibration(), "calibration exit: source cleared")
	_ok(not FileAccess.file_exists("user://records.json"), "calibration exit: no records file")
	_ok(not DirAccess.dir_exists_absolute("user://ghosts/"), "calibration exit: no ghosts dir")
	_ok(GameState.last_result == before_result, "calibration exit: last_result untouched")
	_done.append("calibration_reenter_and_lap")


func _check_calibration_menu_exit() -> void:
	GameState.start_calibration()
	_ok(await _wait_scene(GAMEPLAY, 120), "calibration menu: enter gameplay")
	await _close_tutorial()
	await _key(KEY_ESCAPE)
	await _frames(3)
	_ok(get_tree().paused, "calibration menu: Esc pauses")
	await _key(KEY_M)
	_ok(await _wait_scene(KIND, 120), "calibration menu: M returns to kind select")
	_ok(not get_tree().paused, "calibration menu: tree unpaused")
	_ok(not GameState.is_calibration(), "calibration menu: source cleared")
	_done.append("calibration_menu_exit")


func _check_calibration_existing_install() -> void:
	var f: FileAccess = FileAccess.open("user://settings.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"nickname": "old"}))
	f.close()
	LeaderboardClient.calibration_intro_pending = true
	LeaderboardClient.call("_load_settings")
	_ok(not LeaderboardClient.calibration_intro_pending, "existing install: missing key -> false")
	_ok(LeaderboardClient.nickname == "old", "existing install: nickname loaded")
	_ok(await _goto(MAIN), "existing install: main loads")
	_ok(_find_nickname_dialog() == null, "existing install: no nickname dialog")
	await _click(_scene().get_node("Menu/StartButton"))
	_ok(await _wait_scene(KIND), "existing install: Start goes to kind select")
	_ok(not GameState.is_calibration(), "existing install: not calibration")
	# 드라이버 전제 상태 복원.
	LeaderboardClient.nickname = "tester"
	LeaderboardClient.tutorial_seen = true
	LeaderboardClient.calibration_intro_pending = false
	LeaderboardClient.last_track_id = ""
	_done.append("calibration_existing_install")


# --- 메인 → 트랙 종류 선택 ---


func _check_main_to_kind() -> void:
	_ok(await _goto(MAIN), "main scene loads")
	await _frames(3)
	var start: Button = _scene().get_node("Menu/StartButton")
	_ok(start != null and start.is_visible_in_tree(), "main start button visible")
	await _click(start)
	_ok(await _wait_scene(KIND), "Start opens track kind select (not TrackSelect)")
	_ok(_scene_path() != SELECT, "Start does not jump straight to TrackSelect")
	_done.append("main_to_kind")


func _check_kind_layout() -> void:
	var s: Node = _scene()
	var off: Button = s.get("_official_card")
	var usr: Button = s.get("_user_card")
	var back: Button = s.get("_back_button")
	_ok(off != null and off.is_visible_in_tree(), "official card visible")
	_ok(usr != null and usr.is_visible_in_tree(), "user card visible")
	_ok(back != null and back.is_visible_in_tree(), "back button visible")
	_ok(_focus_owner() == off, "default focus is official card")
	var off_title: Label = off.find_child("TitleLabel", true, false)
	var off_desc: Label = off.find_child("DescLabel", true, false)
	var usr_title: Label = usr.find_child("TitleLabel", true, false)
	var usr_desc: Label = usr.find_child("DescLabel", true, false)
	_ok(off_title != null and off_title.text == "공식 트랙", "official card title")
	_ok(usr_title != null and usr_title.text == "유저 트랙", "user card title")
	_ok(off_desc != null and off_desc.text.contains("공식 리더보드"), "official desc mentions leaderboard")
	_ok(
		usr_desc != null and usr_desc.text.contains("공유 허브") and usr_desc.text.contains("이 기기"),
		"user desc mentions hub and local-only record"
	)
	for l in [off_title, off_desc, usr_title, usr_desc]:
		_ok(l.mouse_filter == Control.MOUSE_FILTER_IGNORE, "card label passes mouse: " + l.text)
	_ok(_inside(off) and _inside(usr) and _inside(back), "kind select widgets inside 1280x720")
	_ok(not off.get_global_rect().intersects(usr.get_global_rect()), "cards do not overlap")
	_ok(back.get_global_rect().position.y >= off.get_global_rect().end.y, "back below cards")
	# 설명 줄이 카드 안에 들어가는지(넘침 없음).
	for card in [off, usr]:
		var desc: Label = card.find_child("DescLabel", true, false)
		_ok(
			card.get_global_rect().grow(0.5).encloses(desc.get_global_rect()),
			"desc label inside card " + card.name
		)
	# 844×390 창 배율에서의 글자 크기(제목 ≥ 18px, 설명·버튼 ≥ 11px 상당).
	_ok(_font_px(off_title) * PHONE_SCALE >= 18.0, "card title readable at 844x390")
	_ok(_font_px(off_desc) * PHONE_SCALE >= 11.0, "card desc readable at 844x390")
	_ok(_font_px(back) * PHONE_SCALE >= 11.0, "back button text readable at 844x390")
	# ←→ 포커스 이동.
	await _key(KEY_RIGHT)
	_ok(_focus_owner() == usr, "right arrow moves focus to user card")
	await _key(KEY_LEFT)
	_ok(_focus_owner() == off, "left arrow moves focus back to official card")
	await _key(KEY_DOWN)
	var cal: Button = s.get("_calibration_button")
	_ok(_focus_owner() == cal, "down arrow moves focus to calibration button")
	await _key(KEY_DOWN)
	_ok(_focus_owner() == back, "down again moves focus to back button")
	await _key(KEY_UP)
	_ok(_focus_owner() == cal, "up arrow returns to calibration button")
	await _key(KEY_UP)
	_ok(_focus_owner() == off, "up again returns to official card")
	# 감도 다시 맞추기 버튼 레이아웃.
	_ok(cal != null and cal.is_visible_in_tree(), "calibration button visible")
	_ok(cal != null and cal.text == "감도 다시 맞추기", "calibration button text")
	_ok(_inside(cal), "calibration button inside 1280x720")
	_ok(
		cal.get_global_rect().position.y >= maxf(off.get_global_rect().end.y, usr.get_global_rect().end.y),
		"calibration button below cards"
	)
	_ok(
		back.get_global_rect().position.y >= cal.get_global_rect().end.y,
		"back button below calibration button"
	)
	var cal_desc: Label = s.find_child("CalibrationDescLabel", true, false)
	_ok(
		cal_desc != null and cal_desc.is_visible_in_tree() and cal_desc.text.contains("직접 달리며 조향 감도를 조절"),
		"calibration desc label"
	)
	_ok(cal_desc != null and _inside(cal_desc), "calibration desc inside 1280x720")
	_ok(_font_px(cal) * PHONE_SCALE >= 11.0, "calibration button text readable at 844x390")
	_ok(cal_desc != null and _font_px(cal_desc) * PHONE_SCALE >= 11.0, "calibration desc readable at 844x390")
	_ok(
		not TrackLoader.list_tracks().any(func(t): return str(t.get("track_id", "")) == "steer_calibration"),
		"demo not in list_tracks"
	)
	_ok(
		not TrackLoader.list_custom_tracks().any(func(t): return str(t.get("track_id", "")) == "steer_calibration"),
		"demo not in list_custom_tracks"
	)
	_done.append("kind_layout")


func _check_kind_back() -> void:
	await _key(KEY_ESCAPE)
	_ok(await _wait_scene(MAIN), "Esc on kind select returns to main")
	_ok(await _goto(KIND), "kind select reload")
	await _click(_scene().get("_back_button"))
	_ok(await _wait_scene(MAIN), "back button on kind select returns to main")
	_done.append("kind_back")


# --- 공식 모드 ---


func _assert_official_mode(label: String) -> void:
	_ok(_scene_path() == SELECT, label + ": on TrackSelect")
	_ok(str(_scene().call("current_mode")) == TrackSelectScript.MODE_OFFICIAL, label + ": official")
	var ids: Array = _ids()
	_ok(ids == _official_ids(), label + ": list is exactly official tracks")
	var has_custom: bool = false
	for id in ids:
		if str(id).begins_with("custom_"):
			has_custom = true
	_ok(not has_custom, label + ": no custom track in official list")
	_ok((_sel("_header_label") as Label).text == "공식 트랙", label + ": header")
	for p in [
		"_create_button",
		"_import_button",
		"_export_button",
		"_delete_button",
		"_publish_button",
		"_hub_button"
	]:
		_ok(not _vis(p), label + ": hidden " + p)
	_ok(not _vis("_action_row"), label + ": action row hidden")
	_ok(_vis("_play_button"), label + ": play visible")
	_ok(not _vis("_empty_label"), label + ": no empty notice")
	_ok(
		_vis("_leaderboard_button") == LeaderboardClient.is_online_enabled(),
		label + ": leaderboard button follows online state"
	)


func _check_official_mode() -> void:
	_ok(await _goto(KIND), "kind select for official")
	await _click(_scene().get("_official_card"))
	_ok(await _wait_scene(SELECT), "official card opens TrackSelect")
	_assert_official_mode("official")
	_ok(_focus_owner() == _sel("_play_button"), "official: play has focus")
	_ok(TrackSelectScript.pending_mode == "", "pending mode consumed on entry")
	# 트랙 순환은 공식 목록 안에서만 돈다.
	var n: int = _ids().size()
	for _i in range(n):
		await _key(KEY_RIGHT)
		_ok(not str(_scene().call("_current_id")).begins_with("custom_"), "cycle stays official")
	_done.append("official_mode")


func _check_official_back() -> void:
	await _key(KEY_ESCAPE)
	_ok(await _wait_scene(KIND), "Esc on official TrackSelect returns to kind select")
	_ok(_focus_owner() == _scene().get("_official_card"), "back from official focuses official card")
	await _key(KEY_ESCAPE)
	_ok(await _wait_scene(MAIN), "then Esc returns to main")
	_ok(await _goto(KIND), "kind select again")
	await _click(_scene().get("_official_card"))
	_ok(await _wait_scene(SELECT), "official again")
	await _click(_sel("_back_button"))
	_ok(await _wait_scene(KIND), "back button on TrackSelect returns to kind select")
	_done.append("official_back")


# --- 유저 모드(빈 목록) ---


func _assert_user_common(label: String) -> void:
	_ok(_scene_path() == SELECT, label + ": on TrackSelect")
	_ok(str(_scene().call("current_mode")) == TrackSelectScript.MODE_USER, label + ": user mode")
	_ok((_sel("_header_label") as Label).text == "유저 트랙", label + ": header")
	for id in _ids():
		_ok(str(id).begins_with("custom_"), label + ": only custom tracks (%s)" % id)
	_ok(_vis("_hub_button"), label + ": hub button visible")
	_ok(_vis("_create_button"), label + ": create visible")
	_ok(_vis("_import_button"), label + ": import visible")
	_ok(not _vis("_leaderboard_button"), label + ": leaderboard hidden")


func _check_user_empty() -> void:
	_ok(TrackLoader.list_custom_tracks().is_empty(), "precondition: no custom tracks yet")
	# 키보드로 유저 카드 선택: → 후 Enter.
	await _key(KEY_RIGHT)
	_ok(_focus_owner() == _scene().get("_user_card"), "focus on user card")
	await _key(KEY_ENTER)
	_ok(await _wait_scene(SELECT), "Enter on user card opens TrackSelect")
	_assert_user_common("user empty")
	_ok(_ids().is_empty(), "user empty: list empty")
	var empty: Label = _sel("_empty_label")
	_ok(empty.is_visible_in_tree(), "user empty: notice visible")
	_ok(
		empty.text.contains("아직 유저 트랙이 없습니다") and empty.text.contains("공유 허브"),
		"user empty: notice text"
	)
	for p in ["_play_button", "_preview", "_selector", "_info_label", "_export_button"]:
		_ok(not _vis(p), "user empty: hidden " + p)
	_ok(not _vis("_delete_button"), "user empty: delete hidden")
	_ok(not _vis("_publish_button"), "user empty: publish hidden")
	_ok(_focus_owner() == _sel("_hub_button"), "user empty: hub button has focus")
	# 빈 목록에서 Enter(Play 없음)나 ←→ 는 오류 없이 무시된다.
	await _key(KEY_LEFT)
	await _key(KEY_RIGHT)
	_ok(_scene_path() == SELECT and _ids().is_empty(), "user empty: arrows harmless")
	# 허브 버튼과 만들기 버튼이 모두 키보드로 닿는다(↓로 만들기 줄).
	await _key(KEY_DOWN)
	var f: Control = _focus_owner()
	_ok(f == _sel("_create_button") or f == _sel("_import_button"), "user empty: down reaches actions")
	_done.append("user_empty")


func _check_user_back() -> void:
	await _key(KEY_ESCAPE)
	_ok(await _wait_scene(KIND), "Esc on user TrackSelect returns to kind select")
	_ok(_focus_owner() == _scene().get("_user_card"), "back from user focuses user card")
	_done.append("user_back")


func _check_hub_back() -> void:
	await _click(_scene().get("_user_card"))
	_ok(await _wait_scene(SELECT), "user card click opens TrackSelect")
	await _click(_sel("_hub_button"))
	_ok(await _wait_scene(HUB), "hub button opens community hub")
	await _key(KEY_ESCAPE)
	_ok(await _wait_scene(SELECT), "Esc on hub returns to TrackSelect")
	_assert_user_common("hub back")
	# 허브의 뒤로 버튼 경로도 확인한다.
	await _click(_sel("_hub_button"))
	_ok(await _wait_scene(HUB), "hub again")
	var back: Button = _scene().get("_list_back_btn")
	_ok(back != null and back.is_visible_in_tree(), "hub list back button visible")
	await _click(back)
	_ok(await _wait_scene(SELECT), "hub back button returns to TrackSelect")
	_assert_user_common("hub back button")
	_done.append("hub_back")


# --- 유저 모드(트랙 있음) ---


## 직접 만든 트랙(공식 cotton_01 JSON 불러오기) + 허브에서 받은 트랙(heart_01 경로를 허브 게시물로).
func _make_tracks() -> void:
	var own: Dictionary = TrackLoader.import_custom_from_text(
		_read_text("res://tracks/official/cotton_01.json"), "My Own Track"
	)
	_ok(bool(own["ok"]), "fixture: own custom track imported")
	_own_id = str(own["track_id"])
	# 허브 게시물 형식(폴리라인)은 게시용 변환(build_publish_track)으로 만든다: heart_01 을 임시 커스텀으로
	# 불러와 변환한 뒤 임시본은 지운다.
	var tmp: Dictionary = TrackLoader.import_custom_from_text(
		_read_text("res://tracks/official/heart_01.json"), "Temp Heart"
	)
	var built: Dictionary = TrackLoader.build_publish_track(str(tmp["track_id"]))
	_ok(bool(built["ok"]), "fixture: publish-form track built")
	TrackLoader.delete_custom_track(str(tmp["track_id"]))
	var hub: Dictionary = TrackLoader.import_hub_track(
		{
			"post_id": "00000000-0000-4000-8000-000000000001",
			"title": "Hub Heart",
			"content_hash": "hash-start-flow",
			"track": built["track"],
		}
	)
	_ok(bool(hub["ok"]), "fixture: hub track imported " + str(hub["message"]))
	_hub_id = str(hub["track_id"])


func _check_user_tracks() -> void:
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_USER
	_ok(await _goto(SELECT), "TrackSelect user with tracks")
	_assert_user_common("user tracks")
	var ids: Array = _ids()
	_ok(ids.size() == 2 and _own_id in ids and _hub_id in ids, "user tracks: own + hub listed")
	_ok(_vis("_play_button"), "user tracks: play visible")
	_ok(not _vis("_empty_label"), "user tracks: no empty notice")
	_ok(_focus_owner() == _sel("_play_button"), "user tracks: play focused")
	_ok(_vis("_export_button") and _vis("_delete_button"), "user tracks: export/delete visible")
	# 트랙별 표식·게시 버튼.
	var seen_hub: bool = false
	var seen_own: bool = false
	for _i in range(ids.size()):
		var id: String = str(_scene().call("_current_id"))
		var info: String = (_sel("_info_label") as Label).text
		if id == _hub_id:
			seen_hub = true
			_ok(info.begins_with("허브 · "), "hub track shows hub badge: " + info)
			_ok(not _vis("_publish_button"), "unmodified hub download has no publish button")
		elif id == _own_id:
			seen_own = true
			_ok(info.begins_with("CUSTOM · "), "own track shows CUSTOM badge: " + info)
			_ok(_vis("_publish_button"), "own track shows publish button")
		await _key(KEY_RIGHT)
	_ok(seen_hub and seen_own, "cycled through both user tracks")
	_done.append("user_tracks")


## 공식 모드에서 파일을 끌어다 놓으면(불러오기 버튼은 숨김) 유저 모드로 바뀌어 새 트랙을 보여 준다.
func _check_user_import_drop() -> void:
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_OFFICIAL
	_ok(await _goto(SELECT), "TrackSelect official for drop")
	var path: String = OS.get_user_data_dir().path_join("drop_star.json")
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(_read_text("res://tracks/official/star_01.json"))
	f.close()
	_scene().call("_on_files_dropped", PackedStringArray([path]))
	await _frames(2)
	_ok(str(_scene().call("current_mode")) == TrackSelectScript.MODE_USER, "drop switches to user")
	_ok(str(_scene().call("_current_id")).begins_with("custom_"), "dropped track selected")
	_ok(_ids().size() == 3, "user list now has 3 tracks")
	_ok(_vis("_hub_button") and _vis("_action_row"), "user buttons shown after drop")
	# 정리: 방금 불러온 트랙을 삭제해 이후 검사 목록을 2개로 유지한다.
	var dropped: String = str(_scene().call("_current_id"))
	_ok(TrackLoader.delete_custom_track(dropped), "cleanup dropped track")
	DirAccess.remove_absolute(path)
	_done.append("user_import_drop")


# --- 결과 화면 복귀 ---


## TrackSelect에서 Play → (게임플레이 대신) 결과 화면 → Menu 로 돌아온다.
func _play_and_return(select_id: String) -> void:
	_scene().call("_select_track", select_id)
	await _frames(1)
	_ok(str(_scene().call("_current_id")) == select_id, "selected " + select_id)
	(_sel("_play_button") as Button).emit_signal("pressed")
	_ok(TrackSelectScript.pending_mode == "", "play leaves no pending mode")
	_ok(await _wait_scene("res://scenes/Gameplay.tscn", 120), "gameplay loads for " + select_id)
	_ok(GameState.track_id == select_id, "GameState.track_id is played track")
	GameState.to_result(
		{
			"track_id": select_id,
			"difficulty": GameState.difficulty,
			"final_time_ms": 61234,
			"grade": "B",
			"accuracy": 90.0,
		}
	)
	_ok(await _wait_scene(RESULT, 120), "result screen loads")
	var menu: Button = _scene().get("_menu_button")
	_ok(menu != null, "result menu button exists")
	menu.emit_signal("pressed")
	_ok(await _wait_scene(SELECT, 120), "result Menu returns to TrackSelect")


func _check_result_return_custom() -> void:
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_USER
	_ok(await _goto(SELECT), "user mode before play")
	await _play_and_return(_hub_id)
	_assert_user_common("after custom run")
	_ok(str(_scene().call("_current_id")) == _hub_id, "played hub track reselected")
	_done.append("result_return_custom")


func _check_result_return_official() -> void:
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_OFFICIAL
	_ok(await _goto(SELECT), "official mode before play")
	await _play_and_return("heart_01")
	_assert_official_mode("after official run")
	_ok(str(_scene().call("_current_id")) == "heart_01", "played official track reselected")
	_done.append("result_return_official")


func _check_leaderboard_return() -> void:
	# 리더보드는 공식 모드에서만 열린다. 뒤로 오면 공식 모드 유지.
	if not _vis("_leaderboard_button"):
		# 온라인 비활성이면 버튼이 없으므로 핸들러를 직접 부른다(같은 복귀 경로).
		_scene().call("_on_leaderboard_pressed")
	else:
		(_sel("_leaderboard_button") as Button).emit_signal("pressed")
	_ok(await _wait_scene("res://scenes/Leaderboard.tscn", 120), "leaderboard opens")
	get_tree().change_scene_to_file(SELECT)  # 리더보드 뒤로 = return_scene(TrackSelect)
	_ok(await _wait_scene(SELECT), "back to TrackSelect from leaderboard")
	_assert_official_mode("after leaderboard")
	_done.append("leaderboard_return")


func _check_editor_return() -> void:
	# 유저 모드에서 "트랙 만들기" → 에디터 → TrackSelect 복귀 시 유저 모드. 에디터 내부 동작은 이 검사의
	# 범위가 아니므로 에디터 씬이 뜬 것만 확인하고, 에디터의 나가기와 같은 씬 전환으로 돌아온다.
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_USER
	_ok(await _goto(SELECT), "user mode before editor")
	# 방금 공식 트랙을 플레이한 상태에서도 에디터 복귀는 유저 모드여야 한다.
	_ok(not GameState.track_id.begins_with("custom_"), "precondition: last run was official")
	(_sel("_create_button") as Button).emit_signal("pressed")
	_ok(TrackSelectScript.pending_mode == TrackSelectScript.MODE_USER, "leaving keeps user mode")
	_ok(await _wait_scene(EDITOR, 120), "create opens track editor")
	get_tree().change_scene_to_file(SELECT)
	_ok(await _wait_scene(SELECT), "editor exit returns to TrackSelect")
	_assert_user_common("after editor")
	_done.append("editor_return")
	await _check_layout_fit()


# --- 레이아웃 ---


func _panel_fits(label: String) -> void:
	var panel: Control = _scene().get_node("Panel")
	_ok(_inside(panel), label + ": TrackSelect panel inside 1280x720 " + str(panel.get_global_rect()))
	for p in ["_play_button", "_hub_button", "_back_button", "_create_button"]:
		var c: Control = _sel(p)
		if c.is_visible_in_tree():
			_ok(_inside(c), label + ": inside " + p)


func _check_layout_fit() -> void:
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_USER
	_ok(await _goto(SELECT), "layout user")
	_panel_fits("user tracks")
	var play: Control = _sel("_play_button")
	var hub: Control = _sel("_hub_button")
	_ok(
		absf(play.get_global_rect().size.y - hub.get_global_rect().size.y) < 1.0,
		"hub button same height as play (prominent)"
	)
	_ok(_font_px(hub) * PHONE_SCALE >= 11.0, "hub button text readable at 844x390")
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_OFFICIAL
	_ok(await _goto(SELECT), "layout official")
	_panel_fits("official")
	# 빈 유저 목록 레이아웃: 트랙을 잠시 옮겨 두지 않고 목록만 비운 상태를 흉내 낸다.
	TrackSelectScript.pending_mode = TrackSelectScript.MODE_USER
	_ok(await _goto(SELECT), "layout user empty")
	_scene().set("_tracks", [])
	_scene().call("_refresh")
	await _frames(2)
	_panel_fits("user empty")
	var empty: Label = _sel("_empty_label")
	_ok(_font_px(empty) * PHONE_SCALE >= 11.0, "empty notice readable at 844x390")
	_done.append("layout_fit")
