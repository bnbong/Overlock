class_name ProfileDialog
extends Control
## 개발자 프로필 팝업 (재봉 스킨 모달). 메인 메뉴 우하단 프로필 칩 클릭으로 연다
## (res://scenes/ProfileDialog.tscn). NicknameDialog와 동일한 모달 관례를 따른다
## (Dim + 재봉 패치 패널 + Esc/닫기로 해제, queue_free).
##
## - 아바타(원형, 재봉 톤 링) 크게 + 이름 + 한 줄 소개 + 제보/후원/닫기 버튼.
## - 링크 열기: 데스크톱은 OS.shell_open, 웹은 JavaScriptBridge로 window.open(_, "_blank").
##   웹 팝업 차단을 피하려면 반드시 클릭(pressed) 핸들러 안에서 동기로 호출해야 한다.
## - 순수 UI — 게임 값·판정과 무관.

signal closed

const DEV_NAME: String = "bnbong"
const DEV_INTRO: String = "Overlock 개발자"
const ISSUES_URL: String = "https://github.com/bnbong/Overlock/issues"
# 확장 자리: 크티(Ctee) 후원 버튼. 크티 플레이스 URL(예: https://ctee.kr/place/<아이디>)을
# 아래에 채우면 _ready에서 버튼이 자동 노출된다(핸들러·스킨은 이미 배선돼 있다).
const SUPPORT_URL: String = "https://ctee.kr/place/bnbong"
const DEV_PROFILE_TEX: String = "res://assets/gfx/dev_profile.png"

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
# PanelBg가 Panel(VBox)을 감싸는 세로 여백(위/아래 각각). 가로 여백(40px)은 씬의
# 고정 오프셋 차이(PanelBg ±240 vs Panel ±200)로 유지한다.
const _PANEL_PAD_V: float = 32.0

@onready var _avatar: TextureRect = $Panel/AvatarBox/Avatar
@onready var _name_label: Label = $Panel/NameLabel
@onready var _intro_label: Label = $Panel/IntroLabel
@onready var _report: Button = $Panel/ReportButton
@onready var _support: Button = $Panel/SupportButton
@onready var _close: Button = $Panel/CloseButton


func _ready() -> void:
	var tex: Texture2D = _load_avatar()
	if tex != null:
		_avatar.texture = tex
	_name_label.text = DEV_NAME
	_intro_label.text = DEV_INTRO
	_report.pressed.connect(_on_report_pressed)
	_support.pressed.connect(_on_support_pressed)
	_close.pressed.connect(_do_close)
	# URL이 비어 있으면 숨김 유지, 채워지면 자동 노출(수동 토글 불필요).
	_support.visible = not SUPPORT_URL.strip_edges().is_empty()
	_apply_skin()
	# 팝업 안 키보드 포커스는 제보 버튼에서 시작(Tab/방향키로 닫기와 순환, Esc로 해제).
	_report.grab_focus()
	# 버튼 수(제보/후원/닫기 또는 제보/닫기)에 따라 콘텐츠 높이가 달라지므로
	# 실제 최소 크기를 재서 패널을 감싼다(넘침 방지, 중앙 정렬·여백 유지).
	_fit_to_content()


## Panel(VBox)의 콘텐츠 최소 높이를 재서 Panel과 PanelBg의 세로 크기를 맞춘다.
## 가로 오프셋(중앙 정렬·좌우 여백)은 씬 값 그대로 두고 세로만 조정한다.
func _fit_to_content() -> void:
	# 자식 버튼/라벨의 최소 크기가 확정되도록 한 프레임 대기.
	await get_tree().process_frame
	var content_h: float = $Panel.get_combined_minimum_size().y
	$Panel.offset_top = -content_h * 0.5
	$Panel.offset_bottom = content_h * 0.5
	var bg_h: float = content_h + _PANEL_PAD_V * 2.0
	$PanelBg.offset_top = -bg_h * 0.5
	$PanelBg.offset_bottom = bg_h * 0.5


## Esc/닫기 모두 해제로 처리(NicknameDialog와 동일 관례).
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_do_close()
		accept_event()


func _do_close() -> void:
	closed.emit()
	queue_free()


func _on_report_pressed() -> void:
	_open_url(ISSUES_URL)


func _on_support_pressed() -> void:
	_open_url(SUPPORT_URL)


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
		UiSkin.skin_button(_report, "small", 18)
		UiSkin.skin_button(_support, "small", 18)
		UiSkin.skin_button(_close, "small", 18)
		return
	_skin_button(_report)
	_skin_button(_support)
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
