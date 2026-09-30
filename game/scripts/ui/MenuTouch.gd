class_name MenuTouch
extends RefCounted
## 메뉴·결과 화면의 터치 전용 배치 도우미(docs/mobile.md §5.1).
##
## 1280×720 캔버스는 폰 가로 화면(844×390 기준)에서 약 0.54배로 줄어든다. 터치 기기
## (TouchControls.should_show, 데스크톱 검증은 `-- --touch-controls`)에서만 버튼을 실제 화면
## 약 44~48px(논리 84)로 키우고 글자를 실제 약 12px 이상(논리 23 이상)으로 올린다. 고정 크기만
## 키우면 넘치므로 화면별 배치(두 열, 세로 스크롤, 줄 바꿈 격자)는 이 도우미의 columns·scroll·grid로
## 다시 짠다. 데스크톱(키보드·마우스)에서는 아무것도 바꾸지 않는다(호출부가 active()로 막는다).
##
## 시트 필 버튼(UiSkin small 48·large 56 텍스처)은 세로로 늘리면 양끝 단추 캡이 반복돼 깨지므로
## 일시정지 터치 버튼(HUD._style_touch_button)과 같은 재봉 팔레트 StyleBoxFlat으로 바꾼다.
## 절차 스타일(StyleBoxFlat)·투명 나브 버튼·정사각 텍스처(96px)는 늘려도 깨지지 않아 그대로 둔다.

## 터치 버튼 최소 높이(논리). 844×390에서 약 45px, 932×430에서 약 50px.
const MIN_H: float = 84.0
## 버튼 글자(논리 24 → 844×390에서 약 13px).
const BUTTON_FONT: int = 24
## 본문·상태 글자 하한(논리 23 → 844×390에서 약 12.5px).
const TEXT_FONT: int = 23
## 슬라이더 줄 높이와 단추(그래버) 지름(논리).
const SLIDER_H: float = 64.0
const GRABBER_D: int = 40
const _RADIUS: int = 16

# active() 판별 결과 캐시(-1 = 아직 모름). 웹 판별은 JavaScriptBridge를 부르므로 라벨마다 다시 묻지 않는다.
static var _active: int = -1


## 터치 배치를 쓸지. 게임플레이 터치 버튼과 같은 판별(터치스크린·웹 maxTouchPoints·강제 인자)이다.
## 실행 중에는 바뀌지 않는다고 보고 처음 한 번만 판별한다.
static func active() -> bool:
	if _active < 0:
		_active = 1 if TouchControls.should_show() else 0
	return _active == 1


## 버튼 하나를 터치 크기로 맞춘다: 최소 높이·최소 폭·글자 하한, 필요하면 재봉 팔레트 스타일.
static func button(b: Button, font: int = BUTTON_FONT, min_w: float = 0.0) -> void:
	b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, MIN_H)
	b.custom_minimum_size.x = maxf(b.custom_minimum_size.x, min_w)
	b.add_theme_font_size_override("font_size", maxi(font, b.get_theme_font_size("font_size")))
	if b.has_theme_constant_override("icon_max_width"):
		b.add_theme_constant_override("icon_max_width", 40)
	var sb: StyleBox = b.get_theme_stylebox("normal")
	if sb is StyleBoxTexture and _texture_h(sb as StyleBoxTexture) < MIN_H:
		_flat_look(b)


static func buttons(list: Array, font: int = BUTTON_FONT) -> void:
	for b in list:
		button(b, font)


## 라벨·입력 칸 글자를 하한 이상으로 올린다(원래 더 크면 그대로).
static func text(c: Control, font: int = TEXT_FONT) -> void:
	c.add_theme_font_size_override("font_size", maxi(font, c.get_theme_font_size("font_size")))


static func texts(list: Array, font: int = TEXT_FONT) -> void:
	for c in list:
		text(c, font)


## 입력 칸(LineEdit·TextEdit)을 손가락 높이와 버튼 글자 크기로 맞춘다.
static func edit(c: Control) -> void:
	c.custom_minimum_size.y = maxf(c.custom_minimum_size.y, MIN_H)
	text(c, BUTTON_FONT)


## 중앙 앵커(preset 8) 컨트롤의 오프셋을 반폭·반높이로 맞춘다.
static func set_box(c: Control, half: Vector2) -> void:
	c.offset_left = -half.x
	c.offset_right = half.x
	c.offset_top = -half.y
	c.offset_bottom = half.y


## 세로 목록 parent의 index 자리에 두 열(HBox 안 VBox 둘)을 만들고 left·right 노드를 옮긴다.
## 노드 참조는 그대로라 화면 스크립트의 @onready 변수는 계속 쓸 수 있다. [왼쪽, 오른쪽] VBox를 돌려준다.
static func columns(
	parent: Container, index: int, left: Array, right: Array, gap: int = 28, col_w: float = 0.0
) -> Array:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "TouchColumns"
	row.add_theme_constant_override("separation", gap)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	parent.move_child(row, index)
	var out: Array = []
	for nodes in [left, right]:
		var col: VBoxContainer = VBoxContainer.new()
		col.add_theme_constant_override("separation", parent.get_theme_constant("separation"))
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.custom_minimum_size.x = col_w
		row.add_child(col)
		for n in nodes:
			(n as Node).reparent(col, false)
		out.append(col)
	out[0].name = "Left"
	out[1].name = "Right"
	return out


## 가로 줄(HBox)의 버튼들을 줄 안의 흐름 컨테이너로 옮겨, 한 줄에 최소 폭 min_w 버튼이 들어가는 만큼만
## 놓고 나머지는 다음 줄로 넘긴다(보이는 버튼은 줄 폭을 나눠 채우고, 하나만 보이면 한 줄을 다 쓴다).
## 줄 자체의 visible은 그대로라 화면 스크립트가 줄 단위로 숨기고 보이는 규칙이 유지된다.
static func wrap_row(row: Container, min_w: float, gap: int = 12) -> HFlowContainer:
	var flow: HFlowContainer = HFlowContainer.new()
	flow.name = "TouchFlow"
	flow.add_theme_constant_override("h_separation", gap)
	flow.add_theme_constant_override("v_separation", gap)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in row.get_children():
		(child as Node).reparent(flow, false)
		(child as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		(child as Control).custom_minimum_size.x = maxf(
			(child as Control).custom_minimum_size.x, min_w
		)
	row.add_child(flow)
	return flow


## 터치 배치에서만 content를 세로 스크롤 영역으로 감싼다(데스크톱이면 content를 그대로 돌려준다).
## 호출부는 돌려받은 노드를 원래 자리에 넣으면 된다. 포커스가 옮겨 가면 그 컨트롤까지 스크롤한다.
static func scroll(content: Control) -> Control:
	if not active():
		return content
	var sc: ScrollContainer = ScrollContainer.new()
	sc.name = "TouchScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.follow_focus = true
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_FILL
	sc.add_child(content)
	sc.visibility_changed.connect(_settle_scroll.bind(sc))
	return sc


## 보기가 나타나는 순간의 포커스 이동은 배치가 끝나기 전 크기로 스크롤을 잡으므로, 한 프레임 뒤 맨 위로
## 되돌리고 포커스가 영역 안에 있으면 그 컨트롤이 보이게 다시 맞춘다.
static func _settle_scroll(sc: ScrollContainer) -> void:
	if not sc.is_visible_in_tree():
		return
	await sc.get_tree().process_frame
	if not is_instance_valid(sc):
		return
	sc.scroll_vertical = 0
	var focus: Control = sc.get_viewport().gui_get_focus_owner()
	if focus != null and sc.is_ancestor_of(focus):
		sc.ensure_control_visible(focus)


## 한 줄 라벨이 긴 문자열(트랙 이름·닉네임)로 배치를 밀어내지 않게 말줄임으로 자른다.
static func ellipsis(l: Label) -> void:
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS


static func _texture_h(sb: StyleBoxTexture) -> float:
	return sb.texture.get_size().y if sb.texture != null else 0.0


## 재봉 팔레트 버튼 룩(베이지 원단 + 실 보라 테두리, 누르면 보라 + 크림 글자, 포커스는 빨간 테두리).
static func _flat_look(b: Button) -> void:
	var looks: Dictionary = {
		"normal": [SewingSkin.FABRIC, SewingSkin.THREAD_PURPLE, 3],
		"hover": [Color(0.95, 0.9, 0.78), SewingSkin.THREAD_PURPLE, 3],
		"pressed": [SewingSkin.THREAD_PURPLE, SewingSkin.KNOT, 3],
		"hover_pressed": [SewingSkin.THREAD_PURPLE, SewingSkin.KNOT, 3],
		"disabled": [Color(0.72, 0.68, 0.6, 0.7), SewingSkin.KNOT, 2],
		"focus": [Color(0, 0, 0, 0), UiSkin.FOCUS_RED, 4],
	}
	for key in looks:
		var v: Array = looks[key]
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = v[0]
		sb.border_color = v[1]
		sb.set_border_width_all(v[2])
		sb.set_corner_radius_all(_RADIUS)
		sb.content_margin_left = 18.0
		sb.content_margin_right = 18.0
		sb.content_margin_top = 8.0
		sb.content_margin_bottom = 8.0
		b.add_theme_stylebox_override(key, sb)
	b.add_theme_color_override("font_pressed_color", SewingSkin.CREAM)
	b.add_theme_color_override("font_hover_pressed_color", SewingSkin.CREAM)
