class_name ItemSlots
extends Control
## 아이템 슬롯 2칸 위젯 (v2.2.1, docs/architecture.md §6.6).
##
## RaceDirector가 담은 아이템 FIFO(앞=다음 사용)를 HUD가 set_slots()로 넘기면 칸마다 기존 아이템
## 아이콘을 그린다. 왼쪽 칸이 늘 다음에 쓸 아이템이며 NEXT 표시를 붙인다. 담을 때는 새 칸이 팝으로
## 나타나고, 쓸 때는 왼쪽 아이콘이 커지며 사라진 뒤 오른쪽 아이콘이 왼쪽으로 미끄러진다. 슬롯이
## 가득 차 아이템을 못 먹거나 사용이 거절되면 shake()로 짧게 흔들린다. 키보드 모드에서는 캡션
## 오른쪽에 사용 키(Space) 키캡을 그린다. 새 그림 없이 재봉 스킨(SewingSkin)과 기존 아이콘만 쓴다.
## 순수 표현용이라 게임 값·판정에는 관여하지 않는다.

const SIZE: Vector2 = Vector2(124.0, 80.0)
const RADIUS: float = 12.0
const SLOT: float = 44.0
const SLOT_Y: float = 26.0
const SLOT_X: Array[float] = [12.0, 68.0]
const ICON_PAD: float = 5.0
const POP_TIME: float = 0.2
const USE_TIME: float = 0.22
const SLIDE_TIME: float = 0.16
const SHAKE_TIME: float = 0.36
const SHAKE_PX: float = 6.0
const SHAKE_RATE: float = 46.0
const WARN: Color = Color(0.83, 0.28, 0.26)  # 가득 참 흔들림 테두리(노루발 경고 톤)

var _icons: Dictionary = {}  # type(String) -> Texture2D
var _slots: Array[String] = []
var _key_hint: String = ""
var _pop: Array[float] = [1.0, 1.0]  # 칸별 팝 진행(0..1)
var _slide: float = 1.0  # 오른쪽→왼쪽 미끄러짐 진행(0..1)
var _used_type: String = ""  # 사라지는 중인 아이콘 type
var _used_t: float = 1.0
var _shake_t: float = 0.0
var _shake_warn: bool = false


## HUD가 1회 호출해 type별 아이콘을 넘긴다.
func setup(icons: Dictionary) -> void:
	_icons = icons
	custom_minimum_size = SIZE
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 캡션 오른쪽 키캡 글자(빈 문자열이면 그리지 않음, 터치 모드).
func set_key_hint(text: String) -> void:
	_key_hint = text
	queue_redraw()


## 슬롯 내용 갱신. 이전 내용과 비교해 담기(뒤에 하나 추가)·사용(앞에서 하나 빠짐) 연출을 고른다.
func set_slots(slots: Array[String]) -> void:
	var old: Array[String] = _slots
	var now: Array[String] = slots.duplicate()
	if now == old:
		return
	if now.size() == old.size() + 1 and now.slice(0, old.size()) == old:
		_pop[now.size() - 1] = 0.0
	elif old.size() > 0 and now == old.slice(1):
		_used_type = old[0]
		_used_t = 0.0
		_slide = 0.0 if now.size() > 0 else 1.0
	else:
		_pop = [1.0, 1.0]
		_slide = 1.0
		_used_t = 1.0
	_slots = now
	queue_redraw()


func slots() -> Array[String]:
	return _slots.duplicate()


## 짧은 좌우 흔들림. warn=true면 테두리를 경고색으로 물들인다(가득 차 못 먹음).
func shake(warn: bool = true) -> void:
	_shake_t = SHAKE_TIME
	_shake_warn = warn
	queue_redraw()


func is_shaking() -> bool:
	return _shake_t > 0.0


## 칸 i의 사각형(위젯 로컬). 회귀 검사·튜토리얼이 쓴다.
func slot_rect(i: int) -> Rect2:
	return Rect2(Vector2(SLOT_X[clampi(i, 0, 1)], SLOT_Y), Vector2(SLOT, SLOT))


func _process(delta: float) -> void:
	var busy: bool = false
	for i in 2:
		if _pop[i] < 1.0:
			_pop[i] = minf(_pop[i] + delta / POP_TIME, 1.0)
			busy = true
	if _slide < 1.0:
		_slide = minf(_slide + delta / SLIDE_TIME, 1.0)
		busy = true
	if _used_t < 1.0:
		_used_t = minf(_used_t + delta / USE_TIME, 1.0)
		busy = true
	if _shake_t > 0.0:
		_shake_t = maxf(_shake_t - delta, 0.0)
		busy = true
	if busy:
		queue_redraw()


func _draw() -> void:
	var dx: float = 0.0
	if _shake_t > 0.0:
		var k: float = _shake_t / SHAKE_TIME
		dx = sin((SHAKE_TIME - _shake_t) * SHAKE_RATE) * SHAKE_PX * k
	draw_set_transform(Vector2(dx, 0.0), 0.0, Vector2.ONE)
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	SewingSkin.draw_patch(self, rect, SewingSkin.FABRIC, RADIUS)
	var border: Color = WARN if (_shake_t > 0.0 and _shake_warn) else SewingSkin.THREAD_PURPLE
	SewingSkin.draw_stitch_border(self, rect, border, 5.0, RADIUS, 1.5)
	var font: Font = ThemeDB.fallback_font
	var cap_col: Color = SewingSkin.INK_SOFT
	draw_string(font, Vector2(12.0, 19.0), "ITEM", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, cap_col)
	if _key_hint != "":
		_draw_keycap(font)
	for i in 2:
		_draw_slot_bg(i)
	# 왼쪽 칸: 사라지는 중이면 사용된 아이콘을 키우며 흐리게 그리고, 그 위로 미끄러져 오는 아이콘을 그린다.
	if _used_t < 1.0 and _used_type != "":
		var grow: float = 1.0 + 0.35 * _used_t
		_draw_icon(_used_type, slot_rect(0), grow, 1.0 - _used_t)
	for i in _slots.size():
		var r: Rect2 = slot_rect(i)
		if i == 0 and _slide < 1.0:
			var from: Vector2 = slot_rect(1).position
			var e: float = 1.0 - pow(1.0 - _slide, 3.0)
			r.position = from.lerp(r.position, e)
		_draw_icon(_slots[i], r, _pop_scale(_pop[i]), 1.0)
	if not _slots.is_empty():
		_draw_next_badge(font)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_slot_bg(i: int) -> void:
	var r: Rect2 = slot_rect(i)
	var groove: StyleBoxFlat = StyleBoxFlat.new()
	groove.bg_color = SewingSkin.FABRIC_DEEP
	groove.set_corner_radius_all(8)
	if i == 0 and not _slots.is_empty():
		groove.border_color = SewingSkin.THREAD_PURPLE
		groove.set_border_width_all(3)
	draw_style_box(groove, r)


func _draw_icon(type: String, r: Rect2, scale_k: float, alpha: float) -> void:
	var tex: Texture2D = _icons.get(type, null)
	if tex == null or alpha <= 0.01:
		return
	var side: float = (SLOT - ICON_PAD * 2.0) * scale_k
	var c: Vector2 = r.get_center()
	var ir: Rect2 = Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side))
	draw_texture_rect(tex, ir, false, Color(1.0, 1.0, 1.0, alpha))


func _draw_next_badge(font: Font) -> void:
	var r: Rect2 = slot_rect(0)
	var badge: Rect2 = Rect2(Vector2(r.get_center().x - 18.0, r.end.y - 6.0), Vector2(36.0, 13.0))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = SewingSkin.THREAD_PURPLE
	sb.set_corner_radius_all(6)
	draw_style_box(sb, badge)
	draw_string(
		font,
		Vector2(badge.position.x, badge.position.y + 10.5),
		"NEXT",
		HORIZONTAL_ALIGNMENT_CENTER,
		badge.size.x,
		10,
		SewingSkin.CREAM
	)


func _draw_keycap(font: Font) -> void:
	var fs: int = 12
	var tw: float = font.get_string_size(_key_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var cap: Rect2 = Rect2(Vector2(size.x - 12.0 - tw - 12.0, 6.0), Vector2(tw + 12.0, 17.0))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = SewingSkin.CREAM
	sb.border_color = SewingSkin.INK_SOFT
	sb.set_border_width_all(1)
	sb.border_width_bottom = 2
	sb.set_corner_radius_all(4)
	draw_style_box(sb, cap)
	draw_string(
		font,
		Vector2(cap.position.x, cap.position.y + 13.0),
		_key_hint,
		HORIZONTAL_ALIGNMENT_CENTER,
		cap.size.x,
		fs,
		SewingSkin.INK
	)


## 팝 등장 스케일(백-이즈 아웃, EffectTimerCard와 같은 곡선).
static func _pop_scale(t: float) -> float:
	if t >= 1.0:
		return 1.0
	var c1: float = 1.70158
	var c3: float = c1 + 1.0
	var u: float = t - 1.0
	return lerpf(0.5, 1.0, 1.0 + c3 * u * u * u + c1 * u * u)
