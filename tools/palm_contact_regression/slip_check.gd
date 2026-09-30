extends Node
## 부상 사전 연출(손 미끄러짐·놀란 눈·cut 뒤 움찔 복귀) 표현 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## 상태 주입 검사다: Gameplay 의 시뮬·표현 구동을 멈추고, 물리 틱 대신 player 의 pending/스턴 필드를
## PlayerController 규약(cut_pending_timer·is_cut_pending·cut_pending_progress)대로 직접 바꾼 뒤
## 손·Presenter 의 _process 를 정해진 dt 로 부른다(실제 입력 플레이 아님). 게임 안 처리 순서처럼 손이
## Presenter 보다 먼저 처리된다. 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const P: String = "res://assets/gfx/palm_contact/"
const HAND_FLAT: String = P + "hand_flat.png"
const CUT1: String = P + "handcut1_flat.png"
const CUT2: String = P + "handcut2_flat.png"
const CUT3: String = P + "handcut3_flat.png"
const THIMBLE: String = P + "hand_thimble_flat.png"
const CUT1_T: String = P + "handcut1_thimble_flat.png"
const DT: float = 1.0 / 60.0
# 화면 기준 기하(1280x720 캔버스). 바늘은 x=640, 노루발 불투명 영역은 presentation.md §15.2.
const NEEDLE_X: float = 640.0
const FOOT_RECT: Rect2 = Rect2(558.0, 299.0, 165.0, 174.0)
# 손(그림자 포함)이 바늘 x에서 이만큼 안쪽으로는 들어오지 않아야 한다(중앙 트랙 가시성 기준).
const NEEDLE_CLEAR: float = 60.0
# 엄지 끝(hand_flat.png 원본 (169,623) → 표시 사각형 로컬). 검지보다 위에서 노루발 옆면에 가깝다.
const THUMB_TIP: Vector2 = Vector2(-241.5, 34.8)
# 기존 눈(eyes_normal)과 놀란 눈(eyes_surprised)의 동공 중심(텍스처 비율, 1280x720 정규화 측정값).
const NORMAL_PUPILS: Array[Vector2] = [Vector2(453.4, 245.0), Vector2(827.0, 246.4)]
const SURPRISED_PUPILS: Array[Vector2] = [Vector2(479.4, 285.5), Vector2(848.4, 285.7)]
const MIN_PASSED: int = 181
const SECTIONS: Array[String] = [
	"wiring",
	"start",
	"progress",
	"cut",
	"selection",
	"cancel",
	"mom",
	"frame_independence",
	"max_combo",
	"face",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _gp: Node = null
var _pres: PresentationController = null
var _player: PlayerController = null
var _lh: HandView = null
var _rh: HandView = null
var _face: BackgroundFace = null
var _w: float = 0.2


func _ready() -> void:
	LeaderboardClient.tutorial_seen = true
	await _setup()
	_check_start_and_progress()
	_check_cut()
	_check_selection()
	_check_cancel()
	_check_mom()
	_check_frame_independence()
	_check_max_combo()
	_check_face()
	_ok(_done == SECTIONS, "all check sections ran to completion (%s)" % [_done])
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("slip regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


func _path(tex: Texture2D) -> String:
	return tex.resource_path if tex != null else "<null>"


func _setup() -> void:
	_gp = load("res://scenes/Gameplay.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_gp)
	await get_tree().process_frame
	await get_tree().process_frame
	_gp.set_physics_process(false)
	_gp.set_process(false)
	_pres = _gp.get_node("Presenter")
	_pres.set_process(false)
	_player = _gp.get_node("SimHost/FabricSource/World/Player")
	_lh = _gp.get_node("ForegroundLayer/LeftHand")
	_rh = _gp.get_node("ForegroundLayer/RightHand")
	_face = _gp.get_node("BackdropLayer/FaceView")
	for n in [_lh, _rh, _face]:
		n.set_process(false)
	_w = Tuning.cut_windup_duration
	_ok(_w > 0.1 and _w <= 0.3, "cut_windup_duration %.3f in (0.1, 0.3]" % _w)
	_ok(
		HandView.SLIP_RECOIL_DUR >= 0.12 and HandView.SLIP_RECOIL_DUR <= 0.18,
		"recoil duration %.3f in [0.12, 0.18]" % HandView.SLIP_RECOIL_DUR
	)
	_ok(_face.eyes_surprised != null, "FaceView.eyes_surprised wired")
	_ok(
		is_equal_approx(_face.eyes_offset_y, 50.0) and is_equal_approx(_face.eyes_scale, 0.9),
		"user eyes_offset_y 50 / eyes_scale 0.9 unchanged"
	)
	_ok(
		is_equal_approx(HandView.DISPLAY_SIZE.x / HandView.DISPLAY_SIZE.y, 4.0 / 3.0),
		"DISPLAY_SIZE keeps 4:3 (%s)" % HandView.DISPLAY_SIZE
	)
	_done.append("wiring")


## 새 런 상태: 손·표정·cut 단계 초기화, 고속 직진, pending/스턴 없음.
func _fresh(steer: float = 0.0, drift: bool = false) -> void:
	_player.stun_timer = 0.0
	_player.cut_pending_timer = 0.0
	_player.offfabric_timer = 0.0
	_player.thimble_timer = 0.0
	_player.autopilot_timer = 0.0
	_player.risk = 0.5
	_player.speed_index = 5
	_player.speed = 300.0
	_set_steer(steer, drift)
	_pres.reset_hands()
	_pres._mom_swipe = 0.0
	_pres._injury_shake = 0.0
	for h in [_lh, _rh]:
		h._swap = 0.0
		h._swap_target = 0.0
	_face.set_mom(false, 0.0)
	_face._bonk_t = -1.0
	_frame(DT)
	_settle(90)


func _set_steer(v: float, drift: bool) -> void:
	_player.target_steer = v
	_player.actual_steer = v
	_player.is_drifting = drift
	_player.drift_dir = v if drift else 0.0


## 렌더 한 프레임: 손·얼굴이 먼저, Presenter가 나중(Gameplay.tscn 트리 순서와 같다).
func _frame(dt: float) -> void:
	_lh._process(dt)
	_rh._process(dt)
	_face._process(dt)
	_pres._process(dt)


func _settle(n: int) -> void:
	for i in range(n):
		_frame(DT)


## pending 시작(risk MAX 틱)부터 i번째 물리 틱의 시뮬 상태를 주입한다(0 <= i < ticks).
func _pend_tick(i: int) -> void:
	_player.risk = 1.0
	_player.cut_pending_timer = _w - float(i) * DT


## cut 틱: pending 해제 + 기존 _trigger_cut 과 같은 결과.
func _cut_tick() -> void:
	_player.cut_pending_timer = 0.0
	_player.risk = 0.0
	_player.stun_timer = Tuning.stun_duration
	_player.speed_index = 1
	_player.speed = Tuning.speed_table[0]


func _ease(u: float) -> float:
	var v: float = clampf(u, 0.0, 1.0)
	return HandView.SLIP_EASE_LIN * v + (1.0 - HandView.SLIP_EASE_LIN) * v * v


func _ticks() -> int:
	return int(round(_w / DT))


## 1) pending 시작 프레임과 진행(1번째 cut = 오른손).
func _check_start_and_progress() -> void:
	_fresh(0.0)
	var stage0: int = _pres._cut_stage
	var r_tex: Texture2D = _rh.texture
	var ps0: float = _rh.press_scale()
	_pend_tick(0)
	_frame(DT)
	_ok(_player.is_cut_pending(), "pending injected")
	_ok(_pres._cut_stage == stage0, "start: band stage unchanged (%d)" % _pres._cut_stage)
	_ok(_pres.cut_count() == 0, "start: cut count unchanged")
	_ok(_pres._injury_shake == 0.0, "start: no injury shake (%.2f)" % _pres._injury_shake)
	_ok(_rh.texture == r_tex, "start: right hand texture unchanged")
	_ok(_rh.slip_offset().x < -0.1, "start: right (target) hand slips inward %s" % _rh.slip_offset())
	_ok(_lh.slip_offset() == Vector2.ZERO, "start: left hand no slip %s" % _lh.slip_offset())
	_ok(_face._state == BackgroundFace.FaceState.SURPRISED, "start: face SURPRISED")
	_ok(_face._fade_t == 1.0, "start: surprised snaps in (fade_t %.2f)" % _face._fade_t)
	_ok(_face.is_surprised(), "start: face.is_surprised()")
	_done.append("start")
	var xs: Array[float] = [-_rh.slip_offset().x]
	var ys: Array[float] = [_rh.slip_offset().y]
	for i in range(1, _ticks()):
		_pend_tick(i)
		_frame(DT)
		xs.append(-_rh.slip_offset().x)
		ys.append(_rh.slip_offset().y)
		_ok(_lh.slip_offset() == Vector2.ZERO, "progress %d: left stays 0" % i)
	var mono: bool = true
	var accel: bool = true
	for i in range(1, xs.size()):
		mono = mono and xs[i] > xs[i - 1]
		if i >= 2:
			accel = accel and (xs[i] - xs[i - 1]) >= (xs[i - 1] - xs[i - 2]) - 1e-3
	_ok(mono, "progress: inward offset strictly increases %s" % str(xs))
	_ok(accel, "progress: inward offset accelerates (ease-in)")
	var up_ok: bool = ys.all(
		func(y: float) -> bool: return y <= 0.0 and y >= -HandView.SLIP_MAX_UP - 1e-3
	)
	_ok(up_ok, "progress: vertical move up only, <= %.0f px %s" % [HandView.SLIP_MAX_UP, str(ys)])
	_ok(xs[xs.size() - 1] <= HandView.SLIP_MAX_IN + 1e-3, "progress: inward <= SLIP_MAX_IN")
	_ok(xs[xs.size() - 1] >= 20.0, "progress: final slip visible (%.1f px)" % xs[xs.size() - 1])
	_ok(is_equal_approx(_rh.press_scale(), ps0), "progress: slip keeps press scale (no squash)")
	_ok(_face._state == BackgroundFace.FaceState.SURPRISED, "progress: face stays SURPRISED")
	_done.append("progress")


## 2) cut(스턴 상승엣지): 밴드 +1, INJURED, 움찔(바깥) 후 0 복귀, 중복 없음.
func _check_cut() -> void:
	var stage0: int = _pres._cut_stage
	var before: Vector2 = _rh.slip_offset()
	_cut_tick()
	_frame(DT)
	_ok(_pres._cut_stage == stage0 + 1, "cut: band stage +1 (%d)" % _pres._cut_stage)
	_ok(_pres.cut_count() == 1, "cut: cut count 1")
	_ok(_pres._injury_shake > 0.0, "cut: injury shake fired")
	_ok(_path(_rh.texture) == CUT1, "cut: right hand shows handcut1")
	_ok(_face._state == BackgroundFace.FaceState.INJURED, "cut: face INJURED")
	_ok(not _face.is_surprised(), "cut: surprised cleared")
	_ok(_rh.slip_offset().is_equal_approx(before), "cut: recoil starts from contact position")
	var t: float = 0.0
	var max_out: float = 0.0
	var max_down: float = 0.0
	while t < HandView.SLIP_RECOIL_DUR + 3.0 * DT:
		_frame(DT)
		t += DT
		max_out = maxf(max_out, _rh.slip_offset().x)
		max_down = maxf(max_down, _rh.slip_offset().y)
		if t <= HandView.SLIP_RECOIL_DUR - DT:
			_ok(_rh.slip_offset() != Vector2.ZERO, "recoil t=%.3f still moving" % t)
	_ok(
		max_out >= HandView.SLIP_RECOIL_PX * 0.8 and max_out <= HandView.SLIP_RECOIL_PX + 1e-3,
		"recoil: outward flinch %.2f px (peak %.1f)" % [max_out, HandView.SLIP_RECOIL_PX]
	)
	_ok(max_down <= 3.0, "recoil: vertical flinch small (%.2f px)" % max_down)
	_ok(_rh.slip_offset() == Vector2.ZERO, "recoil: offset back to 0 after duration")
	_ok(_rh._slip_mode == HandView.SlipMode.NONE, "recoil: mode NONE")
	_settle(30)
	_ok(_pres._cut_stage == stage0 + 1, "cut: no duplicate stage while stun held")
	_ok(_pres.cut_count() == 1, "cut: no duplicate count while stun held")
	_done.append("cut")


## 한 번의 완전한 cut(pending→cut→스턴 해제). 대상 손을 돌려준다(pending 시작 프레임 기준).
func _full_cut() -> String:
	_player.stun_timer = 0.0
	_settle(5)
	_pend_tick(0)
	_frame(DT)
	var who: String = "none"
	var r: bool = _rh.slip_offset() != Vector2.ZERO
	var l: bool = _lh.slip_offset() != Vector2.ZERO
	if r and not l:
		who = "R"
	elif l and not r:
		who = "L"
	elif l and r:
		who = "both"
	for i in range(1, _ticks()):
		_pend_tick(i)
		_frame(DT)
	_cut_tick()
	_frame(DT)
	_settle(20)
	return who


## 3) 손 선택: 누적 cut 1·3·5=오른손, 2·4·6=왼손(밴드 배열 이후에도 홀짝 유지, 텍스처 불변).
func _check_selection() -> void:
	_fresh(0.0)
	var expect: Array[String] = ["R", "L", "R", "L", "R", "L"]
	var tex_expect: Array = [
		[CUT1, HAND_FLAT], [CUT1, CUT2], [CUT3, CUT2], [CUT3, CUT2], [CUT3, CUT2], [CUT3, CUT2]
	]
	for k in range(expect.size()):
		var who: String = _full_cut()
		_ok(who == expect[k], "selection cut %d -> %s (got %s)" % [k + 1, expect[k], who])
		_ok(_pres.cut_count() == k + 1, "selection cut %d count" % (k + 1))
		_ok(_pres._cut_stage == mini(k + 1, 3), "selection cut %d band stage capped" % (k + 1))
		_ok(
			_path(_rh.texture) == tex_expect[k][0] and _path(_lh.texture) == tex_expect[k][1],
			"selection cut %d textures R=%s L=%s" % [k + 1, _path(_rh.texture), _path(_lh.texture)]
		)
	_player.stun_timer = 0.0
	_done.append("selection")


## pending 을 n 틱 진행한 뒤 해제 콜백으로 끝낸다. 해제 뒤 오프셋·표정·단계를 확인한다.
func _cancel_case(tag: String, cancel: Callable, back_state: int) -> void:
	_fresh(0.5)
	_player.thimble_timer = 0.0
	var stage0: int = _pres._cut_stage
	for i in range(6):
		_pend_tick(i)
		_frame(DT)
	var peak: Vector2 = _rh.slip_offset()
	_ok(peak.x < -1.0, "%s: slipping before cancel %s" % [tag, peak])
	cancel.call()
	_frame(DT)
	_ok(not _player.is_cut_pending(), "%s: pending released" % tag)
	_ok(_rh._slip_mode == HandView.SlipMode.RELEASE, "%s: right hand RELEASE mode" % tag)
	_ok(absf(_rh.slip_offset().x) <= absf(peak.x) + 1e-3, "%s: release starts at slip pos" % tag)
	_ok(_pres._cut_stage == stage0, "%s: band stage unchanged" % tag)
	_ok(_pres.cut_count() == 0, "%s: no cut counted" % tag)
	_ok(_pres._injury_shake == 0.0 or tag == "offfabric", "%s: no injury shake" % tag)
	_ok(_path(_rh.texture) != CUT1 and _path(_rh.texture) != CUT1_T, "%s: no band texture" % tag)
	_ok(not _face.is_surprised(), "%s: surprised off" % tag)
	_ok(_face._state == back_state, "%s: face state %d (want %d)" % [tag, _face._state, back_state])
	var prev: float = absf(_rh.slip_offset().x)
	var mono: bool = true
	for i in range(int(ceil(HandView.SLIP_RELEASE_DUR / DT)) + 1):
		_frame(DT)
		mono = mono and absf(_rh.slip_offset().x) <= prev + 1e-4
		prev = absf(_rh.slip_offset().x)
	_ok(mono, "%s: release returns monotonically (no flinch)" % tag)
	_ok(_rh.slip_offset() == Vector2.ZERO, "%s: offset 0 after release" % tag)
	_ok(_lh.slip_offset() == Vector2.ZERO, "%s: left untouched" % tag)


## 4) cut 없이 해제: 골무·엄마 찬스·이탈 리셋·리셋(재시작)·완주 전 해제.
func _check_cancel() -> void:
	_cancel_case(
		"thimble",
		func() -> void:
			_player.cut_pending_timer = 0.0
			_player.thimble_timer = Tuning.thimble_duration
			_player.risk = 0.95,
		BackgroundFace.FaceState.FOCUS
	)
	var thimble_tex: String = _path(_rh.texture)
	_ok(thimble_tex == THIMBLE, "thimble: thimble texture kept after release (%s)" % thimble_tex)
	_cancel_case(
		"offfabric",
		func() -> void:
			_player.cut_pending_timer = 0.0
			_player.risk = 0.0
			_player.speed_index = 1
			_player.offfabric_timer = Tuning.reset_lockout,
		BackgroundFace.FaceState.INJURED
	)
	_ok(_face.is_bonk_active(), "offfabric: bonk played (> < override)")
	_player.offfabric_timer = 0.0
	# 리셋(재시작 경로): 즉시 0.
	_fresh(0.5)
	for i in range(8):
		_pend_tick(i)
		_frame(DT)
	_player.cut_pending_timer = 0.0
	_pres.reset_hands()
	_ok(_rh.slip_offset() == Vector2.ZERO, "reset: slip cleared immediately")
	_ok(not _face.is_surprised(), "reset: surprised cleared")
	_ok(_pres.cut_count() == 0 and _pres._cut_stage == 0, "reset: counters 0")
	_frame(DT)
	_ok(_rh.slip_offset() == Vector2.ZERO, "reset: no slip next frame")
	_done.append("cancel")


## 5) 엄마 찬스: pending 해제 → 아이 손 복귀, 엄마 손에는 미끄러짐이 전이되지 않음.
func _check_mom() -> void:
	_cancel_case(
		"mom",
		func() -> void:
			_player.cut_pending_timer = 0.0
			_player.autopilot_timer = 3.0,
		BackgroundFace.FaceState.FOCUS
	)
	# 교대가 끝날 때까지 진행(엄마 손 표시).
	for i in range(90):
		_frame(DT)
	_ok(_rh.mom_hand_visible() and _lh.mom_hand_visible(), "mom: mom hands visible")
	# 엄마 손이 보이는 중에 아이 손 미끄러짐 상태를 강제로 넣어도 엄마 손 오프셋은 변하지 않는다.
	var mom_off: Vector2 = _rh._mom_draw_offset() - _rh._jitter
	_rh.set_slip(1.0)
	_ok(_rh.slip_offset() != Vector2.ZERO, "mom: forced child slip non-zero")
	var mom_off2: Vector2 = _rh._mom_draw_offset() - _rh._jitter
	_ok(mom_off.is_equal_approx(mom_off2), "mom: slip not transferred to mom hand")
	var pl_off: Vector2 = _rh._player_draw_offset() - _rh._jitter
	_ok(
		(pl_off - (_rh._press_offset() + Vector2(_rh.player_hand_dx(), 0.0))).is_equal_approx(
			_rh.slip_offset()
		),
		"mom: player draw offset carries the slip"
	)
	_rh.release_slip(true)
	_player.autopilot_timer = 0.0
	for i in range(90):
		_frame(DT)
	_ok(_rh.player_hand_visible() and _rh.slip_offset() == Vector2.ZERO, "mom: child hand back, 0")
	_done.append("mom")


## 시뮬(60Hz 틱)과 렌더(dt)를 함께 진행하며 표본 시각(1/15초 배수)의 오른손 오프셋을 모은다.
func _timeline(dt: float) -> Array:
	_fresh(0.0)
	var out: Array = []
	var ticks_done: int = 0
	var cut_tick: int = _ticks()
	var t: float = 0.0
	var per: int = int(round((1.0 / 15.0) / dt))
	var frame_i: int = 0
	var total_frames: int = int(round(0.6 / dt))
	for f in range(total_frames):
		t = float(f) * dt
		# 이 프레임까지 실행된 물리 틱 수(틱 0 = pending 시작, 시각 0).
		var want: int = int(floor(t / DT + 1e-6))
		while ticks_done <= want:
			if ticks_done < cut_tick:
				_pend_tick(ticks_done)
			elif ticks_done == cut_tick:
				_cut_tick()
			ticks_done += 1
		_frame(dt)
		if frame_i % per == 0:
			out.append(_rh.slip_offset())
		frame_i += 1
	_player.stun_timer = 0.0
	return out


## 6) 프레임 독립성: 60/90/120Hz와 낮은 렌더 FPS(15)에서 같은 시각 오프셋 일치.
func _check_frame_independence() -> void:
	var dts: Array[float] = [1.0 / 60.0, 1.0 / 90.0, 1.0 / 120.0, 1.0 / 15.0]
	var runs: Array = []
	for dt in dts:
		runs.append(_timeline(dt))
	var n: int = runs[0].size()
	_ok(n >= 8, "frame independence: %d samples" % n)
	# 미끄러짐 구간은 렌더 시계가 [시뮬 경과, 시뮬 경과 + 1틱] 안에서 "이번 프레임 끝" 시각을 보여 주므로
	# 주사율마다 같은 시각의 값이 최대 1틱까지 다를 수 있다(60Hz와 15Hz는 같고, 90/120Hz는 틱 정렬에 따라
	# 1/180~1/120초 뒤진다). 허용 오차는 1틱 동안 곡선의 최대 기울기(c'(1) = 2 - SLIP_EASE_LIN)로 움직이는
	# 거리다. cut 이후(움찔·복귀)는 닫힌 형식이라 0.05px.
	var goal: float = runs[0][2].length() / _ease(2.0 / 15.0 / _w + DT / _w)
	var tol_slip: float = goal * (2.0 - HandView.SLIP_EASE_LIN) / _w * DT + 0.05
	var cut_k: int = int(round(_w * 15.0))
	var worst_slip: float = 0.0
	var worst_post: float = 0.0
	for j in range(1, runs.size()):
		_ok(runs[j].size() == n, "frame independence: dt %.4f sample count" % dts[j])
		for k in range(mini(n, runs[j].size())):
			var d: float = (runs[j][k] - runs[0][k]).length()
			if k < cut_k:
				worst_slip = maxf(worst_slip, d)
			else:
				worst_post = maxf(worst_post, d)
	_ok(
		worst_slip <= tol_slip,
		"frame independence: slip max diff %.3f px <= %.3f" % [worst_slip, tol_slip]
	)
	_ok(worst_post <= 0.05, "frame independence: recoil max diff %.4f px <= 0.05" % worst_post)
	_ok(runs[3][2].is_equal_approx(runs[0][2]), "frame independence: 15Hz == 60Hz mid-slip")
	var moved: bool = false
	for v in runs[0]:
		moved = moved or v.length() > 5.0
	_ok(moved, "frame independence: samples actually move")
	# 순서: 1/15초 표본 3개(0.2초 = cut 전)는 안쪽으로 커지고, 마지막은 0.
	for r in runs:
		_ok(
			r[1].x < r[0].x and r[2].x < r[1].x and r[r.size() - 1] == Vector2.ZERO,
			"frame independence: order slip->return %s" % [r.slice(0, 4)]
		)
	_done.append("frame_independence")


## 손 불투명 픽셀(그림자 포함)의 화면 좌표 극값. 원본 PNG를 4px 간격으로 샘플한다.
func _hand_extent(h: HandView, img: Image) -> Dictionary:
	var flip: float = -1.0 if h.mirror else 1.0
	var s: float = h.press_scale()
	var rect: Rect2 = HandView.display_rect()
	var pivot: Vector2 = rect.get_center() + rect.size * HandView.PRESS_PIVOT
	var off: Vector2 = h._press_offset() + h.slip_offset()
	var origin: Vector2 = off + Vector2(pivot.x * flip, pivot.y) * (1.0 - s)
	var iw: float = float(img.get_width())
	var ih: float = float(img.get_height())
	var inner: float = INF
	var in_foot: int = 0
	var shadow: Vector2 = HandView.CONTACT_SHADOW_FAR
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			if img.get_pixel(x, y).a < 0.5:
				continue
			var lp: Vector2 = rect.position + Vector2(x / iw, y / ih) * rect.size
			for so in [Vector2.ZERO, Vector2(shadow.x * flip, shadow.y)]:
				var q: Vector2 = lp + so
				var sp: Vector2 = h.position + origin + Vector2(q.x * flip * s, q.y * s)
				sp.x += HandView.JITTER_X * -flip
				inner = minf(inner, absf(sp.x - NEEDLE_X))
				if FOOT_RECT.grow(-2.0).has_point(sp):
					in_foot += 1
	return {"inner": inner, "in_foot": in_foot}


## 7) 최대 미끄러짐 + 최대 조향·드리프트(대상 손 누름 최대)와 반대 조향(이완)에서 손(그림자 포함)이
##    바늘 띠와 노루발 불투명 영역을 침범하지 않고, 손가락 끝이 목표 지점에서 멈춘다.
func _check_max_combo() -> void:
	var cases: Array = [
		["R drift max", _rh, 1.0, true, HAND_FLAT],
		["R relaxed", _rh, -1.0, false, CUT3],
		["L drift max", _lh, -1.0, true, CUT2],
		["L relaxed", _lh, 1.0, false, HAND_FLAT],
	]
	for c in cases:
		var h: HandView = c[1]
		_fresh(float(c[2]), bool(c[3]))
		h.set_slip(1.0)
		var tip: Vector2 = h.position + h._slip_tip_local()
		var thumb: Vector2 = h.position + h._press_point(THUMB_TIP, HandView.display_rect())
		thumb += h.slip_offset()
		var target: Vector2 = h.position + h._slip_target_local()
		_ok(
			absf(tip.x - target.x) <= 1.0 and tip.y >= target.y - 0.5,
			"%s: fingertip %s stops at target %s" % [c[0], tip, target]
		)
		_ok(
			absf(tip.x - NEEDLE_X) >= HandView.SLIP_TARGET_DX - 1.0,
			"%s: fingertip stays %.1f px from needle" % [c[0], absf(tip.x - NEEDLE_X)]
		)
		_ok(
			tip.y > FOOT_RECT.end.y or absf(tip.x - NEEDLE_X) > FOOT_RECT.size.x * 0.5,
			"%s: fingertip outside foot (%s)" % [c[0], tip]
		)
		_ok(
			absf(thumb.x - NEEDLE_X) > FOOT_RECT.size.x * 0.5 + 2.0,
			"%s: thumb %s beside foot, not under it" % [c[0], thumb]
		)
		var img: Image = Image.load_from_file(ProjectSettings.globalize_path(str(c[4])))
		var ext: Dictionary = _hand_extent(h, img)
		_ok(
			float(ext["inner"]) >= NEEDLE_CLEAR,
			"%s: hand+shadow keeps %.1f px from needle (>= %.0f)" % [c[0], ext["inner"], NEEDLE_CLEAR]
		)
		_ok(int(ext["in_foot"]) == 0, "%s: no hand pixel inside foot (%d)" % [c[0], ext["in_foot"]])
		h.release_slip(true)
	_done.append("max_combo")


## 8) 놀란 눈 정렬 rect·우선순위·크로스페이드.
func _check_face() -> void:
	_fresh(0.0)
	var rect: Rect2 = _face._face_rect()
	var eye: Rect2 = _face.eye_rect_for(rect)
	# 실제 그리기 경로(_state_eye_rect)의 rect로 정렬을 본다.
	var sur: Rect2 = _face._state_eye_rect(BackgroundFace.FaceState.SURPRISED, eye)
	_ok(BackgroundFace.surprised_eye_rect(eye) == sur, "face: surprised rect")
	for st in [
		BackgroundFace.FaceState.NORMAL,
		BackgroundFace.FaceState.FOCUS,
		BackgroundFace.FaceState.INJURED
	]:
		_ok(_face._state_eye_rect(st, eye) == eye, "face: state %d uses eye_rect" % st)
	var shift: Vector2 = (sur.position - eye.position) / eye.size
	_ok(shift.x < -0.01 and shift.y < -0.04, "face: surprised correction applied %s" % shift)
	var worst: float = 0.0
	for i in range(2):
		var pn: Vector2 = eye.position + NORMAL_PUPILS[i] / Vector2(1280.0, 720.0) * eye.size
		var ps: Vector2 = sur.position + SURPRISED_PUPILS[i] / Vector2(1280.0, 720.0) * sur.size
		worst = maxf(worst, pn.distance_to(ps))
	_ok(worst <= 1.5, "face: pupil centers match within %.2f px (<= 1.5)" % worst)
	# 우선순위: 부상 > 놀람 > 집중 > 평상, 꿀밤은 부상과 같은 오버라이드.
	_face.set_expression(1.0, false, 5)
	_face.set_surprised(true)
	_ok(_face._state == BackgroundFace.FaceState.SURPRISED, "face: surprised over focus")
	_ok(_face._fade_t == 1.0, "face: surprised entry snaps")
	_face.set_expression(1.0, true, 5)
	_ok(_face._state == BackgroundFace.FaceState.INJURED, "face: injured over surprised")
	_ok(_face._fade_from == BackgroundFace.FaceState.SURPRISED, "face: crossfade from surprised")
	_ok(_face._fade_t == 0.0, "face: injured uses existing crossfade")
	_face.set_surprised(false)
	_face.set_expression(0.0, false, 1)
	_face.set_surprised(true)
	_face.play_bonk()
	_ok(_face._state == BackgroundFace.FaceState.INJURED, "face: bonk overrides surprised")
	_face._bonk_t = BackgroundFace.BONK_EXPR_DUR - DT
	_face._process(2.0 * DT)
	_ok(_face._state == BackgroundFace.FaceState.SURPRISED, "face: bonk end refreshes to surprised")
	_face._bonk_t = -1.0
	_face.set_surprised(false)
	_ok(_face._state == BackgroundFace.FaceState.NORMAL, "face: surprised off returns NORMAL")
	_ok(_face._fade_t == 0.0, "face: surprised exit crossfades")
	_face._fade_t = 1.0
	_done.append("face")
