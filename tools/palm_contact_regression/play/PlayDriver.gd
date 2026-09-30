extends Node
## Overlock 실제 입력 플레이 드라이버(검증 사본 전용 autoload, 저장소 game/에는 넣지 않는다).
##
## 원칙: 게임 상태는 읽기만 한다. 조작은 전부 Input.parse_input_event()로 InputEventKey
## (InputSetup이 바인딩한 physical keycode)·InputEventMouseButton·InputEventScreenTouch를 주입해
## 엔진 입력 파이프라인(_input → GUI → _unhandled_input, Input.is_action_pressed)을 통과시킨다.
## _steer/_phase/_state/위치 등 게임 변수 대입, Input.action_press()는 쓰지 않는다.
##
## 인자(-- 뒤): --out=<dir> --scenario=full|mobile|scold [--touch-controls]
## --fixed-fps 60 으로 실행하면 1 프레임 = 1 물리 틱이라 같은 입력 스크립트가 같은 결과를 낸다.

const K_LEFT: int = KEY_LEFT
const K_RIGHT: int = KEY_RIGHT
const K_UP: int = KEY_W
const K_DOWN: int = KEY_S
const K_DRIFT: int = KEY_SHIFT
const K_PAUSE: int = KEY_ESCAPE
const K_RESTART: int = KEY_R

const R: GDScript = preload("res://play_driver/PlayRead.gd")
const TARGET_TRACK: String = "tee_01"
const FACE_CUT_TEX: String = "res://assets/gfx/face_base_clean.png"
const CAP_MAX_WAIT: int = 20  # 캡처가 그리기를 기다리는 최대 프레임
const BONK_RELEASE_DEG: float = 40.0  # 꿀밤 유도: 트랙 접선 대비 이 각도에서 조향 키를 뗀다

var out_dir: String = ""
var scenario: String = "full"
var touch_mode: bool = false

var frame: int = 0
var auto_steer: bool = false
var steer_via_touch: bool = false
var pause_mom_run: int = 2  # 이 회차의 엄마 찬스 전환 도중 일시정지를 1회 넣는다
var manual_override: bool = false  # true면 컨트롤러가 조향 키를 건드리지 않는다
var _held: Dictionary = {}  # key/touch-id -> bool
var _touch_steer_dir: int = 0  # 터치 조향 손가락이 누른 방향(0=뗌)
var _auto_caps: Dictionary = {}  # 자연 발생 이벤트 캡처 카운터
var _log: FileAccess = null
var _events: FileAccess = null
var _seq_prefix: String = ""
var _seq_every: int = 0
var _seq_until: int = -1
var _seq_idx: int = 0
var _cut_pts: PackedVector2Array = PackedVector2Array()
var _face_min_y: float = INF
var _face_min_frame: int = -1
var _run_index: int = 0
var _prev: Dictionary = {}
var _draw_count: int = 0  # frame_post_draw 누적 횟수(그리기 정지 감지)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000
	process_priority = 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--scenario="):
			scenario = a.substr(11)
		elif a == "--touch-controls":
			touch_mode = true
	if out_dir.is_empty():
		push_warning("PlayDriver: --out 없음, 비활성")
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	DirAccess.make_dir_recursive_absolute(out_dir + "/seq")
	_log = FileAccess.open(out_dir + "/frames.csv", FileAccess.WRITE)
	(
		_log
		. store_line(
			(
				"frame,scene,run,state,s,speed_idx,target_steer,actual_steer,drifting,risk,stun,"
				+ "thimble,autopilot,face_steer,face_mom_swipe,face_cut_min_y,needle_tip,needle_rate,"
				+ "lh_steer,lh_press,lh_tex,rh_steer,rh_press,rh_tex,paused,held,"
				+ "offfabric,err,heading_err_deg,lh_scale,rh_scale,lh_swap,rh_swap,bonk,bonk_y,cut_stage"
			)
		)
	)
	_events = FileAccess.open(out_dir + "/events.txt", FileAccess.WRITE)
	_cut_pts = R.load_cut_points(FACE_CUT_TEX)
	_ev(
		(
			"start scenario=%s touch=%s window=%s"
			% [scenario, touch_mode, DisplayServer.window_get_size()]
		)
	)
	_main.call_deferred()


func _ev(msg: String) -> void:
	var line: String = "[f%05d] %s" % [frame, msg]
	print("PLAYDRIVER ", line)
	if _events != null:
		_events.store_line(line)
		_events.flush()


# ---------------------------------------------------------------- 입력 주입


func _key(code: int, pressed: bool) -> void:
	if bool(_held.get(code, false)) == pressed:
		return
	_held[code] = pressed
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _tap(code: int, hold_frames: int = 3) -> void:
	_key(code, true)
	await _wait(hold_frames)
	_key(code, false)


func _to_window(canvas_pos: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * canvas_pos


func _center_of(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)


func _click_control(c: Control) -> void:
	await _click(_center_of(c))


func _click(canvas_pos: Vector2) -> void:
	var wp: Vector2 = _to_window(canvas_pos)
	var mm: InputEventMouseMotion = InputEventMouseMotion.new()
	mm.position = wp
	mm.global_position = wp
	Input.parse_input_event(mm)
	await _wait(2)
	var down: InputEventMouseButton = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = wp
	down.global_position = wp
	Input.parse_input_event(down)
	await _wait(3)
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = wp
	up.global_position = wp
	Input.parse_input_event(up)
	_ev("click canvas=%s window=%s" % [canvas_pos, wp])


func _touch(index: int, canvas_pos: Vector2, pressed: bool) -> void:
	var tag: String = "touch%d" % index
	if bool(_held.get(tag, false)) == pressed and pressed:
		return
	_held[tag] = pressed
	var ev: InputEventScreenTouch = InputEventScreenTouch.new()
	ev.index = index
	ev.position = _to_window(canvas_pos)
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _touch_tap(index: int, canvas_pos: Vector2) -> void:
	_touch(index, canvas_pos, true)
	await _wait(4)
	_touch(index, canvas_pos, false)
	_ev("touch tap %d at %s" % [index, canvas_pos])


func _release_steer() -> void:
	if steer_via_touch:
		_touch_steer(0)
	else:
		_key(K_LEFT, false)
		_key(K_RIGHT, false)


# 터치 조향: index 0 손가락을 ◀/▶ 버튼 위에 누르고 있다. dir=0이면 뗀다.


func _touch_steer(dir: int) -> void:
	if dir == _touch_steer_dir:
		return
	var tc: Control = _touch_controls()
	if tc == null:
		return
	if _touch_steer_dir != 0:
		var old_b: int = 0 if _touch_steer_dir < 0 else 1
		_touch(0, tc.button_rect(old_b).get_center(), false)
	_touch_steer_dir = dir
	if dir != 0:
		var b: int = 0 if dir < 0 else 1
		_touch(0, tc.button_rect(b).get_center(), true)


func _steer_hold(dir: int) -> void:
	if steer_via_touch:
		_touch_steer(dir)
		return
	_key(K_LEFT, dir < 0)
	_key(K_RIGHT, dir > 0)


# ---------------------------------------------------------------- 대기·캡처


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _wait_until(cond: Callable, max_frames: int, what: String) -> bool:
	for _i in range(max_frames):
		if cond.call():
			return true
		await get_tree().process_frame
	_ev("TIMEOUT waiting for " + what)
	return false


func _cap(name: String) -> void:
	# 창이 가려지거나 최소화되면 macOS가 그리기를 건너뛴다. 무기한 기다리면(특히 일시정지 중)
	# 시나리오가 멈추므로 그리기 1회를 CAP_MAX_WAIT 프레임까지만 기다리고, 넘으면 건너뛴다.
	if not await _await_draw():
		_ev("WARNING capture %s SKIPPED (render stalled)" % name)
		return
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out_dir, name])
	_ev("capture %s %s" % [name, img.get_size()])


func _cap_seq() -> void:
	var name: String = "seq/%s_%03d_f%05d" % [_seq_prefix, _seq_idx, frame]
	_seq_idx += 1
	if not await _await_draw():
		_ev("WARNING seq %s SKIPPED (render stalled)" % name)
		return
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out_dir, name])


## 다음 그리기 완료(frame_post_draw)까지 최대 CAP_MAX_WAIT 프레임 기다린다. 그려졌으면 true.
## 뷰포트 텍스처는 다음 그리기 전까지 그대로라 이어서 get_image()하면 그 프레임 내용이다.
func _await_draw() -> bool:
	var start: int = _draw_count
	for _i in range(CAP_MAX_WAIT):
		await get_tree().process_frame
		if _draw_count > start:
			return true
	return false


func _on_post_draw() -> void:
	_draw_count += 1


func _record(prefix: String, every: int, frames: int) -> void:
	_seq_prefix = prefix
	_seq_every = every
	_seq_until = frame + frames
	_seq_idx = 0
	_ev("record %s every %d for %d frames" % [prefix, every, frames])


# ---------------------------------------------------------------- 상태 읽기(쓰기 금지)


func _scene() -> Node:
	return get_tree().current_scene


func _scene_name() -> String:
	var s: Node = _scene()
	return s.scene_file_path.get_file().get_basename() if s != null else ""


func _gp() -> Node:
	var s: Node = _scene()
	if s != null and s.scene_file_path.ends_with("Gameplay.tscn"):
		return s
	return null


func _touch_controls() -> Control:
	var gp: Node = _gp()
	if gp == null:
		return null
	return gp.get_node_or_null("HUD/TouchControls") as Control


func _player() -> Node:
	var gp: Node = _gp()
	return gp.get("_player") if gp != null else null


func _state() -> int:
	var gp: Node = _gp()
	return int(gp.get("_state")) if gp != null else -1


func _progress_s() -> float:
	var gp: Node = _gp()
	if gp == null:
		return -1.0
	var tr: Object = gp.get("_track")
	var p: Node2D = gp.get("_player")
	if tr == null or p == null:
		return -1.0
	return float(tr.query(p.position, int(gp.get("_hint")))["s"])


func _process(_delta: float) -> void:
	frame += 1
	if _seq_every > 0 and frame <= _seq_until and frame % _seq_every == 0:
		_cap_seq()
	if frame == _seq_until:
		_ev("record %s done (%d frames saved)" % [_seq_prefix, _seq_idx])
	_write_log()


func _write_log() -> void:
	if _log == null:
		return
	var gp: Node = _gp()
	var cols: Array = [frame, _scene_name(), _run_index]
	if gp == null:
		_log.store_line(",".join(cols.map(func(x): return str(x))))
		return
	var p: Node = gp.get("_player")
	var face: Control = gp.get_node_or_null("BackdropLayer/FaceView")
	var nv: Node = gp.get_node_or_null("ForegroundLayer/NeedleView")
	var lh: Node = gp.get_node_or_null("ForegroundLayer/LeftHand")
	var rh: Node = gp.get_node_or_null("ForegroundLayer/RightHand")
	var fy: float = R.face_cut_min_y(face, _cut_pts)
	var st: int = _state()
	if st == 1 and fy < _face_min_y:
		_face_min_y = fy
		_face_min_frame = frame
	(
		cols
		. append_array(
			[
				st,
				"%.1f" % _progress_s(),
				p.speed_index,
				"%.3f" % p.target_steer,
				"%.3f" % p.actual_steer,
				int(p.is_drifting),
				"%.3f" % p.risk,
				"%.2f" % p.stun_timer,
				"%.2f" % p.thimble_timer,
				"%.2f" % p.autopilot_timer,
				"%.3f" % R.f(face, "_steer"),
				"%.3f" % R.f(face, "_mom_swipe"),
				"%.2f" % fy,
				"%.2f" % float(nv.needle_tip_y()),
				"%.3f" % R.f(nv, "_rate"),
				"%.3f" % R.f(lh, "_steer"),
				"%.3f" % R.f(lh, "_press"),
				R.tex_name(lh),
				"%.3f" % R.f(rh, "_steer"),
				"%.3f" % R.f(rh, "_press"),
				R.tex_name(rh),
				int(get_tree().paused),
				_held_str(),
				"%.2f" % p.offfabric_timer,
				"%.1f" % R.err(_gp()),
				"%.1f" % R.heading_err_deg(_gp()),
				"%.4f" % float(lh.call("press_scale")),
				"%.4f" % float(rh.call("press_scale")),
				"%.3f" % float(lh.call("swap_progress")),
				"%.3f" % float(rh.call("swap_progress")),
				int(bool(face.call("is_bonk_active"))),
				"%.2f" % float(face.call("bonk_offset_y")),
				int(R.cut_stage(_gp())),
			]
		)
	)
	_log.store_line(",".join(cols.map(func(x): return str(x))))
	_detect_events(gp, p, face)


func _held_str() -> String:
	var out: PackedStringArray = PackedStringArray()
	for k in _held.keys():
		if _held[k]:
			out.append(OS.get_keycode_string(k) if k is int else str(k))
	return "+".join(out)


# 자연 발생 이벤트(부상·아이템·엄마) 감지 → 캡처. 읽기만 한다.


func _detect_events(_gpn: Node, p: Node, face: Control) -> void:
	var stun: bool = p.stun_timer > 0.0
	var th: bool = p.thimble_timer > 0.0
	var ap: bool = p.autopilot_timer > 0.0
	var mom_sw: float = R.f(face, "_mom_swipe")
	var tag: String = "r%d" % _run_index
	if stun and not bool(_prev.get("stun", false)):
		var n: int = int(_auto_caps.get(tag + "cut", 0)) + 1
		_auto_caps[tag + "cut"] = n
		_ev("EVENT injury #%d s=%.0f" % [n, _progress_s()])
		_cap_later("play_%s_injury%d_t0" % [tag, n], 2)
		_cap_later("play_%s_injury%d_t30" % [tag, n], 30)
	if th and not bool(_prev.get("th", false)):
		_ev("EVENT thimble s=%.0f" % _progress_s())
		_cap_later("play_%s_thimble_s%.0f" % [tag, _progress_s()], 20)
	if not th and bool(_prev.get("th", false)):
		_ev("EVENT thimble end")
		_cap_later("play_%s_thimble_end_s%.0f" % [tag, _progress_s()], 10)
	var off: bool = p.offfabric_timer > 0.0
	if off and not bool(_prev.get("off", false)):
		var nb: int = int(_auto_caps.get(tag + "bonk", 0)) + 1
		_auto_caps[tag + "bonk"] = nb
		_ev(
			(
				"EVENT offfabric reset (bonk) #%d s=%.0f stun=%.2f cut_stage=%d bonk_active=%s"
				% [
					nb,
					_progress_s(),
					p.stun_timer,
					R.cut_stage(_gp()),
					face.call("is_bonk_active"),
				]
			)
		)
	if ap and not bool(_prev.get("ap", false)):
		_ev("EVENT mom chance start s=%.0f" % _progress_s())
		if _run_index == pause_mom_run:
			_pause_probe("play_%s_mom_paused_mid" % tag, 10, 45)
		_cap_later("play_%s_mom_enter_a" % tag, 8)
		_cap_later("play_%s_mom_enter_b" % tag, 18)
		_cap_later("play_%s_mom_hold" % tag, 90)
		_record("%s_mom" % tag, 4, 260)
	if not ap and bool(_prev.get("ap", false)):
		_ev("EVENT mom chance end s=%.0f" % _progress_s())
		_cap_later("play_%s_mom_exit_a" % tag, 10)
		_cap_later("play_%s_mom_exit_done" % tag, 60)
	_prev["stun"] = stun
	_prev["th"] = th
	_prev["ap"] = ap
	_prev["off"] = off
	_prev["mom_sw"] = mom_sw


## delay 프레임 뒤 Esc로 일시정지 → hold 프레임 유지·캡처 → Esc로 복귀(전환 도중 일시정지 확인).
func _pause_probe(name: String, delay: int, hold: int) -> void:
	await _wait(delay)
	var lh: Node = _gp().get_node("ForegroundLayer/LeftHand") if _gp() != null else null
	var before: float = float(lh.call("swap_progress")) if lh != null else NAN
	await _tap(K_PAUSE)
	await _wait(hold)
	var during: float = float(lh.call("swap_progress")) if is_instance_valid(lh) else NAN
	await _cap(name)
	_ev("pause probe %s paused=%s swap %.3f -> %.3f" % [name, get_tree().paused, before, during])
	await _tap(K_PAUSE)
	await _wait(6)
	_ev("pause probe %s resumed paused=%s" % [name, get_tree().paused])


func _cap_later(name: String, delay: int) -> void:
	await _wait(delay)
	await _cap(name)


# ---------------------------------------------------------------- 자동 조향(읽은 값으로 판단)


func _physics_process(_delta: float) -> void:
	if not auto_steer or manual_override:
		return
	var gp: Node = _gp()
	if gp == null or _state() != 1 or get_tree().paused:
		_release_steer()
		return
	var p: Node2D = gp.get("_player")
	var tr: Object = gp.get("_track")
	if p.autopilot_timer > 0.0 or p.stun_timer > 0.0 or p.offfabric_timer > 0.0:
		_release_steer()
		return
	var s: float = float(tr.query(p.position, int(gp.get("_hint")))["s"])
	var look: float = clampf(p.speed * 0.42, 42.0, 130.0)
	var tgt: Vector2 = tr.point_at_s(minf(s + look, tr.length))
	var herr: float = wrapf((tgt - p.position).angle() - p.heading, -PI, PI)
	var u: float = clampf(herr * 2.6, -1.0, 1.0)
	var diff: float = u - p.target_steer
	if diff > 0.06:
		_steer_hold(1)
	elif diff < -0.06:
		_steer_hold(-1)
	else:
		_steer_hold(0)


# ---------------------------------------------------------------- 시나리오


func _main() -> void:
	await _wait(20)
	if scenario == "mobile":
		await _scenario_mobile()
	elif scenario == "scold":
		await load("res://play_driver/ScoldPlay.gd").run(self)
	elif scenario.begins_with("cutdlg"):
		await load("res://play_driver/CutDialoguePlay.gd").run(self)
	else:
		await _scenario_full()
	_ev("face cut min y over RUNNING frames = %.2f at frame %d" % [_face_min_y, _face_min_frame])
	_ev("DONE")
	if _log != null:
		_log.flush()
	await _wait(5)
	get_tree().quit(0)


func _menu_to_gameplay(prefix: String) -> bool:
	# 1) 메인 메뉴 + 최초 실행 닉네임 모달
	await _wait_until(func(): return _scene_name() == "Main", 300, "Main")
	await _wait(40)
	var nick: Node = R.find_script_node(_scene(), "NicknameDialog.gd")
	if nick != null:
		await _cap(prefix + "01_nickname_modal")
		# 대화상자가 닫히며 해제되므로 약한 참조로 잡는다(해제된 람다 캡처 오류 방지).
		var cb_ref: WeakRef = weakref(nick.get_node("Panel/ConfirmButton"))
		var nick_ref: WeakRef = weakref(nick)
		await _activate(
			func(): return cb_ref.get_ref(),
			func(): return nick_ref.get_ref() == null,
			"NickConfirm"
		)
		await _wait(20)
	else:
		_ev("no nickname modal")
	await _cap(prefix + "02_main_menu")
	if not await _activate(
		func(): return _scene().get_node("Menu/StartButton"),
		func(): return _scene_name() == "TrackKindSelect",
		"Start"
	):
		return false
	var official: Callable = func(): return _scene().get("_official_card")  # 트랙 종류: 공식
	if not await _activate(official, func(): return _scene_name() == "TrackSelect", "Official"):
		return false
	await _wait(30)
	# 2) 트랙 선택: → 키(또는 터치 모드에선 다음 버튼 클릭)로 tee_01까지 이동
	for _i in range(20):
		if str(_scene().call("_current_id")) == TARGET_TRACK:
			break
		if touch_mode:
			await _click_control(_scene().get("_next_button"))
		else:
			await _tap(K_RIGHT)
		await _wait(8)
	_ev("track selected: %s" % _scene().call("_current_id"))
	await _cap(prefix + "03_track_select")
	return await _activate(
		func(): return _scene().get("_play_button"), func(): return _gp() != null, "Play"
	)


## 버튼 활성화: 마우스 클릭(최대 2회) → 실패하면 fallback 키(기본 Enter=ui_accept, 튜토리얼은 Esc).
## 드물게 OS 창 마우스 exit 이벤트가 눌림/뗌 사이에 끼어 클릭이 취소되는 경우가 있어 재시도한다.
## 어느 쪽이든 실제 입력 이벤트다. 어떤 방식으로 넘어갔는지 로그에 남긴다.
func _activate(
	get_btn: Callable, done: Callable, what: String, fallback_key: int = KEY_ENTER
) -> bool:
	for attempt in range(4):
		if attempt < 2:
			await _click_control(get_btn.call())
		else:
			await _tap(fallback_key)
		if await _wait_until(done, 90, what):
			_ev(
				(
					"%s activated by %s (attempt %d)"
					% [
						what,
						"click" if attempt < 2 else OS.get_keycode_string(fallback_key),
						attempt
					]
				)
			)
			return true
		_ev("%s attempt %d did not take effect; retrying" % [what, attempt])
	return false


func _close_tutorial_if_any(prefix: String) -> void:
	await _wait(30)
	var tut: Node = R.find_script_node(_scene(), "TutorialDialog.gd")
	if tut == null:
		_ev("no tutorial")
		return
	await _wait(20)
	await _cap(prefix + "04_tutorial_coachmarks")
	var btn_ref: WeakRef = weakref(tut.get_node("CloseButton"))
	var tut_ref: WeakRef = weakref(tut)
	await _activate(
		func(): return btn_ref.get_ref(),
		func(): return tut_ref.get_ref() == null,
		"TutorialClose",
		KEY_ESCAPE
	)
	await _wait(5)


func _wait_countdown(prefix: String) -> void:
	# 카운트다운 동안 바늘 끝 y를 기록해 상승점 정지 여부를 본다.
	var tips: Array = []
	var got_mid: bool = false
	while _gp() != null and _state() == 0:
		var nv: Node = _gp().get_node("ForegroundLayer/NeedleView")
		tips.append(float(nv.needle_tip_y()))
		if not got_mid and float(_gp().get("_countdown_time")) < 1.6:
			got_mid = true
			await _cap(prefix + "05_countdown")
		await get_tree().process_frame
	if tips.size() > 0:
		_ev(
			(
				"countdown needle tip: frames=%d min=%.2f max=%.2f"
				% [tips.size(), tips.min(), tips.max()]
			)
		)


func _scenario_full() -> void:
	if not await _menu_to_gameplay("play_"):
		return
	_run_index = 1
	await _close_tutorial_if_any("play_")
	await _wait_countdown("play_")
	_ev("GO run1")
	auto_steer = true
	await _wait(20)
	await _cap("play_06_straight_gear1")
	# 3) 가감속 1→5→2 (W/S 키 탭). 각 단 40프레임 유지 후 캡처.
	_record("r1_gears", 6, 330)
	for g in range(2, 6):
		await _tap(K_UP)
		await _wait(40)
		await _cap("play_07_gear%d_s%.0f" % [g, _progress_s()])
	for g in [4, 3, 2]:
		await _tap(K_DOWN)
		await _wait(30)
	await _cap("play_08_gear_down2_s%.0f" % _progress_s())
	# 커브 진입 전/중 캡처(자동 조향으로 주행하며 s 기준).
	await _wait_until(func(): return _progress_s() >= 560.0, 1200, "s>=560")
	await _cap("play_09_after_curve1_s%.0f" % _progress_s())
	# 4) 좌우 연속 조향(수동, 자동조향 해제). 직선 구간 s≈600~1100.
	manual_override = true
	_record("r1_steer", 2, 330)
	_steer_hold(-1)
	await _wait(45)
	await _cap("play_10_steer_left_hold")
	_steer_hold(1)
	await _wait(12)
	await _cap("play_11_steer_switching_to_right")
	await _wait(60)
	await _cap("play_12_steer_right_max")
	_steer_hold(-1)
	await _wait(12)
	await _cap("play_13_steer_switching_to_left")
	await _wait(60)
	await _cap("play_14_steer_left_max")
	for _k in range(4):
		_steer_hold(1)
		await _wait(16)
		_steer_hold(-1)
		await _wait(16)
	_steer_hold(0)
	manual_override = false
	await _wait(90)
	_ev("steer demo done s=%.0f" % _progress_s())
	# (s 1298 엄마 찬스는 자동 조향이 지나가며 자연 획득 → _detect_events가 캡처)
	# 5) 드리프트: 좌 커브 s≈1800~2150 에서 Shift 홀드 + 자동 조향.
	await _wait_until(func(): return _progress_s() >= 1400.0, 3000, "s>=1400")
	await _cap("play_15_curve_right_approach_s%.0f" % _progress_s())
	await _wait_until(func(): return _progress_s() >= 1780.0, 3000, "s>=1780")
	await _cap("play_16_curve_left_entry_s%.0f" % _progress_s())
	_record("r1_drift", 3, 150)
	_key(K_DRIFT, true)
	await _wait(40)
	await _cap("play_17_drift_a")
	await _wait(40)
	await _cap("play_18_drift_b")
	await _wait(60)
	_key(K_DRIFT, false)
	await _wait(30)
	# 6) 일시정지 → 복귀
	_ev("pause at s=%.0f" % _progress_s())
	await _tap(K_PAUSE)
	await _wait(12)
	await _cap("play_19_paused_t0")
	await _wait(60)
	await _cap("play_20_paused_t60")
	await _tap(K_PAUSE)
	await _wait(20)
	await _cap("play_21_resumed")
	await _wait(60)
	# 6b) 트랙 이탈 강제 복귀(꿀밤): 사선 직선(s 2213~2780, heading≈-x)에서 4단으로 올린 뒤 우조향
	#     (바깥쪽=화면 위, 다른 트랙 구간 없음)으로 틀고 키를 떼 직진한다.
	await _wait_until(func(): return _progress_s() >= 2260.0, 1500, "s>=2260")
	await _induce_bonk("r1", 1, 4, false)
	await _gear_to(2)
	await _wait(60)
	# 7) 재시작(R)
	_ev("restart at s=%.0f" % _progress_s())
	auto_steer = false
	_release_steer()
	await _tap(K_RESTART)
	await _wait_until(func(): return _gp() != null and _state() == 0, 200, "restart countdown")
	await _wait(3)
	await _cap("play_22_restart_t3")
	_run_index = 2
	_prev.clear()
	await _wait_countdown("play_r2_")
	_ev("GO run2")
	auto_steer = true
	# 8) 2회차: 완주 목표. 초반 직선에서 3단, s 600~1000 직선에서 5단 급반전으로 자연 부상 유도.
	await _tap(K_UP)
	await _wait(20)
	await _tap(K_UP)
	await _wait_until(func(): return _progress_s() >= 620.0, 3000, "s>=620")
	await _tap(K_UP)
	await _wait(10)
	await _tap(K_UP)
	await _wait(30)
	await _induce_injury("r2a", 1060.0)
	# 엄마 찬스(s 1298) 전후는 자동 조향. 부상 해제 후 3단 복귀.
	await _gear_to(3)
	# 첫 골무(s 2884)가 끝난 뒤 둘째 부상 유도 → 둘째 골무(s 4193)에서 부상+골무 조합.
	await _wait_until(
		func(): return _progress_s() >= 3350.0 and _player().thimble_timer <= 0.0,
		6000,
		"thimble1 over"
	)
	await _gear_to(5)
	await _wait(10)
	await _induce_injury("r2b", 3900.0)
	await _gear_to(3)
	# 2회차 꿀밤: 긴 직선(s 4597~5532, heading≈+y)에서 좌조향(안쪽=+x, 반대편 트랙까지 916px).
	# 부상 2단계 상태에서 발동해 손 부상 단계가 오르지 않는지 보고, 도중 일시정지를 1회 넣는다.
	await _wait_until(func(): return _progress_s() >= 4660.0, 6000, "s>=4660")
	await _induce_bonk("r2", -1, 4, true)
	await _gear_to(3)
	await _wait_until(func(): return _progress_s() >= 5000.0, 6000, "s>=5000")
	await _cap("play_r2_straight_late_s%.0f" % _progress_s())
	# 완주 → FinishView → Result
	await _wait_until(func(): return _gp() == null or _state() >= 2, 6000, "finish")
	if _gp() != null:
		_ev("FINISH_VIEW")
		_release_steer()
		auto_steer = false
		var nv: Node = _gp().get_node("ForegroundLayer/NeedleView")
		_record("r2_finish", 6, 220)
		await _wait(6)
		await _cap("play_30_finish_view_t6")
		_ev("finish needle tip=%.2f" % float(nv.needle_tip_y()))
		await _wait(54)
		await _cap("play_31_finish_view_t60")
		await _wait(90)
		await _cap("play_32_finish_view_t150")
		_ev("finish needle tip=%.2f" % float(nv.needle_tip_y()))
	await _wait_until(func(): return _scene_name() == "Result", 600, "Result")
	await _wait(60)
	await _cap("play_33_result")


func _gear_to(target: int) -> void:
	for _i in range(8):
		var p: Node = _player()
		if p == null:
			return
		if p.stun_timer > 0.0 or p.offfabric_timer > 0.0:
			await _wait_until(
				func():
					return (
						_player() == null
						or (_player().stun_timer <= 0.0 and _player().offfabric_timer <= 0.0)
					),
				600,
				"unlock"
			)
			continue
		if p.speed_index == target:
			return
		if steer_via_touch and _touch_controls() != null:
			var b: int = 2 if p.speed_index < target else 3  # TouchControls.Btn.SPEED_UP/DOWN
			await _touch_tap(1, _touch_controls().button_rect(b).get_center())
		else:
			await _tap(K_UP if p.speed_index < target else K_DOWN)
		await _wait(6)


## 고속 좌우 급반전(실제 키 입력)으로 위험도를 올려 자연 부상을 유도한다. s_limit 넘거나 부상
## 발생 시 종료. 조향은 수동, 끝나면 자동 조향 복귀.
func _induce_injury(tag: String, s_limit: float) -> void:
	_ev("induce injury %s from s=%.0f" % [tag, _progress_s()])
	manual_override = true
	_record(tag + "_reversal", 3, 150)
	var dir: int = 1
	_key(K_DRIFT, true)
	for _i in range(40):
		var p: Node = _player()
		if p == null or p.stun_timer > 0.0 or _progress_s() >= s_limit:
			break
		_steer_hold(dir)
		dir = -dir
		await _wait(26)
	_key(K_DRIFT, false)
	_steer_hold(0)
	manual_override = false
	_ev("induce injury %s end s=%.0f stun=%.2f" % [tag, _progress_s(), _player().stun_timer])


## 트랙 이탈 강제 복귀(꿀밤)를 실제 조향 입력으로 발동한다. 속도를 올린 뒤 dir 쪽으로 조향해
## heading을 트랙 접선에서 약 70~85도 틀고(RELEASE_DEG에서 키를 떼면 조향 복귀 지연으로 더 돈다),
## 조향 키를 뗀 채 직진해 오차가 임계(max(300, fail*3.5))를 넘어 0.12초 지속되게 한다.
## 임계 근처부터 매 프레임 시퀀스를 저장한다(발동 전 프레임 포함). pause_mid면 발동 12프레임 뒤
## 일시정지·복귀를 1회 넣는다. 게임 상태는 읽기만 한다.
func _induce_bonk(tag: String, dir: int, gear: int, pause_mid: bool) -> bool:
	var p0: Node = _player()
	_ev(
		(
			"induce bonk %s start s=%.0f err=%.1f thr=%.1f cut_stage=%d stun=%.2f"
			% [
				tag,
				_progress_s(),
				R.err(_gp()),
				R.reset_threshold(_gp()),
				R.cut_stage(_gp()),
				p0.stun_timer
			]
		)
	)
	manual_override = true
	_steer_hold(0)
	await _gear_to(gear)
	await _wait(20)
	var thr: float = R.reset_threshold(_gp())
	var stage0: int = R.cut_stage(_gp())
	_steer_hold(dir)
	_ev("bonk %s steer %s held" % [tag, "right" if dir > 0 else "left"])
	await _wait_until(
		func(): return absf(R.heading_err_deg(_gp())) >= BONK_RELEASE_DEG, 240, "bonk heading turn"
	)
	_steer_hold(0)
	_ev(
		(
			"bonk %s steer released heading_err=%.1f err=%.1f speed_idx=%d"
			% [tag, R.heading_err_deg(_gp()), R.err(_gp()), _player().speed_index]
		)
	)
	await _wait(18)
	_ev("bonk %s heading settled=%.1f err=%.1f" % [tag, R.heading_err_deg(_gp()), R.err(_gp())])
	await _cap("play_%s_bonk_0_offseam_straight" % tag)
	await _wait_until(
		func(): return R.err(_gp()) >= thr - 45.0 or _player().offfabric_timer > 0.0,
		900,
		"err near threshold"
	)
	_record("%s_bonk" % tag, 1, 100)
	var t_near: int = frame
	var hit: bool = await _wait_until(
		func(): return _player().offfabric_timer > 0.0, 400, "offfabric reset"
	)
	if not hit:
		_steer_hold(0)
		manual_override = false
		_ev("bonk %s FAILED (no reset) err=%.1f" % [tag, R.err(_gp())])
		return false
	_ev(
		(
			"bonk %s triggered %d frames after err>=thr-45; cut_stage %d->%d stun=%.2f"
			% [tag, frame - t_near, stage0, R.cut_stage(_gp()), _player().stun_timer]
		)
	)
	await _wait(3)
	await _cap("play_%s_bonk_1_t3" % tag)
	await _wait(9)
	if pause_mid:
		_ev("bonk %s pause mid-bonk (bonk_active=%s)" % [tag, _face_bonk_active()])
		if steer_via_touch and _touch_controls() != null:
			await _touch_tap(2, _touch_controls().button_rect(5).get_center())
		else:
			await _tap(K_PAUSE)
		await _wait(40)
		await _cap("play_%s_bonk_2_paused_mid" % tag)
		_ev("bonk %s paused=%s bonk_y=%.2f" % [tag, get_tree().paused, _face_bonk_y()])
		await _resume_from_pause()
		_ev("bonk %s resumed paused=%s" % [tag, get_tree().paused])
	else:
		await _cap("play_%s_bonk_2_t12" % tag)
	await _wait_until(func(): return _player().offfabric_timer <= 0.0, 200, "offfabric end")
	await _wait(10)
	await _cap("play_%s_bonk_3_after" % tag)
	_ev(
		(
			"bonk %s done s=%.0f cut_stage=%d stun=%.2f speed_idx=%d"
			% [tag, _progress_s(), R.cut_stage(_gp()), _player().stun_timer, _player().speed_index]
		)
	)
	manual_override = false
	return true


func _face_bonk_active() -> bool:
	var face: Node = _gp().get_node_or_null("BackdropLayer/FaceView") if _gp() != null else null
	return face != null and bool(face.call("is_bonk_active"))


func _face_bonk_y() -> float:
	var face: Node = _gp().get_node_or_null("BackdropLayer/FaceView") if _gp() != null else null
	return float(face.call("bonk_offset_y")) if face != null else NAN


## 일시정지 해제: 터치 모드면 일시정지 오버레이의 "계속" 버튼을 터치, 아니면 Esc.
func _resume_from_pause() -> void:
	# 한 번의 탭이 창 포커스/마우스 exit 이벤트로 취소될 수 있어, 해제될 때까지 재시도한다
	# (터치 2회 → Esc). 어떤 입력으로 풀렸는지 로그에 남긴다.
	for attempt in range(4):
		var row: Node = (
			_gp().get_node_or_null("HUD/PauseOverlay/TouchPauseButtons") if _gp() != null else null
		)
		if steer_via_touch and row != null and attempt < 2:
			await _touch_tap(3, _center_of(row.get_child(0)))
		else:
			await _tap(K_PAUSE)
		await _wait(20)
		if not get_tree().paused:
			_ev("resume ok attempt %d (%s)" % [attempt, "touch" if attempt < 2 else "Esc"])
			return
		_ev("resume attempt %d did not take effect; retrying" % attempt)


func _scenario_mobile() -> void:
	steer_via_touch = true
	if not await _menu_to_gameplay("play_m_"):
		return
	_run_index = 1
	await _close_tutorial_if_any("play_m_")
	await _wait_countdown("play_m_")
	_ev("GO mobile")
	var tc: Control = _touch_controls()
	if tc == null:
		_ev("NO touch controls")
		return
	auto_steer = true
	await _wait(30)
	await _cap("play_m_06_start")
	await _touch_tap(1, tc.button_rect(2).get_center())
	await _wait(20)
	await _touch_tap(1, tc.button_rect(2).get_center())
	await _wait(40)
	await _cap("play_m_07_gear3")
	await _wait_until(func(): return _progress_s() >= 600.0, 1500, "s>=600")
	manual_override = true
	_touch_steer(-1)
	await _wait(50)
	await _cap("play_m_08_steer_left_max")
	_touch_steer(1)
	await _wait(60)
	await _cap("play_m_09_steer_right_max")
	_touch_steer(0)
	manual_override = false
	await _wait_until(func(): return _progress_s() >= 1780.0, 3000, "s>=1780")
	# 드리프트: index 1 손가락으로 DRIFT 버튼 홀드 + index 0 자동 조향
	_touch(1, tc.button_rect(4).get_center(), true)
	await _wait(45)
	await _cap("play_m_10_drift")
	_touch(1, tc.button_rect(4).get_center(), false)
	await _wait(30)
	await _touch_tap(2, tc.button_rect(5).get_center())
	await _wait(20)
	await _cap("play_m_11_paused")
	# 일시정지 오버레이의 "계속" 버튼(터치 → 에뮬레이션 마우스로 Button 눌림)
	var row: Node = _gp().get_node_or_null("HUD/PauseOverlay/TouchPauseButtons")
	if row != null:
		var btn: Control = row.get_child(0)
		var pos: Vector2 = _center_of(btn)
		await _touch_tap(3, pos)
	else:
		await _tap(K_PAUSE)
	await _wait(30)
	_ev("after resume paused=%s" % get_tree().paused)
	await _cap("play_m_12_resumed")
	# 터치 꿀밤: ▲ 터치로 4단, ▶ 터치 홀드로 바깥쪽 조향 후 뗌. 도중 ∥ 터치 일시정지·계속.
	await _wait_until(func(): return _progress_s() >= 2260.0, 1500, "s>=2260")
	await _induce_bonk("m", 1, 4, true)
	await _wait(30)
	await _cap("play_m_13_after_bonk")
