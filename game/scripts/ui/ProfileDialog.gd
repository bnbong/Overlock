class_name ProfileDialog
extends Control
## 개발자 프로필 팝업 (재봉 스킨 모달). 메인 메뉴 우하단 프로필 칩 클릭으로 연다
## (res://scenes/ProfileDialog.tscn). NicknameDialog와 동일한 모달 관례를 따른다
## (Dim + 재봉 패치 패널 + Esc/닫기로 해제, queue_free).
##
## - 아바타(원형, 재봉 톤 링) 크게 + 이름 + 한 줄 소개 + "GitHub 방문" 버튼 + 닫기.
## - 링크 열기: 데스크톱은 OS.shell_open, 웹은 JavaScriptBridge로 window.open(_, "_blank").
##   웹 팝업 차단을 피하려면 반드시 클릭(pressed) 핸들러 안에서 동기로 호출해야 한다.
## - 순수 UI — 게임 값·판정과 무관.

signal closed

const DEV_NAME: String = "bnbong"
const DEV_INTRO: String = "Overlock 개발자"
const GITHUB_URL: String = "https://github.com/bnbong"
# 확장 자리: Buy Me a Coffee 후원 버튼. 링크가 준비되면 아래 URL을 채우고
# $Panel/CoffeeButton.visible = true 로 노출한다(핸들러·스킨은 이미 배선돼 있다).
const COFFEE_URL: String = ""
const DEV_PROFILE_TEX: String = "res://assets/gfx/dev_profile.png"

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

@onready var _avatar: TextureRect = $Panel/AvatarBox/Avatar
@onready var _name_label: Label = $Panel/NameLabel
@onready var _intro_label: Label = $Panel/IntroLabel
@onready var _github: Button = $Panel/GitHubButton
@onready var _coffee: Button = $Panel/CoffeeButton
@onready var _close: Button = $Panel/CloseButton


func _ready() -> void:
	var tex: Texture2D = _load_avatar()
	if tex != null:
		_avatar.texture = tex
	_name_label.text = DEV_NAME
	_intro_label.text = DEV_INTRO
	_github.pressed.connect(_on_github_pressed)
	_coffee.pressed.connect(_on_coffee_pressed)
	_close.pressed.connect(_do_close)
	_apply_skin()
	# 팝업 안 키보드 포커스는 GitHub 버튼에서 시작(Tab/방향키로 닫기와 순환, Esc로 해제).
	_github.grab_focus()


## Esc/닫기 모두 해제로 처리(NicknameDialog와 동일 관례).
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_do_close()
		accept_event()


func _do_close() -> void:
	closed.emit()
	queue_free()


func _on_github_pressed() -> void:
	_open_url(GITHUB_URL)


func _on_coffee_pressed() -> void:
	_open_url(COFFEE_URL)


## 외부 링크 열기. 웹은 팝업 차단 회피를 위해 클릭 핸들러 안에서 동기로 window.open을
## 호출하고, 데스크톱은 OS.shell_open을 쓴다. URL이 비면 아무것도 하지 않는다.
func _open_url(url: String) -> void:
	if url.strip_edges().is_empty():
		return
	# 검증 로깅(어떤 URL을 여는지 남겨 캡처/CI에서 확인). 실제 개방은 아래 분기가 담당.
	print("[ProfileDialog] open_url: ", url)
	# 검증/CI 안전장치: 환경변수가 있으면 실제로 브라우저를 열지 않는다(사용자 브라우저
	# 임의 개방 방지). 프로덕션에서는 이 변수가 없으므로 정상 동작한다.
	if OS.has_environment("OVERLOCK_LINK_DRYRUN"):
		return
	if OS.has_feature("web"):
		# JSON.stringify로 URL을 안전한 JS 문자열 리터럴로 감싼다. use_global=true.
		JavaScriptBridge.eval('window.open(%s, "_blank");' % JSON.stringify(url), true)
	else:
		OS.shell_open(url)


func _load_avatar() -> Texture2D:
	if ResourceLoader.exists(DEV_PROFILE_TEX):
		return load(DEV_PROFILE_TEX) as Texture2D
	return null


## 시트 스킨(있으면) 소형 필 버튼 + 베이지 패널, 없으면 절차 폴백(NicknameDialog와 동일).
func _apply_skin() -> void:
	if UiSkin.has_skin():
		UiSkin.skin_panel($PanelBg, "beige")
		UiSkin.skin_button(_github, "small", 18)
		UiSkin.skin_button(_coffee, "small", 18)
		UiSkin.skin_button(_close, "small", 18)
		return
	_skin_button(_github)
	_skin_button(_coffee)
	_skin_button(_close)


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
