class_name CalibrationPromptDialog
extends Control
## 첫 Start 조향 감도 체험 여부를 묻는 모달 (재봉 스킨). 최초 닉네임을 확정한 새 사용자가 처음 Start를
## 누르면 메인 메뉴가 띄운다(res://scenes/CalibrationPromptDialog.tscn). ProfileDialog·NicknameDialog와
## 같은 모달 관례를 따른다(Dim + 재봉 패치 패널 + 버튼, 닫으면 queue_free).
##
## - "체험하기"(기본 포커스, Enter)는 accepted, "나중에"와 Esc(ui_cancel)는 declined를 방출하고 해제된다.
##   어느 쪽으로 갈지는 메인 메뉴가 정한다(체험 트랙 / 트랙 종류 선택).
## - ←→·Tab으로 두 버튼 사이를 오가고, 위아래 이동은 대화상자 밖(뒤의 메뉴 버튼)으로 새지 않게 막는다.
## - 순수 UI — 게임 값·판정과 무관. 체험 대기 소비(settings.json)는 메인 메뉴가 띄우기 전에 처리한다.
## - 터치 기기에서는 버튼을 손가락 크기(MenuTouch)로, 글자를 하한 이상으로 키우고 패널을 넓힌다.

signal accepted
signal declined

const TITLE_TEXT: String = "조향 감도를 먼저 맞춰 볼까요?"
# 본문 두 줄(표시할 때 줄 바꿈으로 잇는다).
const BODY_LINE_1: String = "짧은 체험 코스를 달리며 바늘이 꺾이는 정도를 조절할 수 있어요."
const BODY_LINE_2: String = "설정 화면과 트랙 선택의 '감도 다시 맞추기'에서도 언제든 바꿀 수 있어요."
const ACCEPT_TEXT: String = "체험하기"
const DECLINE_TEXT: String = "나중에"

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
# PanelBg가 Panel(VBox)을 감싸는 세로 여백(위/아래 각각)과 가로 여백.
const _PANEL_PAD_V: float = 32.0
const _PANEL_PAD_H: float = 40.0
# Panel 반폭(데스크톱 / 터치). 터치는 본문 글자가 커지므로 넓힌다.
const _HALF_W: float = 290.0
const _TOUCH_HALF_W: float = 420.0
# 터치 배치의 제목 글자(논리).
const _TOUCH_TITLE_FONT: int = 32

# 한 번만 방출하도록 막는다(버튼과 Esc가 같은 프레임에 겹쳐도 한 번).
var _closing: bool = false

@onready var _title: Label = $Panel/TitleLabel
@onready var _body: Label = $Panel/BodyLabel
@onready var _accept: Button = $Panel/ButtonRow/AcceptButton
@onready var _decline: Button = $Panel/ButtonRow/DeclineButton


func _ready() -> void:
	_title.text = TITLE_TEXT
	_body.text = BODY_LINE_1 + "\n" + BODY_LINE_2
	_accept.text = ACCEPT_TEXT
	_decline.text = DECLINE_TEXT
	_accept.pressed.connect(_on_accept_pressed)
	_decline.pressed.connect(_on_decline_pressed)
	_wire_focus()
	_apply_skin()
	_apply_touch_layout()
	_accept.grab_focus()
	_fit_to_content()


## 두 버튼 사이만 순환하게 이웃을 지정한다(←→·Tab·Shift+Tab). 위아래는 제자리로 막아
## 뒤에 깔린 메인 메뉴 버튼으로 포커스가 빠져나가지 않게 한다.
func _wire_focus() -> void:
	for pair in [[_accept, _decline], [_decline, _accept]]:
		var b: Button = pair[0]
		var other: NodePath = b.get_path_to(pair[1])
		b.focus_neighbor_left = other
		b.focus_neighbor_right = other
		b.focus_next = other
		b.focus_previous = other
		b.focus_neighbor_top = NodePath(".")
		b.focus_neighbor_bottom = NodePath(".")


## 줄 바꿈 본문·버튼의 최소 크기가 확정된 뒤(한 프레임 뒤) 패널 세로 크기를 콘텐츠에 맞춘다.
func _fit_to_content() -> void:
	await get_tree().process_frame
	if not is_instance_valid(self) or not is_inside_tree():
		return
	var half_w: float = _TOUCH_HALF_W if MenuTouch.active() else _HALF_W
	var panel: Control = $Panel
	var h: float = panel.get_combined_minimum_size().y
	MenuTouch.set_box(panel, Vector2(half_w, h * 0.5))
	# 시트 스킨 패치(NinePatchRect)는 패치 여백 합보다 작아지지 않으므로, 배경을 그 최소 크기
	# 이상으로 잡아 패치가 배경 밖으로 삐져나가지 않게 한다(콘텐츠는 가운데 그대로).
	var bg_min: Vector2 = Vector2.ZERO
	var skin: Control = $PanelBg.get_node_or_null("UiSkinPanel")
	if skin != null:
		bg_min = skin.get_combined_minimum_size()
	var bg_half: Vector2 = Vector2(half_w + _PANEL_PAD_H, h * 0.5 + _PANEL_PAD_V)
	MenuTouch.set_box($PanelBg, bg_half.max(bg_min * 0.5))


## Esc는 "나중에"와 같다.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_decline_pressed()


func _on_accept_pressed() -> void:
	if _closing:
		return
	_closing = true
	accepted.emit()
	queue_free()


func _on_decline_pressed() -> void:
	if _closing:
		return
	_closing = true
	declined.emit()
	queue_free()


## 터치 기기: 버튼을 손가락 크기로, 본문·제목 글자를 키운다(패널 폭은 _fit_to_content가 맞춘다).
func _apply_touch_layout() -> void:
	if not MenuTouch.active():
		return
	MenuTouch.buttons([_accept, _decline])
	MenuTouch.text(_body)
	MenuTouch.text(_title, _TOUCH_TITLE_FONT)
	($Panel/ButtonRow as Control).add_theme_constant_override("separation", 20)


## 시트 스킨(있으면) 소형 필 버튼 + 베이지 패널, 없으면 절차 폴백(NicknameDialog와 동일).
func _apply_skin() -> void:
	if UiSkin.has_skin():
		UiSkin.skin_panel($PanelBg, "beige")
		UiSkin.skin_button(_accept, "small", 18)
		UiSkin.skin_button(_decline, "small", 18)
		return
	_skin_button(_accept)
	_skin_button(_decline)


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
