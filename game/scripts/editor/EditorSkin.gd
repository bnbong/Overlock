class_name EditorSkin
extends RefCounted
## 트랙 에디터 버튼·옵션 절차 스킨(TrackEditor에서 분리).
##
## 에디터 툴바는 좁은 텍스트 버튼이 많아 시트의 필 버튼(양끝 단추 캡)이 텍스트를
## 밀어내므로 절차 스킨을 유지한다(시트 필 버튼은 폭이 넉넉한 버튼에만 적합).

const INK: Color = Color(0.278, 0.203, 0.153)
const INK_DEEP: Color = Color(0.2, 0.14, 0.1)
# 터치 기기(TouchControls.should_show)에서는 1280×720 기준 화면이 폰에서 약 0.54배로 줄어드므로
# 버튼·입력칸을 키운다(56 → 폰 약 30px). 툴바·속성 줄은 흐름 컨테이너라 넘치면 줄을 바꾼다.
const TOUCH_MIN_H: float = 56.0
const TOUCH_FONT: int = 20
const STATUS_H: float = 30.0


## 에디터 화면 틀: 버튼 스킨, 터치 크기, 그리고 툴바·속성 패널 실제 높이에 맞춘 그리기 영역 배치.
## 캔버스는 툴바·상태줄과 하단 패널 사이만 차지한다(전체 보기·중앙 계산이 이 영역 기준).
static func setup_chrome(ed: Control) -> void:
	var touch: bool = TouchControls.should_show()
	for n in _descendants(ed):
		if n is OptionButton:
			skin_option(n)
		elif n is Button and not (n is CheckButton):
			skin_button(n)
		if touch and (n is Button or n is LineEdit):
			var c: Control = n
			c.custom_minimum_size.y = maxf(c.custom_minimum_size.y, TOUCH_MIN_H)
			c.add_theme_font_size_override("font_size", TOUCH_FONT)
	if touch:
		(ed.get_node("HintLabel") as Label).visible = false  # 키보드 단축키 안내는 뜻이 없다
		for b in ed.get_node("ViewBar").get_children():
			if b is Button:
				(b as Button).custom_minimum_size = Vector2(64.0, TOUCH_MIN_H)
	var relayout: Callable = layout_chrome.bind(ed)
	ed.resized.connect(relayout)
	(ed.get_node("Toolbar") as Control).resized.connect(relayout)
	(ed.get_node("MetaPanel") as Control).resized.connect(relayout)
	layout_chrome(ed)


## 툴바(위로부터)와 속성 패널(아래로부터)의 실제 높이로 배경·상태줄·안내줄·캔버스·화면 도구 줄 위치를
## 다시 잡는다(1280 폭에서 한 줄, 좁거나 터치 크기면 두 줄로 넘어가도 겹치지 않게).
static func layout_chrome(ed: Control) -> void:
	var h: float = ed.size.y
	if h < 2.0:
		return
	var tb: Control = ed.get_node("Toolbar")
	var tb_bottom: float = tb.position.y + tb.size.y
	(ed.get_node("ToolbarBg") as Control).offset_bottom = tb_bottom + 6.0
	var status: Control = ed.get_node("StatusLabel")
	status.offset_top = tb_bottom + 10.0
	status.offset_bottom = status.offset_top + STATUS_H
	var meta_top: float = (ed.get_node("MetaPanel") as Control).position.y - h
	(ed.get_node("MetaBg") as Control).offset_top = meta_top - 10.0
	var hint: Control = ed.get_node("HintLabel")
	var canvas_bottom: float = meta_top - 16.0
	if hint.visible:
		hint.offset_bottom = meta_top - 14.0
		hint.offset_top = hint.offset_bottom - 20.0
		canvas_bottom = hint.offset_top - 2.0
	var canvas: Control = ed.get_node("Canvas")
	canvas.offset_top = status.offset_bottom + 4.0
	canvas.offset_bottom = canvas_bottom
	place_overlays.call_deferred(ed)
	for bar_name in ["ViewBar", "ReviewRow"]:
		var bar: Control = ed.get_node(bar_name)
		var bh: float = bar.get_combined_minimum_size().y
		bar.offset_bottom = canvas_bottom - 8.0
		bar.offset_top = bar.offset_bottom - bh


## 그리기 영역 위쪽에 겹쳐 두는 아이템 막대(왼쪽)와 검증 목록(오른쪽)을 캔버스 위 끝에 맞추고,
## 검증 목록은 내용 크기로 줄인다(접으면 제목 줄만 남는다). 목록 높이는 캔버스 높이 안으로 제한한다.
static func place_overlays(ed: Control) -> void:
	var canvas: Control = ed.get_node("Canvas")
	var top: float = canvas.position.y + 8.0
	(ed.get_node("ItemBar") as Control).position.y = top
	var panel: Control = ed.get_node("IssuePanel")
	var scroll: Control = panel.get_node("Box/Scroll")
	scroll.custom_minimum_size.y = clampf(canvas.size.y - 120.0, 80.0, 170.0)
	panel.reset_size()
	panel.position = Vector2(ed.size.x - 18.0 - panel.size.x, top)


static func _descendants(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		out.append(c)
		out.append_array(_descendants(c))
	return out


static func skin_button(b: Button) -> void:
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", INK_DEEP)
	b.add_theme_color_override("font_pressed_color", INK_DEEP)
	b.add_theme_color_override("font_focus_color", INK_DEEP)
	b.add_theme_color_override("font_disabled_color", Color(0.5, 0.44, 0.36))
	skin_control(b)
	b.add_theme_stylebox_override(
		"disabled", box(Color(0.6, 0.55, 0.47, 0.6), Color(0.45, 0.4, 0.34))
	)


static func skin_option(o: OptionButton) -> void:
	o.add_theme_color_override("font_color", INK)
	skin_control(o)


## normal/hover/pressed/focus 스타일박스를 공통 적용(버튼·옵션버튼 공유).
static func skin_control(c: Control) -> void:
	c.add_theme_stylebox_override(
		"normal", box(Color(0.831, 0.753, 0.6), Color(0.553, 0.384, 0.725))
	)
	c.add_theme_stylebox_override(
		"hover", box(Color(0.906, 0.835, 0.686), Color(0.616, 0.435, 0.784))
	)
	c.add_theme_stylebox_override(
		"pressed", box(Color(0.761, 0.682, 0.541), Color(0.478, 0.333, 0.243))
	)
	c.add_theme_stylebox_override(
		"focus", box(Color(0.906, 0.835, 0.686), Color(0.831, 0.278, 0.263), 3)
	)


static func box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb
