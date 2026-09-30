extends RefCounted
## 부상 대사 말풍선 + 손 미끄러짐·부상 연출 통합 실제 입력 플레이 시나리오. PlayDriver 가 호출한다.
## 조작은 PlayDriver 의 키·마우스·터치 주입(Input.parse_input_event)만 쓰고, 게임·토스트 상태는 읽기만 한다.
##
## --scenario=cutdlg  (1280×720 키보드): 메뉴 → tee_01 → 고속 급반전 부상 ①(연속 프레임) → 엄마 찬스
##   토스트 중 부상 ②(선점) → 강제 복귀(엄마 꾸중) 직후 부상 ③(선점) → 골무 중 급반전(부상 없음) →
##   부상 ④(사전 연출 중 Esc 일시정지·복귀) → 부상 ⑤(연속 갱신, 밴드 최대 이후) → pending 중 R 재시작 →
##   2회차 강제 복귀 + 완주 직전 부상 시도 → 완주 → 결과(제출 버튼은 누르지 않는다).
## --scenario=cutdlg_mobile (--touch-controls): 터치로 부상 1회 이상 + 강제 복귀 1회.
## --scenario=cutdlg_lowfps (--fixed-fps 15): 키보드로 부상 1회, 순서·집계·대사 1회 확인.
## --scenario=cutdlg_band: 부상 6회 연속(밴드 최대 이후 부상·대사 갱신, 4번째 사전 연출 중 일시정지).
## --scenario=cutdlg_finish [--finish-back=N]: 완주선 N px 앞 급반전(완주 직전·완주 틱 부상과 대사 정리).
##
## 기록: cutdlg_frames.csv(그리기 완료 시점마다 1행), events.txt 의 "CUTDLG" 줄(부상·대사 프레임과 문구),
## seq/cutN_* (pending 시작 3프레임 전 ~ 움찔 복귀 뒤까지 매 프레임 PNG).

const R: GDScript = preload("res://play_driver/PlayRead.gd")
const CUT_LINES: Array[String] = ["아얏!", "아파!", "아이고!"]
const PENALTY_TEXT: String = "이녀석, 제대로 해야지!"
const RING: int = 3  # pending 시작 전 보관 프레임 수
const SEQ_MAX: int = 48  # 부상 1회 연속 프레임 최대 수
const FACE_NAMES: Array[String] = ["NORMAL", "FOCUS", "INJURED", "SURPRISED"]


static func run(d: Node) -> void:
	var st: Dictionary = _new_state(d)
	RenderingServer.frame_post_draw.connect(func() -> void: _on_draw(d, st))
	var mode: String = d.scenario
	if mode == "cutdlg_mobile":
		await _mobile(d, st)
	elif mode == "cutdlg_finish":
		await _finish_only(d, st)
	elif mode == "cutdlg_band":
		await _band(d, st)
	elif mode == "cutdlg_lowfps":
		await _lowfps(d, st)
	else:
		await _desktop(d, st)
	_summary(d, st)
	st["log"].flush()


static func _new_state(d: Node) -> Dictionary:
	var f: FileAccess = FileAccess.open(d.out_dir + "/cutdlg_frames.csv", FileAccess.WRITE)
	f.store_line(
		(
			"frame,run,state,s,speed_idx,steer,risk,cut_pending,stun,cut_stage,cut_count,"
			+ "lh_slip_x,lh_slip_y,rh_slip_x,rh_slip_y,face,surprised,bonk,toast_visible,toast_text,"
			+ "toast_portrait,toast_alpha,toast_immediate,toast_queue,stats_cuts,thimble,autopilot,"
			+ "offfabric,paused"
		)
	)
	DirAccess.make_dir_recursive_absolute(d.out_dir + "/seq")
	return {
		"log": f,
		"ring": [],
		"ring_on": false,
		"seq_left": 0,
		"seq_no": 0,
		"seq_idx": 0,
		"prev_pending": false,
		"prev_stun": false,
		"prev_off": false,
		"prev_gen": -1,
		"injury_frames": [],
		"dialogue": [],
		"pending_starts": 0,
		"seen_scene": null,
		"cap_dialogue": 0,
		# --no-drift: 급반전 중 드리프트 키를 누르지 않는다(부상 뒤 원단 이탈을 줄여 연속 부상을 노린다).
		"no_drift": OS.get_cmdline_user_args().has("--no-drift"),
	}


static func _ev(d: Node, msg: String) -> void:
	d._ev("CUTDLG " + msg)


static func _toast(d: Node) -> Node:
	var gp: Node = d._gp()
	if gp == null:
		return null
	var pres: Node = gp.get_node_or_null("Presenter")
	return pres.get("_toast") if pres != null else null


static func _pres(d: Node) -> Node:
	var gp: Node = d._gp()
	return gp.get_node_or_null("Presenter") if gp != null else null


static func _stats_cuts(d: Node) -> int:
	var gp: Node = d._gp()
	if gp == null or gp.get("_stats") == null:
		return -1
	return int(gp.get("_stats").cuts)


## 토스트 현재 상태(읽기 전용): [보임, 대사, 초상화 파일, 알파, 즉시 항목, 큐 길이, 세대].
static func _toast_state(d: Node) -> Array:
	var t: Node = _toast(d)
	if t == null or t.get("_group") == null:
		return [false, "", "-", 0.0, false, 0, -1]
	var g: Control = t.get("_group")
	var pr: TextureRect = t.get("_portrait")
	var tex: String = "-"
	if pr != null and pr.visible and pr.texture != null:
		tex = pr.texture.resource_path.get_file()
	return [
		g.visible,
		str(t.get("_label").text),
		tex,
		g.modulate.a if g.visible else 0.0,
		bool(t.get("_immediate")),
		int(t.get("_queue").size()),
		int(t.get("_gen")),
	]


# ---------------------------------------------------------------- 그리기 완료 시점 기록


## 그리기가 끝날 때마다(화면에 나간 상태 그대로) 한 행을 쓰고 사건을 판정한다. 게임 상태는 읽기만 한다.
static func _on_draw(d: Node, st: Dictionary) -> void:
	var gp: Node = d._gp()
	if gp == null:
		st["prev_gen"] = -1
		return
	if st["seen_scene"] != gp:
		# 새 씬(시작·재시작): 엣지 기준을 새로 잡는다.
		st["seen_scene"] = gp
		st["prev_pending"] = false
		st["prev_stun"] = false
		st["prev_off"] = false
		st["prev_gen"] = -1
		_ev(d, "scene %s entered (restart check below)" % gp.name)
		st["check_fresh"] = 3
	var p: Node = gp.get("_player")
	var pres: Node = gp.get_node_or_null("Presenter")
	var lh: Node = gp.get_node_or_null("ForegroundLayer/LeftHand")
	var rh: Node = gp.get_node_or_null("ForegroundLayer/RightHand")
	var face: Node = gp.get_node_or_null("BackdropLayer/FaceView")
	if p == null or pres == null or lh == null or rh == null or face == null:
		return
	var ts: Array = _toast_state(d)
	var lo: Vector2 = lh.call("slip_offset")
	var ro: Vector2 = rh.call("slip_offset")
	var fs: int = int(face.get("_state"))
	var row: Array = [
		d.frame,
		d._run_index,
		d._state(),
		"%.1f" % d._progress_s(),
		p.speed_index,
		"%.3f" % p.actual_steer,
		"%.3f" % p.risk,
		"%.3f" % p.cut_pending_timer,
		"%.3f" % p.stun_timer,
		int(pres.get("_cut_stage")),
		int(pres.call("cut_count")),
		"%.1f" % lo.x,
		"%.1f" % lo.y,
		"%.1f" % ro.x,
		"%.1f" % ro.y,
		FACE_NAMES[fs] if fs >= 0 and fs < FACE_NAMES.size() else str(fs),
		int(bool(face.call("is_surprised"))),
		int(bool(face.call("is_bonk_active"))),
		int(ts[0]),
		'"%s"' % ts[1],
		ts[2],
		"%.3f" % ts[3],
		int(ts[4]),
		ts[5],
		_stats_cuts(d),
		"%.2f" % p.thimble_timer,
		"%.2f" % p.autopilot_timer,
		"%.2f" % p.offfabric_timer,
		int(d.get_tree().paused),
	]
	st["log"].store_line(",".join(row.map(func(x): return str(x))))
	if int(st.get("check_fresh", 0)) > 0:
		st["check_fresh"] = int(st["check_fresh"]) - 1
		if int(st["check_fresh"]) == 0:
			_ev(
				d,
				(
					"fresh scene state: pending=%.3f stun=%.2f cut_stage=%d slipL=%s slipR=%s face=%s"
					% [p.cut_pending_timer, p.stun_timer, int(pres.get("_cut_stage")), lo, ro, row[15]]
					+ (
						" surprised=%s toast_visible=%s toast_queue=%d"
						% [face.call("is_surprised"), ts[0], ts[5]]
					)
				)
			)
	_detect(d, st, p, ts, lo, ro, row)
	_ring_capture(d, st)


static func _detect(
	d: Node, st: Dictionary, p: Node, ts: Array, lo: Vector2, ro: Vector2, row: Array
) -> void:
	var pending: bool = p.cut_pending_timer > 0.0
	var stun: bool = p.stun_timer > 0.0
	var off: bool = p.offfabric_timer > 0.0
	if pending and not bool(st["prev_pending"]):
		st["pending_starts"] = int(st["pending_starts"]) + 1
		_ev(
			d,
			(
				"pending start #%d s=%.0f risk=%.3f thimble=%.2f autopilot=%.2f"
				% [st["pending_starts"], d._progress_s(), p.risk, p.thimble_timer, p.autopilot_timer]
			)
		)
		if bool(st["ring_on"]) and int(st["seq_left"]) == 0:
			_begin_seq(d, st)
	if not pending and bool(st["prev_pending"]) and not stun:
		_ev(d, "pending released without cut (thimble/mom/off-fabric/finish/restart?)")
	if stun and not bool(st["prev_stun"]):
		st["injury_frames"].append(d.frame)
		_ev(
			d,
			(
				"INJURY #%d frame=%d s=%.0f cut_stage=%s stats_cuts=%d slipL=%s slipR=%s face=%s"
				% [st["injury_frames"].size(), d.frame, d._progress_s(), row[9], row[24], lo, ro, row[15]]
			)
		)
	if off and not bool(st["prev_off"]):
		_ev(
			d,
			(
				"OFFFABRIC reset frame=%d stun=%.2f pending_before=%s toast=\"%s\" immediate=%s queue=%d"
				% [d.frame, p.stun_timer, st["prev_pending"], ts[1], ts[4], ts[5]]
			)
		)
	var gen: int = int(ts[6])
	if gen != int(st["prev_gen"]) and bool(ts[0]):
		var hurt: bool = CUT_LINES.has(ts[1]) and bool(ts[4])
		var last_inj: int = st["injury_frames"].back() if not st["injury_frames"].is_empty() else -1
		_ev(
			d,
			(
				"TOAST item frame=%d text=\"%s\" portrait=%s immediate=%s alpha=%.3f queue=%d"
				% [d.frame, ts[1], ts[2], ts[4], ts[3], ts[5]]
				+ (" HURT_LINE injury_frame=%d delta=%d" % [last_inj, d.frame - last_inj] if hurt else "")
			)
		)
		if hurt:
			st["dialogue"].append({"frame": d.frame, "text": ts[1], "injury": last_inj})
			var n: int = st["dialogue"].size()
			_cap_now(d, "play_dlg%02d_%s_t0" % [n, _line_tag(ts[1])])
			_cap_later(d, "play_dlg%02d_%s_t8" % [n, _line_tag(ts[1])], 8)
	st["prev_gen"] = gen
	st["prev_pending"] = pending
	st["prev_stun"] = stun
	st["prev_off"] = off


static func _line_tag(text: String) -> String:
	var i: int = CUT_LINES.find(text)
	return ["ayat", "apa", "aigo"][i] if i >= 0 else "other"


## 이 그리기의 화면을 바로 저장(뷰포트 텍스처는 다음 그리기 전까지 이 프레임 내용).
static func _cap_now(d: Node, name: String) -> void:
	var img: Image = d.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [d.out_dir, name])
	d._ev("capture %s" % name)


static func _cap_later(d: Node, name: String, delay: int) -> void:
	await d._wait(delay)
	await d._cap(name)


# ---------------------------------------------------------------- 부상 연속 프레임(링 버퍼)


static func _ring_capture(d: Node, st: Dictionary) -> void:
	if not bool(st["ring_on"]) and int(st["seq_left"]) == 0:
		return
	# 일시정지 중에는 화면이 멈춰 있으므로 15프레임마다 한 장만 남기고 연속 캡처 예산은 쓰지 않는다
	# (복귀 뒤 부상·움찔 복귀까지 담기 위해).
	if d.get_tree().paused and int(st["seq_left"]) > 0:
		st["paused_draws"] = int(st.get("paused_draws", 0)) + 1
		if int(st["paused_draws"]) % 15 == 1:
			_save_seq(d, st, d.get_viewport().get_texture().get_image(), d.frame)
		return
	var img: Image = d.get_viewport().get_texture().get_image()
	if int(st["seq_left"]) > 0:
		_save_seq(d, st, img, d.frame)
		st["seq_left"] = int(st["seq_left"]) - 1
		if int(st["seq_left"]) == 0:
			_ev(d, "seq cut%d done (%d frames)" % [st["seq_no"], st["seq_idx"]])
		return
	var ring: Array = st["ring"]
	ring.append([d.frame, img])
	while ring.size() > RING:
		ring.pop_front()


static func _begin_seq(d: Node, st: Dictionary) -> void:
	st["seq_no"] = int(st["seq_no"]) + 1
	st["seq_idx"] = 0
	for e in st["ring"]:
		_save_seq(d, st, e[1], int(e[0]))
	st["ring"] = []
	st["seq_left"] = SEQ_MAX - RING


static func _save_seq(d: Node, st: Dictionary, img: Image, f: int) -> void:
	var name: String = "seq/cut%d_%02d_f%05d" % [st["seq_no"], st["seq_idx"], f]
	img.save_png("%s/%s.png" % [d.out_dir, name])
	st["seq_idx"] = int(st["seq_idx"]) + 1


# ---------------------------------------------------------------- 조작(실제 입력만)


## 조향 반전 주기(프레임). 렌더 FPS 가 낮으면 프레임당 시간이 길어 같은 실시간(약 0.43초)이 되게 한다.
static func _period(d: Node) -> int:
	var dt: float = d.get_process_delta_time()
	if dt <= 0.0:
		dt = 1.0 / 60.0
	return maxi(2, int(round(0.433 / dt)))


## 고속 급반전(+드리프트)으로 RISK 를 올려 실제 부상을 유도한다. 부상(스턴 상승)·s 한계·반복 한도에서 끝.
## 연속 프레임 캡처(ring_on)를 켠 채 진행한다. 부상이 나면 true.
static func _reversals(
	d: Node, st: Dictionary, tag: String, s_limit: float, pause_in_pending: bool = false
) -> bool:
	_ev(d, "reversals %s start s=%.0f gear=%d" % [tag, d._progress_s(), d._player().speed_index])
	d.manual_override = true
	st["ring_on"] = true
	var dir: int = 1
	var hit: bool = false
	var paused_done: bool = false
	var drift_on: bool = false
	for _i in range(60):
		var p: Node = d._player()
		if p == null or d._gp() == null:
			break
		if p.stun_timer > 0.0:
			hit = true
			break
		if d._progress_s() >= s_limit or p.offfabric_timer > 0.0:
			break
		_drift(d, not bool(st.get("no_drift", false)))
		drift_on = true
		# 재봉선에서 멀어지면(오차 > 30px 또는 heading 이 25도 넘게 틀어짐) 트랙 쪽으로 조향해 이탈을 막고,
		# 그 밖에는 좌우를 번갈아 급반전한다(읽은 값으로 판단, 조작은 키·터치 입력만).
		var toward: int = _toward_track(d)
		var off_line: bool = R.err(d._gp()) > 30.0 or absf(R.heading_err_deg(d._gp())) > 25.0
		# RISK 가 높으면(곧 사전 연출·부상) 트랙 쪽으로 틀어 두어, 조작이 잠기는 스턴 동안 원단 밖으로
		# 흘러가 강제 복귀가 끼어드는 일을 줄인다.
		var near_cut: bool = p.risk >= 0.8 or p.cut_pending_timer > 0.0
		if (off_line or near_cut) and toward != 0:
			dir = toward
		d._steer_hold(dir)
		dir = -dir
		var per: int = _period(d)
		for _k in range(per):
			await d._wait(1)
			var q: Node = d._player()
			if q == null:
				break
			# 미끄러짐이 눈에 보이도록 사전 연출 중간(남은 시간 절반 이하)에서 멈춘다.
			var half: float = Tuning.cut_windup_duration * 0.5
			var mid: bool = q.cut_pending_timer > 0.0 and q.cut_pending_timer <= half
			if pause_in_pending and not paused_done and mid:
				paused_done = true
				await _pause_probe(d, "play_pause_pending", q)
			if q.stun_timer > 0.0:
				break
	if drift_on:
		_drift(d, false)
	d._steer_hold(0)
	d.manual_override = false
	# 움찔 복귀가 끝날 때까지 연속 캡처를 이어 간다(seq_left 가 소진될 때까지 링 버퍼는 멈춘다).
	st["ring_on"] = false
	st["ring"] = []
	var p2: Node = d._player()
	_ev(
		d,
		(
			"reversals %s end hit=%s s=%.0f stun=%.2f risk=%.3f"
			% [tag, hit, d._progress_s(), p2.stun_timer if p2 else -1.0, p2.risk if p2 else -1.0]
		)
	)
	return hit


## 앞쪽 재봉선 지점을 향하는 조향 부호(+1=우, -1=좌, 0=정렬). PlayDriver 자동 조향과 같은 계산(읽기 전용).
static func _toward_track(d: Node) -> int:
	var gp: Node = d._gp()
	var p: Node2D = d._player()
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


static func _drift(d: Node, on: bool) -> void:
	if d.steer_via_touch:
		var tc: Control = d._touch_controls()
		if tc != null:
			d._touch(1, tc.button_rect(4).get_center(), on)
	else:
		d._key(KEY_SHIFT, on)


## pending(사전 연출) 도중 Esc 일시정지: 정지 중 손·눈·토스트가 그대로인지 보고 복귀 후 이어짐을 본다.
static func _pause_probe(d: Node, name: String, p: Node) -> void:
	var gp: Node = d._gp()
	var rh: Node = gp.get_node("ForegroundLayer/RightHand")
	var lh: Node = gp.get_node("ForegroundLayer/LeftHand")
	var face: Node = gp.get_node("BackdropLayer/FaceView")
	await d._tap(KEY_ESCAPE, 1)
	await d._wait(3)
	var a: Array = _pause_snap(p, lh, rh, face)
	await d._cap(name + "_t3")
	await d._wait(40)
	var b: Array = _pause_snap(p, lh, rh, face)
	await d._cap(name + "_t43")
	_ev(
		d,
		(
			"PAUSE in pending paused=%s pending %.3f->%.3f slipL %s->%s slipR %s->%s face %s->%s frozen=%s"
			% [d.get_tree().paused, a[0], b[0], a[1], b[1], a[2], b[2], a[3], b[3], a == b]
		)
	)
	await d._tap(KEY_ESCAPE, 1)
	await d._wait(2)
	_ev(d, "PAUSE resumed paused=%s pending=%.3f" % [d.get_tree().paused, p.cut_pending_timer])


## 일시정지 확인용 스냅샷: pending 남은 시간, 양손 미끄러짐 오프셋, 표정 상태.
static func _pause_snap(p: Node, lh: Node, rh: Node, face: Node) -> Array:
	return [p.cut_pending_timer, lh.call("slip_offset"), rh.call("slip_offset"), face.get("_state")]


## 부상 뒤 스턴이 풀리길 기다렸다가 기어를 맞춘다.
static func _after_injury(d: Node, gear: int) -> void:
	await d._wait_until(
		func(): return d._player() == null or d._player().stun_timer <= 0.0, 400, "stun end"
	)
	await d._gear_to(gear)


# ---------------------------------------------------------------- 1280×720 키보드


static func _desktop(d: Node, st: Dictionary) -> void:
	if not await d._menu_to_gameplay("play_c_"):
		return
	d._run_index = 1
	await d._close_tutorial_if_any("play_c_")
	await d._wait_countdown("play_c_")
	_ev(d, "GO run1")
	d.auto_steer = true
	await d._wait(20)
	await d._gear_to(3)
	# ① 첫 긴 직선(s 400~1360)에서 5단 급반전 → 부상 1.
	await d._wait_until(func(): return d._progress_s() >= 560.0, 2400, "s>=560")
	await d._gear_to(5)
	await d._wait(10)
	await _reversals(d, st, "inj1", 1180.0)
	await _after_injury(d, 3)
	# ② 엄마 찬스(s 1298) 토스트가 떠 있는 동안 부상: 오토파일럿 중 5단 준비 → 끝나자마자 급반전.
	await d._wait_until(func(): return d._player().autopilot_timer > 0.0, 3000, "mom chance")
	await d._wait(20)
	await d._gear_to(5)
	await d._wait_until(func(): return d._player().autopilot_timer <= 0.0, 600, "mom end")
	await d._gear_to(5)
	_ev(d, "mom chance over; toast=%s" % [_toast_state(d)])
	await _reversals(d, st, "inj2_during_mom_toast", 2200.0)
	await _after_injury(d, 3)
	# ③ 강제 복귀(엄마 꾸중) 직후 부상: 사선 직선(s≈2260)에서 조향 후 직진으로 이탈 → 복귀 즉시 급반전.
	await d._wait_until(func(): return d._progress_s() >= 2260.0, 3000, "s>=2260")
	await d._induce_bonk("c1", 1, 4, false)
	await d._gear_to(5)
	_ev(d, "after bonk; toast=%s" % [_toast_state(d)])
	await _reversals(d, st, "inj3_during_scold", 2860.0)
	await _after_injury(d, 3)
	# 골무(s 2903): 활성 중 5단 급반전 → 부상·대사 없음.
	await d._wait_until(func(): return d._player().thimble_timer > 0.0, 3000, "thimble")
	await d._gear_to(5)
	var inj_before: int = st["injury_frames"].size()
	var max_risk: float = 0.0
	d.manual_override = true
	var dir: int = 1
	while d._player().thimble_timer > 0.6:
		_drift(d, true)
		d._steer_hold(dir)
		dir = -dir
		for _k in range(_period(d)):
			await d._wait(1)
			max_risk = maxf(max_risk, d._player().risk)
		if d._player().offfabric_timer > 0.0:
			break
	_drift(d, false)
	d._steer_hold(0)
	d.manual_override = false
	_ev(
		d,
		(
			"THIMBLE reversals: max risk=%.3f injuries during thimble=%d pending_starts=%d"
			% [max_risk, st["injury_frames"].size() - inj_before, st["pending_starts"]]
		)
	)
	await d._gear_to(3)
	await d._wait_until(func(): return d._player().thimble_timer <= 0.0, 600, "thimble end")
	await d._wait(30)
	# ④ 사전 연출 중 Esc 일시정지 → 복귀 → 부상 4(밴드 최대 이후).
	await d._gear_to(5)
	await _reversals(d, st, "inj4_pause_in_pending", d._progress_s() + 900.0, true)
	await _after_injury(d, 5)
	# ⑤ 연속 부상: 부상 4 대사가 아직 떠 있는 동안 곧바로 부상 5(대사 갱신). 표시 중 일시정지도 1회.
	await _reversals(d, st, "inj5_consecutive", d._progress_s() + 900.0)
	await d._wait(12)
	await d._tap(KEY_ESCAPE, 1)
	await d._wait(3)
	var ta: Array = _toast_state(d)
	await d._wait(40)
	var tb: Array = _toast_state(d)
	await d._cap("play_pause_dialogue_t43")
	_ev(
		d,
		(
			"PAUSE during dialogue alpha %.3f->%.3f text=\"%s\" frozen=%s"
			% [ta[3], tb[3], tb[1], ta == tb]
		)
	)
	await d._tap(KEY_ESCAPE, 1)
	await _after_injury(d, 5)
	# pending 중 R 재시작: 부상·대사 없이 새 씬으로(모든 상태 초기화).
	var run1_cuts: int = _stats_cuts(d)
	_ev(d, "run1 stats cuts=%d observed injuries=%d" % [run1_cuts, st["injury_frames"].size()])
	d.manual_override = true
	var restarted: bool = false
	dir = 1
	_drift(d, true)
	for _i in range(40):
		d._steer_hold(dir)
		dir = -dir
		var hit_pending: bool = await d._wait_until(
			func(): return d._player() != null and d._player().cut_pending_timer > 0.0,
			_period(d),
			"pending"
		)
		if hit_pending:
			await d._wait(4)
			_ev(d, "RESTART during pending=%.3f toast=%s" % [d._player().cut_pending_timer, _toast_state(d)])
			await d._cap("play_restart_pending_before")
			_drift(d, false)
			d._steer_hold(0)
			await d._tap(KEY_R, 2)
			restarted = true
			break
		if d._player().stun_timer > 0.0:
			await _after_injury(d, 5)
	_drift(d, false)
	d._steer_hold(0)
	d.manual_override = false
	if not restarted:
		_ev(d, "restart during pending not reached; restarting anyway")
		d.auto_steer = false
		await d._tap(KEY_R, 2)
	d.auto_steer = false
	await d._wait_until(func(): return d._gp() != null and d._state() == 0, 300, "restart countdown")
	await d._wait(4)
	await d._cap("play_restart_t4")
	d._run_index = 2
	d._prev.clear()
	var inj_run1: int = st["injury_frames"].size()
	await d._wait_countdown("play_c_r2_")
	_ev(d, "GO run2")
	d.auto_steer = true
	await d._gear_to(3)
	# 2회차: pending 중 원단 이탈 시도(긴 직선 s≈4660, 이탈 조향 도중 급반전) → 엄마 꾸중만.
	await d._wait_until(func(): return d._progress_s() >= 4640.0, 9000, "s>=4640")
	await _bonk_with_pending(d, st)
	await d._gear_to(3)
	await _finish_part(d, st, inj_run1, 330.0)


## 완주 직전 부상 시도: 완주선 back px 앞에서 5단 급반전을 완주선까지 이어 간다. 완주 줌아웃·결과
## 화면을 캡처하고 결과 cuts 를 관측 부상 수와 대조한다.
static func _finish_part(d: Node, st: Dictionary, inj_before: int, back: float) -> void:
	var track_len: float = float(d._gp().get("_track").length)
	await d._wait_until(func(): return d._progress_s() >= track_len - back, 6000, "final straight")
	await d._gear_to(5)
	st["ring_on"] = true
	await _reversals(d, st, "inj_finish", track_len + 100.0)
	await d._wait_until(func(): return d._gp() == null or d._state() >= 2, 1200, "finish")
	if d._gp() != null:
		var res: Dictionary = d._gp().get("_pending_result")
		var inj_run: int = st["injury_frames"].size() - inj_before
		_ev(
			d,
			(
				"FINISH stats cuts=%d result cuts=%s observed injuries this run=%d pending=%.3f stun=%.2f"
				% [
					_stats_cuts(d),
					res.get("cuts", "?"),
					inj_run,
					d._player().cut_pending_timer,
					d._player().stun_timer
				]
			)
		)
		d.auto_steer = false
		d._release_steer()
		await d._wait(2)
		await d._cap("play_finish_t2")
		await d._wait(20)
		await d._cap("play_finish_t22")
		await d._wait(60)
		await d._cap("play_finish_t82")
	await d._wait_until(func(): return d._scene_name() == "Result", 900, "Result")
	await d._wait(60)
	await d._cap("play_result")
	var rs: Node = d._scene()
	var stats_label: Label = rs.get("_stats_label") if rs != null else null
	_ev(
		d,
		(
			"RESULT scene=%s last_result cuts=%s stats_label=\"%s\""
			% [
				d._scene_name(),
				GameState.last_result.get("cuts", "?"),
				stats_label.text.replace("\n", " | ") if stats_label != null else "?"
			]
		)
	)



## 완주만 보는 짧은 시나리오: 3단 자동 조향으로 달리다 완주선 --finish-back=N(기본 280) px 앞에서
## 급반전(완주 틱 pending 확정 또는 완주 직전 부상과 대사 정리를 노린다).
static func _finish_only(d: Node, st: Dictionary) -> void:
	var back: float = 280.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--finish-back="):
			back = float(a.substr(14))
	if not await d._menu_to_gameplay("play_cf_"):
		return
	d._run_index = 1
	await d._close_tutorial_if_any("play_cf_")
	await d._wait_countdown("play_cf_")
	_ev(d, "GO finish back=%.0f" % back)
	d.auto_steer = true
	await d._gear_to(3)
	await _finish_part(d, st, 0, back)


## 조향으로 재봉선에서 벗어나는 도중(임계 부근) 급반전으로 RISK 를 올려 pending 과 강제 복귀가
## 겹치게 시도한다. 결과(겹쳤는지)는 사건 로그에 남는다.
static func _bonk_with_pending(d: Node, st: Dictionary) -> void:
	d.manual_override = true
	d._steer_hold(0)
	await d._gear_to(5)
	await d._wait(10)
	var thr: float = R.reset_threshold(d._gp())
	d._steer_hold(-1)
	await d._wait_until(
		func(): return absf(R.heading_err_deg(d._gp())) >= 40.0, 240, "turn out"
	)
	d._steer_hold(0)
	await d._wait_until(
		func(): return R.err(d._gp()) >= thr - 160.0 or d._player().offfabric_timer > 0.0, 900, "err"
	)
	_ev(d, "bonk+pending: wiggle from err=%.1f thr=%.1f" % [R.err(d._gp()), thr])
	st["ring_on"] = true
	var dir: int = -1
	_drift(d, true)
	for _i in range(40):
		if d._player().offfabric_timer > 0.0 or d._player().stun_timer > 0.0:
			break
		d._steer_hold(dir)
		dir = -dir
		await d._wait(maxi(2, _period(d) / 2))
	_drift(d, false)
	d._steer_hold(0)
	st["ring_on"] = false
	await d._wait_until(
		func(): return d._player().offfabric_timer > 0.0 or d._player().stun_timer > 0.0, 400, "reset"
	)
	await d._wait(8)
	await d._cap("play_r2_bonk_pending_t8")
	await d._wait_until(
		func(): return d._player().offfabric_timer <= 0.0 and d._player().stun_timer <= 0.0,
		400,
		"unlock"
	)
	d.manual_override = false


# ---------------------------------------------------------------- 연속 부상(밴드 최대 이후)


## 부상을 연달아 6회 일으킨다(스턴이 풀리자마자 5단 급반전). 3회 뒤로는 밴드 최대 단계 이후의 부상이고,
## 앞 대사가 떠 있는 동안 다음 부상이 나 대사가 갱신된다. 4번째는 사전 연출 중간에 Esc 일시정지.
static func _band(d: Node, st: Dictionary) -> void:
	if not await d._menu_to_gameplay("play_cb_"):
		return
	d._run_index = 1
	await d._close_tutorial_if_any("play_cb_")
	await d._wait_countdown("play_cb_")
	_ev(d, "GO band")
	d.auto_steer = true
	await d._wait(20)
	await d._gear_to(3)
	await d._wait_until(func(): return d._progress_s() >= 560.0, 2400, "s>=560")
	for k in range(6):
		await d._gear_to(5)
		var hit: bool = await _reversals(d, st, "band%d" % (k + 1), d._progress_s() + 900.0, k == 3)
		if hit:
			await d._wait(4)
			_ev(d, "band %d toast=%s stage=%d" % [k + 1, _toast_state(d), _pres(d).get("_cut_stage")])
		await _after_injury(d, 5)
		if d._player().offfabric_timer > 0.0:
			await d._wait_until(func(): return d._player().offfabric_timer <= 0.0, 300, "unlock")
	var cc: int = int(_pres(d).call("cut_count"))
	_ev(d, "band done stats cuts=%d presenter cut_count=%d" % [_stats_cuts(d), cc])


# ---------------------------------------------------------------- 모바일(터치)


static func _mobile(d: Node, st: Dictionary) -> void:
	d.steer_via_touch = true
	if not await d._menu_to_gameplay("play_cm_"):
		return
	d._run_index = 1
	await d._close_tutorial_if_any("play_cm_")
	await d._wait_countdown("play_cm_")
	_ev(d, "GO mobile window=%s" % DisplayServer.window_get_size())
	d.auto_steer = true
	await d._wait(20)
	await d._gear_to(3)
	await d._wait_until(func(): return d._progress_s() >= 560.0, 2400, "s>=560")
	await d._gear_to(5)
	await _reversals(d, st, "m_inj1", 1200.0)
	await _after_injury(d, 5)
	await _reversals(d, st, "m_inj2", 1250.0)
	await _after_injury(d, 3)
	await d._wait_until(func(): return d._progress_s() >= 2260.0, 4000, "s>=2260")
	await d._induce_bonk("cm", 1, 4, false)
	await d._wait(40)
	await d._cap("play_cm_after_bonk")


# ---------------------------------------------------------------- 저 FPS(--fixed-fps 15)


static func _lowfps(d: Node, st: Dictionary) -> void:
	if not await d._menu_to_gameplay("play_cl_"):
		return
	d._run_index = 1
	await d._close_tutorial_if_any("play_cl_")
	await d._wait_countdown("play_cl_")
	_ev(d, "GO lowfps delta=%.4f period=%d" % [d.get_process_delta_time(), _period(d)])
	d.auto_steer = true
	await d._wait(8)
	await d._gear_to(3)
	await d._wait_until(func(): return d._progress_s() >= 560.0, 800, "s>=560")
	await d._gear_to(5)
	await _reversals(d, st, "l_inj1", 1200.0)
	await d._wait(20)
	var pres: Node = _pres(d)
	_ev(
		d,
		(
			"LOWFPS injuries=%d dialogues=%d stats_cuts=%d presenter cut_count=%d"
			% [st["injury_frames"].size(), st["dialogue"].size(), _stats_cuts(d), pres.call("cut_count")]
		)
	)


static func _summary(d: Node, st: Dictionary) -> void:
	_ev(
		d,
		(
			"SUMMARY injuries=%d frames=%s dialogues=%d pending_starts=%d"
			% [st["injury_frames"].size(), st["injury_frames"], st["dialogue"].size(), st["pending_starts"]]
		)
	)
	for e in st["dialogue"]:
		_ev(d, "SUMMARY dialogue frame=%d injury=%d text=\"%s\"" % [e["frame"], e["injury"], e["text"]])
