class_name TutorialDialog
extends Control
## 최초 1회 튜토리얼 코치마크 오버레이 (res://scenes/TutorialDialog.tscn).
## 설치 후 어떤 트랙이든 처음 플레이할 때 한 번만 RaceDirector가 HUD 위에 띄운다
## (전역 1회 — LeaderboardClient.tutorial_seen). 해제 관례는 ProfileDialog와 같다
## (Esc/"시작하기" 버튼 → closed 방출 후 queue_free).
##
## - 인게임 화면 전체를 살짝 어둡게 덮고, 설명 대상(바늘·미니맵·진행도·시간·속도·RISK·
##   드리프트·아이템 슬롯, 터치 모드면 조향/일시정지/USE 버튼)만 딤에서 오려내 보라 박음질 테두리로
##   강조한다.
## - 대상마다 베이지 설명 라벨 + 화살표를 붙인다. 라벨은 대상 위치에 따라 선호 방향 목록을
##   차례로 시도해, 다른 대상·라벨·제목·버튼과 겹치지 않는 첫 자리에 놓는다(_place_box).
## - 대상 사각형은 하드코딩하지 않고 첫 프레임 레이아웃이 확정된 뒤 HUD 노드에서 읽는다.
##   노드가 없거나 숨겨져 있으면 그 콜아웃은 생략한다.
## - 딤·컷아웃·화살표·라벨 배경은 _draw, 글은 Label 노드. 루트 Control이 mouse_filter STOP으로
##   아래 HUD 클릭을 막는다(터치 버튼은 HUD가 입력만 막고 보이게 둔다 — HUD._refresh_touch_block).
## - 순수 UI — 게임 값·판정과 무관. 카운트다운 홀드는 RaceDirector가 담당한다.

signal closed

enum Side { ABOVE, BELOW, LEFT, RIGHT }

const TITLE_TEXT: String = "Overlock 튜토리얼"
const NOTE_ITEMS: String = "아이템 — 골무: 잠시 부상 면역 · 엄마 찬스: 잠시 자동 주행"
const TEXT_SLOTS_KEYS: String = "먹은 아이템은 2칸에 보관\nSpace로 사용(먼저 먹은 것부터)"
const TEXT_SLOTS_TOUCH: String = "먹은 아이템은 2칸에 보관"
const TEXT_USE_TOUCH: String = "USE 버튼으로 아이템 사용\n(먼저 먹은 것부터)"
const NOTE_KEYS: String = "R 재시작 · Esc 일시정지"
const TEXT_NEEDLE_KEYS: String = "보라색 재봉선을 따라 바늘을 움직이세요.\n← → (A/D) 조향"
const TEXT_NEEDLE_TOUCH: String = "보라색 재봉선을 따라 바늘을 움직이세요."
const TEXT_STEER_TOUCH: String = "◀ ▶ 버튼으로 조향"
const TEXT_MINIMAP: String = "코스 전체와 현재 위치"
const TEXT_PROGRESS: String = "완주까지 진행도"
const TEXT_TIME: String = "경과 시간 — 기록에 도전"
const TEXT_SPEED_KEYS: String = "속도 단계 ↑ ↓ (W/S)"
const TEXT_SPEED_TOUCH: String = "▲ ▼ 버튼으로 속도 조절"
const TEXT_RISK: String = "선에서 벗어나면 RISK 상승,\n가득 차면 손가락 부상(페널티)"
const TEXT_DRIFT_KEYS: String = "Shift 홀드 = 드리프트\n(빠르게 꺾지만 위험↑)"
const TEXT_DRIFT_TOUCH: String = "DRIFT 홀드 = 드리프트\n(빠르게 꺾지만 위험↑)"
const TEXT_PAUSE: String = "일시정지"

const DIM_COLOR: Color = Color(0.0, 0.0, 0.0, 0.5)
## 컷아웃(대상 사각형) 여유와 모서리 반경.
const HOLE_PAD: float = 4.0
const HOLE_RADIUS: float = 12.0
## 대상 가장자리 ~ 라벨 박스 사이 거리(= 화살표 길이).
const ARROW_GAP: float = 36.0
const ARROW_HEAD_LEN: float = 12.0
const ARROW_HEAD_HALF: float = 7.0
const ARROW_COLOR: Color = Color(0.968, 0.929, 0.847)  # SewingSkin.CREAM
const ARROW_SHADOW: Color = Color(0.0, 0.0, 0.0, 0.4)
const LABEL_FONT: int = 16
const LABEL_MAX_W: float = 260.0
const TITLE_FONT: int = 24
const NOTE_FONT: int = 14
const HEADER_MAX_W: float = 380.0
const BOX_PAD: Vector2 = Vector2(12.0, 8.0)
const BOX_RADIUS: float = 10.0
const SCREEN_MARGIN: float = 8.0
## 라벨 박스끼리/대상과의 최소 간격(겹침 판정 여유).
const CLEARANCE: float = 6.0
## 바늘 콜아웃 대상: NeedleView 원점(관통점) 기준 확대 노루발 전체 + 바로 앞 재봉선 구간.
## NeedleView.FOOT_RECT의 불투명 영역(x -82..83, y -147..27)과 상승한 바늘 끝(-NEEDLE_TRAVEL)·
## 클램프(상단 약 -218)를 감싸고, 그 위로 이어지는 바늘대는 포함하지 않는다.
const NEEDLE_AREA: Rect2 = Rect2(-91.0, -220.0, 182.0, 265.0)
## "시작하기" 버튼을 바늘 대상 아래에 둘 때의 간격.
const BUTTON_GAP: float = 16.0

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

## 배치가 끝난 콜아웃: {hole: Rect2, box: Rect2, side: Side}.
var _callouts: Array = []
## 제목·안내 박스(배치 전에는 빈 사각형).
var _header_box: Rect2 = Rect2()
var _laid_out: bool = false

@onready var _close: Button = $CloseButton


func _ready() -> void:
	_close.pressed.connect(_do_close)
	_apply_skin()
	_close.grab_focus()
	# 딤·화살표를 가리지 않게 버튼은 레이아웃이 끝날 때까지 숨긴다(Esc는 그대로 동작).
	_close.visible = false
	_layout()


## Esc/버튼 모두 해제로 처리(ProfileDialog와 동일 관례).
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_do_close()
		accept_event()


func _do_close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()


# --- 레이아웃 ---


## HUD 위젯 사각형은 첫 프레임 레이아웃(앵커 해석·터치 버튼 크기)이 끝나야 확정되므로 한 프레임
## 기다린 뒤 대상 수집 → 제목 → 버튼 → 콜아웃 순으로 배치한다.
func _layout() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var touch: TouchControls = _touch_controls()
	var specs: Array = _collect_specs(touch)
	var needle_hole: Rect2 = Rect2()
	if not specs.is_empty() and specs[0].get("needle", false):
		needle_hole = specs[0]["hole"]
	# 모든 대상 컷아웃을 미리 장애물로 넣어 라벨이 어떤 대상도 가리지 않게 한다.
	var obstacles: Array = []
	for s in specs:
		obstacles.append(s["hole"])
	_build_header(touch != null)
	obstacles.append(_header_box)
	obstacles.append(_place_button(needle_hole))
	for s in specs:
		var label: Label = _make_label(s["text"], LABEL_FONT, SewingSkin.INK, LABEL_MAX_W)
		var box_size: Vector2 = label.size + BOX_PAD * 2.0
		var placed: Array = _place_box(s["hole"], box_size, s["prefs"], obstacles)
		var box: Rect2 = placed[0]
		label.position = box.position + BOX_PAD
		obstacles.append(box)
		_callouts.append({"hole": s["hole"], "box": box, "side": placed[1]})
	_close.visible = true
	_laid_out = true
	queue_redraw()


## 설명 대상 목록: {hole, text, prefs[, needle]}. 순서가 배치 우선순위다(먼저 온 것이 좋은 자리).
func _collect_specs(touch: TouchControls) -> Array:
	var specs: Array = []
	var hud: Node = get_parent()
	var needle: Variant = _needle_rect()
	if needle != null:
		var ntext: String = TEXT_NEEDLE_TOUCH if touch != null else TEXT_NEEDLE_KEYS
		specs.append(_spec(needle, ntext, [Side.ABOVE, Side.LEFT, Side.RIGHT], true))
	_add_node_spec(specs, hud, "MiniMap", TEXT_MINIMAP, [Side.RIGHT, Side.BELOW])
	_add_node_spec(specs, hud, "ProgressBar", TEXT_PROGRESS, [Side.RIGHT, Side.BELOW])
	_add_node_spec(specs, hud, "TimePanel", TEXT_TIME, [Side.BELOW, Side.LEFT])
	var speed: Variant = _node_rect(hud, "SpeedPanel")
	if touch != null:
		for b in [TouchControls.Btn.SPEED_UP, TouchControls.Btn.SPEED_DOWN]:
			speed = _merge(speed, _touch_rect(touch, b))
	if speed != null:
		var stext: String = TEXT_SPEED_TOUCH if touch != null else TEXT_SPEED_KEYS
		specs.append(_spec(speed, stext, [Side.ABOVE, Side.LEFT]))
	_add_node_spec(specs, hud, "RiskMeter", TEXT_RISK, [Side.ABOVE, Side.RIGHT])
	var slots_text: String = TEXT_SLOTS_TOUCH if touch != null else TEXT_SLOTS_KEYS
	_add_node_spec(specs, hud, "ItemSlots", slots_text, [Side.ABOVE, Side.RIGHT])
	if touch != null:
		var use: Rect2 = _touch_rect(touch, TouchControls.Btn.USE_ITEM)
		specs.append(_spec(use, TEXT_USE_TOUCH, [Side.LEFT, Side.ABOVE]))
		var drift: Rect2 = _touch_rect(touch, TouchControls.Btn.DRIFT)
		specs.append(_spec(drift, TEXT_DRIFT_TOUCH, [Side.ABOVE, Side.LEFT]))
		var steer: Rect2 = _touch_rect(touch, TouchControls.Btn.STEER_LEFT).merge(
			_touch_rect(touch, TouchControls.Btn.STEER_RIGHT)
		)
		specs.append(_spec(steer, TEXT_STEER_TOUCH, [Side.ABOVE, Side.RIGHT]))
		var pause: Rect2 = _touch_rect(touch, TouchControls.Btn.PAUSE)
		specs.append(_spec(pause, TEXT_PAUSE, [Side.BELOW, Side.LEFT]))
	else:
		_add_node_spec(
			specs, hud, "SteerHint", TEXT_DRIFT_KEYS, [Side.ABOVE, Side.RIGHT, Side.LEFT]
		)
	return specs


func _spec(target: Rect2, text: String, prefs: Array, is_needle: bool = false) -> Dictionary:
	return {"hole": target.grow(HOLE_PAD), "text": text, "prefs": prefs, "needle": is_needle}


func _add_node_spec(specs: Array, hud: Node, path: String, text: String, prefs: Array) -> void:
	var r: Variant = _node_rect(hud, path)
	if r != null:
		specs.append(_spec(r, text, prefs))


## HUD 자식 Control의 사각형(이 오버레이 좌표). 없거나 숨겨져 있으면 null.
func _node_rect(hud: Node, path: String) -> Variant:
	if hud == null:
		return null
	var c: Control = hud.get_node_or_null(path) as Control
	if c == null or not c.is_visible_in_tree():
		return null
	return _to_local(c) * Rect2(Vector2.ZERO, c.size)


func _touch_controls() -> TouchControls:
	var hud: Node = get_parent()
	if hud == null:
		return null
	var t: TouchControls = hud.get_node_or_null("TouchControls") as TouchControls
	if t == null or not t.is_visible_in_tree():
		return null
	return t


func _touch_rect(touch: TouchControls, b: int) -> Rect2:
	return _to_local(touch) * touch.button_rect(b)


## 바늘 대상 사각형: Gameplay/ForegroundLayer/NeedleView 원점 기준. 노드가 없으면
## PresentationController.v_needle() 행(화면 중앙)으로 대신한다.
func _needle_rect() -> Variant:
	var origin: Vector2 = Vector2(size.x * 0.5, PresentationController.v_needle() * size.y)
	var hud: Node = get_parent()
	var root: Node = hud.get_parent() if hud != null else null
	if root != null:
		var nv: Node2D = root.get_node_or_null("ForegroundLayer/NeedleView") as Node2D
		if nv != null:
			if not nv.is_visible_in_tree():
				return null
			var xf: Transform2D = get_global_transform_with_canvas().affine_inverse()
			origin = xf * nv.get_global_transform_with_canvas().origin
	return Rect2(origin + NEEDLE_AREA.position, NEEDLE_AREA.size)


## 다른 CanvasItem 좌표 → 이 오버레이 좌표 변환.
func _to_local(ci: CanvasItem) -> Transform2D:
	return (
		get_global_transform_with_canvas().affine_inverse() * ci.get_global_transform_with_canvas()
	)


static func _merge(a: Variant, b: Rect2) -> Rect2:
	if a == null:
		return b
	return (a as Rect2).merge(b)


## 상단 중앙 제목 + 안내(아이템·단축키) 박스.
func _build_header(is_touch: bool) -> void:
	var title: Label = _make_label(TITLE_TEXT, TITLE_FONT, SewingSkin.INK, HEADER_MAX_W)
	var note_text: String = NOTE_ITEMS if is_touch else NOTE_ITEMS + "\n" + NOTE_KEYS
	var note: Label = _make_label(note_text, NOTE_FONT, SewingSkin.INK_SOFT, HEADER_MAX_W)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var inner_w: float = maxf(title.size.x, note.size.x)
	title.size.x = inner_w
	note.size.x = inner_w
	var pad: Vector2 = BOX_PAD + Vector2(6.0, 2.0)
	var box_size: Vector2 = Vector2(inner_w, title.size.y + 2.0 + note.size.y) + pad * 2.0
	_header_box = Rect2(Vector2((size.x - box_size.x) * 0.5, SCREEN_MARGIN), box_size)
	title.position = _header_box.position + pad
	note.position = title.position + Vector2(0.0, title.size.y + 2.0)


## "시작하기" 버튼을 바늘 대상 바로 아래 중앙에 둔다(바늘 대상이 없으면 화면 72% 행).
func _place_button(needle_hole: Rect2) -> Rect2:
	var bsize: Vector2 = _close.get_combined_minimum_size()
	bsize.x = maxf(bsize.x, _close.custom_minimum_size.x)
	var y: float = size.y * 0.72
	if needle_hole.has_area():
		y = needle_hole.end.y + BUTTON_GAP
	y = minf(y, size.y - SCREEN_MARGIN - bsize.y)
	_close.position = Vector2((size.x - bsize.x) * 0.5, y)
	_close.size = bsize
	return Rect2(_close.position, bsize)


## 자동 줄바꿈 라벨을 만들고 실제 글 크기(최대 폭 max_w)에 맞춰 size를 정한다.
func _make_label(text: String, font_size: int, color: Color, max_w: float) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.text = text
	add_child(label)
	# 버튼보다 아래(먼저) 그려지게 한다 — 버튼이 항상 맨 위.
	move_child(label, _close.get_index())
	var natural_w: float = label.get_minimum_size().x
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size = Vector2(minf(natural_w, max_w), 0.0)
	label.size = Vector2(label.size.x, label.get_minimum_size().y)
	return label


## 대상 hole 주변에 box_size 박스를 선호 방향(prefs) 순서로 시도해 놓는다.
## 방향마다 정렬 3가지(가운데/시작/끝)를 화면 안으로 클램프한 뒤 장애물과의 겹침을 재고,
## 겹침이 없는 첫 후보를 고른다(모두 겹치면 겹침 면적이 가장 작은 후보). 반환 [Rect2, Side].
func _place_box(hole: Rect2, box_size: Vector2, prefs: Array, obstacles: Array) -> Array:
	var best: Rect2 = Rect2()
	var best_side: int = prefs[0]
	var best_cost: float = INF
	for side in prefs:
		for align in [0.5, 0.0, 1.0]:
			var r: Rect2 = _clamp_to_screen(_candidate(hole, box_size, side, align))
			var cost: float = _overlap_cost(r, obstacles)
			if cost < best_cost:
				best = r
				best_side = side
				best_cost = cost
			if cost <= 0.0:
				return [best, best_side]
	return [best, best_side]


## side 방향으로 ARROW_GAP만큼 떨어진 박스. align은 수직축 정렬(0=시작 가장자리, 0.5=가운데,
## 1=끝 가장자리 맞춤).
static func _candidate(hole: Rect2, box_size: Vector2, side: int, align: float) -> Rect2:
	var pos: Vector2 = Vector2.ZERO
	match side:
		Side.ABOVE, Side.BELOW:
			pos.x = lerpf(hole.position.x, hole.end.x - box_size.x, align)
			if align == 0.5:
				pos.x = hole.get_center().x - box_size.x * 0.5
			if side == Side.ABOVE:
				pos.y = hole.position.y - ARROW_GAP - box_size.y
			else:
				pos.y = hole.end.y + ARROW_GAP
		_:
			pos.y = lerpf(hole.position.y, hole.end.y - box_size.y, align)
			if align == 0.5:
				pos.y = hole.get_center().y - box_size.y * 0.5
			if side == Side.LEFT:
				pos.x = hole.position.x - ARROW_GAP - box_size.x
			else:
				pos.x = hole.end.x + ARROW_GAP
	return Rect2(pos, box_size)


func _clamp_to_screen(r: Rect2) -> Rect2:
	var p: Vector2 = r.position
	p.x = clampf(p.x, SCREEN_MARGIN, maxf(size.x - SCREEN_MARGIN - r.size.x, SCREEN_MARGIN))
	p.y = clampf(p.y, SCREEN_MARGIN, maxf(size.y - SCREEN_MARGIN - r.size.y, SCREEN_MARGIN))
	return Rect2(p, r.size)


static func _overlap_cost(r: Rect2, obstacles: Array) -> float:
	var cost: float = 0.0
	var grown: Rect2 = r.grow(CLEARANCE)
	for o in obstacles:
		var ob: Rect2 = o
		if grown.intersects(ob):
			cost += grown.intersection(ob).get_area() + 1.0
	return cost


# --- 드로잉 ---


func _draw() -> void:
	var holes: Array = []
	for c in _callouts:
		holes.append(c["hole"])
	_draw_dim(holes)
	if not _laid_out:
		return
	for h in holes:
		_draw_highlight(h)
	for c in _callouts:
		_draw_arrow(c["box"], c["hole"], c["side"])
	for c in _callouts:
		_draw_box(c["box"])
	_draw_box(_header_box)


## 화면 전체 딤에서 hole(둥근 사각형)들을 뺀 영역만 칠한다.
## 구멍이 폴리곤 안쪽에 완전히 갇히면 clip_polygons가 '구멍 폴리곤'을 따로 돌려줘 그대로 칠할 수
## 없으므로, 각 hole의 중심 x에서 화면을 세로 띠로 자른다. 그러면 모든 hole이 띠 경계를 가로질러
## 띠 바깥과 닿으므로 차집합이 항상 구멍 없는 단순 폴리곤이 된다.
func _draw_dim(holes: Array) -> void:
	var xs: Array = [0.0, size.x]
	for h in holes:
		xs.append(clampf((h as Rect2).get_center().x, 0.0, size.x))
	xs.sort()
	var hole_polys: Array = []
	for h in holes:
		hole_polys.append(SewingSkin.rounded_rect_polyline(h, HOLE_RADIUS))
	for i in range(xs.size() - 1):
		var x0: float = xs[i]
		var x1: float = xs[i + 1]
		if x1 - x0 < 0.5:
			continue
		var pieces: Array = [
			PackedVector2Array(
				[Vector2(x0, 0.0), Vector2(x1, 0.0), Vector2(x1, size.y), Vector2(x0, size.y)]
			)
		]
		for hp in hole_polys:
			var next: Array = []
			for piece in pieces:
				next.append_array(Geometry2D.clip_polygons(piece, hp))
			pieces = next
		for piece in pieces:
			var poly: PackedVector2Array = piece
			if poly.size() >= 3:
				draw_colored_polygon(poly, DIM_COLOR)


func _draw_highlight(hole: Rect2) -> void:
	var pts: PackedVector2Array = SewingSkin.rounded_rect_polyline(hole, HOLE_RADIUS)
	var closed_pts: PackedVector2Array = pts.duplicate()
	closed_pts.append(pts[0])
	draw_polyline(closed_pts, Color(SewingSkin.CREAM, 0.45), 5.0, true)
	SewingSkin.draw_running_stitch(self, pts, true, SewingSkin.THREAD_PURPLE, 7.0, 4.0, 3.0)


## 라벨 박스 가장자리(대상 쪽) → 대상 컷아웃 가장자리 화살표. 가능하면 두 사각형이 겹치는
## 구간에서 곧게 긋고, 아니면 박스 쪽 끝점을 대상 중심에 가깝게 잡아 비스듬히 긋는다.
func _draw_arrow(box: Rect2, hole: Rect2, side: int) -> void:
	var from: Vector2
	var to: Vector2
	var inset: float = 14.0
	match side:
		Side.ABOVE, Side.BELOW:
			var sx: float = clampf(hole.get_center().x, box.position.x + inset, box.end.x - inset)
			var tx: float = clampf(sx, hole.position.x + inset, hole.end.x - inset)
			if side == Side.ABOVE:
				from = Vector2(sx, box.end.y)
				to = Vector2(tx, hole.position.y)
			else:
				from = Vector2(sx, box.position.y)
				to = Vector2(tx, hole.end.y)
		_:
			var sy: float = clampf(hole.get_center().y, box.position.y + inset, box.end.y - inset)
			var ty: float = clampf(sy, hole.position.y + inset, hole.end.y - inset)
			if side == Side.LEFT:
				from = Vector2(box.end.x, sy)
				to = Vector2(hole.position.x, ty)
			else:
				from = Vector2(box.position.x, sy)
				to = Vector2(hole.end.x, ty)
	var dir: Vector2 = (to - from).normalized()
	if dir == Vector2.ZERO:
		return
	var tip: Vector2 = to - dir * 3.0
	var base: Vector2 = tip - dir * ARROW_HEAD_LEN
	var normal: Vector2 = Vector2(-dir.y, dir.x) * ARROW_HEAD_HALF
	var head: PackedVector2Array = PackedVector2Array([tip, base + normal, base - normal])
	draw_line(from, base, ARROW_SHADOW, 6.0, true)
	draw_colored_polygon(
		PackedVector2Array([tip + dir * 1.5, base + normal * 1.35, base - normal * 1.35]),
		ARROW_SHADOW
	)
	draw_line(from, base + dir * 2.0, ARROW_COLOR, 3.0, true)
	draw_colored_polygon(head, ARROW_COLOR)


func _draw_box(box: Rect2) -> void:
	if not box.has_area():
		return
	SewingSkin.draw_patch(self, box, SewingSkin.FABRIC, BOX_RADIUS)
	SewingSkin.draw_stitch_border(
		self, box, Color(SewingSkin.THREAD_PURPLE, 0.8), 4.0, BOX_RADIUS, 1.5
	)


# --- 버튼 스킨 ---


## 시트 스킨(있으면) 소형 필 버튼, 없으면 절차 폴백(ProfileDialog와 동일).
func _apply_skin() -> void:
	if UiSkin.has_skin():
		UiSkin.skin_button(_close, "small", 18)
		return
	_skin_button(_close)


func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", _INK)
	b.add_theme_color_override("font_hover_color", _INK_HOVER)
	b.add_theme_color_override("font_pressed_color", _INK_HOVER)
	b.add_theme_color_override("font_focus_color", _INK_HOVER)
	b.add_theme_stylebox_override(
		"normal", _box(Color(0.831, 0.753, 0.6), Color(0.553, 0.384, 0.725))
	)
	b.add_theme_stylebox_override(
		"hover", _box(Color(0.906, 0.835, 0.686), Color(0.616, 0.435, 0.784))
	)
	b.add_theme_stylebox_override(
		"pressed", _box(Color(0.761, 0.682, 0.541), Color(0.478, 0.333, 0.243))
	)
	b.add_theme_stylebox_override(
		"focus", _box(Color(0.906, 0.835, 0.686), Color(0.831, 0.278, 0.263), 3)
	)


static func _box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb
