class_name NicknameDialog
extends Control
## 닉네임 설정/변경 모달 (재봉 스킨). 최초 실행(닉네임 미설정) 진입과 타이틀 태그 클릭에서
## 공유한다(res://scenes/NicknameDialog.tscn).
##
## - 닉네임 미설정이면 추천 닉네임("Stitcher-####")을 프리필하고, 설정돼 있으면 현재 값을 채운다.
## - 확인/Enter 또는 Esc/닫기 모두로 확정한다. 입력이 비었거나 규칙(1~16자)에 어긋나면 프리필
##   값으로 확정해 "항상 닉네임이 존재"하도록 보장한다.
## - 확정 시 LeaderboardClient.save_nickname으로 영속하고 confirmed(nickname)을 방출한 뒤 스스로
##   해제된다. 순수 UI — 게임 값·판정과 무관.

signal confirmed(nickname: String)

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

# Esc/빈 입력 시 확정할 폴백(항상 닉네임 보장). 프리필과 동일.
var _fallback: String = ""

@onready var _title: Label = $Panel/TitleLabel
@onready var _edit: LineEdit = $Panel/NickEdit
@onready var _confirm: Button = $Panel/ConfirmButton


func _ready() -> void:
	var existing: String = LeaderboardClient.nickname.strip_edges()
	if existing.is_empty():
		_title.text = "닉네임 설정"
		_fallback = _suggested_nickname()
	else:
		_title.text = "닉네임 변경"
		_fallback = existing
	_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_edit.text = _fallback
	_edit.select_all()
	_edit.grab_focus()
	_edit.text_submitted.connect(_on_submitted)
	_confirm.pressed.connect(_do_confirm)
	_apply_skin()


## UI 전용 추천 닉네임(결정론 무관 — randi 허용). "Stitcher-" + 랜덤 4자리.
func _suggested_nickname() -> String:
	return "Stitcher-%04d" % (randi() % 10000)


func _on_submitted(_text: String) -> void:
	_do_confirm()


## Esc/닫기도 확정으로 처리(항상 닉네임 보장). 유효 입력이면 그 값, 아니면 프리필로.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_do_confirm()
		accept_event()


func _do_confirm() -> void:
	var nick: String = _edit.text.strip_edges()
	if nick.is_empty() or nick.length() > LeaderboardClient.NICKNAME_MAX:
		nick = _fallback
	LeaderboardClient.save_nickname(nick)
	confirmed.emit(nick)
	queue_free()


## 시트 스킨(있으면) 소형 필 버튼, 없으면 절차 폴백.
func _apply_skin() -> void:
	if UiSkin.has_skin():
		UiSkin.skin_panel($PanelBg, "beige")
		UiSkin.skin_button(_confirm, "small", 18)
		return
	_skin_button(_confirm)


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
