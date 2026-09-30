extends Node
## 아이템 슬롯(FIFO 2칸)·사용 입력·자동 일시정지 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## Gameplay 씬을 루트에 붙이고 RaceDirector 의 물리 틱(_physics_process)을 고정 dt 로 직접 돌린다
## (자동 물리 처리는 끈다 → 같은 입력이면 같은 결과). 입력은 InputEventKey/InputEventAction 을
## Input.parse_input_event 로 넣어 실제 경로(_unhandled_input 버퍼 → InputFrame)를 통과시킨다.
## 필드 아이템은 검사용 합성 배치(출발 직후 중심선)로 바꾸고, 픽업은 노루발을 아이템 위치로 옮겨 만든다.
## run.sh 가 세 모드로 실행한다: 키보드(인자 없음), 터치(--touch-controls), --no-focus-pause.
## 데스크톱 헤드리스 모사이며 실제 기기·웹 검증이 아니다. 실패가 하나라도 있으면 종료 코드 1.

const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const RD: GDScript = preload("res://scripts/systems/RaceDirector.gd")
const AudioCheck: GDScript = preload("res://item_slot_regression/check_audio.gd")
const DT: float = 1.0 / 60.0
const B := TouchControls.Btn
const USE_RECT: Rect2 = Rect2(1014.0, 436.0, 112.0, 112.0)
const RESULT_KEYS: Array[String] = [
	"track_id",
	"difficulty",
	"finish_ms",
	"penalty_ms",
	"final_time_ms",
	"accuracy",
	"perfect_rate",
	"off_seam_ms",
	"cuts",
	"resets",
	"max_speed",
	"avg_speed",
	"max_combo",
	"grade",
	"grade_score",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _mode: String = "keys"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	LeaderboardClient.tutorial_seen = true
	if TouchControls.is_forced():
		_mode = "touch"
	elif RD.focus_pause_disabled():
		_mode = "nofocus"
	await get_tree().process_frame
	var sections: Array[String] = []
	if _mode == "nofocus":
		sections = ["nofocus"]
		await _check_nofocus()
	else:
		sections = ["input_map", "fifo", "full", "edge", "effects", "pending", "locks"]
		sections.append_array(["gates", "finish", "restart", "determinism", "stats", "auto_pause"])
		_check_input_map()
		await _check_fifo_and_full()
		await _check_edge()
		await _check_effects()
		await _check_pending()
		await _check_locks()
		await _check_gates()
		await _check_finish()
		await _check_restart()
		await _check_determinism()
		_check_stats()
		await _check_auto_pause()
		sections.append("run_audio")
		await _check_run_audio()
		if _mode == "touch":
			sections.append("touch")
			await _check_touch()
		else:
			sections.append("keys_hud")
			await _check_keys_hud()
	for s in sections:
		_ok(s in _done, "section completed: " + s)
	print("item slot regression (%s): %d passed, %d failed" % [_mode, _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


# --- 헬퍼 ---


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Gameplay 를 루트에 붙이고 자동 물리 처리를 끈다. items 가 있으면 합성 배치로 바꾼다.
func _new_game(items: Array = [], running: bool = true) -> Node:
	get_tree().paused = false
	var g: Node = GameplayScene.instantiate()
	get_tree().root.add_child(g)
	await _frames(2)
	g.set_physics_process(false)
	if not items.is_empty():
		_set_items(g, items)
	if running:
		g._countdown_time = 0.0001
		_step(g, 1)
	return g


func _free_game(g: Node) -> void:
	get_tree().paused = false
	_release_all()
	if is_instance_valid(g):
		g.queue_free()
	await _frames(2)


## 합성 아이템 배치. 표현(ItemField)도 같은 목록으로 다시 구성하고, 공유 트랙 캐시는 바로 되돌린다.
func _set_items(g: Node, items: Array) -> void:
	var track: TrackData = g._track
	var saved: Array = track.items
	track.items = items
	g._init_player()
	track.items = saved
	g._hud.set_item_slots(g._slots)


func _item(s: float, type: String, lat: float = 0.0) -> Dictionary:
	return {"s": s, "lat": lat, "type": type}


func _world(g: Node, i: int) -> Vector2:
	var it: Dictionary = g._items[i]
	var s: float = float(it["s"])
	return g._track.point_at_s(s) + g._track.tangent_at_s(s).orthogonal() * float(it["lat"])


## 노루발을 pos 로 옮기고 트랙 질의 hint 를 맞춘다(재로컬라이즈 실패로 이탈 리셋이 나지 않게).
func _teleport(g: Node, pos: Vector2) -> void:
	g._player.position = pos
	g._hint = int(g._track.query(pos, 0)["idx"])


func _away(g: Node) -> Vector2:
	return g._track.point_at_s(8.0)


func _step(g: Node, n: int = 1) -> void:
	for i in n:
		g._physics_process(DT)


func _key(code: int, pressed: bool, echo: bool = false) -> void:
	var ev: InputEventKey = InputEventKey.new()
	ev.physical_keycode = code as Key
	ev.keycode = code as Key
	ev.pressed = pressed
	ev.echo = echo
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _action(action: StringName, pressed: bool) -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _tap_space() -> void:
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)


func _tap_pause() -> void:
	_action(&"pause", true)
	_action(&"pause", false)


func _release_all() -> void:
	for a in RD.GAME_ACTIONS:
		Input.action_release(a)
	Input.action_release(&"pause")
	Input.flush_buffered_events()


## 아이템 i 위로 옮겨 한 틱 돌린다.
func _visit(g: Node, i: int) -> void:
	_teleport(g, _world(g, i))
	_step(g, 1)


func _leave(g: Node) -> void:
	_teleport(g, _away(g))
	_step(g, 1)


# --- 검사 ---


func _check_input_map() -> void:
	_ok(InputMap.has_action(&"use_item"), "use_item action registered")
	var has_space: bool = false
	for ev in InputMap.action_get_events(&"use_item"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_SPACE:
			has_space = true
	_ok(has_space, "use_item bound to physical Space")
	var clash: Array[String] = []
	for a in ["steer_left", "steer_right", "speed_up", "speed_down", "drift", "restart", "pause"]:
		for ev in InputMap.action_get_events(a):
			if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_SPACE:
				clash.append(a)
	_ok(clash.is_empty(), "Space not bound to other game actions %s" % str(clash))
	var ctrl: bool = false
	for ev in InputMap.action_get_events(&"use_item"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_CTRL:
			ctrl = true
	_ok(not ctrl, "use_item not bound to Ctrl (browser shortcut clash)")
	_ok(RD.ITEM_SLOT_CAPACITY == 2, "slot capacity 2")
	_done.append("input_map")


func _check_fifo_and_full() -> void:
	var items: Array = [_item(60.0, "thimble"), _item(110.0, "autopilot"), _item(160.0, "thimble")]
	var g: Node = await _new_game(items)
	_ok(int(g._state) == 1, "running")
	_ok(g.item_slots().is_empty(), "slots start empty")
	_ok(g._hud._item_slots.slots().is_empty(), "HUD slots start empty")
	_ok(g.get_viewport().gui_get_focus_owner() == null, "no GUI focus owner while running")
	_visit(g, 0)
	_ok(g.item_slots() == ["thimble"], "pickup 1 stored: %s" % str(g.item_slots()))
	_ok(g._player.thimble_timer == 0.0, "pickup does not activate thimble")
	_ok(bool(g._collected[0]), "item 0 collected")
	_ok(bool(g._item_field._items[0]["collected"]), "ItemField notified for item 0")
	_visit(g, 1)
	_ok(g.item_slots() == ["thimble", "autopilot"], "pickup 2 appended (FIFO order)")
	_ok(g._player.autopilot_timer == 0.0, "pickup does not activate autopilot")
	_ok(g._hud._item_slots.slots() == ["thimble", "autopilot"], "HUD mirrors slots")
	_done.append("fifo")
	# 가득 참: 세 번째는 획득하지 않고 필드에 남는다. 피드백은 반경 진입 1회.
	g._hud._item_slots._shake_t = 0.0
	_visit(g, 2)
	_ok(g.item_slots() == ["thimble", "autopilot"], "full: slots unchanged")
	_ok(not bool(g._collected[2]), "full: item 2 not collected")
	_ok(not bool(g._item_field._items[2]["collected"]), "full: ItemField keeps item 2")
	_ok(g._hud._item_slots.is_shaking(), "full: slot widget shakes")
	g._hud._item_slots._shake_t = 0.0
	_teleport(g, _world(g, 2))
	_step(g, 1)
	_ok(not g._hud._item_slots.is_shaking(), "full: feedback once while staying in radius")
	_leave(g)
	g._hud._item_slots._shake_t = 0.0
	_visit(g, 2)
	_ok(g._hud._item_slots.is_shaking(), "full: feedback again after re-entering")
	# 사용 → 같은 반경 안에 있으면 다음 틱에 획득.
	_teleport(g, _world(g, 2))
	_tap_space()
	_step(g, 1)
	_ok(g._player.thimble_timer > 0.0, "use: first-in (thimble) activated")
	_ok(g._player.autopilot_timer == 0.0, "use: second item not activated")
	_ok(bool(g._collected[2]), "same tick: use frees slot, pickup after sim stores item 2")
	_ok(g.item_slots() == ["autopilot", "thimble"], "after use+pickup: %s" % str(g.item_slots()))
	_tap_space()
	_step(g, 1)
	_ok(g._player.autopilot_timer > 0.0, "use: autopilot second (FIFO)")
	_ok(g.item_slots() == ["thimble"], "slots after two uses: %s" % str(g.item_slots()))
	await _frames(1)
	_ok(g._hud._item_slots.slots() == ["thimble"], "HUD after uses")
	await _free_game(g)
	_done.append("full")


func _check_edge() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "thimble")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	_ok(g.item_slots().size() == 2, "edge: two thimbles stored")
	_key(KEY_SPACE, true)
	_step(g, 30)
	_ok(g.item_slots().size() == 1, "edge: holding Space 30 ticks uses exactly one")
	for i in 5:
		_key(KEY_SPACE, true, true)
		_step(g, 1)
	_ok(g.item_slots().size() == 1, "edge: key repeat (echo) does not use")
	_key(KEY_SPACE, false)
	_step(g, 1)
	_ok(g.item_slots().size() == 1, "edge: release does not use")
	# 한 틱 안 두 번 누름은 1회로 합친다.
	_tap_space()
	_tap_space()
	_step(g, 1)
	_ok(g.item_slots().is_empty(), "edge: second item used by next press")
	g._hud._item_slots._shake_t = 0.0
	_tap_space()
	_step(g, 1)
	_ok(
		g.item_slots().is_empty() and g._hud._item_slots.is_shaking(),
		"edge: empty use = shake only"
	)
	await _free_game(g)
	_done.append("edge")


## 슬롯 도입 전과 같은 효과 코드: 골무·엄마 찬스 지속 시간과 활성 중 재사용(갱신) 규칙.
func _check_effects() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "autopilot")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	_tap_space()
	_step(g, 1)
	var t0: float = g._player.thimble_timer
	_ok(is_equal_approx(t0, Tuning.thimble_duration - DT), "thimble timer = duration - 1 tick")
	var ticks: int = 1
	while g._player.thimble_timer > 0.0 and ticks < 2000:
		_step(g, 1)
		ticks += 1
	var ref: int = _ref_ticks(Tuning.thimble_duration)
	_ok(ticks == ref, "thimble active ticks %d == reference %d" % [ticks, ref])
	var s_before: float = g._last_s
	_tap_space()
	_step(g, 1)
	var a0: float = g._player.autopilot_timer
	_ok(is_equal_approx(a0, Tuning.autopilot_duration - DT), "autopilot timer = duration - 1 tick")
	var s_want: float = s_before + g._player.speed * DT
	_ok(
		is_equal_approx(g._autopilot_s, s_want), "autopilot starts from last tick s (%.2f)" % s_want
	)
	var ok_on_line: bool = true
	var ap_ticks: int = 1
	while g._player.autopilot_timer > 0.0 and ap_ticks < 2000:
		_step(g, 1)
		ap_ticks += 1
		if g._player.autopilot_timer > 0.0:
			var q: Dictionary = g._track.query(g._player.position, g._hint)
			ok_on_line = ok_on_line and float(q["error"]) < 1.0
	var ap_ref: int = _ref_ticks(Tuning.autopilot_duration)
	var grace: int = int(ceil(Tuning.autopilot_handoff_max_grace * 60.0))
	var ap_ok: bool = ap_ticks >= ap_ref and ap_ticks <= ap_ref + grace
	_ok(ap_ok, "autopilot ticks %d in [%d, %d]" % [ap_ticks, ap_ref, ap_ref + grace])
	_ok(ok_on_line, "autopilot keeps needle on centerline")
	await _free_game(g)
	# 활성 중 재사용: 골무는 전체 지속으로 갱신(연장 아님), 엄마 찬스도 갱신.
	g = await _new_game([_item(60.0, "thimble"), _item(110.0, "thimble")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	_tap_space()
	_step(g, 60)
	_ok(g._player.thimble_timer < Tuning.thimble_duration - 0.9, "thimble ticking down")
	_tap_space()
	_step(g, 1)
	var refreshed: bool = is_equal_approx(g._player.thimble_timer, Tuning.thimble_duration - DT)
	_ok(refreshed, "thimble reuse while active refreshes to full (no stacking)")
	await _free_game(g)
	g = await _new_game([_item(60.0, "autopilot"), _item(110.0, "thimble")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	_tap_space()
	_step(g, 10)
	_tap_space()
	_step(g, 1)
	_ok(
		g._player.autopilot_timer > 0.0 and g._player.thimble_timer > 0.0,
		"thimble during autopilot"
	)
	await _free_game(g)
	_done.append("effects")


## PlayerController 타이머 감소와 같은 부동소수 연산으로 활성 틱 수를 센다(사용 틱 포함).
func _ref_ticks(duration: float) -> int:
	var t: float = duration
	var n: int = 0
	while t > 0.0 and n < 5000:
		t -= DT
		if t < 0.0:
			t = 0.0
		n += 1
	return n


## 부상 대기(손 미끄러짐) 해제는 획득이 아니라 사용 시점에 일어난다.
func _check_pending() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "autopilot")])
	# 대기 중 획득: 해제하지 않는다 → 12틱 뒤 부상.
	g._player.cut_pending_timer = Tuning.cut_windup_duration
	g._player.risk = 1.0
	_visit(g, 0)
	_ok(g._player.is_cut_pending(), "pending: pickup does not cancel pending")
	var cuts0: int = g._stats.cuts
	_step(g, 20)
	_ok(g._stats.cuts == cuts0 + 1, "pending: cut resolves after pickup (no cancel)")
	_ok(g._player.stun_timer > 0.0, "pending: stunned after cut")
	g._player.stun_timer = 0.0
	_visit(g, 1)
	_leave(g)
	_ok(g.item_slots() == ["thimble", "autopilot"], "pending: both stored")
	# 대기 중 사용(골무): 같은 틱에 해제, 부상 없음, risk 는 골무 상한.
	g._player.cut_pending_timer = Tuning.cut_windup_duration
	g._player.risk = 1.0
	_step(g, 3)
	_ok(g._player.is_cut_pending(), "pending: still pending before use")
	_tap_space()
	_step(g, 1)
	_ok(not g._player.is_cut_pending(), "pending: thimble use cancels pending")
	_ok(g._player.risk <= PlayerController.THIMBLE_RISK_CAP + 1e-6, "pending: risk capped 0.95")
	_step(g, 30)
	_ok(g._stats.cuts == cuts0 + 1, "pending: no cut after thimble use")
	# 대기 마지막 틱에 엄마 찬스 사용: 시뮬 전에 처리되어 그 틱 부상을 막는다.
	g._player.thimble_timer = 0.0
	g._player.risk = 1.0
	g._player.cut_pending_timer = DT * 0.5
	_tap_space()
	_step(g, 1)
	_ok(
		not g._player.is_cut_pending() and g._player.autopilot_timer > 0.0,
		"pending: autopilot saves"
	)
	_ok(g._stats.cuts == cuts0 + 1, "pending: last-tick use prevents cut")
	await _free_game(g)
	_done.append("pending")


## 부상 스턴·원단 이탈 복귀 잠금 중 사용은 무시(슬롯 유지).
func _check_locks() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "autopilot")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	g._player.stun_timer = 1.0
	_tap_space()
	_step(g, 1)
	_ok(g.item_slots().size() == 2 and g._player.thimble_timer == 0.0, "stun: use ignored")
	g._player.stun_timer = 0.0
	g._player.offfabric_timer = 1.0
	_tap_space()
	_step(g, 1)
	_ok(g.item_slots().size() == 2 and g._player.thimble_timer == 0.0, "off-fabric lock: ignored")
	g._player.offfabric_timer = 0.0
	_step(g, 1)
	_ok(g.item_slots().size() == 2, "lock: dropped press is not replayed later")
	_tap_space()
	_step(g, 1)
	_ok(g.item_slots().size() == 1 and g._player.thimble_timer > 0.0, "lock released: use works")
	await _free_game(g)
	_done.append("locks")


## 카운트다운·일시정지 중 누름은 버리고, 재개 뒤에 뒤늦게 쓰이지 않는다.
func _check_gates() -> void:
	var g: Node = await _new_game([_item(20.0, "thimble")], false)
	_ok(int(g._state) == 0, "gates: countdown state")
	g._collected[0] = true
	g._slots.append("thimble")
	_tap_space()
	_ok(not g._buf_use_item, "countdown: press not buffered")
	g._countdown_time = 0.0001
	_step(g, 1)
	_step(g, 3)
	_ok(g.item_slots().size() == 1 and g._player.thimble_timer == 0.0, "countdown: nothing used")
	_tap_pause()
	_step(g, 1)
	_ok(get_tree().paused, "gates: paused")
	_tap_space()
	_ok(not g._buf_use_item, "paused: press not buffered")
	_step(g, 3)
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused, "gates: resumed")
	_step(g, 3)
	_ok(g.item_slots().size() == 1 and g._player.thimble_timer == 0.0, "paused press not replayed")
	await _free_game(g)
	_done.append("gates")


## 완주: 남은 슬롯은 효과 없이 사라지고 결과는 그대로. 줌아웃 중 Space 는 스킵일 뿐 사용이 아니다.
func _check_finish() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "autopilot")])
	_visit(g, 0)
	_visit(g, 1)
	_leave(g)
	g._finish()
	_ok(int(g._state) == 2, "finish: FINISH_VIEW")
	_ok(g.item_slots().is_empty(), "finish: leftover slots discarded")
	_ok(g._player.thimble_timer == 0.0 and g._player.autopilot_timer == 0.0, "finish: no effect")
	var res: Dictionary = g._pending_result
	_ok(res.has("final_time_ms") and int(res["cuts"]) == 0, "finish: result unaffected")
	_tap_space()
	_ok(not g._buf_use_item, "finish view: Space not buffered as use")
	g._auto_paused = false
	_ok(not g.request_auto_pause(), "finish view: auto pause not applied")
	_ok(not get_tree().paused, "finish view: tree not paused")
	await _free_game(g)
	_done.append("finish")


## 재시작(reload_current_scene)하면 새 RaceDirector 의 슬롯이 비어 있다.
func _check_restart() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble")])
	_visit(g, 0)
	_ok(g.item_slots().size() == 1, "restart: stored before")
	get_tree().current_scene = g
	g._restart()
	await _frames(3)
	var ng: Node = get_tree().current_scene
	_ok(ng != null and ng != g and ng.has_method("item_slots"), "restart: new gameplay scene")
	if ng != null and ng.has_method("item_slots"):
		_ok(ng.item_slots().is_empty(), "restart: slots reset")
		_ok(ng._hud._item_slots.slots().is_empty(), "restart: HUD slots reset")
		ng.set_physics_process(false)
		get_tree().current_scene = self
		await _free_game(ng)
	else:
		get_tree().current_scene = self
	_done.append("restart")


## 같은 입력 시퀀스(조향·속도·드리프트·사용)를 두 번 돌리면 틱마다 상태가 같다.
func _check_determinism() -> void:
	var probe_g: Node = await _new_game()
	var spots: Array = []
	for t in 360:
		_drive_input(t)
		_step(probe_g, 1)
		if t in [40, 90, 150, 230]:
			spots.append(probe_g._player.position)
	var items: Array = []
	var types: Array[String] = ["thimble", "autopilot", "thimble", "autopilot"]
	for k in spots.size():
		var q: Dictionary = probe_g._track.query(spots[k], probe_g._hint)
		var s: float = float(q["s"])
		var n: Vector2 = probe_g._track.tangent_at_s(s).orthogonal()
		var lat: float = (spots[k] - probe_g._track.point_at_s(s)).dot(n)
		items.append(_item(s, types[k], lat))
	await _free_game(probe_g)
	var a: Array = await _det_run(items)
	var b: Array = await _det_run(items)
	_ok(a.size() == b.size() and a.size() > 0, "determinism: traces recorded (%d)" % a.size())
	var same: bool = a == b
	_ok(same, "determinism: two runs identical tick-by-tick")
	var used_any: bool = false
	for row in a:
		if float(row[5]) > 0.0 or float(row[6]) > 0.0:
			used_any = true
	_ok(used_any, "determinism: sequence actually used an item")
	_done.append("determinism")


func _drive_input(t: int) -> void:
	_release_all()
	if t == 5 or t == 7:
		_action(&"speed_up", true)
		_action(&"speed_up", false)
	var phase: int = int(t / 45.0) % 3
	if phase == 1:
		Input.action_press(&"steer_left")
	elif phase == 2:
		Input.action_press(&"steer_right")
	if t >= 200 and t < 240:
		Input.action_press(&"drift")
	if t in [100, 180, 260, 300]:
		_tap_space()
	Input.flush_buffered_events()


func _det_run(items: Array) -> Array:
	var g: Node = await _new_game(items)
	var trace: Array = []
	for t in 360:
		_drive_input(t)
		_step(g, 1)
		var p: PlayerController = g._player
		trace.append(
			[
				p.position,
				p.heading,
				p.risk,
				p.speed_index,
				str(g.item_slots()),
				p.thimble_timer,
				p.autopilot_timer,
				g._collected.duplicate(),
				g._elapsed
			]
		)
	_release_all()
	await _free_game(g)
	return trace


func _check_stats() -> void:
	var st: RunStats = RunStats.new()
	var res: Dictionary = st.finalize(10.0, 40.0, "cotton_01", "normal")
	var keys: Array = res.keys()
	keys.sort()
	var want: Array = RESULT_KEYS.duplicate()
	want.sort()
	_ok(keys == want, "RunStats result schema unchanged %s" % str(keys))
	_done.append("stats")


# --- 자동 일시정지 ---


func _snapshot(g: Node) -> Array:
	var p: PlayerController = g._player
	return [p.position, p.heading, p.risk, g._elapsed, g._countdown_time, p.speed_index]


func _check_auto_pause() -> void:
	var guard: Node = get_node("/root/OrientationGuard")
	# 주행 중 포커스 상실.
	var g: Node = await _new_game()
	_step(g, 30)
	_action(&"speed_up", true)
	_action(&"speed_up", false)
	_step(g, 1)
	Input.action_press(&"steer_left")
	Input.action_press(&"drift")
	Input.flush_buffered_events()
	_step(g, 20)
	var risk_before: float = g._player.risk
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_ok(get_tree().paused and g.is_auto_paused(), "focus out (running): auto paused")
	_ok(g._hud._pause_overlay.visible, "focus out: pause overlay shown")
	_ok(g._hud.is_auto_pause_notice_visible(), "focus out: auto pause notice shown")
	var released: bool = not Input.is_action_pressed(&"steer_left")
	_ok(released and not Input.is_action_pressed(&"drift"), "focus out: steer/drift released")
	var snap: Array = _snapshot(g)
	_step(g, 60)
	_ok(_snapshot(g) == snap, "focus out: time/position/risk frozen")
	_ok(is_equal_approx(g._player.risk, risk_before), "focus out: risk frozen")
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_step(g, 10)
	_ok(get_tree().paused, "focus in: stays paused (no auto resume)")
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused and not g.is_auto_paused(), "resume via pause action")
	_ok(not g._hud.is_auto_pause_notice_visible(), "resume: notice hidden")
	_ok(not Input.is_action_pressed(&"steer_left"), "resume: no stuck steer")
	var e0: float = g._elapsed
	_step(g, 5)
	_ok(g._elapsed > e0, "resume: time runs again")
	# 창 포커스 상실(WM)도 같다.
	g.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_ok(g.is_auto_paused(), "WM window focus out: auto paused")
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused, "WM: resumed")
	# 세로 전환 → 가로 복귀: 멈춘 채, 세로 동안은 Esc 로도 재개하지 않는다.
	guard._apply_portrait(true)
	_ok(get_tree().paused and g.is_auto_paused(), "portrait: auto paused")
	_tap_pause()
	_step(g, 1)
	_ok(get_tree().paused, "portrait: pause action cannot resume behind overlay")
	guard._apply_portrait(false)
	_step(g, 5)
	_ok(get_tree().paused, "landscape again: still paused")
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused, "landscape: resumed with pause action")
	# 수동 일시정지 중: 자동 정지로 바뀌지 않고, 회전 복구가 수동 정지를 풀지 않는다.
	_tap_pause()
	_step(g, 1)
	_ok(get_tree().paused and not g.is_auto_paused(), "manual pause")
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_ok(not g.is_auto_paused() and not g._hud.is_auto_pause_notice_visible(), "manual kept")
	guard._apply_portrait(true)
	guard._apply_portrait(false)
	_step(g, 5)
	_ok(get_tree().paused and not g.is_auto_paused(), "rotation does not clear manual pause")
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused, "manual resume")
	await _free_game(g)
	# 웹 보강 신호(page_focus_lost)도 포커스 상실과 같다(헤드리스에서는 신호를 직접 보낸다).
	g = await _new_game()
	guard.page_focus_lost.emit()
	_ok(get_tree().paused and g.is_auto_paused(), "web page_focus_lost signal: auto paused")
	_ok(not guard.is_page_hidden(), "is_page_hidden false off web")
	await _free_game(g)
	# 버퍼된 재시작(R)이 다음 틱 전에 포커스를 잃어도 자동 정지를 풀지 않는다(교차 리뷰 1).
	await _check_buffered_meta()
	# 카운트다운 중.
	g = await _new_game([], false)
	_step(g, 30)
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var cd: float = g._countdown_time
	_step(g, 120)
	_ok(get_tree().paused and is_equal_approx(g._countdown_time, cd), "countdown: frozen")
	_ok(int(g._state) == 0, "countdown: still countdown")
	_tap_pause()
	_step(g, 1)
	_ok(not get_tree().paused, "countdown: resumed")
	await _free_game(g)
	# 튜토리얼이 떠 있으면 걸지 않는다(시뮬은 이미 홀드).
	LeaderboardClient.tutorial_seen = false
	g = await _new_game([], false)
	_ok(g._tutorial_open, "tutorial open")
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_ok(not get_tree().paused, "tutorial: no auto pause")
	LeaderboardClient.tutorial_seen = true
	await _free_game(g)
	# 세로로 진입하면 카운트다운 시작 전에 멈춘다.
	guard._apply_portrait(true)
	g = await _new_game([], false)
	_ok(get_tree().paused and g.is_auto_paused(), "enter in portrait: paused at start")
	guard._apply_portrait(false)
	await _free_game(g)
	_ok(not get_tree().paused, "after free: tree unpaused")
	_done.append("auto_pause")


## R 을 눌러 재시작이 버퍼된 뒤 물리 틱 전에 포커스를 잃으면, 자동 정지가 메타 입력 버퍼도 비워
## 다음 틱에 재시작(정지 해제 + 새 씬)이 실행되지 않아야 한다.
func _check_buffered_meta() -> void:
	var g: Node = await _new_game()
	get_tree().current_scene = g
	_action(&"restart", true)
	_action(&"restart", false)
	_ok(g._buf_restart, "buffered restart: R buffered before tick")
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_ok(not g._buf_restart and not g._buf_to_menu, "buffered restart: meta buffers cleared")
	_step(g, 1)
	var kept: bool = g.is_inside_tree() and get_tree().current_scene == g
	if kept:
		_step(g, 2)
		kept = get_tree().current_scene == g and get_tree().paused and g.is_auto_paused()
	_ok(kept, "buffered restart: stays auto paused (no reload)")
	await _frames(3)
	var cur: Node = get_tree().current_scene
	get_tree().current_scene = self
	if cur != null and cur != g and cur != self:
		cur.set_physics_process(false)
		await _free_game(cur)
	if is_instance_valid(g):
		await _free_game(g)


## --no-focus-pause: 포커스 경로만 꺼지고 세로 전환은 그대로 멈춘다.
func _check_nofocus() -> void:
	var guard: Node = get_node("/root/OrientationGuard")
	var g: Node = await _new_game()
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	g.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	guard.page_focus_lost.emit()
	_ok(not get_tree().paused, "no-focus-pause: focus out / page_focus_lost ignored")
	guard._apply_portrait(true)
	_ok(get_tree().paused and g.is_auto_paused(), "no-focus-pause: portrait still pauses")
	guard._apply_portrait(false)
	await _free_game(g)
	_done.append("nofocus")


## 주행 전용 소리 누수(일시정지 후 메뉴·재시작·에디터 복귀·결과 전환). check_audio.gd 참조.
func _check_run_audio() -> void:
	await AudioCheck.new().run(self)
	_done.append("run_audio")


# --- 모드별 HUD ---


func _check_keys_hud() -> void:
	var g: Node = await _new_game()
	var hud: CanvasLayer = g._hud
	_ok(hud._touch == null, "keys: no touch controls")
	var w: ItemSlots = hud._item_slots
	_ok(w._key_hint == "Space", "keys: slot widget shows Space hint")
	var r: Rect2 = w.get_global_rect()
	_ok(r.is_equal_approx(Rect2(146.0, 604.0, 124.0, 80.0)), "keys: slot rect %s" % r)
	var risk: Rect2 = hud.get_node("RiskMeter").get_global_rect()
	_ok(not r.intersects(risk), "keys: slot clear of RISK")
	_ok(r.end.x < 288.0, "keys: slot left of scold portrait (288)")
	var speed: Rect2 = hud.get_node("SpeedPanel").get_global_rect()
	_ok(not r.intersects(speed), "keys: slot clear of speed panel")
	hud._thimble_card.visible = true
	hud._autopilot_card.visible = true
	await _frames(2)
	_ok(not r.intersects(hud._effect_box.get_global_rect()), "keys: slot clear of effect cards")
	await _free_game(g)
	LeaderboardClient.tutorial_seen = false
	g = await _new_game([], false)
	await _frames(3)
	var dlg: TutorialDialog = null
	for c in g._hud.get_children():
		if c is TutorialDialog:
			dlg = c
	_ok(dlg != null and dlg._laid_out, "keys tutorial laid out")
	if dlg != null:
		var found: bool = false
		var slot_r: Rect2 = g._hud._item_slots.get_global_rect()
		var cl: Array = dlg._callouts
		for i in cl.size():
			var box: Rect2 = cl[i]["box"]
			if (cl[i]["hole"] as Rect2).encloses(slot_r):
				found = true
			_ok(Rect2(Vector2.ZERO, dlg.size).encloses(box), "keys tutorial box %d in screen" % i)
			for j in cl.size():
				if j != i:
					var msg: String = "keys tutorial box %d clear of hole %d" % [i, j]
					_ok(not box.intersects(cl[j]["hole"]), msg)
			_ok(not box.intersects(dlg._header_box), "keys tutorial box %d clear of header" % i)
		_ok(found, "keys tutorial: slot callout present")
	LeaderboardClient.tutorial_seen = true
	await _free_game(g)
	_done.append("keys_hud")


func _check_touch() -> void:
	var g: Node = await _new_game([_item(60.0, "thimble"), _item(110.0, "autopilot")])
	var hud: CanvasLayer = g._hud
	var tc: TouchControls = hud._touch
	_ok(tc != null, "touch: controls built")
	if tc == null:
		await _free_game(g)
		return
	var r: Rect2 = tc.button_rect(B.USE_ITEM)
	_ok(r.is_equal_approx(USE_RECT), "touch: USE rect %s" % r)
	_ok(hud._item_slots._key_hint == "", "touch: no key hint on slot widget")
	var sr: Rect2 = hud._item_slots.get_global_rect()
	_ok(sr.is_equal_approx(Rect2(146.0, 468.0, 124.0, 80.0)), "touch: slot rect %s" % sr)
	var steer: Rect2 = tc.button_rect(B.STEER_LEFT).merge(tc.button_rect(B.STEER_RIGHT))
	_ok(not sr.intersects(steer.grow(TouchControls.HIT_PAD)), "touch: slot clear of steer hit")
	_ok(not sr.intersects(hud.get_node("RiskMeter").get_global_rect()), "touch: slot clear of RISK")
	_ok(tc.use_icon() == null, "touch: USE disabled when empty")
	_visit(g, 0)
	_ok(tc.use_icon() == HUD.ICON_THIMBLE, "touch: USE shows next item (thimble)")
	_visit(g, 1)
	_leave(g)
	_ok(tc.use_icon() == HUD.ICON_THIMBLE, "touch: USE still shows first-in")
	_touch(5, r.get_center(), true)
	_ok(Input.is_action_pressed(&"use_item"), "touch: USE tap presses use_item")
	_step(g, 1)
	_touch(5, r.get_center(), false)
	_step(g, 5)
	_ok(g.item_slots() == ["autopilot"] and g._player.thimble_timer > 0.0, "touch: one item used")
	_ok(tc.use_icon() == HUD.ICON_AUTOPILOT, "touch: USE shows autopilot next")
	# DRIFT 를 누른 채 위로 미끄러져도 USE 는 눌리지 않는다(탭형).
	var drift: Vector2 = tc.button_rect(B.DRIFT).get_center()
	_touch(6, drift, true)
	_drag(6, r.get_center())
	_ok(not Input.is_action_pressed(&"use_item"), "touch: slide DRIFT->USE does not press")
	_touch(6, r.get_center(), false)
	_step(g, 2)
	_ok(g.item_slots() == ["autopilot"], "touch: slide did not use")
	# 자동 일시정지: 버튼 숨김·눌림 해제.
	_touch(7, tc.button_rect(B.STEER_LEFT).get_center(), true)
	_ok(Input.is_action_pressed(&"steer_left"), "touch: steer held")
	g.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	tc.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	Input.flush_buffered_events()
	_ok(get_tree().paused and not tc.visible, "touch focus out: paused, buttons hidden")
	_ok(not Input.is_action_pressed(&"steer_left"), "touch focus out: steer released")
	_touch(7, tc.button_rect(B.STEER_LEFT).get_center(), false)
	_ok(hud.is_auto_pause_notice_visible(), "touch: auto pause notice")
	_tap_pause()
	_step(g, 1)
	await _frames(1)
	_ok(not get_tree().paused and tc.visible, "touch: resumed, buttons back")
	await _free_game(g)
	_done.append("touch")


func _touch(idx: int, pos: Vector2, pressed: bool) -> void:
	var ev: InputEventScreenTouch = InputEventScreenTouch.new()
	ev.index = idx
	ev.position = pos
	ev.pressed = pressed
	get_viewport().push_input(ev, true)
	Input.flush_buffered_events()


func _drag(idx: int, pos: Vector2) -> void:
	var ev: InputEventScreenDrag = InputEventScreenDrag.new()
	ev.index = idx
	ev.position = pos
	get_viewport().push_input(ev, true)
	Input.flush_buffered_events()
