class_name NicknameDialog
extends Control
## 닉네임 설정/변경 모달 (재봉 스킨). 최초 실행(닉네임 미설정) 진입과 타이틀 태그 클릭에서
## 공유한다(res://scenes/NicknameDialog.tscn).
##
## 저장 규칙(v2.2.1, 명시 저장/취소):
## - 닉네임 변경(이미 있음): 현재 값을 채운다. "저장"/Enter만 저장하고, "취소"/Esc는 수정한 내용을
##   버리고 닫는다(cancelled).
## - 최초 설정(없음): 추천 닉네임("Stitcher-####")을 채워 두고, "저장"/Enter는 입력 칸의 값을,
##   "기본 닉네임으로 시작"은 추천 닉네임을 저장한다. 닉네임이 항상 있어야 하므로 Esc는
##   "기본 닉네임으로 시작"과 같다.
## - 빈 입력은 저장하지 않고 안내한다. LeaderboardClient.save_nickname이 실패하면 닫지 않고 알리며,
##   이전 닉네임이 그대로 유지된다(다시 저장하거나 취소할 수 있다).
## - 저장에 성공하면 confirmed(nickname)을 방출하고 스스로 해제된다. 순수 UI — 게임 값·판정과 무관.
## - 터치 기기에서는 MenuTouch 크기(버튼·입력 칸 높이, 글자)와 넓은 패널을 쓴다.
##
## 모바일 가상 키보드(v2.3.1, docs/mobile.md §5.1.1):
## - 웹 export의 가상 키보드 옵션을 켰다. 태그를 탭하면 그 터치 처리 안에서 이 대화상자가 열리고 입력 칸이
##   포커스를 얻어 엔진이 키보드를 요청한다. 키보드를 닫은 뒤 입력 칸을 다시 탭해도 엔진이 다시 요청한다.
## - 키보드가 뜰 수 있는 환경(DisplayServer 가상 키보드 기능)에서 입력 중이면 패널을 화면 위쪽으로 올린다.
##   웹은 키보드 높이를 알려 주지 않으므로 패널 윗변을 화면 맨 위 근처에 고정한다.
## - 키보드가 뜨지 않는 환경을 위해 터치 배치에만 "추천 이름으로 바꾸기"를 둔다. 입력 칸을 새 추천
##   닉네임으로 바꾸기만 하고, 저장은 "저장"으로 한다(최초 설정이면 "기본 닉네임으로 시작"도 그 이름을 쓴다).

signal confirmed(nickname: String)
signal cancelled

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
const _HINT: Color = Color(0.478, 0.333, 0.243)
const _WARN: Color = Color(0.72, 0.2, 0.16)
const HINT_TEXT: String = "1~16자 · 언제든 다시 바꿀 수 있어요"
const SUGGEST_TEXT: String = "추천 이름으로 바꾸기"
# 터치 배치에서 패널이 콘텐츠를 감싸는 여백(위아래)과 패널 반폭.
const _TOUCH_PAD_V: float = 36.0
const _TOUCH_HALF_W: float = 330.0
# 가상 키보드를 피해 패널을 올릴 때 패널 윗변의 화면 위 여백(논리).
const _KEYBOARD_TOP: float = 12.0

# 최초 설정이면 true(보조 버튼이 "기본 닉네임으로 시작", Esc도 같다).
var _first_visit: bool = false
# 최초 설정에서 "기본 닉네임으로 시작"이 저장할 추천 닉네임.
var _suggested: String = ""
# 가상 키보드를 피해 패널을 올린 거리(논리, 위로 음수). 0이면 가운데.
var _kb_lift: float = 0.0

@onready var _title: Label = $Panel/TitleLabel
@onready var _edit: LineEdit = $Panel/NickEdit
@onready var _hint: Label = $Panel/HintLabel
@onready var _confirm: Button = $Panel/ConfirmButton
@onready var _secondary: Button = $Panel/SecondaryButton


func _ready() -> void:
	var existing: String = LeaderboardClient.nickname.strip_edges()
	_first_visit = existing.is_empty()
	if _first_visit:
		_title.text = "닉네임 설정"
		_suggested = _suggested_nickname()
		_edit.text = _suggested
		_secondary.text = "기본 닉네임으로 시작"
	else:
		_title.text = "닉네임 변경"
		_edit.text = existing
		_secondary.text = "취소"
	_confirm.text = "저장"
	_hint.text = HINT_TEXT
	_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_edit.select_all()
	_edit.grab_focus()
	_edit.text_submitted.connect(_on_submitted)
	_confirm.pressed.connect(_on_save_pressed)
	_secondary.pressed.connect(_on_secondary_pressed)
	_apply_skin()
	_apply_touch_layout()


## UI 전용 추천 닉네임(결정론 무관 — randi 허용). "Stitcher-" + 랜덤 4자리.
func _suggested_nickname() -> String:
	return "Stitcher-%04d" % (randi() % 10000)


func _on_submitted(_text: String) -> void:
	_on_save_pressed()


## Esc: 변경이면 취소, 최초 설정이면 기본 닉네임으로 시작.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_secondary_pressed()


func _on_secondary_pressed() -> void:
	if _first_visit:
		_commit(_suggested)
		return
	cancelled.emit()
	queue_free()


## "저장"/Enter: 입력 칸의 값을 저장한다. 비어 있으면 저장하지 않고 안내한다.
func _on_save_pressed() -> void:
	var nick: String = _edit.text.strip_edges()
	if nick.is_empty() or nick.length() > LeaderboardClient.NICKNAME_MAX:
		_show_error("닉네임을 입력하세요 (1~16자)")
		_edit.grab_focus()
		return
	_commit(nick)


## 저장에 성공하면 알리고 닫는다. 실패하면 대화상자를 유지하고 사유를 보인다.
func _commit(nick: String) -> void:
	if not LeaderboardClient.save_nickname(nick):
		_show_error("저장하지 못했습니다. 다시 시도하세요.")
		return
	confirmed.emit(LeaderboardClient.nickname)
	queue_free()


func _show_error(text: String) -> void:
	_hint.text = text
	_hint.add_theme_color_override("font_color", _WARN)


## 터치 기기: 버튼·입력 칸을 손가락 크기로, 글자를 키우고 패널을 콘텐츠에 맞춰 넓힌다.
func _apply_touch_layout() -> void:
	if not MenuTouch.active():
		return
	var suggest: Button = _make_suggest_button()
	MenuTouch.buttons([suggest, _confirm, _secondary])
	MenuTouch.edit(_edit)
	_edit.editing_toggled.connect(_on_editing_toggled)
	MenuTouch.texts([$Panel/InfoLabel, _hint])
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	($Panel as Control).add_theme_constant_override("separation", 10)
	_fit_touch_panel()


## 줄 바꿈 라벨·버튼의 최소 크기가 확정된 뒤(한 프레임 뒤) 패널을 콘텐츠 높이에 맞춘다.
func _fit_touch_panel() -> void:
	await get_tree().process_frame
	var panel: Control = $Panel
	var h: float = panel.get_combined_minimum_size().y
	MenuTouch.set_box(panel, Vector2(_TOUCH_HALF_W, h * 0.5))
	MenuTouch.set_box($PanelBg, Vector2(_TOUCH_HALF_W + 50.0, h * 0.5 + _TOUCH_PAD_V))
	_kb_lift = 0.0
	_set_keyboard_lift(_edit.is_editing() and _keyboard_expected())


## 터치 배치 전용 "추천 이름으로 바꾸기" 버튼을 "저장" 위에 만든다(키보드 없이 바꾸는 길).
func _make_suggest_button() -> Button:
	var b: Button = Button.new()
	b.name = "SuggestButton"
	b.text = SUGGEST_TEXT
	b.focus_mode = Control.FOCUS_NONE
	if UiSkin.has_skin():
		UiSkin.skin_button(b, "small", 18)
	else:
		_skin_button(b)
	var panel: Control = $Panel
	panel.add_child(b)
	panel.move_child(b, _confirm.get_index())
	b.pressed.connect(_on_suggest_pressed)
	return b


## 입력 칸을 지금과 다른 새 추천 닉네임으로 바꾼다. 저장은 하지 않는다.
func _on_suggest_pressed() -> void:
	var nick: String = _suggested_nickname()
	while nick == _edit.text:
		nick = _suggested_nickname()
	_edit.text = nick
	_edit.caret_column = nick.length()
	if _first_visit:
		_suggested = nick
	_hint.text = HINT_TEXT
	_hint.add_theme_color_override("font_color", _HINT)


## 가상 키보드가 뜰 수 있는 환경인지(웹은 export의 가상 키보드 옵션과 터치 지원 브라우저일 때만 참).
func _keyboard_expected() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD)


func _on_editing_toggled(on: bool) -> void:
	_set_keyboard_lift(on and _keyboard_expected())


## 입력 중이면 패널을 화면 위쪽으로 올려 아래쪽 가상 키보드에 가리지 않게 하고, 아니면 가운데로 되돌린다.
func _set_keyboard_lift(on: bool) -> void:
	var bg: Control = $PanelBg
	var target: float = 0.0
	if on:
		var top: float = size.y * 0.5 + bg.offset_top - _kb_lift
		target = minf(0.0, _KEYBOARD_TOP - top)
	var delta: float = target - _kb_lift
	_kb_lift = target
	for c in [bg, $Panel]:
		(c as Control).offset_top += delta
		(c as Control).offset_bottom += delta


## 시트 스킨(있으면) 소형 필 버튼, 없으면 절차 폴백.
func _apply_skin() -> void:
	if UiSkin.has_skin():
		UiSkin.skin_panel($PanelBg, "beige")
		UiSkin.skin_button(_confirm, "small", 18)
		UiSkin.skin_button(_secondary, "small", 18)
		return
	_skin_button(_confirm)
	_skin_button(_secondary)


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
