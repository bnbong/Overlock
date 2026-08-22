extends Control
## 온라인 설정 화면(재봉 스킨 패널). 닉네임(1~16자) + 서버 URL을 입력·저장한다
## (기획서 §18 Phase 5 닉네임 입력). 저장은 LeaderboardClient가 user://settings.json에
## 영속한다. 서버 URL을 비우면 온라인 기능이 비활성된다.
##
## "서버 연결 확인" 버튼은 GET /api/health로 현재 URL의 연결성을 점검해 표시한다.

const MAIN_SCENE: String = "res://scenes/Main.tscn"

# 재봉 스킨 버튼 톤(MainMenu와 통일).
const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

@onready var _nick_edit: LineEdit = $Panel/NickRow/NickEdit
@onready var _url_edit: LineEdit = $Panel/UrlRow/UrlEdit
@onready var _hint_label: Label = $Panel/HintLabel
@onready var _status_label: Label = $Panel/StatusLabel
@onready var _test_button: Button = $Panel/TestButton
@onready var _save_button: Button = $Panel/SaveButton
@onready var _back_button: Button = $Panel/BackButton


func _ready() -> void:
	_nick_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_nick_edit.text = LeaderboardClient.nickname
	_url_edit.text = LeaderboardClient.base_url
	if OS.has_feature("web"):
		# 웹 배포는 게임·API가 동일 도메인이라 비워두면 현재 사이트를 자동 사용한다.
		_url_edit.placeholder_text = "비우면 현재 사이트 사용"
		_hint_label.text = "Server URL을 비우면 현재 사이트를 자동 사용합니다."
	else:
		_url_edit.placeholder_text = LeaderboardClient.DEFAULT_BASE_URL
	_apply_skin()
	_test_button.pressed.connect(_on_test_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	LeaderboardClient.health_checked.connect(_on_health_checked)
	_status_label.text = ""
	_nick_edit.grab_focus()


func _on_save_pressed() -> void:
	var nick: String = _nick_edit.text.strip_edges()
	var url: String = _url_edit.text.strip_edges()
	if not LeaderboardClient.save_settings(nick, url):
		_status_label.text = "저장 실패"
		return
	# 정규화된 값으로 필드를 되비춘다(공백 제거 등).
	_nick_edit.text = LeaderboardClient.nickname
	_url_edit.text = LeaderboardClient.base_url
	if not LeaderboardClient.is_online_enabled():
		_status_label.text = "저장됨 · 온라인 비활성(서버 URL 비어 있음)"
	elif not LeaderboardClient.has_nickname():
		_status_label.text = "저장됨 · 제출하려면 닉네임 필요"
	else:
		_status_label.text = "저장됨"


func _on_test_pressed() -> void:
	if not LeaderboardClient.is_online_enabled():
		_status_label.text = "서버 URL을 먼저 입력하세요"
		return
	# 입력 중인 URL을 즉시 반영해 확인한다(저장 없이도 점검 가능).
	LeaderboardClient.base_url = _url_edit.text.strip_edges()
	_status_label.text = "확인 중..."
	LeaderboardClient.health_check()


func _on_health_checked(ok: bool, message: String) -> void:
	if ok:
		# message에는 서버 버전이 담겨 온다(있으면 함께 표시).
		_status_label.text = "서버 연결됨" + ((" · v" + message) if not message.is_empty() else "")
	else:
		_status_label.text = "연결 실패: " + message


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


## 사용자 제공 시트 스킨(있으면): 베이지 카드 패널 + 소형 필 버튼. 없으면 절차 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		for b in [_test_button, _save_button, _back_button]:
			_skin_button(b)
		return
	UiSkin.skin_panel(get_node("PanelBg"), "beige")
	for b in [_test_button, _save_button, _back_button]:
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
