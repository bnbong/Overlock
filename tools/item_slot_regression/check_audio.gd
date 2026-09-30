extends RefCounted
## 주행 전용 소리(재봉틀 틱 루프) 누수 회귀 검사. check.gd 가 run(self)로 부르며 헬퍼(_new_game·_step·
## _action·_ok 등)는 check.gd 것을 그대로 쓴다. 주행해 틱 rate 를 올린 뒤 일시정지 → 메뉴·재시작·
## 에디터 복귀·결과 전환 같은 이탈 경로를 실제 씬 전환(change_scene_to_file·reload_current_scene)으로
## 따라가고, 새 화면에서 AudioManager 의 틱 상태(_tick_norm)와 틱 플레이어의 playing 을 본다.
## 헤드리스(Dummy 오디오 드라이버)에서도 AudioStreamPlayer.play() 뒤 playing 이 true 가 되므로 이것으로
## 판정한다(실제 스피커 출력 검증은 아니다). 서버에 닿지 않도록 base_url 을 닫힌 로컬 포트로 바꾼다.

const MAIN: String = "res://scenes/Main.tscn"
const RESULT: String = "res://scenes/Result.tscn"
const SELECT: String = "res://scenes/TrackSelect.tscn"
const EDITOR: String = "res://scenes/TrackEditor.tscn"
const GAMEPLAY: String = "res://scenes/Gameplay.tscn"
const SILENT_FRAMES: int = 60
const STALE_WAIT: float = 0.8  # AudioManager.TICK_STALE_TIME(0.5초)보다 넉넉히

var h: Node = null
var am: Node = null


func run(host: Node) -> void:
	h = host
	am = h.get_node("/root/AudioManager")
	LeaderboardClient.base_url = "http://127.0.0.1:9"
	await _case_to_menu("esc_m", false)
	await _case_to_menu("auto_pause_m", true)
	await _case_to_menu("stun_m", false, "stun")
	await _case_to_menu("autopilot_m", false, "autopilot")
	if TouchControls.is_forced():
		await _case_to_menu("touch_menu", false, "", true)
	await _case_restart()
	await _case_editor_return()
	await _case_result()
	await _case_stale()


# --- 헬퍼 ---


func _tree() -> SceneTree:
	return h.get_tree()


## 주행 게임을 현재 씬으로 올리고, 물리 틱과 렌더 프레임을 번갈아 돌려 프레젠테이션이 틱 rate 를
## 올리게 한다. effect 가 있으면 마지막 몇 틱을 그 상태(부상 스턴·엄마 찬스)로 돌린다.
func _drive(effect: String = "") -> Node:
	var g: Node = await h._new_game([h._item(60.0, "autopilot")])
	_tree().current_scene = g
	for i in 60:
		h._step(g, 1)
		await _tree().process_frame
	if effect == "stun":
		g._player.stun_timer = 1.0
	elif effect == "autopilot":
		h._visit(g, 0)
		h._leave(g)
		h._tap_space()
	for i in 4:
		h._step(g, 1)
		await _tree().process_frame
	return g


## 현재 씬이 path 가 될 때까지(최대 frames 프레임) 기다린다.
func _wait_scene(path: String, frames: int = 90) -> bool:
	for i in frames:
		var s: Node = _tree().current_scene
		if s != null and s.scene_file_path == path and s.is_node_ready():
			return true
		await _tree().process_frame
	return false


## SILENT_FRAMES 동안 틱 플레이어가 한 번도 재생 중이 아니고 rate 도 0 인가.
func _tick_silent() -> bool:
	var playing: int = 0
	for i in SILENT_FRAMES:
		await _tree().process_frame
		if am._tick_player.playing:
			playing += 1
	return playing == 0 and am._tick_norm <= 0.001


## 검사로 올린 현재 씬을 치우고 검사 노드를 현재 씬으로 되돌린다.
func _cleanup() -> void:
	_tree().paused = false
	h._release_all()
	var cur: Node = _tree().current_scene
	_tree().current_scene = h
	if cur != null and cur != h:
		cur.set_physics_process(false)
		cur.queue_free()
	await h._frames(3)


## 일시정지 오버레이의 터치 버튼(label)을 누른다(HUD._tap_action 경로).
func _press_touch_pause_button(g: Node, label: String) -> bool:
	var row: Node = g._hud._pause_overlay.get_node_or_null("TouchPauseButtons")
	if row == null:
		return false
	for b in row.get_children():
		if b is Button and (b as Button).text == label:
			(b as Button).pressed.emit()
			Input.flush_buffered_events()
			return true
	return false


# --- 경로별 검사 ---


## 일시정지(Esc·자동 일시정지) → 메인 복귀(M·터치 "메인"). 메인 메뉴에서 틱이 울리지 않아야 한다.
func _case_to_menu(tag: String, auto: bool, effect: String = "", touch: bool = false) -> void:
	var g: Node = await _drive(effect)
	var before: float = am._tick_norm
	print("audio %s: tick rate before pause %.3f" % [tag, before])
	if effect == "":
		h._ok(before > 0.05, "audio %s: tick loop running before pause" % tag)
	elif effect == "autopilot":
		h._ok(g._player.autopilot_timer > 0.0, "audio %s: autopilot active" % tag)
	else:
		h._ok(g._player.stun_timer > 0.0, "audio %s: stun active" % tag)
	if auto:
		h._ok(g.request_auto_pause(), "audio %s: auto paused" % tag)
	else:
		h._tap_pause()
		h._step(g, 1)
	h._ok(_tree().paused, "audio %s: tree paused" % tag)
	await h._frames(3)
	if touch:
		h._ok(_press_touch_pause_button(g, "메인"), "audio %s: touch menu button" % tag)
	else:
		h._action(&"to_menu", true)
		h._action(&"to_menu", false)
	h._step(g, 1)
	var arrived: bool = await _wait_scene(MAIN)
	h._ok(arrived, "audio %s: main menu shown" % tag)
	h._ok(am._tick_norm <= 0.001, "audio %s: tick rate cleared on leave" % tag)
	h._ok(await _tick_silent(), "audio %s: no machine tick in main menu" % tag)
	h._ok(am._current_bgm_id == "menu" and am._bgm_player.playing, "audio %s: menu BGM" % tag)
	await _cleanup()


## 일시정지 → R(터치 모드는 "재시작" 버튼) 재시작: 새 판 카운트다운에서 틱이 울리지 않고 BGM 은 이어진다.
func _case_restart() -> void:
	var g: Node = await _drive()
	h._ok(am._tick_norm > 0.05, "audio restart: tick loop running before pause")
	h._tap_pause()
	h._step(g, 1)
	await h._frames(3)
	if TouchControls.is_forced():
		h._ok(_press_touch_pause_button(g, "재시작"), "audio restart: touch restart button")
	else:
		h._action(&"restart", true)
		h._action(&"restart", false)
	h._step(g, 1)
	await h._frames(3)
	var ng: Node = _tree().current_scene
	var reloaded: bool = ng != null and ng != g and ng.scene_file_path == GAMEPLAY
	h._ok(reloaded, "audio restart: new gameplay scene")
	if reloaded:
		ng.set_physics_process(false)
	h._ok(am._tick_norm <= 0.001, "audio restart: tick rate cleared")
	h._ok(await _tick_silent(), "audio restart: no machine tick during new countdown")
	var bgm_ok: bool = am._current_bgm_id == "gameplay" and am._bgm_player.playing
	h._ok(bgm_ok, "audio restart: gameplay BGM continues")
	await _cleanup()


## 에디터 테스트 플레이 → 일시정지 → M(편집으로): 편집 화면에서 틱이 울리지 않고 메뉴 곡으로 돌아온다.
func _case_editor_return() -> void:
	GameState.run_source = GameState.SOURCE_EDITOR_TEST
	var g: Node = await _drive()
	h._ok(am._tick_norm > 0.05, "audio editor: tick loop running before pause")
	h._tap_pause()
	h._step(g, 1)
	await h._frames(3)
	h._action(&"to_menu", true)
	h._action(&"to_menu", false)
	h._step(g, 1)
	var arrived: bool = await _wait_scene(EDITOR)
	h._ok(arrived, "audio editor: track editor shown")
	h._ok(am._tick_norm <= 0.001, "audio editor: tick rate cleared on leave")
	h._ok(await _tick_silent(), "audio editor: no machine tick in editor")
	var bgm_ok: bool = am._current_bgm_id == "menu" and am._bgm_player.playing
	h._ok(bgm_ok, "audio editor: menu BGM in editor (not gameplay BGM)")
	GameState.clear_editor_test()
	await _cleanup()


## 완주 → 결과 → 트랙 선택: 결과·선택 화면에서 틱이 울리지 않는다.
func _case_result() -> void:
	var g: Node = await _drive()
	h._ok(am._tick_norm > 0.05, "audio result: tick loop running before finish")
	g._finish()
	g._go_to_result()
	var arrived: bool = await _wait_scene(RESULT)
	h._ok(arrived, "audio result: result screen shown")
	h._ok(await _tick_silent(), "audio result: no machine tick on result screen")
	_tree().change_scene_to_file(SELECT)
	arrived = await _wait_scene(SELECT)
	h._ok(arrived, "audio result: track select shown")
	h._ok(await _tick_silent(), "audio result: no machine tick on track select")
	h._ok(am._current_bgm_id == "menu" and am._bgm_player.playing, "audio result: menu BGM")
	await _cleanup()


## 방어선: 구동자 없이 rate 만 남으면(이탈 정리 누락 가정) 짧은 시간 뒤 틱 루프가 스스로 꺼진다.
func _case_stale() -> void:
	am.set_machine_rate(0.6)
	await _tree().create_timer(STALE_WAIT).timeout
	h._ok(am._tick_norm <= 0.001, "audio stale: orphan tick rate switches itself off")
	h._ok(await _tick_silent(), "audio stale: no tick afterwards")
	am.set_machine_rate(0.0)
