extends Node
## Overlock 홍보 영상 촬영 드라이버(촬영 사본 전용 autoload, 저장소 game/에는 넣지 않는다).
## tools/palm_contact_regression/play/PlayDriver.gd 를 촬영용으로 개조했다.
##
## 원칙: 게임 상태는 읽기만 한다. 조작은 전부 Input.parse_input_event()로 InputEventKey·
## InputEventMouseButton 을 주입한다. 촬영용 표현 조작은 HUD 캔버스 레이어 표시 끄기(HUD 없는 스틸)
## 한 가지뿐이며, 스틸을 찍은 직후 되돌린다. 화면에 로그 텍스트를 그리지 않는다.
##
## 인자(-- 뒤): --out=<dir> --scenario=heart|tee|star [--stills]
##   --stills : 시나리오가 지정한 순간에 HUD 있는/없는 스틸 PNG를 같은 프레임으로 저장한다.
##              Movie Maker 촬영(--write-movie)과 같이 쓰지 않는다(HUD 끄기 프레임이 섞이지 않게).
## --fixed-fps 60(Movie Maker는 자동)으로 실행하면 1 프레임 = 1 물리 틱이라 같은 입력 스크립트가
## 같은 결과를 낸다. events.jsonl 의 mf 는 Movie Maker 출력 프레임 번호(Engine.get_frames_drawn())다.

const K_LEFT: int = KEY_LEFT
const K_RIGHT: int = KEY_RIGHT
const K_UP: int = KEY_W
const K_DOWN: int = KEY_S
const K_DRIFT: int = KEY_SHIFT
const R: GDScript = preload("res://promo_driver/PromoRead.gd")
const CAP_MAX_WAIT: int = 20
const BONK_RELEASE_DEG: float = 40.0
const INJ_PERIOD: int = 14  # 부상 유도 급반전 주기(프레임)

# 자동 조향 파라미터(피드포워드 곡률 + 헤딩/횡오차 피드백 → 조향량 역산 → 키 탭 선택).
const FF_TIME: float = 0.16  # 곡률 미리보기 시간(초)
const HEAD_TIME: float = 0.06  # 기준 헤딩 미리보기 시간(초)
const K_PSI: float = 3.2  # 헤딩 오차 게인(1/s)
const K_E: float = 2.2  # 횡오차 게인(1/s, Stanley)
const LEAD: float = 1.0  # actual_steer 지연 보상(목표 조향 선행량)
const GEAR_USE: float = 0.75  # 기어 선택: 최대 각속도 대비 허용 사용률
const DRIFT_ON: float = 0.8  # 드리프트 보조: 비드리프트 최대 각속도 대비 이 사용률을 넘으면 Shift

var out_dir: String = ""
var scenario: String = "heart"
var stills: bool = false

var frame: int = 0
var auto_steer: bool = false
var auto_gear: bool = false
var auto_drift: bool = false
var max_gear: int = 4
var manual_override: bool = false
# 자동 조향 횡오프셋(px, +=진행 방향 오른쪽). 아이템을 비켜 가야 할 때 [s0, s1] 구간에서만 쓴다.
var lat_offset: float = 0.0
var lat_s0: float = INF
var lat_s1: float = -INF
var drift_count: int = 0
var _held: Dictionary = {}
var _gear_key: int = 0
var _gear_key_frames: int = 0
var _gear_cooldown: int = 0
var _upshift_wait: int = 0
var _drift_off_frames: int = 0
var _log: FileAccess = null
var _events: FileAccess = null
var _prev: Dictionary = {}
var _draw_count: int = 0
var _last_cd: int = -1
var _still_seq: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000
	process_priority = 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--scenario="):
			scenario = a.substr(11)
		elif a == "--stills":
			stills = true
	if out_dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	if stills:
		DirAccess.make_dir_recursive_absolute(out_dir + "/stills")
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	_log = FileAccess.open(out_dir + "/frames.csv", FileAccess.WRITE)
	_log.store_line(
		(
			"frame,mf,scene,state,s,speed_idx,target_steer,actual_steer,err,drifting,risk,"
			+ "stun,thimble,autopilot,offfabric,held"
		)
	)
	_events = FileAccess.open(out_dir + "/events.jsonl", FileAccess.WRITE)
	_ev("start", {"scenario": scenario, "window": str(DisplayServer.window_get_size())})
	_main.call_deferred()


## 이벤트 기록. f=드라이버 프레임, mf=그려진 프레임 수(Movie Maker 프레임 번호와 대조).
func _ev(name: String, extra: Dictionary = {}) -> void:
	var d: Dictionary = {"f": frame, "mf": Engine.get_frames_drawn(), "ev": name}
	d.merge(extra)
	var line: String = JSON.stringify(d)
	print("PROMO ", line)
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


func _click_control(c: Control) -> void:
	var wp: Vector2 = _to_window(c.get_global_transform_with_canvas() * (c.size * 0.5))
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
	await _wait(4)
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = wp
	up.global_position = wp
	Input.parse_input_event(up)


## 마우스를 화면 밖 구석으로 옮겨 버튼 hover 강조가 남지 않게 한다.
func _park_mouse() -> void:
	var mm: InputEventMouseMotion = InputEventMouseMotion.new()
	mm.position = Vector2(2, 2)
	mm.global_position = Vector2(2, 2)
	Input.parse_input_event(mm)


func _release_steer() -> void:
	_key(K_LEFT, false)
	_key(K_RIGHT, false)


func _steer_hold(dir: int) -> void:
	_key(K_LEFT, dir < 0)
	_key(K_RIGHT, dir > 0)


# ---------------------------------------------------------------- 대기·스틸


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _wait_until(cond: Callable, max_frames: int, what: String) -> bool:
	for _i in range(max_frames):
		if cond.call():
			return true
		await get_tree().process_frame
	_ev("timeout", {"what": what})
	return false


func _await_draw() -> bool:
	var start: int = _draw_count
	for _i in range(CAP_MAX_WAIT):
		await get_tree().process_frame
		if _draw_count > start:
			return true
	return false


func _on_post_draw() -> void:
	_draw_count += 1


## 스틸: 다음 그리기 결과(HUD 있음)를 저장하고, 곧바로 HUD 캔버스 레이어만 숨긴 채 같은 게임
## 상태를 한 번 더 그려(force_draw, 시간 진행 없음) HUD 없는 판을 저장한 뒤 HUD를 되돌린다.
## --stills 가 없으면 아무것도 하지 않는다.
func _still(name: String) -> void:
	if not stills:
		return
	if not await _await_draw():
		_ev("still_skipped", {"name": name})
		return
	_still_seq += 1
	var base: String = "%s/stills/%s_%02d" % [out_dir, name, _still_seq]
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(base + "_hud.png")
	var hud: CanvasLayer = _gp().get_node_or_null("HUD") if _gp() != null else null
	if hud != null and hud.visible:
		hud.visible = false
		RenderingServer.force_draw(false, 0.0)
		var img2: Image = get_viewport().get_texture().get_image()
		img2.save_png(base + "_nohud.png")
		hud.visible = true
	_ev("still", {"name": base.get_file(), "size": str(img.get_size())})


## 조건을 만족하는 프레임에서 스틸을 count 장(간격 gap 프레임 이상) 찍는다(병렬 코루틴).
func _still_when(name: String, cond: Callable, count: int, gap: int, max_frames: int) -> void:
	if not stills:
		return
	var taken: int = 0
	var last: int = -100000
	for _i in range(max_frames):
		if taken >= count:
			return
		if frame - last >= gap and cond.call():
			await _still(name)
			taken += 1
			last = frame
		else:
			await get_tree().process_frame


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


func _needle_tip() -> float:
	var gp: Node = _gp()
	var nv: Node = gp.get_node_or_null("ForegroundLayer/NeedleView") if gp != null else null
	return float(nv.call("needle_tip_y")) if nv != null else NAN


func _process(_delta: float) -> void:
	frame += 1
	_write_log()


func _write_log() -> void:
	if _log == null:
		return
	var gp: Node = _gp()
	var cols: Array = [frame, Engine.get_frames_drawn(), _scene_name()]
	if gp == null:
		_log.store_line(",".join(cols.map(func(x): return str(x))))
		return
	var p: Node = gp.get("_player")
	cols.append_array(
		[
			_state(),
			"%.1f" % _progress_s(),
			p.speed_index,
			"%.3f" % p.target_steer,
			"%.3f" % p.actual_steer,
			"%.1f" % R.err(gp),
			int(p.is_drifting),
			"%.3f" % p.risk,
			"%.2f" % p.stun_timer,
			"%.2f" % p.thimble_timer,
			"%.2f" % p.autopilot_timer,
			"%.2f" % p.offfabric_timer,
			_held_str(),
		]
	)
	_log.store_line(",".join(cols.map(func(x): return str(x))))
	_detect_events(gp, p)


func _held_str() -> String:
	var out: PackedStringArray = PackedStringArray()
	for k in _held.keys():
		if _held[k]:
			out.append(OS.get_keycode_string(k))
	return "+".join(out)


## 자연 발생 이벤트(카운트다운·출발·부상·아이템·엄마·강제 복귀·드리프트·완주) 감지. 읽기만 한다.
func _detect_events(gp: Node, p: Node) -> void:
	var st: int = _state()
	if st == 0 and not bool(gp.get("_tutorial_open")):
		var cd: int = ceili(float(gp.get("_countdown_time")))
		if cd != _last_cd:
			_last_cd = cd
			_ev("countdown", {"value": cd})
	var prev_st: int = int(_prev.get("st", -1))
	if st == 1 and prev_st == 0:
		_ev("go", {"s": _progress_s()})
	if st == 2 and prev_st == 1:
		var res: Dictionary = gp.get("_pending_result")
		_ev(
			"finish",
			{
				"grade": str(res.get("grade", "")),
				"accuracy": float(res.get("accuracy", 0.0)),
				"perfect_rate": float(res.get("perfect_rate", 0.0)),
				"cuts": int(res.get("cuts", 0)),
				"final_time_ms": int(res.get("final_time_ms", 0)),
			}
		)
	var flags: Dictionary = {
		"cut_pending": p.cut_pending_timer > 0.0,
		"stun": p.stun_timer > 0.0,
		"thimble": p.thimble_timer > 0.0,
		"autopilot": p.autopilot_timer > 0.0,
		"offfabric": p.offfabric_timer > 0.0,
		"drift": bool(p.is_drifting),
	}
	for k in flags:
		var on: bool = flags[k]
		var was: bool = bool(_prev.get(k, false))
		if on != was:
			_ev(k + ("_start" if on else "_end"), {"s": snappedf(_progress_s(), 0.1)})
	if int(_prev.get("gear", -1)) != int(p.speed_index):
		_ev("gear", {"value": int(p.speed_index)})
	_detect_toast(gp)
	_prev.merge(flags, true)
	_prev["st"] = st
	_prev["gear"] = int(p.speed_index)


## 하단 알림(부상 대사·엄마 꾸중 말풍선·아이템 토스트) 상태 변화를 기록한다. 읽기만 한다.
## toast_show: 새 항목(세대 번호 변화)과 대사·초상화, toast_full: 알파 1 도달, toast_fade: 페이드아웃 시작,
## toast_hidden: 사라짐. _process 시점 값이라 화면과 1프레임 어긋날 수 있다(프레임 분석으로 확인).
func _detect_toast(gp: Node) -> void:
	var pres: Node = gp.get_node_or_null("Presenter")
	var t: Node = pres.get("_toast") if pres != null else null
	if t == null or t.get("_group") == null:
		return
	var g: Control = t.get("_group")
	var gen: int = int(t.get("_gen"))
	var vis: bool = g.visible
	var a: float = g.modulate.a if vis else 0.0
	var pr: TextureRect = t.get("_portrait")
	var tex: String = "-"
	if pr != null and pr.visible and pr.texture != null:
		tex = pr.texture.resource_path.get_file()
	var text: String = str(t.get("_label").text)
	if vis and gen != int(_prev.get("toast_gen", -1)):
		_ev("toast_show", {"text": text, "portrait": tex, "immediate": bool(t.get("_immediate"))})
		_prev["toast_full"] = false
	var prev_a: float = float(_prev.get("toast_a", 0.0))
	if vis and a >= 0.999 and not bool(_prev.get("toast_full", false)):
		_prev["toast_full"] = true
		_ev("toast_full", {"text": text})
	if vis and bool(_prev.get("toast_full", false)) and a < 0.999 and prev_a >= 0.999:
		_ev("toast_fade", {"text": text})
	if not vis and bool(_prev.get("toast_vis", false)):
		_ev("toast_hidden")
	_prev["toast_gen"] = gen if vis else int(_prev.get("toast_gen", -1))
	_prev["toast_a"] = a
	_prev["toast_vis"] = vis


# ---------------------------------------------------------------- 자동 조향(읽은 값으로 판단)


func _physics_process(_delta: float) -> void:
	var gp: Node = _gp()
	if gp == null or _state() != 1 or get_tree().paused:
		if auto_steer:
			_release_steer()
		_gear_release()
		if auto_drift:
			_key(K_DRIFT, false)
		return
	var p: Node2D = gp.get("_player")
	var tr: Object = gp.get("_track")
	var locked: bool = p.autopilot_timer > 0.0 or p.stun_timer > 0.0 or p.offfabric_timer > 0.0
	if auto_gear:
		_auto_gear_step(p, tr, gp, locked)
	if not auto_steer or manual_override:
		return
	if locked:
		_release_steer()
		if auto_drift:
			_key(K_DRIFT, false)
		return
	_auto_steer_step(p, tr, gp)


static func _expo(a: float) -> float:
	var s: float = Tuning.steer_expo
	if s <= 0.0:
		return a
	var m: float = absf(a)
	return signf(a) * (m - s * m * pow(1.0 - m, Tuning.steer_soft_p))


## _expo 의 역함수(단조 증가 구간 이분 탐색).
static func _inv_expo(e: float) -> float:
	var target: float = absf(e)
	var lo: float = 0.0
	var hi: float = 1.0
	for _i in range(24):
		var mid: float = (lo + hi) * 0.5
		if absf(_expo(mid)) < target:
			lo = mid
		else:
			hi = mid
	return signf(e) * (lo + hi) * 0.5


static func _wmax(speed: float, drift: bool) -> float:
	var tsf: float = maxf(speed / Tuning.max_speed, Tuning.steer_speed_floor)
	return Tuning.turn_power * tsf * (Tuning.drift_turn_mult if drift else 1.0)


static func _max_abs_curv(tr: Object, s0: float, s1: float) -> float:
	var k: float = 0.0
	var s: float = s0
	while s <= s1:
		k = maxf(k, absf(R.signed_curvature(tr, minf(s, tr.length), 14.0)))
		s += 8.0
	return k


func _auto_steer_step(p: Node2D, tr: Object, gp: Node) -> void:
	var q: Dictionary = tr.query(p.position, int(gp.get("_hint")))
	var s: float = float(q["s"])
	var v: float = p.speed
	# 드리프트 보조: 곧 올 곡률이 비드리프트 한계를 넘으면 Shift 홀드, 잦아들면 뗀다.
	if auto_drift:
		var need: float = v * _max_abs_curv(tr, s, s + v * 0.3 + 10.0)
		if need > DRIFT_ON * _wmax(v, false):
			if not bool(_held.get(K_DRIFT, false)):
				drift_count += 1
				_ev("drift_key_down", {"n": drift_count, "s": snappedf(s, 0.1)})
			_key(K_DRIFT, true)
			_drift_off_frames = 0
		elif bool(_held.get(K_DRIFT, false)):
			_drift_off_frames += 1
			if _drift_off_frames >= 4:
				_key(K_DRIFT, false)
	var drifting: bool = bool(_held.get(K_DRIFT, false))
	var c: Vector2 = tr.point_at_s(s)
	var t: Vector2 = tr.tangent_at_s(s)
	var n_right: Vector2 = Vector2(-t.y, t.x)
	var e_right: float = (p.position - c).dot(n_right)
	if s >= lat_s0 and s <= lat_s1:
		e_right -= lat_offset
	var kff: float = R.signed_curvature(tr, minf(s + v * FF_TIME, tr.length))
	var ref_h: float = tr.tangent_at_s(minf(s + v * HEAD_TIME, tr.length)).angle()
	var psi: float = wrapf(ref_h - p.heading, -PI, PI)
	var psi_cmd: float = psi + atan2(-K_E * e_right, v + 40.0)
	var w_des: float = v * kff + K_PSI * psi_cmd
	var a_des: float = _inv_expo(clampf(w_des / _wmax(v, drifting), -1.0, 1.0))
	var t_des: float = clampf(a_des + LEAD * (a_des - p.actual_steer), -1.0, 1.0)
	# 다음 틱 target_steer 후보 3가지(뗌/우/좌) 중 목표에 가장 가까운 입력을 고른다.
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var tgt: float = p.target_steer
	var none: float = move_toward(tgt, 0.0, Tuning.steer_return_rate * dt)
	var rr: float = Tuning.steer_charge_rate * (Tuning.steer_reversal_boost if tgt < 0.0 else 1.0)
	var rl: float = Tuning.steer_charge_rate * (Tuning.steer_reversal_boost if tgt > 0.0 else 1.0)
	var right: float = minf(tgt + rr * dt, 1.0)
	var left: float = maxf(tgt - rl * dt, -1.0)
	var best: int = 0
	var best_err: float = absf(none - t_des)
	if absf(right - t_des) < best_err - 0.002:
		best = 1
		best_err = absf(right - t_des)
	if absf(left - t_des) < best_err - 0.002:
		best = -1
	_steer_hold(best)


## 자동 변속: 앞 구간 곡률로 기어를 정한다(하향은 즉시, 상향은 대기 후). W/S 키 탭 상태기계.
func _auto_gear_step(p: Node2D, tr: Object, gp: Node, locked: bool) -> void:
	if _gear_key != 0:
		_gear_key_frames -= 1
		if _gear_key_frames <= 0:
			_gear_release()
			_gear_cooldown = 5
		return
	if _gear_cooldown > 0:
		_gear_cooldown -= 1
		return
	if locked:
		return
	var s: float = float(tr.query(p.position, int(gp.get("_hint")))["s"])
	var want: int = 1
	for g in range(max_gear, 0, -1):
		var v: float = Tuning.speed_table[g - 1]
		var k: float = _max_abs_curv(tr, s, s + v * 1.1 + 60.0)
		if v * k <= GEAR_USE * _wmax(v, auto_drift):
			want = g
			break
	var cur: int = int(p.speed_index)
	if want < cur:
		_upshift_wait = 0
		_gear_press(K_DOWN)
	elif want > cur:
		_upshift_wait += 1
		if _upshift_wait >= 24:
			_upshift_wait = 0
			_gear_press(K_UP)
	else:
		_upshift_wait = 0


func _gear_press(code: int) -> void:
	_gear_key = code
	_gear_key_frames = 3
	_key(code, true)


func _gear_release() -> void:
	if _gear_key != 0:
		_key(_gear_key, false)
		_gear_key = 0


# ---------------------------------------------------------------- 시나리오 공통


func _main() -> void:
	await _wait(10)
	match scenario:
		"heart":
			await _scenario_heart()
		"tee":
			await _scenario_tee()
		"star":
			await _scenario_star()
		"probe":
			await _wait(120)
		_:
			_ev("unknown_scenario")
	_ev("done")
	if _log != null:
		_log.flush()
	await _wait(5)
	get_tree().quit(0)


## 메인 메뉴에서 hold 프레임 머문 뒤 Start → 트랙 종류 선택(공식 트랙) → 트랙 선택에서 steps(+1=다음, -1=이전)대로 캐러셀을
## 넘기고(각 dwell 프레임), 목표 트랙이면 Play 를 누른다.
func _menu_to_track(track_id: String, hold: int, steps: Array, dwell: int) -> bool:
	await _wait_until(func(): return _scene_name() == "Main", 600, "Main")
	_park_mouse()
	_ev("main_menu")
	await _wait(hold)
	var start_btn: Control = _scene().get_node("Menu/StartButton")
	await _click_control(start_btn)
	if not await _wait_until(func(): return _scene_name() == "TrackKindSelect", 120, "TrackKind"):
		return false
	_park_mouse()
	await _wait(dwell)
	await _click_control(_scene().get("_official_card"))
	if not await _wait_until(func(): return _scene_name() == "TrackSelect", 120, "TrackSelect"):
		return false
	_park_mouse()
	_ev("track_select", {"track": str(_scene().call("_current_id"))})
	await _wait(dwell)
	for d in steps:
		var btn: Control = _scene().get("_next_button" if int(d) > 0 else "_prev_button")
		await _click_control(btn)
		_park_mouse()
		await _wait(2)
		_ev("carousel", {"dir": int(d), "track": str(_scene().call("_current_id"))})
		await _wait(dwell - 2)
	# 목표 트랙까지 남은 이동(키 없이 다음 버튼 클릭)
	for _i in range(20):
		if str(_scene().call("_current_id")) == track_id:
			break
		await _click_control(_scene().get("_next_button"))
		_park_mouse()
		await _wait(10)
	_ev("track_selected", {"track": str(_scene().call("_current_id"))})
	await _wait(20)
	await _click_control(_scene().get("_play_button"))
	_park_mouse()
	return await _wait_until(func(): return _gp() != null, 120, "Gameplay")


func _wait_go() -> void:
	await _wait_until(func(): return _state() == 1, 600, "go")


func _wait_finish_to_result(hold: int) -> void:
	await _wait_until(func(): return _gp() == null or _state() >= 2, 20000, "finish")
	auto_steer = false
	auto_gear = false
	auto_drift = false
	_release_steer()
	_key(K_DRIFT, false)
	_gear_release()
	# 줌아웃 중간(+0.5초)과 등급 문구가 완전히 떠오른 뒤(+1.6초)
	await _wait(29)
	await _still("finish_zoom")
	await _wait(64)
	await _still("finish_grade")
	await _wait_until(func(): return _scene_name() == "Result", 600, "Result")
	_ev("result_screen")
	await _wait(50)
	await _still("result")
	await _wait(hold)


# ---------------------------------------------------------------- 시나리오: heart(메뉴·깔끔한 완주)


func _scenario_heart() -> void:
	# 메인 메뉴 11초(오프라인 알림 토스트가 사라진 뒤 5초 이상) → 트랙 선택 캐러셀(cotton에서 다음 4번, 이전 3번) → heart_01
	if not await _menu_to_track("heart_01", 660, [1, 1, 1, 1, -1, -1, -1], 70):
		return
	_ev("gameplay")
	_still_when("countdown", func(): return _state() == 0 and _last_cd == 2, 1, 1, 400)
	await _wait_go()
	auto_steer = true
	auto_gear = true
	max_gear = 4
	_still_when(
		"curve",
		func():
			var p: Node = _player()
			return (
				p != null
				and absf(p.actual_steer) > 0.35
				and R.err(_gp()) < 10.0
				and _needle_tip() > -3.0
			),
		3,
		150,
		4000
	)
	await _wait_finish_to_result(300)


# ---------------------------------------------------------------- 시나리오: tee(가속·엄마·꿀밤·골무·부상)


func _scenario_tee() -> void:
	if not await _menu_to_track("tee_01", 30, [], 20):
		return
	_ev("gameplay")
	await _wait_go()
	auto_steer = true
	auto_gear = false
	# 1) 긴 직선(s 500~1450)에서 1→5단 가속(W 탭, 0.6초 간격)
	await _wait_until(func(): return _progress_s() >= 520.0, 2000, "s>=520")
	_ev("speedup_begin")
	for _g in range(4):
		await _tap(K_UP)
		await _wait(36)
	_ev("speedup_end")
	# 2) 엄마 찬스(s 1298) 자연 획득 → 자동 주행 → 복귀 후 자동 변속
	_still_when(
		"mom",
		func():
			var p: Node = _player()
			return p != null and p.autopilot_timer > 0.3 and p.autopilot_timer < 2.4,
		2,
		60,
		2000
	)
	await _wait_until(func(): return _player().autopilot_timer > 0.0, 2000, "mom")
	await _wait_until(func(): return _player().autopilot_timer <= 0.0, 600, "mom end")
	auto_gear = true
	max_gear = 3
	# 3) 사선 직선(s 2260~)에서 트랙 이탈 강제 복귀(우조향으로 heading을 틀고 키를 뗀 채 직진)
	await _wait_until(func(): return _progress_s() >= 2260.0, 3000, "s>=2260")
	auto_gear = false
	await _induce_bonk(1, 4)
	auto_gear = true
	# 4) 골무(s 2903) 자연 획득
	_still_when(
		"thimble",
		func(): return _player() != null and _player().thimble_timer > 0.0,
		2,
		60,
		3000
	)
	await _wait_until(func(): return _player().thimble_timer > 0.0, 3000, "thimble")
	# 5) 직선(s 3150~3850)에서 5단 좌우 급반전(실제 키 입력)으로 부상 A를 유도한다. 직선이 짧아 골무가
	#    끝나기 약 1초 전부터 시작한다(골무 중에는 RISK 가 0.95에서 멈추고, 골무가 끝나면 곧 부상한다).
	#    RISK 최대 → 놀란 눈·손 미끄러짐(0.20초) → 부상(밴드·> <·대사 말풍선) → 움찔 복귀.
	await _wait_until(func(): return _player().thimble_timer <= 1.3, 600, "thimble ending")
	auto_gear = false
	await _gear_to(5)
	await _induce_injury("A", 3850.0)
	# 대사 말풍선(약 4초)이 사라질 때까지 자동 주행. 부상 뒤 강제 복귀가 끼어들지 않았는지 events 로 본다.
	await _wait_until(func(): return _player().stun_timer <= 0.0, 300, "stun end")
	manual_override = false
	auto_gear = true
	max_gear = 3
	# 6) 두 번째 골무(s 4211)는 옆으로 비켜 간다(골무 면역이 부상 B 구간까지 이어지지 않게).
	lat_offset = 50.0
	lat_s0 = 4020.0
	lat_s1 = 4290.0
	await _wait_until(_toast_gone, 600, "dialogue A gone")
	_ev("dialogue_gone", {"s": snappedf(_progress_s(), 0.1)})
	# 7) 긴 직선(s 4600~5500)에서 부상 B.
	await _wait_until(func(): return _progress_s() >= 4640.0, 3000, "s>=4640")
	auto_gear = false
	await _gear_to(5)
	await _induce_injury("B", 5450.0)
	await _wait_until(func(): return _player().stun_timer <= 0.0, 300, "stun end")
	manual_override = false
	auto_gear = true
	await _wait_until(_toast_gone, 600, "dialogue B gone")
	await _wait(90)


## 하단 알림이 모두 사라졌는가(읽기 전용).
func _toast_gone() -> bool:
	var gp: Node = _gp()
	var pres: Node = gp.get_node_or_null("Presenter") if gp != null else null
	var t: Node = pres.get("_toast") if pres != null else null
	if t == null or t.get("_group") == null:
		return true
	return not (t.get("_group") as Control).visible


## 5단 + 드리프트 홀드 좌우 급반전으로 부상을 낸다(키 입력만). RISK 가 높아지거나 사전 연출이 시작되면
## 트랙 쪽으로 조향해 두어, 조작이 잠기는 스턴 동안 원단 밖으로 흘러 강제 복귀가 끼어드는 일을 줄인다.
## 스틸: 사전 연출 중간(놀란 눈·미끄러짐)과 대사 말풍선이 완전히 뜬 직후(부상 0.25초 뒤) 한 장씩.
func _induce_injury(tag: String, s_limit: float) -> bool:
	_still_when(
		"injury%s_slip" % tag,
		func():
			var p: Node = _player()
			return p != null and p.cut_pending_timer > 0.0 and p.cut_pending_timer <= 0.09,
		1,
		1,
		900
	)
	_still_when(
		"injury%s" % tag,
		func(): return _player() != null and _player().stun_timer > 0.0 and _player().stun_timer < 1.75,
		1,
		1,
		900
	)
	_ev("induce_injury_begin", {"tag": tag})
	manual_override = true
	var dir: int = 1
	var hit: bool = false
	for _i in range(80):
		var p: Node = _player()
		if p.stun_timer > 0.0:
			hit = true
			break
		if _progress_s() >= s_limit or p.offfabric_timer > 0.0:
			break
		if p.cut_pending_timer > 0.0:
			# 사전 연출(0.20초) 동안은 자동 조향으로 재봉선 쪽 heading 을 맞춰 둔다(스턴 중 이탈 방지).
			manual_override = false
			await _wait(1)
			continue
		var toward: int = _toward_track()
		var off_line: bool = R.err(_gp()) > 24.0 or absf(R.heading_err_deg(_gp())) > 18.0
		if off_line and toward != 0:
			dir = toward
		_steer_hold(dir)
		dir = -dir
		for _k in range(INJ_PERIOD):
			await _wait(1)
			if _player().stun_timer > 0.0 or _player().cut_pending_timer > 0.0:
				break
	manual_override = true
	_steer_hold(0)
	_ev("induce_injury_end", {"tag": tag, "hit": hit, "stun": _player().stun_timer})
	return hit


## 앞쪽 재봉선 지점을 향하는 조향 부호(+1=우, -1=좌, 0=정렬). 읽기 전용.
func _toward_track() -> int:
	var gp: Node = _gp()
	var p: Node2D = _player()
	if gp == null or p == null:
		return 0
	var tr: Object = gp.get("_track")
	var s: float = float(tr.query(p.position, int(gp.get("_hint")))["s"])
	var look: float = clampf(p.speed * 0.42, 42.0, 130.0)
	var tgt: Vector2 = tr.point_at_s(minf(s + look, tr.length))
	var herr: float = wrapf((tgt - p.position).angle() - p.heading, -PI, PI)
	if absf(herr) < 0.05:
		return 0
	return 1 if herr > 0.0 else -1


func _gear_to(target: int) -> void:
	for _i in range(8):
		var p: Node = _player()
		if p == null:
			return
		if p.stun_timer > 0.0 or p.offfabric_timer > 0.0:
			await _wait_until(
				func(): return _player().stun_timer <= 0.0 and _player().offfabric_timer <= 0.0,
				600,
				"unlock"
			)
			continue
		if p.speed_index == target:
			return
		await _tap(K_UP if p.speed_index < target else K_DOWN)
		await _wait(6)


## 트랙 이탈 강제 복귀(꿀밤)를 실제 조향 입력으로 발동한다(PlayDriver._induce_bonk 축약판).
func _induce_bonk(dir: int, gear: int) -> bool:
	manual_override = true
	_steer_hold(0)
	await _gear_to(gear)
	await _wait(20)
	var thr: float = R.reset_threshold(_gp())
	_ev("bonk_steer_begin", {"thr": thr})
	_steer_hold(dir)
	await _wait_until(
		func(): return absf(R.heading_err_deg(_gp())) >= BONK_RELEASE_DEG, 240, "bonk heading"
	)
	_steer_hold(0)
	_ev("bonk_steer_release")
	var hit: bool = await _wait_until(
		func(): return _player().offfabric_timer > 0.0, 900, "offfabric reset"
	)
	if not hit:
		manual_override = false
		return false
	_still_when("bonk", func(): return true, 1, 1, 10)
	await _wait(40)
	await _still("bonk_bubble")
	await _wait_until(func(): return _player().offfabric_timer <= 0.0, 200, "offfabric end")
	manual_override = false
	return true


# ---------------------------------------------------------------- 시나리오: star(드리프트)


func _scenario_star() -> void:
	if not await _menu_to_track("star_01", 30, [], 20):
		return
	_ev("gameplay")
	await _wait_go()
	auto_steer = true
	auto_gear = true
	auto_drift = true
	max_gear = 4
	_still_when(
		"drift",
		func():
			var p: Node = _player()
			return p != null and p.is_drifting and absf(p.actual_steer) > 0.6,
		3,
		120,
		6000
	)
	await _wait_finish_to_result(200)
