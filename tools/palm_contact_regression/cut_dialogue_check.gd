extends Node
## 부상 대사 말풍선(아얏!/아파!/아이고! + 눈물 초상화) 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## 상태 주입 검사다: Gameplay 의 시뮬·표현 구동을 멈추고 player 의 pending/스턴/이탈 필드를 직접 바꾸거나
## RaceDirector._physics_process 를 한 틱씩 부른 뒤 Presenter 의 _process 를 정해진 dt 로 부른다(실제 입력
## 플레이 아님). Presenter 의 토스트는 기록 전용 스파이(toast_spy.gd)로 바꿔 호출만 센다(같은 틱 검사는
## 실제 Toast 로도 확인). 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const ToastSpy: GDScript = preload("res://palm_regression/toast_spy.gd")
const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const CUT_LINES: Array[String] = ["아얏!", "아파!", "아이고!"]
const HURT_PATH: String = "res://assets/gfx/ui/player_hurt_teary.png"
const MOM_PATH: String = "res://assets/gfx/ui/mom_scolding.png"
const PENALTY_TEXT: String = "이녀석, 제대로 해야지!"
const PRES_SRC: String = "res://scripts/presentation/PresentationController.gd"
const DT: float = 1.0 / 60.0
const MIN_PASSED: int = 98
const SECTIONS: Array[String] = [
	"wiring",
	"cut_once",
	"cancel",
	"offfabric_only",
	"max_stage",
	"same_frame",
	"forced_lines",
	"consecutive",
	"global_rng",
	"just_cut_untouched",
	"director_same_tick",
	"director_finish",
	"finish_items",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _gp: Node = null
var _pres: PresentationController = null
var _player: PlayerController = null
var _spy: Toast = null
var _real: Toast = null
var _w: float = 0.2


func _ready() -> void:
	LeaderboardClient.tutorial_seen = true
	_gp = await _spawn()
	_bind(_gp)
	_check_wiring()
	_check_cut_once()
	_check_cancel()
	_check_offfabric_only()
	_check_max_stage()
	_check_same_frame()
	_check_forced_lines()
	_check_consecutive()
	_check_global_rng()
	_check_just_cut_untouched()
	_unbind()
	_gp.queue_free()
	await get_tree().process_frame
	await _check_director_same_tick()
	await _check_director_finish()
	await _check_finish_items()
	_ok(_done == SECTIONS, "all check sections ran to completion (%s)" % [_done])
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("cut dialogue regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


## Gameplay 인스턴스를 띄우고 모든 자동 구동(시뮬·표현·손·얼굴)을 멈춘다.
func _spawn() -> Node:
	var gp: Node = GameplayScene.instantiate()
	get_tree().root.add_child.call_deferred(gp)
	await get_tree().process_frame
	await get_tree().process_frame
	gp.set_physics_process(false)
	gp.set_process(false)
	for path in ["Presenter", "ForegroundLayer/LeftHand", "ForegroundLayer/RightHand"]:
		gp.get_node(path).set_process(false)
	gp.get_node("BackdropLayer/FaceView").set_process(false)
	return gp


## Presenter 토스트를 스파이로 바꿔 끼운다(실제 토스트는 _real 로 보관).
func _bind(gp: Node) -> void:
	_pres = gp.get_node("Presenter")
	_player = gp.get_node("SimHost/FabricSource/World/Player")
	_real = _pres._toast
	_spy = ToastSpy.new()
	_pres._toast = _spy
	_w = Tuning.cut_windup_duration


func _unbind() -> void:
	_pres._toast = _real
	_spy.free()
	_spy = null


func _frame() -> void:
	_pres._process(DT)


func _settle(n: int) -> void:
	for i in range(n):
		_frame()


## 새 런 상태: pending/스턴/이탈/아이템 없음, cut 단계 0, 스파이 기록 비움.
func _fresh() -> void:
	_player.stun_timer = 0.0
	_player.cut_pending_timer = 0.0
	_player.offfabric_timer = 0.0
	_player.thimble_timer = 0.0
	_player.autopilot_timer = 0.0
	_player.risk = 0.5
	_player.speed_index = 5
	_player.speed = 300.0
	_pres.reset_hands()
	_settle(3)
	_spy.calls.clear()


func _ticks() -> int:
	return int(round(_w / DT))


## pending 시작부터 i번째 물리 틱의 시뮬 상태.
func _pend_tick(i: int) -> void:
	_player.risk = 1.0
	_player.cut_pending_timer = _w - float(i) * DT


## cut 틱: pending 해제 + 기존 _trigger_cut 과 같은 결과(스턴 상승엣지).
func _cut_tick() -> void:
	_player.cut_pending_timer = 0.0
	_player.risk = 0.0
	_player.stun_timer = Tuning.stun_duration
	_player.speed_index = 1
	_player.speed = Tuning.speed_table[0]


## pending 전 구간 → cut 틱 → 스턴 유지 몇 프레임. 스파이 기록 수 변화를 돌려준다.
func _full_cut() -> void:
	_player.stun_timer = 0.0
	_settle(2)
	for i in range(_ticks()):
		_pend_tick(i)
		_frame()
	_cut_tick()
	_frame()
	_settle(10)


func _imm(calls: Array) -> Array:
	return calls.filter(func(c: Dictionary) -> bool: return c["immediate"])


func _norm(calls: Array) -> Array:
	return calls.filter(func(c: Dictionary) -> bool: return not c["immediate"])


func _path(tex: Texture2D) -> String:
	return tex.resource_path if tex != null else "<null>"


## 부상 대사 호출 하나가 규약(세 문구 중 하나, 눈물 초상화, 즉시 경로)에 맞는가.
func _is_hurt_call(c: Dictionary) -> bool:
	return c["immediate"] and CUT_LINES.has(c["text"]) and _path(c["portrait"]) == HURT_PATH


## PresentationController 소스에서 함수 하나의 본문(다음 최상위 func 전까지)을 잘라낸다.
func _func_body(src: String, fname: String) -> String:
	var at: int = src.find("func %s(" % fname)
	if at < 0:
		return ""
	var nxt: int = src.find("\nfunc ", at + 5)
	return src.substr(at, (nxt - at) if nxt > 0 else -1)


## 1) 배선: 문구 상수, 초상화, 표현 전용 RNG, 훅.
func _check_wiring() -> void:
	var lines: Array[String] = PresentationController.CUT_LINES
	_ok(lines == CUT_LINES, "CUT_LINES exact %s" % [lines])
	_ok(
		_path(PresentationController._PLAYER_HURT_TEX) == HURT_PATH,
		"hurt portrait constant is player_hurt_teary.png"
	)
	_ok(_pres._line_rng is RandomNumberGenerator, "presentation-only RNG instance created in _ready")
	_ok(_pres.has_method("set_next_cut_line_index"), "test hook set_next_cut_line_index exists")
	_ok(_spy.calls.is_empty(), "no toast before any event")
	_done.append("wiring")


## 2) 실제 cut(스턴 상승엣지) 1회당 push_immediate 정확히 1회. pending 시작·진행 중에는 없음.
func _check_cut_once() -> void:
	_fresh()
	_pend_tick(0)
	_frame()
	_ok(_spy.calls.is_empty(), "pending start: no dialogue (%d)" % _spy.calls.size())
	for i in range(1, _ticks()):
		_pend_tick(i)
		_frame()
	_ok(_spy.calls.is_empty(), "whole pending: no dialogue (%d)" % _spy.calls.size())
	_cut_tick()
	_frame()
	_ok(_spy.calls.size() == 1, "cut frame: exactly one toast call (%d)" % _spy.calls.size())
	if _spy.calls.size() >= 1:
		var c: Dictionary = _spy.calls[0]
		_ok(c["immediate"], "cut frame: call is push_immediate")
		_ok(CUT_LINES.has(c["text"]), "cut frame: text is one of the three (%s)" % c["text"])
		_ok(_path(c["portrait"]) == HURT_PATH, "cut frame: portrait %s" % _path(c["portrait"]))
	_settle(60)
	_ok(_spy.calls.size() == 1, "stun held: no repeat (%d)" % _spy.calls.size())
	_player.stun_timer = 0.0
	_settle(5)
	_ok(_spy.calls.size() == 1, "stun end: no call (%d)" % _spy.calls.size())
	_done.append("cut_once")


## pending 을 몇 틱 진행한 뒤 실제 PlayerController API 로 해제하고 프레임을 돈다.
func _cancel_case(tag: String, cancel: Callable) -> void:
	_fresh()
	for i in range(5):
		_pend_tick(i)
		_frame()
	cancel.call()
	_settle(_ticks() * 2)
	_ok(not _player.is_cut_pending(), "%s: pending released" % tag)
	_ok(_player.stun_timer == 0.0, "%s: no stun" % tag)
	_ok(_imm(_spy.calls).is_empty(), "%s: no hurt dialogue (%d)" % [tag, _imm(_spy.calls).size()])
	_ok(_pres.cut_count() == 0, "%s: no cut counted" % tag)


## 3) pending 취소(골무·엄마 찬스·원단 이탈·리셋)만으로는 부상 대사가 없다.
func _check_cancel() -> void:
	_cancel_case("thimble", func() -> void: _player.grant_thimble())
	_ok(
		_norm(_spy.calls).size() == 1 and str(_norm(_spy.calls)[0]["text"]).begins_with("골무!"),
		"thimble: only the thimble toast"
	)
	_player.thimble_timer = 0.0
	_cancel_case("mom", func() -> void: _player.grant_autopilot())
	_ok(
		_norm(_spy.calls).size() == 1 and str(_norm(_spy.calls)[0]["text"]).begins_with("엄마 찬스!"),
		"mom: only the mom chance toast"
	)
	_player.autopilot_timer = 0.0
	_settle(30)
	_cancel_case("offfabric", func() -> void: _player.off_fabric_reset(Vector2.ZERO, 0.0))
	var n: Array = _norm(_spy.calls)
	_ok(
		n.size() == 1 and n[0]["text"] == PENALTY_TEXT and _path(n[0]["portrait"]) == MOM_PATH,
		"offfabric: only the mom scolding push"
	)
	_player.offfabric_timer = 0.0
	_cancel_case("reset", func() -> void: _player.reset_state(Vector2.ZERO, 0.0))
	_ok(_spy.calls.is_empty(), "reset: no toast at all (%d)" % _spy.calls.size())
	_done.append("cancel")


## 4) 원단 이탈 강제 복귀만: 엄마 push 1회, 부상 대사 없음.
func _check_offfabric_only() -> void:
	_fresh()
	_player.offfabric_timer = Tuning.reset_lockout
	_frame()
	_settle(20)
	_ok(_spy.calls.size() == 1, "off-fabric: one call (%d)" % _spy.calls.size())
	if _spy.calls.size() == 1:
		var c: Dictionary = _spy.calls[0]
		_ok(not c["immediate"], "off-fabric: queued push, not immediate")
		_ok(c["text"] == PENALTY_TEXT and _path(c["portrait"]) == MOM_PATH, "off-fabric: mom line")
	_player.offfabric_timer = 0.0
	_done.append("offfabric_only")


## 5) 밴드 최대 단계 이후의 cut(4·5·6번째)에도 cut마다 대사 1회.
func _check_max_stage() -> void:
	_fresh()
	var cap: int = _pres.cut_hand_textures.size()
	for k in range(cap + 3):
		var before: int = _spy.calls.size()
		_full_cut()
		var added: Array = _spy.calls.slice(before)
		_ok(
			added.size() == 1 and _is_hurt_call(added[0]),
			"cut %d (stage %d/%d): one hurt dialogue (%d)" % [k + 1, _pres._cut_stage, cap, added.size()]
		)
	_ok(_pres._cut_stage == cap, "band stage capped at %d" % cap)
	_ok(_pres.cut_count() == cap + 3, "cut count %d" % _pres.cut_count())
	_player.stun_timer = 0.0
	_done.append("max_stage")


## 6) 같은 프레임 cut + 원단 이탈: 부상 대사(즉시) 먼저, 엄마 꾸중(push) 뒤. 실제 Toast 에서도 한 말풍선씩.
func _check_same_frame() -> void:
	_fresh()
	for i in range(_ticks()):
		_pend_tick(i)
		_frame()
	_cut_tick()
	_player.offfabric_timer = Tuning.reset_lockout
	_frame()
	_ok(_spy.calls.size() == 2, "same frame: two calls (%d)" % _spy.calls.size())
	if _spy.calls.size() == 2:
		_ok(_is_hurt_call(_spy.calls[0]), "same frame: first is hurt dialogue (immediate)")
		var m: Dictionary = _spy.calls[1]
		_ok(
			not m["immediate"] and m["text"] == PENALTY_TEXT and _path(m["portrait"]) == MOM_PATH,
			"same frame: second is queued mom scolding"
		)
	# 실제 Toast: 부상 대사가 슬롯, 엄마 꾸중은 대기 큐(초상화 섞임 없음).
	_player.stun_timer = 0.0
	_player.offfabric_timer = 0.0
	_settle(3)
	var real: Toast = _real
	_pres._toast = real
	_pres.set_next_cut_line_index(2)
	_cut_tick()
	_player.offfabric_timer = Tuning.reset_lockout
	_frame()
	_ok(real._label.text == CUT_LINES[2] and real._immediate, "real toast: hurt line in slot")
	_ok(_path(real._portrait.texture) == HURT_PATH and real._scold, "real toast: hurt portrait shown")
	_ok(real._queue.size() == 1, "real toast: mom scolding waiting (%d)" % real._queue.size())
	if real._queue.size() == 1:
		var q: Dictionary = real._queue[0]
		_ok(
			q["text"] == PENALTY_TEXT and _path(q["portrait"]) == MOM_PATH,
			"real toast: queued item keeps its own mom portrait"
		)
	# 정리: 실제 토스트 비우고 스파이로 복귀.
	real._kill_tween()
	real._queue.clear()
	real._show_next()
	_pres._toast = _spy
	_player.stun_timer = 0.0
	_player.offfabric_timer = 0.0
	_done.append("same_frame")


## 7) 훅으로 세 문구를 각각 지정(확률 무관). 훅은 1회만 쓰이고 이후엔 다시 무작위(세 문구 중 하나).
func _check_forced_lines() -> void:
	_fresh()
	for i in range(3):
		_pres.set_next_cut_line_index(i)
		var before: int = _spy.calls.size()
		_full_cut()
		var added: Array = _spy.calls.slice(before)
		_ok(
			added.size() == 1 and added[0]["text"] == CUT_LINES[i] and _is_hurt_call(added[0]),
			"forced line %d -> '%s'" % [i, CUT_LINES[i]]
		)
	_ok(_pres._forced_line == -1, "hook consumed after use")
	_pres.set_next_cut_line_index(7)
	_ok(CUT_LINES.has(_pres._pick_cut_line()), "out-of-range hook falls back to random line")
	# 고정 시드: 표현 RNG 로 세 문구가 모두 나오고 치우치지 않는다(결정적).
	var saved: int = _pres._line_rng.state
	_pres._line_rng.seed = 20260930
	var counts: Dictionary = {}
	for line in CUT_LINES:
		counts[line] = 0
	for i in range(3000):
		var s: String = _pres._pick_cut_line()
		counts[s] = int(counts.get(s, 0)) + 1
	var even: bool = counts.size() == 3
	for line in CUT_LINES:
		even = even and int(counts[line]) > 850 and int(counts[line]) < 1150
	_ok(even, "fixed seed: three lines near-uniform %s" % [counts])
	_pres._line_rng.state = saved
	_player.stun_timer = 0.0
	_done.append("forced_lines")


## 8) 연속 cut: cut마다 새 대사 호출(갱신). 실제 Toast 에서 슬롯 대사가 바뀌고 큐에 쌓이지 않는다.
func _check_consecutive() -> void:
	_fresh()
	var real: Toast = _real
	_pres._toast = real
	_pres.set_next_cut_line_index(0)
	_full_cut()
	_ok(real._label.text == CUT_LINES[0] and real._immediate, "consecutive: first line shown")
	_pres.set_next_cut_line_index(1)
	_full_cut()
	_ok(real._label.text == CUT_LINES[1] and real._immediate, "consecutive: second line replaces")
	_ok(real._queue.is_empty(), "consecutive: old hurt line not queued (%d)" % real._queue.size())
	_ok(_path(real._portrait.texture) == HURT_PATH, "consecutive: hurt portrait kept")
	real._kill_tween()
	real._show_next()
	_pres._toast = _spy
	_player.stun_timer = 0.0
	_done.append("consecutive")


## 9) 대사 선택이 전역 난수열을 바꾸지 않는다(시뮬·아이템·트랙 난수 보존). 소스에도 전역 난수 없음.
func _check_global_rng() -> void:
	seed(424242)
	var ref: Array[int] = []
	for i in range(8):
		ref.append(randi())
	seed(424242)
	for i in range(50):
		_pres._pick_cut_line()
	var got: Array[int] = []
	for i in range(8):
		got.append(randi())
	_ok(ref == got, "global randi() sequence unchanged by line picks")
	var src: String = FileAccess.get_file_as_string(PRES_SRC)
	_ok(src.length() > 0, "presentation source readable")
	_ok(not src.contains("pick_random"), "no Array.pick_random in PresentationController")
	var body: String = _func_body(src, "_pick_cut_line")
	_ok(body.contains("_line_rng.randi_range"), "_pick_cut_line uses the presentation RNG")
	var bare: bool = (
		body.replace("_line_rng.randi_range", "").contains("randi")
		or body.contains("randf")
		or body.contains("pick_random")
	)
	_ok(not bare, "_pick_cut_line has no global randi/randf/pick_random")
	_done.append("global_rng")


## 10) 표현 계층은 consume_just_cut 을 부르지 않는다(RaceDirector 집계 보존).
func _check_just_cut_untouched() -> void:
	_fresh()
	for i in range(_ticks()):
		_pend_tick(i)
		_frame()
	_cut_tick()
	_player._just_cut = true
	_frame()
	_settle(5)
	_ok(_player._just_cut, "cut flag still set after presenter frames (not consumed)")
	_ok(_imm(_spy.calls).size() == 1, "dialogue shown without consuming the flag")
	_player._just_cut = false
	var src: String = FileAccess.get_file_as_string(PRES_SRC)
	_ok(not src.contains("consume_just_cut"), "PresentationController never calls consume_just_cut")
	_player.stun_timer = 0.0
	_done.append("just_cut_untouched")


## 11) RaceDirector 실제 틱 순서: 부상 실행 틱 == 원단 이탈 리셋 틱이면 그 틱 뒤 스턴·이탈이 함께
##     켜져 있고, 다음 표현 프레임에서 부상 대사(즉시) → 엄마 꾸중(큐) 순서로 한 번씩.
func _check_director_same_tick() -> void:
	var gp: Node = await _spawn()
	_bind(gp)
	gp._state = gp.State.RUNNING
	_settle(3)
	_spy.calls.clear()
	_player.risk = 1.0
	_player.cut_pending_timer = DT * 0.5
	_player.position = Vector2(1.0e5, 1.0e5)
	gp._offfabric_dwell = gp.RESET_DWELL
	gp._physics_process(DT)
	_ok(_player.stun_timer > 0.0 and _player.offfabric_timer > 0.0, "director: cut + reset same tick")
	_ok(gp._stats.cuts == 1, "director: cut counted once (%d)" % gp._stats.cuts)
	_frame()
	_ok(_spy.calls.size() == 2, "director same tick: two calls (%d)" % _spy.calls.size())
	if _spy.calls.size() == 2:
		_ok(_is_hurt_call(_spy.calls[0]), "director same tick: hurt dialogue first")
		_ok(
			not _spy.calls[1]["immediate"] and _spy.calls[1]["text"] == PENALTY_TEXT,
			"director same tick: mom scolding second (queued)"
		)
	# pending 중 리셋(부상 없음): 엄마 꾸중만.
	_player.stun_timer = 0.0
	_player.offfabric_timer = 0.0
	_settle(3)
	_spy.calls.clear()
	_player.risk = 1.0
	_player.cut_pending_timer = 0.1
	_player.position = Vector2(1.0e5, 1.0e5)
	gp._offfabric_dwell = gp.RESET_DWELL
	gp._physics_process(DT)
	_frame()
	_settle(_ticks() * 2)
	_ok(_imm(_spy.calls).is_empty(), "director pending+reset: no hurt dialogue")
	_ok(_norm(_spy.calls).size() == 1, "director pending+reset: mom scolding only")
	_unbind()
	gp.queue_free()
	await get_tree().process_frame
	_done.append("director_same_tick")


## 12) 완주: (a) 완주 틱에 pending 부상이 확정되면 집계·밴드·셰이크는 1회 반영되지만, 완주 줌아웃이 이미
##     보이므로 대사는 띄우지 않고 진입 프레임에 토스트를 한 번 정리(dismiss)한다. (b) 완주 직전 부상 대사가
##     떠 있는 채로 완주하면 실제 Toast 가 짧게 걷히고 큐도 비워진다.
func _check_director_finish() -> void:
	var gp: Node = await _spawn()
	_bind(gp)
	gp._state = gp.State.RUNNING
	_settle(3)
	_spy.calls.clear()
	_player.risk = 1.0
	_player.speed_index = 5
	_player.cut_pending_timer = 0.1
	_frame()
	gp._finish()
	_ok(gp._stats.cuts == 1, "finish a: pending resolved and counted (%d)" % gp._stats.cuts)
	_ok(gp.get_node("FinishViewLayer/FinishView").visible, "finish a: finish view shown")
	_frame()
	_ok(_pres._injury_shake > 0.0, "finish a: injury edge processed (shake)")
	_settle(30)
	_ok(_imm(_spy.calls).is_empty(), "finish a: no hurt dialogue over finish view")
	_ok(_spy.dismissed == 1, "finish a: toast dismissed once on finish (%d)" % _spy.dismissed)
	_ok(_pres.cut_count() == 1 and _pres._cut_stage == 1, "finish a: band/cut count still advance")
	_unbind()
	gp.queue_free()
	await get_tree().process_frame
	# (b) 실제 Toast: 부상 대사 표시 중 완주.
	gp = await _spawn()
	_bind(gp)
	_unbind()
	gp._state = gp.State.RUNNING
	_settle(3)
	_pres.set_next_cut_line_index(1)
	_cut_tick()
	_frame()
	var t: Toast = _pres._toast
	_ok(t._label.text == CUT_LINES[1] and t._group.visible, "finish b: hurt line shown before finish")
	t.push("골무! 4.5초 동안 부상 면역")
	_player.stun_timer = 0.0
	gp._finish()
	_frame()
	_ok(not t._busy and t._queue.is_empty(), "finish b: slot released and queue cleared")
	await get_tree().create_timer(0.3).timeout
	_ok(not t._group.visible and t._portrait.texture == null, "finish b: bubble faded out and hidden")
	_ok(_live_tweens(t) == 0, "finish b: no tween left")
	gp.queue_free()
	await get_tree().process_frame
	_done.append("director_finish")


## 13) 완주 틱에 골무·엄마 찬스 획득(상승엣지)이 겹쳐도 획득 토스트는 완주 진입 dismiss 뒤에 push되지
##     않는다. (a) 스파이: 완주 프레임 이후 push 호출 0, dismiss 1회. (b) 실제 Toast: 표시 중이던 알림이
##     걷힌 뒤 다시 보이지 않고 큐도 비어 있다. 아이템 상태(스와이프·골무 손)는 기존대로 반영된다.
func _check_finish_items() -> void:
	var gp: Node = await _spawn()
	_bind(gp)
	gp._state = gp.State.RUNNING
	_settle(3)
	_spy.calls.clear()
	_player.thimble_timer = Tuning.thimble_duration
	_player.autopilot_timer = Tuning.autopilot_duration
	gp._finish()
	_ok(gp.get_node("FinishViewLayer/FinishView").visible, "finish items a: finish view shown")
	_frame()
	_settle(30)
	_ok(_spy.calls.is_empty(), "finish items a: no item toast pushed (%d)" % _spy.calls.size())
	_ok(_spy.dismissed == 1, "finish items a: toast dismissed once (%d)" % _spy.dismissed)
	_ok(_pres._prev_thimble and _pres._prev_autopilot, "finish items a: item edges still consumed")
	_ok(_pres._mom_swipe > 0.0, "finish items a: mom swipe still driven")
	_unbind()
	gp.queue_free()
	await get_tree().process_frame
	# (b) 실제 Toast: 부상 대사 표시 중 완주 틱에 두 아이템을 함께 획득.
	gp = await _spawn()
	_bind(gp)
	_unbind()
	gp._state = gp.State.RUNNING
	_settle(3)
	_pres.set_next_cut_line_index(0)
	_cut_tick()
	_frame()
	var t: Toast = _pres._toast
	_ok(t._group.visible, "finish items b: hurt line shown before finish")
	_player.stun_timer = 0.0
	_player.thimble_timer = Tuning.thimble_duration
	_player.autopilot_timer = Tuning.autopilot_duration
	gp._finish()
	_frame()
	_ok(not t._busy and t._queue.is_empty(), "finish items b: slot released and queue empty")
	await get_tree().create_timer(0.3).timeout
	_settle(5)
	_ok(not t._group.visible, "finish items b: no toast visible after finish")
	_ok(t._queue.is_empty() and not t._busy, "finish items b: queue still empty")
	_ok(_live_tweens(t) == 0, "finish items b: no tween left")
	gp.queue_free()
	await get_tree().process_frame
	_done.append("finish_items")


func _live_tweens(t: Toast) -> int:
	return 1 if t._tween != null and t._tween.is_valid() and t._tween.is_running() else 0
