extends Control
## 메인 메뉴(2단 네비게이션 1단). 타이틀 플라크 + 세로 4버튼(Start / Settings /
## Leaderboard / Quit)만 둔다. 트랙 캐러셀·미리보기·에디터/불러오기/삭제는 Start로
## 진입하는 맵 선택 화면(TrackSelect)으로 이관했다(아키텍처 §2.1 갱신).
##
## 키보드: ↑↓(ui_up/ui_down)로 버튼 포커스 이동, Enter(ui_accept)로 실행 — Godot
## 기본 GUI 포커스 순환을 그대로 쓰고 초기 포커스만 Start에 준다. 포커스 표시는
## 버튼 focus 스타일박스(빨간 테두리)로 제공한다.
##
## 정체성 바(좌상단): 현재 닉네임 태그 + 온라인/오프라인 상태. 진입 시 닉네임이 없으면
## 최초 실행 닉네임 모달을 띄우고(항상 닉네임 보장), 백그라운드 health_check로 서버 연결을
## 확인해 상태 점을 갱신한다. 서버 미연결이면 세션당 1회 안내 토스트를 띄운다.

const TRACK_SELECT_SCENE: String = "res://scenes/TrackSelect.tscn"
const SETTINGS_SCENE: String = "res://scenes/Settings.tscn"
const LEADERBOARD_SCENE: String = "res://scenes/Leaderboard.tscn"

# 리더보드 복귀 씬을 진입 직전 설정한다(메인에서 열면 뒤로가기는 메인으로).
const LeaderboardScreenScript = preload("res://scripts/ui/LeaderboardScreen.gd")
const ToastScene = preload("res://scenes/Toast.tscn")
const NicknameDialogScene = preload("res://scenes/NicknameDialog.tscn")

const _OFFLINE_MSG: String = "서버에 연결할 수 없어 기록이 온라인 리더보드에 제출되지 않습니다." + " 로컬 최고 기록은 계속 저장됩니다."
const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
const _C_ONLINE: Color = Color(0.36, 0.78, 0.46)
const _C_OFFLINE: Color = Color(0.87, 0.47, 0.42)
const _C_CHECKING: Color = Color(0.82, 0.79, 0.72)

var _toast: Toast
var _nick_tag: Button
var _status_label: Label

@onready var _start_button: Button = $Menu/StartButton
@onready var _settings_button: Button = $Menu/SettingsButton
@onready var _leaderboard_button: Button = $Menu/LeaderboardButton
@onready var _quit_button: Button = $Menu/QuitButton


func _ready() -> void:
	_start_button.pressed.connect(_on_start_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_leaderboard_button.pressed.connect(_on_leaderboard_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_apply_skin()
	# 웹(HTML5)에는 앱 종료 개념이 없어 Quit 버튼을 숨긴다(브라우저 탭이 곧 앱 수명).
	_quit_button.visible = not OS.has_feature("web")

	_toast = ToastScene.instantiate()
	add_child(_toast)
	_build_identity_bar()
	LeaderboardClient.health_checked.connect(_on_health_checked)

	_start_button.grab_focus()

	# 최초 실행: 닉네임이 없으면 설정 모달을 띄워 항상 닉네임이 존재하도록 보장한다.
	if not LeaderboardClient.has_nickname():
		_open_nickname_dialog()
	# 백그라운드 서버 연결 확인(상태 점 갱신 + 오프라인 시 세션 1회 토스트).
	LeaderboardClient.health_check()


## 사용자 제공 시트 스킨(있으면) 적용 — 대형 필 버튼 + 의미별 아이콘. 없으면 .tscn 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		return
	for b in [_start_button, _settings_button, _leaderboard_button, _quit_button]:
		UiSkin.skin_button(b, "large")


# --- 정체성 바(좌상단): 닉네임 태그 + 온라인 상태 ---


func _build_identity_bar() -> void:
	var bar: VBoxContainer = VBoxContainer.new()
	bar.name = "IdentityBar"
	bar.position = Vector2(16.0, 14.0)
	bar.add_theme_constant_override("separation", 4)
	add_child(bar)

	_nick_tag = Button.new()
	_nick_tag.focus_mode = Control.FOCUS_NONE
	_nick_tag.add_theme_font_size_override("font_size", 16)
	_skin_tag(_nick_tag)
	_nick_tag.pressed.connect(_open_nickname_dialog)
	bar.add_child(_nick_tag)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_outline_color", Color(0.11, 0.086, 0.072))
	_status_label.add_theme_constant_override("outline_size", 3)
	bar.add_child(_status_label)

	_refresh_nick_tag()
	_set_status(_C_CHECKING, "서버 확인 중…")


func _refresh_nick_tag() -> void:
	var nick: String = LeaderboardClient.nickname.strip_edges()
	_nick_tag.text = "·  " + (nick if not nick.is_empty() else "닉네임 설정")


func _set_status(color: Color, text: String) -> void:
	_status_label.add_theme_color_override("font_color", color)
	_status_label.text = "●  " + text


func _open_nickname_dialog() -> void:
	var dlg: NicknameDialog = NicknameDialogScene.instantiate()
	add_child(dlg)
	dlg.confirmed.connect(_on_nickname_confirmed)


func _on_nickname_confirmed(_nickname: String) -> void:
	_refresh_nick_tag()


func _on_health_checked(ok: bool, _message: String) -> void:
	if not is_instance_valid(_status_label):
		return
	if ok:
		_set_status(_C_ONLINE, "온라인")
	else:
		_set_status(_C_OFFLINE, "오프라인")
		# 오프라인 안내는 세션당 1회만(메뉴 재방문마다 반복 금지).
		if not LeaderboardClient.offline_notice_shown:
			LeaderboardClient.offline_notice_shown = true
			_toast.push(_OFFLINE_MSG)


## 좌상단 소형 태그(재봉 패치 톤): 베이지 원단 + 실 보라 테두리.
func _skin_tag(b: Button) -> void:
	b.add_theme_color_override("font_color", _INK)
	b.add_theme_color_override("font_hover_color", _INK_HOVER)
	b.add_theme_color_override("font_pressed_color", _INK_HOVER)
	b.add_theme_stylebox_override(
		"normal", _tag_box(Color(0.831, 0.753, 0.6), Color(0.553, 0.384, 0.725))
	)
	b.add_theme_stylebox_override(
		"hover", _tag_box(Color(0.906, 0.835, 0.686), Color(0.616, 0.435, 0.784))
	)
	b.add_theme_stylebox_override(
		"pressed", _tag_box(Color(0.761, 0.682, 0.541), Color(0.478, 0.333, 0.243))
	)


static func _tag_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.24)
	sb.shadow_size = 3
	sb.shadow_offset = Vector2(0.0, 2.0)
	return sb


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(TRACK_SELECT_SCENE)


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file(SETTINGS_SCENE)


## 메인에서 직접 여는 리더보드는 트랙 컨텍스트가 없으므로, 리더보드 화면이 첫 공식
## 트랙으로 자체 초기화하도록 조회 대상을 비우고 복귀 씬만 메인으로 지정한다.
## (화면 안 ◀▶로 공식 트랙을 전환한다.)
func _on_leaderboard_pressed() -> void:
	LeaderboardScreenScript.return_scene = "res://scenes/Main.tscn"
	LeaderboardClient.set_view_target("", LeaderboardClient.view_difficulty, "")
	get_tree().change_scene_to_file(LEADERBOARD_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()
