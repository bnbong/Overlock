extends RefCounted
## 원단 이탈 페널티 알림(엄마 꾸중 말풍선) 실제 입력 플레이 시나리오. PlayDriver 가 호출한다.
## 조작은 PlayDriver 의 키·터치 주입(Input.parse_input_event)만 쓰고, 게임·토스트 상태는 읽기만 한다.
##
## 흐름: 메뉴 → tee_01 → 자동 조향으로 엄마 찬스(s≈1298, 일반 토스트) → 사선 직선(s≈2260)에서
## 조향 입력으로 트랙 이탈 강제 복귀 2회 연속(두 번째 알림이 큐에 쌓이는지) → 골무(s≈2884, 페널티 뒤
## 일반 토스트) → 토스트가 모두 끝날 때까지 대기. 결과 화면까지 가지 않으므로 기록 제출도 없다.
## 토스트 항목마다 시작 프레임·대사·초상화를 events.txt 에 남기고, 첫 페널티 항목은 페이드 인 중간·
## 완전 표시·페이드 아웃 중간·종료 직후를, 나머지 항목은 완전 표시를 캡처한다(play_ 접두사).

const R: GDScript = preload("res://play_driver/PlayRead.gd")
const PENALTY_TEXT: String = "이녀석, 제대로 해야지!"
# 변경 전 페널티 문구. 이전/이후 비교 캡처를 같은 시나리오로 찍을 때만 쓴다(게임 코드는 문자열로 판별하지 않음).
const LEGACY_PENALTY_TEXT: String = "원단 이탈! 재봉선 복귀"


static func _toast(d: Node) -> Node:
	var gp: Node = d._gp()
	if gp == null:
		return null
	var pres: Node = gp.get_node_or_null("Presenter")
	return pres.get("_toast") if pres != null else null


static func run(d: Node) -> void:
	var pre: String = "play_sm_" if d.touch_mode else "play_s_"
	d.steer_via_touch = d.touch_mode
	if not await d._menu_to_gameplay(pre):
		return
	d._run_index = 1
	await d._close_tutorial_if_any(pre)
	await d._wait_countdown(pre)
	d._ev("GO scold")
	d.auto_steer = true
	var state: Dictionary = {"done": false, "items": 0, "penalty": 0}
	_watch(d, pre, state)
	await d._wait(20)
	await d._gear_to(3)
	# 1) 엄마 찬스(자동 조향이 자연 획득) → 일반 토스트.
	await d._wait_until(func(): return d._player().autopilot_timer > 0.0, 4000, "mom chance")
	await d._wait_until(func(): return d._player().autopilot_timer <= 0.0, 1200, "mom end")
	await d._gear_to(3)
	# 2) 사선 직선에서 강제 복귀 2회 연속(바깥쪽=우조향, 다른 트랙 구간 없음).
	await d._wait_until(func(): return d._progress_s() >= 2260.0, 3000, "s>=2260")
	await d._induce_bonk("s1", 1, 4, false)
	# 두 번째는 첫 알림이 아직 떠 있는 동안 발동해 큐에 쌓이게 한다(5단, 더 크게 틀어 빨리 벗어남).
	await _quick_bonk(d, "s2", 1)
	await d._gear_to(3)
	# 3) 골무(자연 획득) → 페널티 뒤 일반 토스트.
	await d._wait_until(func(): return d._player().thimble_timer > 0.0, 3000, "thimble")
	await d._wait(10)  # 골무 토스트가 큐에 들어간 뒤부터 비워질 때까지 기다린다.
	# 4) 남은 토스트가 모두 끝날 때까지.
	var t: Node = _toast(d)
	await d._wait_until(
		func(): return t == null or not bool(t.get("_busy")), 1500, "toast queue drained"
	)
	await d._wait(20)
	d._ev(
		(
			"scold summary: toast items=%d penalty items=%d offfabric resets=%d"
			% [state["items"], state["penalty"], int(d._auto_caps.get("r1bonk", 0))]
		)
	)
	state["done"] = true


## 토스트 상태를 매 프레임 읽어 항목 시작·페이드 단계를 기록하고 캡처한다(병렬 코루틴).
static func _watch(d: Node, pre: String, state: Dictionary) -> void:
	var prev_a: float = 0.0
	var phase: String = "idle"  # idle → in → full → out
	var n: int = 0
	var is_pen: bool = false
	var full_frames: int = 0
	while not bool(state["done"]):
		await d.get_tree().process_frame
		var t: Node = _toast(d)
		if t == null:
			continue
		# 변경 전 Toast(비교 캡처용 사본)에는 _group·_portrait 가 없어 패널 알파로 대신 읽는다.
		var group: Control = t.get("_group") if t.get("_group") != null else t.get("_panel")
		var label: Label = t.get("_label")
		var portrait: TextureRect = t.get("_portrait")
		var a: float = group.modulate.a if group.visible else 0.0
		if phase == "idle" or phase == "out":
			if a > prev_a and prev_a <= 0.001 and a > 0.0:
				n += 1
				state["items"] = n
				is_pen = (
					(portrait != null and portrait.visible) or label.text == LEGACY_PENALTY_TEXT
				)
				if is_pen:
					state["penalty"] = int(state["penalty"]) + 1
				var tex: String = "-"
				if portrait != null and portrait.texture != null:
					tex = portrait.texture.resource_path.get_file()
				var p: Node = d._player()
				d._ev(
					(
						"EVENT toast #%d start text=\"%s\" portrait=%s penalty=%s exact=%s"
						% [n, label.text, tex, is_pen, label.text == PENALTY_TEXT]
						+ (
							" offfabric=%.2f bonk_active=%s font=%d"
							% [
								p.offfabric_timer if p != null else -1.0,
								d._face_bonk_active(),
								label.get_theme_font_size("font_size"),
							]
						)
					)
				)
				phase = "in"
				full_frames = 0
		if phase == "in":
			if n == 1 or (is_pen and int(state["penalty"]) == 1):
				if a >= 0.45 and prev_a < 0.45:
					_cap_phase(d, "%st%02d_fadein_mid" % [pre, n], a)
			if a >= 0.999:
				phase = "full"
		elif phase == "full":
			full_frames += 1
			if full_frames == 2:
				_cap_phase(d, "%st%02d_full%s" % [pre, n, "_penalty" if is_pen else ""], a)
			if a < prev_a:
				phase = "out"
		if phase == "out" and a < prev_a:
			if is_pen and int(state["penalty"]) == 1 and a <= 0.55 and prev_a > 0.55:
				_cap_phase(d, "%st%02d_fadeout_mid" % [pre, n], a)
		if phase == "out" and a <= 0.001 and prev_a > 0.001:
			d._ev("EVENT toast #%d end (group visible=%s)" % [n, group.visible])
			if is_pen:
				_cap_phase(d, "%st%02d_end" % [pre, n], a)
		prev_a = a


## 복귀 잠금이 풀리자마자 5단으로 올리고 dir 쪽으로 조향을 유지해 heading 을 약 70도 튼 뒤
## 키를 떼고 직진해 다시 강제 복귀를 일으킨다(실제 키·터치 입력, 상태는 읽기만).
static func _quick_bonk(d: Node, tag: String, dir: int) -> void:
	d.manual_override = true
	d._steer_hold(0)
	await d._wait_until(func(): return d._player().offfabric_timer <= 0.0, 200, "unlock")
	d._ev("quick bonk %s start s=%.0f" % [tag, d._progress_s()])
	d._steer_hold(dir)
	await d._gear_to(5)
	await d._wait_until(
		func(): return absf(R.heading_err_deg(d._gp())) >= 55.0, 240, "quick heading turn"
	)
	d._steer_hold(0)
	d._ev("quick bonk %s released heading_err=%.1f" % [tag, R.heading_err_deg(d._gp())])
	var hit: bool = await d._wait_until(
		func(): return d._player().offfabric_timer > 0.0, 600, "quick offfabric reset"
	)
	d._ev("quick bonk %s %s s=%.0f" % [tag, "triggered" if hit else "FAILED", d._progress_s()])
	await d._wait(3)
	await d._cap("play_%s_bonk_1_t3" % tag)
	await d._wait_until(func(): return d._player().offfabric_timer <= 0.0, 200, "offfabric end")
	d.manual_override = false


static func _cap_phase(d: Node, name: String, a: float) -> void:
	d._ev("toast phase %s alpha=%.3f" % [name, a])
	await d._cap(name)
