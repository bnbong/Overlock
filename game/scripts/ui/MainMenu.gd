extends Control
## 메인 메뉴(2단 네비게이션 1단). 타이틀 플라크 + 세로 4버튼(Start / Settings /
## Leaderboard / Quit)만 둔다. 트랙 캐러셀·미리보기·에디터/불러오기/삭제는 Start로
## 진입하는 맵 선택 화면(TrackSelect)으로 이관했다(아키텍처 §2.1 갱신).
##
## 키보드: ↑↓(ui_up/ui_down)로 버튼 포커스 이동, Enter(ui_accept)로 실행 — Godot
## 기본 GUI 포커스 순환을 그대로 쓰고 초기 포커스만 Start에 준다. 포커스 표시는
## 버튼 focus 스타일박스(빨간 테두리)로 제공한다.

const TRACK_SELECT_SCENE: String = "res://scenes/TrackSelect.tscn"
const SETTINGS_SCENE: String = "res://scenes/Settings.tscn"
const LEADERBOARD_SCENE: String = "res://scenes/Leaderboard.tscn"

# 리더보드 복귀 씬을 진입 직전 설정한다(메인에서 열면 뒤로가기는 메인으로).
const LeaderboardScreenScript = preload("res://scripts/ui/LeaderboardScreen.gd")

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
	_start_button.grab_focus()


## 사용자 제공 시트 스킨(있으면) 적용 — 대형 필 버튼 + 의미별 아이콘. 없으면 .tscn 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		return
	for b in [_start_button, _settings_button, _leaderboard_button, _quit_button]:
		UiSkin.skin_button(b, "large")



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
