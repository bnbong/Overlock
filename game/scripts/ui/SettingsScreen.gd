extends Control
## 온라인 설정 화면(재봉 스킨 패널). 닉네임(1~16자)만 입력·저장한다(기획서 §18 Phase 5
## 닉네임 입력). 저장은 LeaderboardClient가 user://settings.json에 영속한다.
##
## 서버 URL은 UI에서 제거했다(배포 시 데스크톱 기본값=프로덕션, 웹=same-origin 자동).
## 셀프호스팅/개발은 user://settings.json에 base_url을 수동으로 적어 우선시킨다. 이 화면은
## 닉네임 관리 중심이며, 추후 볼륨 등 설정이 여기에 더해진다. 닉네임 변경은 메인 화면의
## 닉네임 태그로도 가능하다(진입점 중복 허용).

const MAIN_SCENE: String = "res://scenes/Main.tscn"

# 재봉 스킨 버튼 톤(MainMenu와 통일).
const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

@onready var _nick_edit: LineEdit = $Panel/NickRow/NickEdit
@onready var _hint_label: Label = $Panel/HintLabel
@onready var _status_label: Label = $Panel/StatusLabel
@onready var _save_button: Button = $Panel/SaveButton
@onready var _back_button: Button = $Panel/BackButton


func _ready() -> void:
	_nick_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_nick_edit.text = LeaderboardClient.nickname
	_hint_label.text = "리더보드에 표시될 닉네임 (1~16자)"
	_apply_skin()
	_save_button.pressed.connect(_on_save_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_nick_edit.text_submitted.connect(_on_nick_submitted)
	_status_label.text = ""
	_nick_edit.grab_focus()


func _on_nick_submitted(_text: String) -> void:
	_on_save_pressed()


func _on_save_pressed() -> void:
	var nick: String = _nick_edit.text.strip_edges()
	if nick.is_empty():
		_status_label.text = "닉네임을 입력하세요 (1~16자)"
		return
	if not LeaderboardClient.save_nickname(nick):
		_status_label.text = "저장 실패"
		return
	# 정규화된 값으로 필드를 되비춘다(공백 제거 등).
	_nick_edit.text = LeaderboardClient.nickname
	_status_label.text = "저장됨"


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


## 사용자 제공 시트 스킨(있으면): 베이지 카드 패널 + 소형 필 버튼. 없으면 절차 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		for b in [_save_button, _back_button]:
			_skin_button(b)
		return
	UiSkin.skin_panel(get_node("PanelBg"), "beige")
	for b in [_save_button, _back_button]:
		UiSkin.skin_button(b, "small", 16)


## 재봉 스킨 톤 버튼 스타일(MainMenu._skin_button와 동일 계열).
func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 16)
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
