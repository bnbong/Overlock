extends Node
## 모바일 조향 버튼 확대(STEER_SIZE 144, v2.2.1) + 아이템 USE 버튼 입력·배치 회귀 검사(사본 프로젝트
## 전용, run.sh 가 실행).
## InputEventScreenTouch/ScreenDrag 를 뷰포트에 직접 넣고 Input.is_action_pressed 로 액션 상태를
## 확인한다(데스크톱 헤드리스 모사이며 실제 기기 터치 검증이 아니다). run.sh 는 `-- --touch-controls`
## 를 붙여 실행하므로 Gameplay 의 HUD 도 터치 버튼을 만든다.
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const ToastScene: PackedScene = preload("res://scenes/Toast.tscn")
const MOM_PORTRAIT_PATH: String = "res://assets/gfx/ui/mom_scolding.png"
const HURT_PORTRAIT_PATH: String = "res://assets/gfx/ui/player_hurt_teary.png"

const B := TouchControls.Btn
const EXPECTED: Dictionary = {
	B.STEER_LEFT: Rect2(16.0, 560.0, 144.0, 144.0),
	B.STEER_RIGHT: Rect2(176.0, 560.0, 144.0, 144.0),
	B.SPEED_UP: Rect2(1152.0, 464.0, 112.0, 112.0),
	B.SPEED_DOWN: Rect2(1152.0, 592.0, 112.0, 112.0),
	B.DRIFT: Rect2(1004.0, 572.0, 132.0, 132.0),
	B.PAUSE: Rect2(946.0, 10.0, 80.0, 80.0),
	B.USE_ITEM: Rect2(1014.0, 436.0, 112.0, 112.0),
}
const ALL_ACTIONS: Array[StringName] = [
	&"steer_left", &"steer_right", &"speed_up", &"speed_down", &"drift", &"pause", &"use_item"
]
# 끝까지 실행돼야 하는 검사 구획(스크립트 오류로 중간에 끊기면 마지막 대조에서 실패).
const SECTIONS: Array[String] = [
	"constants",
	"rects",
	"tap",
	"slide",
	"outside",
	"multi",
	"tap_rules",
	"use_item",
	"hit_pad",
	"blocked",
	"focus",
	"hidden",
	"hud_layout",
	"pause",
	"toast",
	"tutorial",
]
const MIN_PASSED: int = 90

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _tc: TouchControls


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	LeaderboardClient.tutorial_seen = true
	await get_tree().process_frame
	_ok(TouchControls.is_forced(), "run with --touch-controls user arg")
	_check_constants()
	_tc = TouchControls.new()
	add_child(_tc)
	await get_tree().process_frame
	_check_rects()
	_check_tap()
	_check_slide()
	_check_outside()
	_check_multi()
	_check_tap_rules()
	_check_use_item()
	_check_hit_pad()
	_check_blocked()
	_check_focus()
	_check_hidden()
	_tc.queue_free()
	await get_tree().process_frame
	_release_keys()
	await _check_hud_layout_and_pause()
	await _check_toast()
	await _check_tutorial()
	for s in SECTIONS:
		_ok(s in _done, "section completed: " + s)
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("mobile steer regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


# --- 입력 주입 헬퍼 ---


## 헤드리스 창 크기가 0이라 뷰포트 최종 변환이 퇴화하므로 in_local_coords=true 로 캔버스 좌표를 그대로
## 넣는다(TouchControls._to_local_pos 가 받는 좌표와 같다).
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


func _p(action: StringName) -> bool:
	return Input.is_action_pressed(action)


func _none_pressed() -> bool:
	for a in ALL_ACTIONS:
		if Input.is_action_pressed(a):
			return false
	return true


func _release_keys() -> void:
	for a in ALL_ACTIONS:
		Input.action_release(a)
	Input.flush_buffered_events()


func _c(b: int) -> Vector2:
	return _tc.button_rect(b).get_center()


# --- 검사 ---


func _check_constants() -> void:
	_ok(TouchControls.STEER_SIZE == 144.0, "STEER_SIZE 144")
	_ok(TouchControls.USE_ITEM_SIZE == 112.0, "USE_ITEM_SIZE 112")
	_ok(TouchControls.USE_ITEM_GAP == 24.0, "USE_ITEM_GAP 24")
	_ok(TouchControls.SPEED_SIZE == 112.0, "SPEED_SIZE unchanged 112")
	_ok(TouchControls.DRIFT_SIZE == 132.0, "DRIFT_SIZE unchanged 132")
	_ok(TouchControls.PAUSE_SIZE == 80.0, "PAUSE_SIZE unchanged 80")
	_ok(TouchControls.EDGE_MARGIN == 16.0, "EDGE_MARGIN unchanged 16")
	_ok(TouchControls.BUTTON_GAP == 16.0, "BUTTON_GAP unchanged 16")
	_ok(TouchControls.HIT_PAD == 8.0, "HIT_PAD unchanged 8")
	_ok(TouchControls.HUD_GAP == 12.0, "HUD_GAP unchanged 12")
	_done.append("constants")


func _check_rects() -> void:
	_ok(_tc.size == Vector2(1280.0, 720.0), "touch controls canvas %s" % str(_tc.size))
	for b in EXPECTED.keys():
		var r: Rect2 = _tc.button_rect(b)
		_ok(r.is_equal_approx(EXPECTED[b]), "button_rect %d = %s (expected %s)" % [b, r, EXPECTED[b]])
	# 판정 사각형끼리 겹치지 않는다(has_point 는 오른쪽·아래 변 제외 → 공유 변은 한쪽만 인정).
	var keys: Array = EXPECTED.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Rect2 = _tc.button_rect(keys[i]).grow(TouchControls.HIT_PAD)
			var c: Rect2 = _tc.button_rect(keys[j]).grow(TouchControls.HIT_PAD)
			_ok(not a.intersects(c), "hit rects %d/%d do not overlap" % [keys[i], keys[j]])
	_done.append("rects")


func _check_tap() -> void:
	_touch(0, _c(B.STEER_LEFT), true)
	_ok(_p(&"steer_left") and not _p(&"steer_right"), "tap left: steer_left pressed")
	_ok(_tc.is_button_pressed(B.STEER_LEFT), "tap left: button drawn pressed")
	_touch(0, _c(B.STEER_LEFT), false)
	_ok(_none_pressed(), "tap left: released")
	_touch(0, _c(B.STEER_RIGHT), true)
	_ok(_p(&"steer_right") and not _p(&"steer_left"), "tap right: steer_right pressed")
	_touch(0, _c(B.STEER_RIGHT), false)
	_ok(_none_pressed(), "tap right: released")
	# 새로 커진 영역의 모서리(이전 128 크기 바깥) 탭도 인정한다.
	_touch(0, Vector2(156.0, 564.0), true)
	_ok(_p(&"steer_left"), "tap left enlarged corner (156,564)")
	_touch(0, Vector2(156.0, 564.0), false)
	_touch(0, Vector2(316.0, 700.0), true)
	_ok(_p(&"steer_right"), "tap right enlarged corner (316,700)")
	_touch(0, Vector2(316.0, 700.0), false)
	_ok(_none_pressed(), "corner taps released")
	_done.append("tap")


func _check_slide() -> void:
	_touch(0, _c(B.STEER_LEFT), true)
	_drag(0, Vector2(100.0, 640.0))
	_ok(_p(&"steer_left"), "slide: still left inside left")
	# 두 버튼 사이 간격(160..176)의 한가운데(168)는 오른쪽 판정 시작점 → 빈틈 없이 전환.
	_drag(0, Vector2(167.9, 640.0))
	_ok(_p(&"steer_left") and not _p(&"steer_right"), "slide: 167.9 still left (pad)")
	_drag(0, Vector2(168.0, 640.0))
	_ok(_p(&"steer_right") and not _p(&"steer_left"), "slide: 168 switches to right")
	_drag(0, _c(B.STEER_RIGHT))
	_ok(_p(&"steer_right") and not _p(&"steer_left"), "slide: right center")
	_drag(0, _c(B.STEER_LEFT))
	_ok(_p(&"steer_left") and not _p(&"steer_right"), "slide back: right -> left")
	_touch(0, _c(B.STEER_LEFT), false)
	_ok(_none_pressed(), "slide: released on lift")
	_done.append("slide")


func _check_outside() -> void:
	_touch(0, _c(B.STEER_RIGHT), true)
	_drag(0, Vector2(640.0, 360.0))
	_ok(_none_pressed(), "drag outside: steer released")
	_ok(int(_tc._touch_btn.get(0, 99)) == -1, "drag outside: finger still tracked as none")
	_drag(0, Vector2(220.0, 520.0))
	_ok(_none_pressed(), "drag above right (y 520, outside pad): none")
	_drag(0, _c(B.STEER_RIGHT))
	_ok(_p(&"steer_right"), "drag back in: steer_right pressed again (passby)")
	_drag(0, _c(B.SPEED_UP))
	_ok(not _p(&"speed_up") and not _p(&"steer_right"), "slide into speed button: ignored")
	_drag(0, _c(B.DRIFT))
	_ok(_p(&"drift"), "slide into DRIFT: hold passby")
	_touch(0, _c(B.DRIFT), false)
	_ok(_none_pressed(), "outside: released on lift")
	_done.append("outside")


func _check_multi() -> void:
	_touch(0, _c(B.STEER_LEFT), true)
	_touch(1, _c(B.DRIFT), true)
	_ok(_p(&"steer_left") and _p(&"drift"), "two fingers: steer_left + drift")
	_touch(2, _c(B.SPEED_UP), true)
	_ok(_p(&"speed_up"), "third finger: speed_up while steering+drift")
	_touch(2, _c(B.SPEED_UP), false)
	_ok(not _p(&"speed_up") and _p(&"steer_left") and _p(&"drift"), "speed tap released only")
	_drag(0, _c(B.STEER_RIGHT))
	_ok(_p(&"steer_right") and not _p(&"steer_left") and _p(&"drift"), "slide steer while drift held")
	_touch(3, _c(B.SPEED_DOWN), true)
	_ok(_p(&"speed_down") and _p(&"steer_right") and _p(&"drift"), "speed_down with steer+drift")
	_touch(3, _c(B.SPEED_DOWN), false)
	_touch(1, _c(B.DRIFT), false)
	_ok(not _p(&"drift") and _p(&"steer_right"), "drift lift keeps steer")
	# 같은 버튼을 두 손가락이 누르면 마지막 손가락이 뗄 때만 해제.
	_touch(4, Vector2(190.0, 590.0), true)
	_ok(_tc._press_count[B.STEER_RIGHT] == 2, "same button two fingers: count 2")
	_touch(0, _c(B.STEER_RIGHT), false)
	_ok(_p(&"steer_right"), "same button: first lift keeps pressed")
	_touch(4, Vector2(190.0, 590.0), false)
	_ok(_none_pressed(), "multi: all released")
	_done.append("multi")


func _check_tap_rules() -> void:
	# 속도 버튼에서 시작해 밖으로 나가도 뗄 때까지 유지(뗌 1회).
	_touch(0, _c(B.SPEED_UP), true)
	_drag(0, Vector2(640.0, 360.0))
	_ok(_p(&"speed_up"), "tap button: stays pressed when dragged out")
	_drag(0, _c(B.STEER_LEFT))
	_ok(_p(&"speed_up") and not _p(&"steer_left"), "tap finger dragged to steer: no steer")
	_touch(0, _c(B.STEER_LEFT), false)
	_ok(_none_pressed(), "tap rules: released")
	# 버튼 밖에서 시작한 터치는 추적하지 않는다.
	_touch(0, Vector2(640.0, 360.0), true)
	_drag(0, _c(B.STEER_LEFT))
	_ok(_none_pressed(), "touch started outside then slid in: ignored")
	_touch(0, _c(B.STEER_LEFT), false)
	_done.append("tap_rules")


## USE(아이템 사용)는 탭형: 시작한 버튼에서만 눌리고, 홀드 버튼에서 미끄러져 들어와도 눌리지 않는다.
func _check_use_item() -> void:
	_touch(0, _c(B.USE_ITEM), true)
	_ok(_p(&"use_item"), "USE tap: use_item pressed")
	_drag(0, Vector2(640.0, 360.0))
	_ok(_p(&"use_item"), "USE: stays pressed when dragged out (tap rule)")
	_touch(0, Vector2(640.0, 360.0), false)
	_ok(_none_pressed(), "USE: released on lift")
	_touch(1, _c(B.DRIFT), true)
	_drag(1, _c(B.USE_ITEM))
	_ok(not _p(&"use_item") and not _p(&"drift"), "slide DRIFT -> USE: no use, drift released")
	_touch(1, _c(B.USE_ITEM), false)
	var use: Rect2 = _tc.button_rect(B.USE_ITEM)
	var drift: Rect2 = _tc.button_rect(B.DRIFT)
	var gap: float = drift.position.y - use.end.y - TouchControls.HIT_PAD * 2.0
	_ok(is_equal_approx(gap, 8.0), "USE/DRIFT hit areas 8px apart (%.1f)" % gap)
	_touch(2, Vector2(use.get_center().x, use.end.y + TouchControls.HIT_PAD + 1.0), true)
	_ok(not _p(&"use_item") and not _p(&"drift"), "touch in USE/DRIFT gap: nothing")
	_touch(2, Vector2(use.get_center().x, use.end.y + TouchControls.HIT_PAD + 1.0), false)
	_tc.set_use_icon(null)
	_ok(_tc.use_icon() == null, "USE icon cleared (disabled look)")
	_ok(_none_pressed(), "use_item: nothing left pressed")
	_done.append("use_item")


func _hit_at(pos: Vector2) -> Array:
	_touch(7, pos, true)
	var res: Array = [_p(&"steer_left"), _p(&"steer_right")]
	_touch(7, pos, false)
	return res


func _check_hit_pad() -> void:
	var pad: float = TouchControls.HIT_PAD
	var l: Rect2 = _tc.button_rect(B.STEER_LEFT)
	var r: Rect2 = _tc.button_rect(B.STEER_RIGHT)
	var my: float = l.get_center().y
	_ok(_hit_at(Vector2(l.position.x - pad, my))[0], "left pad edge x=8 hits")
	_ok(not _hit_at(Vector2(l.position.x - pad - 0.5, my))[0], "left pad outside x=7.5 misses")
	_ok(_hit_at(Vector2(l.get_center().x, l.position.y - pad))[0], "left pad top y=552 hits")
	_ok(not _hit_at(Vector2(l.get_center().x, l.position.y - pad - 0.5))[0], "top y=551.5 misses")
	_ok(_hit_at(Vector2(l.get_center().x, l.end.y + pad - 0.5))[0], "left pad bottom y=711.5 hits")
	_ok(_hit_at(Vector2(r.end.x + pad - 0.5, my))[1], "right pad edge x=327.5 hits")
	_ok(not _hit_at(Vector2(r.end.x + pad, my))[1], "right pad outside x=328 misses")
	_ok(_hit_at(Vector2(r.get_center().x, r.position.y - pad))[1], "right pad top y=552 hits")
	_ok(not _hit_at(Vector2(r.get_center().x, r.position.y - pad - 0.5))[1], "right top 551.5 misses")
	_ok(_none_pressed(), "hit pad: nothing left pressed")
	_done.append("hit_pad")


func _check_blocked() -> void:
	_touch(0, _c(B.STEER_LEFT), true)
	_touch(1, _c(B.DRIFT), true)
	_tc.set_blocked(true)
	Input.flush_buffered_events()
	_ok(_none_pressed(), "set_blocked(true): all released")
	_ok(not _tc.visible, "set_blocked(true): hidden")
	_touch(2, _c(B.STEER_RIGHT), true)
	_ok(_none_pressed(), "blocked: new touch ignored")
	_touch(2, _c(B.STEER_RIGHT), false)
	_touch(0, _c(B.STEER_LEFT), false)
	_tc.set_blocked(false)
	_ok(_tc.visible and not _tc.is_blocked(), "unblocked: visible")
	_drag(1, _c(B.STEER_LEFT))
	_ok(_none_pressed(), "stale finger drag after unblock: ignored")
	_touch(1, _c(B.DRIFT), false)
	# 튜토리얼 코치마크: 보이게 둔 채 입력만 막는다.
	_touch(0, _c(B.STEER_RIGHT), true)
	_tc.set_blocked(true, false)
	Input.flush_buffered_events()
	_ok(_none_pressed() and _tc.visible, "set_blocked(true,false): released, still visible")
	_touch(3, _c(B.STEER_LEFT), true)
	_ok(_none_pressed(), "blocked visible: touch ignored")
	_touch(3, _c(B.STEER_LEFT), false)
	_touch(0, _c(B.STEER_RIGHT), false)
	_tc.set_blocked(false)
	_ok(_none_pressed(), "blocked: nothing pressed")
	_done.append("blocked")


func _check_focus() -> void:
	for what in [
		Node.NOTIFICATION_APPLICATION_FOCUS_OUT, Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT
	]:
		_touch(0, _c(B.STEER_LEFT), true)
		_touch(1, _c(B.DRIFT), true)
		_ok(_p(&"steer_left") and _p(&"drift"), "focus %d: held before" % what)
		_tc.notification(what)
		Input.flush_buffered_events()
		_ok(_none_pressed(), "focus out %d: all released" % what)
		_touch(0, _c(B.STEER_LEFT), false)
		_touch(1, _c(B.DRIFT), false)
		_ok(_none_pressed(), "focus out %d: late lift keeps released" % what)
	_done.append("focus")


func _check_hidden() -> void:
	_touch(0, _c(B.STEER_RIGHT), true)
	_tc.visible = false
	Input.flush_buffered_events()
	_ok(_none_pressed(), "hide: released")
	_touch(1, _c(B.STEER_LEFT), true)
	_ok(_none_pressed(), "hidden: touch ignored")
	_touch(1, _c(B.STEER_LEFT), false)
	_touch(0, _c(B.STEER_RIGHT), false)
	_tc.visible = true
	_touch(0, _c(B.STEER_RIGHT), true)
	_tc.release_all()
	Input.flush_buffered_events()
	_ok(_none_pressed(), "release_all: released")
	_touch(0, _c(B.STEER_RIGHT), false)
	_ok(_none_pressed(), "hidden: nothing pressed")
	_done.append("hidden")


static func _rect_of(c: Control) -> Rect2:
	return c.get_global_rect()


func _check_hud_layout_and_pause() -> void:
	LeaderboardClient.tutorial_seen = true
	var g: Node = GameplayScene.instantiate()
	get_tree().root.add_child(g)
	await get_tree().process_frame
	await get_tree().process_frame
	var hud: CanvasLayer = g.get_node("HUD")
	var tc: TouchControls = hud.get_node_or_null("TouchControls") as TouchControls
	_ok(tc != null, "HUD built TouchControls")
	if tc == null:
		g.queue_free()
		return
	_tc = tc
	var sl: Rect2 = tc.button_rect(B.STEER_LEFT)
	var sr: Rect2 = tc.button_rect(B.STEER_RIGHT)
	_ok(sl.is_equal_approx(EXPECTED[B.STEER_LEFT]), "HUD steer left %s" % sl)
	_ok(sr.is_equal_approx(EXPECTED[B.STEER_RIGHT]), "HUD steer right %s" % sr)
	var risk: Rect2 = _rect_of(hud.get_node("RiskMeter"))
	_ok(risk.is_equal_approx(Rect2(16.0, 398.0, 120.0, 150.0)), "RiskMeter %s" % risk)
	_ok(is_equal_approx(risk.end.y + TouchControls.HUD_GAP, sl.position.y), "RISK 12px above steer")
	var eff: Control = hud._effect_box
	_ok(is_equal_approx(eff.offset_bottom, -332.0), "effect box bottom 388 (%.1f)" % eff.offset_bottom)
	# 두 카드를 모두 띄웠을 때의 스택 범위.
	hud._thimble_card.visible = true
	hud._autopilot_card.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	var er: Rect2 = _rect_of(eff)
	print("INFO effect box (both cards) ", er)
	var prog: Rect2 = _rect_of(hud.get_node("ProgressBar"))
	var mini: Rect2 = _rect_of(hud.get_node("MiniMap"))
	var er_msg: String = "effect cards top %.1f below progress %.1f" % [er.position.y, prog.end.y]
	_ok(er.position.y >= prog.end.y, er_msg)
	_ok(not er.intersects(mini) and not er.intersects(risk), "effect cards clear of minimap/risk")
	_ok(not risk.intersects(sl.grow(TouchControls.HIT_PAD)), "RISK clear of steer hit rect")
	_ok(not mini.intersects(sl) and not prog.intersects(sl), "minimap/progress clear of steer")
	var speed: Rect2 = _rect_of(hud.get_node("SpeedPanel"))
	_ok(speed.is_equal_approx(Rect2(1152.0, 214.0, 112.0, 238.0)), "SpeedPanel unchanged %s" % speed)
	# 아이템 슬롯 위젯(RISK 오른쪽)과 USE 버튼.
	var slots: Rect2 = _rect_of(hud.get_node("ItemSlots"))
	_ok(slots.is_equal_approx(Rect2(146.0, 468.0, 124.0, 80.0)), "ItemSlots %s" % slots)
	_ok(not slots.intersects(risk) and not slots.intersects(er), "ItemSlots clear of RISK/effects")
	var steer_hit: Rect2 = sl.merge(sr).grow(TouchControls.HIT_PAD)
	_ok(not slots.intersects(steer_hit), "ItemSlots clear of steer hit rects")
	var use: Rect2 = tc.button_rect(B.USE_ITEM)
	_ok(use.is_equal_approx(EXPECTED[B.USE_ITEM]), "HUD USE %s" % use)
	_ok(not use.grow(TouchControls.HIT_PAD).intersects(speed), "USE hit clear of SpeedPanel")
	var status: Label = hud.get_node("StatusLabel")
	print("INFO StatusLabel rect ", _rect_of(status))
	hud._thimble_card.visible = false
	hud._autopilot_card.visible = false
	# 일시정지: 조향을 누른 채 ‖ 탭 → 실제 RaceDirector 경로로 일시정지 → 버튼 숨김·해제.
	_touch(0, tc.button_rect(B.STEER_LEFT).get_center(), true)
	_touch(1, tc.button_rect(B.DRIFT).get_center(), true)
	_ok(_p(&"steer_left") and _p(&"drift"), "gameplay: steer+drift held")
	_touch(2, tc.button_rect(B.PAUSE).get_center(), true)
	_touch(2, tc.button_rect(B.PAUSE).get_center(), false)
	for i in 4:
		await get_tree().physics_frame
	_ok(get_tree().paused, "pause button paused the tree")
	_ok(not tc.visible and tc.is_blocked(), "paused: touch controls hidden+blocked")
	_ok(not _p(&"steer_left") and not _p(&"drift"), "paused: steer/drift released")
	_touch(0, sl.get_center(), false)
	_touch(1, tc.button_rect(B.DRIFT).get_center(), false)
	_touch(3, sl.get_center(), true)
	_ok(not _p(&"steer_left"), "paused: touch on steer ignored")
	_touch(3, sl.get_center(), false)
	# 일시정지 오버레이의 "계속" 버튼과 같은 경로(pause 액션 눌림/뗌)로 재개한다.
	var resume: InputEventAction = InputEventAction.new()
	resume.action = &"pause"
	resume.pressed = true
	Input.parse_input_event(resume)
	Input.flush_buffered_events()
	resume = InputEventAction.new()
	resume.action = &"pause"
	resume.pressed = false
	Input.parse_input_event(resume)
	Input.flush_buffered_events()
	for i in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	_ok(not get_tree().paused and tc.visible and not tc.is_blocked(), "resumed: controls back")
	_touch(0, sl.get_center(), true)
	_ok(_p(&"steer_left"), "resumed: steer works again")
	_touch(0, sl.get_center(), false)
	_done.append("hud_layout")
	_done.append("pause")
	g.queue_free()
	await get_tree().process_frame
	get_tree().paused = false
	_ok(_none_pressed(), "gameplay freed: nothing pressed")


func _check_toast() -> void:
	var t: Toast = ToastScene.instantiate()
	get_tree().root.add_child(t)
	await get_tree().process_frame
	var steer: Rect2 = EXPECTED[B.STEER_LEFT].merge(EXPECTED[B.STEER_RIGHT])
	for path in [MOM_PORTRAIT_PATH, HURT_PORTRAIT_PATH]:
		# 엄마 꾸중은 실제 가장 긴 대사로 넣어 줄어든 폭 안에 들어가는지 본다.
		var line: String = "이녀석, 제대로 해야지!" if path == MOM_PORTRAIT_PATH else "아얏!"
		t.push_immediate(line, load(path))
		for i in 3:
			await get_tree().process_frame
		var panel: Rect2 = Rect2(t._panel.position, t._panel.size)
		var portrait: Rect2 = Rect2(t._portrait.position, t._portrait.size)
		print("INFO toast %s panel %s portrait %s" % [path.get_file(), panel, portrait])
		_ok(not panel.intersects(steer), "%s: bubble clear of steer buttons" % path.get_file())
		_ok(not portrait.intersects(steer), "%s: portrait rect clear of steer" % path.get_file())
		# 터치 모드 말풍선: 폭을 줄여 DRIFT·USE 와도 겹치지 않고, 대사가 줄어든 폭 안에 들어간다.
		var right_btns: Rect2 = EXPECTED[B.DRIFT].merge(EXPECTED[B.USE_ITEM])
		_ok(not panel.intersects(right_btns), "%s: bubble clear of DRIFT/USE" % path.get_file())
		_ok(is_equal_approx(panel.position.x, 344.0), "%s: bubble left 344" % path.get_file())
		var wmsg: String = "%s: bubble width 648 (%.1f)" % [path.get_file(), panel.size.x]
		_ok(is_equal_approx(panel.size.x, 648.0), wmsg)
		_ok(is_equal_approx(portrait.position.x, 332.0), "%s: portrait left 332" % path.get_file())
		_ok(is_equal_approx(panel.size.y, 82.0), "%s: bubble height kept 82" % path.get_file())
		# 초상화 불투명 영역(알파>0.05)의 실제 왼쪽 끝과 조향 버튼 오른쪽 끝의 간격.
		var img: Image = (load(path) as Texture2D).get_image()
		var min_x: int = img.get_width()
		for y in range(0, img.get_height(), 4):
			for x in range(0, mini(min_x, img.get_width()), 2):
				if img.get_pixel(x, y).a > 0.05:
					min_x = x
					break
		var opaque_left: float = portrait.position.x + portrait.size.x * min_x / img.get_width()
		var info: Array = [path.get_file(), opaque_left, steer.end.x]
		print("INFO %s opaque left %.1f, steer right edge %.1f" % info)
		_ok(opaque_left > steer.end.x, "%s: visible portrait right of steer" % path.get_file())
	t.queue_free()
	await get_tree().process_frame
	_done.append("toast")


func _check_tutorial() -> void:
	LeaderboardClient.tutorial_seen = false
	var g: Node = GameplayScene.instantiate()
	get_tree().root.add_child(g)
	for i in 4:
		await get_tree().process_frame
	var hud: CanvasLayer = g.get_node("HUD")
	var dlg: TutorialDialog = null
	for c in hud.get_children():
		if c is TutorialDialog:
			dlg = c
	_ok(dlg != null, "tutorial opened")
	var tc: TouchControls = hud.get_node_or_null("TouchControls") as TouchControls
	if dlg == null or tc == null:
		g.queue_free()
		return
	_ok(dlg._laid_out, "tutorial laid out")
	_ok(tc.visible and tc.is_blocked(), "tutorial: buttons visible but blocked")
	_touch(0, tc.button_rect(B.STEER_LEFT).get_center(), true)
	_ok(not _p(&"steer_left"), "tutorial: steer touch ignored")
	_touch(0, tc.button_rect(B.STEER_LEFT).get_center(), false)
	var steer: Rect2 = tc.button_rect(B.STEER_LEFT).merge(tc.button_rect(B.STEER_RIGHT))
	var screen: Rect2 = Rect2(Vector2.ZERO, dlg.size)
	var found_steer: bool = false
	var callouts: Array = dlg._callouts
	for i in callouts.size():
		var co: Dictionary = callouts[i]
		var box: Rect2 = co["box"]
		var hole: Rect2 = co["hole"]
		print("INFO callout %d hole %s box %s" % [i, hole, box])
		if hole.encloses(steer):
			found_steer = true
		_ok(screen.encloses(box), "callout %d box inside screen" % i)
		for j in callouts.size():
			if j == i:
				continue
			_ok(not box.intersects(callouts[j]["hole"]), "callout %d box clear of hole %d" % [i, j])
			if j > i:
				_ok(not box.intersects(callouts[j]["box"]), "callout %d box clear of box %d" % [i, j])
		_ok(not box.intersects(dlg._header_box), "callout %d box clear of header" % i)
	_ok(found_steer, "tutorial steer callout hole encloses enlarged steer rects")
	g.queue_free()
	await get_tree().process_frame
	LeaderboardClient.tutorial_seen = true
	_done.append("tutorial")
