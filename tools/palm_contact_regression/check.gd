extends Node
## 손 밀착 자세·바늘 연출 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## 검사 씬을 메인 씬으로 실행해 autoload(Tuning 등)를 활성 상태로 둔다.
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const P: String = "res://assets/gfx/palm_contact/"
const HAND_FLAT: String = P + "hand_flat.png"
const HAND_MOM: String = P + "hand_mom_flat.png"
const CUT1: String = P + "handcut1_flat.png"
const CUT2: String = P + "handcut2_flat.png"
const CUT3: String = P + "handcut3_flat.png"
const THIMBLE: String = P + "hand_thimble_flat.png"
const CUT1_T: String = P + "handcut1_thimble_flat.png"
const CUT2_T: String = P + "handcut2_thimble_flat.png"
const CUT3_T: String = P + "handcut3_thimble_flat.png"
const FOOT: String = P + "presser_foot_large.png"
const HAND_FILES: Array[String] = [
	HAND_FLAT, HAND_MOM, CUT1, CUT2, CUT3, THIMBLE, CUT1_T, CUT2_T, CUT3_T
]
# 프레임 독립성 검사에 쓰는 dt(60/90/120Hz).
const NEEDLE_DTS: Array[float] = [1.0 / 60.0, 1.0 / 90.0, 1.0 / 120.0]

var _passed: int = 0
var _failed: int = 0
var _gp: Node = null
var _pres: Node = null
var _lh: HandView = null
var _rh: HandView = null
# 얼굴 하단 절단 경계의 최악(가장 위) 화면 y와 수평선 y(_check_face_cut이 기록, 꿀밤 검사가 재사용).
var _face_cut_worst: float = INF
var _face_horizon_y: float = 0.0


func _ready() -> void:
	# 튜토리얼 오버레이는 메모리상 플래그로 끈다(사본 user dir 도 격리돼 있다).
	LeaderboardClient.tutorial_seen = true
	_check_texture_sizes()
	await _check_scene_wiring()
	_check_hand_states()
	_check_mom_swap()
	_check_mom_null_texture()
	_check_press_scale()
	_check_needle(1.0 / 60.0, 0.0)
	_check_needle(1.0 / 60.0, 300.0)
	_check_needle(1.0 / 120.0, 150.0)
	_check_needle_frame_independence()
	_check_needle_slow_park()
	_check_needle_extreme_delta()
	_check_foot_alignment()
	_check_face_cut()
	_check_bonk()
	print("palm regression: %d passed, %d failed" % [_passed, _failed])
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


func _expect_hands(step: String, right: String, left: String) -> void:
	_ok(_path(_rh.texture) == right, "%s: right=%s (got %s)" % [step, right, _path(_rh.texture)])
	_ok(_path(_lh.texture) == left, "%s: left=%s (got %s)" % [step, left, _path(_lh.texture)])


## 2) 손 변형 9종(엄마 포함) 크기 동일, 표시 사각형 고정.
func _check_texture_sizes() -> void:
	var first: Vector2 = Vector2.ZERO
	for i in range(HAND_FILES.size()):
		var tex: Texture2D = load(HAND_FILES[i]) as Texture2D
		_ok(tex != null, "load %s" % HAND_FILES[i])
		if tex == null:
			continue
		if i == 0:
			first = tex.get_size()
		_ok(
			tex.get_size() == first,
			"size %s == %s (got %s)" % [HAND_FILES[i], first, tex.get_size()]
		)
	_ok(HandView.DISPLAY_SIZE == Vector2(630.0, 472.5), "HandView.DISPLAY_SIZE == 630x472.5")
	_ok(
		HandView.display_rect() == Rect2(-315.0, -236.25, 630.0, 472.5),
		"HandView.display_rect() == centered 630x472.5"
	)
	# 엄마(어른) 손: 같은 중심, 같은 비율, 아이 손보다 조금 더 크게.
	var mom: Rect2 = HandView.mom_display_rect()
	_ok(HandView.MOM_HAND_SCALE > 1.0, "HandView.MOM_HAND_SCALE > 1 (%s)" % HandView.MOM_HAND_SCALE)
	_ok(
		mom.size.x > HandView.DISPLAY_SIZE.x and mom.size.y > HandView.DISPLAY_SIZE.y,
		"mom_display_rect larger than DISPLAY_SIZE (%s)" % mom.size
	)
	_ok(mom.get_center().is_zero_approx(), "mom_display_rect centered on node origin")
	_ok(
		is_equal_approx(mom.size.x * HandView.DISPLAY_SIZE.y, mom.size.y * HandView.DISPLAY_SIZE.x),
		"mom_display_rect keeps DISPLAY_SIZE aspect"
	)
	# 원본 캔버스 종횡비 보존(가로·세로 같은 배율): DISPLAY.x * tex.h == DISPLAY.y * tex.w.
	_ok(
		is_equal_approx(HandView.DISPLAY_SIZE.x * first.y, HandView.DISPLAY_SIZE.y * first.x),
		"HandView.DISPLAY_SIZE keeps texture aspect %s" % first
	)
	_ok(HandView.JITTER_Y <= 0.5, "HandView.JITTER_Y <= 0.5")


## 4) Gameplay 씬 배선.
func _check_scene_wiring() -> void:
	_gp = load("res://scenes/Gameplay.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_gp)
	await get_tree().process_frame
	await get_tree().process_frame
	# 시뮬·표현 구동을 멈춰 검사가 손 상태를 직접 제어한다.
	_gp.set_physics_process(false)
	_gp.set_process(false)
	_pres = _gp.get_node("Presenter")
	_pres.set_process(false)
	_lh = _gp.get_node("ForegroundLayer/LeftHand")
	_rh = _gp.get_node("ForegroundLayer/RightHand")
	var nv: NeedleView = _gp.get_node("ForegroundLayer/NeedleView")
	_expect_hands("scene wiring", HAND_FLAT, HAND_FLAT)
	_ok(_lh.mirror and not _rh.mirror, "left hand mirror=true, right hand mirror=false")
	_ok(
		_lh.position == Vector2(256.0, 392.0), "LeftHand position (256,392) (got %s)" % _lh.position
	)
	_ok(
		_rh.position == Vector2(1024.0, 392.0),
		"RightHand position (1024,392) (got %s)" % _rh.position
	)
	_ok(_lh.scale == Vector2.ONE and _rh.scale == Vector2.ONE, "hand scale 1.0")
	_ok(
		_path(nv.foot_texture) == FOOT,
		"NeedleView.foot_texture == %s (got %s)" % [FOOT, _path(nv.foot_texture)]
	)
	_ok(
		_path(nv.needle_texture) == "res://assets/gfx/needle.png",
		"NeedleView.needle_texture == needle.png"
	)
	_ok(_path(_lh.mom_texture) == HAND_MOM, "LeftHand.mom_texture == hand_mom_flat.png")
	_ok(_path(_rh.mom_texture) == HAND_MOM, "RightHand.mom_texture == hand_mom_flat.png")
	# Presenter 배선 경로가 새 에셋인지.
	var cuts: Array[Texture2D] = _pres.cut_hand_textures
	var cut_paths: Array[String] = [CUT1, CUT2, CUT3]
	var thimble_paths: Array[String] = [CUT1_T, CUT2_T, CUT3_T]
	_ok(cuts.size() == 3, "cut_hand_textures has 3 entries")
	for i in range(mini(cuts.size(), 3)):
		_ok(_path(cuts[i]) == cut_paths[i], "cut_hand_textures[%d] == %s" % [i, cut_paths[i]])
		_ok(
			_path(_pres.thimble_cut_textures[i]) == thimble_paths[i],
			"thimble_cut_textures[%d] == %s" % [i, thimble_paths[i]]
		)
	_ok(_path(_pres.right_thimble_base) == THIMBLE, "right_thimble_base == hand_thimble_flat.png")
	_ok(_path(_pres.left_thimble_base) == THIMBLE, "left_thimble_base == hand_thimble_flat.png")


## 1) 손 상태 전환과 복원.
func _check_hand_states() -> void:
	var rect0: Rect2 = HandView.display_rect()
	_pres.reset_hands()
	_expect_hands("default", HAND_FLAT, HAND_FLAT)
	# 부상 전 골무 조합.
	_thimble(true)
	_expect_hands("stage0 thimble on", THIMBLE, THIMBLE)
	_thimble(false)
	_expect_hands("stage0 thimble off", HAND_FLAT, HAND_FLAT)
	# 부상 1: 우측 손.
	_pres._advance_cut_stage()
	_expect_hands("cut1", CUT1, HAND_FLAT)
	_thimble(true)
	_expect_hands("cut1 thimble on", CUT1_T, THIMBLE)
	_thimble(false)
	_expect_hands("cut1 thimble off", CUT1, HAND_FLAT)
	# 부상 2: 좌측 손.
	_pres._advance_cut_stage()
	_expect_hands("cut2", CUT1, CUT2)
	_thimble(true)
	_expect_hands("cut2 thimble on", CUT1_T, CUT2_T)
	_thimble(false)
	_expect_hands("cut2 thimble off", CUT1, CUT2)
	# 부상 3: 우측 손.
	_pres._advance_cut_stage()
	_expect_hands("cut3", CUT3, CUT2)
	_thimble(true)
	_expect_hands("cut3 thimble on", CUT3_T, CUT2_T)
	_thimble(false)
	_expect_hands("cut3 thimble off", CUT3, CUT2)
	# 4번째 부상은 무시된다.
	_pres._advance_cut_stage()
	_expect_hands("cut4 ignored", CUT3, CUT2)
	# 엄마 진입/복귀: 골무 off 상태와 on 상태 모두.
	for thimble_on in [false, true]:
		var tag: String = "mom(thimble=%s)" % thimble_on
		_thimble(thimble_on)
		var before_r: Texture2D = _rh.texture
		var before_l: Texture2D = _lh.texture
		_mom(true, thimble_on)
		_ok(_pres._mom_swipe == 1.0, "%s enter reaches swipe 1" % tag)
		_ok(
			_rh.texture == before_r and _lh.texture == before_l,
			"%s enter keeps player textures" % tag
		)
		_ok(_rh._mom_swipe == 1.0 and _lh._mom_swipe == 1.0, "%s hands swipe=1" % tag)
		_mom(false, thimble_on)
		_ok(_pres._mom_swipe == 0.0, "%s exit reaches swipe 0" % tag)
		_ok(_rh._mom_swipe == 0.0 and _lh._mom_swipe == 0.0, "%s hands swipe=0" % tag)
		_ok(_rh.texture == before_r and _lh.texture == before_l, "%s exit restores textures" % tag)
	_thimble(false)
	_expect_hands("after mom, thimble off", CUT3, CUT2)
	# 리셋.
	_pres.reset_hands()
	_expect_hands("reset_hands", HAND_FLAT, HAND_FLAT)
	_ok(_pres._cut_stage == 0, "reset_hands cut_stage == 0")
	_ok(HandView.display_rect() == rect0, "display_rect unchanged after all states")


## 1b) 엄마 찬스 손 교대: 두 캐릭터 손이 동시에 화면에 보이지 않고, 각 손은 자기 쪽 가장자리로
## 퇴장·등장하며, 방향 반전 시 연속이고, 끝나면 플레이어 텍스처가 복원된다. HandView._process를
## 고정 dt로 직접 호출해 결정적으로 진행한다.
func _check_mom_swap() -> void:
	_pres.reset_hands()
	_pres._advance_cut_stage()
	_thimble(true)
	var before_r: Texture2D = _rh.texture
	var before_l: Texture2D = _lh.texture
	var steps: int = 20
	var dt: float = HandView.MOM_SWAP_TIME / steps
	var both_ok: bool = true
	var dir_ok: bool = true
	var vis_ok: bool = true
	var prev_pl: float = 0.0
	var prev_pr: float = 0.0
	var prev_ml: float = -1e9
	var prev_mr: float = 1e9
	for h in [_lh, _rh]:
		h.set_mom(true, 0.0)
		h.set_mom(true, 0.3)  # 증가 → 진입 목표
	for i in range(steps + 1):
		if i > 0:
			_lh._process(dt)
			_rh._process(dt)
		for h in [_lh, _rh]:
			if _hand_on_screen(h, false) and _hand_on_screen(h, true):
				both_ok = false
			# 그리는 쪽이 아닌 손은 화면 밖이어야 한다(그리지 않는 구간).
			if not h.player_hand_visible() and not h.mom_hand_visible():
				vis_ok = vis_ok and not _hand_on_screen(h, false) and not _hand_on_screen(h, true)
		# 퇴장 구간: 좌측 손 x 감소, 우측 손 x 증가. 등장 구간: 엄마 손이 바깥에서 안쪽으로.
		var pl: float = _lh.player_hand_dx()
		var pr: float = _rh.player_hand_dx()
		var ml: float = _lh.mom_hand_dx()
		var mr: float = _rh.mom_hand_dx()
		if pl > prev_pl + 0.001 or pr < prev_pr - 0.001 or pl > 0.001 or pr < -0.001:
			dir_ok = false
		if ml < prev_ml - 0.001 or mr > prev_mr + 0.001 or ml > 0.001 or mr < -0.001:
			dir_ok = false
		prev_pl = pl
		prev_pr = pr
		prev_ml = ml
		prev_mr = mr
	_ok(both_ok, "mom swap: player/mom hands never on screen together (0..1, %d steps)" % steps)
	_ok(vis_ok, "mom swap: undrawn hands are off screen")
	_ok(dir_ok, "mom swap: left hand exits/enters via left edge, right via right edge")
	_ok(_rh.swap_progress() == 1.0 and _rh.mom_hand_visible(), "mom swap: hold shows mom only")
	_ok(
		is_zero_approx(_rh.mom_hand_dx()) and is_zero_approx(_lh.mom_hand_dx()),
		"mom swap: mom hands settle in place"
	)
	_ok(
		_rh.texture == before_r and _lh.texture == before_l,
		"mom swap: player textures untouched during hold"
	)
	# hold 중 부상·골무 상태 변경 → 복귀 후 새 상태가 보여야 한다.
	_pres._advance_cut_stage()
	_thimble(false)
	var want_r: Texture2D = _rh.texture
	var want_l: Texture2D = _lh.texture
	_ok(_path(want_l) == CUT2, "mom swap: cut during hold applied to left texture")
	# 복귀 도중 방향 반전: 연속성(한 스텝 이동량 상한) 확인.
	for h in [_lh, _rh]:
		h.set_mom(true, 1.0)
		h.set_mom(true, 0.9)  # 감소 → 복귀 목표
	var cont_ok: bool = true
	var last: float = _rh.swap_progress()
	var max_step: float = dt / HandView.MOM_SWAP_TIME + 1e-4
	for i in range(30):
		if i == 8:
			for h in [_lh, _rh]:
				h.set_mom(true, 0.95)  # 다시 증가 → 진입 목표
		if i == 14:
			for h in [_lh, _rh]:
				h.set_mom(true, 0.5)  # 다시 감소
		_lh._process(dt)
		_rh._process(dt)
		var p: float = _rh.swap_progress()
		if absf(p - last) > max_step:
			cont_ok = false
		last = p
		if _hand_on_screen(_rh, false) and _hand_on_screen(_rh, true):
			cont_ok = false
	_ok(cont_ok, "mom swap: reversal keeps progress continuous")
	for h in [_lh, _rh]:
		h.set_mom(false, 0.0)
	for i in range(steps + 2):
		_lh._process(dt)
		_rh._process(dt)
	_ok(_rh.swap_progress() == 0.0 and _rh.player_hand_visible(), "mom swap: back to player hand")
	_ok(
		is_zero_approx(_rh.player_hand_dx()) and is_zero_approx(_lh.player_hand_dx()),
		"mom swap: player hands settle in place"
	)
	_ok(
		_rh.texture == want_r and _lh.texture == want_l,
		"mom swap: player textures reflect state changed during hold"
	)
	_pres.reset_hands()


## 1b-2) 엄마 손 텍스처가 없으면(mom_texture=null) 교대하지 않는다: 엄마 활성(swipe 1)으로 교대
## 시간을 충분히 넘겨 진행해도 매 프레임 플레이어 손이 제자리(오프셋 0)에 보인다.
func _check_mom_null_texture() -> void:
	var dt: float = 1.0 / 60.0
	for mirrored in [false, true]:
		var tag: String = "mom null texture (mirror=%s)" % mirrored
		var h: HandView = HandView.new()
		h.mirror = mirrored
		h.position = Vector2(256.0 if mirrored else 1024.0, 392.0)
		h.mom_texture = null
		add_child(h)
		h.set_process(false)
		h.set_mom(true, 0.3)
		var always_player: bool = true
		for i in range(int(3.0 * HandView.MOM_SWAP_TIME / dt)):
			if i == 5:
				h.set_mom(true, 1.0)
			h._process(dt)
			if not h.player_hand_visible() or h.mom_hand_visible():
				always_player = false
			if not is_zero_approx(h.player_hand_dx()):
				always_player = false
		_ok(always_player, "%s: player hand drawn in place every frame" % tag)
		_ok(h._swap_target == 1.0, "%s: mom swap was requested (target %.1f)" % [tag, h._swap_target])
		_ok(
			h.swap_progress() == 0.0 and h.player_hand_visible() and not h.mom_hand_visible(),
			"%s: swap progress stays 0" % tag
		)
		_ok(is_zero_approx(h.player_hand_dx()), "%s: player hand offset 0" % tag)
		h.queue_free()


## 1c) 조향·드리프트 누름 확대: 조향 방향 손은 눈에 보이게(기존 1.015보다 크게) 커지고, 드리프트
## 방향 손은 그보다 더 커지며, 반대(이완) 손은 1 이하로 약간만 줄어든다. 드리프트 반대 손은 증폭하지
## 않는다. 조향을 한 프레임에 반대로 뒤집어도 확대율이 STEER_LERP 보간을 따라 연속으로 변한다.
## 최대 드리프트에서 손끝(사각형 안쪽 끝에서 폭의 0.1배 안쪽 지점)의 안쪽 이동이 노루발 간격 예산
## (기본 자세 가로 간격 약 50px - 최소 10px) 안에 든다.
func _check_press_scale() -> void:
	var dt: float = 1.0 / 60.0
	var hands: Array[HandView] = [_lh, _rh]
	# 우조향(steer=+1): 우측 손(mirror=false)이 누르고 좌측 손이 이완한다.
	_settle_press(1.0, false, 0.0, dt)
	var steer_s: float = _rh.press_scale()
	var relax_s: float = _lh.press_scale()
	_ok(steer_s > 1.015, "press scale: steer max %.4f > old 1.015" % steer_s)
	_ok(steer_s >= 1.12 and steer_s <= 1.14, "press scale: steer max %.4f in [1.12, 1.14]" % steer_s)
	_ok(relax_s <= 1.0 and relax_s >= 0.94, "press scale: relaxed hand %.4f in [0.94, 1]" % relax_s)
	_ok(1.0 - relax_s < steer_s - 1.0, "press scale: relax shrink smaller than steer grow")
	# 우드리프트: 우측 손만 추가 확대, 좌측(반대) 손은 증폭 없이 이완 그대로.
	_settle_press(1.0, true, 1.0, dt)
	var drift_s: float = _rh.press_scale()
	_ok(drift_s > steer_s, "press scale: drift max %.4f > steer max %.4f" % [drift_s, steer_s])
	_ok(drift_s >= 1.20 and drift_s <= 1.23, "press scale: drift max %.4f in [1.20, 1.23]" % drift_s)
	_ok(
		is_equal_approx(_lh.press_scale(), relax_s),
		"press scale: drift opposite hand not boosted (%.4f)" % _lh.press_scale()
	)
	_ok(
		drift_s <= HandView.max_press_scale() + 1e-4,
		"press scale: drift max within max_press_scale %.4f" % HandView.max_press_scale()
	)
	# 좌측도 대칭.
	_settle_press(-1.0, true, -1.0, dt)
	_ok(
		is_equal_approx(_lh.press_scale(), drift_s) and is_equal_approx(_rh.press_scale(), relax_s),
		"press scale: left drift mirrors right (L %.4f R %.4f)" % [_lh.press_scale(), _rh.press_scale()]
	)
	# 연속성: 최대 좌드리프트 → 한 프레임에 최대 우조향으로 뒤집어도 프레임당 변화가 보간 상한 이내.
	var max_step: float = 0.0
	var prev: Array[float] = [_lh.press_scale(), _rh.press_scale()]
	for h in hands:
		h.set_steer(1.0)
		h.set_drift(false, 0.0)
	var lerp_k: float = clampf(HandView.STEER_LERP * dt, 0.0, 1.0)
	# 한 프레임 보간량: 조향 press가 2(-1→1) 범위를 가장 큰 기울기(PRESS_SCALE)로, 드리프트가 1 범위를
	# DRIFT_SCALE로 움직일 때의 상한. 순간 이동(보간 무시)이면 이 값을 넘는다.
	var span: float = 2.0 * HandView.PRESS_SCALE + HandView.DRIFT_SCALE
	for i in range(60):
		for k in range(2):
			hands[k]._process(dt)
			max_step = maxf(max_step, absf(hands[k].press_scale() - prev[k]))
			prev[k] = hands[k].press_scale()
	_ok(
		max_step <= span * lerp_k + 1e-4,
		"press scale: reversal step %.4f <= lerp bound %.4f" % [max_step, span * lerp_k]
	)
	# 손끝 안쪽 이동(최대 드리프트, 아이 손): 확대 기준점에 따른 이동 + 안쪽 누름 이동.
	var w: float = HandView.DISPLAY_SIZE.x
	var tip_x: float = -0.4 * w
	var pivot_x: float = HandView.PRESS_PIVOT.x * w
	var s_max: float = HandView.max_press_scale()
	var inward: float = HandView.PRESS_INWARD * HandView.SWAP_MAX_PRESS
	var tip_in: float = (pivot_x - tip_x) * (s_max - 1.0) + inward
	_ok(tip_in <= 40.0, "press scale: fingertip inward travel at max drift %.1f px <= 40" % tip_in)
	var sc: Array[float] = []  # 드리프트 [L, R] 쌍: dir ±0.001(미세 부호) 뒤 |dir| 증가 순.
	for d in [0.001, -0.001, 0.0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0]:
		_settle_press(d, true, d, dt)
		sc.append_array([_lh.press_scale(), _rh.press_scale()])
	var nz: bool = sc.slice(0, 4).all(func(v: float) -> bool: return absf(v - 1.0) <= 0.001)
	var up: bool = range(7, 22, 2).all(func(i: int) -> bool: return sc[i] >= sc[i - 2])
	_ok(nz, "press scale: near-zero drift (dir ±0.001) hands ~1 %s" % str(sc.slice(0, 4)))
	_ok(up and sc[21] >= 1.20, "press scale: drift grows with |dir| to max (R) %s" % str(sc))
	_settle_press(0.0, false, 0.0, dt)
	_ok(
		is_equal_approx(_lh.press_scale(), 1.0) and is_equal_approx(_rh.press_scale(), 1.0),
		"press scale: back to 1 when straight"
	)


func _settle_press(steer: float, drifting: bool, dir: float, dt: float) -> void:
	for h in [_lh, _rh]:
		h.set_steer(steer)
		h.set_drift(drifting, dir)
	for i in range(240):
		_lh._process(dt)
		_rh._process(dt)


## 손 사각형(최대 누름 확대 포함)이 1280 폭 화면과 겹치는가(교대 x 오프셋 반영). 확대 기준점이 안쪽이라
## 실제 안쪽 끝 확장은 반폭×max_press_scale() 이하다(보수적 판정).
func _hand_on_screen(h: HandView, is_mom: bool) -> bool:
	var rect: Rect2 = HandView.mom_display_rect() if is_mom else HandView.display_rect()
	var dx: float = h.mom_hand_dx() if is_mom else h.player_hand_dx()
	var half: float = rect.size.x * 0.5 * HandView.max_press_scale()
	var inward: float = HandView.PRESS_INWARD * HandView.SWAP_MAX_PRESS + HandView.JITTER_X + 2.0
	var x0: float = h.position.x + dx - half - inward
	var x1: float = h.position.x + dx + half + inward
	return x1 > 0.0 and x0 < HandView.SWAP_VIEWPORT_W


func _thimble(on: bool) -> void:
	_pres._update_items(0.0, false, on)


func _mom(entering: bool, thimble_on: bool) -> void:
	# delta 를 크게 줘 스와이프 보간을 한 번에 끝값까지 진행한다.
	_pres._update_items(10.0, entering, thimble_on)


## 3) 바늘. NeedleView 를 직접 만들어 _process 를 정해진 dt 로 호출한다(결정적).
func _check_needle(dt: float, speed: float) -> void:
	var tag: String = "needle dt=%.4f speed=%.0f" % [dt, speed]
	var nv: NeedleView = NeedleView.new()
	add_child(nv)
	nv.set_process(false)
	var travel: float = NeedleView.NEEDLE_TRAVEL
	_ok(travel == 90.0, "NEEDLE_TRAVEL == 90")
	var rect0: Rect2 = nv.foot_rect()
	_ok(rect0 == NeedleView.FOOT_RECT, "%s foot_rect == FOOT_RECT" % tag)
	if speed > 0.0:
		nv.set_speed(speed)
		nv.set_running(true)
		for i in range(int(0.5 / dt)):
			nv._process(dt)
		var mn: float = 1e9
		var mx: float = -1e9
		var rect_same: bool = true
		for i in range(int(3.0 / dt)):
			nv._process(dt)
			var tip: float = nv.needle_tip_y()
			mn = minf(mn, tip)
			mx = maxf(mx, tip)
			if nv.foot_rect() != rect0:
				rect_same = false
		_ok(absf(mn + travel) <= 1.0, "%s min ~ -TRAVEL (got %.3f)" % [tag, mn])
		_ok(absf(mx) <= 1.0, "%s max ~ 0 (got %.3f)" % [tag, mx])
		_ok(mx <= 0.0, "%s never below origin (max %.4f)" % [tag, mx])
		_ok(rect_same, "%s foot_rect identical every frame" % tag)
		# 정지: 위상마다 set_running(false) 후 1초 안에 -TRAVEL 로 수렴.
		var jump_cap: float = PI * travel * NeedleView.FREQ_MAX_HZ * dt * 1.05
		for k in range(8):
			nv.set_running(true)
			for i in range(k * 3 + 1):
				nv._process(dt)
			nv.set_running(false)
			var prev_tip: float = nv.needle_tip_y()
			var worst: float = 0.0
			for i in range(int(1.0 / dt)):
				nv._process(dt)
				var t: float = nv.needle_tip_y()
				worst = maxf(worst, absf(t - prev_tip))
				prev_tip = t
			_ok(
				absf(prev_tip + travel) <= 0.5,
				"%s park %d converges (got %.3f)" % [tag, k, prev_tip]
			)
			_ok(
				worst <= jump_cap,
				"%s park %d no teleport (%.3f <= %.3f)" % [tag, k, worst, jump_cap]
			)
			# 수렴 후 더 움직이지 않는다.
			var settled: float = nv.needle_tip_y()
			var drift: float = 0.0
			for i in range(int(0.5 / dt)):
				nv._process(dt)
				drift = maxf(drift, absf(nv.needle_tip_y() - settled))
			_ok(drift == 0.0, "%s park %d stays still (drift %.4f)" % [tag, k, drift])
	else:
		# 속도 0 이라도 running=true 이면 최저 주파수로 왕복한다(정지 판정은 running 이 결정).
		# 바늘은 상승점(-TRAVEL)에서 출발하므로 최솟값만 보면 전혀 움직이지 않아도 통과한다.
		# 최댓값이 최하단(0) 근처까지 내려와 전체 행정을 오가는지도 요구한다.
		nv.set_speed(0.0)
		nv.set_running(true)
		var mn0: float = 1e9
		var mx0: float = -1e9
		for i in range(int(2.0 / dt)):
			nv._process(dt)
			mn0 = minf(mn0, nv.needle_tip_y())
			mx0 = maxf(mx0, nv.needle_tip_y())
		_ok(absf(mn0 + travel) <= 1.0, "%s running at speed 0 reaches top (got %.3f)" % [tag, mn0])
		_ok(absf(mx0) <= 1.0, "%s running at speed 0 reaches bottom ~0 (got %.3f)" % [tag, mx0])
		# 정지 검사는 행정 중간(상승점에서 충분히 내려온 위치)에서 멈춰야 의미가 있다. 상승점에 있을
		# 때 멈추면 움직이지 않는 바늘도 -TRAVEL 에서 쉬는 것으로 통과한다.
		var guard: int = 0
		while nv.needle_tip_y() < -travel * 0.5 and guard < int(1.0 / dt):
			nv._process(dt)
			guard += 1
		var stop_tip: float = nv.needle_tip_y()
		var mid_stroke: bool = stop_tip >= -travel * 0.5
		_ok(mid_stroke, "%s stop issued mid-stroke (tip %.3f)" % [tag, stop_tip])
		nv.set_running(false)
		for i in range(int(1.0 / dt)):
			nv._process(dt)
		var rest: float = nv.needle_tip_y()
		_ok(
			mid_stroke and absf(rest + travel) <= 0.5,
			"%s stopped rests at -TRAVEL after moving (got %.3f)" % [tag, rest]
		)
	nv.queue_free()


## 상승점 정지 상태의 새 NeedleView(_process 는 검사가 직접 호출).
func _new_needle(speed: float) -> NeedleView:
	var nv: NeedleView = NeedleView.new()
	add_child(nv)
	nv.set_process(false)
	nv.set_speed(speed)
	return nv


## seconds 동안 dt 간격으로 _process 를 호출한다(프레임 수는 반올림).
func _step(nv: NeedleView, dt: float, seconds: float) -> void:
	for i in range(int(round(seconds / dt))):
		nv._process(dt)


## 정지 신호 후 상승점 주차 완료까지 걸린 시간(초). limit 안에 못 멈추면 -1.
func _park_time(nv: NeedleView, dt: float, limit: float) -> float:
	nv.set_running(false)
	var t: float = 0.0
	while t < limit:
		nv._process(dt)
		t += dt
		if nv._parked:
			return t
	return -1.0


## 5) 프레임 독립성: 같은 주행 시간·같은 정지 시점이면 dt 가 달라도 같은 결과.
func _check_needle_frame_independence() -> void:
	for speed in [0.0, 150.0, 300.0]:
		for run_s in [0.5, 1.0, 1.3]:
			var tips: Array[float] = []
			var stops: Array[float] = []
			# 주행 중 주차 상태를 벗어났는가. 벗어나지 않으면 끝 위치·주차 시간이 dt 와 무관하게
			# 같아져 아래 검사가 항상 참이 된다.
			var left_rest: bool = true
			for dt in NEEDLE_DTS:
				var nv: NeedleView = _new_needle(speed)
				nv.set_running(true)
				_step(nv, dt, run_s)
				left_rest = left_rest and not nv._parked
				tips.append(nv.needle_tip_y())
				stops.append(_park_time(nv, dt, 2.0))
				nv.queue_free()
			var tag: String = "needle frame-indep speed=%.0f run=%.1fs" % [speed, run_s]
			_ok(left_rest, "%s left rest while running" % tag)
			var tip_spread: float = tips.max() - tips.min()
			_ok(tip_spread <= 1.0, "%s tip spread %.4f px <= 1 (%s)" % [tag, tip_spread, tips])
			var ok_stop: bool = stops.min() > 0.0
			var stop_spread: float = stops.max() - stops.min()
			_ok(
				ok_stop and stop_spread <= NEEDLE_DTS[0] + 1e-6,
				"%s park-time spread %.4f s <= 1 frame (%s)" % [tag, stop_spread, stops]
			)
			_ok(ok_stop and stops.max() <= 1.0, "%s park time <= 1s (%s)" % [tag, stops])


## 6) 출발 직후(속도가 아직 낮을 때) 정지: 속도 불연속·순간 이동 없이 1초 안에 상승점.
func _check_needle_slow_park() -> void:
	var travel: float = NeedleView.NEEDLE_TRAVEL
	for dt in NEEDLE_DTS:
		var jump_cap: float = PI * travel * NeedleView.FREQ_MAX_HZ * dt * 1.05
		# 속도가 PARK_MIN_RATE 아래일 때 한 프레임 속도 변화 상한(수렴 기울기 K·|gap|).
		var rate_cap: float = NeedleView.PARK_DECEL * NeedleView.PARK_MIN_RATE * dt * 1.01
		for frames in [1, 2, 3]:
			var tag: String = "needle slow-park dt=%.4f frames=%d" % [dt, frames]
			var nv: NeedleView = _new_needle(300.0)
			nv.set_running(true)
			for i in range(frames):
				nv._process(dt)
			# 출발 직후 몇 프레임은 바늘 끝 이동이 미세하므로 상태로 확인한다. 주차 상태를 벗어나지
			# 않았다면 아래 주차·정지 검사가 초기 상태만으로 통과한다.
			var left_rest: bool = not nv._parked and nv._phase > 0.0
			_ok(left_rest, "%s left rest before stop (phase %.5f)" % [tag, nv._phase])
			nv.set_running(false)
			var prev_tip: float = nv.needle_tip_y()
			var prev_rate: float = nv._rate
			var worst: float = 0.0
			var worst_rate: float = 0.0
			var t: float = 0.0
			while not nv._parked and t < 1.0:
				nv._process(dt)
				t += dt
				worst = maxf(worst, absf(nv.needle_tip_y() - prev_tip))
				prev_tip = nv.needle_tip_y()
				if not nv._parked:
					worst_rate = maxf(worst_rate, absf(nv._rate - prev_rate))
					prev_rate = nv._rate
			_ok(
				left_rest and nv._parked and t > 0.0 and t <= 1.0,
				"%s parks within 1s (t=%.3f)" % [tag, t]
			)
			_ok(
				left_rest and absf(nv.needle_tip_y() + travel) <= 0.001,
				"%s rests at -TRAVEL" % tag
			)
			_ok(worst <= jump_cap, "%s no teleport (%.3f <= %.3f)" % [tag, worst, jump_cap])
			_ok(
				worst_rate <= rate_cap,
				"%s rate continuous (%.4f <= %.4f)" % [tag, worst_rate, rate_cap]
			)
			nv.queue_free()


## 7) 큰 delta(프레임 드랍)와 delta 0: 범위 이탈 없음, delta 0 은 상태 불변.
func _check_needle_extreme_delta() -> void:
	var travel: float = NeedleView.NEEDLE_TRAVEL
	var nv: NeedleView = _new_needle(300.0)
	var in_range: bool = true
	var zero_same: bool = true
	# 주행 중 바늘이 실제로 상승점을 벗어났는가(움직이지 않으면 범위·주차 검사가 항상 참).
	var run_max: float = -travel
	nv.set_running(true)
	for i in range(12):
		var tip0: float = nv.needle_tip_y()
		var rate0: float = nv._rate
		nv._process(0.0)
		if nv.needle_tip_y() != tip0 or nv._rate != rate0:
			zero_same = false
		nv._process(0.25)
		var tip: float = nv.needle_tip_y()
		run_max = maxf(run_max, tip)
		if tip < -travel or tip > 0.0:
			in_range = false
	nv.set_running(false)
	for i in range(8):
		nv._process(0.25)
		var tip: float = nv.needle_tip_y()
		if tip < -travel or tip > 0.0:
			in_range = false
	_ok(
		run_max >= -travel * 0.5,
		"needle delta=0.25 moves while running (max tip %.3f)" % run_max
	)
	_ok(in_range, "needle delta=0.25 tip stays in [-TRAVEL, 0]")
	_ok(zero_same, "needle delta=0 keeps state")
	_ok(nv._parked and nv.needle_tip_y() == -travel, "needle delta=0.25 park rests at -TRAVEL")
	nv.queue_free()


## 8) 노루발 정렬·크기(presser_foot_large.png 1254x1254 픽셀 측정값 기준). 관통점 (624, 985)이
## 노드 원점에 오고, 불투명 폭(1036px 비율)이 축소 범위이며, 바늘이 슬롯 상단 폭 안에 들어가고,
## 튜토리얼 바늘 콜아웃이 노루발 불투명 영역과 상승한 바늘 클램프를 감싸는지 본다.
func _check_foot_alignment() -> void:
	var r: Rect2 = NeedleView.FOOT_RECT
	var k: float = r.size.x / 1254.0
	_ok(is_equal_approx(r.size.x, r.size.y), "FOOT_RECT is square (%s)" % r.size)
	var pierce: Vector2 = r.position + Vector2(624.0, 985.0) * k
	_ok(pierce.length() <= 0.15, "foot pierce point at origin (got %s)" % pierce)
	var opaque_w: float = 1036.0 * k
	_ok(
		opaque_w >= 150.0 and opaque_w <= 185.0,
		"foot opaque width in 150..185 (got %.1f)" % opaque_w
	)
	# 슬롯 상단(원본 y=897) 개구 x[562, 688] 반폭 vs 바늘 반폭(불투명 x 6..13)+외곽선 1px.
	var slot_half: float = (688.0 - 562.0) * 0.5 * k
	var needle_half: float = 4.0 * NeedleView.NEEDLE_SCALE + 1.0
	_ok(
		needle_half < slot_half,
		"needle half width %.1f < slot half width %.1f" % [needle_half, slot_half]
	)
	var opaque: Rect2 = Rect2(
		r.position + Vector2(109.0, 62.0) * k, Vector2(1036.0, 1092.0) * k
	)
	var clamp_top: float = (
		-NeedleView.NEEDLE_TRAVEL
		- NeedleView.NEEDLE_LENGTH
		- NeedleView.CLAMP_SIZE.y
		+ NeedleView.CLAMP_OVERLAP
		- 1.0
	)
	var area: Rect2 = TutorialDialog.NEEDLE_AREA
	_ok(area.encloses(opaque), "NEEDLE_AREA %s encloses foot opaque %s" % [area, opaque])
	_ok(area.position.y <= clamp_top, "NEEDLE_AREA top <= raised clamp top %.1f" % clamp_top)


## 9) 얼굴 배치(0.84/-40)와 하단 절단 경계. BackgroundFace._face_rect()/_draw()의 변환
## (face_rect 중앙·HEAD_PIVOT_FRAC 피벗 회전 steer*MAX_HEAD_TILT + 수평 이동 steer*HEAD_LEAN_PX)을
## 그대로 옮겨, 텍스처 각 열의 가장 아래 불투명 픽셀이 모든 조향 값(전환 도중 포함)에서
## 수평선(HORIZON*720) 아래에 오는지 본다. 원단은 수평선 아래에서 불투명하다.
func _check_face_cut() -> void:
	var face: BackgroundFace = _gp.get_node("BackdropLayer/FaceView")
	_ok(
		is_equal_approx(face.face_draw_scale, 0.84) and is_equal_approx(face.face_offset_y, -40.0),
		"FaceView scene values 0.84/-40 (got %s/%s)" % [face.face_draw_scale, face.face_offset_y]
	)
	_ok(BackgroundFace.MAX_HEAD_TILT == 0.11, "MAX_HEAD_TILT unchanged 0.11")
	_ok(BackgroundFace.HEAD_LEAN_PX == 24.0, "HEAD_LEAN_PX unchanged 24")
	var screen: Vector2 = Vector2(1280.0, 720.0)
	var horizon_y: float = PresentationController.HORIZON * screen.y
	var dw: float = screen.x * face.face_draw_scale
	var dh: float = screen.y * face.face_draw_scale
	var rect: Rect2 = Rect2((screen.x - dw) * 0.5, face.face_offset_y, dw, dh)
	var pivot: Vector2 = Vector2(
		rect.position.x + rect.size.x * 0.5,
		rect.position.y + rect.size.y * BackgroundFace.HEAD_PIVOT_FRAC
	)
	var bottoms: PackedVector2Array = _opaque_bottoms(face.base_clean.resource_path)
	_ok(bottoms.size() >= 300, "face_base_clean flat bottom cut found (%d columns)" % bottoms.size())
	var tex_w: float = 1280.0
	var tex_h: float = 720.0
	var worst: float = INF
	var worst_steer: float = 0.0
	for i in range(41):
		var steer: float = -1.0 + i * 0.05
		var angle: float = steer * BackgroundFace.MAX_HEAD_TILT
		var lean: Vector2 = Vector2(steer * BackgroundFace.HEAD_LEAN_PX, 0.0)
		var xf: Transform2D = Transform2D(angle, lean + pivot - pivot.rotated(angle))
		for b in bottoms:
			var local: Vector2 = rect.position + Vector2(b.x / tex_w, b.y / tex_h) * rect.size
			var y: float = (xf * local).y
			if y < worst:
				worst = y
				worst_steer = steer
	_face_cut_worst = worst
	_face_horizon_y = horizon_y
	_ok(
		worst > horizon_y,
		(
			"face bottom cut stays below horizon %.1f for steer -1..1 (min %.1f at steer %.2f)"
			% [horizon_y, worst, worst_steer]
		)
	)
	# 엄마 얼굴은 기울이지 않는다(같은 face_rect + mom_offset_y).
	var mom_bottoms: PackedVector2Array = _opaque_bottoms(face.mom_face.resource_path)
	var mom_worst: float = INF
	for b in mom_bottoms:
		var y: float = rect.position.y + face.mom_offset_y * face.face_draw_scale
		y += b.y / tex_h * rect.size.y
		mom_worst = minf(mom_worst, y)
	_ok(
		mom_bottoms.size() > 0 and mom_worst > horizon_y,
		"mom face bottom cut below horizon %.1f (min %.1f)" % [horizon_y, mom_worst]
	)


## 하단 평평한 절단 경계 점 목록(u+0.5, v+1). 각 열의 가장 아래 불투명(alpha>0.5) 픽셀을 구하고,
## 같은 v가 CUT_RUN 열 이상 이어지는 수평 구간이면서 이미지 최하단 불투명 행에서 CUT_BAND px
## 안에 있는 것만 절단면으로 본다. 원본 PNG에서 직접 읽는다.
## face_base_clean 절단면: 턱 u 499~803 v=456, 좌 머리카락 u 318~370 v=467, 우 머리카락
## u 892~963 v=455~467. 우측 끝 곱슬 끝(u 1015~1100, 꼭짓점 v=452, 수평 15열)은 둥근 자연
## 외곽선이라 제외된다.
func _opaque_bottoms(res_path: String) -> PackedVector2Array:
	const CUT_BAND: int = 16
	const CUT_RUN: int = 16
	var out: PackedVector2Array = PackedVector2Array()
	var img: Image = Image.load_from_file(ProjectSettings.globalize_path(res_path))
	if img == null or img.is_empty():
		return out
	var w: int = img.get_width()
	var bottoms: PackedInt32Array = PackedInt32Array()
	var lowest: int = -1
	for u in range(w):
		var b: int = -1
		for v in range(img.get_height() - 1, -1, -1):
			if img.get_pixel(u, v).a > 0.5:
				b = v
				break
		bottoms.append(b)
		lowest = maxi(lowest, b)
	var start: int = 0
	for u in range(1, w + 1):
		if u < w and bottoms[u] == bottoms[start]:
			continue
		var v0: int = bottoms[start]
		if u - start >= CUT_RUN and v0 >= 0 and v0 >= lowest - CUT_BAND:
			for c in range(start, u):
				out.append(Vector2(c + 0.5, v0 + 1.0))
		start = u
	return out


## 10) 꿀밤(원단 이탈 소프트 리셋 연출). Presenter._process 를 직접 호출해 offfabric 상승엣지에서
## 1회 시작·재시작되는지, "> <"(INJURED) 표정 오버라이드와 복귀, cut 단계·손 텍스처 불변, 바운스
## 상향 상한·프레임 독립·종료, 최대 고개꺾기와 겹친 하단 절단 경계를 본다(FaceView._process 는
## 검사가 정해진 dt 로 직접 호출).
func _check_bonk() -> void:
	var face: BackgroundFace = _gp.get_node("BackdropLayer/FaceView")
	var player: PlayerController = _gp.get_node("SimHost/FabricSource/World/Player")
	const DT: float = 1.0 / 60.0
	face.set_process(false)
	# 상수 관계: 전체 길이가 표정·바운스·마지막 별 수명을 덮고, 표정은 조작 잠금 안에서 끝난다.
	var last_star: float = (
		BackgroundFace.BONK_STAR_LIFE
		+ BackgroundFace.BONK_STAR_STAGGER * float(BackgroundFace.BONK_STAR_OFFSETS.size() - 1)
	)
	_ok(
		(
			BackgroundFace.BONK_TOTAL_DUR >= BackgroundFace.BONK_EXPR_DUR
			and BackgroundFace.BONK_TOTAL_DUR >= BackgroundFace.BONK_BOUNCE_DUR
			and BackgroundFace.BONK_TOTAL_DUR >= last_star
		),
		"bonk total %.3f covers expr/bounce/stars (%.3f)" % [BackgroundFace.BONK_TOTAL_DUR, last_star]
	)
	_ok(
		BackgroundFace.BONK_EXPR_DUR < Tuning.reset_lockout,
		"bonk expr %.2f < reset_lockout %.2f" % [BackgroundFace.BONK_EXPR_DUR, Tuning.reset_lockout]
	)
	var n_stars: int = BackgroundFace.BONK_STAR_OFFSETS.size()
	_ok(
		(
			n_stars >= 3
			and n_stars <= 5
			and BackgroundFace.BONK_STAR_RADII.size() == n_stars
			and BackgroundFace.BONK_STAR_SPIN.size() == n_stars
		),
		"bonk star tables 3..5 and aligned (%d)" % n_stars
	)
	# 바운스 곡선(닫힌 형식) 조밀 샘플: 첫 하강 폭, 위쪽 상한, 끝·이전 값 0.
	var mn: float = INF
	var mx: float = -INF
	var t: float = 0.0
	while t <= BackgroundFace.BONK_BOUNCE_DUR + 0.01:
		var y: float = BackgroundFace.bonk_offset_at(t)
		mn = minf(mn, y)
		mx = maxf(mx, y)
		t += 0.0005
	_ok(mx >= 10.0 and mx <= 16.0, "bonk first drop in 10..16 px (got %.3f)" % mx)
	_ok(
		mn >= -BackgroundFace.BONK_MAX_UP - 1e-6 and mn < 0.0,
		"bonk upward overshoot %.3f within -BONK_MAX_UP %.1f" % [mn, BackgroundFace.BONK_MAX_UP]
	)
	_ok(
		(
			BackgroundFace.bonk_offset_at(BackgroundFace.BONK_BOUNCE_DUR) == 0.0
			and BackgroundFace.bonk_offset_at(-0.01) == 0.0
			and BackgroundFace.bonk_offset_at(0.0) == 0.0
		),
		"bonk offset 0 at t<=0 and t>=BOUNCE_DUR"
	)
	# 최대 고개꺾기(±1) 최악 절단 경계 + 최대 상향 오버슈트(상한 전체)에서도 수평선 아래.
	var lifted: float = _face_cut_worst - BackgroundFace.BONK_MAX_UP
	_ok(
		lifted > _face_horizon_y,
		(
			"face bottom cut with max tilt + BONK_MAX_UP %.1f still below horizon %.1f (min %.2f)"
			% [BackgroundFace.BONK_MAX_UP, _face_horizon_y, lifted]
		)
	)
	# Presenter 상승엣지 트리거(표현 경로). 손·cut 초기 상태에서 시작.
	_pres.reset_hands()
	face.set_mom(false, 0.0)
	_pres._mom_swipe = 0.0
	_pres._prev_autopilot = false
	player.stun_timer = 0.0
	player.autopilot_timer = 0.0
	player.risk = 0.0
	player.speed_index = 1
	player.offfabric_timer = 0.0
	_pres._prev_stun_active = false
	_pres._prev_offfabric = false
	_pres._process(DT)
	_bonk_face_step(face, DT, 0.5)
	_ok(not face.is_bonk_active(), "bonk inactive without off-fabric")
	_ok(face._state == BackgroundFace.FaceState.NORMAL, "face NORMAL before bonk")
	var r_tex: Texture2D = _rh.texture
	var l_tex: Texture2D = _lh.texture
	var cut0: int = _pres._cut_stage
	player.offfabric_timer = Tuning.reset_lockout
	_pres._process(DT)
	_ok(face.is_bonk_active() and face._bonk_t == 0.0, "bonk starts on off-fabric rising edge")
	_ok(face._state == BackgroundFace.FaceState.INJURED, "bonk shows INJURED (> <) eyes")
	_ok(face._fade_t == 1.0, "bonk expression snaps in (no fade)")
	_bonk_face_step(face, DT, 0.3)
	_pres._process(DT)
	_ok(
		absf(face._bonk_t - 0.3) < 1e-3,
		"bonk not restarted while off-fabric held (t=%.4f)" % face._bonk_t
	)
	# 재트리거: 하강 후 다시 상승하면 처음부터.
	player.offfabric_timer = 0.0
	_pres._process(DT)
	player.offfabric_timer = Tuning.reset_lockout
	_pres._process(DT)
	_ok(face._bonk_t == 0.0, "bonk restarts on a new rising edge")
	# 표정 구간 끝 직전: INJURED 유지·땀 억제, 직후: 원래 상태로 크로스페이드 시작.
	_bonk_face_step(face, DT, BackgroundFace.BONK_EXPR_DUR - 2.0 * DT)
	_ok(face._state == BackgroundFace.FaceState.INJURED, "INJURED kept until BONK_EXPR_DUR")
	_ok(face._injured_shown(), "sweat gate suppressed during bonk expression")
	_bonk_face_step(face, DT, 3.0 * DT)
	_ok(face._state == BackgroundFace.FaceState.NORMAL, "state returns to NORMAL after bonk")
	_ok(face._fade_t < 1.0, "return uses crossfade (fade_t %.3f)" % face._fade_t)
	_bonk_face_step(face, DT, BackgroundFace.BONK_TOTAL_DUR)
	_ok(
		not face.is_bonk_active() and face.bonk_offset_y() == 0.0,
		"bonk inactive and offset 0 after total duration"
	)
	# 꿀밤은 부상이 아니다: cut 단계·손 텍스처 불변.
	_ok(_pres._cut_stage == cut0, "bonk keeps cut stage %d (got %d)" % [cut0, _pres._cut_stage])
	_ok(_rh.texture == r_tex and _lh.texture == l_tex, "bonk keeps hand textures")
	_ok(not face._stunned, "bonk does not set _stunned")
	# 실제 부상과 겹침: 꿀밤이 끝나도 부상 중이면 INJURED 유지, 부상 해제 시 복귀.
	face.play_bonk()
	face.set_expression(0.0, true, 1)
	_bonk_face_step(face, DT, BackgroundFace.BONK_TOTAL_DUR + DT)
	_ok(face._state == BackgroundFace.FaceState.INJURED, "stun overlap keeps INJURED after bonk")
	face.set_expression(0.0, false, 1)
	_ok(face._state == BackgroundFace.FaceState.NORMAL, "stun end returns NORMAL")
	# 고집중 중 꿀밤 → 끝나면 FOCUS로 복귀(기존 우선순위 유지).
	face.set_expression(1.0, false, 5)
	_bonk_face_step(face, DT, 0.5)
	face.play_bonk()
	_ok(face._state == BackgroundFace.FaceState.INJURED, "bonk overrides FOCUS")
	_bonk_face_step(face, DT, BackgroundFace.BONK_TOTAL_DUR + DT)
	_ok(face._state == BackgroundFace.FaceState.FOCUS, "bonk end returns to FOCUS")
	face.set_expression(0.0, false, 1)
	# 엄마 찬스 전환 중엔 생략.
	face.set_mom(true, 1.0)
	face.play_bonk()
	_ok(not face.is_bonk_active(), "bonk skipped while mom face active")
	face.set_mom(false, 0.0)
	# 프레임 독립: 1/30 배수 시각(60/90/120Hz 모두 정수 프레임)에서 오프셋 일치, 끝나면 비활성.
	var samples: Array = []
	for dt in NEEDLE_DTS:
		face.play_bonk()
		var per: int = int(round((1.0 / 30.0) / dt))
		var offs: Array[float] = []
		for k in range(1, 16):
			for i in range(per):
				face._process(dt)
			offs.append(face.bonk_offset_y())
		_bonk_face_step(face, dt, BackgroundFace.BONK_TOTAL_DUR)
		_ok(
			not face.is_bonk_active() and face.bonk_offset_y() == 0.0,
			"bonk ends at dt=%.4f" % dt
		)
		samples.append(offs)
	var spread: float = 0.0
	for k in range(samples[0].size()):
		for j in range(1, samples.size()):
			spread = maxf(spread, absf(samples[j][k] - samples[0][k]))
	# 오프셋이 전부 0이면(바운스가 재생되지 않으면) 차이 0으로 항상 통과하므로 실제로 움직였는지 본다.
	var peak: float = 0.0
	for v in samples[0]:
		peak = maxf(peak, absf(v))
	_ok(peak >= 1.0, "bonk offset samples actually bounce (peak %.3f px >= 1)" % peak)
	_ok(spread <= 0.01, "bonk offset frame-independent at 60/90/120Hz (max diff %.5f px)" % spread)
	player.offfabric_timer = 0.0
	_pres._prev_offfabric = false
	face.set_process(true)


## FaceView._process 를 dt 간격으로 seconds 동안 호출한다(프레임 수는 반올림).
func _bonk_face_step(face: BackgroundFace, dt: float, seconds: float) -> void:
	for i in range(int(round(seconds / dt))):
		face._process(dt)
