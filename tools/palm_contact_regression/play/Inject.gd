extends Node
## 상태 주입 보조 검사(실제 입력 플레이 아님). 캡처 이름은 모두 inject_ 접두사.
## 인자: -- --out=<dir>

var _out: String = ""
var _gp: Node = null
var _pres: Node = null
var _p: Node = null
var _face: Control = null
var _nv: Node2D = null
var _lh: Node = null
var _rh: Node = null
var _cut_pts: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--inject-out="):
			_out = a.substr(13)
	DirAccess.make_dir_recursive_absolute(_out)
	LeaderboardClient.tutorial_seen = true
	_gp = load("res://scenes/Gameplay.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_gp)
	await _f(3)
	# 주입: 카운트다운을 건너뛰고 시뮬 틱을 멈춘다(표현 계층만 동작).
	_gp.set("_countdown_time", 0.01)
	await _f(5)
	_gp.set_physics_process(false)
	_pres = _gp.get_node("Presenter")
	_p = _gp.get_node("SimHost/FabricSource/World/Player")
	_face = _gp.get_node("BackdropLayer/FaceView")
	_nv = _gp.get_node("ForegroundLayer/NeedleView")
	_lh = _gp.get_node("ForegroundLayer/LeftHand")
	_rh = _gp.get_node("ForegroundLayer/RightHand")
	_load_cut()
	await _run()
	get_tree().quit()


func _f(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(_out.path_join(name + ".png"))
	print(
		"INJECT ",
		name,
		(
			" face_steer=%.3f cut_min_y=%.2f tip=%.2f L=%s R=%s mom_swipe=%.2f"
			% [
				float(_face.get("_steer")),
				_cut_min_y(),
				_nv.needle_tip_y(),
				_tex(_lh),
				_tex(_rh),
				float(_face.get("_mom_swipe")),
			]
		)
	)


func _tex(h: Node) -> String:
	var t: Variant = h.get("texture")
	return (t as Texture2D).resource_path.get_file() if t != null else "-"


func _steer(v: float) -> void:
	_p.target_steer = v
	_p.actual_steer = v


func _run() -> void:
	_p.speed_index = 3
	_p.speed = 170.0
	# 1) 최대 기울임 경계값 ±1 과 반대 전환 도중.
	_steer(1.0)
	await _f(90)
	await _shot("inject_face_steer_plus1")
	_steer(-1.0)
	for i in range(6):
		await _f(4)
		await _shot("inject_face_switch_plus_to_minus_%02d" % ((i + 1) * 4))
	await _f(90)
	await _shot("inject_face_steer_minus1")
	_steer(0.0)
	await _f(90)
	# 2) 바늘 끝점: 프로세스를 멈추고 위상만 주입.
	_nv.set_process(false)
	_nv.set("_phase", 0.0)
	_nv.queue_redraw()
	await _f(2)
	await _shot("inject_needle_top")
	_nv.set("_phase", 0.5)
	_nv.queue_redraw()
	await _f(2)
	await _shot("inject_needle_bottom")
	_nv.set_process(true)
	# 3) 부상 1·2·3 (스턴 상승엣지 주입 → 표현이 컷 단계를 올린다).
	for k in range(3):
		_p.stun_timer = 0.5
		await _f(4)
		await _shot("inject_cut%d" % (k + 1))
		_p.stun_timer = 0.0
		await _f(10)
	# 4) 부상3 + 골무
	_p.thimble_timer = 30.0
	await _f(20)
	await _shot("inject_cut3_thimble")
	# 5) 엄마 찬스 진입·hold·복귀(부상3+골무 상태에서)
	_p.autopilot_timer = 30.0
	await _f(10)
	await _shot("inject_mom_enter_mid")
	await _f(60)
	await _shot("inject_mom_hold")
	_p.autopilot_timer = 0.0
	await _f(10)
	await _shot("inject_mom_exit_mid")
	await _f(60)
	await _shot("inject_mom_exit_restored_cut3_thimble")
	_p.thimble_timer = 0.0
	await _f(20)
	await _shot("inject_thimble_end_restored_cut3")


func _load_cut() -> void:
	var img: Image = Image.load_from_file(
		ProjectSettings.globalize_path("res://assets/gfx/face_base_clean.png")
	)
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
		if u - start >= 16 and v0 >= 0 and v0 >= lowest - 16:
			for c in range(start, u):
				_cut_pts.append(Vector2(c + 0.5, v0 + 1.0))
		start = u


func _cut_min_y() -> float:
	var sz: Vector2 = _face.size
	var sc: float = float(_face.get("face_draw_scale"))
	var rect: Rect2 = Rect2(
		(sz.x - sz.x * sc) * 0.5, float(_face.get("face_offset_y")), sz.x * sc, sz.y * sc
	)
	var pivot: Vector2 = Vector2(
		rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.60
	)
	var steer: float = float(_face.get("_steer"))
	var xf: Transform2D = Transform2D(
		steer * 0.11, Vector2(steer * 24.0, 0.0) + pivot - pivot.rotated(steer * 0.11)
	)
	var worst: float = INF
	for b in _cut_pts:
		worst = minf(
			worst, (xf * (rect.position + Vector2(b.x / 1280.0, b.y / 720.0) * rect.size)).y
		)
	return worst
