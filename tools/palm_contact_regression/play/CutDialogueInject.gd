extends Node
## 부상 대사 말풍선 상태 주입 보조 캡처(실제 입력 플레이 아님). 캡처 이름은 모두 inject_ 접두사.
## Gameplay 를 평소처럼 돌리되(RaceDirector 물리 틱·표현 모두 정상 구동, 입력 없음), 실제 플레이로 맞추기
## 어려운 시점에만 player/RaceDirector 필드를 물리 틱 직전에 주입한다.
##   pend_thimble : pending 5틱 뒤 골무 획득(grant_thimble, RaceDirector 픽업과 같은 호출) → 부상·대사 없음
##   pend_mom     : pending 5틱 뒤 엄마 찬스 획득(grant_autopilot) → 부상·대사 없음
##   same_tick    : 부상 실행 틱 == 원단 이탈 리셋 틱 → 부상 대사 먼저(즉시), 엄마 꾸중은 끝난 뒤
## 각 사례의 프레임을 seq/<case>_NN_fXXXXX.png 로 저장하고 사건을 INJECTCUT 줄로 출력한다.
## 인자: -- --inject-out=<dir>

const DT: float = 1.0 / 60.0

var _out: String = ""
var _gp: Node = null
var _p: Node = null
var _pres: Node = null
var _frame: int = 0
var _case: String = ""
var _idx: int = 0
var _rec: int = 0
var _every: int = 1
var _inject: Callable = Callable()  # 다음 물리 틱 직전에 한 번 실행할 주입


func _ready() -> void:
	process_priority = 1000
	process_physics_priority = -1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--inject-out="):
			_out = a.substr(13)
	DirAccess.make_dir_recursive_absolute(_out + "/seq")
	LeaderboardClient.tutorial_seen = true
	_gp = load("res://scenes/Gameplay.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_gp)
	await _f(3)
	_gp.set("_countdown_time", 0.01)
	_p = _gp.get_node("SimHost/FabricSource/World/Player")
	_pres = _gp.get_node("Presenter")
	RenderingServer.frame_post_draw.connect(_on_draw)
	await _f(30)
	await _run()
	_log("DONE")
	get_tree().quit()


func _log(msg: String) -> void:
	print("INJECTCUT [f%05d] %s" % [_frame, msg])


func _f(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _physics_process(_delta: float) -> void:
	if _inject.is_valid():
		var c: Callable = _inject
		_inject = Callable()
		c.call()


func _process(_delta: float) -> void:
	_frame += 1


func _toast() -> Toast:
	return _pres.get("_toast")


func _on_draw() -> void:
	if _rec <= 0:
		return
	_rec -= 1
	if _rec % _every != 0:
		return
	var t: Toast = _toast()
	var img: Image = get_viewport().get_texture().get_image()
	var name: String = "seq/%s_%02d_f%05d" % [_case, _idx, _frame]
	img.save_png(_out.path_join(name + ".png"))
	_idx += 1
	_log(
		(
			"%s pend=%.3f stun=%.2f off=%.2f thimble=%.2f ap=%.2f toast=\"%s\" imm=%s a=%.2f q=%d"
			% [
				name,
				_p.cut_pending_timer,
				_p.stun_timer,
				_p.offfabric_timer,
				_p.thimble_timer,
				_p.autopilot_timer,
				t._label.text if t._group.visible else "",
				t._immediate,
				t._group.modulate.a if t._group.visible else 0.0,
				t._queue.size(),
			]
		)
	)


func _record(case: String, frames: int, every: int = 1) -> void:
	_case = case
	_idx = 0
	_every = every
	_rec = frames


func _wait_clear() -> void:
	# 이전 사례의 스턴·이탈·아이템·토스트가 모두 끝날 때까지.
	for _i in range(600):
		var t: Toast = _toast()
		var busy: bool = t._busy or t._group.visible
		if (
			_p.stun_timer <= 0.0
			and _p.offfabric_timer <= 0.0
			and _p.thimble_timer <= 0.0
			and _p.autopilot_timer <= 0.0
			and not busy
		):
			return
		await _f(1)


func _start_pending() -> void:
	_p.risk = 1.0
	_p.speed_index = 5
	_p.cut_pending_timer = Tuning.cut_windup_duration


func _run() -> void:
	# 1) pending 중 골무 획득.
	await _wait_clear()
	var cuts0: int = int(_gp.get("_stats").cuts)
	_record("inject_pend_thimble", 40)
	_inject = _start_pending
	await _f(6)
	_inject = func() -> void: _p.grant_thimble()
	await _f(40)
	_log(
		(
			"pend_thimble: cuts %d->%d stage=%d toast=\"%s\""
			% [cuts0, _gp.get("_stats").cuts, _pres.get("_cut_stage"), _toast()._label.text]
		)
	)
	# 2) pending 중 엄마 찬스 획득.
	await _wait_clear()
	cuts0 = int(_gp.get("_stats").cuts)
	_record("inject_pend_mom", 40)
	_inject = _start_pending
	await _f(6)
	_inject = func() -> void: _p.grant_autopilot()
	await _f(40)
	_log(
		(
			"pend_mom: cuts %d->%d stage=%d toast=\"%s\""
			% [cuts0, _gp.get("_stats").cuts, _pres.get("_cut_stage"), _toast()._label.text]
		)
	)
	# 3) 부상 실행 틱 == 원단 이탈 리셋 틱(RaceDirector 실제 판정 순서).
	await _wait_clear()
	cuts0 = int(_gp.get("_stats").cuts)
	_pres.call("set_next_cut_line_index", 1)
	_record("inject_same_tick", 300, 6)
	_inject = func() -> void:
		_p.risk = 1.0
		_p.cut_pending_timer = DT * 0.5
		_p.position = _p.position + Vector2(0.0, 2000.0)
		_gp.set("_offfabric_dwell", float(_gp.get_script().get_script_constant_map()["RESET_DWELL"]))
	await _f(300)
	var stats: Object = _gp.get("_stats")
	_log("same_tick: cuts %d->%d resets=%d" % [cuts0, stats.cuts, stats.resets])
