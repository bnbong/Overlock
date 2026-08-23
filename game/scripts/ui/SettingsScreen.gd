extends Control
## 온라인 설정 화면(재봉 스킨 패널). 닉네임(1~16자)과 소리 크기(마스터/배경음/효과음)를
## 입력·저장한다(기획서 §18 Phase 5 닉네임 입력, §7 오디오 볼륨). 저장은 LeaderboardClient가
## user://settings.json에 영속하고, 버스 반영은 AudioManager가 담당한다.
##
## 서버 URL은 UI에서 제거했다(배포 시 데스크톱 기본값=프로덕션, 웹=same-origin 자동).
## 셀프호스팅/개발은 user://settings.json에 base_url을 수동으로 적어 우선시킨다. 닉네임 변경은
## 메인 화면의 닉네임 태그로도 가능하다(진입점 중복 허용).
##
## 볼륨: 슬라이더 드래그 중 AudioManager.set_*_volume로 버스에 실시간 반영하고(value_changed),
## 조작 종료 시(drag_ended) LeaderboardClient.save_volumes로 즉시 영속한다. 마스터/효과음
## 슬라이더는 조작 종료 시 효과음을 1회 미리듣기해 체감을 확인시킨다(배경음은 제외).

const MAIN_SCENE: String = "res://scenes/Main.tscn"

# 재봉 스킨 버튼 톤(MainMenu와 통일).
const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
# 볼륨 슬라이더 재봉 톤(SewingSkin 팔레트 계승).
const _THREAD: Color = Color(0.553, 0.384, 0.725)  # 실 보라(채운 구간)
const _THREAD_HI: Color = Color(0.616, 0.435, 0.784)  # 강조(하이라이트)
const _FABRIC_DEEP: Color = Color(0.796, 0.726, 0.576)  # 원단 그늘(트랙 바탕)
const _KNOT: Color = Color(0.478, 0.333, 0.243)  # 단추/매듭(그래버)
const _KNOT_HI: Color = Color(0.6, 0.44, 0.34)

@onready var _nick_edit: LineEdit = $Panel/NickRow/NickEdit
@onready var _hint_label: Label = $Panel/HintLabel
@onready var _status_label: Label = $Panel/StatusLabel
@onready var _save_button: Button = $Panel/SaveButton
@onready var _back_button: Button = $Panel/BackButton
@onready var _master_slider: HSlider = $Panel/MasterRow/MasterSlider
@onready var _master_value: Label = $Panel/MasterRow/MasterValue
@onready var _bgm_slider: HSlider = $Panel/BgmRow/BgmSlider
@onready var _bgm_value: Label = $Panel/BgmRow/BgmValue
@onready var _sfx_slider: HSlider = $Panel/SfxRow/SfxSlider
@onready var _sfx_value: Label = $Panel/SfxRow/SfxValue


func _ready() -> void:
	_nick_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_nick_edit.text = LeaderboardClient.nickname
	_hint_label.text = "리더보드에 표시될 닉네임 (1~16자)"
	_apply_skin()
	_setup_volume()
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
	# 볼륨은 슬라이더 조작 종료 시 이미 영속하지만, 키보드 조작 등 drag_ended가 없는 변경도
	# 저장에 포함되도록 현재 버스값을 한 번 더 반영한다.
	_persist_volumes()
	if not LeaderboardClient.save_nickname(nick):
		_status_label.text = "저장 실패"
		return
	# 정규화된 값으로 필드를 되비춘다(공백 제거 등).
	_nick_edit.text = LeaderboardClient.nickname
	_status_label.text = "저장됨"


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


# --- 볼륨(마스터/배경음/효과음) ---


## 세 슬라이더를 현재 버스 볼륨(AudioManager)으로 초기화하고 시그널을 배선한다. 값 설정을
## 시그널 연결보다 먼저 해 초기화 시 불필요한 set/미리듣기가 튀지 않게 한다.
func _setup_volume() -> void:
	_init_slider(_master_slider, _master_value, AudioManager.get_master_volume())
	_init_slider(_bgm_slider, _bgm_value, AudioManager.get_bgm_volume())
	_init_slider(_sfx_slider, _sfx_value, AudioManager.get_sfx_volume())
	_master_slider.value_changed.connect(_on_master_changed)
	_bgm_slider.value_changed.connect(_on_bgm_changed)
	_sfx_slider.value_changed.connect(_on_sfx_changed)
	# 조작 종료 시: 세 슬라이더 모두 즉시 영속. 마스터/효과음은 효과음 1회 미리듣기(preview=true).
	_master_slider.drag_ended.connect(_on_volume_drag_ended.bind(true))
	_bgm_slider.drag_ended.connect(_on_volume_drag_ended.bind(false))
	_sfx_slider.drag_ended.connect(_on_volume_drag_ended.bind(true))


func _init_slider(slider: HSlider, value_label: Label, linear: float) -> void:
	_skin_slider(slider)
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = roundf(linear * 100.0)
	_update_percent(value_label, slider.value)


func _update_percent(value_label: Label, percent: float) -> void:
	value_label.text = "%d%%" % int(round(percent))


func _on_master_changed(percent: float) -> void:
	AudioManager.set_master_volume(percent / 100.0)
	_update_percent(_master_value, percent)


func _on_bgm_changed(percent: float) -> void:
	AudioManager.set_bgm_volume(percent / 100.0)
	_update_percent(_bgm_value, percent)


func _on_sfx_changed(percent: float) -> void:
	AudioManager.set_sfx_volume(percent / 100.0)
	_update_percent(_sfx_value, percent)


## 슬라이더 조작 종료: 현재 볼륨을 영속하고, 마스터/효과음이면 효과음 미리듣기를 1회 재생한다.
func _on_volume_drag_ended(_value_changed: bool, preview: bool) -> void:
	_persist_volumes()
	if preview:
		AudioManager.preview_sfx()


## 현재 버스 볼륨(AudioManager 권위값)을 settings.json에 영속한다.
func _persist_volumes() -> void:
	LeaderboardClient.save_volumes(
		AudioManager.get_master_volume(),
		AudioManager.get_bgm_volume(),
		AudioManager.get_sfx_volume(),
	)


## 재봉 톤 슬라이더 스타일: 원단 그늘 트랙 + 실 보라 채움 + 단추(매듭) 그래버.
func _skin_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = _FABRIC_DEEP
	track.set_corner_radius_all(4)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	slider.add_theme_stylebox_override("slider", track)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = _THREAD
	fill.set_corner_radius_all(4)
	slider.add_theme_stylebox_override("grabber_area", fill)
	var fill_hi: StyleBoxFlat = fill.duplicate()
	fill_hi.bg_color = _THREAD_HI
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	slider.add_theme_icon_override("grabber", _make_grabber(_KNOT))
	slider.add_theme_icon_override("grabber_highlight", _make_grabber(_KNOT_HI))


## 단추(매듭) 모양 그래버 텍스처(안티에일리어스 원). 시트 에셋 없이 톤을 통일한다.
static func _make_grabber(color: Color) -> ImageTexture:
	var d: int = 18
	var img: Image = Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c: float = (d - 1) * 0.5
	var r: float = c - 1.0
	for y in range(d):
		for x in range(d):
			var dist: float = Vector2(x - c, y - c).length()
			if dist <= r:
				img.set_pixel(x, y, color)
			elif dist <= r + 1.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, r + 1.0 - dist))
	return ImageTexture.create_from_image(img)


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
