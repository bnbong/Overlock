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

signal confirmed(nickname: String)
signal cancelled

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
const _HINT: Color = Color(0.478, 0.333, 0.243)
const _WARN: Color = Color(0.72, 0.2, 0.16)
const HINT_TEXT: String = "1~16자 · 언제든 다시 바꿀 수 있어요"
# 터치 배치에서 패널이 콘텐츠를 감싸는 여백(위아래)과 패널 반폭.
const _TOUCH_PAD_V: float = 36.0
const _TOUCH_HALF_W: float = 330.0

# 최초 설정이면 true(보조 버튼이 "기본 닉네임으로 시작", Esc도 같다).
var _first_visit: bool = false
# 최초 설정에서 "기본 닉네임으로 시작"이 저장할 추천 닉네임.
var _suggested: String = ""

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
	MenuTouch.buttons([_confirm, _secondary])
	MenuTouch.edit(_edit)
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
