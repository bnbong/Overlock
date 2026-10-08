extends Control
## 트랙 종류 선택 화면. 메인의 Start로 진입해 "공식 트랙"과 "유저 트랙" 가운데 하나를 고르면
## 맵 선택 화면(TrackSelect)을 해당 모드로 연다. 유저 트랙 쪽에서 공유 허브로 바로 이어지므로
## 허브 진입 경로가 메인에서 두 단계로 줄어든다.
##
## 선택지는 큰 카드 버튼 두 개(재봉 패치 톤: 베이지 원단 + 실 보라 테두리 + 박음질 + 모서리 단추)와
## 그 아래 보조 버튼 "감도 다시 맞추기"(+ 한 줄 설명), 뒤로 버튼이다. 감도 버튼은 조향 감도 체험
## 트랙(GameState.start_calibration)으로 바로 들어가며, 카드보다 작은 글자의 일반 필 버튼이라 시각적
## 우선순위가 낮다. 아이콘은 UiSkin 시트의 기존 아이콘(트로피·바늘)을 재사용하고, 없으면 글자만 보인다.
##
## 조작: ←→(ui_left/ui_right)로 카드 이동, ↓로 카드 → 감도 버튼 → 뒤로 버튼, ↑는 그 역순(감도 버튼에서
## ↑는 공식 트랙 카드). 감도 버튼과 뒤로 버튼의 ←→는 제자리에 머문다. Enter(ui_accept)로 결정, Esc(ui_cancel,
## 게임패드 B 포함)로 메인 복귀. 터치·마우스는 카드·버튼을 누르면 된다. 기본 포커스는 공식 트랙이고,
## TrackSelect에서 뒤로 돌아온 경우에는 방금 쓰던 모드의 카드에 포커스를 둔다.
##
## 글자 크기는 1280×720 캔버스 기준이며, 844×390 창(canvas_items + keep, 배율 약 0.54)에서도
## 제목 약 18px, 설명 약 12px로 읽히도록 크게 잡았다. 세로는 터치 배치(버튼 높이 84, 글자 하한 23)에서도
## 제목·카드·감도 버튼·설명·뒤로·힌트가 720 안에 들어가도록 카드 높이와 줄 간격을 잡았다.

const MAIN_SCENE: String = "res://scenes/Main.tscn"
const TRACK_SELECT_SCENE: String = "res://scenes/TrackSelect.tscn"
const TrackSelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const W = preload("res://scripts/ui/CommunityHubWidgets.gd")

const TITLE_TEXT: String = "어떤 트랙을 달릴까요?"
const OFFICIAL_TITLE: String = "공식 트랙"
const OFFICIAL_DESC: String = "기본으로 들어 있는 트랙입니다.\n기록을 공식 리더보드에 제출합니다."
const USER_TITLE: String = "유저 트랙"
const USER_DESC: String = "직접 만들거나 공유 허브에서 받은 트랙입니다.\n기록은 이 기기에만 저장됩니다."
const CALIBRATION_TEXT: String = "감도 다시 맞추기"
const CALIBRATION_DESC: String = "직접 달리며 조향 감도를 조절"
const HINT_TEXT: String = "← → ↑ ↓  이동      Enter  결정      Esc  뒤로"

const CARD_SIZE: Vector2 = Vector2(470.0, 300.0)
const TOUCH_CARD_SIZE: Vector2 = Vector2(580.0, 300.0)
const CARD_GAP: int = 44
const CARD_RADIUS: int = 18
const TITLE_FONT: int = 34
const CARD_TITLE_FONT: int = 36
const CARD_DESC_FONT: int = 22
const BACK_FONT: int = 22
# 감도 버튼·설명은 뒤로 버튼보다 한 단계 작게(844×390에서 약 11.4px, 읽기 하한 11px 이상).
const CALIBRATION_FONT: int = 21
const CALIBRATION_W: float = 320.0
const CALIBRATION_DESC_FONT: int = 21
const ROOT_GAP: int = 18
const CALIBRATION_GAP: int = 4
const HINT_FONT: int = 17

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_SOFT: Color = Color(0.36, 0.27, 0.21)
const _CREAM: Color = Color(0.968, 0.929, 0.847)

## 다음 _ready 1회만 공식 트랙 카드에 포커스를 준다(소비형). 감도 체험에서 돌아올 때
## GameState.exit_calibration이 켠다. 데모 뒤에는 공식 트랙으로 바로 이어 달리게 하려는 것이며
## (docs/sensitivity-calibration-plan.md), TrackSelectScript.last_mode는 그대로 둔다.
static var focus_official_once: bool = false

var _official_card: Button
var _user_card: Button
var _calibration_button: Button
var _back_button: Button


func _ready() -> void:
	_build_ui()
	_apply_touch_layout()
	if focus_official_once:
		focus_official_once = false
		_official_card.grab_focus()
	elif TrackSelectScript.last_mode == TrackSelectScript.MODE_USER:
		_user_card.grab_focus()
	else:
		_official_card.grab_focus()
	_play_menu_bgm()


## 터치 기기: 버튼·글자는 CommunityHubWidgets가 이미 키웠다. 커진 설명 글자가 카드 안에서 음절 단위로
## 끊기지 않게 카드만 넓힌다(두 장 합계 1204, 캔버스 1280 안).
func _apply_touch_layout() -> void:
	if not MenuTouch.active():
		return
	for card in [_official_card, _user_card]:
		(card as Control).custom_minimum_size = TOUCH_CARD_SIZE


## Esc(ui_cancel): 메인으로. 카드 이동·결정은 Godot 기본 GUI 포커스 처리에 맡긴다.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back_pressed()


func _build_ui() -> void:
	var root: VBoxContainer = W.vbox(ROOT_GAP)
	root.name = "Content"
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_top = 24.0
	root.offset_bottom = -24.0
	add_child(root)

	var title: Label = W.label(TITLE_TEXT, TITLE_FONT, _CREAM)
	title.name = "TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.26, 0.11, 0.15))
	title.add_theme_constant_override("outline_size", 7)
	root.add_child(title)

	var cards: HBoxContainer = W.hbox(CARD_GAP)
	cards.name = "Cards"
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(cards)
	_official_card = _make_card("OfficialCard", OFFICIAL_TITLE, OFFICIAL_DESC, "trophy")
	_official_card.pressed.connect(_choose.bind(TrackSelectScript.MODE_OFFICIAL))
	cards.add_child(_official_card)
	_user_card = _make_card("UserCard", USER_TITLE, USER_DESC, "needle")
	_user_card.pressed.connect(_choose.bind(TrackSelectScript.MODE_USER))
	cards.add_child(_user_card)

	# 감도 다시 맞추기: 버튼 + 바로 아래 한 줄 설명을 한 묶음으로 둔다(묶음 안 간격은 좁게).
	var calibration_box: VBoxContainer = W.vbox(CALIBRATION_GAP)
	calibration_box.name = "Calibration"
	root.add_child(calibration_box)
	var calibration_row: HBoxContainer = W.hbox(0)
	calibration_row.alignment = BoxContainer.ALIGNMENT_CENTER
	calibration_box.add_child(calibration_row)
	_calibration_button = W.button(CALIBRATION_TEXT, CALIBRATION_FONT, CALIBRATION_W)
	_calibration_button.name = "CalibrationButton"
	_calibration_button.pressed.connect(_on_calibration_pressed)
	calibration_row.add_child(_calibration_button)
	var calibration_desc: Label = W.label(
		CALIBRATION_DESC, CALIBRATION_DESC_FONT, Color(0.93, 0.88, 0.94)
	)
	calibration_desc.name = "CalibrationDescLabel"
	calibration_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	calibration_desc.add_theme_color_override("font_outline_color", _INK)
	calibration_desc.add_theme_constant_override("outline_size", 4)
	calibration_box.add_child(calibration_desc)

	var back_row: HBoxContainer = W.hbox(0)
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(back_row)
	_back_button = W.button("뒤로", BACK_FONT, 240.0)
	_back_button.name = "BackButton"
	_back_button.pressed.connect(_on_back_pressed)
	back_row.add_child(_back_button)

	var hint: Label = W.label(HINT_TEXT, HINT_FONT, Color(0.86, 0.80, 0.92))
	hint.name = "HintLabel"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_outline_color", _INK)
	hint.add_theme_constant_override("outline_size", 4)
	root.add_child(hint)

	# 포커스 이웃을 명시해 ←→·↑↓ 이동이 배치와 어긋나지 않게 한다.
	_official_card.focus_neighbor_right = _user_card.get_path()
	_official_card.focus_neighbor_left = _user_card.get_path()
	_user_card.focus_neighbor_left = _official_card.get_path()
	_user_card.focus_neighbor_right = _official_card.get_path()
	_official_card.focus_neighbor_bottom = _calibration_button.get_path()
	_user_card.focus_neighbor_bottom = _calibration_button.get_path()
	_calibration_button.focus_neighbor_top = _official_card.get_path()
	_calibration_button.focus_neighbor_bottom = _back_button.get_path()
	# 감도·뒤로 버튼의 ←→는 제자리(기본 탐색이 위쪽 버튼·카드로 튀지 않게 자기 자신을 이웃으로 둔다).
	_calibration_button.focus_neighbor_left = _calibration_button.get_path()
	_calibration_button.focus_neighbor_right = _calibration_button.get_path()
	_back_button.focus_neighbor_top = _calibration_button.get_path()
	_back_button.focus_neighbor_left = _back_button.get_path()
	_back_button.focus_neighbor_right = _back_button.get_path()


## 선택 카드: Button(텍스트 없음) 위에 아이콘·제목·설명을 쌓는다. 자식은 마우스를 통과시켜
## 카드 전체가 한 번의 클릭·탭으로 눌린다.
func _make_card(node_name: String, title: String, desc: String, icon_name: String) -> Button:
	var card: Button = Button.new()
	card.name = node_name
	card.custom_minimum_size = CARD_SIZE
	card.focus_mode = Control.FOCUS_ALL
	card.add_theme_stylebox_override(
		"normal", _card_box(SewingSkin.FABRIC, SewingSkin.THREAD_PURPLE)
	)
	card.add_theme_stylebox_override(
		"hover", _card_box(Color(0.95, 0.9, 0.78), Color(0.616, 0.435, 0.784))
	)
	card.add_theme_stylebox_override("pressed", _card_box(SewingSkin.FABRIC_DEEP, SewingSkin.KNOT))
	card.add_theme_stylebox_override(
		"hover_pressed", _card_box(SewingSkin.FABRIC_DEEP, SewingSkin.KNOT)
	)
	card.add_theme_stylebox_override("focus", _focus_box())

	var stitch: Control = Control.new()
	stitch.name = "Stitch"
	stitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stitch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stitch.draw.connect(_draw_card_stitch.bind(stitch))
	stitch.resized.connect(stitch.queue_redraw)
	card.add_child(stitch)

	var box: VBoxContainer = W.vbox(12)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 34.0
	box.offset_right = -34.0
	box.offset_top = 26.0
	box.offset_bottom = -26.0
	card.add_child(box)

	var tex: Texture2D = UiSkin.tex("icon_" + icon_name)
	if tex != null:
		var icon: TextureRect = TextureRect.new()
		icon.name = "Icon"
		icon.texture = tex
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(0.0, 60.0)
		icon.modulate = _INK
		box.add_child(icon)

	var title_label: Label = W.label(title, CARD_TITLE_FONT, _INK)
	title_label.name = "TitleLabel"
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)

	var desc_label: Label = W.label(desc, CARD_DESC_FONT, _INK_SOFT, true)
	desc_label.name = "DescLabel"
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(desc_label)
	return card


func _draw_card_stitch(c: Control) -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, c.size)
	SewingSkin.draw_stitch_border(c, rect, SewingSkin.THREAD_PURPLE, 11.0, float(CARD_RADIUS))
	SewingSkin.draw_corner_buttons(c, rect, 22.0)


static func _card_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(CARD_RADIUS)
	sb.shadow_color = SewingSkin.SHADOW
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## 포커스 표시: 투명 바탕 + 굵은 빨간 테두리(다른 메뉴의 포커스 색과 같다).
static func _focus_box() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = UiSkin.FOCUS_RED
	sb.set_border_width_all(5)
	sb.set_corner_radius_all(CARD_RADIUS)
	sb.expand_margin_left = 3.0
	sb.expand_margin_right = 3.0
	sb.expand_margin_top = 3.0
	sb.expand_margin_bottom = 3.0
	return sb


## 선택한 모드로 맵 선택 화면을 연다(모드는 TrackSelectScreen.pending_mode로 넘긴다).
func _choose(mode: String) -> void:
	TrackSelectScript.pending_mode = mode
	get_tree().change_scene_to_file(TRACK_SELECT_SCENE)


## 조향 감도 체험 트랙으로 바로 들어간다. 맵 선택 모드(pending_mode)는 건드리지 않는다.
func _on_calibration_pressed() -> void:
	GameState.start_calibration()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


## 메뉴 BGM(메뉴 곡). /root/AudioManager 런타임 조회 + has_method 가드(오토로드가 없으면 무시).
## 같은 곡이 이미 재생 중이면 AudioManager가 재시작하지 않는다.
func _play_menu_bgm() -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null and am.has_method("play_bgm"):
		am.play_bgm("menu")
