extends Node
## 원단 이탈 페널티 알림(엄마 꾸중 말풍선) 회귀 검사(사본 프로젝트 전용, run.sh 가 실행).
## 상태 주입 검사다: 토스트에 직접 push 하고 트윈을 멈춘 채 custom_step 으로 시간을 넘기며,
## PresentationController 는 _process 를 직접 불러 상승엣지를 만든다(실제 입력 플레이 아님).
## 실패한 assertion이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const ToastScene: PackedScene = preload("res://scenes/Toast.tscn")
const ToastSpy: GDScript = preload("res://palm_regression/toast_spy.gd")
const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const PENALTY_TEXT: String = "이녀석, 제대로 해야지!"
const PORTRAIT_PATH: String = "res://assets/gfx/ui/mom_scolding.png"
const FONT_PATH: String = "res://assets/fonts/Pretendard-Regular.woff2"
const NORMAL_A: String = "엄마 찬스! 3.0초 동안 자동 주행"
const NORMAL_B: String = "골무! 8.0초 동안 부상 면역"
# 일반 토스트 대사 폭(360px)을 넘겨 자동 줄바꿈(2줄 이상)이 일어나는 긴 일반 메시지.
const NORMAL_LONG: String = NORMAL_A + " · " + NORMAL_B + " · " + NORMAL_A
const DURATION: float = 3.6
const FADE: float = 0.28
const DT: float = 1.0 / 60.0
# 부상 대사(push_immediate): 세 문구, 눈물 초상화, 선점·갱신 페이드 인 시간.
const CUT_LINES: Array[String] = ["아얏!", "아파!", "아이고!"]
const HURT_PATH: String = "res://assets/gfx/ui/player_hurt_teary.png"
const IMM_FADE: float = 0.08
# 눈물 초상화 스티커 외곽(불투명) 범위: 원본 1254px 중 x 29..1227, y 8..1231(알파>0.05).
const HURT_STICKER_RIGHT: float = 1227.0 / 1254.0
const HURT_STICKER_BOTTOM: float = 1231.0 / 1254.0
const HURT_STICKER_TOP: float = 8.0 / 1254.0
# 엄마 말풍선 기존 배치(1280×720): 본체 680×82 하단 중앙 여백 38, 초상화 212 오프셋(-12, 4).
const MOM_PANEL_RECT: Rect2 = Rect2(300.0, 600.0, 680.0, 82.0)
const MOM_PORTRAIT_RECT: Rect2 = Rect2(288.0, 474.0, 212.0, 212.0)
# 스티커 외곽(불투명) 가로 범위: 원본 1254px 중 x 52..1202(알파>0.05).
const STICKER_RIGHT: float = 1202.0 / 1254.0
const STICKER_BOTTOM: float = 1220.0 / 1254.0
# 가리면 안 되는 화면 영역(1280×720 캔버스): 노루발, RISK 패널, 속도 패널.
const FOOT_RECT: Rect2 = Rect2(558.0, 299.0, 165.0, 174.0)
const RISK_MAX_X: float = 136.0
const SPEED_RECT: Rect2 = Rect2(1130.0, 442.0, 150.0, 278.0)

# 전체 실행 시 통과해야 하는 최소 검사 수. 검사가 의도치 않게 빠지거나 분기를 건너뛰면 실패로 잡는다
# (검사를 추가해 수가 늘면 이 값도 함께 올린다).
const MIN_PASSED: int = 330
# 끝까지 실행된 검사 구획 이름(최상위 구획과 중첩 검사 함수 모두). 스크립트 오류로 함수가 중간에
# 끊기면 호출자는 계속 진행하지만 이름이 여기에 남지 않아 마지막 대조에서 실패로 잡힌다.
const SECTIONS: Array[String] = [
	"hud_clearance",
	"penalty_layout",
	"font_glyphs",
	"mouse_filters",
	"queue",
	"while_showing",
	"last_hides",
	"reflow",
	"presenter",
	"imm_idle",
	"imm_preempt_normal",
	"imm_preempt_mom",
	"imm_preempt_fades",
	"imm_preempt_await",
	"imm_repeat",
	"imm_restore",
	"imm_lines",
	"imm_cleanup",
	"imm_pause",
]

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []


func _ready() -> void:
	LeaderboardClient.tutorial_seen = true
	# 루트가 자식 구성을 마친 뒤에 토스트를 붙인다(_ready 도중 add_child 는 실패).
	await get_tree().process_frame
	await _check_queue_and_styles()
	await _check_penalty_while_showing()
	await _check_penalty_last_hides_together()
	await _check_reflow_after_long()
	await _check_presenter_edges()
	await _check_imm_idle()
	await _check_imm_preempt_normal()
	await _check_imm_preempt_mom()
	await _check_imm_preempt_fades()
	await _check_imm_preempt_await()
	await _check_imm_repeat()
	await _check_imm_restore()
	await _check_imm_lines()
	await _check_imm_cleanup()
	await _check_imm_pause()
	_ok(_done == SECTIONS, "all check sections ran to completion (%s)" % [_done])
	# 이 가드 자신도 통과로 세므로 +1.
	var n_pass: int = _passed + 1
	_ok(n_pass >= MIN_PASSED, "passed count %d >= minimum %d" % [n_pass, MIN_PASSED])
	print("toast regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


func _new_toast() -> Toast:
	var t: Toast = ToastScene.instantiate()
	get_tree().root.add_child(t)
	await get_tree().process_frame
	_ok(t._label != null and t._group != null and t._portrait != null, "toast built in tree")
	return t


## 현재 항목의 트윈이 만들어질 때까지 기다린 뒤 모든 트윈을 멈춘다(이후 _step 으로만 진행).
## Toast._show_next 가 먼저 process_frame 을 기다리고 있으므로 같은 신호에서 이 코루틴이 나중에
## 깨어나, 트리가 트윈을 처리하기 전에 멈출 수 있다(실시간 경과가 섞이지 않음).
func _settle() -> void:
	await get_tree().process_frame
	var tweens: Array[Tween] = get_tree().get_processed_tweens()
	for tw in tweens:
		tw.pause()
	_ok(not tweens.is_empty(), "toast tween created and paused for stepping")


func _step(seconds: float) -> void:
	var left: float = seconds
	while left > 1e-6:
		var d: float = minf(DT, left)
		for tw in get_tree().get_processed_tweens():
			if tw.is_valid():
				tw.custom_step(d)
		left -= d


## 현재 항목의 표시 끝(페이드 아웃 완료)까지 진행하고 다음 항목이 자리를 잡게 한다.
func _finish_item() -> void:
	_step(FADE + DURATION + FADE + DT)
	await _settle()


func _alpha(t: Toast) -> float:
	return t._group.modulate.a


## 표시 스타일 스냅숏(대사 문자열 제외). 일반 스타일 복원 비교에 쓴다.
func _snap(t: Toast) -> Dictionary:
	var box: StyleBox = t._panel.get_theme_stylebox("panel")
	var d: Dictionary = {
		"font_size": t._label.get_theme_font_size("font_size"),
		"font": t._label.get_theme_font("font"),
		"font_override": t._label.has_theme_font_override("font"),
		"label_min": t._label.custom_minimum_size,
		"autowrap": t._label.autowrap_mode,
		"h_align": t._label.horizontal_alignment,
		"v_align": t._label.vertical_alignment,
		"panel_min": t._panel.custom_minimum_size,
		"box_class": box.get_class(),
		"margins":
		[
			box.content_margin_left,
			box.content_margin_right,
			box.content_margin_top,
			box.content_margin_bottom,
		],
		"tail": t._scold,
		"panel_size": t._panel.size,
		"panel_pos": t._panel.position,
		"portrait_visible": t._portrait.visible,
		"portrait_tex": t._portrait.texture,
	}
	if box is StyleBoxFlat:
		var f: StyleBoxFlat = box
		d["bg"] = f.bg_color
		d["border"] = [f.border_color, f.border_width_top, f.corner_radius_top_left]
		d["shadow"] = [f.shadow_color, f.shadow_size, f.shadow_offset]
	return d


func _same(a: Dictionary, b: Dictionary, step: String) -> void:
	for k in a.keys():
		var va: Variant = a[k]
		var vb: Variant = b.get(k)
		var eq: bool = va == vb
		if va is Vector2 and vb is Vector2:
			eq = (va as Vector2).is_equal_approx(vb)
		_ok(eq, "%s: %s same as reference (%s == %s)" % [step, k, va, vb])


## 일반 → 페널티 → 일반 연속 push: 큐 순서, 대사, 초상화 표시/숨김, 일반 스타일 복원, 페이드.
func _check_queue_and_styles() -> void:
	var t: Toast = await _new_toast()
	var tex: Texture2D = load(PORTRAIT_PATH)
	t.push(NORMAL_A)
	t.push(PENALTY_TEXT, tex)
	t.push(NORMAL_B)
	_ok(t._queue.size() == 2, "queue holds 2 pending items after 3 pushes")
	_ok(
		(
			t._queue.size() == 2
			and t._queue[0]["text"] == PENALTY_TEXT
			and t._queue[0]["portrait"] == tex
			and t._queue[1]["text"] == NORMAL_B
			and t._queue[1]["portrait"] == null
		),
		"queue order [penalty(portrait), normal(no portrait)] with per-item portrait"
	)
	await _settle()
	# 1) 첫 일반 항목.
	_ok(t._label.text == NORMAL_A, "1st shown item is NORMAL_A (got %s)" % t._label.text)
	_ok(not t._portrait.visible, "normal toast hides portrait")
	_ok(not t._portrait.is_visible_in_tree(), "normal toast portrait not visible in tree")
	_ok(t._label.get_theme_font_size("font_size") == 16, "normal toast font size 16")
	_ok(t._panel.get_theme_stylebox("panel") is StyleBoxFlat, "normal toast uses flat box")
	var view: Vector2 = t._root.size
	var ps: Vector2 = t._panel.size
	_ok(
		t._panel.position.is_equal_approx(
			Vector2((view.x - ps.x) * 0.5, view.y - ps.y - Toast._BOTTOM_MARGIN)
		),
		"normal toast bottom-centered with 64px margin (pos %s size %s view %s)" % [
			t._panel.position, ps, view
		]
	)
	var n1: Dictionary = _snap(t)
	_step(FADE * 0.5)
	_ok(absf(_alpha(t) - 0.5) < 0.08, "normal fade-in mid alpha ~0.5 (%.3f)" % _alpha(t))
	await _finish_item()
	# 2) 페널티 항목.
	_ok(t._label.text == PENALTY_TEXT, "2nd shown item text exact '%s'" % PENALTY_TEXT)
	_ok(t._portrait.visible and t._portrait.is_visible_in_tree(), "penalty shows portrait")
	_ok(
		t._portrait.texture != null and t._portrait.texture.resource_path == PORTRAIT_PATH,
		"penalty portrait texture is mom_scolding.png"
	)
	_ok(t._scold, "penalty draws bubble tail/stitch (_scold)")
	_ok(t._label.get_theme_font_size("font_size") > 16, "penalty uses larger dialogue font")
	_check_penalty_layout(t)
	_check_font_glyphs(t)
	_check_mouse_filters(t)
	# 함께 페이드: 그룹 알파만 바뀌고 패널·초상화 자체 알파는 1, 둘 다 같은 그룹의 자식.
	_ok(absf(_alpha(t)) < 0.08, "penalty starts transparent (%.3f)" % _alpha(t))
	_step(FADE * 0.5)
	_ok(absf(_alpha(t) - 0.5) < 0.08, "penalty fade-in mid alpha ~0.5 (%.3f)" % _alpha(t))
	_ok(
		(
			t._portrait.get_parent() == t._group
			and t._panel.get_parent() == t._group
			and t._portrait.modulate.a == 1.0
			and t._panel.modulate.a == 1.0
			and t._portrait.is_visible_in_tree()
			and t._panel.is_visible_in_tree()
		),
		"portrait and panel fade together as one group (fade-in)"
	)
	_step(FADE * 0.5 + DURATION)
	_ok(absf(_alpha(t) - 1.0) < 0.02, "penalty fully shown (%.3f)" % _alpha(t))
	_step(FADE * 0.5)
	_ok(
		absf(_alpha(t) - 0.5) < 0.08 and t._portrait.is_visible_in_tree(),
		"penalty fade-out mid alpha ~0.5 with portrait still in group (%.3f)" % _alpha(t)
	)
	await _finish_item()
	# 3) 다음 일반 항목: 모든 스타일이 페널티 이전 일반 항목과 같아야 한다.
	_ok(t._label.text == NORMAL_B, "3rd shown item is NORMAL_B (got %s)" % t._label.text)
	_ok(not t._portrait.visible, "normal after penalty hides portrait")
	var n2: Dictionary = _snap(t)
	_same(n1, n2, "normal after penalty")
	# 4) 마지막 항목 끝 → 그룹 숨김(패널·초상화 함께).
	_step(FADE + DURATION + FADE + DT)
	await get_tree().process_frame
	_ok(not t._busy and t._queue.is_empty(), "queue drained")
	_ok(
		not t._panel.is_visible_in_tree() and not t._portrait.is_visible_in_tree(),
		"after last fade-out panel and portrait hidden together"
	)
	t.queue_free()
	await get_tree().process_frame
	_done.append("queue")


## 일반 토스트 표시 중 페널티 push: 표시 중인 일반 토스트 스타일은 그대로.
func _check_penalty_while_showing() -> void:
	var t: Toast = await _new_toast()
	t.push(NORMAL_A)
	await _settle()
	_step(FADE + 1.0)
	var before: Dictionary = _snap(t)
	var a0: float = _alpha(t)
	t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	await get_tree().process_frame
	_ok(t._label.text == NORMAL_A, "showing normal text kept after penalty push")
	_same(before, _snap(t), "normal while penalty queued")
	_ok(absf(_alpha(t) - a0) < 1e-4, "showing normal alpha untouched by penalty push")
	await _finish_item()
	_ok(t._label.text == PENALTY_TEXT and t._portrait.visible, "queued penalty shown next")
	# 페널티 연속(이탈 2회): 두 번째도 큐에 쌓였다가 같은 말풍선 스타일로 한 번 더 뜬다.
	var pen1: Dictionary = _snap(t)
	t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	_ok(t._queue.size() == 1, "second penalty queued behind showing penalty")
	await _finish_item()
	_ok(t._label.text == PENALTY_TEXT and t._portrait.visible, "second penalty shown after first")
	_same(pen1, _snap(t), "penalty after penalty")
	t.queue_free()
	await get_tree().process_frame
	_done.append("while_showing")


## 페널티가 마지막 항목일 때: 페이드 아웃이 끝나면 초상화·패널이 같은 프레임에 함께 숨는다.
func _check_penalty_last_hides_together() -> void:
	var t: Toast = await _new_toast()
	t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	await _settle()
	_step(FADE + DURATION + FADE * 0.9)
	_ok(
		t._portrait.is_visible_in_tree() and t._panel.is_visible_in_tree(),
		"penalty (last) still visible near end of fade-out (alpha %.3f)" % _alpha(t)
	)
	_step(FADE * 0.1 + DT)
	_ok(
		not t._portrait.is_visible_in_tree() and not t._panel.is_visible_in_tree(),
		"penalty (last) portrait and panel hidden together after fade-out"
	)
	_ok(not t._busy, "toast idle after last penalty")
	t.queue_free()
	await get_tree().process_frame
	_done.append("last_hides")


## 페널티 표시 배치: 초상화 비율·위치, 대사 비겹침, 화면 HUD 영역 비가림.
func _check_penalty_layout(t: Toast) -> void:
	var pr: Rect2 = t._portrait.get_global_rect()
	var br: Rect2 = t._panel.get_global_rect()
	var tex: Texture2D = t._portrait.texture
	var src: Image = Image.load_from_file(ProjectSettings.globalize_path(PORTRAIT_PATH))
	_ok(src.get_size() == Vector2i(1254, 1254), "source PNG 1254x1254 (%s)" % src.get_size())
	_ok(is_equal_approx(pr.size.x, pr.size.y), "portrait display rect is square (%s)" % pr.size)
	_ok(
		is_equal_approx(pr.size.x * tex.get_height(), pr.size.y * tex.get_width()),
		"portrait display aspect == texture aspect (%s vs %s)" % [pr.size, tex.get_size()]
	)
	_ok(
		(
			t._portrait.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			and t._portrait.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
		),
		"portrait keeps aspect (STRETCH_KEEP_ASPECT_CENTERED)"
	)
	_ok(not t._group.clip_contents and not t._root.clip_contents, "no parent clipping")
	# 말풍선 왼쪽 위에 걸침: 머리는 말풍선 위, 바닥은 말풍선 바닥 근처, 왼쪽 끝은 말풍선 왼쪽 근처.
	_ok(pr.position.y < br.position.y - 60.0, "portrait head rises above bubble (%s)" % pr)
	var sticker_bottom: float = pr.position.y + pr.size.y * STICKER_BOTTOM
	_ok(
		absf(sticker_bottom - br.end.y) <= 6.0,
		"sticker bottom %.1f near bubble bottom %.1f" % [sticker_bottom, br.end.y]
	)
	_ok(absf(pr.position.x - br.position.x) <= 24.0, "portrait at bubble's left edge")
	_ok(pr.position.y >= 0.0 and pr.end.x <= t._root.size.x, "portrait inside viewport")
	# 대사와 초상화 비겹침: 대사 글자 영역 왼쪽 > 스티커 오른쪽 끝.
	var lr: Rect2 = t._label.get_global_rect()
	var font: Font = t._label.get_theme_font("font")
	var fs: int = t._label.get_theme_font_size("font_size")
	var tw: float = font.get_string_size(t._label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var text_l: float = lr.position.x + (lr.size.x - tw) * 0.5
	var sticker_r: float = pr.position.x + pr.size.x * STICKER_RIGHT
	_ok(text_l > sticker_r + 8.0, "dialogue x %.1f right of portrait %.1f" % [text_l, sticker_r])
	_ok(tw <= lr.size.x, "dialogue fits on one line (%.1f <= %.1f)" % [tw, lr.size.x])
	_ok(text_l + tw <= br.end.x - 16.0, "dialogue inside bubble right edge")
	# 꼬리: 말풍선 윗변 위, 꼭짓점은 초상화 쪽(왼쪽 위).
	var outline: PackedVector2Array = t.scold_outline()
	var tip: Vector2 = br.position + outline[outline.size() - 2]
	var base_l: Vector2 = br.position + outline[outline.size() - 3]
	_ok(tip.y < br.position.y and tip.x < base_l.x, "tail tip above bubble, pointing left (%s)" % tip)
	_ok(tip.x > sticker_r - 20.0 and tip.x < text_l, "tail between portrait and dialogue")
	# 화면 HUD 영역 비가림(1280×720 캔버스).
	var alert: Rect2 = br.merge(pr).merge(Rect2(tip, Vector2.ONE))
	_ok(not alert.intersects(FOOT_RECT), "alert avoids presser foot (%s)" % alert)
	_ok(alert.position.x > RISK_MAX_X, "alert right of RISK panel")
	_ok(not alert.intersects(SPEED_RECT), "alert avoids speed panel")
	_check_hud_clearance(br, pr, tip)
	_done.append("penalty_layout")


## Gameplay 씬 HUD 요소(상태 글·조작 안내·터치 버튼)와 말풍선의 겹침 검사.
func _check_hud_clearance(br: Rect2, pr: Rect2, tip: Vector2) -> void:
	var gp: Node = GameplayScene.instantiate()
	var status: Label = gp.get_node("HUD/StatusLabel")
	var hint: Label = gp.get_node("HUD/SteerHint")
	var font: Font = load(FONT_PATH)
	# 상태 글: 장면 오프셋(위 556~596, 가로 중앙 정렬) + 26px 글자 폭 + 외곽선.
	var s_fs: int = status.get_theme_font_size("font_size")
	var s_w: float = (
		font.get_string_size("원단 이탈 · 복귀", HORIZONTAL_ALIGNMENT_LEFT, -1, s_fs).x
		+ float(status.get_theme_constant("outline_size"))
	)
	var s_rect: Rect2 = Rect2(
		Vector2((1280.0 - s_w) * 0.5, status.offset_top),
		Vector2(s_w, status.offset_bottom - status.offset_top)
	)
	_ok(not br.intersects(s_rect), "bubble below status text %s (bubble %s)" % [s_rect, br])
	_ok(not s_rect.has_point(tip) and tip.x < s_rect.position.x, "tail clear of status text")
	_ok(pr.end.x < s_rect.position.x, "portrait left of status text")
	# 조작 안내(아래 앵커, 720 기준).
	var h_rect: Rect2 = Rect2(
		Vector2(640.0 + hint.offset_left, 720.0 + hint.offset_top),
		Vector2(hint.offset_right - hint.offset_left, hint.offset_bottom - hint.offset_top)
	)
	_ok(br.end.y + 2.0 <= h_rect.position.y, "bubble above steer hint %s" % h_rect)
	_ok(pr.end.y <= h_rect.position.y + 4.0, "portrait above steer hint")
	# 터치 버튼(1280×720, TouchControls 배치식과 같은 상수).
	var tc: TouchControls = TouchControls.new()
	tc.size = Vector2(1280.0, 720.0)
	var alert: Rect2 = br.merge(pr)
	for b in [0, 1, 2, 3, 4, 5]:
		var r: Rect2 = tc.button_rect(b)
		_ok(not alert.intersects(r), "alert avoids touch button %d %s" % [b, r])
	tc.free()
	gp.free()
	_done.append("hud_clearance")


## 대사 글자가 프로젝트 폰트(웹 서브셋)에 모두 있어야 한다(시스템 폴백 없는 웹에서 tofu 방지).
func _check_font_glyphs(t: Toast) -> void:
	var f: Font = load(FONT_PATH)
	var missing: String = ""
	for i in range(PENALTY_TEXT.length()):
		var c: int = PENALTY_TEXT.unicode_at(i)
		if not f.has_char(c):
			missing += PENALTY_TEXT[i]
	_ok(missing.is_empty(), "Pretendard subset has all dialogue glyphs (missing '%s')" % missing)
	var used: Font = t._label.get_theme_font("font")
	var base: Font = used
	if used is FontVariation:
		base = (used as FontVariation).base_font
	_ok(base != null and base.resource_path == FONT_PATH, "dialogue font based on project font")
	_done.append("font_glyphs")


func _check_mouse_filters(t: Toast) -> void:
	var nodes: Array[Node] = [t]
	var n_ctrl: int = 0
	var bad: String = ""
	while not nodes.is_empty():
		var n: Node = nodes.pop_back()
		if n is Control:
			n_ctrl += 1
			if (n as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
				bad += " " + n.get_class()
		nodes.append_array(n.get_children(true))
	_ok(n_ctrl >= 5 and bad.is_empty(), "all %d toast Controls MOUSE_FILTER_IGNORE%s" % [n_ctrl, bad])
	_done.append("mouse_filters")


## 표시 중인 패널의 배치(위치·크기).
func _box(t: Toast) -> Rect2:
	return Rect2(t._panel.position, t._panel.size)


## 기준 배치와 같은지(부동소수 근사) 확인한다.
func _same_box(ref: Rect2, got: Rect2, step: String) -> void:
	_ok(got.is_equal_approx(ref), "%s: panel rect %s same as reference %s" % [step, got, ref])


## 새 토스트에 texts 를 차례로 push 하고 첫 항목이 자리를 잡을 때까지 기다린다.
func _toast_with(texts: Array, penalty_first: bool) -> Toast:
	var t: Toast = await _new_toast()
	if penalty_first:
		t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	for s in texts:
		t.push(s)
	await _settle()
	return t


## 긴 일반 메시지(자동 줄바꿈) 뒤 짧은 일반 메시지: 앞 항목의 커진 패널 크기를 물려받지 않고
## 처음부터 짧은 메시지만 표시했을 때와 같은 크기·위치로 뜬다. 페널티가 앞에 있어도 같다.
func _check_reflow_after_long() -> void:
	# 기준: 짧은 메시지만, 긴 메시지만 각각 새 토스트에서 표시.
	var t: Toast = await _toast_with([NORMAL_B], false)
	var short_ref: Rect2 = _box(t)
	t.queue_free()
	t = await _toast_with([NORMAL_LONG], false)
	var long_ref: Rect2 = _box(t)
	var lines: int = t._label.get_line_count()
	t.queue_free()
	# 긴 메시지가 실제로 여러 줄이어야 아래 비교가 의미 있다(항상 참이 되는 검사 방지).
	_ok(lines >= 2, "long normal message wraps to %d lines (>= 2)" % lines)
	_ok(
		long_ref.size.y > short_ref.size.y + 8.0,
		"long normal panel taller than short (%s vs %s)" % [long_ref.size, short_ref.size]
	)
	# 긴 일반 → 짧은 일반.
	t = await _toast_with([NORMAL_LONG, NORMAL_B], false)
	_ok(t._label.text == NORMAL_LONG, "long shown first (got %s)" % t._label.text)
	_same_box(long_ref, _box(t), "long before short")
	await _finish_item()
	_ok(t._label.text == NORMAL_B, "short shown after long (got %s)" % t._label.text)
	_same_box(short_ref, _box(t), "short after long")
	t.queue_free()
	# 페널티 → 긴 일반 → 짧은 일반.
	t = await _toast_with([NORMAL_LONG, NORMAL_B], true)
	_ok(t._label.text == PENALTY_TEXT, "penalty shown first (got %s)" % t._label.text)
	await _finish_item()
	_ok(t._label.text == NORMAL_LONG, "long shown after penalty (got %s)" % t._label.text)
	_same_box(long_ref, _box(t), "long after penalty")
	await _finish_item()
	_ok(t._label.text == NORMAL_B, "short shown after penalty+long (got %s)" % t._label.text)
	_same_box(short_ref, _box(t), "short after penalty+long")
	t.queue_free()
	await get_tree().process_frame
	_done.append("reflow")


## PresentationController: 원단 이탈 상승엣지에서만 페널티 1회, 유지 중 반복 없음, 엄마 찬스·골무는
## 초상화 없는 일반 토스트.
func _check_presenter_edges() -> void:
	var gp: Node = GameplayScene.instantiate()
	get_tree().root.add_child.call_deferred(gp)
	await get_tree().process_frame
	await get_tree().process_frame
	gp.set_physics_process(false)
	gp.set_process(false)
	var pres: PresentationController = gp.get_node("Presenter")
	pres.set_process(false)
	var player: PlayerController = gp.get_node("SimHost/FabricSource/World/Player")
	var real: Toast = pres._toast
	var spy: Toast = ToastSpy.new()
	pres._toast = spy
	player.offfabric_timer = 0.0
	player.autopilot_timer = 0.0
	player.thimble_timer = 0.0
	player.stun_timer = 0.0
	pres._prev_offfabric = false
	pres._prev_autopilot = false
	pres._prev_thimble = false
	for i in range(5):
		pres._process(DT)
	_ok(spy.calls.is_empty(), "no toast without events (%d)" % spy.calls.size())
	player.offfabric_timer = Tuning.reset_lockout
	pres._process(DT)
	_ok(spy.calls.size() == 1, "off-fabric rising edge pushes exactly 1 toast")
	if spy.calls.size() >= 1:
		var c: Dictionary = spy.calls[0]
		_ok(c["text"] == PENALTY_TEXT, "penalty toast text exact (got '%s')" % c["text"])
		var ptex: Texture2D = c["portrait"]
		_ok(
			ptex != null and ptex.resource_path == PORTRAIT_PATH,
			"penalty toast passes mom_scolding.png portrait"
		)
	for i in range(30):
		pres._process(DT)
	_ok(spy.calls.size() == 1, "held off-fabric does not repeat penalty (%d)" % spy.calls.size())
	player.offfabric_timer = 0.0
	pres._process(DT)
	player.offfabric_timer = Tuning.reset_lockout
	pres._process(DT)
	_ok(spy.calls.size() == 2, "new rising edge pushes one more penalty (%d)" % spy.calls.size())
	player.offfabric_timer = 0.0
	pres._process(DT)
	player.autopilot_timer = 3.0
	pres._process(DT)
	player.autopilot_timer = 0.0
	player.thimble_timer = 8.0
	pres._process(DT)
	_ok(spy.calls.size() == 4, "mom chance + thimble push 2 toasts (%d)" % spy.calls.size())
	if spy.calls.size() == 4:
		_ok(
			str(spy.calls[2]["text"]).begins_with("엄마 찬스!") and spy.calls[2]["portrait"] == null,
			"mom chance toast has no portrait"
		)
		_ok(
			str(spy.calls[3]["text"]).begins_with("골무!") and spy.calls[3]["portrait"] == null,
			"thimble toast has no portrait"
		)
	pres._toast = real
	spy.free()
	gp.queue_free()
	await get_tree().process_frame
	_done.append("presenter")


# --- 부상 대사 즉시 표시(push_immediate) ---


## 검사 구획 끝: 토스트를 해제하고 구획 이름을 남긴다.
func _end(t: Toast, section: String) -> void:
	t.queue_free()
	await get_tree().process_frame
	_done.append(section)


## 지금 살아 있는(kill 되지 않은) 트윈 수.
func _live_tweens() -> int:
	var n: int = 0
	for tw in get_tree().get_processed_tweens():
		if tw.is_valid():
			n += 1
	return n


## 지금 있는 트윈을 모두 멈춘다(동기 호출 직후 실시간 경과가 섞이지 않게).
func _pause_tweens() -> void:
	for tw in get_tree().get_processed_tweens():
		if tw.is_valid():
			tw.pause()


## 패널·초상화 배치가 기준(_layout 결과)과 같은지.
func _placed(t: Toast, ref: Array[Rect2]) -> bool:
	return (
		t._panel.get_global_rect().is_equal_approx(ref[0])
		and t._portrait.get_global_rect().is_equal_approx(ref[1])
	)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


## 보이는 대사·초상화·스타일이 한 항목으로 일치하는지(엄마 초상화 + 부상 대사 같은 섞임 방지).
func _coherent(t: Toast) -> bool:
	if not t._group.visible:
		return true
	var text: String = t._label.text
	var box: StyleBox = t._panel.get_theme_stylebox("panel")
	var tex: String = t._portrait.texture.resource_path if t._portrait.texture != null else ""
	if text in CUT_LINES:
		return t._portrait.visible and tex == HURT_PATH and t._scold and box is StyleBoxEmpty
	if text == PENALTY_TEXT:
		return t._portrait.visible and tex == PORTRAIT_PATH and t._scold
	return not t._portrait.visible and not t._scold and box is StyleBoxFlat


## 표시 배치(패널·초상화·대사 글자 영역) 스냅숏.
func _layout(t: Toast) -> Array[Rect2]:
	return [t._panel.get_global_rect(), t._portrait.get_global_rect(), t._label.get_global_rect()]


func _same_layout(a: Array[Rect2], b: Array[Rect2], step: String) -> void:
	var eq: bool = a.size() == b.size()
	for i in range(mini(a.size(), b.size())):
		eq = eq and a[i].is_equal_approx(b[i])
	_ok(eq, "%s: layout %s same as %s" % [step, a, b])


## 일반 스타일 기준 스냅숏: 새 토스트에 text 만 표시했을 때.
func _normal_ref(text: String) -> Dictionary:
	var r: Toast = await _toast_with([text], false)
	var d: Dictionary = _snap(r)
	r.queue_free()
	await get_tree().process_frame
	return d


## 빈 상태에서 push_immediate: 호출한 프레임에 대사·초상화·스타일·배치가 모두 정해지고, 일반 push 와
## 같은 페이드 인(0.28초)·표시 시간(3.6초)으로 뜬 뒤 사라진다. 큐에는 들어가지 않는다.
func _check_imm_idle() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	# 기준: 같은 대사·초상화를 일반 push 로 띄운 배치.
	var r: Toast = await _new_toast()
	r.push(CUT_LINES[0], hurt)
	await _settle()
	await _frames(2)
	var ref: Array[Rect2] = _layout(r)
	r.queue_free()
	await get_tree().process_frame
	var t: Toast = await _new_toast()
	t.push_immediate(CUT_LINES[0], hurt)
	_pause_tweens()
	_ok(t._label.text == CUT_LINES[0] and _coherent(t), "idle immediate text+hurt portrait at once")
	_ok(t._scold and t._group.visible and t._busy and t._immediate, "idle immediate slot taken")
	_ok(t._queue.is_empty() and _live_tweens() == 1, "idle immediate: not queued, one tween")
	_ok(absf(_alpha(t)) < 1e-4, "idle immediate starts transparent (%.3f)" % _alpha(t))
	# 배치는 호출 프레임에 이미 하단 중앙(대기 프레임 없음).
	_ok(_placed(t, ref), "idle immediate panel/portrait placed in the calling frame")
	await get_tree().process_frame
	_same_layout(_layout(t), ref, "idle immediate next frame")
	_ok(_coherent(t), "idle immediate coherent")
	_step(IMM_FADE * 0.5)
	_ok(absf(_alpha(t) - 0.5) < 0.08, "idle immediate fade-in 0.08s (mid %.3f)" % _alpha(t))
	_step(IMM_FADE * 0.5 + DURATION - 0.05)
	_ok(absf(_alpha(t) - 1.0) < 0.02, "idle immediate held until 3.6s (%.3f)" % _alpha(t))
	_step(0.05 + FADE * 0.5)
	_ok(absf(_alpha(t) - 0.5) < 0.08, "idle immediate fade-out mid (%.3f)" % _alpha(t))
	_step(FADE * 0.5 + DT)
	await get_tree().process_frame
	var idle: bool = not t._busy and not t._immediate and not t._group.visible
	_ok(idle and t._portrait.texture == null, "idle immediate ends hidden, portrait released")
	_ok(_live_tweens() == 0 and t._queue.is_empty(), "no tween/queue left after immediate")
	await _end(t, "imm_idle")


## 일반 알림 표시 중 선점: 현재 일반 항목 종료(재표시 없음), 대기 큐 순서 유지, 알파 연속.
func _check_imm_preempt_normal() -> void:
	var ref_b: Dictionary = await _normal_ref(NORMAL_B)
	var hurt: Texture2D = load(HURT_PATH)
	var t: Toast = await _new_toast()
	t.push(NORMAL_A)
	t.push(NORMAL_B)
	t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	await _settle()
	_step(FADE + 1.0)
	_ok(t._label.text == NORMAL_A and absf(_alpha(t) - 1.0) < 0.02, "normal A fully shown")
	var old_tw: Tween = t._tween
	t.push_immediate(CUT_LINES[1], hurt)
	_pause_tweens()
	_ok(old_tw != null and not old_tw.is_valid(), "preempted normal tween killed")
	_ok(_live_tweens() == 1, "one live tween after preempt (%d)" % _live_tweens())
	_ok(t._label.text == CUT_LINES[1] and _coherent(t), "preempt normal: coherent in calling frame")
	_ok(absf(_alpha(t) - 1.0) < 0.02, "alpha continues from 1 (no blink) %.3f" % _alpha(t))
	var q: Array = t._queue.map(func(it: Dictionary) -> String: return it["text"])
	_ok(q == [NORMAL_B, PENALTY_TEXT], "pending queue kept in order [B, penalty] (%s)" % [q])
	var shown: Array[String] = [t._label.text]
	_step(IMM_FADE + DURATION + FADE + DT)
	await _settle()
	shown.append(t._label.text)
	_same(ref_b, _snap(t), "normal B after preempting immediate")
	await _finish_item()
	shown.append(t._label.text)
	_ok(_coherent(t), "penalty after immediate coherent")
	_step(FADE + DURATION + FADE + DT)
	await get_tree().process_frame
	_ok(not t._busy and t._queue.is_empty(), "queue drained after preempt")
	_ok(
		shown == [CUT_LINES[1], NORMAL_B, PENALTY_TEXT],
		"display order immediate -> B -> penalty, A not re-shown (%s)" % [shown]
	)
	await _end(t, "imm_preempt_normal")


## 엄마 말풍선 표시 중 선점: 선점 전 2프레임 ~ 후 6프레임 동안 어느 프레임에도 엄마 초상화와 부상
## 대사가 함께 보이지 않고, 첫 프레임부터 새 배치(대사 글자 영역 포함)가 자리를 잡는다.
func _check_imm_preempt_mom() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	var t: Toast = await _new_toast()
	t.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	await _settle()
	_step(FADE + 1.0)
	var mom_layout: Array[Rect2] = _layout(t)
	var bad: int = 0
	for _i in range(2):
		await get_tree().process_frame
		_step(DT)
		if not _coherent(t) or t._label.text != PENALTY_TEXT:
			bad += 1
	t.push_immediate(CUT_LINES[2], hurt)
	_pause_tweens()
	_ok(_coherent(t), "preempt mom: coherent in calling frame")
	_ok(t._panel.get_theme_stylebox("panel") is StyleBoxEmpty, "preempt mom: bubble style kept")
	var first: Array[Rect2] = []
	for i in range(6):
		await get_tree().process_frame
		if i == 0:
			first = _layout(t)
		_step(DT)
		if not _coherent(t) or t._label.text != CUT_LINES[2]:
			bad += 1
	_ok(bad == 0, "no frame mixes mom portrait and hurt line (bad %d)" % bad)
	_same_layout(first, _layout(t), "preempt mom first frame vs settled")
	_same_layout(first, mom_layout, "hurt bubble same rects as mom bubble")
	_ok(_live_tweens() == 1, "one live tween after mom preempt (%d)" % _live_tweens())
	await _end(t, "imm_preempt_mom")


## 페이드 인 중·페이드 아웃 중 선점: 알파는 그 값에서 이어서 짧게(0.08초) 1까지 올라간다.
func _check_imm_preempt_fades() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	for phase in ["fade_in", "fade_out"]:
		var t: Toast = await _new_toast()
		t.push(NORMAL_A)
		await _settle()
		if phase == "fade_in":
			_step(FADE * 0.4)
		else:
			_step(FADE + DURATION + FADE * 0.6)
		var a0: float = _alpha(t)
		_ok(a0 > 0.2 and a0 < 0.7, "%s: normal mid-fade alpha %.3f" % [phase, a0])
		t.push_immediate(CUT_LINES[0], hurt)
		_pause_tweens()
		_ok(absf(_alpha(t) - a0) < 1e-4, "%s: alpha continuous at preempt" % phase)
		_ok(_live_tweens() == 1, "%s: one live tween (%d)" % [phase, _live_tweens()])
		_ok(_coherent(t) and t._label.text == CUT_LINES[0], "%s: immediate shown" % phase)
		var prev: float = _alpha(t)
		var mono: bool = true
		for _i in range(5):
			_step(DT)
			mono = mono and _alpha(t) >= prev - 1e-4
			prev = _alpha(t)
		_ok(mono and absf(_alpha(t) - 1.0) < 0.02, "%s: rises to 1 in 0.08s" % phase)
		_step(DURATION - 0.1)
		_ok(absf(_alpha(t) - 1.0) < 0.02, "%s: held with fresh duration" % phase)
		t.queue_free()
		await get_tree().process_frame
	_done.append("imm_preempt_fades")


## 일반 항목이 process_frame 을 기다리는 사이 선점: 깨어난 오래된 작업이 배치·트윈·큐를 건드리지 않는다.
func _check_imm_preempt_await() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	var t: Toast = await _new_toast()
	t.push(NORMAL_A)
	t.push(NORMAL_B)
	t.push_immediate(CUT_LINES[1], hurt)
	_pause_tweens()
	var lay: Array[Rect2] = _layout(t)
	var a0: float = _alpha(t)
	await get_tree().process_frame
	_pause_tweens()
	_ok(_live_tweens() == 1, "stale await adds no tween (%d)" % _live_tweens())
	_ok(absf(_alpha(t) - a0) < 1e-4 and _placed(t, lay), "stale await leaves alpha/placement")
	_ok(t._queue.size() == 1 and t._queue[0]["text"] == NORMAL_B, "stale await leaves queue")
	_ok(t._label.text == CUT_LINES[1] and _coherent(t), "immediate still shown")
	# 1초 뒤 갱신: 선점된 작업이 남긴 트윈이 있으면 첫 즉시 알림의 트윈이 끊기지 않고 남아, 그
	# 콜백(첫 호출 + 3.96초)이 갱신된 알림을 일찍 끝낸다.
	_step(1.0)
	t.push_immediate(CUT_LINES[2], hurt)
	_pause_tweens()
	_ok(_live_tweens() == 1, "refresh after stale await: one live tween (%d)" % _live_tweens())
	_step(DURATION - 0.2)
	_ok(
		t._label.text == CUT_LINES[2] and absf(_alpha(t) - 1.0) < 0.02 and t._queue.size() == 1,
		"refreshed line held full duration (%s, %.3f)" % [t._label.text, _alpha(t)]
	)
	_step(IMM_FADE + 0.2 + FADE + DT)
	await _settle()
	_ok(t._label.text == NORMAL_B and _coherent(t), "B shown next, A dropped (%s)" % t._label.text)
	_ok(_live_tweens() == 1, "one live tween for B (%d)" % _live_tweens())
	# 오래된 작업의 트윈이 남아 있었다면 그 콜백(0.28+3.6+0.28초)이 여기서 B 를 끝내 버린다.
	_step(0.5)
	_ok(
		t._label.text == NORMAL_B and t._group.visible and absf(_alpha(t) - 1.0) < 0.02,
		"B still fully shown 0.5s later (no stale callback, alpha %.3f)" % _alpha(t)
	)
	_step(FADE + DURATION + FADE + DT - 0.5)
	await get_tree().process_frame
	_ok(not t._busy and not t._group.visible, "drained after B")
	await _end(t, "imm_preempt_await")


## 연속 push_immediate 3회: 마지막 대사만, 표시 시간은 마지막 호출부터, 지난 대사는 다시 안 나온다.
func _check_imm_repeat() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	var t: Toast = await _new_toast()
	var jumps: bool = false
	for i in range(3):
		var a0: float = _alpha(t)
		t.push_immediate(CUT_LINES[i], hurt)
		_pause_tweens()
		if i > 0 and absf(_alpha(t) - a0) > 1e-4:
			jumps = true
		_ok(_live_tweens() == 1 and t._queue.is_empty(), "repeat %d: one tween, no queue" % i)
		if i < 2:
			_step(2.0)
	_ok(not jumps, "repeat: alpha continuous across refresh")
	_ok(t._label.text == CUT_LINES[2] and _coherent(t), "repeat: last line shown")
	# 첫 호출 기준이면 0.28+3.6+0.28 = 4.16초에 끝났어야 하지만 마지막 호출부터 다시 센다.
	_step(IMM_FADE + DURATION - 0.1)
	_ok(absf(_alpha(t) - 1.0) < 0.02, "repeat: still held 3.58s after last call (4+ s total)")
	_step(0.1 + FADE + DT)
	await get_tree().process_frame
	_ok(not t._busy and not t._group.visible, "repeat: hidden after last duration")
	await _frames(3)
	_ok(not t._group.visible and t._label.text == CUT_LINES[2], "repeat: no stale line reappears")
	_ok(_live_tweens() == 0, "repeat: no live tween left (%d)" % _live_tweens())
	await _end(t, "imm_repeat")


## 즉시 알림 뒤 일반 알림: 즉시 알림 중 push 는 큐에 쌓이고, 다음 일반 항목은 스타일이 모두 복원된다.
func _check_imm_restore() -> void:
	var ref_b: Dictionary = await _normal_ref(NORMAL_B)
	var t: Toast = await _new_toast()
	t.push_immediate(CUT_LINES[0], load(HURT_PATH))
	_pause_tweens()
	t.push(NORMAL_B)
	_ok(t._queue.size() == 1 and t._label.text == CUT_LINES[0], "push during immediate queues")
	_step(FADE + DURATION + FADE + DT)
	await _settle()
	_ok(t._label.text == NORMAL_B and not t._immediate, "normal after immediate shown")
	_same(ref_b, _snap(t), "normal after immediate")
	await _end(t, "imm_restore")


## 세 문구 각각(고정 지정): 글리프, 대사 위치(초상화 오른쪽·말풍선 안·글자 영역 중앙), 초상화 사각형·
## 비율, 엄마 말풍선과 같은 본체 배치. 엄마 말풍선 기존 배치 값도 그대로인지 확인한다.
func _check_imm_lines() -> void:
	var f: Font = load(FONT_PATH)
	var m: Toast = await _new_toast()
	m.push(PENALTY_TEXT, load(PORTRAIT_PATH))
	await _settle()
	await _frames(2)
	var mom: Array[Rect2] = _layout(m)
	_ok(mom[0].is_equal_approx(MOM_PANEL_RECT), "mom bubble rect unchanged %s" % mom[0])
	_ok(mom[1].is_equal_approx(MOM_PORTRAIT_RECT), "mom portrait rect unchanged %s" % mom[1])
	m.queue_free()
	var src: Image = Image.load_from_file(ProjectSettings.globalize_path(HURT_PATH))
	_ok(src.get_size() == Vector2i(1254, 1254), "hurt PNG 1254x1254 (%s)" % src.get_size())
	for line in CUT_LINES:
		var missing: String = ""
		for i in range(line.length()):
			if not f.has_char(line.unicode_at(i)):
				missing += line[i]
		_ok(missing.is_empty(), "'%s' glyphs in Pretendard subset (missing '%s')" % [line, missing])
		var t: Toast = await _new_toast()
		t.push_immediate(line, load(HURT_PATH))
		_pause_tweens()
		await _frames(2)
		_ok(t._label.text == line and _coherent(t), "'%s' shown exact with hurt portrait" % line)
		var lay: Array[Rect2] = _layout(t)
		_same_layout(lay, mom, "'%s' rects vs mom bubble" % line)
		var pr: Rect2 = lay[1]
		var br: Rect2 = lay[0]
		var lr: Rect2 = lay[2]
		var tex: Texture2D = t._portrait.texture
		var keep: bool = t._portrait.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var sq: bool = is_equal_approx(pr.size.x, pr.size.y) and tex.get_width() == tex.get_height()
		_ok(keep and sq, "'%s' portrait 1:1 keep-aspect (%s, %s)" % [line, pr.size, tex.get_size()])
		var head: float = pr.position.y + pr.size.y * HURT_STICKER_TOP
		_ok(head >= 0.0 and head < br.position.y - 60.0, "'%s' head above bubble %.1f" % [line, head])
		var bottom: float = pr.position.y + pr.size.y * HURT_STICKER_BOTTOM
		_ok(absf(bottom - br.end.y) <= 6.0, "'%s' sticker bottom %.1f near bubble" % [line, bottom])
		var fs: int = t._label.get_theme_font_size("font_size")
		var used: Font = t._label.get_theme_font("font")
		var tw: float = used.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var text_l: float = lr.position.x + (lr.size.x - tw) * 0.5
		var sticker_r: float = pr.position.x + pr.size.x * HURT_STICKER_RIGHT
		_ok(text_l > sticker_r + 8.0, "'%s' x %.1f right of portrait %.1f" % [line, text_l, sticker_r])
		_ok(text_l + tw <= br.end.x - 16.0, "'%s' inside bubble right edge" % line)
		_ok(t._label.get_line_count() == 1 and tw <= lr.size.x, "'%s' one line" % line)
		var al: Array = [t._label.horizontal_alignment, t._label.vertical_alignment]
		_ok(al == [HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER], "'%s' centered" % line)
		t.queue_free()
		await get_tree().process_frame
	_done.append("imm_lines")


## 정리: 트리에서 빠지면 트윈·큐·초상화가 비고, 다시 붙이면 일반 push 가 정상 동작. 대기 중 해제,
## 같은 프레임 연속 선점도 남는 트윈이 없다.
func _check_imm_cleanup() -> void:
	var hurt: Texture2D = load(HURT_PATH)
	var t: Toast = await _new_toast()
	t.push(NORMAL_A)
	await _settle()
	t.push_immediate(CUT_LINES[0], hurt)
	t.push(NORMAL_B)
	_pause_tweens()
	var parent: Node = t.get_parent()
	parent.remove_child(t)
	_ok(t._queue.is_empty() and not t._busy and not t._immediate, "exit tree clears queue/slot")
	var gone: bool = t._portrait.texture == null and not t._group.visible and t._tween == null
	_ok(gone and _live_tweens() == 0, "exit tree kills tween, releases portrait")
	parent.add_child(t)
	t.push(NORMAL_B)
	await _settle()
	_ok(t._label.text == NORMAL_B and _coherent(t), "re-added toast shows normal push")
	t.queue_free()
	await get_tree().process_frame
	# 대기(process_frame) 중 해제: 남는 트윈 없음.
	t = await _new_toast()
	t.push(NORMAL_A)
	t.queue_free()
	await _frames(3)
	_ok(_live_tweens() == 0, "freed while awaiting: no tween (%d)" % _live_tweens())
	t = await _new_toast()
	t.push_immediate(CUT_LINES[1], hurt)
	t.queue_free()
	await _frames(2)
	_ok(_live_tweens() == 0, "freed while immediate: no tween (%d)" % _live_tweens())
	# 선점 직후 곧바로 또 선점(같은 프레임).
	t = await _new_toast()
	t.push(NORMAL_A)
	await _settle()
	t.push_immediate(CUT_LINES[0], hurt)
	t.push_immediate(CUT_LINES[2], hurt)
	_pause_tweens()
	await get_tree().process_frame
	_ok(_live_tweens() == 1, "double preempt same frame: one tween (%d)" % _live_tweens())
	_ok(t._label.text == CUT_LINES[2] and t._queue.is_empty(), "double preempt: last line only")
	await _end(t, "imm_cleanup")


## 트리 일시정지 중: 일반 push 와 같이 트윈이 멈춰 알파가 그대로이고, 풀리면 이어서 진행한다.
func _check_imm_pause() -> void:
	var t: Toast = await _new_toast()
	var n: Toast = await _new_toast()
	get_tree().paused = true
	t.push_immediate(CUT_LINES[0], load(HURT_PATH))
	n.push(NORMAL_A)
	await _frames(6)
	var held: bool = t._label.text == CUT_LINES[0] and t._group.visible
	_ok(held and absf(_alpha(t)) < 1e-4 and absf(_alpha(n)) < 1e-4, "paused: both stay at 0")
	get_tree().paused = false
	await _frames(6)
	_ok(_alpha(t) > 0.0 and _alpha(n) > 0.0, "unpaused: both fade in (%.3f)" % _alpha(t))
	t.queue_free()
	n.queue_free()
	await get_tree().process_frame
	_done.append("imm_pause")
