extends RefCounted
## 공유 허브 화면(CommunityHubScreen)의 위젯·스타일 도우미. 재봉 스킨(UiSkin/SewingSkin) 톤을
## 따르는 라벨·버튼·입력 칸·행 박스를 만든다. 텍스트는 모두 일반 텍스트(Label/LineEdit)다.
## 터치 기기(MenuTouch.active)에서는 여기서 만드는 버튼·입력 칸·목록 행을 손가락 크기로, 글자를 하한
## 이상으로 만든다(허브 화면과 트랙 종류 선택 화면이 함께 쓴다). 데스크톱에서는 전과 같다.

const INK: Color = Color(0.278, 0.203, 0.153)
const CREAM: Color = Color(0.968, 0.929, 0.847)
const SOFT: Color = Color(0.80, 0.74, 0.64)
# 소형 필 버튼 텍스처의 캡(둥근 끝 + 단추) 폭보다 넉넉한 좌우 여백(px).
const BUTTON_CAP_PAD: float = 46.0


static func label(text: String, size: int, color: Color, wrap: bool = false) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", touch_font(size))
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## 재봉 스킨 소형 필 버튼. 필 양끝 단추(캡)가 글자를 덮지 않도록 글자 폭 + 양쪽 여백을 최소 폭으로
## 잡는다(min_w가 더 크면 그 값).
static func button(text: String, font_size: int = 16, min_w: float = 0.0) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var font: Font = b.get_theme_font("font")
	var text_w: float = 0.0
	if font != null:
		text_w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	b.custom_minimum_size.x = maxf(min_w, text_w + BUTTON_CAP_PAD * 2.0)
	if not UiSkin.skin_button(b, "small", font_size):
		b.custom_minimum_size.y = 48
		b.add_theme_font_size_override("font_size", font_size)
		b.add_theme_color_override("font_color", INK)
		b.add_theme_color_override("font_disabled_color", UiSkin.INK_DISABLED)
		b.add_theme_stylebox_override(
			"normal", flat_box(Color(0.831, 0.753, 0.6), SewingSkin.THREAD_PURPLE)
		)
		b.add_theme_stylebox_override(
			"hover", flat_box(Color(0.906, 0.835, 0.686), SewingSkin.THREAD_PURPLE)
		)
		b.add_theme_stylebox_override("pressed", flat_box(Color(0.761, 0.682, 0.541), SewingSkin.KNOT))
		b.add_theme_stylebox_override("focus", flat_box(Color(0, 0, 0, 0), UiSkin.FOCUS_RED, 3))
		b.add_theme_stylebox_override(
			"disabled", flat_box(Color(0.6, 0.55, 0.47, 0.6), SewingSkin.KNOT)
		)
	if MenuTouch.active():
		MenuTouch.button(b)
	return b


## 터치 배치면 글자를 본문 하한(MenuTouch.TEXT_FONT) 이상으로 올린다. 데스크톱은 size 그대로.
static func touch_font(size: int) -> int:
	return maxi(size, MenuTouch.TEXT_FONT) if MenuTouch.active() else size


static func flat_box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func row_box(bg: Color, border: Color, bw: int = 1) -> StyleBoxFlat:
	var sb: StyleBoxFlat = flat_box(bg, border, bw)
	sb.set_corner_radius_all(8)
	return sb


static func edit_box(focused: bool) -> StyleBoxFlat:
	var sb: StyleBoxFlat = flat_box(
		Color(0.968, 0.929, 0.847, 0.96), UiSkin.FOCUS_RED if focused else SewingSkin.THREAD_PURPLE
	)
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	return sb


static func style_edit(c: Control) -> void:
	c.add_theme_stylebox_override("normal", edit_box(false))
	c.add_theme_stylebox_override("focus", edit_box(true))
	c.add_theme_stylebox_override("read_only", edit_box(false))
	c.add_theme_color_override("font_color", INK)
	c.add_theme_color_override("font_readonly_color", INK)  # TextEdit 읽기 전용
	c.add_theme_color_override("font_uneditable_color", INK)  # LineEdit editable=false
	c.add_theme_color_override("font_placeholder_color", Color(0.45, 0.38, 0.32))
	c.add_theme_color_override("caret_color", INK)
	c.add_theme_font_size_override("font_size", 17)
	if MenuTouch.active():
		MenuTouch.edit(c)


static func center(c: Control, half: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_CENTER)
	c.offset_left = -half.x
	c.offset_right = half.x
	c.offset_top = -half.y
	c.offset_bottom = half.y


static func vbox(sep: int = 8) -> VBoxContainer:
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep: int = 10) -> HBoxContainer:
	var h: HBoxContainer = HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func spacer() -> Control:
	var c: Control = Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## 목록 행(버튼 + 일반 텍스트 라벨). 둘째 줄은 작성자 표시명 Label 과 메타(난이도·재질·길이·날짜)
## Label 을 따로 두어, 작성자가 입력한 문자열이 다른 정보의 표시 순서에 끼어들지 못하게 한다.
static func post_row(item: Dictionary, meta_text: String) -> Button:
	var b: Button = Button.new()
	b.custom_minimum_size = Vector2(0, 104 if MenuTouch.active() else 66)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_ALL
	b.set_meta("post_id", str(item["id"]))
	b.add_theme_stylebox_override("normal", row_box(Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.14)))
	b.add_theme_stylebox_override("hover", row_box(Color(1, 1, 1, 0.13), Color(1, 1, 1, 0.3)))
	b.add_theme_stylebox_override("pressed", row_box(Color(0, 0, 0, 0.2), Color(1, 1, 1, 0.3)))
	b.add_theme_stylebox_override("focus", row_box(Color(0, 0, 0, 0), UiSkin.FOCUS_RED, 3))
	var box: VBoxContainer = vbox(2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 16.0
	box.offset_right = -16.0
	box.offset_top = 8.0
	box.offset_bottom = -8.0
	var title: Label = clipped(label(str(item["title"]), 19, CREAM))
	title.name = "TitleLabel"
	var line: HBoxContainer = hbox(18)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var author: Label = clipped(label("작성자 표시명: " + str(item["author_name"]), 14, SOFT))
	author.name = "AuthorLabel"
	author.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	author.size_flags_stretch_ratio = 0.8
	var meta: Label = clipped(label(meta_text, 14, SOFT))
	meta.name = "MetaLabel"
	meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta.size_flags_stretch_ratio = 1.2
	line.add_child(author)
	line.add_child(meta)
	box.add_child(title)
	box.add_child(line)
	b.add_child(box)
	return b


## 한 줄 라벨을 영역 안에서 말줄임으로 자르게 한다.
static func clipped(l: Label) -> Label:
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## 확인 창(어두운 막 + 가운데 패널 + 문구 + 취소/확인 버튼). {root, label, no, yes}.
static func confirm_overlay(fabric: Color, border: Color, ink: Color, btn_w: float) -> Dictionary:
	var overlay: Control = Control.new()
	overlay.name = "ConfirmOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	var center_box: CenterContainer = CenterContainer.new()
	center_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center_box)
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = flat_box(fabric, border, 3)
	sb.set_content_margin_all(26.0)
	panel.add_theme_stylebox_override("panel", sb)
	center_box.add_child(panel)
	var v: VBoxContainer = vbox(18)
	panel.add_child(v)
	var text: Label = label("", 18, ink, true)
	text.custom_minimum_size = Vector2(820 if MenuTouch.active() else 600, 0)
	v.add_child(text)
	var row: HBoxContainer = hbox(14)
	var no: Button = button("취소", 17, btn_w)
	var yes: Button = button("확인", 17, btn_w)
	row.add_child(no)
	row.add_child(spacer())
	row.add_child(yes)
	v.add_child(row)
	return {"root": overlay, "label": text, "no": no, "yes": yes}


## 게시 완료 화면의 "저장하지 못한 토큰" 상자. {box, edit, copy, retry, ack}.
static func token_box(warn: Color) -> Dictionary:
	var box: VBoxContainer = vbox(8)
	box.visible = false
	box.add_child(
		label(
			(
				"삭제 토큰을 이 기기에 저장하지 못했습니다. 업로드는 이미 성공했으니 다시 게시하지 말고, "
				+ "아래 토큰을 복사해 따로 보관하세요. '보관했습니다'를 누르기 전까지는 허브에 들어올 "
				+ "때마다 이 안내가 다시 나타나며, 게임을 종료하면 사라집니다."
			),
			16,
			warn,
			true
		)
	)
	var row: HBoxContainer = hbox(10)
	var edit: LineEdit = LineEdit.new()
	edit.editable = false
	edit.selecting_enabled = true
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 44)
	style_edit(edit)
	var copy: Button = button("토큰 복사", 16, 130.0)
	row.add_child(edit)
	row.add_child(copy)
	box.add_child(row)
	var row2: HBoxContainer = hbox(10)
	var retry: Button = button("다시 저장", 16, 130.0)
	var ack: Button = button("보관했습니다", 16, 130.0)
	row2.add_child(retry)
	row2.add_child(spacer())
	row2.add_child(ack)
	box.add_child(row2)
	return {"box": box, "edit": edit, "copy": copy, "retry": retry, "ack": ack}


## 결과 상태 → 화면 문구. 422는 서버 detail 목록의 msg를 줄마다 보여 준다. 404·401·403 은
## 요청 종류별로 다르므로 CommunityTrackClient 가 정한 message 를 그대로 쓴다.
static func status_text(r: Dictionary) -> String:
	var text: String = str(r.get("message", ""))
	match str(r["status"]):
		"network_error":
			text = "서버에 연결할 수 없습니다. 네트워크 상태를 확인한 뒤 다시 시도하세요."
		"timeout":
			text = "서버 응답이 없습니다 (시간 초과). 잠시 후 다시 시도하세요."
		"rate_limited":
			text = "요청이 너무 잦습니다 (429). 잠시 후 다시 시도하세요."
		"validation_error":
			var errs: Array = r.get("errors", [])
			text = "검증 실패: " + ("\n".join(PackedStringArray(errs)) if not errs.is_empty() else "")
		"too_large":
			text = "업로드 크기가 너무 큽니다 (413)."
		"offline":
			text = "오프라인입니다 (서버 주소 미설정)."
	return text


## "2026-09-30T09:36:36.772183+00:00" → "2026-09-30 09:36 UTC". 형식이 다르면 앞 16자.
static func fmt_date(iso: String) -> String:
	if iso.length() >= 16 and iso[10] == "T":
		return "%s %s UTC" % [iso.substr(0, 10), iso.substr(11, 5)]
	return iso.substr(0, 16)
