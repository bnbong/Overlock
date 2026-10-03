extends "res://drift_folds_regression/check_base.gd"
## 드리프트 주름 회귀 검사: Gameplay 씬을 수동 틱으로 돌리는 항목(check.gd가 상속해 실행).

# ---------------------------------------------------------------- gameplay helpers


func _new_game(running: bool = true, folds: bool = true) -> Node:
	get_tree().paused = false
	GameState.track_id = TRACK
	GameState.difficulty = "normal"
	var g: Node = GameplayScene.instantiate()
	get_tree().root.add_child(g)
	g.get_node("Presenter").drift_folds_enabled = folds
	await _frames(2)
	g.set_physics_process(false)
	if running:
		g._countdown_time = 0.0001
		g._physics_process(DT)
		await _frames(1)
	return g


func _free_game(g: Node) -> void:
	get_tree().paused = false
	_release_all()
	if is_instance_valid(g):
		g.queue_free()
	await _frames(2)


func _release_all() -> void:
	for a in RD.GAME_ACTIONS:
		Input.action_release(a)
	Input.flush_buffered_events()


func _press(steer: int, drift: bool) -> void:
	_release_all()
	if steer < 0:
		Input.action_press(&"steer_left")
	elif steer > 0:
		Input.action_press(&"steer_right")
	if drift:
		Input.action_press(&"drift")
	Input.flush_buffered_events()


## 한 틱 진행 + 표현 프레임 1회(PresentationController._process가 주름을 갱신).
func _tick(g: Node) -> void:
	g._physics_process(DT)
	await get_tree().process_frame


func _skid_of(g: Node) -> DriftSkid:
	return g.get_node("SimHost/FabricSource/World/DriftSkid")


func _folds_of(g: Node) -> DriftFoldLayer:
	return g.get_node("FabricLayer/DriftFolds")


## 결정론 입력 스크립트(가속·좌우 드리프트·급반전·연속 드리프트·아이템 사용).
func _script_input(g: Node, t: int) -> void:
	if t == 4 or t == 6:
		g._buf_speed_delta = 1
	var steer: int = 0
	var drift: bool = false
	var ph: int = t % 240
	if ph >= 40 and ph < 64:
		steer = 1
		drift = true
	elif ph >= 110 and ph < 130:
		steer = -1
		drift = true
	elif ph >= 130 and ph < 150:
		steer = 1
		drift = true
	elif ph >= 180 and ph < 200:
		steer = -1 if (t / 240) % 2 == 0 else 1
		drift = ph < 196
	elif ph >= 64 and ph < 90:
		steer = -1
	_press(steer, drift)
	if t % 300 == 299:
		g._buf_use_item = true


func _trace_row(g: Node) -> Array:
	var p: PlayerController = g._player
	return [
		p.position,
		p.heading,
		p.speed,
		p.risk,
		p.speed_index,
		p.actual_steer,
		p.is_drifting,
		p.drift_dir,
		p.offfabric_timer,
		p.autopilot_timer,
		p.thimble_timer,
		g._hint,
		g._elapsed,
		g._stats.penalty_time,
		g._stats.cuts,
		g._stats.resets,
		g.item_slots(),
		int(g._state),
	]


func _drive_trace(folds: bool, ticks: int) -> Dictionary:
	# 두 런이 같은 기록·고스트 상태에서 시작하도록 이 트랙의 저장 기록을 비운다(격리 user dir).
	RecordStore.purge(TRACK)
	var g: Node = await _new_game(true, folds)
	var trace: Array = []
	for t in ticks:
		_script_input(g, t)
		await _tick(g)
		trace.append(_trace_row(g))
	_release_all()
	var made: int = _skid_of(g).get_full_marks().size()
	g._finish()
	var result: Dictionary = g._pending_result.duplicate()
	result.erase("is_new_record")
	# 리뷰 8: 고스트 기록 내용(샘플·구간·완주·직렬화)도 비교한다.
	var gr: GhostRun = g._ghost_rec
	var ghost: Array = [
		gr.samples,
		gr.split_t,
		gr.split_pen,
		gr.split_valid,
		gr.finish_ms,
		gr.sample_count(),
		gr.skip_reason(),
		JSON.stringify(gr.to_ghost(result))
	]
	await _free_game(g)
	return {"trace": trace, "result": result, "folds": made, "ghost": ghost}


# ---------------------------------------------------------------- gameplay checks


func _check_game_on_off() -> void:
	var ticks: int = 1500
	var on: Dictionary = await _drive_trace(true, ticks)
	var off: Dictionary = await _drive_trace(false, ticks)
	var first_diff: int = -1
	for i in range(ticks):
		if on["trace"][i] != off["trace"][i]:
			first_diff = i
			break
	print(
		(
			"on/off: %d ticks compared, folds made ON=%d OFF=%d, first diff %d"
			% [ticks, on["folds"], off["folds"], first_diff]
		)
	)
	_ok(int(on["folds"]) > 10, "on/off: ON run actually generated folds")
	_ok(int(off["folds"]) == 0, "on/off: OFF run generated none")
	_ok(first_diff == -1, "on/off: position/time/RISK/items/state identical every tick")
	var diff_keys: Array = []
	for key in on["result"].keys():
		if not off["result"].has(key) or str(on["result"][key]) != str(off["result"][key]):
			diff_keys.append(key)
	for key in off["result"].keys():
		if not on["result"].has(key):
			diff_keys.append(key)
	if not diff_keys.is_empty():
		print("on/off: result diff keys ", diff_keys)
		for key in diff_keys:
			print("  ", key, " ON=", on["result"].get(key), " OFF=", off["result"].get(key))
	_ok(diff_keys.is_empty(), "on/off: finish result identical")
	_ok(int(on["ghost"][5]) > 10, "on/off: ghost recorded samples")
	_ok(on["ghost"] == off["ghost"], "on/off: ghost samples/splits/serialized ghost identical")
	var drifted: bool = false
	var resets: int = 0
	for row in on["trace"]:
		if bool(row[6]):
			drifted = true
		resets = maxi(resets, int(row[15]))
	_ok(drifted, "on/off: script drifted")
	print("on/off: resets during script %d" % resets)


func _check_game_gates() -> void:
	# 카운트다운: 드리프트 상태를 억지로 켜도 생성하지 않는다.
	var g: Node = await _new_game(false)
	# 레이어: 바닥(FabricWarp) 바로 위, 아이템 빌보드·손·노루발·HUD 아래.
	var fab: CanvasLayer = g.get_node("FabricLayer")
	var folds_node: Node = g.get_node("FabricLayer/DriftFolds")
	_ok(
		folds_node.get_index() > g.get_node("FabricLayer/FabricWarp").get_index(),
		"layer: folds drawn after floor"
	)
	var item_l: int = (g.get_node("ItemLayer") as CanvasLayer).layer
	var fg_l: int = (g.get_node("ForegroundLayer") as CanvasLayer).layer
	var hud_l: int = (g.get_node("HUD") as CanvasLayer).layer
	_ok(
		fab.layer < item_l and item_l < fg_l and fg_l < hud_l,
		"layer: floor < items < hands/foot < HUD"
	)
	_ok(
		not g.get_node("SimHost/FabricSource").is_ancestor_of(folds_node),
		"layer: folds not composited into floor viewport"
	)
	_ok(not g.is_racing(), "gate: countdown is not racing")
	var p: PlayerController = g._player
	for i in 20:
		p.is_drifting = true
		p.drift_dir = 0.8
		p.position += Vector2(10.0, 0.0)
		await get_tree().process_frame
	_ok(_skid_of(g).get_full_marks().is_empty(), "gate: no folds during countdown")
	await _free_game(g)
	# 완주 전환: 드리프트 중 완주 → 스트로크 끝, 이후 생성 없음, 완주 뷰가 같은 레코드를 받는다.
	g = await _new_game(true)
	g._buf_speed_delta = 2
	for i in 30:
		_press(1, true)
		await _tick(g)
	var skid: DriftSkid = _skid_of(g)
	_ok(skid.is_stroke_active(), "finish: stroke active while drifting")
	var count: int = skid.get_full_marks().size()
	_ok(count > 0, "finish: folds before finish")
	var live_before: bool = not skid.get_live_fold().is_empty()
	_ok(live_before, "finish: fingertip fold alive while drifting")
	var fx_before: float = float(g.get_node("Presenter")._fx_time)
	g._finish()
	await get_tree().process_frame
	_ok(not skid.is_stroke_active(), "finish: stroke ended on finish view")
	_ok(skid.get_live_fold().is_empty(), "finish: fingertip fold handed over at stroke end")
	# 손끝 주름은 그 자리에 고정된 패치 하나로 넘어갈 뿐, 완주 전환에서 새로 생기는 패치는 없다.
	var added: int = skid.get_full_marks().size() - count
	var handed_ok: bool = added == (1 if live_before else 0)
	if added == 1:
		handed_ok = handed_ok and float(skid.get_full_marks()[-1]["born"]) < fx_before
	_ok(
		handed_ok, "finish: no new patch at finish transition (only the fingertip fold handed over)"
	)
	count = skid.get_full_marks().size()
	var relaxed: bool = true
	for rec in skid.get_full_marks():
		if float(rec["relax"]) > float(g.get_node("Presenter")._fx_time) + 1e-6:
			relaxed = false
	_ok(relaxed, "finish: folds relax from finish (no abrupt removal)")
	p = g._player
	for i in 20:
		p.is_drifting = true
		p.drift_dir = 0.8
		p.position += Vector2(10.0, 0.0)
		await get_tree().process_frame
	_ok(skid.get_full_marks().size() == count, "finish: no folds during finish view")
	var fv: Node = g.get_node("FinishViewLayer/FinishView")
	_ok(fv.visible, "finish: finish view visible")
	_ok(
		is_same(fv._skid_marks, skid.get_full_marks()),
		"finish: finish view shares the same records"
	)
	var same_geo: bool = fv._skid_marks.size() == count
	for i in range(mini(fv._skid_marks.size(), count)):
		var a: Dictionary = fv._skid_marks[i]
		if not (a.has("rv") and a.has("tan") and Vector2(a["pos"]).is_finite()):
			same_geo = false
	_ok(same_geo, "finish: records keep position/direction/mesh for zoom-out")
	_ok(
		float(g.get_node("Presenter")._fx_time) >= fx_before, "finish: presentation clock continues"
	)
	await _free_game(g)


func _check_game_breaks() -> void:
	var g: Node = await _new_game(true)
	g._buf_speed_delta = 2
	for i in 20:
		_press(1, true)
		await _tick(g)
	var skid: DriftSkid = _skid_of(g)
	var sid: int = skid.stroke_id()
	_ok(sid >= 1 and skid.is_stroke_active(), "break: drifting stroke")
	# 드리프트 종료.
	for i in 3:
		_press(0, false)
		await _tick(g)
	_ok(not skid.is_stroke_active(), "break: drift end ends stroke")
	# 재시작(같은 방향 다시 드리프트) → 새 스트로크.
	for i in 12:
		_press(1, true)
		await _tick(g)
	_ok(skid.stroke_id() == sid + 1, "break: re-drift starts new stroke")
	# 순간이동(드리프트 유지).
	sid = skid.stroke_id()
	g._player.position += Vector2(260.0, 0.0)
	for i in 6:
		_press(1, true)
		await _tick(g)
	_ok(skid.stroke_id() > sid, "break: teleport starts new stroke")
	# 원단 이탈 강제 복귀(RaceDirector 실제 경로).
	for i in 6:
		_press(1, true)
		await _tick(g)
	sid = skid.stroke_id()
	var n_before: int = skid.get_near_folds().size()
	g._soft_reset_off_fabric()
	await get_tree().process_frame
	_ok(not skid.is_stroke_active(), "break: off-fabric reset ends stroke")
	var relax_ok: bool = true
	var now: float = skid.current_time()
	for rec in skid.get_near_folds():
		if int(rec["stroke"]) == sid and float(rec["relax"]) > now + 1e-6:
			relax_ok = false
	_ok(relax_ok, "break: reset stroke relaxes")
	# 잠금(offfabric_timer) 동안은 드리프트가 걸리지 않고, 끝난 뒤 새 스트로크.
	var guard: int = 0
	while g._player.offfabric_timer > 0.0 and guard < 300:
		_press(1, true)
		await _tick(g)
		guard += 1
	for i in 12:
		_press(1, true)
		await _tick(g)
	_ok(skid.stroke_id() > sid, "break: new stroke after reset")
	_ok(skid.get_near_folds().size() > n_before, "break: folds resume after reset")
	await _free_game(g)


func _check_game_sign() -> void:
	for dir in [1, -1]:
		var g: Node = await _new_game(true)
		g._buf_speed_delta = 2
		for i in 30:
			_press(0, false)
			await _tick(g)
		var skid: DriftSkid = _skid_of(g)
		var hand_ok: bool = false
		for i in 14:
			_press(dir, true)
			await _tick(g)
		var recs: Array = skid.get_near_folds()
		_ok(not recs.is_empty(), "sign %d: folds created" % dir)
		if recs.is_empty():
			await _free_game(g)
			continue
		var rec: Dictionary = recs[recs.size() - 1]
		_ok(float(rec["side"]) == float(dir), "sign %d: side follows drift_dir sign" % dir)
		var p: PlayerController = g._player
		var pr: Vector3 = DriftFoldLayer.project(rec["pos"], 0.0, p.position, p.heading, SCREEN)
		var on_side: bool = (pr.x - SCREEN.x * 0.5) * float(dir) > 0.0
		_ok(
			on_side,
			(
				"sign %d: fold center on the %s half of the screen"
				% [dir, "right" if dir > 0 else "left"]
			)
		)
		var rh: HandView = g.get_node("ForegroundLayer/RightHand")
		var lh: HandView = g.get_node("ForegroundLayer/LeftHand")
		var pressed: HandView = rh if dir > 0 else lh
		var other: HandView = lh if dir > 0 else rh
		hand_ok = pressed._drift_target > 0.0 and other._drift_target == 0.0
		_ok(hand_ok, "sign %d: pressing hand is on the fold side" % dir)
		# 손 실루엣(불투명 픽셀)에 가리지 않고 화면에 보이는 주름 비율(높이 가중). 드리프트 중 마지막 틱과,
		# 드리프트를 놓고 직진하는 20틱 동안의 평균.
		# 손끝 기준점: 화면 손끝을 바닥으로 역투영한 점을 다시 투영하면 같은 화면 점이어야 한다.
		var tip_s: Vector2 = pressed.position + pressed._slip_tip_local()
		var tip_w: Vector2 = g.get_node("Presenter")._fold_tip_world(
			float(dir), p.position, p.heading
		)
		var tip_re: Vector3 = DriftFoldLayer.project(tip_w, 0.0, p.position, p.heading, SCREEN)
		_ok(
			Vector2(tip_re.x, tip_re.y).distance_to(tip_s) < 0.01,
			"tip %d: fingertip back-projection round-trips" % dir
		)
		# 손끝 주름: 살아 있고, 높이 가중 중심이 손끝에서 가깝고, 손에 거의 가리지 않는다.
		var live: Dictionary = skid.get_live_fold()
		_ok(not live.is_empty(), "tip %d: fingertip fold alive while drifting" % dir)
		if not live.is_empty():
			var st: Array = _fold_stats(g, live, [rh, lh])
			print(
				(
					"tip %d: fingertip %s, fold centre %s (%.0f px away), under hands %.2f, max lift %.1f px"
					% [dir, tip_s, st[0], Vector2(st[0]).distance_to(tip_s), st[1], st[2]]
				)
			)
			_ok(
				Vector2(st[0]).distance_to(tip_s) < 90.0,
				"tip %d: fold centred near fingertip" % dir
			)
			_ok(float(st[1]) <= 0.1, "tip %d: fingertip fold not under the hands" % dir)
			_ok(float(st[2]) >= 30.0, "tip %d: fingertip fold lifts >= 30 px" % dir)
		var vis_drift: float = _visible_fold_fraction(g, [rh, lh])
		var foot_hits: int = _foot_overlap(g)
		var vis_sum: float = 0.0
		var vis_n: int = 0
		for i in 20:
			_press(0, false)
			await _tick(g)
			foot_hits = maxi(foot_hits, _foot_overlap(g))
			var f: float = _visible_fold_fraction(g, [rh, lh])
			if f >= 0.0:
				vis_sum += f
				vis_n += 1
		var vis_after: float = vis_sum / maxf(float(vis_n), 1.0)
		print(
			(
				"visibility %d: on-screen fold weight not under hands: drifting %.2f, after release avg %.2f"
				% [dir, vis_drift, vis_after]
			)
		)
		_ok(vis_drift >= 0.8, "visibility %d: >= 80%% of the fold visible while drifting" % dir)
		_ok(vis_after >= 0.8, "visibility %d: >= 80%% of the fold visible after release" % dir)
		print(
			(
				"foot %d: raised fold vertices over the presser-foot silhouette (max) %d"
				% [dir, foot_hits]
			)
		)
		_ok(foot_hits == 0, "foot %d: no raised fold vertex overlaps the presser foot" % dir)
		print(
			(
				"sign %d: side %+d, fold screen x %.0f, drift_dir %.2f"
				% [dir, int(rec["side"]), pr.x, p.drift_dir]
			)
		)
		await _free_game(g)


## 패치 하나의 [높이 가중 화면 중심, 손에 가린 비율, 최대 화면 솟음 px].
func _fold_stats(g: Node, rec: Dictionary, hands: Array) -> Array:
	var folds: DriftFoldLayer = _folds_of(g)
	var p: PlayerController = g._player
	var lifted: PackedVector2Array = folds.debug_project_patch(rec, SCREEN)
	var ground: PackedVector2Array = DriftFoldLayer.patch_world_grid(rec)
	var tot: float = 0.0
	var hid: float = 0.0
	var mean: Vector2 = Vector2.ZERO
	var lift: float = 0.0
	for k in range(lifted.size()):
		var wgt: float = DriftFoldShape.grid_h[k]
		var g0: Vector3 = DriftFoldLayer.project(ground[k], 0.0, p.position, p.heading, SCREEN)
		lift = maxf(lift, g0.y - lifted[k].y)
		if wgt <= 0.05:
			continue
		tot += wgt
		mean += lifted[k] * wgt
		for hand in hands:
			if _hand_covers(hand, lifted[k]):
				hid += wgt
				break
	return [mean / maxf(tot, 0.001), hid / maxf(tot, 0.001), lift]


## 솟은(높이 0.05 이상) 주름 정점 중 노루발 텍스처 불투명 픽셀 위에 투영되는 개수.
func _foot_overlap(g: Node) -> int:
	var needle: NeedleView = g.get_node("ForegroundLayer/NeedleView")
	var tex: Texture2D = needle.foot_texture
	if tex == null:
		return 0
	if not _hand_img_cache.has(tex):
		_hand_img_cache[tex] = tex.get_image()
	var img: Image = _hand_img_cache[tex]
	var rect: Rect2 = needle.foot_rect()
	var origin: Vector2 = needle.get_global_transform_with_canvas().origin
	var folds: DriftFoldLayer = _folds_of(g)
	var hits: int = 0
	for rec in folds.active_records():
		var pts: PackedVector2Array = folds.debug_project_patch(rec, SCREEN)
		for k in range(pts.size()):
			if DriftFoldShape.grid_h[k] < 0.05:
				continue
			var uv: Vector2 = (pts[k] - origin - rect.position) / rect.size
			if uv.x < 0.0 or uv.x >= 1.0 or uv.y < 0.0 or uv.y >= 1.0:
				continue
			var px: Vector2i = Vector2i(int(uv.x * img.get_width()), int(uv.y * img.get_height()))
			if img.get_pixelv(px).a > 0.5:
				hits += 1
	return hits


## 활성 주름 정점(높이 가중)이 손 불투명 픽셀 밖, 화면 안에 놓인 비율. 활성 패치가 없으면 -1.
## FOLD_DBG 환경변수가 있으면 패치별 가림을 출력한다.
func _visible_fold_fraction(g: Node, hands: Array) -> float:
	var folds: DriftFoldLayer = _folds_of(g)
	var total: float = 0.0
	var seen: float = 0.0
	var off: float = 0.0
	var dbg: bool = OS.get_environment("FOLD_DBG") != ""
	for rec in folds.active_records():
		var pts: PackedVector2Array = folds.debug_project_patch(rec, SCREEN)
		var r_tot: float = 0.0
		var r_hand: float = 0.0
		var r_mean: Vector2 = Vector2.ZERO
		for k in range(pts.size()):
			var wgt: float = DriftFoldShape.grid_h[k]
			if wgt <= 0.05:
				continue
			total += wgt
			r_tot += wgt
			var q: Vector2 = pts[k]
			r_mean += q * wgt
			if q.x < 0.0 or q.x > SCREEN.x or q.y < 0.0 or q.y > SCREEN.y:
				off += wgt
				continue
			var covered: bool = false
			for hand in hands:
				if _hand_covers(hand, q):
					covered = true
					break
			if covered:
				r_hand += wgt
			else:
				seen += wgt
		if dbg and r_tot > 0.0:
			print(
				(
					"    rec live=%s born=%.2f hand=%.2f mean=%s"
					% [rec.has("live"), float(rec["born"]), r_hand / r_tot, r_mean / r_tot]
				)
			)
	if total > 0.0:
		print(
			(
				"  vis detail: seen %.2f offscreen %.2f hand %.2f"
				% [seen / total, off / total, (total - seen - off) / total]
			)
		)
	# 화면 아래로 흘러 나간 부분은 가림이 아니므로 화면 안 비율로 본다.
	return -1.0 if total - off <= 0.0 else seen / (total - off)


## HandView._draw_hand_tex와 같은 변환을 거꾸로 풀어 화면 점이 손 텍스처 불투명 픽셀 위인지 본다.
func _hand_covers(hand: HandView, q: Vector2) -> bool:
	var tex: Texture2D = hand.texture
	if tex == null:
		return false
	if not _hand_img_cache.has(tex):
		_hand_img_cache[tex] = tex.get_image()
	var img: Image = _hand_img_cache[tex]
	var flip: float = -1.0 if hand.mirror else 1.0
	var sc: float = hand.press_scale()
	var rect: Rect2 = HandView.display_rect()
	var pivot: Vector2 = rect.get_center() + rect.size * HandView.PRESS_PIVOT
	var origin: Vector2 = hand._player_draw_offset() + Vector2(pivot.x * flip, pivot.y) * (1.0 - sc)
	var local: Vector2 = q - hand.get_global_transform_with_canvas().origin
	var r: Vector2 = Vector2((local.x - origin.x) / (flip * sc), (local.y - origin.y) / sc)
	var uv: Vector2 = (r - rect.position) / rect.size
	if uv.x < 0.0 or uv.x >= 1.0 or uv.y < 0.0 or uv.y >= 1.0:
		return false
	var px: Vector2i = Vector2i(int(uv.x * img.get_width()), int(uv.y * img.get_height()))
	return img.get_pixelv(px).a > 0.5


func _check_game_pause() -> void:
	var g: Node = await _new_game(true)
	g._buf_speed_delta = 2
	for i in 20:
		_press(1, true)
		await _tick(g)
	for i in 4:
		_press(0, false)
		await _tick(g)
	var pres: Node = g.get_node("Presenter")
	var folds: DriftFoldLayer = _folds_of(g)
	var skid: DriftSkid = _skid_of(g)
	var t0: float = float(pres._fx_time)
	var recs: Array = skid.get_near_folds()
	var a0: float = DriftFoldShape.amp01(float(recs[-1]["born"]), float(recs[-1]["relax"]), t0)
	get_tree().paused = true
	await _frames(30)
	var t1: float = float(pres._fx_time)
	var a1: float = DriftFoldShape.amp01(
		float(recs[-1]["born"]), float(recs[-1]["relax"]), skid.current_time()
	)
	_ok(t1 == t0, "pause: presentation clock stopped (%.4f -> %.4f)" % [t0, t1])
	_ok(a1 == a0 and a0 > 0.0, "pause: fold height frozen (%.3f)" % a0)
	_ok(folds.active_records().size() > 0, "pause: folds stay visible while paused")
	get_tree().paused = false
	await _frames(5)
	_ok(float(pres._fx_time) > t1, "pause: clock resumes")
	await _free_game(g)


func _check_game_restart() -> void:
	var g: Node = await _new_game(true)
	g._buf_speed_delta = 2
	for i in 30:
		_press(1 if i < 15 else -1, true)
		await _tick(g)
	_ok(_skid_of(g).get_full_marks().size() > 0, "restart: folds before restart")
	await _free_game(g)
	var g2: Node = await _new_game(false)
	await _frames(3)
	var skid: DriftSkid = _skid_of(g2)
	_ok(
		skid.get_full_marks().is_empty() and skid.get_near_folds().is_empty(),
		"restart: no residual records"
	)
	_ok(skid.stroke_id() == 0 and not skid.is_stroke_active(), "restart: stroke state reset")
	_ok(_folds_of(g2).active_records().is_empty(), "restart: no active fold meshes")
	var shape2: RefCounted = DriftFoldShape.new()
	var bakes2: int = int(shape2.call("bake_count")) if shape2.has_method("bake_count") else -1
	_ok(bakes2 == 1, "restart: height map bake reused (count %d)" % bakes2)
	await _free_game(g2)
